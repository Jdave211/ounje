import express from "express";
import crypto from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";

const router = express.Router();

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const FEEDBACK_SHADOW_KIND = "recipe_nudge";
const FEEDBACK_ATTACHMENTS_BUCKET = "feedback-attachments";
// Signed URLs live for 1 hour. The client opens the feedback sheet, fetches
// the thread, and renders attachments inline; an hour is plenty for the
// average session and short enough that a leaked URL has limited blast radius.
const ATTACHMENT_SIGNED_URL_TTL_SECONDS = 60 * 60;

function getSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Feedback API requires Supabase service role configuration");
  }

  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

// Generates signed read URLs for every attachment with a storage_path. We use
// service-role credentials here so the response is the same shape regardless
// of the calling user's RLS context. The signed URL is scoped to the bucket +
// path, so users only ever receive URLs for their own files (the row was
// loaded under their user_id filter).
async function signAttachmentUrls(supabase, attachments) {
  if (!Array.isArray(attachments) || attachments.length === 0) return [];

  const normalizedAttachments = attachments
    .filter((attachment) => attachment && typeof attachment === "object");
  const pathByIndex = normalizedAttachments.map((attachment) => String(attachment.storage_path ?? attachment.storagePath ?? "").trim());
  const paths = [];
  const batchIndexByAttachmentIndex = new Map();
  pathByIndex.forEach((path, attachmentIndex) => {
    if (!path) return;
    batchIndexByAttachmentIndex.set(attachmentIndex, paths.length);
    paths.push(path);
  });
  const bucket = supabase.storage.from(FEEDBACK_ATTACHMENTS_BUCKET);
  if (paths.length > 0 && typeof bucket.createSignedUrls === "function") {
    try {
      const { data, error } = await bucket.createSignedUrls(paths, ATTACHMENT_SIGNED_URL_TTL_SECONDS);
      if (error) throw error;

      const signedURLByPath = new Map();
      const signedURLByIndex = new Map();
      for (const [index, item] of (data ?? []).entries()) {
        const path = String(item?.path ?? item?.name ?? paths[index] ?? "").trim();
        const signedURL = item?.signedUrl ?? item?.signedURL ?? item?.signed_url ?? null;
        if (path && signedURL) signedURLByPath.set(path, signedURL);
        if (signedURL) signedURLByIndex.set(index, signedURL);
      }

      return normalizedAttachments.map((attachment, index) => {
        const path = pathByIndex[index];
        const signedURL = path && signedURLByPath.has(path)
          ? signedURLByPath.get(path)
          : signedURLByIndex.get(batchIndexByAttachmentIndex.get(index));
        return signedURL
          ? { ...attachment, signed_url: signedURL }
          : attachment;
      });
    } catch (cause) {
      console.warn("[feedback] batch signed attachment URLs failed:", cause.message);
    }
  }

  const result = [];
  for (const attachment of normalizedAttachments) {
    const path = attachment.storage_path ?? attachment.storagePath;
    if (!path) {
      result.push(attachment);
      continue;
    }
    try {
      const { data, error } = await supabase.storage
        .from(FEEDBACK_ATTACHMENTS_BUCKET)
        .createSignedUrl(path, ATTACHMENT_SIGNED_URL_TTL_SECONDS);
      if (error) throw error;
      result.push({
        ...attachment,
        signed_url: data?.signedUrl ?? null,
      });
    } catch (cause) {
      console.warn("[feedback] failed to sign attachment URL:", cause.message);
      result.push(attachment);
    }
  }
  return result;
}

async function hydrateMessageAttachments(supabase, messages) {
  if (!Array.isArray(messages)) return [];
  const hydrated = await Promise.all(
    messages.map(async (message) => {
      const attachments = await signAttachmentUrls(supabase, message?.attachments ?? []);
      return { ...message, attachments };
    })
  );
  return hydrated;
}

// Attachments now carry a storage_path that points at an object inside the
// `feedback-attachments` private bucket. We preserve fileName/mimeType/kind so
// the client can render a placeholder while the signed URL resolves.
function normalizeAttachments(value) {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => {
      const fileName = String(item?.file_name ?? item?.fileName ?? "").trim();
      const mimeType = String(item?.mime_type ?? item?.mimeType ?? "").trim();
      const kind = String(item?.kind ?? "").trim();
      const storagePath = String(item?.storage_path ?? item?.storagePath ?? "").trim();
      const width = Number.isFinite(Number(item?.width)) ? Number(item.width) : null;
      const height = Number.isFinite(Number(item?.height)) ? Number(item.height) : null;
      const sizeBytes = Number.isFinite(Number(item?.size_bytes ?? item?.sizeBytes))
        ? Number(item.size_bytes ?? item.sizeBytes)
        : null;
      if (!fileName && !mimeType && !kind && !storagePath) return null;
      const normalized = {
        file_name: fileName,
        mime_type: mimeType,
        kind: kind || (mimeType.startsWith("video") ? "video" : "image"),
      };
      if (storagePath) normalized.storage_path = storagePath;
      if (width !== null) normalized.width = width;
      if (height !== null) normalized.height = height;
      if (sizeBytes !== null) normalized.size_bytes = sizeBytes;
      return normalized;
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
      const hydratedFallback = await hydrateMessageAttachments(supabase, fallbackItems);
      return res.json({ items: hydratedFallback, storage: "notification_shadow" });
    }

    const filtered = (data ?? []).filter((row) => !isLegacyAutomatedFeedbackMessage(row));
    const hydrated = await hydrateMessageAttachments(supabase, filtered);
    return res.json({
      items: hydrated,
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
      const hydratedFallback = await hydrateMessageAttachments(supabase, fallbackItems);
      return res.status(201).json({
        items: hydratedFallback,
        storage: "notification_shadow",
      });
    }

    const hydrated = await hydrateMessageAttachments(supabase, data ?? []);
    return res.status(201).json({
      items: hydrated,
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
