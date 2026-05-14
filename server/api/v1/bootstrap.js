import express from "express";
import { createClient } from "@supabase/supabase-js";
import { resolveAuthorizedUserID } from "../../lib/auth.js";
import { readRedisJSON, writeRedisJSON } from "../../lib/redis-cache.js";
import {
  invalidateUserBootstrapCache,
  normalizeText,
  userBootstrapCacheKey,
  userScopedCacheKey,
} from "../../lib/user-bootstrap-cache.js";
import { getCurrentInstacartRunLogSummary } from "../../lib/instacart-run-logs.js";

const router = express.Router();

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const ENTITLEMENTS_TABLE = "app_user_entitlements";
const USER_BOOTSTRAP_CACHE_TTL_SECONDS = 60;
const ALLOWED_TIERS = new Set(["free", "plus", "autopilot", "foundingLifetime"]);
const ALLOWED_STATUSES = new Set(["active", "expired", "revoked", "inactive"]);
const ALLOWED_SOURCES = new Set(["app_store", "manual", "system"]);

function getServiceSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Supabase not configured");
  }
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

function normalizeTier(value) {
  const raw = normalizeText(value);
  if (!raw) return "free";
  if (raw === "founding_lifetime" || raw === "foundinglifetime") return "foundingLifetime";
  return ALLOWED_TIERS.has(raw) ? raw : "free";
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

function isMissingEntitlementsTableError(error) {
  const code = normalizeText(error?.code);
  const message = normalizeText(error?.message ?? error?.details).toLowerCase();
  return code === "42P01"
    || message.includes(ENTITLEMENTS_TABLE)
    && (message.includes("schema cache") || message.includes("does not exist"));
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

async function countUserRows(supabase, table, userID, selectColumn, applyFilters = null) {
  let query = supabase
    .from(table)
    .select(selectColumn, { count: "planned", head: true })
    .eq("user_id", userID);
  if (typeof applyFilters === "function") {
    query = applyFilters(query);
  }
  const { count, error } = await query;
  if (error) throw error;
  return count ?? 0;
}

function safeQuery(query, fallback) {
  return Promise.resolve(query).catch(() => fallback);
}

function compactSavedCard(row) {
  return {
    recipe_id: row.recipe_id,
    title: row.title,
    description: row.description ?? null,
    author_name: row.author_name ?? null,
    author_handle: row.author_handle ?? null,
    category: row.category ?? null,
    recipe_type: row.recipe_type ?? null,
    cook_time_text: row.cook_time_text ?? null,
    published_date: row.published_date ?? null,
    discover_card_image_url: row.discover_card_image_url ?? null,
    hero_image_url: row.hero_image_url ?? null,
    recipe_url: row.recipe_url ?? null,
    source: row.source ?? null,
    saved_at: row.saved_at ?? null,
  };
}

function compactImportStatus(row) {
  return {
    id: row.id,
    status: row.status,
    source_url: row.source_url ?? null,
    canonical_url: row.canonical_url ?? null,
    recipe_id: row.recipe_id ?? null,
    error_message: row.error_message ?? null,
    completed_at: row.completed_at ?? null,
    updated_at: row.updated_at ?? null,
  };
}

router.get("/bootstrap/user", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const cacheKey = userBootstrapCacheKey(userID);
    const cached = await readRedisJSON(cacheKey);
    if (cached) return res.json(cached);

    const supabase = getServiceSupabase();
    const [
      profileResult,
      entitlementRow,
      latestPlanResult,
      prepHistoryCount,
      prepOverrideCount,
      completedImportCount,
      recentImportsResult,
      savedIDsResult,
      latestSavedResult,
      savedTombstonesResult,
      mainShopCount,
      baseCartCount,
      latestOrderResult,
      latestRunSummary,
    ] = await Promise.all([
      supabase
        .from("profiles")
        .select("id,email,display_name,auth_provider,onboarded,last_onboarding_step,account_status,deactivated_at,profile_json,updated_at,preferred_name,dietary_patterns,hard_restrictions,cadence,delivery_anchor_day,adults,kids,cooks_for_others,meals_per_week,budget_per_cycle,budget_window,ordering_autonomy,address_line1,address_line2,city,region,postal_code,delivery_notes,food_persona,food_goals")
        .eq("id", userID)
        .limit(1)
        .maybeSingle(),
      fetchEntitlementRow(supabase, userID).catch((error) => {
        if (isMissingEntitlementsTableError(error)) return null;
        throw error;
      }),
      safeQuery(
        supabase
          .from("meal_prep_cycles")
          .select("plan,plan_id,generated_at")
          .eq("user_id", userID)
          .order("generated_at", { ascending: false })
          .limit(1)
          .maybeSingle(),
        { data: null, error: null }
      ),
      countUserRows(supabase, "meal_prep_cycles", userID, "plan_id").catch(() => null),
      countUserRows(supabase, "prep_recipe_overrides", userID, "recipe_id").catch(() => null),
      countUserRows(
        supabase,
        "recipe_ingestion_jobs",
        userID,
        "id",
        (query) => query.in("status", ["saved", "draft", "needs_review"])
      ).catch(() => null),
      safeQuery(
        supabase
          .from("recipe_ingestion_jobs")
          .select("id,status,source_url,canonical_url,recipe_id,error_message,completed_at,updated_at")
          .eq("user_id", userID)
          .order("updated_at", { ascending: false })
          .limit(8),
        { data: [], error: null }
      ),
      safeQuery(
        supabase
          .from("saved_recipes")
          .select("recipe_id,saved_at")
          .eq("user_id", userID)
          .order("saved_at", { ascending: false }),
        { data: [], error: null }
      ),
      safeQuery(
        supabase
          .from("saved_recipes")
          .select("recipe_id,title,description,author_name,author_handle,category,recipe_type,cook_time_text,published_date,discover_card_image_url,hero_image_url,recipe_url,source,saved_at")
          .eq("user_id", userID)
          .order("saved_at", { ascending: false })
          .limit(120),
        { data: [], error: null }
      ),
      safeQuery(
        supabase
          .from("saved_recipe_tombstones")
          .select("recipe_id")
          .eq("user_id", userID),
        { data: [], error: null }
      ),
      countUserRows(supabase, "main_shop_items", userID, "id").catch(() => null),
      countUserRows(supabase, "base_cart_items", userID, "id").catch(() => null),
      safeQuery(
        supabase
          .from("grocery_orders")
          .select("id,provider,status,status_message,total_cents,created_at,completed_at,provider_tracking_url,tracking_status,tracking_title,tracking_detail,tracking_eta_text,tracking_image_url,last_tracked_at,delivered_at")
          .eq("user_id", userID)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle(),
        { data: null, error: null }
      ),
      getCurrentInstacartRunLogSummary({ userID }).catch(() => null),
    ]);

    if (profileResult.error) throw profileResult.error;
    if (latestPlanResult.error) throw latestPlanResult.error;
    if (recentImportsResult.error) throw recentImportsResult.error;
    if (savedIDsResult.error) throw savedIDsResult.error;
    if (latestSavedResult.error) throw latestSavedResult.error;
    if (savedTombstonesResult.error) throw savedTombstonesResult.error;
    if (latestOrderResult.error) throw latestOrderResult.error;

    const profile = profileResult.data ?? null;
    const tombstonedSavedRecipeIDs = new Set(
      (savedTombstonesResult.data ?? []).map((row) => row.recipe_id).filter(Boolean)
    );
    const savedIDRows = (savedIDsResult.data ?? []).filter((row) => !tombstonedSavedRecipeIDs.has(row.recipe_id));
    const latestSavedRows = (latestSavedResult.data ?? []).filter((row) => !tombstonedSavedRecipeIDs.has(row.recipe_id));
    const payload = {
      version: 1,
      user_id: userID,
      profile_state: profile
        ? {
          onboarded: Boolean(profile.onboarded),
          last_onboarding_step: profile.last_onboarding_step ?? 0,
          account_status: normalizeText(profile.account_status) || "active",
          deactivated_at: profile.deactivated_at ?? null,
          profile_updated_at: profile.updated_at ?? null,
          profile_json: profile.profile_json ?? null,
          preferred_name: profile.preferred_name ?? null,
          dietary_patterns: profile.dietary_patterns ?? [],
          hard_restrictions: profile.hard_restrictions ?? [],
          cadence: profile.cadence ?? null,
          delivery_anchor_day: profile.delivery_anchor_day ?? null,
          adults: profile.adults ?? null,
          kids: profile.kids ?? null,
          cooks_for_others: profile.cooks_for_others ?? null,
          meals_per_week: profile.meals_per_week ?? null,
          budget_per_cycle: profile.budget_per_cycle ?? null,
          budget_window: profile.budget_window ?? null,
          ordering_autonomy: profile.ordering_autonomy ?? null,
          address_line1: profile.address_line1 ?? null,
          address_line2: profile.address_line2 ?? null,
          city: profile.city ?? null,
          region: profile.region ?? null,
          postal_code: profile.postal_code ?? null,
          delivery_notes: profile.delivery_notes ?? null,
          food_persona: profile.food_persona ?? null,
          food_goals: profile.food_goals ?? [],
          email: profile.email ?? null,
          display_name: profile.display_name ?? null,
          auth_provider: profile.auth_provider ?? null,
        }
        : null,
      entitlement: entitlementToResponse(entitlementRow),
      prep: {
        latest_plan: latestPlanResult.data?.plan ?? null,
        latest_plan_id: latestPlanResult.data?.plan_id ?? null,
        history_count: prepHistoryCount,
        override_count: prepOverrideCount,
      },
      saved: {
        count: savedIDRows.length,
        ids: savedIDRows.map((row) => row.recipe_id).filter(Boolean),
        latest_cards: latestSavedRows.map(compactSavedCard),
      },
      imports: {
        completed_count: completedImportCount,
        recent_statuses: (recentImportsResult.data ?? []).map(compactImportStatus),
      },
      cart: {
        main_shop_count: mainShopCount,
        base_cart_count: baseCartCount,
        latest_grocery_order: latestOrderResult.data ?? null,
        latest_instacart_run: latestRunSummary ?? null,
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

router.post("/bootstrap/invalidate", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    invalidateUserBootstrapCache(userID);
    return res.json({
      ok: true,
      cache_key: userScopedCacheKey("user-bootstrap", userID),
    });
  } catch (error) {
    const statusCode = Number(error?.statusCode) || 500;
    console.error("[bootstrap/invalidate] error:", error.message);
    return res.status(statusCode).json({ error: error.message });
  }
});

export default router;
