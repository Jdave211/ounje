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
import {
  geocodeAddress,
  searchGroceryCart,
  getStoreQuotes,
  createCart,
  shapeStoreOptions,
} from "./providers/mealme.js";
import { createInstacartShoppableLink }                              from "./providers/instacart.js";
import { buildKrogerSearchUrl, findNearestKrogerStore, searchKrogerProduct } from "./providers/kroger.js";

const router = express.Router();

// ── Env ───────────────────────────────────────────────────────────────────────
const MEALME_API_KEY     = process.env.MEALME_API_KEY       ?? "";
const INSTACART_API_KEY  = process.env.INSTACART_API_KEY    ?? "";
const KROGER_CLIENT_ID   = process.env.KROGER_CLIENT_ID     ?? "";
const KROGER_CLIENT_SECRET = process.env.KROGER_CLIENT_SECRET ?? "";

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

  if (!Array.isArray(items) || items.length === 0) {
    return res.status(400).json({ error: "items array is required and must not be empty" });
  }

  try {
    // ── MealMe: primary path ────────────────────────────────────────────────
    if (provider === "mealme") {
      return await handleMealMe(req, res, items, deliveryAddress, recipeContext);
    }

    // ── Legacy fallback providers ───────────────────────────────────────────
    const normalizedItems = items.map((item) => ({ ...item, name: normalizeForSearch(item.name) }));
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
    const normalizedItems = items.map((i) => ({ ...i, name: normalizeForSearch(i.name) }));
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
  const rawStores = await searchGroceryCart({
    items,
    latitude,
    longitude,
    address: deliveryAddress,
    maxMiles: 8,
    sort: "cheapest",
    apiKey: MEALME_API_KEY,
  });

  const storeOptions = shapeStoreOptions(rawStores, 5);

  if (storeOptions.length === 0) {
    // No stores found — fall back to Instacart deep-link
    const normalizedItems = items.map((i) => ({ ...i, name: normalizeForSearch(i.name) }));
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

// ── Normalization ─────────────────────────────────────────────────────────────
const STRIP_WORDS = new Set([
  "fresh","dried","frozen","canned","organic","raw","cooked",
  "large","medium","small","extra","very","ripe",
  "chopped","sliced","diced","minced","grated","shredded",
  "ground","whole","boneless","skinless","peeled","deveined",
  "room","temperature","softened","melted","divided",
]);

function normalizeForSearch(name) {
  return name
    .toLowerCase()
    .split(/\s+/)
    .filter((w) => !STRIP_WORDS.has(w))
    .join(" ")
    .trim();
}

export default router;
