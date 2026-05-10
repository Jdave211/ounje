import express from "express";
import { createClient } from "@supabase/supabase-js";
import { resolveAuthenticatedUserID } from "../../lib/instacart-run-logs.js";

const router = express.Router();

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const ENTITLEMENTS_TABLE = "app_user_entitlements";
const ALLOWED_TIERS = new Set(["free", "plus", "autopilot", "foundingLifetime"]);
const ALLOWED_STATUSES = new Set(["active", "expired", "revoked", "inactive"]);
const ALLOWED_SOURCES = new Set(["app_store", "manual", "system"]);
const PRODUCT_IDS_BY_TIER = {
  plus: new Set(["net.ounje.plus.monthly", "net.ounje.plus.annually", "net.ounje.plus.yearly"]),
  autopilot: new Set(["net.ounje.autopilot.monthly", "net.ounje.autopilot.yearly"]),
};

function normalizeText(value) {
  return String(value ?? "").trim();
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

function entitlementToResponse(row = null) {
  if (!row) {
    return {
      entitlement: null,
      effectiveTier: "free",
    };
  }

  const tier = normalizeTier(row.tier);
  const status = normalizeStatus(row.status);
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
      source: normalizeSource(row.source),
      product_id: normalizeText(row.product_id) || null,
      transaction_id: normalizeText(row.transaction_id) || null,
      original_transaction_id: normalizeText(row.original_transaction_id) || null,
      expires_at: row.expires_at ?? null,
      updated_at: row.updated_at ?? null,
      metadata,
    },
    effectiveTier: status === "active" ? tier : "free",
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
    const supabase = getServiceSupabase();
    const row = await fetchEntitlementRow(supabase, userID);
    return res.json(entitlementToResponse(row));
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
    const payload = {
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

    if (incomingSource === "app_store" && incomingStatus === "active") {
      if (!payload.product_id || !payload.transaction_id) {
        return res.status(400).json({ error: "Active App Store entitlements require product_id and transaction_id." });
      }
      const expectedProductIDs = PRODUCT_IDS_BY_TIER[incomingTier];
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
    return res.json(entitlementToResponse(data));
  } catch (error) {
    if (isMissingEntitlementsTableError(error)) {
      return res.status(503).json({ error: "Entitlements table is not available yet." });
    }
    const statusCode = Number(error?.statusCode) || 500;
    console.error("[entitlements/sync] error:", error.message);
    return res.status(statusCode).json({ error: error.message });
  }
});

export default router;
