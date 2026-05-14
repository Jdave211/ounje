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

import * as browserAgent from "../api/v1/providers/browser-agent.js";
import {
  createNotificationEvent,
  fetchOrderingAutonomy,
  fetchOrderingGuardrails,
} from "./notification-events.js";
import { invalidateUserBootstrapCache } from "./user-bootstrap-cache.js";
import { getServiceRoleSupabase } from "./supabase-clients.js";

// ── Configuration ──────────────────────────────────────────────────────────────

const LUMBOX_API_KEY = process.env.LUMBOX_API_KEY ?? "";
const AGENTSIM_API_KEY = process.env.AGENTSIM_API_KEY ?? "";

const MAX_RETRIES = 3;

// ── Supabase Client ────────────────────────────────────────────────────────────

function getSupabase() {
  return getServiceRoleSupabase();
}

function normalizeText(value) {
  return String(value ?? "").trim();
}

function parseDateValue(value) {
  const normalized = normalizeText(value);
  if (!normalized) return null;
  const parsed = new Date(normalized);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function isoDay(value) {
  const parsed = value instanceof Date ? value : parseDateValue(value);
  if (!parsed) return null;
  return parsed.toISOString().slice(0, 10);
}

const AUTONOMY_MODES = new Set(["autoOrderWithinBudget", "fullyAutonomousGuardrails"]);
const MANUAL_REVIEW_MODES = new Set(["suggestOnly", "approvalRequired"]);

function effectiveOrderingAutonomy(orderingAutonomy, pricingTier) {
  const autonomy = normalizeText(orderingAutonomy);
  const tier = normalizeText(pricingTier).toLowerCase();

  if (!autonomy) {
    return null;
  }

  switch (tier) {
  case "free":
    return autonomy === "fullyAutonomousGuardrails" || autonomy === "autoOrderWithinBudget"
      ? "approvalRequired"
      : autonomy;
  case "plus":
    return autonomy === "fullyAutonomousGuardrails"
      ? "autoOrderWithinBudget"
      : autonomy;
  case "autopilot":
  case "foundinglifetime":
  case "founding_lifetime":
    return autonomy;
  default:
    return autonomy;
  }
}

async function resolveTargetDeliveryDay(order, supabase = getSupabase()) {
  if (!normalizeText(order?.meal_plan_id)) {
    return null;
  }

  const { data: cycle } = await supabase
    .from("meal_prep_cycles")
    .select("plan")
    .eq("user_id", order.user_id)
    .eq("plan_id", order.meal_plan_id)
    .order("generated_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  return (
    isoDay(cycle?.plan?.periodStart)
    ?? isoDay(cycle?.plan?.deliveryAnchorDate)
    ?? isoDay(cycle?.plan?.periodEnd)
  );
}

function parseSlotStartMinutes(timeRange) {
  const normalized = normalizeText(timeRange).toLowerCase();
  if (!normalized) return null;

  const startLabel = normalized.split("-")[0]?.trim() ?? normalized;
  const match = startLabel.match(/(\d{1,2})(?::(\d{2}))?\s*(am|pm)/i);
  if (!match) return null;

  let hour = Number(match[1] ?? 0);
  const minute = Number(match[2] ?? 0);
  const meridiem = normalizeText(match[3]).toLowerCase();

  if (meridiem === "pm" && hour < 12) hour += 12;
  if (meridiem === "am" && hour === 12) hour = 0;
  if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;
  return (hour * 60) + minute;
}

function dayDifference(fromISO, toISO) {
  const from = parseDateValue(fromISO);
  const to = parseDateValue(toISO);
  if (!from || !to) return null;
  const startOfFrom = Date.UTC(from.getUTCFullYear(), from.getUTCMonth(), from.getUTCDate());
  const startOfTo = Date.UTC(to.getUTCFullYear(), to.getUTCMonth(), to.getUTCDate());
  return Math.round((startOfTo - startOfFrom) / (24 * 60 * 60 * 1000));
}

function pickRecommendedDeliverySlot({ slots, targetDeliveryDay, preferredTimeMinutes }) {
  const availableSlots = (Array.isArray(slots) ? slots : []).filter((slot) => slot?.available !== false);
  if (!availableSlots.length) {
    return { recommendedSlot: null, recommendationReason: null };
  }

  const todayISO = new Date().toISOString().slice(0, 10);
  const cheapestFee = availableSlots.reduce((lowest, slot) => {
    const fee = Number(slot?.fee ?? 0);
    return Number.isFinite(fee) ? Math.min(lowest, fee) : lowest;
  }, Number.POSITIVE_INFINITY);

  let bestSlot = null;
  let bestScore = Number.POSITIVE_INFINITY;

  for (const slot of availableSlots) {
    const fee = Number(slot?.fee ?? 0);
    const startMinutes = parseSlotStartMinutes(slot?.timeRange);
    const daysUntilSlot = dayDifference(todayISO, slot?.date) ?? 0;
    const targetDelta = targetDeliveryDay ? dayDifference(slot?.date, targetDeliveryDay) : null;
    const timePenalty = preferredTimeMinutes != null && startMinutes != null
      ? Math.abs(startMinutes - preferredTimeMinutes) * 0.45
      : 0;
    const feePenalty = Number.isFinite(fee) ? fee * 450 : 0;
    const latenessPenalty = targetDelta != null && targetDelta < 0
      ? (Math.abs(targetDelta) * 9000) + 30000
      : 0;
    const earlinessPenalty = targetDelta != null && targetDelta > 0
      ? targetDelta * 700
      : 0;
    const speedPenalty = Math.max(0, daysUntilSlot) * 120;

    const score = feePenalty + timePenalty + latenessPenalty + earlinessPenalty + speedPenalty;

    if (score < bestScore) {
      bestScore = score;
      bestSlot = slot;
    }
  }

  if (!bestSlot) {
    return { recommendedSlot: null, recommendationReason: null };
  }

  const reasons = [];
  const chosenFee = Number(bestSlot?.fee ?? 0);
  const chosenStartMinutes = parseSlotStartMinutes(bestSlot?.timeRange);
  const chosenTargetDelta = targetDeliveryDay ? dayDifference(bestSlot?.date, targetDeliveryDay) : null;

  if (Number.isFinite(chosenFee) && Math.abs(chosenFee - cheapestFee) < 0.001) {
    reasons.push("lowest fee");
  }
  if (chosenTargetDelta === 0) {
    reasons.push("matches the prep day");
  } else if (chosenTargetDelta != null && chosenTargetDelta > 0) {
    reasons.push("lands before the prep day");
  }
  if (preferredTimeMinutes != null && chosenStartMinutes != null) {
    const minuteGap = Math.abs(chosenStartMinutes - preferredTimeMinutes);
    if (minuteGap <= 90) {
      reasons.push("close to your preferred time");
    } else if (chosenStartMinutes < preferredTimeMinutes) {
      reasons.push("earlier to keep delivery fees down");
    }
  }

  return {
    recommendedSlot: bestSlot,
    recommendationReason: reasons.slice(0, 2).join(" · ") || "Best fee and timing balance for this prep",
  };
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
  invalidateUserBootstrapCache(userId);

  return order;
}

function estimateSelectedSlotFeeCents(order, date, timeRange) {
  const availableSlots = Array.isArray(order?.available_slots) ? order.available_slots : [];
  const selectedSlot = availableSlots.find((slot) => {
    const slotDate = normalizeText(slot?.date);
    const slotRange = normalizeText(slot?.timeRange ?? slot?.time_range);
    return slotDate === normalizeText(date) && slotRange === normalizeText(timeRange);
  }) ?? order?.delivery_slot ?? null;

  const fee = Number(selectedSlot?.fee ?? 0);
  if (!Number.isFinite(fee) || fee <= 0) {
    return 0;
  }

  return Math.max(0, Math.round(fee * 100));
}

function estimateCheckoutSpendCents(order, selectedSlotFeeCents = 0) {
  const subtotalCents = Math.max(0, Math.round(Number(order?.subtotal_cents ?? 0)));
  return subtotalCents + Math.max(0, Math.round(selectedSlotFeeCents));
}

async function loadCheckoutPolicy(order, { date, timeRange } = {}) {
  const guardrails = await fetchOrderingGuardrails(order.user_id).catch(() => ({
    orderingAutonomy: null,
    budgetPerCycle: null,
    budgetWindow: null,
    pricingTier: null,
  }));
  const supabase = getSupabase();
  const targetDeliveryDay = await resolveTargetDeliveryDay(order, supabase);
  const requestedAutonomy = guardrails.orderingAutonomy || await fetchOrderingAutonomy(order.user_id).catch(() => null);
  const autonomy = effectiveOrderingAutonomy(requestedAutonomy, guardrails.pricingTier);
  const budgetPerCycle = Number(guardrails.budgetPerCycle ?? 0) || null;
  const budgetCents = budgetPerCycle ? Math.round(budgetPerCycle * 100) : 0;
  const selectedSlotFeeCents = estimateSelectedSlotFeeCents(order, date, timeRange);
  const estimatedSpendCents = estimateCheckoutSpendCents(order, selectedSlotFeeCents);
  const missingCount = Array.isArray(order.missing_items) ? order.missing_items.length : 0;
  const substitutionCount = Array.isArray(order.substitutions) ? order.substitutions.length : 0;
  const withinBudget = budgetCents > 0 ? estimatedSpendCents <= budgetCents : false;
  const selectedSlotDay = isoDay(date ?? order?.delivery_slot?.date);
  const withinTimeline = targetDeliveryDay && selectedSlotDay
    ? selectedSlotDay <= targetDeliveryDay
    : null;
  const shouldAutoAdvance =
    AUTONOMY_MODES.has(autonomy) &&
    withinBudget &&
    withinTimeline !== false &&
    missingCount === 0 &&
    substitutionCount === 0;
  const requiresHumanReview =
    MANUAL_REVIEW_MODES.has(autonomy) ||
    !withinBudget ||
    withinTimeline === false ||
    missingCount > 0 ||
    substitutionCount > 0;

  return {
    autonomy,
    requestedAutonomy,
    pricingTier: guardrails.pricingTier ?? null,
    budgetPerCycle,
    budgetCents,
    selectedSlotFeeCents,
    estimatedSpendCents,
    missingCount,
    substitutionCount,
    withinBudget,
    withinTimeline,
    targetDeliveryDay,
    selectedSlotDay,
    shouldAutoAdvance,
    requiresHumanReview,
  };
}

/**
 * Start processing an order.
 * This kicks off the browser-use session and begins cart building.
 */
export async function startOrder(orderId, { deliveryAddress: deliveryAddressOverride } = {}) {
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

  const resolvedDeliveryAddress = isCompleteDeliveryAddress(deliveryAddressOverride)
    ? deliveryAddressOverride
    : order.delivery_address;

  if (!isCompleteDeliveryAddress(resolvedDeliveryAddress)) {
    throw new Error("A complete deliveryAddress is required before starting this order");
  }

  if (JSON.stringify(order.delivery_address ?? null) !== JSON.stringify(resolvedDeliveryAddress ?? null)) {
    await supabase
      .from("grocery_orders")
      .update({
        delivery_address: resolvedDeliveryAddress,
      })
      .eq("id", orderId);
    order.delivery_address = resolvedDeliveryAddress;
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

    await emitOrderNotification(orderId, {
      kind: "autoshop_started",
      dedupeKey: `grocery-order-started-${order.user_id}-${orderId}`,
      title: "Our agents started shopping",
      body: "We’re building your cart now.",
      actionUrl: liveUrl ?? "ounje://cart",
      actionLabel: "Open cart",
      orderId,
      metadata: {
        provider: order.provider,
        status: "session_started",
      },
    }).catch(() => {});

    // Transition to building_cart
    await updateOrderStatus(orderId, "building_cart", {
      status_message: "Adding items to cart...",
    });

    // Build cart
    const cartResult = await browserAgent.buildCart({
      provider: order.provider,
      items: order.requested_items,
      address: resolvedDeliveryAddress,
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

    await emitOrderNotification(orderId, {
      kind: missingItems.length > 0 ? "autoshop_failed" : "autoshop_completed",
      dedupeKey: `grocery-cart-ready-${order.user_id}-${orderId}`,
      title: matchedItems.length > 0
        ? `Cart built with ${matchedItems.length} items`
        : "Your Instacart cart is ready",
      body: missingItems.length > 0
        ? `${missingItems.length} item${missingItems.length === 1 ? "" : "s"} still need attention before checkout.`
        : "Your grocery cart is set and ready for the next step.",
      actionUrl: cartResult.cartUrl ?? "ounje://cart",
      actionLabel: "Open cart",
      orderId,
      metadata: {
        matchedItems: matchedItems.length,
        substitutions: substitutions.length,
        missingItems: missingItems.length,
        provider: order.provider,
      },
    }).catch(() => {});

    let autoSlotSelection = null;
    try {
      const slotsPayload = await getDeliverySlots(orderId);
      const recommendedSlot = slotsPayload?.recommendedSlot ?? null;

      if (recommendedSlot?.date && recommendedSlot?.timeRange) {
        autoSlotSelection = await selectDeliverySlot(orderId, {
          date: recommendedSlot.date,
          timeRange: recommendedSlot.timeRange,
        });
      }
    } catch (slotError) {
      console.warn?.(`[grocery-orchestrator] slot recommendation failed for ${orderId}: ${slotError.message}`);
    }

    return {
      orderId,
      status: autoSlotSelection?.autoApproved
        ? "checkout_started"
        : autoSlotSelection
          ? "awaiting_review"
          : "cart_ready",
      sessionId,
      liveUrl,
      matchedItems: matchedItems.length,
      substitutions: substitutions.length,
      missingItems: missingItems.length,
      subtotal: cartResult.subtotal,
      deliverySlot: autoSlotSelection?.policy?.selectedDate && autoSlotSelection?.policy?.selectedTimeRange
        ? {
            date: autoSlotSelection.policy.selectedDate,
            timeRange: autoSlotSelection.policy.selectedTimeRange,
          }
        : null,
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
    const guardrails = await fetchOrderingGuardrails(order.user_id).catch(() => ({
      deliveryTimeMinutes: null,
      pricingTier: null,
      orderingAutonomy: null,
    }));
    const slots = await browserAgent.getDeliverySlots({
      sessionId: order.browser_session_id,
      provider: order.provider,
    });
    const targetDeliveryDay = await resolveTargetDeliveryDay(order, supabase);
    const { recommendedSlot, recommendationReason } = pickRecommendedDeliverySlot({
      slots: slots.slots,
      targetDeliveryDay,
      preferredTimeMinutes: Number(guardrails.deliveryTimeMinutes ?? 0) || null,
    });

    await supabase
      .from("grocery_orders")
      .update({ available_slots: slots.slots })
      .eq("id", orderId);

    return {
      ...slots,
      recommendedSlot,
      recommendationReason,
      targetDeliveryDay,
    };
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
        delivery_slot: {
          date,
          timeRange,
          selected: result.selected,
          selectedBy: "ounje",
        },
      })
      .eq("id", orderId);

    // Transition to awaiting_review
    await updateOrderStatus(orderId, "awaiting_review", {
      status_message: "Ready for your review",
    });

    const policy = await loadCheckoutPolicy(order, { date, timeRange });
    if (policy.shouldAutoAdvance) {
      const checkoutResult = await approveOrder(orderId, {
        tipCents: order.tip_cents ?? 0,
        approvalMode: "auto",
        policy: {
          ...policy,
          selectedDate: date,
          selectedTimeRange: timeRange,
        },
      });

      return {
        ...result,
        autoApproved: true,
        checkout: checkoutResult,
        policy,
      };
    }

    await emitOrderNotification(orderId, {
      kind: policy.requiresHumanReview ? "checkout_approval_required" : "cart_review_required",
      dedupeKey: `grocery-awaiting-review-${order.user_id}-${orderId}-${date}-${timeRange}`,
      title: policy.requiresHumanReview ? "Final checkout needs your go-ahead" : "Groceries are lined up",
      body: policy.requiresHumanReview
        ? (
            policy.withinTimeline === false
              ? `The selected delivery time lands after your prep window${timeRange ? ` (${timeRange})` : ""}, so checkout needs your review.`
              : policy.withinBudget
                ? `Instacart is ready for your final review${timeRange ? ` for ${timeRange}` : ""}.`
                : `The cart is over budget${timeRange ? ` for ${timeRange}` : ""}, so checkout needs your review.`
          )
        : "Cart, delivery time, and totals are ready to be confirmed.",
      actionUrl: order.browser_live_url ?? order.provider_cart_url ?? null,
      actionLabel: policy.requiresHumanReview ? "Review checkout" : "Open order",
      orderId,
      metadata: {
        provider: order.provider,
        selectedDate: date,
        selectedTimeRange: timeRange,
        approvalRequired: policy.requiresHumanReview,
        autonomy: policy.autonomy,
        withinBudget: policy.withinBudget,
        withinTimeline: policy.withinTimeline,
        targetDeliveryDay: policy.targetDeliveryDay,
        selectedSlotDay: policy.selectedSlotDay,
        estimatedSpendCents: policy.estimatedSpendCents,
        budgetCents: policy.budgetCents,
      },
    }).catch(() => {});

    return {
      ...result,
      autoApproved: false,
      policy,
    };
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
    stepLog: order.step_log ?? [],
    
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
    order_items: Array.isArray(order.items) ? order.items : [],
    
    screenshots: order.screenshots,
    createdAt: order.created_at,
  };
}

/**
 * User approves the order - proceed to checkout.
 */
export async function approveOrder(orderId, { tipCents = 0, approvalMode = "user", policy = null } = {}) {
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

  const normalizedApprovalMode = normalizeText(approvalMode).toLowerCase() === "auto" ? "auto" : "user";
  const approvalStatusMessage = normalizedApprovalMode === "auto"
    ? "Auto-approved within budget"
    : "Approved by user";

  // Update with tip and approval
  await supabase
    .from("grocery_orders")
    .update({
      tip_cents: tipCents,
      ...(normalizedApprovalMode === "user" ? { user_approved_at: new Date().toISOString() } : {}),
    })
    .eq("id", orderId);

  await updateOrderStatus(orderId, "user_approved", {
    status_message: approvalStatusMessage,
  }, {
    approvalMode: normalizedApprovalMode,
    policy,
  });

  // Prepare checkout
  await updateOrderStatus(orderId, "checkout_started", {
    status_message: normalizedApprovalMode === "auto"
      ? "Auto-advancing to checkout..."
      : "Navigating to checkout...",
  }, {
    approvalMode: normalizedApprovalMode,
    policy,
  });

  try {
    if (!order.browser_session_id) {
      const { data: providerAccount } = await supabase
        .from("user_provider_accounts")
        .select("browser_profile_id, login_status")
        .eq("id", order.provider_account_id)
        .maybeSingle();

      const fallbackCheckoutUrl = normalizeText(order.provider_checkout_url) || normalizeText(order.provider_cart_url);
      if (!fallbackCheckoutUrl && order.provider !== "instacart") {
        throw new Error("No Instacart checkout URL available for this order");
      }

      if (order.provider === "instacart" && providerAccount?.browser_profile_id) {
        try {
          const checkoutSession = await browserAgent.createSession({
            provider: "instacart",
            profileId: providerAccount.browser_profile_id,
          });
          const checkoutResult = await browserAgent.prepareCheckout({
            sessionId: checkoutSession.sessionId,
            provider: "instacart",
            startUrl: fallbackCheckoutUrl || order.browser_live_url || "https://www.instacart.ca/store/cart",
          });

          await supabase
            .from("grocery_orders")
            .update({
              browser_session_id: checkoutSession.sessionId,
              browser_live_url: checkoutSession.liveUrl ?? order.browser_live_url ?? null,
              subtotal_cents: Math.round((checkoutResult.subtotal ?? 0) * 100),
              delivery_fee_cents: Math.round((checkoutResult.deliveryFee ?? 0) * 100),
              service_fee_cents: Math.round((checkoutResult.serviceFee ?? 0) * 100),
              tax_cents: Math.round((checkoutResult.tax ?? 0) * 100),
              total_cents: Math.round((checkoutResult.total ?? 0) * 100),
              provider_checkout_url: checkoutResult.checkoutUrl,
            })
            .eq("id", orderId);

          await emitOrderNotification(orderId, {
            kind: "grocery_order_confirmed",
            dedupeKey: `grocery-checkout-started-${order.user_id}-${orderId}-${normalizedApprovalMode}`,
            title: normalizedApprovalMode === "auto"
              ? "Groceries are confirmed"
              : "Checkout is ready",
            body: normalizedApprovalMode === "auto"
              ? "Ounje moved the Instacart cart to checkout and kept the process in one order workflow."
              : "Instacart has the final totals ready. Complete the provider checkout to place the order.",
            actionUrl: checkoutResult.checkoutUrl ?? checkoutSession.liveUrl ?? fallbackCheckoutUrl ?? null,
            actionLabel: "Open checkout",
            orderId,
            metadata: {
              provider: order.provider,
              approvalMode: normalizedApprovalMode,
              budgetCents: policy?.budgetCents ?? null,
              estimatedSpendCents: policy?.estimatedSpendCents ?? null,
              withinBudget: policy?.withinBudget ?? null,
            },
          }).catch(() => {});

          return {
            checkoutUrl: checkoutResult.checkoutUrl,
            liveUrl: checkoutSession.liveUrl ?? order.browser_live_url ?? null,
            total: checkoutResult.total,
            readyToSubmit: checkoutResult.readyToSubmit,
            approvalMode: normalizedApprovalMode,
          };
        } catch (fallbackError) {
          console.warn?.(`[grocery-orchestrator] browser-use Instacart checkout fallback failed: ${fallbackError.message}`);
        }
      }

      if (!fallbackCheckoutUrl) {
        throw new Error("No Instacart checkout URL available for this order");
      }

      await supabase
        .from("grocery_orders")
        .update({
          provider_checkout_url: fallbackCheckoutUrl,
        })
        .eq("id", orderId);

      await emitOrderNotification(orderId, {
        kind: "grocery_order_confirmed",
        dedupeKey: `grocery-checkout-started-${order.user_id}-${orderId}-${normalizedApprovalMode}`,
        title: normalizedApprovalMode === "auto"
          ? "Groceries are confirmed"
          : "Checkout is ready",
        body: normalizedApprovalMode === "auto"
          ? "Ounje moved the Instacart cart to checkout and kept the process in one order workflow."
          : "Instacart checkout is ready. Open the cart to finish placing the order.",
        actionUrl: fallbackCheckoutUrl,
        actionLabel: "Open checkout",
        orderId,
        metadata: {
          provider: order.provider,
          approvalMode: normalizedApprovalMode,
          budgetCents: policy?.budgetCents ?? null,
          estimatedSpendCents: policy?.estimatedSpendCents ?? null,
          withinBudget: policy?.withinBudget ?? null,
          externalCheckout: true,
        },
      }).catch(() => {});

      return {
        checkoutUrl: fallbackCheckoutUrl,
        liveUrl: order.browser_live_url ?? fallbackCheckoutUrl,
        total: (order.total_cents ?? order.subtotal_cents ?? 0) / 100,
        readyToSubmit: false,
        approvalMode: normalizedApprovalMode,
      };
    }

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
    await emitOrderNotification(orderId, {
      kind: "grocery_order_confirmed",
      dedupeKey: `grocery-checkout-started-${order.user_id}-${orderId}-${normalizedApprovalMode}`,
      title: normalizedApprovalMode === "auto"
        ? "Groceries are confirmed"
        : "Checkout is ready",
      body: normalizedApprovalMode === "auto"
        ? "Ounje kept the cart within budget and moved it to provider checkout."
        : "Instacart has the final totals ready. Complete the provider checkout to place the order.",
      actionUrl: checkoutResult.checkoutUrl ?? order.browser_live_url ?? null,
      actionLabel: "Open checkout",
      orderId,
      metadata: {
        provider: order.provider,
        total: checkoutResult.total ?? null,
        approvalMode: normalizedApprovalMode,
        budgetCents: policy?.budgetCents ?? null,
        estimatedSpendCents: policy?.estimatedSpendCents ?? null,
        withinBudget: policy?.withinBudget ?? null,
      },
    }).catch(() => {});

    return {
      checkoutUrl: checkoutResult.checkoutUrl,
      liveUrl: order.browser_live_url,
      total: checkoutResult.total,
      readyToSubmit: checkoutResult.readyToSubmit,
      approvalMode: normalizedApprovalMode,
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
    .select("*")
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

  await emitOrderNotification(orderId, {
    kind: "grocery_order_confirmed",
    dedupeKey: `grocery-order-confirmed-${order.user_id}-${orderId}-${normalizeText(providerOrderId) || "submitted"}`,
    title: "Groceries are confirmed",
    body: "Instacart accepted the order and delivery tracking can start now.",
    actionUrl: order.provider_checkout_url ?? order.provider_cart_url ?? null,
    actionLabel: "Open Instacart",
    orderId,
    metadata: {
      provider: order.provider,
      providerOrderId: normalizeText(providerOrderId) || null,
    },
  }).catch(() => {});

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

  const { data: cancelledOrder } = await supabase
    .from("grocery_orders")
    .select("user_id, provider")
    .eq("id", orderId)
    .maybeSingle();

  if (cancelledOrder?.user_id) {
    await emitOrderNotification(orderId, {
      kind: "grocery_issue",
      dedupeKey: `grocery-cancelled-${cancelledOrder.user_id}-${orderId}`,
      title: "Instacart order cancelled",
      body: reason ?? "This grocery order was cancelled before checkout completed.",
      orderId,
      metadata: {
        provider: cancelledOrder.provider,
        cancelled: true,
      },
    }).catch(() => {});
  }

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

function isCompleteDeliveryAddress(address) {
  return Boolean(
    address?.line1?.trim() &&
    address?.city?.trim() &&
    address?.region?.trim() &&
    address?.postalCode?.trim()
  );
}

async function updateOrderStatus(orderId, newStatus, extraFields = {}, stepLogExtra = {}) {
  const supabase = getSupabase();

  const { data: order } = await supabase
    .from("grocery_orders")
    .select("status,user_id,step_log")
    .eq("id", orderId)
    .single();

  if (order) {
    const validNext = VALID_TRANSITIONS[order.status] ?? [];
    if (!validNext.includes(newStatus)) {
      throw new Error(`Invalid transition: ${order.status} → ${newStatus}`);
    }
  }

  const fallbackTrackingCopy = (() => {
    switch (newStatus) {
      case "session_started":
        return {
          title: "Starting shopping session",
          body: "We opened the shopping session and are getting the cart ready.",
        };
      case "building_cart":
        return {
          title: "Building your cart",
          body: "We’re matching products and filling the cart now.",
        };
      case "cart_ready":
        return {
          title: "Cart is lined up",
          body: "The cart is ready for delivery timing and checkout review.",
        };
      case "selecting_slot":
        return {
          title: "Checking delivery times",
          body: "We’re looking for a delivery time that fits the prep schedule.",
        };
      case "awaiting_review":
        return {
          title: "Checkout review ready",
          body: "The cart, delivery time, and totals are ready for review.",
        };
      case "user_approved":
        return {
          title: "Checkout approved",
          body: "The order is approved and moving to Instacart checkout.",
        };
      case "checkout_started":
        return {
          title: "Opening Instacart checkout",
          body: "We’re moving the cart into the provider checkout flow.",
        };
      case "completed":
        return {
          title: "Order placed",
          body: "Instacart accepted the order and delivery tracking can begin.",
        };
      case "failed":
        return {
          title: "Shopping paused",
          body: normalizeText(extraFields.status_message) || "The shopping flow hit a snag and needs another pass.",
        };
      case "cancelled":
        return {
          title: "Order cancelled",
          body: normalizeText(extraFields.status_message) || "This shopping flow was cancelled.",
        };
      default:
        return {
          title: normalizeText(extraFields.status_message ?? newStatus.replace(/_/g, " ")) || "Order update",
          body: normalizeText(extraFields.status_message ?? `Order status changed to ${newStatus}.`) || "A grocery order update was recorded.",
        };
    }
  })();

  const stepLogEntry = {
    status: newStatus,
    kind: newStatus,
    title: normalizeText(stepLogExtra.title ?? fallbackTrackingCopy.title) || "Order update",
    body: normalizeText(stepLogExtra.body ?? fallbackTrackingCopy.body) || "A grocery order update was recorded.",
    metadata: stepLogExtra.metadata && typeof stepLogExtra.metadata === "object" ? stepLogExtra.metadata : {},
    at: new Date().toISOString(),
    ...extraFields,
    ...stepLogExtra,
  };

  const existingStepLog = Array.isArray(order?.step_log) ? order.step_log : [];
  const { error } = await supabase
    .from("grocery_orders")
    .update({
      status: newStatus,
      tracking_title: stepLogEntry.title,
      tracking_detail: stepLogEntry.body,
      last_tracked_at: stepLogEntry.at,
      ...extraFields,
      step_log: [...existingStepLog, stepLogEntry],
    })
    .eq("id", orderId);

  if (error) throw error;
  invalidateUserBootstrapCache(order?.user_id);
}

async function failOrder(orderId, errorMessage) {
  const supabase = getSupabase();

  const { data: order } = await supabase
    .from("grocery_orders")
    .select("user_id, provider, provider_cart_url, provider_checkout_url")
    .eq("id", orderId)
    .maybeSingle();

  await supabase
    .from("grocery_orders")
    .update({
      status: "failed",
      error_message: errorMessage,
      status_message: `Failed: ${errorMessage}`,
      tracking_title: "Shopping paused",
      tracking_detail: normalizeText(errorMessage) || "The shopping flow hit a snag and needs another pass.",
      last_tracked_at: new Date().toISOString(),
    })
    .eq("id", orderId);

  if (order?.user_id) {
    invalidateUserBootstrapCache(order.user_id);
    const friendlyBody = (() => {
      const text = normalizeText(errorMessage).toLowerCase();
      if (text.includes("invalid transition")) {
        return "The shopping flow got out of sync and needs another pass.";
      }
      if (text.includes("supabase.sql is not a function")) {
        return "The shopping flow hit a database sync issue and will retry.";
      }
      if (text.includes("session timed out") || text.includes("invalid jwt")) {
        return "The shopping session expired and needs a fresh sign-in.";
      }
      return "The shopping flow hit a snag and needs another pass.";
    })();

    await emitOrderNotification(orderId, {
      kind: "autoshop_failed",
      dedupeKey: `grocery-failed-${order.user_id}-${orderId}-${normalizeText(errorMessage).toLowerCase()}`,
      title: "Shopping paused",
      body: friendlyBody,
      actionUrl: order.provider_checkout_url ?? order.provider_cart_url ?? "ounje://cart",
      actionLabel: "Open order",
      orderId,
      metadata: {
        provider: order.provider,
        failed: true,
      },
    }).catch(() => {});
  }
}

async function emitOrderNotification(orderId, payload) {
  const supabase = getSupabase();
  const { data: order, error } = await supabase
    .from("grocery_orders")
    .select("id,user_id")
    .eq("id", orderId)
    .single();

  if (error || !order?.user_id) {
    return null;
  }

  return await createNotificationEvent({
    userId: order.user_id,
    orderId,
    ...payload,
  });
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
