/**
 * Grocery Ordering Orchestrator
 * 
 * State machine that coordinates:
 *   - browser-use for cart building
 *   - Lumbox for email verification
 *   - AgentSIM for phone verification
 *   - Supabase for persistence
 *
 * State transitions:
 *   pending → session_started → building_cart → cart_ready → 
 *   selecting_slot → awaiting_review → user_approved → 
 *   checkout_started → completed
 *
 * Error handling:
 *   Any state can transition to 'failed'
 *   Failed orders can be retried (up to 3 times)
 */

import { createClient } from "@supabase/supabase-js";
import * as browserAgent from "../api/v1/providers/browser-agent.js";

// ── Configuration ──────────────────────────────────────────────────────────────

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const LUMBOX_API_KEY = process.env.LUMBOX_API_KEY ?? "";
const AGENTSIM_API_KEY = process.env.AGENTSIM_API_KEY ?? "";

const MAX_RETRIES = 3;

// ── Supabase Client ────────────────────────────────────────────────────────────

function getSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
    throw new Error("Supabase not configured");
  }
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
}

// ── Order State Machine ────────────────────────────────────────────────────────

const VALID_TRANSITIONS = {
  pending: ["session_started", "failed", "cancelled"],
  session_started: ["building_cart", "failed", "cancelled"],
  building_cart: ["cart_ready", "failed", "cancelled"],
  cart_ready: ["selecting_slot", "awaiting_review", "failed", "cancelled"],
  selecting_slot: ["awaiting_review", "failed", "cancelled"],
  awaiting_review: ["user_approved", "cancelled"],
  user_approved: ["checkout_started", "failed", "cancelled"],
  checkout_started: ["completed", "failed"],
  completed: [],
  failed: ["pending"],  // Can retry
  cancelled: [],
};

/**
 * Create a new grocery order.
 */
export async function createOrder({
  userId,
  provider,
  items,
  deliveryAddress,
  mealPlanId,
}) {
  const supabase = getSupabase();

  // Validate provider
  if (!browserAgent.SUPPORTED_PROVIDERS.includes(provider)) {
    throw new Error(`Unsupported provider: ${provider}`);
  }

  // Get user's provider account if exists
  const { data: providerAccount } = await supabase
    .from("user_provider_accounts")
    .select("id, browser_profile_id, login_status")
    .eq("user_id", userId)
    .eq("provider", provider)
    .single();

  // Create order
  const { data: order, error } = await supabase
    .from("grocery_orders")
    .insert({
      user_id: userId,
      meal_plan_id: mealPlanId,
      provider,
      provider_account_id: providerAccount?.id,
      requested_items: items,
      delivery_address: deliveryAddress,
      status: "pending",
    })
    .select()
    .single();

  if (error) throw error;

  return order;
}

/**
 * Start processing an order.
 * This kicks off the browser-use session and begins cart building.
 */
export async function startOrder(orderId) {
  const supabase = getSupabase();

  // Get order with provider account
  const { data: order, error } = await supabase
    .from("grocery_orders")
    .select(`
      *,
      provider_account:user_provider_accounts(*)
    `)
    .eq("id", orderId)
    .single();

  if (error) throw error;
  if (!order) throw new Error("Order not found");

  // Validate state
  if (order.status !== "pending" && order.status !== "failed") {
    throw new Error(`Cannot start order in status: ${order.status}`);
  }

  try {
    // Transition to session_started
    await updateOrderStatus(orderId, "session_started", {
      status_message: "Starting browser session...",
    });

    // Create browser session
    const { sessionId, liveUrl } = await browserAgent.createSession({
      provider: order.provider,
      profileId: order.provider_account?.browser_profile_id,
    });

    await supabase
      .from("grocery_orders")
      .update({
        browser_session_id: sessionId,
        browser_live_url: liveUrl,
      })
      .eq("id", orderId);

    // Transition to building_cart
    await updateOrderStatus(orderId, "building_cart", {
      status_message: "Adding items to cart...",
    });

    // Build cart
    const cartResult = await browserAgent.buildCart({
      provider: order.provider,
      items: order.requested_items,
      address: order.delivery_address,
      profileId: order.provider_account?.browser_profile_id,
    });

    // Save cart results
    const matchedItems = cartResult.itemsAdded?.filter(i => i.status === "found") ?? [];
    const substitutions = cartResult.itemsAdded?.filter(i => i.status === "substituted") ?? [];
    const missingItems = cartResult.itemsMissing ?? [];

    await supabase
      .from("grocery_orders")
      .update({
        matched_items: matchedItems,
        substitutions: substitutions,
        missing_items: missingItems,
        subtotal_cents: Math.round((cartResult.subtotal ?? 0) * 100),
        provider_cart_url: cartResult.cartUrl,
        screenshots: [
          ...(order.screenshots ?? []),
          { step: "cart_built", url: cartResult.screenshotUrl, at: new Date().toISOString() },
        ],
      })
      .eq("id", orderId);

    // Insert order items for detailed tracking
    if (cartResult.itemsAdded?.length) {
      const orderItems = cartResult.itemsAdded.map((item) => ({
        order_id: orderId,
        requested_name: item.requested,
        status: item.status,
        matched_name: item.matched,
        unit_price_cents: Math.round((item.price ?? 0) * 100),
        quantity: item.quantity ?? 1,
        total_price_cents: Math.round((item.price ?? 0) * (item.quantity ?? 1) * 100),
      }));

      await supabase.from("grocery_order_items").insert(orderItems);
    }

    // Transition to cart_ready
    await updateOrderStatus(orderId, "cart_ready", {
      status_message: `Cart built with ${matchedItems.length} items`,
      cart_ready_at: new Date().toISOString(),
    });

    return {
      orderId,
      status: "cart_ready",
      sessionId,
      liveUrl,
      matchedItems: matchedItems.length,
      substitutions: substitutions.length,
      missingItems: missingItems.length,
      subtotal: cartResult.subtotal,
    };
  } catch (err) {
    await failOrder(orderId, err.message);
    throw err;
  }
}

/**
 * Get delivery slots for an order.
 */
export async function getDeliverySlots(orderId) {
  const supabase = getSupabase();

  const { data: order, error } = await supabase
    .from("grocery_orders")
    .select("*")
    .eq("id", orderId)
    .single();

  if (error) throw error;
  if (!order.browser_session_id) {
    throw new Error("No active browser session");
  }

  await updateOrderStatus(orderId, "selecting_slot", {
    status_message: "Fetching delivery slots...",
  });

  try {
    const slots = await browserAgent.getDeliverySlots({
      sessionId: order.browser_session_id,
      provider: order.provider,
    });

    await supabase
      .from("grocery_orders")
      .update({ available_slots: slots.slots })
      .eq("id", orderId);

    return slots;
  } catch (err) {
    await failOrder(orderId, err.message);
    throw err;
  }
}

/**
 * Select a delivery slot.
 */
export async function selectDeliverySlot(orderId, { date, timeRange }) {
  const supabase = getSupabase();

  const { data: order, error } = await supabase
    .from("grocery_orders")
    .select("*")
    .eq("id", orderId)
    .single();

  if (error) throw error;

  try {
    const result = await browserAgent.selectDeliverySlot({
      sessionId: order.browser_session_id,
      provider: order.provider,
      date,
      timeRange,
    });

    await supabase
      .from("grocery_orders")
      .update({
        delivery_slot: { date, timeRange, selected: result.selected },
      })
      .eq("id", orderId);

    // Transition to awaiting_review
    await updateOrderStatus(orderId, "awaiting_review", {
      status_message: "Ready for your review",
    });

    return result;
  } catch (err) {
    await failOrder(orderId, err.message);
    throw err;
  }
}

/**
 * Get order summary for user review.
 */
export async function getOrderSummary(orderId) {
  const supabase = getSupabase();

  const { data: order, error } = await supabase
    .from("grocery_orders")
    .select(`
      *,
      items:grocery_order_items(*)
    `)
    .eq("id", orderId)
    .single();

  if (error) throw error;

  return {
    id: order.id,
    provider: order.provider,
    status: order.status,
    
    items: {
      matched: order.matched_items ?? [],
      substituted: order.substitutions ?? [],
      missing: order.missing_items ?? [],
    },
    
    pricing: {
      subtotal: (order.subtotal_cents ?? 0) / 100,
      deliveryFee: (order.delivery_fee_cents ?? 0) / 100,
      serviceFee: (order.service_fee_cents ?? 0) / 100,
      tax: (order.tax_cents ?? 0) / 100,
      tip: (order.tip_cents ?? 0) / 100,
      total: (order.total_cents ?? 0) / 100,
    },
    
    delivery: order.delivery_slot,
    deliveryAddress: order.delivery_address,
    
    liveUrl: order.browser_live_url,
    cartUrl: order.provider_cart_url,
    
    screenshots: order.screenshots,
    createdAt: order.created_at,
  };
}

/**
 * User approves the order - proceed to checkout.
 */
export async function approveOrder(orderId, { tipCents = 0 } = {}) {
  const supabase = getSupabase();

  const { data: order, error } = await supabase
    .from("grocery_orders")
    .select("*")
    .eq("id", orderId)
    .single();

  if (error) throw error;

  if (order.status !== "awaiting_review") {
    throw new Error(`Order must be awaiting_review, is: ${order.status}`);
  }

  // Update with tip and approval
  await supabase
    .from("grocery_orders")
    .update({
      tip_cents: tipCents,
      user_approved_at: new Date().toISOString(),
    })
    .eq("id", orderId);

  await updateOrderStatus(orderId, "user_approved", {
    status_message: "Approved by user",
  });

  // Prepare checkout
  await updateOrderStatus(orderId, "checkout_started", {
    status_message: "Navigating to checkout...",
  });

  try {
    const checkoutResult = await browserAgent.prepareCheckout({
      sessionId: order.browser_session_id,
      provider: order.provider,
    });

    // Update with final totals
    await supabase
      .from("grocery_orders")
      .update({
        subtotal_cents: Math.round((checkoutResult.subtotal ?? 0) * 100),
        delivery_fee_cents: Math.round((checkoutResult.deliveryFee ?? 0) * 100),
        service_fee_cents: Math.round((checkoutResult.serviceFee ?? 0) * 100),
        tax_cents: Math.round((checkoutResult.tax ?? 0) * 100),
        total_cents: Math.round((checkoutResult.total ?? 0) * 100),
        provider_checkout_url: checkoutResult.checkoutUrl,
        screenshots: [
          ...(order.screenshots ?? []),
          { step: "checkout_ready", url: checkoutResult.screenshotUrl, at: new Date().toISOString() },
        ],
      })
      .eq("id", orderId);

    // Return checkout URL for user to complete payment
    // We stop here - user completes payment in provider's UI
    return {
      checkoutUrl: checkoutResult.checkoutUrl,
      liveUrl: order.browser_live_url,
      total: checkoutResult.total,
      readyToSubmit: checkoutResult.readyToSubmit,
    };
  } catch (err) {
    await failOrder(orderId, err.message);
    throw err;
  }
}

/**
 * Mark order as completed (called after user confirms payment).
 */
export async function completeOrder(orderId, { providerOrderId } = {}) {
  const supabase = getSupabase();

  const { data: order, error } = await supabase
    .from("grocery_orders")
    .select("browser_session_id")
    .eq("id", orderId)
    .single();

  if (error) throw error;

  // Stop browser session
  if (order.browser_session_id) {
    try {
      await browserAgent.stopSession(order.browser_session_id);
    } catch {
      // Ignore - session may already be stopped
    }
  }

  await supabase
    .from("grocery_orders")
    .update({
      provider_order_id: providerOrderId,
      submitted_at: new Date().toISOString(),
      completed_at: new Date().toISOString(),
    })
    .eq("id", orderId);

  await updateOrderStatus(orderId, "completed", {
    status_message: "Order placed successfully",
  });

  return { success: true };
}

/**
 * Cancel an order.
 */
export async function cancelOrder(orderId, { reason } = {}) {
  const supabase = getSupabase();

  const { data: order, error } = await supabase
    .from("grocery_orders")
    .select("browser_session_id, status")
    .eq("id", orderId)
    .single();

  if (error) throw error;

  // Can't cancel completed orders
  if (order.status === "completed") {
    throw new Error("Cannot cancel completed order");
  }

  // Stop browser session
  if (order.browser_session_id) {
    try {
      await browserAgent.stopSession(order.browser_session_id);
    } catch {
      // Ignore
    }
  }

  await updateOrderStatus(orderId, "cancelled", {
    status_message: reason ?? "Cancelled by user",
  });

  return { success: true };
}

/**
 * Retry a failed order.
 */
export async function retryOrder(orderId) {
  const supabase = getSupabase();

  const { data: order, error } = await supabase
    .from("grocery_orders")
    .select("status, retry_count")
    .eq("id", orderId)
    .single();

  if (error) throw error;

  if (order.status !== "failed") {
    throw new Error("Can only retry failed orders");
  }

  if (order.retry_count >= MAX_RETRIES) {
    throw new Error(`Max retries (${MAX_RETRIES}) exceeded`);
  }

  await supabase
    .from("grocery_orders")
    .update({
      retry_count: order.retry_count + 1,
      browser_session_id: null,
      browser_live_url: null,
      error_code: null,
      error_message: null,
    })
    .eq("id", orderId);

  await updateOrderStatus(orderId, "pending", {
    status_message: `Retry ${order.retry_count + 1}/${MAX_RETRIES}`,
  });

  // Restart the order
  return startOrder(orderId);
}

// ── Helper Functions ───────────────────────────────────────────────────────────

async function updateOrderStatus(orderId, newStatus, extraFields = {}) {
  const supabase = getSupabase();

  const { data: order } = await supabase
    .from("grocery_orders")
    .select("status")
    .eq("id", orderId)
    .single();

  if (order) {
    const validNext = VALID_TRANSITIONS[order.status] ?? [];
    if (!validNext.includes(newStatus)) {
      throw new Error(`Invalid transition: ${order.status} → ${newStatus}`);
    }
  }

  const { error } = await supabase
    .from("grocery_orders")
    .update({
      status: newStatus,
      ...extraFields,
      step_log: supabase.sql`step_log || ${JSON.stringify([{
        status: newStatus,
        at: new Date().toISOString(),
        ...extraFields,
      }])}::jsonb`,
    })
    .eq("id", orderId);

  if (error) throw error;
}

async function failOrder(orderId, errorMessage) {
  const supabase = getSupabase();

  await supabase
    .from("grocery_orders")
    .update({
      status: "failed",
      error_message: errorMessage,
      status_message: `Failed: ${errorMessage}`,
    })
    .eq("id", orderId);
}

// ── Verification Infrastructure ────────────────────────────────────────────────

/**
 * Create a verification inbox for a user.
 * Used for provider account signups.
 */
export async function createUserVerificationInbox(userId) {
  if (!LUMBOX_API_KEY) {
    throw new Error("LUMBOX_API_KEY not configured");
  }

  const supabase = getSupabase();

  // Check if user already has an inbox
  const { data: existing } = await supabase
    .from("user_verification_inboxes")
    .select("*")
    .eq("user_id", userId)
    .single();

  if (existing) {
    return existing;
  }

  // Create Lumbox inbox
  const resp = await fetch("https://api.lumbox.co/v1/inboxes", {
    method: "POST",
    headers: {
      "X-API-Key": LUMBOX_API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name: `ounje-user-${userId.slice(0, 8)}`,
    }),
  });

  if (!resp.ok) {
    const err = await resp.text();
    throw new Error(`Lumbox createInbox failed: ${err}`);
  }

  const inbox = await resp.json();

  // Save to database
  const { data, error } = await supabase
    .from("user_verification_inboxes")
    .insert({
      user_id: userId,
      lumbox_inbox_id: inbox.id,
      email_address: inbox.address,
    })
    .select()
    .single();

  if (error) throw error;

  return data;
}

/**
 * Wait for an OTP email in the user's verification inbox.
 */
export async function waitForEmailOTP(userId, { timeout = 60, from } = {}) {
  if (!LUMBOX_API_KEY) {
    throw new Error("LUMBOX_API_KEY not configured");
  }

  const supabase = getSupabase();

  const { data: inbox } = await supabase
    .from("user_verification_inboxes")
    .select("lumbox_inbox_id")
    .eq("user_id", userId)
    .single();

  if (!inbox) {
    throw new Error("User has no verification inbox");
  }

  const params = new URLSearchParams({
    timeout: String(timeout),
    ...(from && { from }),
  });

  const resp = await fetch(
    `https://api.lumbox.co/v1/inboxes/${inbox.lumbox_inbox_id}/otp?${params}`,
    {
      headers: { "X-API-Key": LUMBOX_API_KEY },
    }
  );

  if (resp.status === 408) {
    throw new Error("OTP timeout - no verification email received");
  }

  if (!resp.ok) {
    const err = await resp.text();
    throw new Error(`Lumbox getOTP failed: ${err}`);
  }

  return await resp.json();
}

/**
 * Provision a phone number for SMS verification.
 * Uses AgentSIM for real carrier numbers.
 */
export async function provisionPhoneForVerification(userId) {
  if (!AGENTSIM_API_KEY) {
    throw new Error("AGENTSIM_API_KEY not configured");
  }

  const resp = await fetch("https://api.agentsim.dev/v1/numbers/provision", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${AGENTSIM_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      agent_id: `ounje-user-${userId.slice(0, 8)}`,
    }),
  });

  if (!resp.ok) {
    const err = await resp.text();
    throw new Error(`AgentSIM provision failed: ${err}`);
  }

  return await resp.json();
}

/**
 * Wait for an SMS OTP on a provisioned number.
 */
export async function waitForSmsOTP(numberId, { timeout = 60 } = {}) {
  if (!AGENTSIM_API_KEY) {
    throw new Error("AGENTSIM_API_KEY not configured");
  }

  const resp = await fetch(
    `https://api.agentsim.dev/v1/numbers/${numberId}/otp?timeout=${timeout}`,
    {
      headers: { Authorization: `Bearer ${AGENTSIM_API_KEY}` },
    }
  );

  if (resp.status === 408) {
    throw new Error("OTP timeout - no SMS received");
  }

  if (!resp.ok) {
    const err = await resp.text();
    throw new Error(`AgentSIM waitForOTP failed: ${err}`);
  }

  return await resp.json();
}

/**
 * Release a provisioned phone number.
 */
export async function releasePhone(numberId) {
  if (!AGENTSIM_API_KEY) return;

  await fetch(`https://api.agentsim.dev/v1/numbers/${numberId}/release`, {
    method: "POST",
    headers: { Authorization: `Bearer ${AGENTSIM_API_KEY}` },
  });
}
