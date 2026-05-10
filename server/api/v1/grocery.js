/**
 * Grocery cart API
 *
 * POST /v1/grocery/cart
 *   - Instacart / Walmart / Amazon Fresh: search deep-links
 *   - Kroger: API-backed search when configured, otherwise deep-link
 *
 * GET /v1/grocery/providers
 *   - Returns provider availability
 */

import express from "express";
import crypto from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { buildKrogerSearchUrl, findNearestKrogerStore, searchKrogerProduct } from "./providers/kroger.js";
import { buildShoppingSpecEntries } from "../../lib/instacart-intent.js";
import { sourceEdgeID } from "../../lib/main-shop-collation.js";

const router = express.Router();
const GROCERY_SPEC_CACHE_TTL_MS = Math.max(
  30_000,
  Number.parseInt(process.env.GROCERY_SPEC_CACHE_TTL_MS ?? "600000", 10) || 600_000
);
const GROCERY_SPEC_CACHE_MAX_ENTRIES = Math.max(
  20,
  Number.parseInt(process.env.GROCERY_SPEC_CACHE_MAX_ENTRIES ?? "250", 10) || 250
);
const grocerySpecCache = new Map();

// ── Env ───────────────────────────────────────────────────────────────────────
const KROGER_CLIENT_ID   = process.env.KROGER_CLIENT_ID     ?? "";
const KROGER_CLIENT_SECRET = process.env.KROGER_CLIENT_SECRET ?? "";

function normalizeIngredientName(name) {
  return String(name ?? "")
    .toLowerCase()
    .replace(/\b(fresh|large|small|medium|organic|frozen|dried|chopped|sliced|diced|minced|grated|shredded)\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
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

function stableJSONStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableJSONStringify).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJSONStringify(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function grocerySpecCacheKey(normalizedItems = [], plan = null, userID = null) {
  const recipeContext = Array.isArray(plan?.recipes)
    ? plan.recipes.map((entry) => {
        const recipe = entry?.recipe ?? entry;
        return {
          id: String(recipe?.id ?? "").trim(),
          title: String(recipe?.title ?? "").trim(),
          ingredients: (recipe?.ingredients ?? []).map((ingredient) => ({
            name: String(ingredient?.name ?? ingredient?.display_name ?? "").trim(),
            unit: String(ingredient?.unit ?? "").trim(),
          })),
        };
      })
    : [];
  const payload = {
    items: normalizedItems.map((item) => ({
      name: String(item?.name ?? "").trim().toLowerCase(),
      amount: Number(item?.amount ?? 0),
      unit: String(item?.unit ?? "").trim().toLowerCase(),
      sourceIngredients: (item?.sourceIngredients ?? []).map((source) => ({
        recipeID: String(source?.recipeID ?? "").trim().toLowerCase(),
        ingredientName: String(source?.ingredientName ?? "").trim().toLowerCase(),
        unit: String(source?.unit ?? "").trim().toLowerCase(),
      })).sort((lhs, rhs) => stableJSONStringify(lhs).localeCompare(stableJSONStringify(rhs))),
    })).sort((lhs, rhs) => stableJSONStringify(lhs).localeCompare(stableJSONStringify(rhs))),
    recipeContext,
    userID: String(userID ?? "").trim().toLowerCase(),
  };
  return crypto.createHash("sha256").update(stableJSONStringify(payload)).digest("hex");
}

function readGrocerySpecCache(key) {
  const cached = grocerySpecCache.get(key);
  if (!cached) return null;
  if (Date.now() - cached.createdAt > GROCERY_SPEC_CACHE_TTL_MS) {
    grocerySpecCache.delete(key);
    return null;
  }
  return cached.value;
}

function writeGrocerySpecCache(key, value) {
  grocerySpecCache.set(key, { value, createdAt: Date.now() });
  while (grocerySpecCache.size > GROCERY_SPEC_CACHE_MAX_ENTRIES) {
    const firstKey = grocerySpecCache.keys().next().value;
    grocerySpecCache.delete(firstKey);
  }
}

function buildCoverageSummary(originalItems = [], specItems = []) {
  const genericCoverageLabels = new Set([
    "spice",
    "spices",
    "seasoning",
    "seasonings",
    "herb",
    "herbs",
    "sauce",
    "sauces",
    "dressing",
    "dressings",
    "marinade",
    "marinades",
    "glaze",
    "glazes",
    "topping",
    "toppings",
    "garnish",
    "garnishes",
  ]);

  const sourceKey = sourceEdgeID;

  const totalSourceUses = new Set();
  for (const item of originalItems) {
    const sources = Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [];
    if (sources.length === 0) {
      totalSourceUses.add(`fallback::${String(item?.name ?? "").trim().toLowerCase()}::${String(item?.unit ?? "").trim().toLowerCase()}`);
      continue;
    }
    for (const source of sources) {
      const ingredientName = String(source?.ingredientName ?? "").trim().toLowerCase();
      if (genericCoverageLabels.has(ingredientName)) {
        continue;
      }
      const key = sourceKey(source);
      if (key) totalSourceUses.add(key);
    }
  }

  const coveredSourceUses = new Set();
  for (const item of specItems) {
    for (const edgeID of item?.sourceEdgeIDs ?? item?.shoppingContext?.sourceEdgeIDs ?? []) {
      const normalized = String(edgeID ?? "").trim();
      if (normalized) coveredSourceUses.add(normalized);
    }
    for (const source of item?.sourceIngredients ?? []) {
      const key = sourceKey(source);
      if (key) coveredSourceUses.add(key);
    }
  }

  const uncoveredBaseLabels = [];
  for (const item of originalItems) {
    const sources = Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [];
    if (sources.length === 0) continue;
    const isCovered = sources.some((source) => {
      const ingredientName = String(source?.ingredientName ?? "").trim().toLowerCase();
      if (genericCoverageLabels.has(ingredientName)) {
        return true;
      }
      return coveredSourceUses.has(sourceKey(source));
    });
    if (!isCovered) {
      const baseLabel = String(item?.name ?? "").trim() || "ingredient";
      if (!genericCoverageLabels.has(baseLabel.toLowerCase())) {
        uncoveredBaseLabels.push(baseLabel);
      }
    }
  }

  return {
    totalBaseUses: totalSourceUses.size,
    accountedBaseUses: coveredSourceUses.size,
    uncoveredBaseLabels,
  };
}

// ── POST /v1/grocery/spec ──────────────────────────────────────────────────────
router.post("/grocery/spec", async (req, res) => {
  const startedAt = Date.now();
  const { items, plan = null, bypass_cache: bypassCacheRaw = false, bypassCache: bypassCacheCamel = false } = req.body ?? {};
  const normalizedItems = normalizeIncomingItems(items);
  if (!Array.isArray(normalizedItems) || normalizedItems.length === 0) {
    return res.json({
      items: [],
      coverageSummary: {
        totalBaseUses: 0,
        accountedBaseUses: 0,
        uncoveredBaseLabels: [],
      },
      reconciliationSummary: null,
    });
  }

  try {
    const { userID, accessToken } = await resolveAuthorizedUserID(req);
    const cacheKey = grocerySpecCacheKey(normalizedItems, plan, userID);
    const shouldBypassCache = Boolean(bypassCacheRaw || bypassCacheCamel);
    if (!shouldBypassCache) {
      const cached = readGrocerySpecCache(cacheKey);
      if (cached) {
        console.log(
          "[grocery/spec] cache_hit",
          JSON.stringify({
            itemCount: normalizedItems.length,
            resolvedCount: cached.items?.length ?? 0,
            durationMs: Date.now() - startedAt,
          })
        );
        return res.json({
          ...cached,
          cache: { status: "hit" },
        });
      }
    }

    const shoppingSpec = await buildShoppingSpecEntries({
      originalItems: normalizedItems,
      plan,
      accessToken,
    });
    const specItems = Array.isArray(shoppingSpec?.items) ? shoppingSpec.items : [];
    const coverageSummary = buildCoverageSummary(normalizedItems, specItems);
    console.log(
      "[grocery/spec] ok",
      JSON.stringify({
        itemCount: normalizedItems.length,
        resolvedCount: specItems.length,
        durationMs: Date.now() - startedAt,
        reconciliationSummary: shoppingSpec?.reconciliationSummary ?? null,
      })
    );
    const payload = {
      items: specItems,
      coverageSummary,
      reconciliationSummary: shoppingSpec?.reconciliationSummary ?? null,
    };
    writeGrocerySpecCache(cacheKey, payload);
    return res.json(payload);
  } catch (error) {
    console.error(
      "[grocery/spec] error:",
      JSON.stringify({
        itemCount: normalizedItems.length,
        durationMs: Date.now() - startedAt,
        message: error.message,
      })
    );
    return res.status(Number(error?.statusCode) || 500).json({ error: error.message });
  }
});

// ── POST /v1/grocery/cart ─────────────────────────────────────────────────────
/**
 * Request body:
 * {
 *   provider?: "instacart" | "kroger" | "walmart" | "amazonFresh",
 *   items: GroceryItem[],       // [{ name, amount, unit, estimatedPrice }]
 *   recipeContext?: {
 *     title: string,
 *     imageUrl: string,
 *     recipeId: string
 *   },
 *   deliveryAddress?: {
 *     line1: string,
 *     city: string,
 *     region: string,          // state / province
 *     postalCode: string,
 *     country: string          // "US" | "CA"  (default "US")
 *   }
 * }
 *
 * Response:
 * {
 *   provider: string,
 *   cartUrl: string,
 *   providerStatus: "deep_link",
 *   itemCount: number
 * }
 */
router.post("/grocery/cart", async (req, res) => {
  const { provider = "instacart", items, deliveryAddress } = req.body ?? {};
  const normalizedRequestItems = normalizeIncomingItems(items);

  if (!Array.isArray(normalizedRequestItems) || normalizedRequestItems.length === 0) {
    return res.json({
      provider,
      cartUrl: "",
      providerStatus: "deep_link",
      itemCount: 0,
      note: "No items to build",
      resolvedProducts: [],
      selectedStore: null,
      storeOptions: [],
      partialSuccess: false,
      addedItems: [],
      unresolvedItems: [],
    });
  }

  try {
    const normalizedItems = normalizedRequestItems.map((item) => ({ ...item, name: normalizeIngredientName(item.name) }));
    switch (provider) {
      case "instacart":   return handleInstacart(req, res, normalizedItems);
      case "kroger":      return await handleKroger(req, res, normalizedItems, deliveryAddress);
      case "walmart":     return handleWalmart(req, res, normalizedItems);
      case "amazonFresh": return handleAmazonFresh(req, res, normalizedItems);
      default:            return res.status(400).json({ error: `Unknown provider: ${provider}` });
    }
  } catch (err) {
    console.error(`[grocery/cart] ${provider} error:`, err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ── GET /v1/grocery/providers ─────────────────────────────────────────────────
router.get("/grocery/providers", (req, res) => {
  res.json({
    providers: [
      {
        id: "instacart",
        name: "Instacart",
        status: "deep_link",
        coverage: ["US", "CA"],
        note: "Browser search and automation path",
        priority: 1,
      },
      {
        id: "kroger",
        name: "Kroger",
        status: KROGER_CLIENT_ID ? "live" : "deep_link",
        coverage: ["US"],
        note: "Kroger, Ralphs, Fred Meyer, Harris Teeter, and more",
        priority: 2,
      },
      {
        id: "walmart",
        name: "Walmart",
        status: "deep_link",
        coverage: ["US", "CA"],
        priority: 3,
      },
      {
        id: "amazonFresh",
        name: "Amazon Fresh",
        status: "deep_link",
        coverage: ["US"],
        priority: 4,
      },
    ],
  });
});

function handleInstacart(req, res, items) {
  const query = encodeURIComponent(items.slice(0, 8).map((i) => i.name).join(" "));
  return res.json({
    provider: "instacart",
    cartUrl: `https://www.instacart.com/store/s?k=${query}`,
    itemCount: items.length,
    providerStatus: "deep_link",
  });
}

// ── Kroger handler ────────────────────────────────────────────────────────────
async function handleKroger(req, res, items, deliveryAddress) {
  let locationId = null;
  if (KROGER_CLIENT_ID && deliveryAddress?.postalCode) {
    locationId = await findNearestKrogerStore({
      postalCode: deliveryAddress.postalCode,
      clientId: KROGER_CLIENT_ID,
      clientSecret: KROGER_CLIENT_SECRET,
    }).catch(() => null);
  }

  if (!KROGER_CLIENT_ID) {
    return res.json({
      provider: "kroger",
      cartUrl: buildKrogerSearchUrl(items),
      itemCount: items.length,
      providerStatus: "deep_link",
    });
  }

  const resolved = await Promise.allSettled(
    items.slice(0, 20).map((item) =>
      searchKrogerProduct({
        term: item.name,
        locationId,
        clientId: KROGER_CLIENT_ID,
        clientSecret: KROGER_CLIENT_SECRET,
      })
    )
  );

  const matched = resolved
    .map((r, i) => ({ item: items[i], product: r.status === "fulfilled" ? r.value : null }))
    .filter((m) => m.product !== null);

  return res.json({
    provider: "kroger",
    cartUrl: buildKrogerSearchUrl(items),
    itemCount: items.length,
    providerStatus: matched.length > 0 ? "live" : "deep_link",
    resolvedProducts: matched.map((m) => ({
      requested: m.item.name,
      matched:   m.product?.name,
      brand:     m.product?.brand,
      price:     m.product?.price,
      imageUrl:  m.product?.imageUrl,
      upc:       m.product?.upc,
    })),
  });
}

// ── Walmart / Amazon deep-link handlers ───────────────────────────────────────
function handleWalmart(req, res, items) {
  const query = encodeURIComponent(items.slice(0, 10).map((i) => i.name).join(" "));
  return res.json({
    provider: "walmart",
    cartUrl: `https://www.walmart.com/search?q=${query}`,
    itemCount: items.length,
    providerStatus: "deep_link",
  });
}

function handleAmazonFresh(req, res, items) {
  const query = encodeURIComponent(items.slice(0, 10).map((i) => i.name).join(" "));
  return res.json({
    provider: "amazonFresh",
    cartUrl: `https://www.amazon.com/s?k=${query}&i=amazonfresh`,
    itemCount: items.length,
    providerStatus: "deep_link",
  });
}

// ══════════════════════════════════════════════════════════════════════════════
// BROWSER-AGENT ORDERING (New Pipeline)
// ══════════════════════════════════════════════════════════════════════════════

import * as orchestrator from "../../lib/grocery-orchestrator.js";
import * as browserAgent from "./providers/browser-agent.js";
import { trackInstacartOrder } from "../../lib/instacart-order-tracker.js";
import { resolveAuthenticatedUserID } from "../../lib/instacart-run-logs.js";

const BROWSER_USE_API_KEY = process.env.BROWSER_USE_API_KEY ?? "";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

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

  const requestedUserID = String(req.headers["x-user-id"] ?? req.query.user_id ?? req.query.userID ?? "").trim();
  if (requestedUserID && requestedUserID !== authenticatedUserID) {
    const error = new Error("User mismatch");
    error.statusCode = 403;
    throw error;
  }

  return { userID: authenticatedUserID, accessToken };
}

async function assertOrderOwnership(orderId, userID, columns = "id,user_id") {
  const supabase = getServiceSupabase();
  const { data, error } = await supabase
    .from("grocery_orders")
    .select(columns)
    .eq("id", orderId)
    .eq("user_id", userID)
    .maybeSingle();

  if (error) throw error;
  if (!data) {
    const notFoundError = new Error("Order not found");
    notFoundError.statusCode = 404;
    throw notFoundError;
  }

  return data;
}

// ── POST /v1/grocery/orders ────────────────────────────────────────────────────
/**
 * Create a new grocery order for browser-agent processing.
 *
 * Request body:
 * {
 *   provider: "walmart" | "amazonFresh" | "target",
 *   items: GroceryItem[],
 *   deliveryAddress: { line1, city, region, postalCode },
 *   mealPlanId?: string
 * }
 *
 * Response:
 * {
 *   orderId: string,
 *   status: "pending",
 *   provider: string
 * }
 */
router.post("/grocery/orders", async (req, res) => {
  const { provider, items, deliveryAddress, mealPlanId } = req.body ?? {};

  try {
    const { userID } = await resolveAuthorizedUserID(req);

    if (!provider || !browserAgent.SUPPORTED_PROVIDERS.includes(provider)) {
      return res.status(400).json({
        error: `Invalid provider. Supported: ${browserAgent.SUPPORTED_PROVIDERS.join(", ")}`,
      });
    }

    if (!Array.isArray(items) || items.length === 0) {
      return res.status(400).json({ error: "items array is required" });
    }

    if (!deliveryAddress?.line1 || !deliveryAddress?.postalCode) {
      return res.status(400).json({ error: "deliveryAddress is required" });
    }

    const order = await orchestrator.createOrder({
      userId: userID,
      provider,
      items,
      deliveryAddress,
      mealPlanId,
    });

    return res.status(201).json({
      orderId: order.id,
      status: order.status,
      provider: order.provider,
    });
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders] create error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── POST /v1/grocery/orders/:id/start ──────────────────────────────────────────
/**
 * Start processing an order.
 * Kicks off browser-use session and begins cart building.
 */
router.post("/grocery/orders/:id/start", async (req, res) => {
  const { id } = req.params;
  const { deliveryAddress } = req.body ?? {};

  if (!BROWSER_USE_API_KEY) {
    return res.status(503).json({ error: "Browser automation not configured" });
  }

  try {
    const { userID } = await resolveAuthorizedUserID(req);
    await assertOrderOwnership(id, userID);
    const result = await orchestrator.startOrder(id, { deliveryAddress });
    return res.json(result);
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders/start] error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── GET /v1/grocery/orders/:id ─────────────────────────────────────────────────
/**
 * Get order summary for review.
 */
router.get("/grocery/orders/:id", async (req, res) => {
  const { id } = req.params;

  try {
    const { userID } = await resolveAuthorizedUserID(req);
    await assertOrderOwnership(id, userID);
    const summary = await orchestrator.getOrderSummary(id);
    return res.json(summary);
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders] get error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── GET /v1/grocery/orders/:id/tracking ───────────────────────────────────────
router.get("/grocery/orders/:id/tracking", async (req, res) => {
  const { id } = req.params;

  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const supabase = getServiceSupabase();

    const { data, error } = await supabase
      .from("grocery_orders")
      .select("id,provider,status,provider_tracking_url,tracking_status,tracking_title,tracking_detail,tracking_eta_text,tracking_image_url,tracking_payload,tracking_started_at,last_tracked_at,delivered_at,step_log")
      .eq("id", id)
      .eq("user_id", userID)
      .single();

    if (error) throw error;

    return res.json({ tracking: data });
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders/tracking] get error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── POST /v1/grocery/orders/:id/track ─────────────────────────────────────────
router.post("/grocery/orders/:id/track", async (req, res) => {
  const { id } = req.params;

  try {
    const { userID, accessToken } = await resolveAuthorizedUserID(req);
    await assertOrderOwnership(id, userID);
    const result = await trackInstacartOrder({
      orderId: id,
      accessToken,
      headless: true,
      logger: console,
    });

    return res.json(result);
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders/track] error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── GET /v1/grocery/orders/:id/slots ───────────────────────────────────────────
/**
 * Get available delivery slots.
 */
router.get("/grocery/orders/:id/slots", async (req, res) => {
  const { id } = req.params;

  try {
    const { userID } = await resolveAuthorizedUserID(req);
    await assertOrderOwnership(id, userID);
    const slots = await orchestrator.getDeliverySlots(id);
    return res.json(slots);
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders/slots] error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── POST /v1/grocery/orders/:id/slot ───────────────────────────────────────────
/**
 * Select a delivery slot.
 */
router.post("/grocery/orders/:id/slot", async (req, res) => {
  const { id } = req.params;
  const { date, timeRange } = req.body ?? {};

  if (!date || !timeRange) {
    return res.status(400).json({ error: "date and timeRange required" });
  }

  try {
    const { userID } = await resolveAuthorizedUserID(req);
    await assertOrderOwnership(id, userID);
    const result = await orchestrator.selectDeliverySlot(id, { date, timeRange });
    return res.json(result);
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders/slot] error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── POST /v1/grocery/orders/:id/approve ────────────────────────────────────────
/**
 * User approves the order - proceed to checkout.
 * Returns checkout URL for user to complete payment.
 *
 * This is the HUMAN-IN-THE-LOOP gate.
 */
router.post("/grocery/orders/:id/approve", async (req, res) => {
  const { id } = req.params;
  const { tipCents = 0 } = req.body ?? {};

  try {
    const { userID } = await resolveAuthorizedUserID(req);
    await assertOrderOwnership(id, userID);
    const result = await orchestrator.approveOrder(id, { tipCents });
    return res.json(result);
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders/approve] error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── POST /v1/grocery/orders/:id/complete ───────────────────────────────────────
/**
 * Mark order as completed after user confirms payment.
 */
router.post("/grocery/orders/:id/complete", async (req, res) => {
  const { id } = req.params;
  const { providerOrderId } = req.body ?? {};

  try {
    const { userID } = await resolveAuthorizedUserID(req);
    await assertOrderOwnership(id, userID);
    const result = await orchestrator.completeOrder(id, { providerOrderId });
    return res.json(result);
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders/complete] error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── POST /v1/grocery/orders/:id/cancel ─────────────────────────────────────────
/**
 * Cancel an order.
 */
router.post("/grocery/orders/:id/cancel", async (req, res) => {
  const { id } = req.params;
  const { reason } = req.body ?? {};

  try {
    const { userID } = await resolveAuthorizedUserID(req);
    await assertOrderOwnership(id, userID);
    const result = await orchestrator.cancelOrder(id, { reason });
    return res.json(result);
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders/cancel] error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── POST /v1/grocery/orders/:id/retry ──────────────────────────────────────────
/**
 * Retry a failed order.
 */
router.post("/grocery/orders/:id/retry", async (req, res) => {
  const { id } = req.params;

  try {
    const { userID } = await resolveAuthorizedUserID(req);
    await assertOrderOwnership(id, userID);
    const result = await orchestrator.retryOrder(id);
    return res.json(result);
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders/retry] error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── GET /v1/grocery/orders ─────────────────────────────────────────────────────
/**
 * List user's orders.
 */
router.get("/grocery/orders", async (req, res) => {
  try {
    const { userID } = await resolveAuthorizedUserID(req);
    const supabase = getServiceSupabase();

    const { data: orders, error } = await supabase
      .from("grocery_orders")
      .select("id, provider, status, status_message, total_cents, created_at, completed_at, provider_tracking_url, tracking_status, tracking_title, tracking_detail, tracking_eta_text, tracking_image_url, last_tracked_at, delivered_at, step_log")
      .eq("user_id", userID)
      .order("created_at", { ascending: false })
      .limit(20);

    if (error) throw error;

    return res.json({ orders });
  } catch (err) {
    const statusCode = Number(err?.statusCode) || 500;
    console.error("[grocery/orders] list error:", err.message);
    return res.status(statusCode).json({ error: err.message });
  }
});

// ── GET /v1/grocery/agent/providers ────────────────────────────────────────────
/**
 * Get browser-agent supported providers.
 */
router.get("/grocery/agent/providers", (req, res) => {
  const providers = browserAgent.SUPPORTED_PROVIDERS.map((id) => {
    const config = browserAgent.getProviderConfig(id);
    return {
      id,
      name: config?.name ?? id,
      status: BROWSER_USE_API_KEY ? "available" : "not_configured",
      type: "browser_agent",
    };
  });

  return res.json({ providers });
});

// ── Normalization ─────────────────────────────────────────────────────────────
export default router;
