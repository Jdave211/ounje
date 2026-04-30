/**
 * Grocery cart API
 *
 * POST /v1/grocery/cart
 *   - MealMe: full in-app cart flow (store discovery + product matching + cart creation)
 *   - Instacart: hosted shoppable page (fallback for US/CA)
 *   - Kroger / Walmart / Amazon Fresh: search deep-links (fallback)
 *
 * POST /v1/grocery/cart/create
 *   - Finalises a MealMe cart for a chosen store + quote
 *
 * GET /v1/grocery/providers
 *   - Returns provider availability
 */

import express from "express";
import { createClient } from "@supabase/supabase-js";
import {
  geocodeAddress,
  searchGroceryCart,
  getStoreQuotes,
  createCart,
  shapeStoreOptions,
  normalizeIngredientName,
} from "./providers/mealme.js";
import { createInstacartShoppableLink }                              from "./providers/instacart.js";
import { buildKrogerSearchUrl, findNearestKrogerStore, searchKrogerProduct } from "./providers/kroger.js";
import { buildShoppingSpecEntries } from "../../lib/instacart-intent.js";
import { sourceEdgeID } from "../../lib/main-shop-collation.js";

const router = express.Router();

// ── Env ───────────────────────────────────────────────────────────────────────
const MEALME_API_KEY     = process.env.MEALME_API_KEY       ?? "";
const INSTACART_API_KEY  = process.env.INSTACART_API_KEY    ?? "";
const KROGER_CLIENT_ID   = process.env.KROGER_CLIENT_ID     ?? "";
const KROGER_CLIENT_SECRET = process.env.KROGER_CLIENT_SECRET ?? "";

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
  const { items, plan = null } = req.body ?? {};
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
    const shoppingSpec = await buildShoppingSpecEntries({
      originalItems: normalizedItems,
      plan,
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
    return res.json({
      items: specItems,
      coverageSummary,
      reconciliationSummary: shoppingSpec?.reconciliationSummary ?? null,
    });
  } catch (error) {
    console.error(
      "[grocery/spec] error:",
      JSON.stringify({
        itemCount: normalizedItems.length,
        durationMs: Date.now() - startedAt,
        message: error.message,
      })
    );
    return res.status(500).json({ error: error.message });
  }
});

// ── POST /v1/grocery/cart ─────────────────────────────────────────────────────
/**
 * Request body:
 * {
 *   provider?: "mealme" | "instacart" | "kroger" | "walmart" | "amazonFresh",
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
 * MealMe response:
 * {
 *   provider: "mealme",
 *   providerStatus: "live",
 *   storeOptions: StoreOption[],    // ranked by matchedCount, then price
 *   itemCount: number
 * }
 *
 * Fallback response:
 * {
 *   provider: string,
 *   cartUrl: string,
 *   providerStatus: "deep_link",
 *   itemCount: number
 * }
 */
router.post("/grocery/cart", async (req, res) => {
  const { provider = "mealme", items, recipeContext, deliveryAddress } = req.body ?? {};
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
    // ── MealMe: primary path ────────────────────────────────────────────────
    if (provider === "mealme") {
      return await handleMealMe(req, res, normalizedRequestItems, deliveryAddress, recipeContext);
    }

    // ── Legacy fallback providers ───────────────────────────────────────────
    const normalizedItems = normalizedRequestItems.map((item) => ({ ...item, name: normalizeIngredientName(item.name) }));
    switch (provider) {
      case "instacart":   return await handleInstacart(req, res, normalizedItems, recipeContext);
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

// ── POST /v1/grocery/cart/create ──────────────────────────────────────────────
/**
 * Creates a finalised MealMe cart for a specific store option.
 * Called after user picks a store in the app.
 *
 * Request body:
 * {
 *   storeId: string,
 *   quoteId: string,
 *   cartItems: [{ productId, quantity }],
 *   fulfillment?: "delivery" | "pickup",
 *   customer: { firstName, lastName, email, phone },
 *   deliveryAddress: { line1, city, region, postalCode }
 * }
 *
 * Response: { cartId, subtotal, deliveryFee, total, etaMinutes }
 */
router.post("/grocery/cart/create", async (req, res) => {
  if (!MEALME_API_KEY) {
    return res.status(503).json({ error: "MealMe not configured — set MEALME_API_KEY" });
  }

  const { storeId, quoteId, cartItems, fulfillment, customer, deliveryAddress } = req.body ?? {};
  if (!quoteId)                          return res.status(400).json({ error: "quoteId is required" });
  if (!Array.isArray(cartItems) || !cartItems.length)
                                         return res.status(400).json({ error: "cartItems is required" });

  try {
    const result = await createCart({
      quoteId,
      cartItems,
      fulfillment,
      customer,
      deliveryAddress,
      apiKey: MEALME_API_KEY,
    });
    return res.json(result);
  } catch (err) {
    console.error("[grocery/cart/create] error:", err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ── GET /v1/grocery/quotes ────────────────────────────────────────────────────
/**
 * Fetches live delivery/pickup quotes for a given MealMe store.
 * Called when user taps a store option to see the real delivery fee.
 *
 * Query params: storeId, lat, lng, postalCode, city, region, line1
 */
router.get("/grocery/quotes", async (req, res) => {
  if (!MEALME_API_KEY) {
    return res.status(503).json({ error: "MealMe not configured" });
  }

  const { storeId, lat, lng, line1, city, region, postalCode } = req.query;
  if (!storeId || !lat || !lng) {
    return res.status(400).json({ error: "storeId, lat, lng are required" });
  }

  try {
    const quotes = await getStoreQuotes({
      storeId,
      latitude:  parseFloat(lat),
      longitude: parseFloat(lng),
      address:   { line1, city, region, postalCode },
      apiKey: MEALME_API_KEY,
    });
    return res.json({ quotes });
  } catch (err) {
    console.error("[grocery/quotes] error:", err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ── GET /v1/grocery/providers ─────────────────────────────────────────────────
router.get("/grocery/providers", (req, res) => {
  res.json({
    providers: [
      {
        id: "mealme",
        name: "MealMe",
        status: MEALME_API_KEY ? "live" : "not_configured",
        coverage: ["US", "CA"],
        note: "1M+ stores, real product matching, in-app checkout",
        priority: 1,
      },
      {
        id: "instacart",
        name: "Instacart",
        status: INSTACART_API_KEY ? "live" : "deep_link",
        coverage: ["US", "CA"],
        note: "Hosted shoppable page — opens in browser",
        priority: 2,
      },
      {
        id: "kroger",
        name: "Kroger",
        status: KROGER_CLIENT_ID ? "live" : "deep_link",
        coverage: ["US"],
        note: "Kroger, Ralphs, Fred Meyer, Harris Teeter, and more",
        priority: 3,
      },
      {
        id: "walmart",
        name: "Walmart",
        status: "deep_link",
        coverage: ["US", "CA"],
        priority: 4,
      },
      {
        id: "amazonFresh",
        name: "Amazon Fresh",
        status: "deep_link",
        coverage: ["US"],
        priority: 5,
      },
    ],
  });
});

// ── MealMe handler ────────────────────────────────────────────────────────────
async function handleMealMe(req, res, items, deliveryAddress, recipeContext) {
  if (!MEALME_API_KEY) {
    // No key yet — gracefully fall back to Instacart or Walmart deep-link
    console.warn("[grocery/cart] MEALME_API_KEY not set, falling back to deep-link");
    const normalizedItems = items.map((i) => ({ ...i, name: normalizeIngredientName(i.name) }));
    if (INSTACART_API_KEY) return handleInstacart(req, res, normalizedItems, recipeContext);
    return handleWalmart(req, res, normalizedItems);
  }

  // 1. Resolve user coordinates
  let latitude, longitude;
  if (deliveryAddress) {
    const geo = await geocodeAddress(deliveryAddress, MEALME_API_KEY);
    latitude  = geo?.latitude  ?? 37.7786357;  // SF default for dev
    longitude = geo?.longitude ?? -122.3918135;
  } else {
    // Client should always send address, but default to central US if missing
    latitude  = 37.7786357;
    longitude = -122.3918135;
  }

  // 2. Search grocery cart across nearby stores
  const searchResult = await searchGroceryCart({
    items,
    latitude,
    longitude,
    address: deliveryAddress,
    maxMiles: 8,
    sort: "cheapest",
    apiKey: MEALME_API_KEY,
  });

  const storeOptions = shapeStoreOptions(searchResult.stores, 5, searchResult.queryItems);

  if (storeOptions.length === 0) {
    // No stores found — fall back to Instacart deep-link
    const normalizedItems = items.map((i) => ({ ...i, name: normalizeIngredientName(i.name) }));
    return handleWalmart(req, res, normalizedItems);
  }

  return res.json({
    provider:     "mealme",
    providerStatus: "live",
    storeOptions,
    itemCount:    items.length,
    location:     { latitude, longitude },
  });
}

// ── Instacart handler ─────────────────────────────────────────────────────────
async function handleInstacart(req, res, items, recipeContext) {
  if (!INSTACART_API_KEY) {
    const query = encodeURIComponent(items.slice(0, 8).map((i) => i.name).join(" "));
    return res.json({
      provider: "instacart",
      cartUrl: `https://www.instacart.com/store/s?k=${query}`,
      itemCount: items.length,
      providerStatus: "deep_link",
    });
  }

  const linkbackUrl = recipeContext?.recipeId
    ? `ounje://recipes/${recipeContext.recipeId}`
    : undefined;

  const { url, expiresAt } = await createInstacartShoppableLink({
    recipeTitle:       recipeContext?.title,
    recipeImageUrl:    recipeContext?.imageUrl,
    recipeLinkbackUrl: linkbackUrl,
    items,
    apiKey: INSTACART_API_KEY,
  });

  return res.json({
    provider: "instacart",
    cartUrl: url,
    expiresAt,
    itemCount: items.length,
    providerStatus: "live",
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

function resolveReadOnlyUserID(req) {
  return String(req.headers["x-user-id"] ?? req.query.user_id ?? req.query.userID ?? "").trim();
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
    const userID = resolveReadOnlyUserID(req);
    if (!userID) {
      return res.status(401).json({ error: "User ID required" });
    }
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
    const userID = resolveReadOnlyUserID(req);
    if (!userID) {
      return res.status(401).json({ error: "User ID required" });
    }
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
    const userID = resolveReadOnlyUserID(req);
    if (!userID) {
      return res.status(401).json({ error: "User ID required" });
    }
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
    const userID = resolveReadOnlyUserID(req);
    if (!userID) {
      return res.status(401).json({ error: "User ID required" });
    }
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
