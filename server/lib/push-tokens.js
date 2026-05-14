// Device-token registry helpers.
//
// All writes go through the service-role Supabase client because the
// `device_tokens` table is locked down with USING (false) for clients — we
// don't want a stolen access token to be able to register or hijack another
// user's device.

import { createClient } from "@supabase/supabase-js";
import { sendApnsNotification } from "./apns-sender.js";

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

function getSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Supabase service role configuration is missing");
  }
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

function normalize(value) {
  return String(value ?? "").trim();
}

/** Upserts a device token for a user. Returns the inserted/updated row. */
export async function registerDeviceToken({
  userId,
  token,
  environment = "production",
  platform = "ios",
  appVersion = null,
  deviceModel = null,
  osVersion = null,
}) {
  const normalizedUserId = normalize(userId);
  const normalizedToken = normalize(token);
  if (!normalizedUserId || !normalizedToken) {
    throw new Error("registerDeviceToken requires userId and token");
  }
  // If someone else has the same token registered (e.g. a previous account
  // on the same device), drop those rows so the token is now owned by the
  // current user only. Apple recycles tokens between accounts on the same
  // device after sign-out.
  const supabase = getSupabase();
  await supabase
    .from("device_tokens")
    .delete()
    .neq("user_id", normalizedUserId)
    .eq("token", normalizedToken);

  const { data, error } = await supabase
    .from("device_tokens")
    .upsert({
      user_id: normalizedUserId,
      token: normalizedToken,
      environment: ["sandbox", "production"].includes(environment) ? environment : "production",
      platform: ["ios", "ipad", "macos"].includes(platform) ? platform : "ios",
      app_version: normalize(appVersion) || null,
      device_model: normalize(deviceModel) || null,
      os_version: normalize(osVersion) || null,
      last_seen_at: new Date().toISOString(),
    }, { onConflict: "user_id,token" })
    .select("*")
    .single();

  if (error) throw error;
  return data;
}

export async function unregisterDeviceToken({ userId, token }) {
  const normalizedUserId = normalize(userId);
  const normalizedToken = normalize(token);
  if (!normalizedUserId || !normalizedToken) return null;

  const supabase = getSupabase();
  const { error } = await supabase
    .from("device_tokens")
    .delete()
    .eq("user_id", normalizedUserId)
    .eq("token", normalizedToken);
  if (error) throw error;
  return { deleted: true };
}

/**
 * Fans out an APNs push to every registered device of the given user.
 * Returns an array of per-token results; never throws so callers can use it
 * inside a fire-and-forget Promise.all alongside other notification work.
 */
export async function pushToUser({
  userId,
  title,
  body,
  subtitle,
  category = null,
  threadId = null,
  userInfo = {},
}) {
  const normalizedUserId = normalize(userId);
  if (!normalizedUserId) return [];

  let tokens = [];
  try {
    const supabase = getSupabase();
    const { data, error } = await supabase
      .from("device_tokens")
      .select("token, environment")
      .eq("user_id", normalizedUserId);
    if (error) throw error;
    tokens = data ?? [];
  } catch (cause) {
    console.warn("[push] failed to fetch device tokens:", cause.message);
    return [];
  }

  if (tokens.length === 0) return [];

  const results = await Promise.all(
    tokens.map(async (row) => {
      const result = await sendApnsNotification({
        token: row.token,
        environment: row.environment,
        title,
        body,
        subtitle,
        category,
        threadId,
        userInfo,
      });
      // APNs returns "BadDeviceToken" / "Unregistered" / "DeviceTokenNotForTopic"
      // when a token is no longer valid (user uninstalled, re-installed, etc.).
      // Prune those rows so we don't keep retrying.
      const fatal = ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"];
      if (!result.ok && fatal.includes(result.reason)) {
        try {
          const supabase = getSupabase();
          await supabase
            .from("device_tokens")
            .delete()
            .eq("user_id", normalizedUserId)
            .eq("token", row.token);
        } catch (_) { /* swallow */ }
      }
      return { token: row.token, ...result };
    })
  );
  return results;
}
