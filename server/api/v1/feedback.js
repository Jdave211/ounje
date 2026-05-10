import express from "express";
import { createClient } from "@supabase/supabase-js";
import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";

const router = express.Router();

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const FEEDBACK_SHADOW_KIND = "recipe_nudge";

function getSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Feedback API requires Supabase service role configuration");
  }

  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

function normalizeAttachments(value) {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => {
      const fileName = String(item?.file_name ?? item?.fileName ?? "").trim();
      const mimeType = String(item?.mime_type ?? item?.mimeType ?? "").trim();
      const kind = String(item?.kind ?? "").trim();
      if (!fileName && !mimeType && !kind) return null;
      return {
        file_name: fileName,
        mime_type: mimeType,
        kind: kind || "image",
      };
    })
    .filter(Boolean)
    .slice(0, 4);
}

function isMissingFeedbackTableError(error) {
  const message = String(error?.message ?? error ?? "").toLowerCase();
  return message.includes("app_feedback_messages")
    && (message.includes("schema cache") || message.includes("does not exist"));
}

function isLegacyAutomatedFeedbackMessage(row = {}) {
  const authorRole = String(row.author_role ?? "").trim().toLowerCase();
  if (authorRole !== "system") return false;
  const normalizedBody = String(row.body ?? "")
    .trim()
    .toLowerCase()
    .replace(/[’']/g, "'")
    .replace(/\s+/g, " ");
  return normalizedBody === "thank you for the feedback. we really appreciate it."
    || normalizedBody.includes("keep you posted");
}

function toFeedbackMessageRow(row = {}) {
  const metadata = row?.metadata && typeof row.metadata === "object" ? row.metadata : {};
  const attachments = Array.isArray(row?.attachments)
    ? row.attachments
    : Array.isArray(metadata?.attachments)
      ? metadata.attachments
      : [];

  return {
    id: row.id,
    user_id: row.user_id,
    author_role: String(row.author_role ?? metadata.author_role ?? "system").trim() || "system",
    body: String(row.body ?? "").trim(),
    attachments,
    created_at: row.created_at ?? row.scheduled_for ?? new Date().toISOString(),
  };
}

async function listFeedbackShadowMessages(supabase, userID) {
  const { data, error } = await supabase
    .from("app_notification_events")
    .select("id,user_id,body,metadata,created_at,scheduled_for")
    .eq("user_id", userID)
    .contains("metadata", { feedback_thread: true })
    .order("created_at", { ascending: true })
    .limit(200);

  if (error) throw error;
  return (data ?? [])
    .map((row) => toFeedbackMessageRow(row))
    .filter((row) => !isLegacyAutomatedFeedbackMessage(row));
}

async function insertFeedbackShadowMessages(supabase, userID, rows) {
  const now = new Date().toISOString();
  const payload = rows.map((row, index) => ({
    user_id: userID,
    kind: FEEDBACK_SHADOW_KIND,
    dedupe_key: `feedback:${userID}:${Date.now()}:${index}:${crypto.randomUUID()}`,
    title: row.author_role === "user" ? "Feedback sent" : "Feedback reply",
    body: row.body,
    metadata: {
      feedback_thread: true,
      author_role: row.author_role,
      attachments: row.attachments ?? [],
      channel: "feedback",
      hidden_from_notifications: true,
    },
    scheduled_for: now,
    delivered_at: now,
    seen_at: now,
  }));

  const { data, error } = await supabase
    .from("app_notification_events")
    .insert(payload)
    .select("id,user_id,body,metadata,created_at,scheduled_for");

  if (error) throw error;
  return (data ?? []).map((row) => toFeedbackMessageRow(row));
}

router.get("/feedback", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);

    const supabase = getSupabase();
    const { data, error } = await supabase
      .from("app_feedback_messages")
      .select("*")
      .eq("user_id", userID)
      .order("created_at", { ascending: true })
      .limit(200);

    if (error) {
      if (!isMissingFeedbackTableError(error)) throw error;
      const fallbackItems = await listFeedbackShadowMessages(supabase, userID);
      return res.json({ items: fallbackItems, storage: "notification_shadow" });
    }

    return res.json({
      items: (data ?? []).filter((row) => !isLegacyAutomatedFeedbackMessage(row)),
      storage: "feedback_table",
    });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "feedback/list");
    }
    console.error("[feedback/list] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

router.post("/feedback", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);

    const body = String(req.body?.body ?? "").trim();
    const attachments = normalizeAttachments(req.body?.attachments);
    if (!body && attachments.length === 0) {
      return res.status(400).json({ error: "Feedback body or attachment required" });
    }

    const userMessage = {
      user_id: userID,
      author_role: "user",
      body,
      attachments,
      metadata: {
        attachment_count: attachments.length,
      },
    };

    const supabase = getSupabase();
    const { data, error } = await supabase
      .from("app_feedback_messages")
      .insert([userMessage])
      .select("*");

    if (error) {
      if (!isMissingFeedbackTableError(error)) throw error;
      const fallbackItems = await insertFeedbackShadowMessages(supabase, userID, [userMessage]);
      return res.status(201).json({
        items: fallbackItems,
        storage: "notification_shadow",
      });
    }

    return res.status(201).json({
      items: data ?? [],
      storage: "feedback_table",
    });
  } catch (error) {
    if (error?.statusCode === 401 || error?.statusCode === 403) {
      return sendAuthError(res, error, "feedback/create");
    }
    console.error("[feedback/create] error:", error.message);
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

export default router;
