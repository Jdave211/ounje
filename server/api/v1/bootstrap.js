import crypto from "node:crypto";
import express from "express";
import { resolveAuthorizedUserID } from "../../lib/auth.js";
import { readRedisJSON, writeRedisJSON } from "../../lib/redis-cache.js";
import {
  invalidateUserBootstrapCache,
  normalizeText,
  userBootstrapCacheKey,
  userScopedCacheKey,
} from "../../lib/user-bootstrap-cache.js";
import { getCurrentInstacartRunLogSummary } from "../../lib/instacart-run-logs.js";
import { getServiceRoleSupabase } from "../../lib/supabase-clients.js";

const router = express.Router();

const ENTITLEMENTS_TABLE = "app_user_entitlements";
const USER_BOOTSTRAP_CACHE_TTL_SECONDS = 60;
// Cap how many saved-recipe IDs we ship in the bootstrap payload. Power users
// have thousands; without a cap we serialized and sent every one on every
// cold-cache bootstrap. The iOS app already paginates / hydrates from the
// detail endpoint, so 500 is plenty for the "is X saved?" lookup set.
const SAVED_RECIPE_ID_LIMIT = Math.max(
  100,
  Number.parseInt(String(process.env.OUNJE_BOOTSTRAP_SAVED_ID_LIMIT ?? "500"), 10) || 500
);
const SAVED_RECIPE_CARD_LIMIT = 120;
const ALLOWED_TIERS = new Set(["free", "plus", "autopilot", "foundingLifetime"]);
const ALLOWED_STATUSES = new Set(["active", "expired", "revoked", "inactive"]);
const ALLOWED_SOURCES = new Set(["app_store", "manual", "system"]);
const GROCERY_PROVIDER_NAMES = {
  instacart: "Instacart",
  kroger: "Kroger",
  walmart: "Walmart",
};

function getServiceSupabase() {
  return getServiceRoleSupabase();
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

function isProviderAccountConnected(row = {}) {
  const isActive = row.is_active !== false;
  const loginStatus = normalizeText(row.login_status).toLowerCase();
  return isActive && loginStatus === "logged_in";
}

function providerConnectionsPayload(rows = []) {
  const connectedProviders = new Set(
    rows
      .filter(isProviderAccountConnected)
      .map((row) => normalizeText(row.provider).toLowerCase())
      .filter(Boolean)
  );
  return Object.entries(GROCERY_PROVIDER_NAMES).map(([id, name]) => ({
    id,
    name,
    connected: connectedProviders.has(id),
  }));
}

function planBatches(plan) {
  return Array.isArray(plan?.batches) ? plan.batches : [];
}

function planRootRecipes(plan) {
  return Array.isArray(plan?.recipes) ? plan.recipes : [];
}

function planRootGroceryItems(plan) {
  return Array.isArray(plan?.groceryItems) ? plan.groceryItems : [];
}

function recipeIDFromPlannedRecipe(plannedRecipe) {
  return normalizeText(plannedRecipe?.recipe?.id ?? plannedRecipe?.recipe_id).toLowerCase();
}

function sourceRecipeID(source) {
  return normalizeText(source?.recipeID ?? source?.recipe_id).toLowerCase();
}

function batchSignature(plan) {
  return planBatches(plan)
    .map((batch) => [
      normalizeText(batch?.id),
      normalizeText(batch?.name),
      (Array.isArray(batch?.recipes) ? batch.recipes : []).map(recipeIDFromPlannedRecipe).join(","),
    ].join(":"))
    .join("|");
}

function batchStructureScore(plan) {
  const batches = planBatches(plan);
  const nonPrimaryRecipeCount = batches
    .slice(1)
    .reduce((total, batch) => total + (Array.isArray(batch?.recipes) ? batch.recipes.length : 0), 0);
  return batches.length * 1000 + nonPrimaryRecipeCount;
}

function primaryBatchFromPlan(plan, fallbackName = "Usual") {
  const batches = planBatches(plan);
  const activeID = normalizeText(plan?.activeBatchID ?? plan?.active_batch_id);
  const activeBatch = batches.find((batch) => normalizeText(batch?.id) === activeID) ?? batches[0] ?? {};
  return {
    ...activeBatch,
    id: normalizeText(activeBatch?.id) || crypto.randomUUID(),
    name: normalizeText(activeBatch?.name) || fallbackName,
    recipes: Array.isArray(activeBatch?.recipes) && activeBatch.recipes.length > 0
      ? activeBatch.recipes
      : planRootRecipes(plan),
    groceryItems: Array.isArray(activeBatch?.groceryItems) && activeBatch.groceryItems.length > 0
      ? activeBatch.groceryItems
      : planRootGroceryItems(plan),
    recurringRecipeIDs: Array.isArray(activeBatch?.recurringRecipeIDs)
      ? activeBatch.recurringRecipeIDs
      : Array.isArray(plan?.recurringRecipeIDs) ? plan.recurringRecipeIDs : null,
    createdAt: activeBatch?.createdAt ?? plan?.generatedAt ?? null,
  };
}

function mergePlanWithRicherBatchStructure(latestPlan, richerPlan) {
  const richerBatches = planBatches(richerPlan);
  const latestBatches = planBatches(latestPlan);
  if (!latestPlan || batchStructureScore(richerPlan) <= batchStructureScore(latestPlan)) return latestPlan;

  const preservedTail = richerBatches.slice(1).map((batch) => ({
    ...batch,
    recipes: Array.isArray(batch?.recipes) ? batch.recipes : [],
    groceryItems: Array.isArray(batch?.groceryItems) ? batch.groceryItems : [],
    recurringRecipeIDs: Array.isArray(batch?.recurringRecipeIDs) ? batch.recurringRecipeIDs : null,
  }));
  const tailRecipeIDs = new Set(
    preservedTail
      .flatMap((batch) => Array.isArray(batch?.recipes) ? batch.recipes : [])
      .map(recipeIDFromPlannedRecipe)
      .filter(Boolean)
  );
  const latestPrimaryBatch = primaryBatchFromPlan(latestPlan, normalizeText(richerBatches[0]?.name) || "Usual");
  latestPrimaryBatch.recipes = (latestPrimaryBatch.recipes ?? []).filter((plannedRecipe) => {
    const recipeID = recipeIDFromPlannedRecipe(plannedRecipe);
    return !recipeID || !tailRecipeIDs.has(recipeID);
  });
  latestPrimaryBatch.groceryItems = (latestPrimaryBatch.groceryItems ?? []).filter((item) => {
    const sources = Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [];
    return sources.length === 0 || !sources.every((source) => tailRecipeIDs.has(sourceRecipeID(source)));
  });
  const batches = [latestPrimaryBatch, ...preservedTail];
  const activeBatchID = normalizeText(latestPlan.activeBatchID ?? latestPlan.active_batch_id)
    || normalizeText(latestPrimaryBatch.id)
    || null;

  return {
    ...latestPlan,
    activeBatchID,
    batches,
    recipes: latestPrimaryBatch.recipes ?? [],
    groceryItems: latestPrimaryBatch.groceryItems ?? [],
    recurringRecipeIDs: latestPrimaryBatch.recurringRecipeIDs ?? null,
  };
}

function bootstrapPrepPlanFromRows(rows = []) {
  const latestRow = rows[0] ?? null;
  if (!latestRow?.plan) {
    return {
      latestRow: null,
      plan: null,
      historyCount: 0,
      repaired: false,
    };
  }

  const richerRow = rows.reduce((best, row) => {
    if (batchStructureScore(row?.plan) > batchStructureScore(best?.plan)) return row;
    return best;
  }, latestRow);
  const repairedPlan = mergePlanWithRicherBatchStructure(latestRow.plan, richerRow?.plan);
  return {
    latestRow,
    plan: repairedPlan,
    historyCount: rows.length,
    repaired: batchSignature(repairedPlan) !== batchSignature(latestRow.plan),
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
      mealPrepCyclesResult,
      recentImportsResult,
      savedIDsResult,
      latestSavedResult,
      savedTombstonesResult,
      latestOrderResult,
      latestRunSummary,
      providerAccountsResult,
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
          .select("id,plan,plan_id,generated_at,updated_at")
          .eq("user_id", userID)
          .order("updated_at", { ascending: false })
          .limit(12),
        { data: [], error: null }
      ),
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
          .order("saved_at", { ascending: false })
          .limit(SAVED_RECIPE_ID_LIMIT),
        { data: [], error: null }
      ),
      safeQuery(
        supabase
          .from("saved_recipes")
          .select("recipe_id,title,description,author_name,author_handle,category,recipe_type,cook_time_text,published_date,discover_card_image_url,hero_image_url,recipe_url,source,saved_at")
          .eq("user_id", userID)
          .order("saved_at", { ascending: false })
          .limit(SAVED_RECIPE_CARD_LIMIT),
        { data: [], error: null }
      ),
      safeQuery(
        supabase
          .from("saved_recipe_tombstones")
          .select("recipe_id")
          .eq("user_id", userID),
        { data: [], error: null }
      ),
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
      safeQuery(
        supabase
          .from("user_provider_accounts")
          .select("provider,is_active,login_status")
          .eq("user_id", userID),
        { data: [], error: null }
      ),
    ]);

    if (profileResult.error) throw profileResult.error;
    if (mealPrepCyclesResult.error) throw mealPrepCyclesResult.error;
    if (recentImportsResult.error) throw recentImportsResult.error;
    if (savedIDsResult.error) throw savedIDsResult.error;
    if (latestSavedResult.error) throw latestSavedResult.error;
    if (savedTombstonesResult.error) throw savedTombstonesResult.error;
    if (latestOrderResult.error) throw latestOrderResult.error;
    if (providerAccountsResult.error) throw providerAccountsResult.error;

    const profile = profileResult.data ?? null;
    const tombstonedSavedRecipeIDs = new Set(
      (savedTombstonesResult.data ?? []).map((row) => row.recipe_id).filter(Boolean)
    );
    const savedIDRows = (savedIDsResult.data ?? []).filter((row) => !tombstonedSavedRecipeIDs.has(row.recipe_id));
    const latestSavedRows = (latestSavedResult.data ?? []).filter((row) => !tombstonedSavedRecipeIDs.has(row.recipe_id));
    const prepPlan = bootstrapPrepPlanFromRows(mealPrepCyclesResult.data ?? []);
    if (prepPlan.repaired && prepPlan.latestRow?.id && prepPlan.plan) {
      const { error: repairError } = await supabase
        .from("meal_prep_cycles")
        .update({ plan: prepPlan.plan })
        .eq("id", prepPlan.latestRow.id)
        .eq("user_id", userID);
      if (repairError) {
        console.warn("[bootstrap/user] failed to repair latest prep batch structure:", repairError.message);
      }
    }
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
        latest_plan: prepPlan.plan ?? null,
        latest_plan_id: prepPlan.latestRow?.plan_id ?? null,
        history_count: prepPlan.historyCount,
        override_count: null,
      },
      saved: {
        count: savedIDRows.length,
        ids: savedIDRows.map((row) => row.recipe_id).filter(Boolean),
        latest_cards: latestSavedRows.map(compactSavedCard),
      },
      imports: {
        completed_count: null,
        recent_statuses: (recentImportsResult.data ?? []).map(compactImportStatus),
      },
      cart: {
        main_shop_count: null,
        base_cart_count: null,
        latest_grocery_order: latestOrderResult.data ?? null,
        latest_instacart_run: latestRunSummary ?? null,
      },
      providers: providerConnectionsPayload(providerAccountsResult.data ?? []),
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
