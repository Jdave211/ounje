import express from "express";
import crypto from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { resolveAuthenticatedUserID } from "../../lib/instacart-run-logs.js";
import { deleteRedisKey, readRedisJSON, writeRedisJSON } from "../../lib/redis-cache.js";
import {
  APP_STORE_PRODUCT_IDS_BY_TIER,
  deriveEntitlementFromAppStoreNotification,
  verifyAppStoreTransactionInfo,
} from "../../lib/app-store-notifications.js";

const router = express.Router();

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const ENTITLEMENTS_TABLE = "app_user_entitlements";
const ALLOWED_TIERS = new Set(["free", "plus", "autopilot", "foundingLifetime"]);
const ALLOWED_STATUSES = new Set(["active", "expired", "revoked", "inactive"]);
const ALLOWED_SOURCES = new Set(["app_store", "manual", "system"]);
const ENTITLEMENT_CACHE_TTL_SECONDS = 45;
const USER_BOOTSTRAP_CACHE_TTL_SECONDS = 60;

function normalizeText(value) {
  return String(value ?? "").trim();
}

function userScopedCacheKey(namespace, userID) {
  const normalizedUserID = normalizeText(userID);
  if (!namespace || !normalizedUserID) return null;
  const digest = crypto.createHash("sha256").update(normalizedUserID).digest("hex");
  return `ounje:${namespace}:${digest}`;
}

function extractBearerToken(authorizationHeader) {
  const value = String(authorizationHeader ?? "").trim();
  if (!value) return null;
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match?.[1]?.trim() || null;
}

function getServiceSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Supabase not configured");
  }
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

function isMissingEntitlementsTableError(error) {
  const code = normalizeText(error?.code);
  const message = normalizeText(error?.message ?? error?.details).toLowerCase();
  return code === "42P01"
    || message.includes(ENTITLEMENTS_TABLE)
    && (message.includes("schema cache") || message.includes("does not exist"));
}

function normalizeTier(value) {
  const raw = normalizeText(value);
  if (!raw) return "free";
  if (raw === "founding_lifetime" || raw === "foundinglifetime") return "foundingLifetime";
  if (ALLOWED_TIERS.has(raw)) return raw;
  return "free";
}

function normalizeStatus(value) {
  const raw = normalizeText(value).toLowerCase();
  return ALLOWED_STATUSES.has(raw) ? raw : "inactive";
}

function normalizeSource(value) {
  const raw = normalizeText(value).toLowerCase();
  return ALLOWED_SOURCES.has(raw) ? raw : "system";
}

function normalizeTimestamp(value) {
  const raw = normalizeText(value);
  if (!raw) return null;
  const parsed = new Date(raw);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}

function isEntitlementActive(status, expiresAt, source) {
  if (status !== "active") return false;
  const normalizedExpiry = normalizeTimestamp(expiresAt);
  if (normalizeSource(source) === "app_store" && !normalizedExpiry) return false;
  if (!normalizedExpiry) return true;
  return new Date(normalizedExpiry).getTime() > Date.now();
}

function entitlementToResponse(row = null) {
  if (!row) {
    return {
      entitlement: null,
      effectiveTier: "free",
    };
  }

  const tier = normalizeTier(row.tier);
  const status = normalizeStatus(row.status);
  const source = normalizeSource(row.source);
  const isActive = isEntitlementActive(status, row.expires_at, source);
  const metadata = row?.metadata && typeof row.metadata === "object"
    ? Object.fromEntries(
      Object.entries(row.metadata).map(([key, value]) => [key, normalizeText(value)])
    )
    : {};

  return {
    entitlement: {
      user_id: normalizeText(row.user_id),
      tier,
      status,
      source,
      product_id: normalizeText(row.product_id) || null,
      transaction_id: normalizeText(row.transaction_id) || null,
      original_transaction_id: normalizeText(row.original_transaction_id) || null,
      expires_at: row.expires_at ?? null,
      updated_at: row.updated_at ?? null,
      metadata,
    },
    effectiveTier: isActive ? tier : "free",
  };
}

async function resolveAuthorizedUserID(req) {
  const accessToken = extractBearerToken(req.headers.authorization);
  if (!accessToken) {
    const error = new Error("Authorization required");
    error.statusCode = 401;
    throw error;
  }

  const authenticatedUserID = await resolveAuthenticatedUserID(accessToken);
  if (!authenticatedUserID) {
    const error = new Error("Could not resolve authenticated user");
    error.statusCode = 401;
    throw error;
  }

  const requestedUserID = normalizeText(req.headers["x-user-id"] ?? req.query.user_id ?? req.query.userID ?? req.body?.user_id ?? req.body?.userID);
  if (requestedUserID && requestedUserID !== authenticatedUserID) {
    const error = new Error("User mismatch");
    error.statusCode = 403;
    throw error;
  }

  return { userID: authenticatedUserID, accessToken };
}

async function fetchEntitlementRow(supabase, userID) {
  const { data, error } = await supabase
    .from(ENTITLEMENTS_TABLE)
    .select("*")
    .eq("user_id", userID)
    .limit(1)
    .maybeSingle();

  if (error) throw error;
  return data ?? null;
}

router.get("/entitlements/current", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const cacheKey = userScopedCacheKey("entitlement-current", userID);
    const cached = await readRedisJSON(cacheKey);
    if (cached) return res.json(cached);

    const supabase = getServiceSupabase();
    const row = await fetchEntitlementRow(supabase, userID);
    const payload = entitlementToResponse(row);
    void writeRedisJSON(cacheKey, payload, ENTITLEMENT_CACHE_TTL_SECONDS);
    return res.json(payload);
  } catch (error) {
    if (isMissingEntitlementsTableError(error)) {
      return res.json(entitlementToResponse(null));
    }
    const statusCode = Number(error?.statusCode) || 500;
    console.error("[entitlements/current] error:", error.message);
    return res.status(statusCode).json({ error: error.message });
  }
});

router.post("/entitlements/sync", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const supabase = getServiceSupabase();

    const incomingTier = normalizeTier(req.body?.tier);
    const incomingStatus = normalizeStatus(req.body?.status);
    const incomingSource = normalizeSource(req.body?.source || "app_store");
    const expiresAt = normalizeTimestamp(req.body?.expires_at ?? req.body?.expiresAt);
    let payload = {
      user_id: userID,
      tier: incomingTier,
      status: incomingStatus,
      source: incomingSource,
      product_id: normalizeText(req.body?.product_id ?? req.body?.productId) || null,
      transaction_id: normalizeText(req.body?.transaction_id ?? req.body?.transactionId) || null,
      original_transaction_id: normalizeText(req.body?.original_transaction_id ?? req.body?.originalTransactionId) || null,
      expires_at: expiresAt,
      metadata: req.body?.metadata && typeof req.body.metadata === "object" ? req.body.metadata : {},
    };

    const signedTransactionInfo = normalizeText(req.body?.signed_transaction_info ?? req.body?.signedTransactionInfo);
    if (incomingSource === "app_store" && signedTransactionInfo) {
      const verifiedTransaction = await verifyAppStoreTransactionInfo(signedTransactionInfo);
      const appAccountToken = normalizeText(verifiedTransaction?.appAccountToken);
      if (!appAccountToken || appAccountToken !== userID) {
        return res.status(403).json({ error: "Verified App Store transaction does not belong to the authenticated user." });
      }

      const verifiedState = deriveEntitlementFromAppStoreNotification({
        notification: {
          notificationType: "CLIENT_SYNC",
          signedDate: verifiedTransaction?.signedDate,
          data: {
            environment: verifiedTransaction?.environment,
            bundleId: verifiedTransaction?.bundleId,
            status: verifiedTransaction?.revocationDate ? 5 : undefined,
          },
        },
        transactionInfo: verifiedTransaction,
        renewalInfo: null,
      });

      payload = {
        user_id: userID,
        tier: verifiedState.tier,
        status: verifiedState.status,
        source: "app_store",
        product_id: verifiedState.productID || null,
        transaction_id: verifiedState.transactionID || null,
        original_transaction_id: verifiedState.originalTransactionID || null,
        expires_at: verifiedState.expiresAt,
        metadata: {
          ...verifiedState.metadata,
          sync_source: "client_signed_transaction",
        },
      };
    } else if (incomingSource === "app_store"
        && incomingStatus === "active"
        && normalizeText(process.env.APP_STORE_ALLOW_UNSIGNED_CLIENT_SYNC) !== "1") {
      return res.status(400).json({ error: "Active App Store entitlement sync requires signed_transaction_info." });
    }

    if (payload.source === "app_store" && payload.status === "active") {
      if (!payload.product_id || !payload.transaction_id) {
        return res.status(400).json({ error: "Active App Store entitlements require product_id and transaction_id." });
      }
      const expectedProductIDs = APP_STORE_PRODUCT_IDS_BY_TIER[payload.tier];
      if (!expectedProductIDs?.has(payload.product_id)) {
        return res.status(400).json({ error: "product_id does not match the requested tier." });
      }
    }

    const existing = await fetchEntitlementRow(supabase, userID).catch((error) => {
      if (isMissingEntitlementsTableError(error)) return null;
      throw error;
    });

    if (existing?.source === "manual"
        && normalizeStatus(existing.status) === "active"
        && normalizeTier(existing.tier) === "foundingLifetime"
        && incomingSource === "app_store"
        && incomingStatus !== "active") {
      return res.json(entitlementToResponse(existing));
    }

    const { data, error } = await supabase
      .from(ENTITLEMENTS_TABLE)
      .upsert(payload, {
        onConflict: "user_id",
        ignoreDuplicates: false,
      })
      .select("*")
      .single();

    if (error) throw error;
    const responsePayload = entitlementToResponse(data);
    void writeRedisJSON(userScopedCacheKey("entitlement-current", userID), responsePayload, ENTITLEMENT_CACHE_TTL_SECONDS);
    void deleteRedisKey(userScopedCacheKey("user-bootstrap", userID));
    return res.json(responsePayload);
  } catch (error) {
    if (isMissingEntitlementsTableError(error)) {
      return res.status(503).json({ error: "Entitlements table is not available yet." });
    }
    const statusCode = Number(error?.statusCode) || 500;
    console.error("[entitlements/sync] error:", error.message);
    return res.status(statusCode).json({ error: error.message });
  }
});

async function countUserRows(supabase, table, userID, applyFilters = null) {
  let query = supabase
    .from(table)
    .select("id", { count: "exact", head: true })
    .eq("user_id", userID);
  if (typeof applyFilters === "function") {
    query = applyFilters(query);
  }
  const { count, error } = await query;
  if (error) throw error;
  return count ?? 0;
}

router.get("/bootstrap/user", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const cacheKey = userScopedCacheKey("user-bootstrap", userID);
    const cached = await readRedisJSON(cacheKey);
    if (cached) return res.json(cached);

    const supabase = getServiceSupabase();
    const [
      profileResult,
      entitlementRow,
      completedImportCount,
      savedRecipeCount,
      prepOverrideCount,
      latestSavedResult,
    ] = await Promise.all([
      supabase
        .from("profiles")
        .select("id,email,display_name,auth_provider,onboarded,last_onboarding_step,account_status,deactivated_at,profile_json,updated_at")
        .eq("id", userID)
        .limit(1)
        .maybeSingle(),
      fetchEntitlementRow(supabase, userID).catch((error) => {
        if (isMissingEntitlementsTableError(error)) return null;
        throw error;
      }),
      countUserRows(
        supabase,
        "recipe_ingestion_jobs",
        userID,
        (query) => query.in("status", ["saved", "draft", "needs_review"])
      ).catch(() => null),
      countUserRows(supabase, "saved_recipes", userID).catch(() => null),
      countUserRows(supabase, "prep_recipe_overrides", userID).catch(() => null),
      supabase
        .from("saved_recipes")
        .select("recipe_id,title,category,recipe_type,hero_image_url,discover_card_image_url,saved_at")
        .eq("user_id", userID)
        .order("saved_at", { ascending: false })
        .limit(6),
    ]);

    if (profileResult.error) throw profileResult.error;
    if (latestSavedResult.error) throw latestSavedResult.error;

    const profile = profileResult.data ?? null;
    const payload = {
      user_id: userID,
      profile: profile
        ? {
            onboarded: Boolean(profile.onboarded),
            last_onboarding_step: profile.last_onboarding_step ?? 0,
            account_status: normalizeText(profile.account_status) || "active",
            deactivated_at: profile.deactivated_at ?? null,
            profile_updated_at: profile.updated_at ?? null,
            has_profile_json: Boolean(profile.profile_json),
          }
        : null,
      entitlement: entitlementToResponse(entitlementRow),
      counts: {
        completed_imports: completedImportCount,
        saved_recipes: savedRecipeCount,
        prep_overrides: prepOverrideCount,
      },
      cookbook: {
        latest_saved: latestSavedResult.data ?? [],
      },
      cached_at: new Date().toISOString(),
    };

    void writeRedisJSON(cacheKey, payload, USER_BOOTSTRAP_CACHE_TTL_SECONDS);
    return res.json(payload);
  } catch (error) {
    const statusCode = Number(error?.statusCode) || 500;
    console.error("[bootstrap/user] error:", error.message);
    return res.status(statusCode).json({ error: error.message });
  }
});

export default router;
