// Device-token registry helpers.
//
// All writes go through the service-role Supabase client because the
// `device_tokens` table is locked down with USING (false) for clients — we
// don't want a stolen access token to be able to register or hijack another
// user's device.

import { sendApnsNotification } from "./apns-sender.js";
import { getServiceRoleSupabase } from "./supabase-clients.js";

function getSupabase() {
  return getServiceRoleSupabase();
}

function normalize(value) {
  return String(value ?? "").trim();
}

function normalizedPushEnvironment(value) {
  return ["sandbox", "production"].includes(value) ? value : "production";
}

function alternatePushEnvironment(value) {
  return normalizedPushEnvironment(value) === "sandbox" ? "production" : "sandbox";
}

function isApnsEnvironmentMismatch(reason) {
  return [
    "BadDeviceToken",
    "BadCertificateEnvironment",
    "BadEnvironmentKeyInToken",
    "DeviceTokenNotForTopic",
  ].includes(normalize(reason));
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
      environment: normalizedPushEnvironment(environment),
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
  limitLatest = false,
}) {
  const normalizedUserId = normalize(userId);
  if (!normalizedUserId) return [];

  let tokens = [];
  try {
    const supabase = getSupabase();
    let query = supabase
      .from("device_tokens")
      .select("token, environment, platform, last_seen_at")
      .eq("user_id", normalizedUserId)
      .order("last_seen_at", { ascending: false });
    if (limitLatest) {
      query = query.limit(1);
    }
    const { data, error } = await query;
    if (error) throw error;
    tokens = data ?? [];
  } catch (cause) {
    console.warn("[push] failed to fetch device tokens:", cause.message);
    return [];
  }

  if (tokens.length === 0) return [];

  const maskToken = (token) => `${String(token).slice(0, 8)}...${String(token).slice(-6)}`;
  const notificationKind = normalize(userInfo?.kind) || "unknown";
  const results = await Promise.all(
    tokens.map(async (row) => {
      const firstEnvironment = normalizedPushEnvironment(row.environment);
      let result = await sendApnsNotification({
        token: row.token,
        environment: firstEnvironment,
        title,
        body,
        subtitle,
        category,
        threadId,
        userInfo,
      });
      let finalEnvironment = firstEnvironment;
      if (!result.ok && isApnsEnvironmentMismatch(result.reason)) {
        const retryEnvironment = alternatePushEnvironment(firstEnvironment);
        const retryResult = await sendApnsNotification({
          token: row.token,
          environment: retryEnvironment,
          title,
          body,
          subtitle,
          category,
          threadId,
          userInfo,
        });
        if (retryResult.ok) {
          finalEnvironment = retryEnvironment;
          result = {
            ...retryResult,
            retried_environment: retryEnvironment,
            original_environment: firstEnvironment,
            original_reason: result.reason ?? null,
          };
          try {
            const supabase = getSupabase();
            await supabase
              .from("device_tokens")
              .update({
                environment: retryEnvironment,
                last_seen_at: new Date().toISOString(),
              })
              .eq("user_id", normalizedUserId)
              .eq("token", row.token);
          } catch (cause) {
            console.warn("[push] failed to repair APNs token environment:", cause.message);
          }
        } else {
          result = {
            ...retryResult,
            retried_environment: retryEnvironment,
            original_environment: firstEnvironment,
            original_reason: result.reason ?? null,
          };
        }
      }
      console.info("[push] APNs attempt", {
        userId: normalizedUserId,
        kind: notificationKind,
        environment: finalEnvironment,
        platform: row.platform,
        topic: result.topic,
        ok: result.ok,
        status: result.status ?? null,
        reason: result.reason ?? null,
        originalReason: result.original_reason ?? null,
        retriedEnvironment: result.retried_environment ?? null,
        token: maskToken(row.token),
        lastSeenAt: row.last_seen_at ?? null,
      });
      // Only "Unregistered" proves the device token is stale. BadDeviceToken
      // and DeviceTokenNotForTopic can also mean we pointed at the wrong APNs
      // environment or topic, so keep them for diagnostics instead of deleting
      // a potentially valid phone token.
      const fatal = ["Unregistered"];
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
      return { token: maskToken(row.token), ...result };
    })
  );
  return results;
}

export async function pushTestNotificationToLatestDevice({ userId }) {
  return pushToUser({
    userId,
    title: "Ounje test notification",
    body: "If this appears, APNs is wired correctly.",
    userInfo: {
      kind: "apns_test",
      deep_link: "ounje://notifications",
      action_url: "ounje://notifications",
    },
    limitLatest: true,
  });
}
