import crypto from "node:crypto";
import https from "node:https";
import fs from "node:fs/promises";
import path from "node:path";

import {
  Environment,
  NotificationTypeV2,
  SignedDataVerifier,
  Status,
} from "@apple/app-store-server-library";
import { deleteRedisKey } from "./redis-cache.js";

const ENTITLEMENTS_TABLE = "app_user_entitlements";
const NOTIFICATION_EVENTS_TABLE = "app_store_notification_events";
const DEFAULT_BUNDLE_ID = "net.ounje";
const FOUNDER_SLACK_TIMEOUT_MS = 2_500;
const APPLE_ROOT_CERTIFICATE_URLS = [
  "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA-G2.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA.cer",
];

export const APP_STORE_PRODUCT_IDS_BY_TIER = {
  plus: new Set(["net.ounje.plus.monthly", "net.ounje.plus.annually", "net.ounje.plus.yearly"]),
  autopilot: new Set(["net.ounje.autopilot.monthly", "net.ounje.autopilot.yearly"]),
};

let rootCertificatesPromise = null;
let verifierPromise = null;

function normalizeText(value) {
  return String(value ?? "").trim();
}

function normalizeEnvironment(value) {
  const raw = normalizeText(value);
  if (/^sandbox$/i.test(raw)) return Environment.SANDBOX;
  if (/^xcode$/i.test(raw)) return Environment.XCODE;
  if (/^localtesting$/i.test(raw) || /^local_testing$/i.test(raw)) return Environment.LOCAL_TESTING;
  return Environment.PRODUCTION;
}

function isValidTimestampMs(value) {
  return Number.isFinite(Number(value)) && Number(value) > 0;
}

function dateFromMs(value) {
  if (!isValidTimestampMs(value)) return null;
  const date = new Date(Number(value));
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function hashObject(value) {
  return crypto
    .createHash("sha256")
    .update(JSON.stringify(value ?? {}))
    .digest("hex");
}

function productTier(productID) {
  const normalizedProductID = normalizeText(productID);
  for (const [tier, productIDs] of Object.entries(APP_STORE_PRODUCT_IDS_BY_TIER)) {
    if (productIDs.has(normalizedProductID)) return tier;
  }
  return "free";
}

function productCadence(productID) {
  const normalizedProductID = normalizeText(productID).toLowerCase();
  if (normalizedProductID.includes(".annually") || normalizedProductID.includes(".yearly")) return "annual";
  if (normalizedProductID.includes(".monthly")) return "monthly";
  return null;
}

function firstNormalizedText(...values) {
  for (const value of values) {
    const normalized = normalizeText(value);
    if (normalized) return normalized;
  }
  return "";
}

function asNotificationType(value) {
  return normalizeText(value).toUpperCase();
}

function asSubtype(value) {
  return normalizeText(value).toUpperCase();
}

function hasFutureMs(value, nowMs) {
  return isValidTimestampMs(value) && Number(value) > nowMs;
}

function parseMetadataBoolean(value) {
  if (typeof value === "boolean") return value;
  const normalized = normalizeText(value).toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "yes";
}

function isIntroductoryOfferType(value) {
  const normalized = normalizeText(value).toLowerCase();
  return normalized === "1"
    || normalized.includes("intro")
    || normalized.includes("free_trial")
    || normalized.includes("free trial");
}

function isTrialLikeTransaction(transactionInfo, renewalInfo) {
  const offerType = firstNormalizedText(transactionInfo?.offerType, renewalInfo?.offerType);
  const offerIdentifier = firstNormalizedText(transactionInfo?.offerIdentifier, renewalInfo?.offerIdentifier).toLowerCase();
  const offerDiscountType = firstNormalizedText(transactionInfo?.offerDiscountType, renewalInfo?.offerDiscountType).toLowerCase();
  const price = Number(transactionInfo?.price ?? renewalInfo?.price);

  return isIntroductoryOfferType(offerType)
    || offerIdentifier.includes("trial")
    || offerIdentifier.includes("intro")
    || offerDiscountType.includes("free")
    || (Number.isFinite(price) && price === 0);
}

function existingEntitlementWasTrial(existing) {
  const metadata = existing?.metadata ?? {};
  return parseMetadataBoolean(metadata.is_on_trial)
    || parseMetadataBoolean(metadata.is_trial)
    || parseMetadataBoolean(metadata.trial)
    || isIntroductoryOfferType(metadata.offer_type);
}

function isMissingTableError(error, tableName) {
  const code = normalizeText(error?.code);
  const message = normalizeText(error?.message ?? error?.details).toLowerCase();
  return code === "42P01"
    || message.includes(tableName)
    && (message.includes("schema cache") || message.includes("does not exist"));
}

async function fetchURLBuffer(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`Failed to download ${url}: HTTP ${response.statusCode}`));
        return;
      }

      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve(Buffer.concat(chunks)));
    }).on("error", reject);
  });
}

async function loadRootCertificatesFromDirectory(directoryPath) {
  const entries = await fs.readdir(directoryPath, { withFileTypes: true });
  const certificatePaths = entries
    .filter((entry) => entry.isFile() && /\.(cer|der|pem)$/i.test(entry.name))
    .map((entry) => path.join(directoryPath, entry.name))
    .sort();

  if (certificatePaths.length === 0) {
    throw new Error(`No Apple root certificates found in ${directoryPath}`);
  }

  return Promise.all(certificatePaths.map((certificatePath) => fs.readFile(certificatePath)));
}

async function loadAppleRootCertificates() {
  if (rootCertificatesPromise) return rootCertificatesPromise;

  rootCertificatesPromise = (async () => {
    const directoryPath = normalizeText(process.env.APP_STORE_ROOT_CERTS_DIR);
    if (directoryPath) {
      return loadRootCertificatesFromDirectory(directoryPath);
    }

    const inlinePEM = normalizeText(process.env.APP_STORE_ROOT_CERTS_PEM);
    if (inlinePEM) {
      return inlinePEM
        .split(/\n-{5}END CERTIFICATE-{5}\n?/)
        .map((chunk) => chunk.trim())
        .filter(Boolean)
        .map((chunk) => Buffer.from(`${chunk}\n-----END CERTIFICATE-----\n`));
    }

    return Promise.all(APPLE_ROOT_CERTIFICATE_URLS.map(fetchURLBuffer));
  })();

  return rootCertificatesPromise;
}

async function getSignedDataVerifier() {
  if (verifierPromise) return verifierPromise;

  verifierPromise = (async () => {
    const bundleID = normalizeText(process.env.APP_STORE_BUNDLE_ID) || DEFAULT_BUNDLE_ID;
    const environment = normalizeEnvironment(process.env.APP_STORE_ENVIRONMENT);
    const appAppleIDRaw = normalizeText(process.env.APP_STORE_APP_APPLE_ID);
    const appAppleID = appAppleIDRaw ? Number(appAppleIDRaw) : undefined;

    if (appAppleIDRaw && !Number.isFinite(appAppleID)) {
      throw new Error("APP_STORE_APP_APPLE_ID must be numeric.");
    }
    if (environment === Environment.PRODUCTION && !Number.isFinite(appAppleID)) {
      throw new Error("APP_STORE_APP_APPLE_ID is required for production App Store notification verification.");
    }

    const onlineChecks = normalizeText(process.env.APP_STORE_ENABLE_ONLINE_CHECKS || "1") !== "0";
    const rootCertificates = await loadAppleRootCertificates();
    return new SignedDataVerifier(rootCertificates, onlineChecks, environment, bundleID, appAppleID);
  })();

  return verifierPromise;
}

export async function verifyAppStoreNotificationPayload(signedPayload) {
  const normalizedPayload = normalizeText(signedPayload);
  if (!normalizedPayload) {
    const error = new Error("signedPayload is required.");
    error.statusCode = 400;
    throw error;
  }

  const verifier = await getSignedDataVerifier();
  const notification = await verifier.verifyAndDecodeNotification(normalizedPayload);
  const signedTransactionInfo = normalizeText(notification?.data?.signedTransactionInfo);
  const signedRenewalInfo = normalizeText(notification?.data?.signedRenewalInfo);
  const transactionInfo = signedTransactionInfo
    ? await verifier.verifyAndDecodeTransaction(signedTransactionInfo)
    : null;
  const renewalInfo = signedRenewalInfo
    ? await verifier.verifyAndDecodeRenewalInfo(signedRenewalInfo)
    : null;

  return { notification, transactionInfo, renewalInfo };
}

export async function verifyAppStoreTransactionInfo(signedTransactionInfo) {
  const normalizedPayload = normalizeText(signedTransactionInfo);
  if (!normalizedPayload) {
    const error = new Error("signed_transaction_info is required.");
    error.statusCode = 400;
    throw error;
  }

  const verifier = await getSignedDataVerifier();
  return verifier.verifyAndDecodeTransaction(normalizedPayload);
}

export function deriveEntitlementFromAppStoreNotification({
  notification,
  transactionInfo,
  renewalInfo,
  nowMs = Date.now(),
}) {
  const notificationType = asNotificationType(notification?.notificationType);
  const subtype = asSubtype(notification?.subtype);
  const productID = normalizeText(transactionInfo?.productId ?? renewalInfo?.productId ?? renewalInfo?.autoRenewProductId);
  const tier = productTier(productID);
  const transactionExpiresMs = Number(transactionInfo?.expiresDate ?? 0);
  const graceExpiresMs = Number(renewalInfo?.gracePeriodExpiresDate ?? 0);
  const hasGraceAccess = hasFutureMs(graceExpiresMs, nowMs)
    && notificationType !== NotificationTypeV2.GRACE_PERIOD_EXPIRED;
  const currentAccessExpiresMs = hasGraceAccess ? graceExpiresMs : transactionExpiresMs;
  const revocationMs = Number(transactionInfo?.revocationDate ?? 0);
  const dataStatus = Number(notification?.data?.status ?? 0);

  let status = "inactive";
  if (notificationType === NotificationTypeV2.TEST) {
    status = "inactive";
  } else if (revocationMs > 0
      || notificationType === NotificationTypeV2.REFUND
      || notificationType === NotificationTypeV2.REVOKE
      || dataStatus === Status.REVOKED) {
    status = "revoked";
  } else if (notificationType === NotificationTypeV2.EXPIRED
      || notificationType === NotificationTypeV2.GRACE_PERIOD_EXPIRED
      || dataStatus === Status.EXPIRED) {
    status = "expired";
  } else if (tier !== "free" && hasFutureMs(currentAccessExpiresMs, nowMs)) {
    status = "active";
  } else if (tier !== "free" && transactionExpiresMs > 0) {
    status = "expired";
  }

  const effectiveExpiryMs = status === "revoked" && revocationMs > 0
    ? revocationMs
    : currentAccessExpiresMs;
  const userID = normalizeText(transactionInfo?.appAccountToken ?? renewalInfo?.appAccountToken);
  const originalTransactionID = normalizeText(transactionInfo?.originalTransactionId ?? renewalInfo?.originalTransactionId);
  const transactionID = normalizeText(transactionInfo?.transactionId);

  return {
    userID,
    tier,
    status,
    source: "app_store",
    productID,
    transactionID,
    originalTransactionID,
    expiresAt: dateFromMs(effectiveExpiryMs),
    metadata: {
      notification_type: notificationType || null,
      notification_subtype: subtype || null,
      notification_uuid: normalizeText(notification?.notificationUUID) || null,
      app_store_environment: normalizeText(notification?.data?.environment ?? transactionInfo?.environment ?? renewalInfo?.environment) || null,
      bundle_id: normalizeText(notification?.data?.bundleId ?? transactionInfo?.bundleId) || null,
      app_apple_id: normalizeText(notification?.data?.appAppleId) || null,
      auto_renew_status: renewalInfo?.autoRenewStatus ?? null,
      auto_renew_product_id: normalizeText(renewalInfo?.autoRenewProductId) || null,
      expiration_intent: renewalInfo?.expirationIntent ?? null,
      billing_retry: renewalInfo?.isInBillingRetryPeriod ?? null,
      cadence: productCadence(productID),
      offer_type: firstNormalizedText(transactionInfo?.offerType, renewalInfo?.offerType) || null,
      offer_identifier: firstNormalizedText(transactionInfo?.offerIdentifier, renewalInfo?.offerIdentifier) || null,
      offer_discount_type: firstNormalizedText(transactionInfo?.offerDiscountType, renewalInfo?.offerDiscountType) || null,
      is_on_trial: isTrialLikeTransaction(transactionInfo, renewalInfo),
      transaction_expires_at: dateFromMs(transactionExpiresMs),
      grace_period_expires_at: dateFromMs(graceExpiresMs),
      purchase_at: dateFromMs(transactionInfo?.purchaseDate),
      original_purchase_at: dateFromMs(transactionInfo?.originalPurchaseDate),
      signed_at: dateFromMs(notification?.signedDate ?? transactionInfo?.signedDate ?? renewalInfo?.signedDate),
      app_account_token_present: Boolean(userID),
      raw_data_status: notification?.data?.status ?? null,
    },
  };
}

async function findExistingEntitlementByTransaction(supabase, originalTransactionID, transactionID) {
  const lookups = [
    ["original_transaction_id", normalizeText(originalTransactionID)],
    ["transaction_id", normalizeText(transactionID)],
  ].filter(([, value]) => value);

  for (const [column, value] of lookups) {
    const { data, error } = await supabase
      .from(ENTITLEMENTS_TABLE)
      .select("*")
      .eq(column, value)
      .limit(1)
      .maybeSingle();

    if (error) throw error;
    if (data) return data;
  }

  return null;
}

async function fetchExistingEntitlement(supabase, userID) {
  const { data, error } = await supabase
    .from(ENTITLEMENTS_TABLE)
    .select("*")
    .eq("user_id", userID)
    .limit(1)
    .maybeSingle();

  if (error) throw error;
  return data ?? null;
}

function isProtectedManualEntitlement(existing, incomingStatus) {
  return existing?.source === "manual"
    && existing?.status === "active"
    && existing?.tier === "foundingLifetime"
    && incomingStatus !== "active";
}

function entitlementToResponse(row = null) {
  if (!row) return { entitlement: null, effectiveTier: "free" };
  const expiresAtMs = row.expires_at ? new Date(row.expires_at).getTime() : 0;
  const hasActiveExpiry = expiresAtMs > Date.now();
  const effectiveTier = row.status === "active" && row.source === "app_store" && hasActiveExpiry
    ? row.tier
    : row.status === "active" && row.source !== "app_store"
      ? row.tier
      : "free";

  return {
    entitlement: row,
    effectiveTier,
  };
}

function userScopedCacheKey(namespace, userID) {
  const normalizedUserID = normalizeText(userID);
  if (!namespace || !normalizedUserID) return null;
  const digest = crypto.createHash("sha256").update(normalizedUserID).digest("hex");
  return `ounje:${namespace}:${digest}`;
}

async function recordNotificationEvent(supabase, decoded, resolvedUserID, entitlementState) {
  const { notification, transactionInfo, renewalInfo } = decoded;
  const notificationUUID = normalizeText(notification?.notificationUUID)
    || `missing_${hashObject({ notification, transactionInfo, renewalInfo })}`;
  const eventPayload = {
    notification_uuid: notificationUUID,
    notification_type: asNotificationType(notification?.notificationType) || "UNKNOWN",
    subtype: asSubtype(notification?.subtype) || null,
    environment: normalizeText(notification?.data?.environment ?? transactionInfo?.environment ?? renewalInfo?.environment) || null,
    bundle_id: normalizeText(notification?.data?.bundleId ?? transactionInfo?.bundleId) || null,
    app_apple_id: normalizeText(notification?.data?.appAppleId) || null,
    product_id: entitlementState.productID || null,
    transaction_id: entitlementState.transactionID || null,
    original_transaction_id: entitlementState.originalTransactionID || null,
    user_id: resolvedUserID || null,
    payload: {
      notification,
      transaction_info: transactionInfo,
      renewal_info: renewalInfo,
      entitlement_state: entitlementState,
    },
  };

  const { error } = await supabase
    .from(NOTIFICATION_EVENTS_TABLE)
    .upsert(eventPayload, {
      onConflict: "notification_uuid",
      ignoreDuplicates: false,
    });

  if (error && !isMissingTableError(error, NOTIFICATION_EVENTS_TABLE)) {
    throw error;
  }

  return { recorded: !error, notificationUUID };
}

export function classifyFounderSubscriptionAlert({
  notification,
  transactionInfo = null,
  renewalInfo = null,
  existing = null,
} = {}) {
  const notificationType = asNotificationType(notification?.notificationType);
  const subtype = asSubtype(notification?.subtype);
  const isTrialNow = isTrialLikeTransaction(transactionInfo, renewalInfo);
  const wasTrial = existingEntitlementWasTrial(existing);

  if ((notificationType === "SUBSCRIBED" && (!subtype || subtype === "INITIAL_BUY"))
      || notificationType === "INITIAL_BUY") {
    return isTrialNow ? "trial_started" : "paid_started";
  }

  if ((notificationType === "DID_RENEW" || notificationType === "DID_RECOVER")
      && wasTrial
      && !isTrialNow) {
    return "paid_started";
  }

  if (notificationType === "DID_CHANGE_RENEWAL_STATUS" && subtype === "AUTO_RENEW_DISABLED") {
    return (wasTrial || isTrialNow) ? "trial_cancelled" : "paid_cancelled";
  }

  return null;
}

function founderAlertTitle(alertType) {
  switch (alertType) {
    case "trial_started":
      return "New free trial started";
    case "paid_started":
      return "New paid subscriber";
    case "trial_cancelled":
      return "Free trial cancelled";
    case "paid_cancelled":
      return "Paid subscription cancelled";
    default:
      return "App Store subscription event";
  }
}

function founderAlertEmoji(alertType) {
  switch (alertType) {
    case "trial_started":
      return ":seedling:";
    case "paid_started":
      return ":moneybag:";
    case "trial_cancelled":
      return ":warning:";
    case "paid_cancelled":
      return ":rotating_light:";
    default:
      return ":iphone:";
  }
}

function formatSlackField(title, value) {
  return {
    type: "mrkdwn",
    text: `*${title}:*\n${normalizeText(value) || "unknown"}`,
  };
}

async function resolveFounderAlertUserLabel(supabase, userID) {
  const normalizedUserID = normalizeText(userID);
  if (!normalizedUserID) return "unknown";

  try {
    const { data, error } = await supabase.auth?.admin?.getUserById?.(normalizedUserID) ?? {};
    const email = normalizeText(data?.user?.email);
    if (!error && email) return `${email} (${normalizedUserID})`;
  } catch {
    // Founder alerts are observability only. Never let auth lookup affect webhook processing.
  }

  return normalizedUserID;
}

async function sendFounderSubscriptionSlackAlert({
  supabase,
  alertType,
  resolvedUserID,
  entitlementState,
  notification,
  existing,
}) {
  const webhookURL = firstNormalizedText(
    process.env.OUNJE_FOUNDER_SLACK_WEBHOOK_URL,
    process.env.FOUNDER_SLACK_WEBHOOK_URL,
    process.env.SLACK_WEBHOOK_URL
  );
  if (!webhookURL || !alertType) return { sent: false, reason: "not_configured" };

  const metadata = entitlementState?.metadata ?? {};
  const title = founderAlertTitle(alertType);
  const userLabel = await resolveFounderAlertUserLabel(supabase, resolvedUserID);
  const environment = metadata.app_store_environment
    || normalizeText(notification?.data?.environment)
    || "unknown";
  const autoRenewStatus = metadata.auto_renew_status === 0
    ? "off"
    : metadata.auto_renew_status === 1
      ? "on"
      : "unknown";

  const payload = {
    text: `${title}: ${userLabel}`,
    blocks: [
      {
        type: "header",
        text: {
          type: "plain_text",
          text: `${founderAlertEmoji(alertType)} ${title}`,
          emoji: true,
        },
      },
      {
        type: "section",
        fields: [
          formatSlackField("User", userLabel),
          formatSlackField("Plan", entitlementState?.productID),
          formatSlackField("Tier", entitlementState?.tier),
          formatSlackField("Cadence", metadata.cadence),
          formatSlackField("Environment", environment),
          formatSlackField("Auto-renew", autoRenewStatus),
          formatSlackField("Access until", entitlementState?.expiresAt),
          formatSlackField("Previous state", existing?.status),
        ],
      },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: `Apple event: ${metadata.notification_type || "unknown"} / ${metadata.notification_subtype || "none"} · original tx: ${entitlementState?.originalTransactionID || "unknown"}`,
          },
        ],
      },
    ],
  };

  const response = await fetch(webhookURL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(FOUNDER_SLACK_TIMEOUT_MS),
  });

  if (!response.ok) {
    throw new Error(`Slack webhook failed with HTTP ${response.status}`);
  }

  return { sent: true, alertType };
}

function notifyFounderSubscriptionEvent(args) {
  const alertType = classifyFounderSubscriptionAlert(args);
  if (!alertType) return;

  void sendFounderSubscriptionSlackAlert({ ...args, alertType })
    .then((result) => {
      if (result?.sent) {
        console.log("[app-store/notifications] founder Slack alert sent:", result.alertType);
      }
    })
    .catch((error) => {
      console.warn("[app-store/notifications] founder Slack alert failed:", error.message);
    });
}

export async function processAppStoreNotification({
  supabase,
  notification,
  transactionInfo = null,
  renewalInfo = null,
  nowMs = Date.now(),
}) {
  if (!supabase) throw new Error("Supabase client is required.");

  const decoded = { notification, transactionInfo, renewalInfo };
  const entitlementState = deriveEntitlementFromAppStoreNotification({
    notification,
    transactionInfo,
    renewalInfo,
    nowMs,
  });

  let resolvedUserID = entitlementState.userID;
  let existing = null;
  if (!resolvedUserID) {
    existing = await findExistingEntitlementByTransaction(
      supabase,
      entitlementState.originalTransactionID,
      entitlementState.transactionID
    );
    resolvedUserID = normalizeText(existing?.user_id);
  }

  const ledger = await recordNotificationEvent(supabase, decoded, resolvedUserID, entitlementState);

  if (asNotificationType(notification?.notificationType) === NotificationTypeV2.TEST) {
    return {
      ok: true,
      testNotification: true,
      ledger,
      entitlement: null,
      effectiveTier: "free",
    };
  }

  if (!resolvedUserID) {
    const error = new Error("Could not resolve App Store notification to an Ounje user.");
    error.statusCode = 202;
    error.ledger = ledger;
    throw error;
  }

  if (!existing) {
    existing = await fetchExistingEntitlement(supabase, resolvedUserID);
  }

  if (isProtectedManualEntitlement(existing, entitlementState.status)) {
    notifyFounderSubscriptionEvent({
      supabase,
      notification,
      transactionInfo,
      renewalInfo,
      existing,
      entitlementState,
      resolvedUserID,
    });

    return {
      ok: true,
      protectedManualEntitlement: true,
      ledger,
      ...entitlementToResponse(existing),
    };
  }

  if (entitlementState.status === "active") {
    const allowedProductIDs = APP_STORE_PRODUCT_IDS_BY_TIER[entitlementState.tier];
    if (!allowedProductIDs?.has(entitlementState.productID)) {
      const error = new Error("App Store product_id does not map to a paid Ounje tier.");
      error.statusCode = 400;
      error.ledger = ledger;
      throw error;
    }
    if (!entitlementState.expiresAt || !entitlementState.transactionID) {
      const error = new Error("Active App Store entitlement requires transaction_id and expires_at.");
      error.statusCode = 400;
      error.ledger = ledger;
      throw error;
    }
  }

  const payload = {
    user_id: resolvedUserID,
    tier: entitlementState.tier,
    status: entitlementState.status,
    source: "app_store",
    product_id: entitlementState.productID || null,
    transaction_id: entitlementState.transactionID || null,
    original_transaction_id: entitlementState.originalTransactionID || null,
    expires_at: entitlementState.expiresAt,
    metadata: entitlementState.metadata,
  };

  const { data, error } = await supabase
    .from(ENTITLEMENTS_TABLE)
    .upsert(payload, {
      onConflict: "user_id",
      ignoreDuplicates: false,
    })
    .select("*")
    .single();

  if (error) throw error;
  void deleteRedisKey(userScopedCacheKey("entitlement-current", resolvedUserID));
  void deleteRedisKey(userScopedCacheKey("user-bootstrap", resolvedUserID));
  notifyFounderSubscriptionEvent({
    supabase,
    notification,
    transactionInfo,
    renewalInfo,
    existing,
    entitlementState,
    resolvedUserID,
  });

  return {
    ok: true,
    ledger,
    notificationType: asNotificationType(notification?.notificationType) || null,
    subtype: asSubtype(notification?.subtype) || null,
    ...entitlementToResponse(data),
  };
}
