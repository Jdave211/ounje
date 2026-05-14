import crypto from "node:crypto";
import express from "express";
import { createClient } from "@supabase/supabase-js";
import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";
import { invalidateUserBootstrapCache } from "../../lib/user-bootstrap-cache.js";

const prepRouter = express.Router();

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const APPLE_REFERENCE_DATE_MS = Date.UTC(2001, 0, 1, 0, 0, 0);
const MAX_PREP_BATCHES = 4;

let serviceSupabase = null;

function getServiceSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Supabase not configured");
  }
  if (!serviceSupabase) {
    serviceSupabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });
  }
  return serviceSupabase;
}

function normalizeText(value) {
  return String(value ?? "").trim();
}

function swiftDateNow() {
  return (Date.now() - APPLE_REFERENCE_DATE_MS) / 1000;
}

function normalizedBatchName(value, fallback) {
  const normalized = normalizeText(value);
  return normalized || fallback;
}

function normalizeUUID(value) {
  const normalized = normalizeText(value);
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(normalized)
    ? normalized
    : null;
}

function makePrepBatch({ id = null, name, recipes = [], groceryItems = [], recurringRecipeIDs = null }) {
  return {
    id: normalizeUUID(id) ?? crypto.randomUUID(),
    name,
    recipes: Array.isArray(recipes) ? recipes : [],
    groceryItems: Array.isArray(groceryItems) ? groceryItems : [],
    recurringRecipeIDs: Array.isArray(recurringRecipeIDs) ? recurringRecipeIDs : recurringRecipeIDs ?? null,
    createdAt: swiftDateNow(),
  };
}

function resolvePlanBatches(plan) {
  const existingBatches = Array.isArray(plan?.batches) ? plan.batches : [];
  if (existingBatches.length > 0) {
    return existingBatches;
  }

  return [
    makePrepBatch({
      name: "Usual",
      recipes: Array.isArray(plan?.recipes) ? plan.recipes : [],
      groceryItems: Array.isArray(plan?.groceryItems) ? plan.groceryItems : [],
      recurringRecipeIDs: Array.isArray(plan?.recurringRecipeIDs) ? plan.recurringRecipeIDs : null,
    }),
  ];
}

function mergedPlanRecipes(batches) {
  const result = [];
  const seen = new Set();
  for (const batch of batches) {
    for (const plannedRecipe of Array.isArray(batch?.recipes) ? batch.recipes : []) {
      const recipeID = normalizeText(plannedRecipe?.recipe?.id);
      if (!recipeID) {
        result.push(plannedRecipe);
        continue;
      }
      if (seen.has(recipeID)) {
        const existingIndex = result.findIndex((entry) => normalizeText(entry?.recipe?.id) === recipeID);
        if (existingIndex >= 0) result[existingIndex] = plannedRecipe;
      } else {
        seen.add(recipeID);
        result.push(plannedRecipe);
      }
    }
  }
  return result;
}

function resolvePrimeBatchID(plan, batches, preferredBatchID = null) {
  const validIDs = new Set(batches.map((batch) => normalizeUUID(batch?.id)).filter(Boolean));
  const preferred = normalizeUUID(preferredBatchID);
  if (preferred && validIDs.has(preferred)) return preferred;
  const planActive = normalizeUUID(plan?.activeBatchID ?? plan?.active_batch_id);
  if (planActive && validIDs.has(planActive)) return planActive;
  return normalizeUUID(batches[0]?.id);
}

function mirrorPlanToPrimeBatch(plan, batches, preferredBatchID = null) {
  const activeBatchID = resolvePrimeBatchID(plan, batches, preferredBatchID);
  const activeBatch = batches.find((batch) => normalizeUUID(batch?.id) === activeBatchID) ?? batches[0];
  return {
    ...plan,
    activeBatchID,
    batches,
    recipes: Array.isArray(activeBatch?.recipes) ? activeBatch.recipes : [],
    groceryItems: Array.isArray(activeBatch?.groceryItems) ? activeBatch.groceryItems : [],
    recurringRecipeIDs: Array.isArray(activeBatch?.recurringRecipeIDs) ? activeBatch.recurringRecipeIDs : null,
  };
}

async function fetchLatestMealPrepCycle(supabase, userID) {
  const { data, error } = await supabase
    .from("meal_prep_cycles")
    .select("id,plan,plan_id,generated_at")
    .eq("user_id", userID)
    .order("generated_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw error;
  return data ?? null;
}

prepRouter.post("/prep/batches", async (req, res) => {
  let auth;
  try {
    auth = await resolveAuthorizedUserID(req, { allowBodyAccessToken: true });
  } catch (error) {
    return sendAuthError(res, error, "prep/batches");
  }

  try {
    const supabase = getServiceSupabase();
    const latest = await fetchLatestMealPrepCycle(supabase, auth.userID);
    if (!latest?.plan || typeof latest.plan !== "object") {
      return res.status(404).json({ error: "No meal prep plan exists yet." });
    }

    const clientPlan = req.body?.plan && typeof req.body.plan === "object" ? req.body.plan : null;
    const sourcePlan = clientPlan ?? latest.plan;
    const plan = { ...sourcePlan };
    const requestedBatchID = normalizeUUID(req.body?.client_batch_id ?? req.body?.clientBatchID);
    const batches = resolvePlanBatches(plan);
    const existingRequestedBatch = requestedBatchID
      ? batches.find((batch) => normalizeUUID(batch?.id) === requestedBatchID)
      : null;
    if (!existingRequestedBatch && batches.length >= MAX_PREP_BATCHES) {
      return res.status(409).json({ error: `You can keep up to ${MAX_PREP_BATCHES} prep brackets.` });
    }
    const newBatch = existingRequestedBatch ?? makePrepBatch({
      id: requestedBatchID,
      name: normalizedBatchName(req.body?.name, `New Prep ${batches.length + 1}`),
    });
    const nextBatches = existingRequestedBatch ? batches : [...batches, newBatch];
    const nextPlan = mirrorPlanToPrimeBatch(plan, nextBatches, newBatch.id);

    const { error } = await supabase
      .from("meal_prep_cycles")
      .update({ plan: nextPlan })
      .eq("id", latest.id)
      .eq("user_id", auth.userID);

    if (error) throw error;
    invalidateUserBootstrapCache(auth.userID);

    return res.status(200).json({
      plan: nextPlan,
      active_batch_id: newBatch.id,
    });
  } catch (error) {
    console.error("[prep/batches] create failed:", error.message);
    return res.status(500).json({ error: "Failed to create prep batch." });
  }
});

export default prepRouter;
