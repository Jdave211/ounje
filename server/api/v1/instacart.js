import express from "express";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { addItemsToInstacartCart } from "../../lib/instacart-cart.js";
import { buildShoppingSpecEntries } from "../../lib/instacart-intent.js";
import { createAutomationJob } from "../../lib/automation-jobs.js";
import {
  getCurrentInstacartRunLogSummary,
  getInstacartRunLog,
  getInstacartRunLogSummary,
  getInstacartRunLogTrace,
  listInstacartRunLogs,
  persistInstacartRunLog,
  resolveAuthenticatedUserID
} from "../../lib/instacart-run-logs.js";
import { broadcastUserInvalidation } from "../../lib/realtime-invalidation.js";

const router = express.Router();
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const AUTOSHOP_MANUAL_BETA_ONLY = String(process.env.AUTOSHOP_MANUAL_BETA_ONLY ?? "true").trim().toLowerCase() !== "false";

function extractBearerToken(authorizationHeader) {
  const value = String(authorizationHeader ?? "").trim();
  if (!value) return null;
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match?.[1]?.trim() || null;
}

function normalizeText(value) {
    return String(value ?? "").trim();
}

function coerceBoolean(value) {
  if (value === true) return true;
  const normalized = normalizeText(value).toLowerCase();
  return ["1", "true", "yes", "y"].includes(normalized);
}

function slugifyRunPart(value, fallback = "instacart") {
  const slug = normalizeText(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 36);
  return slug || fallback;
}

function makeQueuedRunID(userID, preferredStore = null) {
  return [
    new Date().toISOString().replace(/[:.]/g, "-"),
    slugifyRunPart(userID, "user"),
    slugifyRunPart(preferredStore, "instacart"),
    randomUUID().slice(0, 8),
  ].join("__");
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

function buildRunItemsFromMainShopSnapshot(plan, fallbackItems = []) {
  const snapshotItems = Array.isArray(plan?.mainShopSnapshot?.items) ? plan.mainShopSnapshot.items : [];
  if (!snapshotItems.length) return [];

  const recipeTitleByID = new Map(
    (Array.isArray(plan?.recipes) ? plan.recipes : [])
      .map((entry) => [String(entry?.recipe?.id ?? "").trim(), normalizeText(entry?.recipe?.title)])
      .filter(([id, title]) => id && title)
  );

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

function isCompleteDeliveryAddress(address) {
  return Boolean(
    address?.line1?.trim() &&
    address?.city?.trim() &&
    address?.region?.trim() &&
    address?.postalCode?.trim()
  );
}

function getServiceSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return null;
  }

  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

function normalizeSelectedStoreName(selectedStore) {
  if (typeof selectedStore === "string") {
    return normalizeText(selectedStore) || null;
  }

  return normalizeText(selectedStore?.storeName) || null;
}

function normalizeRetryContext(value) {
  if (!value || typeof value !== "object") return null;
  const kind = normalizeText(value.kind) || "partial_retry";
  const rootRunID = normalizeText(value.root_run_id ?? value.rootRunID) || null;
  const attempt = Number.parseInt(String(value.attempt ?? "1"), 10);
  return {
    kind,
    rootRunID,
    attempt: Number.isFinite(attempt) && attempt > 0 ? attempt : 1,
  };
}

function retryMatchKeys(item) {
  return uniqueStrings([
    item?.requested,
    item?.originalName,
    item?.canonicalName,
    item?.name,
    item?.normalizedQuery,
  ]);
}

function buildRetryItemsFromResult(result, resolvedItems = []) {
  const retryKeys = new Set();
  const carryForwardKeys = new Set();
  for (const item of Array.isArray(result?.unresolvedItems) ? result.unresolvedItems : []) {
    for (const key of retryMatchKeys(item)) {
      retryKeys.add(key.toLowerCase());
    }
  }
  for (const item of Array.isArray(result?.addedItems) ? result.addedItems : []) {
    const shortfall = Number(item?.shortfall ?? 0);
    if (shortfall <= 0) continue;
    for (const key of retryMatchKeys(item)) {
      retryKeys.add(key.toLowerCase());
    }
  }

  for (const item of Array.isArray(result?.addedItems) ? result.addedItems : []) {
    const status = normalizeText(item?.status).toLowerCase();
    const shortfall = Number(item?.shortfall ?? 0);
    if (!status || status === "unresolved" || shortfall > 0) continue;
    for (const key of retryMatchKeys(item)) {
      carryForwardKeys.add(key.toLowerCase());
    }
  }

  if (!retryKeys.size && !carryForwardKeys.size) return [];

  const picked = [];
  const seen = new Set();
  for (const item of Array.isArray(resolvedItems) ? resolvedItems : []) {
    const itemKeys = retryMatchKeys(item).map((key) => key.toLowerCase());
    const shouldCarryForward = itemKeys.some((key) => carryForwardKeys.has(key));
    const shouldRetry = itemKeys.some((key) => retryKeys.has(key));
    if (!shouldCarryForward && !shouldRetry) continue;
    const dedupeKey = itemKeys[0] ?? "";
    if (!dedupeKey || seen.has(dedupeKey)) continue;
    seen.add(dedupeKey);
    picked.push(item);
  }

  return picked;
}

async function appendRunBackedOrderStepEvent({
  groceryOrderID,
  userID,
  status = "building_cart",
  kind,
  title,
  body,
  metadata = {},
  updates = {},
}) {
  const supabase = getServiceSupabase();
  const orderID = normalizeText(groceryOrderID);
  const normalizedUserID = normalizeText(userID);
  if (!supabase || !orderID || !normalizedUserID) return null;

  const { data: existingOrder, error: existingOrderError } = await supabase
    .from("grocery_orders")
    .select("id,step_log")
    .eq("id", orderID)
    .eq("user_id", normalizedUserID)
    .maybeSingle();

  if (existingOrderError) throw existingOrderError;
  if (!existingOrder?.id) return null;

  const at = new Date().toISOString();
  const stepLogEntry = {
    at,
    status: normalizeText(status) || "building_cart",
    source: "instacart_runs",
    kind: normalizeText(kind) || "update",
    title: normalizeText(title) || "Instacart update",
    body: normalizeText(body) || "There is a new update on your Instacart run.",
    metadata: metadata && typeof metadata === "object" ? metadata : {},
  };

  const payload = {
    ...updates,
    step_log: [
      ...((Array.isArray(existingOrder.step_log) ? existingOrder.step_log : [])),
      stepLogEntry,
    ],
  };

  const { error } = await supabase
    .from("grocery_orders")
    .update(payload)
    .eq("id", existingOrder.id);

  if (error) throw error;
  return stepLogEntry;
}

async function updateRunRetryState(runID, { userID = null, accessToken = null, updates = {} } = {}) {
  const normalizedRunID = normalizeText(runID);
  if (!normalizedRunID) return;

  const payload = await getInstacartRunLogTrace(normalizedRunID, { userID, accessToken });
  if (!payload?.trace) return;

  const nextTrace = {
    ...payload.trace,
    ...updates,
  };

  await persistInstacartRunLog(nextTrace, { accessToken });
}

async function findProviderAccountID(supabase, userID, provider = "instacart") {
  if (!supabase || !normalizeText(userID)) return null;

  const { data, error } = await supabase
    .from("user_provider_accounts")
    .select("id")
    .eq("user_id", userID)
    .eq("provider", provider)
    .maybeSingle();

  if (error) {
    throw error;
  }

  return data?.id ?? null;
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
  if (String(result?.retryState ?? "").trim().toLowerCase() === "queued") {
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

async function createRunBackedGroceryOrder({
  userID,
  mealPlanID,
  items,
  deliveryAddress,
  preferredStore,
  retryContext = null,
}) {
  const supabase = getServiceSupabase();
  if (!supabase) return null;

  const providerAccountID = await findProviderAccountID(supabase, userID, "instacart");
  const createdAt = new Date().toISOString();
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
      status_message: "Building Instacart cart...",
      tracking_title: "Our agents started shopping",
      tracking_detail: "We’re building your cart now.",
      step_log: [
        {
          status: "building_cart",
          kind: normalizeText(retryContext?.kind) || "run_started",
          title: normalizeText(retryContext?.kind) ? "Retrying unfinished items" : "Our agents started shopping",
          body: normalizeText(retryContext?.kind)
            ? "We queued another pass for the unfinished items only."
            : "We’re building your cart now.",
          at: createdAt,
          source: "instacart_runs",
          preferredStore: normalizeText(preferredStore) || null,
          metadata: retryContext ?? null,
        },
      ],
    })
    .select("id")
    .single();

  if (error) {
    throw error;
  }

  return data?.id ?? null;
}

async function syncRunToGroceryOrder({
  groceryOrderID,
  userID,
  mealPlanID,
  items,
  deliveryAddress,
  preferredStore,
  result,
}) {
  const supabase = getServiceSupabase();
  if (!supabase) return null;

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
  const orderID = normalizeText(groceryOrderID);
  if (!orderID) return null;

  const { data: existingOrder, error: existingOrderError } = await supabase
    .from("grocery_orders")
    .select("id,step_log,screenshots")
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

  if (error) {
    throw error;
  }

  await broadcastUserInvalidation(userID, "grocery_order.updated", {
    grocery_order_id: data?.id ?? existingOrder.id,
    meal_plan_id: mealPlanID ?? null,
    run_id: normalizeText(result?.runId) || null,
    status: state.status,
  });

  return data?.id ?? existingOrder.id;
}

async function failRunBackedGroceryOrder(groceryOrderID, errorMessage) {
  const supabase = getServiceSupabase();
  const orderID = normalizeText(groceryOrderID);
  if (!supabase || !orderID) return;

  const failedAt = new Date().toISOString();
  const { data: existingOrder } = await supabase
    .from("grocery_orders")
    .select("user_id,step_log")
    .eq("id", orderID)
    .maybeSingle();

  await supabase
    .from("grocery_orders")
    .update({
      status: "failed",
      status_message: normalizeText(errorMessage) || "Instacart run failed",
      step_log: [
        ...((Array.isArray(existingOrder?.step_log) ? existingOrder.step_log : [])),
        {
          status: "failed",
          at: failedAt,
          source: "instacart_runs",
          error: normalizeText(errorMessage) || null,
        },
      ],
    })
    .eq("id", orderID);

  await broadcastUserInvalidation(existingOrder?.user_id, "grocery_order.updated", {
    grocery_order_id: orderID,
    status: "failed",
  });
}

async function launchPartialRetryPass({
  rootRunID,
  userID,
  accessToken,
  mealPlanID,
  groceryOrderID,
  resolvedItems,
  deliveryAddress,
  preferredStore,
  strictStore,
  result,
}) {
  const normalizedRootRunID = normalizeText(rootRunID);
  if (!normalizedRootRunID) return;

  const retryItems = buildRetryItemsFromResult(result, resolvedItems);
  const queuedAt = new Date().toISOString();

  if (!retryItems.length) {
    await updateRunRetryState(normalizedRootRunID, {
      userID,
      accessToken,
      updates: {
        retryState: "skipped",
        retryQueuedAt: queuedAt,
        retryCompletedAt: queuedAt,
        retryItemCount: 0,
      },
    }).catch(() => {});

    await appendRunBackedOrderStepEvent({
      groceryOrderID,
      userID,
      status: "building_cart",
      kind: "retry_skipped",
      title: "Retry skipped",
      body: "There were no unfinished items left to retry.",
      metadata: {
        rootRunID: normalizedRootRunID,
        retryItemCount: 0,
      },
      updates: {
        tracking_title: "Retry skipped",
        tracking_detail: "There were no unfinished items left to retry.",
        last_tracked_at: queuedAt,
      },
    }).catch(() => {});
    return;
  }

  await updateRunRetryState(normalizedRootRunID, {
    userID,
    accessToken,
    updates: {
      retryState: "queued",
      retryQueuedAt: queuedAt,
      retryItemCount: retryItems.length,
      groceryOrderID: normalizeText(groceryOrderID) || null,
    },
  }).catch(() => {});

  await appendRunBackedOrderStepEvent({
    groceryOrderID,
    userID,
    status: "building_cart",
    kind: "retry_queued",
    title: "Retry queued",
    body: `We queued another pass for ${retryItems.length} unfinished item(s) only.`,
    metadata: {
      rootRunID: normalizedRootRunID,
      retryItemCount: retryItems.length,
    },
    updates: {
      tracking_title: "Retry queued",
      tracking_detail: `We queued another pass for ${retryItems.length} unfinished item(s) only.`,
      last_tracked_at: queuedAt,
    },
  }).catch(() => {});

  const retryRunID = makeQueuedRunID(userID, preferredStore);
  const retryContext = {
    kind: "partial_retry",
    rootRunID: normalizedRootRunID,
    attempt: 1,
  };

  await createAutomationJob({
    userID,
    kind: "instacart_run",
    runID: retryRunID,
    groceryOrderID,
    payload: {
      runID: retryRunID,
      userID,
      mealPlanID,
      groceryOrderID,
      items: retryItems,
      requestedItemCount: retryItems.length,
      resolvedItemCount: retryItems.length,
      deliveryAddress,
      preferredStore,
      strictStore: Boolean(strictStore),
      retryContext,
      rootRunID: normalizedRootRunID,
    },
  });
}

function buildQueuedRunTrace({
  runID,
  userID,
  mealPlanID,
  groceryOrderID,
  resolvedItems,
  deliveryAddress,
  preferredStore,
  strictStore,
  retryContext = null,
  jobID = null,
}) {
  const queuedAt = new Date().toISOString();
  const event = {
    at: queuedAt,
    kind: "queued",
    title: "Instacart run queued",
    body: "Ounje queued this cart for the automation worker.",
    metadata: {
      jobID,
      itemCount: Array.isArray(resolvedItems) ? resolvedItems.length : 0,
    },
  };

  return {
    runId: runID,
    startedAt: queuedAt,
    userId: userID,
    mealPlanID: normalizeText(mealPlanID) || null,
    groceryOrderID: normalizeText(groceryOrderID) || null,
    deliveryAddress: deliveryAddress ?? null,
    preferredStore: preferredStore ?? null,
    strictStore: Boolean(strictStore),
    runKind: String(retryContext?.kind ?? "").trim() || "primary",
    rootRunID: String(retryContext?.rootRunID ?? "").trim() || null,
    retryAttempt: Number.isFinite(Number(retryContext?.attempt)) ? Number(retryContext.attempt) : null,
    retryState: null,
    retryQueuedAt: queuedAt,
    selectedStore: null,
    selectedStoreReason: null,
    storeOptions: [],
    cartSummary: {
      totalItems: Array.isArray(resolvedItems) ? resolvedItems.length : 0,
    },
    items: (Array.isArray(resolvedItems) ? resolvedItems : []).map((item) => ({
      requested: normalizeText(item?.name ?? item?.originalName),
      canonicalName: normalizeText(item?.canonicalName ?? item?.name),
      normalizedQuery: normalizeText(item?.shoppingContext?.canonicalName ?? item?.name),
      sourceIngredients: Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [],
      attempts: [],
      finalStatus: {
        status: "queued",
      },
    })),
    events: [event],
    latestEvent: event,
    latestEventAt: queuedAt,
    automationJobID: jobID,
  };
}

async function resolveRunItems({ normalizedItems, plan }) {
  const snapshotItems = buildRunItemsFromMainShopSnapshot(plan, normalizedItems);
  if (snapshotItems.length > 0) return snapshotItems;

  const shoppingSpec = await buildShoppingSpecEntries({
    originalItems: normalizedItems,
    plan,
  });
  return Array.isArray(shoppingSpec?.items) && shoppingSpec.items.length > 0
    ? shoppingSpec.items
    : normalizedItems;
}

export async function executeInstacartAutomationJob(job, { logger = console } = {}) {
  const payload = job?.payload && typeof job.payload === "object" ? job.payload : job ?? {};
  const runID = normalizeText(payload.runID ?? payload.runId ?? job?.runID);
  const userID = normalizeText(payload.userID ?? payload.user_id ?? job?.userID);
  const mealPlanID = normalizeText(payload.mealPlanID ?? payload.meal_plan_id) || null;
  const groceryOrderID = normalizeText(payload.groceryOrderID ?? payload.grocery_order_id ?? job?.groceryOrderID) || null;
  const resolvedItems = normalizeIncomingItems(payload.items);
  const deliveryAddress = payload.deliveryAddress ?? payload.delivery_address ?? null;
  const preferredStore = payload.preferredStore ?? payload.preferred_store ?? null;
  const strictStore = Boolean(payload.strictStore ?? payload.strict_store);
  const retryContext = normalizeRetryContext(payload.retryContext ?? payload.retry_context);

  if (!runID) throw new Error("queued Instacart job is missing runID");
  if (!userID) throw new Error("queued Instacart job is missing userID");
  if (!resolvedItems.length) throw new Error("queued Instacart job is missing items");

  const startedAt = new Date().toISOString();
  if (retryContext?.rootRunID) {
    await updateRunRetryState(retryContext.rootRunID, {
      userID,
      updates: {
        retryState: "running",
        retryStartedAt: startedAt,
        retryItemCount: resolvedItems.length,
      },
    }).catch(() => {});
  }

  await appendRunBackedOrderStepEvent({
    groceryOrderID,
    userID,
    status: "building_cart",
    kind: retryContext ? "retry_running" : "run_running",
    title: retryContext ? "Retrying unfinished items" : "Building Instacart cart",
    body: retryContext ? "The automation worker started another pass." : "The automation worker started building your cart.",
    metadata: {
      jobID: job?.id ?? null,
      runID,
      itemCount: resolvedItems.length,
    },
    updates: {
      tracking_title: retryContext ? "Retrying unfinished items" : "Building Instacart cart",
      tracking_detail: retryContext ? "The automation worker started another pass." : "The automation worker started building your cart.",
      last_tracked_at: startedAt,
    },
  }).catch(() => {});

  let result;
  try {
    result = await addItemsToInstacartCart({
      items: resolvedItems,
      userId: userID,
      runId: runID,
      mealPlanID,
      groceryOrderID,
      deliveryAddress,
      preferredStore,
      strictStore,
      retryContext,
      headless: true,
      logger,
    });
  } catch (error) {
    await failRunBackedGroceryOrder(groceryOrderID, error.message).catch(() => {});
    if (retryContext?.rootRunID) {
      await updateRunRetryState(retryContext.rootRunID, {
        userID,
        updates: {
          retryState: "failed",
          retryStartedAt: startedAt,
          retryCompletedAt: new Date().toISOString(),
          retryItemCount: resolvedItems.length,
        },
      }).catch(() => {});
    }
    throw error;
  }

  await syncRunToGroceryOrder({
    groceryOrderID,
    userID,
    mealPlanID,
    items: resolvedItems,
    deliveryAddress,
    preferredStore,
    result,
  }).catch((syncError) => {
    logger.error?.("[instacart/worker] grocery order sync error:", syncError.message);
  });

  if (retryContext?.rootRunID) {
    await updateRunRetryState(retryContext.rootRunID, {
      userID,
      updates: {
        retryState: result.success ? "completed" : (result.partialSuccess ? "partial" : "failed"),
        retryStartedAt: startedAt,
        retryCompletedAt: new Date().toISOString(),
        retryRunID: normalizeText(result.runId) || runID,
        retryItemCount: resolvedItems.length,
      },
    }).catch(() => {});
  } else if (result?.partialSuccess) {
    await launchPartialRetryPass({
      rootRunID: result.runId,
      userID,
      mealPlanID,
      groceryOrderID,
      resolvedItems,
      deliveryAddress,
      preferredStore,
      strictStore,
      result,
    }).catch((retryError) => {
      logger.error?.("[instacart/worker] partial retry queue error:", retryError.message);
    });
  }

  return {
    ...result,
    runId: result?.runId ?? runID,
    groceryOrderID,
    mealPlanID,
    retryQueued: Boolean(result?.partialSuccess && !retryContext),
  };
}

router.get("/instacart/runs", async (req, res) => {
  try {
    const accessToken = extractBearerToken(req.headers.authorization);
    const userID = req.query.user_id ?? req.query.userID ?? req.headers["x-user-id"] ?? null;
    if (!accessToken && !String(userID ?? "").trim()) {
      return res.status(401).json({ error: "Authorization required" });
    }
    const query = req.query.query ?? req.query.q ?? "";
    const status = req.query.status ?? "all";
    const limit = req.query.limit ?? 24;
    const offset = req.query.offset ?? 0;
    const includeCount = coerceBoolean(req.query.include_count ?? req.query.includeCount ?? false);
    const payload = await listInstacartRunLogs({ userID, accessToken, status, query, limit, offset, includeCount });
    return res.json({
      ...payload,
      query: String(query ?? "").trim() || null,
      status: String(status ?? "all").trim() || "all",
      userID: String(payload?.userID ?? userID ?? "").trim() || null,
    });
  } catch (error) {
    console.error("[instacart/runs] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.get("/instacart/runs/current", async (req, res) => {
  try {
    const accessToken = extractBearerToken(req.headers.authorization);
    const userID = req.query.user_id ?? req.query.userID ?? req.headers["x-user-id"] ?? null;
    if (!accessToken && !String(userID ?? "").trim()) {
      return res.status(401).json({ error: "Authorization required" });
    }
    const mealPlanID = req.query.meal_plan_id ?? req.query.mealPlanID ?? null;
    const summary = await getCurrentInstacartRunLogSummary({ userID, accessToken, mealPlanID });
    return res.json({
      summary: summary ?? null,
      userID: String(userID ?? "").trim() || summary?.userId || null,
    });
  } catch (error) {
    console.error("[instacart/runs/current] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.get("/instacart/runs/:runId", async (req, res) => {
  try {
    const accessToken = extractBearerToken(req.headers.authorization);
    const userID = req.query.user_id ?? req.query.userID ?? req.headers["x-user-id"] ?? null;
    if (!accessToken && !String(userID ?? "").trim()) {
      return res.status(401).json({ error: "Authorization required" });
    }

    const payload = await getInstacartRunLog(req.params.runId, {
      userID,
      accessToken,
    });
    if (!payload) {
      return res.status(404).json({ error: "run not found" });
    }

    return res.json(payload);
  } catch (error) {
    console.error("[instacart/runs/:runId] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.get("/instacart/runs/:runId/summary", async (req, res) => {
  try {
    const accessToken = extractBearerToken(req.headers.authorization);
    const userID = req.query.user_id ?? req.query.userID ?? req.headers["x-user-id"] ?? null;
    if (!accessToken && !String(userID ?? "").trim()) {
      return res.status(401).json({ error: "Authorization required" });
    }

    const summary = await getInstacartRunLogSummary(req.params.runId, {
      userID,
      accessToken,
    });
    if (!summary) {
      return res.status(404).json({ error: "run not found" });
    }

    return res.json({ summary });
  } catch (error) {
    console.error("[instacart/runs/:runId/summary] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.get("/instacart/runs/:runId/trace", async (req, res) => {
  try {
    const accessToken = extractBearerToken(req.headers.authorization);
    const userID = req.query.user_id ?? req.query.userID ?? req.headers["x-user-id"] ?? null;
    if (!accessToken && !String(userID ?? "").trim()) {
      return res.status(401).json({ error: "Authorization required" });
    }

    const trace = await getInstacartRunLogTrace(req.params.runId, {
      userID,
      accessToken,
    });
    if (!trace) {
      return res.status(404).json({ error: "run not found" });
    }

    return res.json(trace);
  } catch (error) {
    console.error("[instacart/runs/:runId/trace] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.post("/instacart/runs/:runId/events", async (req, res) => {
  try {
    const accessToken = extractBearerToken(req.headers.authorization);
    const userID = req.query.user_id ?? req.query.userID ?? req.headers["x-user-id"] ?? null;
    if (!accessToken && !String(userID ?? "").trim()) {
      return res.status(401).json({ error: "Authorization required" });
    }

    const tracePayload = await getInstacartRunLogTrace(req.params.runId, {
      userID,
      accessToken,
    });
    if (!tracePayload?.trace) {
      return res.status(404).json({ error: "run not found" });
    }

    const incomingEvent = req.body?.event && typeof req.body.event === "object"
      ? req.body.event
      : req.body ?? {};
    const event = {
      at: new Date().toISOString(),
      kind: String(incomingEvent.kind ?? "update").trim() || "update",
      title: String(incomingEvent.title ?? "").trim() || "Instacart update",
      body: String(incomingEvent.body ?? "").trim() || "A new Instacart run event was recorded.",
      metadata: incomingEvent.metadata && typeof incomingEvent.metadata === "object" ? incomingEvent.metadata : {},
    };

    const trace = {
      ...tracePayload.trace,
      events: [
        ...((Array.isArray(tracePayload.trace?.events) ? tracePayload.trace.events : [])),
        event,
      ].slice(-80),
      latestEvent: event,
      latestEventAt: event.at,
    };

    await persistInstacartRunLog(trace, { accessToken });
    await appendRunBackedOrderStepEvent({
      groceryOrderID: trace.groceryOrderID,
      userID: trace.userId ?? userID,
      status: "building_cart",
      kind: event.kind,
      title: event.title,
      body: event.body,
      metadata: event.metadata,
      updates: {
        tracking_title: event.title,
        tracking_detail: event.body,
        last_tracked_at: event.at,
      },
    }).catch(() => {});

    return res.json({ ok: true, event });
  } catch (error) {
    console.error("[instacart/runs/:runId/events] error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

router.post("/instacart/runs", async (req, res) => {
  let groceryOrderID = null;
  try {
    const accessToken = extractBearerToken(req.headers.authorization);
    if (!accessToken) {
      return res.status(401).json({ error: "Authorization required" });
    }

    const userID = await resolveAuthenticatedUserID(accessToken);
    if (!userID) {
      return res.status(401).json({ error: "Could not resolve authenticated user" });
    }

    const {
      items = [],
      plan = null,
      preferred_store: preferredStore = null,
      strict_store: strictStore = false,
      meal_plan_id: mealPlanID = null,
      delivery_address: deliveryAddress = null,
      retry_context: rawRetryContext = null,
      manual_intent: rawManualIntent = false,
    } = req.body ?? {};
    const retryContext = normalizeRetryContext(rawRetryContext);
    const manualIntent = coerceBoolean(rawManualIntent);

    if (AUTOSHOP_MANUAL_BETA_ONLY && !manualIntent) {
      return res.status(409).json({
        error: "Autoshop beta requires manual start",
        code: "autoshop_manual_beta_required",
      });
    }

    const normalizedItems = normalizeIncomingItems(items);
    if (!Array.isArray(normalizedItems) || normalizedItems.length === 0) {
      return res.status(400).json({ error: "items array is required" });
    }
    if (!isCompleteDeliveryAddress(deliveryAddress)) {
      return res.status(400).json({ error: "deliveryAddress is required before starting Instacart" });
    }

    const resolvedItems = await resolveRunItems({ normalizedItems, plan });

    groceryOrderID = await createRunBackedGroceryOrder({
      userID,
      mealPlanID,
      items: resolvedItems,
      deliveryAddress,
      preferredStore,
      retryContext,
    });

    const runID = makeQueuedRunID(userID, preferredStore);
    const job = await createAutomationJob({
      userID,
      kind: "instacart_run",
      runID,
      groceryOrderID,
      payload: {
        runID,
        userID,
        mealPlanID,
        groceryOrderID,
        items: resolvedItems,
        requestedItemCount: normalizedItems.length,
        resolvedItemCount: resolvedItems.length,
        plan_id: mealPlanID,
        item_count: resolvedItems.length,
        deliveryAddress,
        preferredStore,
        strictStore: Boolean(strictStore),
        retryContext,
        source: manualIntent ? "manual_beta" : "automation",
        trigger: normalizeText(req.body?.trigger) || (manualIntent ? "manual_beta" : "automatic"),
      },
    });

    const queuedTrace = buildQueuedRunTrace({
      runID,
      userID,
      mealPlanID,
      groceryOrderID,
      resolvedItems,
      deliveryAddress,
      preferredStore,
      strictStore,
      retryContext,
      jobID: job.id,
    });
    await persistInstacartRunLog(queuedTrace);
    await appendRunBackedOrderStepEvent({
      groceryOrderID,
      userID,
      status: "building_cart",
      kind: "run_queued",
      title: "Instacart run queued",
      body: "Ounje queued this cart for the automation worker.",
      metadata: {
        jobID: job.id,
        runID,
        itemCount: resolvedItems.length,
        source: manualIntent ? "manual_beta" : "automation",
      },
      updates: {
        tracking_title: "Instacart run queued",
        tracking_detail: manualIntent
          ? "Ounje queued this cart from your Autoshop beta tap."
          : "Ounje queued this cart for the automation worker.",
        last_tracked_at: new Date().toISOString(),
      },
    }).catch(() => {});

    return res.status(202).json({
      runId: runID,
      jobID: job.id,
      status: "queued",
      success: false,
      partialSuccess: false,
      cartUrl: null,
      mealPlanID,
      deliveryAddress,
      groceryOrderID,
      requestedItemCount: normalizedItems.length,
      resolvedItemCount: resolvedItems.length,
      retryQueued: false,
    });
  } catch (error) {
    await failRunBackedGroceryOrder(groceryOrderID, error.message).catch(() => {});
    console.error("[instacart/runs] create error:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

export default router;
