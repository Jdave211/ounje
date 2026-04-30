#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";
import { createClient } from "@supabase/supabase-js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.join(__dirname, "..", ".env"), override: true });

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("Supabase service role environment is not configured");
}

const { addItemsToInstacartCart } = await import("../lib/instacart-cart.js");
const { getInstacartRunLogTrace, persistInstacartRunLog } = await import("../lib/instacart-run-logs.js");

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

function normalizeText(value) {
  return String(value ?? "").trim();
}

function normalizeIncomingItems(items = []) {
  return (Array.isArray(items) ? items : []).map((item) => {
    const sources = item?.sourceIngredients ?? item?.source_ingredients ?? [];
    return {
      ...item,
      name: item?.name ?? "",
      amount: Number(item?.amount ?? 0),
      unit: item?.unit ?? "item",
      estimatedPrice: Number(item?.estimatedPrice ?? item?.estimated_price ?? 0),
      sourceIngredients: (Array.isArray(sources) ? sources : []).map((source) => ({
        recipeID: String(source?.recipeID ?? source?.recipe_id ?? source?.recipeId ?? "").trim(),
        ingredientName: String(source?.ingredientName ?? source?.ingredient_name ?? "").trim(),
        unit: String(source?.unit ?? "").trim(),
      })),
    };
  });
}

function uniqueStrings(values = [], limit = Number.POSITIVE_INFINITY) {
  const deduped = [];
  const seen = new Set();
  for (const value of values) {
    const normalized = normalizeText(value);
    if (!normalized) continue;
    const key = normalized.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(normalized);
    if (deduped.length >= limit) break;
  }
  return deduped;
}

function parseQuantityText(quantityText) {
  const trimmed = normalizeText(quantityText);
  if (!trimmed) {
    return { amount: 1, unit: "item" };
  }

  const match = /^(\d+(?:\.\d+)?)\s*(.*)$/.exec(trimmed);
  if (!match) {
    return { amount: 1, unit: "item" };
  }

  const amount = Number.parseFloat(match[1]);
  const unit = normalizeText(match[2]) || "item";
  return {
    amount: Number.isFinite(amount) && amount > 0 ? amount : 1,
    unit,
  };
}

function isCompleteDeliveryAddress(address) {
  return Boolean(
    address?.line1?.trim() &&
    address?.city?.trim() &&
    address?.region?.trim() &&
    address?.postalCode?.trim()
  );
}

function resolveDeliveryAddress(profileRow) {
  const profileJSON = profileRow?.profile_json && typeof profileRow.profile_json === "object"
    ? profileRow.profile_json
    : null;
  const profileAddress = profileJSON?.deliveryAddress && typeof profileJSON.deliveryAddress === "object"
    ? profileJSON.deliveryAddress
    : null;

  const address = {
    line1: normalizeText(profileAddress?.line1 ?? profileRow?.address_line1),
    line2: normalizeText(profileAddress?.line2 ?? profileRow?.address_line2),
    city: normalizeText(profileAddress?.city ?? profileRow?.city),
    region: normalizeText(profileAddress?.region ?? profileRow?.region),
    postalCode: normalizeText(profileAddress?.postalCode ?? profileRow?.postal_code),
    country: normalizeText(profileAddress?.country ?? profileRow?.country) || "CA",
    deliveryNotes: normalizeText(profileAddress?.deliveryNotes ?? profileRow?.delivery_notes),
  };

  return isCompleteDeliveryAddress(address) ? address : null;
}

async function fetchLatestPlan(userID) {
  const { data, error } = await supabase
    .from("meal_prep_cycles")
    .select("plan_id, generated_at, plan")
    .eq("user_id", userID)
    .order("generated_at", { ascending: false })
    .limit(12);

  if (error) throw error;

  const rows = Array.isArray(data) ? data : [];
  const latest = rows.find((row) => {
    const plan = row?.plan;
    const recipes = Array.isArray(plan?.recipes) ? plan.recipes : [];
    const groceryItems = Array.isArray(plan?.groceryItems) ? plan.groceryItems : [];
    return recipes.length > 0 && groceryItems.length > 0;
  });

  if (!latest?.plan) {
    throw new Error(`No non-empty meal prep cycle found for user ${userID}`);
  }

  return latest.plan;
}

function buildRunItemsFromPlan(plan) {
  const recipeTitleByID = new Map(
    (Array.isArray(plan?.recipes) ? plan.recipes : [])
      .map((entry) => [String(entry?.recipe?.id ?? "").trim(), normalizeText(entry?.recipe?.title)])
      .filter(([id, title]) => id && title)
  );

  const snapshotItems = Array.isArray(plan?.mainShopSnapshot?.items) ? plan.mainShopSnapshot.items : [];
  if (snapshotItems.length > 0) {
    return snapshotItems.map((item) => {
      const parsedQuantity = parseQuantityText(item?.quantityText);
      const sourceIngredients = Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [];
      const sourceRecipes = uniqueStrings(
        sourceIngredients
          .map((source) => recipeTitleByID.get(String(source?.recipeID ?? "").trim()))
          .filter(Boolean),
        10
      );

      return {
        name: normalizeText(item?.name),
        originalName: normalizeText(item?.name),
        canonicalName: normalizeText(item?.canonicalKey) || normalizeText(item?.name),
        amount: parsedQuantity.amount,
        unit: parsedQuantity.unit,
        estimatedPrice: Number(item?.estimatedPriceValue ?? 0) || 0,
        sourceIngredients,
        sourceRecipes,
        shoppingContext: {
          canonicalName: normalizeText(item?.canonicalKey) || normalizeText(item?.name),
          quantityText: normalizeText(item?.quantityText) || null,
          supportingText: normalizeText(item?.supportingText) || null,
        },
      };
    }).filter((item) => item.name);
  }

  return normalizeIncomingItems(plan?.groceryItems ?? []).map((item) => ({
    ...item,
    originalName: item.originalName ?? item.name,
    sourceRecipes: [],
    shoppingContext: item.shoppingContext ?? null,
  }));
}

async function fetchProfile(userID) {
  const { data, error } = await supabase
    .from("profiles")
    .select("id, profile_json, address_line1, address_line2, city, region, postal_code, delivery_notes")
    .eq("id", userID)
    .maybeSingle();

  if (error) throw error;
  return data;
}

async function findProviderAccountID(userID, provider = "instacart") {
  const { data, error } = await supabase
    .from("user_provider_accounts")
    .select("id")
    .eq("user_id", userID)
    .eq("provider", provider)
    .maybeSingle();

  if (error) throw error;
  return data?.id ?? null;
}

async function supersedeActiveRuns(userID, reason) {
  const { data, error } = await supabase
    .from("instacart_run_logs")
    .select("run_id, status_kind")
    .eq("user_id", userID)
    .in("status_kind", ["running", "partial"])
    .order("created_at", { ascending: false });

  if (error) throw error;

  const activeRows = Array.isArray(data) ? data : [];
  for (const row of activeRows) {
    const runID = normalizeText(row?.run_id);
    if (!runID) continue;
    const tracePayload = await getInstacartRunLogTrace(runID, { userID });
    if (!tracePayload?.trace) continue;

    const now = new Date().toISOString();
    const trace = {
      ...tracePayload.trace,
      completedAt: tracePayload.trace.completedAt ?? now,
      success: false,
      partialSuccess: false,
      error: reason,
      finalizer: {
        ...(tracePayload.trace.finalizer ?? {}),
        status: "superseded",
        summary: reason,
        topIssue: reason,
      },
      latestEventAt: now,
      latestEvent: {
        at: now,
        kind: "run_superseded",
        title: "Run superseded",
        body: reason,
        metadata: {},
      },
      events: [
        ...((Array.isArray(tracePayload.trace.events) ? tracePayload.trace.events : [])),
        {
          at: now,
          kind: "run_superseded",
          title: "Run superseded",
          body: reason,
          metadata: {},
        },
      ].slice(-80),
    };

    await persistInstacartRunLog(trace);
  }

  return activeRows.length;
}

async function supersedeActiveOrders(userID, mealPlanID, reason) {
  const { data, error } = await supabase
    .from("grocery_orders")
    .select("id, status, step_log")
    .eq("user_id", userID)
    .eq("provider", "instacart")
    .eq("meal_plan_id", mealPlanID)
    .in("status", ["pending", "building_cart", "awaiting_review", "checkout_started", "user_approved"]);

  if (error) throw error;

  const orders = Array.isArray(data) ? data : [];
  const now = new Date().toISOString();
  for (const order of orders) {
    await supabase
      .from("grocery_orders")
      .update({
        status: "failed",
        status_message: reason,
        step_log: [
          ...((Array.isArray(order?.step_log) ? order.step_log : [])),
          {
            at: now,
            source: "restart_current_instacart_run",
            status: "failed",
            body: reason,
          },
        ],
      })
      .eq("id", order.id)
      .eq("user_id", userID);
  }

  return orders.length;
}

async function createRunBackedGroceryOrder({ userID, mealPlanID, items, deliveryAddress, preferredStore }) {
  const providerAccountID = await findProviderAccountID(userID, "instacart");
  const createdAt = new Date().toISOString();
  const initialTitle = "Our agents started shopping";
  const initialBody = "We’re building your cart now.";
  const { data, error } = await supabase
    .from("grocery_orders")
    .insert({
      user_id: userID,
      meal_plan_id: mealPlanID,
      provider: "instacart",
      provider_account_id: providerAccountID,
      requested_items: Array.isArray(items) ? items : [],
      delivery_address: deliveryAddress ?? null,
      status: "building_cart",
      status_message: initialBody,
      tracking_title: initialTitle,
      tracking_detail: initialBody,
      last_tracked_at: createdAt,
      step_log: [
        {
          status: "building_cart",
          at: createdAt,
          title: initialTitle,
          body: initialBody,
          source: "restart_current_instacart_run",
          preferredStore: normalizeText(preferredStore) || null,
        },
      ],
    })
    .select("id")
    .single();

  if (error) throw error;
  return data?.id ?? null;
}

function normalizeSelectedStoreName(selectedStore) {
  if (typeof selectedStore === "string") return normalizeText(selectedStore) || null;
  return normalizeText(selectedStore?.storeName) || null;
}

function normalizeMatchedItems(items = []) {
  return items
    .filter((item) => normalizeText(item?.status).toLowerCase() !== "unresolved")
    .map((item) => ({
      requested: item?.requested ?? item?.originalName ?? item?.canonicalName ?? null,
      matched: item?.matched ?? null,
      quantityRequested: Number(item?.quantityRequested ?? item?.quantity ?? 0) || null,
      quantityAdded: Number(item?.quantityAdded ?? item?.quantity ?? 0) || null,
      status: item?.status ?? null,
      score: Number(item?.score ?? 0) || null,
      shortfall: Number(item?.shortfall ?? 0) || 0,
      matchedStore: normalizeSelectedStoreName(item?.matchedStore) ?? null,
      substituteReason: item?.substituteReason ?? null,
    }));
}

function normalizeSubstitutions(items = []) {
  return items
    .filter((item) => normalizeText(item?.status).toLowerCase() === "substituted")
    .map((item) => ({
      requested: item?.requested ?? item?.originalName ?? item?.canonicalName ?? null,
      matched: item?.matched ?? null,
      quantityRequested: Number(item?.quantityRequested ?? item?.quantity ?? 0) || null,
      quantityAdded: Number(item?.quantityAdded ?? item?.quantity ?? 0) || null,
      substituteReason: item?.substituteReason ?? null,
      matchedStore: normalizeSelectedStoreName(item?.matchedStore) ?? null,
    }));
}

function normalizeMissingItems(items = []) {
  return items.map((item) => ({
    requested: item?.requested ?? item?.originalName ?? item?.canonicalName ?? null,
    quantityRequested: Number(item?.quantityRequested ?? item?.quantity ?? 0) || null,
    quantityAdded: Number(item?.quantityAdded ?? 0) || 0,
    status: item?.status ?? "unresolved",
    reason: item?.reason ?? item?.substituteReason ?? null,
    refinedQuery: item?.refinedQuery ?? null,
    matchedStore: normalizeSelectedStoreName(item?.matchedStore) ?? null,
  }));
}

function mirroredOrderStateForRun(result) {
  if (normalizeText(result?.retryState) === "queued") {
    return {
      status: "building_cart",
      statusMessage: "Instacart run queued until the selected cart is cleared",
    };
  }

  if (result?.success) {
    return {
      status: "awaiting_review",
      statusMessage: "Instacart cart is ready for review",
    };
  }

  if (result?.partialSuccess) {
    return {
      status: "building_cart",
      statusMessage: "Instacart cart needs another pass",
    };
  }

  return {
    status: "failed",
    statusMessage: normalizeText(result?.error) || "Instacart run failed",
  };
}

async function syncRunToGroceryOrder({ groceryOrderID, userID, mealPlanID, items, deliveryAddress, preferredStore, result }) {
  const orderID = normalizeText(groceryOrderID);
  if (!orderID) return null;

  const matchedItems = normalizeMatchedItems(result?.addedItems);
  const substitutions = normalizeSubstitutions(result?.addedItems);
  const missingItems = normalizeMissingItems(result?.unresolvedItems);
  const selectedStoreName = normalizeSelectedStoreName(result?.selectedStore);
  const state = mirroredOrderStateForRun(result);
  const syncedAt = new Date().toISOString();
  const stepLogEntry = {
    status: state.status,
    at: syncedAt,
    source: "instacart_runs",
    preferredStore: normalizeText(preferredStore) || null,
    runId: normalizeText(result?.runId) || null,
    selectedStore: selectedStoreName,
    cartUrl: normalizeText(result?.cartUrl) || null,
    success: Boolean(result?.success),
    partialSuccess: Boolean(result?.partialSuccess),
    retryState: normalizeText(result?.retryState) || null,
    retryQueuedAt: normalizeText(result?.retryQueuedAt) || null,
    unresolvedCount: missingItems.length,
  };

  const { data: existingOrder, error: existingOrderError } = await supabase
    .from("grocery_orders")
    .select("id, step_log, screenshots")
    .eq("id", orderID)
    .eq("user_id", userID)
    .maybeSingle();

  if (existingOrderError) throw existingOrderError;
  if (!existingOrder?.id) return null;

  const payload = {
    user_id: userID,
    meal_plan_id: mealPlanID,
    provider: "instacart",
    requested_items: Array.isArray(items) ? items : [],
    delivery_address: deliveryAddress ?? null,
    status: state.status,
    status_message: state.statusMessage,
    matched_items: matchedItems,
    substitutions,
    missing_items: missingItems,
    provider_cart_url: normalizeText(result?.cartUrl) || null,
    browser_live_url: normalizeText(result?.cartUrl) || null,
    screenshots: [
      ...((Array.isArray(existingOrder?.screenshots) ? existingOrder.screenshots : [])),
      {
        step: "instacart_run_synced",
        at: syncedAt,
        cartUrl: normalizeText(result?.cartUrl) || null,
        runId: normalizeText(result?.runId) || null,
        selectedStore: selectedStoreName,
      },
    ],
    step_log: [
      ...((Array.isArray(existingOrder?.step_log) ? existingOrder.step_log : [])),
      stepLogEntry,
    ],
  };

  const { data, error } = await supabase
    .from("grocery_orders")
    .update(payload)
    .eq("id", existingOrder.id)
    .select("id")
    .single();

  if (error) throw error;
  return data?.id ?? existingOrder.id;
}

async function main() {
  const userID = normalizeText(process.argv[2] ?? process.env.OUNJE_USER_ID);
  if (!userID) {
    throw new Error("Usage: node server/scripts/restart-current-instacart-run.mjs <user-id> [preferred-store]");
  }
  const preferredStore = normalizeText(process.argv[3] ?? process.env.INSTACART_PREFERRED_STORE) || null;

  const plan = await fetchLatestPlan(userID);
  const mealPlanID = normalizeText(plan?.id);
  if (!mealPlanID) {
    throw new Error(`Latest plan for ${userID} does not include an id`);
  }

  const profile = await fetchProfile(userID);
  const deliveryAddress = resolveDeliveryAddress(profile);
  if (!deliveryAddress) {
    throw new Error(`No complete delivery address found for user ${userID}`);
  }

  const supersedeReason = "Superseded by a newer run";
  const retiredRuns = await supersedeActiveRuns(userID, supersedeReason);
  const retiredOrders = await supersedeActiveOrders(userID, mealPlanID, "Superseded by a newer Instacart run");

  const runItems = buildRunItemsFromPlan(plan);
  console.log(JSON.stringify({
    phase: "preparing",
    userID,
    mealPlanID,
    recipeCount: Array.isArray(plan.recipes) ? plan.recipes.length : 0,
    groceryCount: Array.isArray(plan.groceryItems) ? plan.groceryItems.length : 0,
    runItemCount: runItems.length,
    source: Array.isArray(plan?.mainShopSnapshot?.items) && plan.mainShopSnapshot.items.length > 0 ? "main_shop_snapshot" : "grocery_items",
    preferredStore,
  }));

  const groceryOrderID = await createRunBackedGroceryOrder({
    userID,
    mealPlanID,
    items: runItems,
    deliveryAddress,
    preferredStore,
  });

  console.log(JSON.stringify({
    phase: "launching",
    userID,
    mealPlanID,
    groceryOrderID,
    retiredRuns,
    retiredOrders,
    itemCount: runItems.length,
    preferredStore,
  }));

  const result = await addItemsToInstacartCart({
    items: runItems.map((entry) => ({
      name: entry.name,
      originalName: entry.originalName ?? entry.name,
      amount: Math.max(1, Math.ceil(Number(entry?.amount ?? 1))),
      unit: entry?.unit ?? "item",
      sourceIngredients: Array.isArray(entry?.sourceIngredients) ? entry.sourceIngredients : [],
      sourceRecipes: Array.isArray(entry?.sourceRecipes) ? entry.sourceRecipes : [],
      shoppingContext: entry.shoppingContext ?? null,
    })),
    userId: userID,
    mealPlanID,
    groceryOrderID,
    deliveryAddress,
    preferredStore,
    strictStore: false,
    headless: true,
    logger: console,
  });

  await syncRunToGroceryOrder({
    groceryOrderID,
    userID,
    mealPlanID,
    items: runItems,
    deliveryAddress,
    preferredStore,
    result,
  });

  console.log(JSON.stringify({
    phase: "finished",
    groceryOrderID,
    runId: result?.runId ?? null,
    success: Boolean(result?.success),
    partialSuccess: Boolean(result?.partialSuccess),
    selectedStore: normalizeSelectedStoreName(result?.selectedStore),
    selectedStoreReason: result?.traceArtifact?.summary?.selectedStoreReason ?? null,
    unresolvedCount: Array.isArray(result?.unresolvedItems) ? result.unresolvedItems.length : 0,
  }));
}

main().catch((error) => {
  console.error(JSON.stringify({
    phase: "failed",
    error: error.message,
  }));
  process.exitCode = 1;
});
