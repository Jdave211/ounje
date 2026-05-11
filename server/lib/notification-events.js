import { createClient } from "@supabase/supabase-js";
import { broadcastUserInvalidation } from "./realtime-invalidation.js";
import { pushToUser } from "./push-tokens.js";

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

// Kinds we deliver as APNs pushes (in addition to writing to the inbox).
// Stuff like internal feedback thread shadows stays inbox-only so users
// aren't blasted with notifications about their own messages.
const PUSH_DELIVERABLE_KINDS = new Set([
  "meal_prep_ready",
  "cart_review_required",
  "checkout_approval_required",
  "grocery_cart_ready",
  "grocery_cart_partial",
  "grocery_order_confirmed",
  "grocery_delivery_update",
  "grocery_delivery_arrived",
  "grocery_issue",
  "recipe_nudge",
  "trending_recipe_nudge",
  "recipe_import_queued",
  "recipe_import_completed",
  "recipe_import_failed",
  "autoshop_started",
  "autoshop_completed",
  "autoshop_failed",
]);

function getSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Supabase notification events are not configured");
  }

  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

function normalizeString(value) {
  return String(value ?? "").trim();
}

export async function createNotificationEvent({
  userId,
  kind,
  dedupeKey,
  title,
  body,
  subtitle = null,
  imageUrl = null,
  actionUrl = null,
  actionLabel = null,
  orderId = null,
  planId = null,
  recipeId = null,
  metadata = {},
  scheduledFor = null,
}) {
  const normalizedUserId = normalizeString(userId);
  const normalizedKind = normalizeString(kind);
  const normalizedDedupeKey = normalizeString(dedupeKey);
  const normalizedTitle = normalizeString(title);
  const normalizedBody = normalizeString(body);

  if (!normalizedUserId || !normalizedKind || !normalizedDedupeKey || !normalizedTitle || !normalizedBody) {
    throw new Error("Notification event requires userId, kind, dedupeKey, title, and body");
  }

  const supabase = getSupabase();
  const payload = {
    user_id: normalizedUserId,
    kind: normalizedKind,
    dedupe_key: normalizedDedupeKey,
    title: normalizedTitle,
    body: normalizedBody,
    subtitle: normalizeString(subtitle) || null,
    image_url: normalizeString(imageUrl) || null,
    action_url: normalizeString(actionUrl) || null,
    action_label: normalizeString(actionLabel) || null,
    order_id: normalizeString(orderId) || null,
    plan_id: normalizeString(planId) || null,
    recipe_id: normalizeString(recipeId) || null,
    metadata: metadata && typeof metadata === "object" ? metadata : {},
    scheduled_for: scheduledFor ?? new Date().toISOString(),
  };

  const { data, error } = await supabase
    .from("app_notification_events")
    .upsert(payload, {
      onConflict: "user_id,dedupe_key",
      ignoreDuplicates: false,
    })
    .select("id,user_id,kind,dedupe_key,title,body,scheduled_for,created_at")
    .single();

  if (error) {
    throw error;
  }

  await broadcastUserInvalidation(normalizedUserId, "notification.updated", {
    id: data?.id ?? null,
    kind: data?.kind ?? normalizedKind,
    dedupe_key: data?.dedupe_key ?? normalizedDedupeKey,
  });

  // Fire-and-forget APNs push so the user is notified even when the app is
  // backgrounded or killed. Pushes are intentionally non-blocking: the
  // inbox row + realtime invalidation must succeed regardless.
  if (
    PUSH_DELIVERABLE_KINDS.has(normalizedKind)
    && !metadata?.hidden_from_notifications
  ) {
    pushToUser({
      userId: normalizedUserId,
      title: normalizedTitle,
      body: normalizedBody,
      subtitle: normalizeString(subtitle) || undefined,
      userInfo: {
        event_id: data?.id ?? null,
        kind: data?.kind ?? normalizedKind,
        dedupe_key: data?.dedupe_key ?? normalizedDedupeKey,
        action_url: normalizeString(actionUrl) || null,
      },
    }).catch((cause) => {
      console.warn("[notifications] APNs push failed:", cause.message);
    });
  }

  return data;
}

export async function createNotificationEvents(events = []) {
  const normalizedEvents = Array.isArray(events) ? events : [];
  if (!normalizedEvents.length) return [];

  const results = [];
  for (const event of normalizedEvents) {
    try {
      const created = await createNotificationEvent(event);
      results.push(created);
    } catch (error) {
      results.push({
        error: error.message,
        dedupeKey: event?.dedupeKey ?? null,
      });
    }
  }
  return results;
}

export async function fetchOrderingAutonomy(userId) {
  const normalizedUserId = normalizeString(userId);
  if (!normalizedUserId) return null;

  const guardrails = await fetchOrderingGuardrails(normalizedUserId);
  return guardrails.orderingAutonomy;
}

export async function fetchOrderingGuardrails(userId) {
  const normalizedUserId = normalizeString(userId);
  if (!normalizedUserId) {
    return {
      orderingAutonomy: null,
      budgetPerCycle: null,
      budgetWindow: null,
      pricingTier: null,
      cadence: null,
      deliveryAnchorDay: null,
      deliveryAnchorDate: null,
      deliveryTimeMinutes: null,
    };
  }

  const supabase = getSupabase();
  const { data, error } = await supabase
    .from("profiles")
    .select("ordering_autonomy,budget_per_cycle,budget_window,profile_json")
    .eq("id", normalizedUserId)
    .limit(1)
    .maybeSingle();

  if (error) {
    throw error;
  }

  const profileJSON = data?.profile_json && typeof data.profile_json === "object"
    ? data.profile_json
    : null;

  let entitlementTier = null;
  try {
    const { data: entitlement, error: entitlementError } = await supabase
      .from("app_user_entitlements")
      .select("tier,status")
      .eq("user_id", normalizedUserId)
      .limit(1)
      .maybeSingle();
    if (entitlementError) {
      const code = normalizeString(entitlementError?.code);
      const message = normalizeString(entitlementError?.message ?? entitlementError?.details).toLowerCase();
      const isMissingTable = code === "42P01"
        || (message.includes("app_user_entitlements") && (message.includes("schema cache") || message.includes("does not exist")));
      if (!isMissingTable) {
        throw entitlementError;
      }
    } else if (normalizeString(entitlement?.status).toLowerCase() === "active") {
      entitlementTier = normalizeString(entitlement?.tier) || null;
    }
  } catch (error) {
    throw error;
  }

  return {
    orderingAutonomy: normalizeString(data?.ordering_autonomy) || null,
    budgetPerCycle: Number(data?.budget_per_cycle ?? 0) || null,
    budgetWindow: normalizeString(data?.budget_window) || null,
    pricingTier: entitlementTier ?? (normalizeString(profileJSON?.pricingTier) || null),
    cadence: normalizeString(profileJSON?.cadence) || null,
    deliveryAnchorDay: normalizeString(profileJSON?.deliveryAnchorDay) || null,
    deliveryAnchorDate: normalizeString(profileJSON?.deliveryAnchorDate) || null,
    deliveryTimeMinutes: Number(profileJSON?.deliveryTimeMinutes ?? 0) || null,
  };
}
