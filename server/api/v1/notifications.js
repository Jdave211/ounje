import express from "express";

import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";
import { createNotificationEvent } from "../../lib/notification-events.js";
import { readRedisJSON, writeRedisJSON, deleteRedisKey } from "../../lib/redis-cache.js";
import { getServiceRoleSupabase } from "../../lib/supabase-clients.js";
import { userScopedCacheKey } from "../../lib/user-bootstrap-cache.js";

const router = express.Router();

// Short TTL: cuts read load during foreground sync bursts; stale data is OK
// for at most this many seconds.
const NOTIFICATION_LIST_CACHE_TTL_SECONDS = 12;
const DEFAULT_NOTIFICATION_RECENT_LIMIT = 60;
const DEFAULT_NOTIFICATION_PENDING_LIMIT = 40;

function getSupabase() {
  return getServiceRoleSupabase();
}

function resolveLimit(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return Math.min(parsed, 100);
}

function resolveEventIDs(value) {
  if (!Array.isArray(value)) return [];
  return value.map((item) => String(item ?? "").trim()).filter(Boolean);
}

function shouldHideNotificationEvent(event) {
  const metadata = event?.metadata && typeof event.metadata === "object" ? event.metadata : null;
  const hiddenValue = String(metadata?.hidden_from_notifications ?? "").trim().toLowerCase();
  return hiddenValue === "true";
}

function invalidateNotificationListCaches(userID) {
  const recentKey = userScopedCacheKey("notifications-recent-default", userID);
  const pendingKey = userScopedCacheKey("notifications-pending-default", userID);
  if (recentKey) void deleteRedisKey(recentKey);
  if (pendingKey) void deleteRedisKey(pendingKey);
}

router.get("/notifications/recent", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);

    const supabase = getSupabase();
    const limit = resolveLimit(req.query.limit, 60);
    const cacheKey = limit === DEFAULT_NOTIFICATION_RECENT_LIMIT
      ? userScopedCacheKey("notifications-recent-default", userID)
      : null;
    if (cacheKey) {
      const cached = await readRedisJSON(cacheKey);
      if (cached) {
        return res.json(cached);
      }
    }

    const { data, error } = await supabase
      .from("app_notification_events")
      .select("*")
      .eq("user_id", userID)
      .order("created_at", { ascending: false })
      .order("scheduled_for", { ascending: false })
      .limit(limit);

    if (error) {
      throw error;
    }

    const payload = { items: (data ?? []).filter((event) => !shouldHideNotificationEvent(event)) };
    if (cacheKey) {
      void writeRedisJSON(cacheKey, payload, NOTIFICATION_LIST_CACHE_TTL_SECONDS);
    }
    return res.json(payload);
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "notifications/recent");
    }
    console.error("[notifications/recent] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.get("/notifications/pending", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);

    const supabase = getSupabase();
    const limit = resolveLimit(req.query.limit, 40);
    const cacheKey = limit === DEFAULT_NOTIFICATION_PENDING_LIMIT
      ? userScopedCacheKey("notifications-pending-default", userID)
      : null;
    if (cacheKey) {
      const cached = await readRedisJSON(cacheKey);
      if (cached) {
        return res.json(cached);
      }
    }

    const { data, error } = await supabase
      .from("app_notification_events")
      .select("*")
      .eq("user_id", userID)
      .is("delivered_at", null)
      .order("scheduled_for", { ascending: true })
      .limit(limit);

    if (error) {
      throw error;
    }

    const payload = { items: (data ?? []).filter((event) => !shouldHideNotificationEvent(event)) };
    if (cacheKey) {
      void writeRedisJSON(cacheKey, payload, NOTIFICATION_LIST_CACHE_TTL_SECONDS);
    }
    return res.json(payload);
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "notifications/pending");
    }
    console.error("[notifications/pending] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.post("/notifications", async (req, res) => {
  try {
    const payload = req.body?.event && typeof req.body.event === "object" ? req.body.event : req.body ?? {};
    const { userID } = await resolveAuthorizedUserID(req);
    const created = await createNotificationEvent({
      userId: userID,
      kind: payload.kind,
      dedupeKey: payload.dedupe_key ?? payload.dedupeKey,
      title: payload.title,
      body: payload.body,
      subtitle: payload.subtitle ?? null,
      imageUrl: payload.image_url ?? payload.imageURLString ?? null,
      actionUrl: payload.action_url ?? payload.actionURLString ?? null,
      actionLabel: payload.action_label ?? payload.actionLabel ?? null,
      orderId: payload.order_id ?? payload.orderID ?? null,
      planId: payload.plan_id ?? payload.planID ?? null,
      recipeId: payload.recipe_id ?? payload.recipeID ?? null,
      metadata: payload.metadata ?? {},
      scheduledFor: payload.scheduled_for ?? payload.scheduledFor ?? null,
    });

    invalidateNotificationListCaches(userID);
    return res.status(201).json(created);
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "notifications/create");
    }
    console.error("[notifications/create] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.post("/notifications/mark-delivered", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const eventIDs = resolveEventIDs(req.body?.event_ids ?? req.body?.eventIDs);
    if (!eventIDs.length) {
      return res.status(400).json({ error: "event_ids array required" });
    }

    const supabase = getSupabase();
    const now = new Date().toISOString();
    const { data, error } = await supabase
      .from("app_notification_events")
      .update({ delivered_at: now })
      .eq("user_id", userID)
      .in("id", eventIDs)
      .select("id");

    if (error) {
      throw error;
    }

    invalidateNotificationListCaches(userID);
    return res.json({ ok: true, updated: data?.length ?? 0 });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "notifications/mark-delivered");
    }
    console.error("[notifications/mark-delivered] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.post("/notifications/mark-seen", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const eventIDs = resolveEventIDs(req.body?.event_ids ?? req.body?.eventIDs);
    if (!eventIDs.length) {
      return res.status(400).json({ error: "event_ids array required" });
    }

    const supabase = getSupabase();
    const now = new Date().toISOString();
    const { data, error } = await supabase
      .from("app_notification_events")
      .update({ seen_at: now })
      .eq("user_id", userID)
      .in("id", eventIDs)
      .select("id");

    if (error) {
      throw error;
    }

    invalidateNotificationListCaches(userID);
    return res.json({ ok: true, updated: data?.length ?? 0 });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "notifications/mark-seen");
    }
    console.error("[notifications/mark-seen] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

export default router;
