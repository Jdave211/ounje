import express from "express";
import { createClient } from "@supabase/supabase-js";

import { createNotificationEvent } from "../../lib/notification-events.js";

const router = express.Router();

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

function getSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Notification proxy requires Supabase service role configuration");
  }

  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

function resolveUserID(req) {
  return String(req.query.user_id ?? req.query.userID ?? req.headers["x-user-id"] ?? "").trim();
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

router.get("/notifications/recent", async (req, res) => {
  try {
    const userID = resolveUserID(req);
    if (!userID) {
      return res.status(401).json({ error: "User ID required" });
    }

    const supabase = getSupabase();
    const limit = resolveLimit(req.query.limit, 60);
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

    return res.json({ items: (data ?? []).filter((event) => !shouldHideNotificationEvent(event)) });
  } catch (error) {
    console.error("[notifications/recent] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.get("/notifications/pending", async (req, res) => {
  try {
    const userID = resolveUserID(req);
    if (!userID) {
      return res.status(401).json({ error: "User ID required" });
    }

    const supabase = getSupabase();
    const limit = resolveLimit(req.query.limit, 40);
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

    return res.json({ items: (data ?? []).filter((event) => !shouldHideNotificationEvent(event)) });
  } catch (error) {
    console.error("[notifications/pending] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.post("/notifications", async (req, res) => {
  try {
    const payload = req.body?.event && typeof req.body.event === "object" ? req.body.event : req.body ?? {};
    const created = await createNotificationEvent({
      userId: payload.user_id ?? payload.userID ?? req.headers["x-user-id"] ?? req.query.user_id ?? req.query.userID,
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

    return res.status(201).json(created);
  } catch (error) {
    console.error("[notifications/create] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.post("/notifications/mark-delivered", async (req, res) => {
  try {
    const userID = resolveUserID(req);
    const eventIDs = resolveEventIDs(req.body?.event_ids ?? req.body?.eventIDs);
    if (!userID) {
      return res.status(401).json({ error: "User ID required" });
    }
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

    return res.json({ ok: true, updated: data?.length ?? 0 });
  } catch (error) {
    console.error("[notifications/mark-delivered] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.post("/notifications/mark-seen", async (req, res) => {
  try {
    const userID = resolveUserID(req);
    const eventIDs = resolveEventIDs(req.body?.event_ids ?? req.body?.eventIDs);
    if (!userID) {
      return res.status(401).json({ error: "User ID required" });
    }
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

    return res.json({ ok: true, updated: data?.length ?? 0 });
  } catch (error) {
    console.error("[notifications/mark-seen] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

export default router;
