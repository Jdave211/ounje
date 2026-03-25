/**
 * MealMe API provider
 * Docs: https://docs.mealme.ai
 *
 * Full grocery pipeline:
 *   1. geocodeAddress()        → lat/lng from user address
 *   2. searchGroceryCart()     → ingredient dict → matched products per nearby store
 *   3. getStoreQuotes()        → delivery fees + ETA per store
 *   4. createCart()            → lock in cart → cart_id
 *   5. finalizeOrder()         → place order (requires payment — called from client)
 */

const BASE = "https://api.mealme.ai";

// ── Auth ──────────────────────────────────────────────────────────────────────
function headers(apiKey) {
  return { "Id-Token": apiKey, "Accept": "application/json" };
}

// ── 1. Geocode ────────────────────────────────────────────────────────────────
/**
 * Convert a street address into lat/lng.
 * Falls back gracefully if geocoding fails.
 */
export async function geocodeAddress(address, apiKey) {
  const { line1, city, region, postalCode, country = "US" } = address;

  const params = new URLSearchParams({
    address: [line1, city, region, postalCode, country].filter(Boolean).join(", "),
  });

  try {
    const resp = await fetch(`${BASE}/location/geocode?${params}`, {
      headers: headers(apiKey),
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    const loc = data.geocoded_address?.location ?? data.location;
    if (!loc?.latitude || !loc?.longitude) return null;
    return { latitude: loc.latitude, longitude: loc.longitude };
  } catch {
    return null;
  }
}

// ── 2. Search grocery cart ─────────────────────────────────────────────────────
/**
 * Core endpoint: given a list of GroceryItems + user location,
 * returns stores near the user with matched products for each ingredient.
 *
 * @param {Object} params
 * @param {Array}  params.items           - GroceryItem[]
 * @param {number} params.latitude
 * @param {number} params.longitude
 * @param {Object} params.address         - { line1, city, region, postalCode }
 * @param {string} params.storeName       - optional store preference (e.g. "Kroger")
 * @param {number} params.maxMiles        - default 5
 * @param {string} params.sort            - "cheapest" | "fastest" | "relevance"
 * @param {string} params.apiKey
 * @returns stores[] with matched carts
 */
export async function searchGroceryCart({
  items,
  latitude,
  longitude,
  address,
  storeName = "",
  maxMiles = 5,
  sort = "cheapest",
  apiKey,
}) {
  // Build the query dict: {"Long Grain Rice": 2, "Chicken Drumsticks": 6, ...}
  const queryDict = {};
  for (const item of items) {
    const key = normalizeIngredientName(item.name);
    if (key) {
      queryDict[key] = Math.max(1, Math.round(item.amount || 1));
    }
  }

  const params = new URLSearchParams({
    query:             JSON.stringify(queryDict),
    user_latitude:     latitude,
    user_longitude:    longitude,
    user_street_num:   extractStreetNum(address?.line1 ?? ""),
    user_street_name:  extractStreetName(address?.line1 ?? ""),
    user_city:         address?.city ?? "",
    user_state:        address?.region ?? "",
    user_zipcode:      address?.postalCode ?? "",
    user_country:      "US",
    pickup:            "false",
    sort,
    open:              "true",
    maximum_miles:     maxMiles,
    full_carts_only:   "false",   // allow partial matches so we always return something
    fuzzy_search:      "true",    // lenient matching for African/ethnic ingredients
    fetch_quotes:      "false",   // we fetch quotes separately per chosen store
    ...(storeName && { store_name: storeName }),
  });

  const resp = await fetch(`${BASE}/groceries/search/cart/v2?${params}`, {
    headers: headers(apiKey),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`MealMe searchGroceryCart ${resp.status}: ${err}`);
  }

  const data = await resp.json();
  return data.stores ?? [];
}

// ── 3. Get delivery quotes for a store ────────────────────────────────────────
/**
 * Fetches live delivery/pickup quotes for a specific store.
 * Returns array of quote objects with fee, ETA, and quote_id.
 */
export async function getStoreQuotes({ storeId, address, latitude, longitude, apiKey }) {
  const params = new URLSearchParams({
    store_id:        storeId,
    user_latitude:   latitude,
    user_longitude:  longitude,
    user_street_num:  extractStreetNum(address?.line1 ?? ""),
    user_street_name: extractStreetName(address?.line1 ?? ""),
    user_city:        address?.city ?? "",
    user_state:       address?.region ?? "",
    user_zipcode:     address?.postalCode ?? "",
    user_country:     "US",
  });

  const resp = await fetch(`${BASE}/groceries/details/quotes?${params}`, {
    headers: headers(apiKey),
  });

  if (!resp.ok) return [];
  const data = await resp.json();
  return data.quotes ?? [];
}

// ── 4. Create cart ─────────────────────────────────────────────────────────────
/**
 * Locks in a cart with chosen products + quote. Returns cart_id.
 *
 * @param {Object} params
 * @param {string} params.quoteId      - quote_id from getStoreQuotes()
 * @param {Array}  params.cartItems    - [{ product_id, quantity }]
 * @param {string} params.fulfillment  - "delivery" | "pickup"
 * @param {Object} params.customer     - { name, email, phone }
 * @param {Object} params.deliveryAddress
 * @param {string} params.apiKey
 */
export async function createCart({
  quoteId,
  cartItems,
  fulfillment = "delivery",
  customer,
  deliveryAddress,
  apiKey,
}) {
  const body = {
    quote_id:    quoteId,
    fulfillment,
    cart_items:  cartItems.map((ci) => ({
      product_id: ci.productId,
      quantity:   Math.max(1, ci.quantity ?? 1),
    })),
    customer_firstname:  customer?.firstName ?? "",
    customer_lastname:   customer?.lastName  ?? "",
    customer_email:      customer?.email     ?? "",
    customer_phone:      customer?.phone     ?? "",
    ...(fulfillment === "delivery" && deliveryAddress && {
      delivery_street_num:  extractStreetNum(deliveryAddress.line1 ?? ""),
      delivery_street_name: extractStreetName(deliveryAddress.line1 ?? ""),
      delivery_city:        deliveryAddress.city    ?? "",
      delivery_state:       deliveryAddress.region  ?? "",
      delivery_zipcode:     deliveryAddress.postalCode ?? "",
      delivery_country:     "US",
      delivery_notes:       deliveryAddress.deliveryNotes ?? "",
    }),
  };

  const resp = await fetch(`${BASE}/cart/create`, {
    method: "POST",
    headers: { ...headers(apiKey), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`MealMe createCart ${resp.status}: ${err}`);
  }

  const data = await resp.json();
  return {
    cartId:       data.cart_id,
    subtotal:     data.subtotal_cents  ? data.subtotal_cents  / 100 : null,
    deliveryFee:  data.delivery_fee_cents ? data.delivery_fee_cents / 100 : null,
    total:        data.total_cents     ? data.total_cents     / 100 : null,
    etaMinutes:   data.estimated_delivery_minutes ?? null,
  };
}

// ── 5. Finalize order (payment) ───────────────────────────────────────────────
/**
 * Places the order. Called from client after payment method is confirmed.
 * This is the last step — money moves here.
 */
export async function finalizeOrder({ cartId, paymentMethodId, tipCents = 0, apiKey }) {
  const body = {
    cart_id:           cartId,
    payment_method_id: paymentMethodId,
    tip_cents:         tipCents,
  };

  const resp = await fetch(`${BASE}/order/finalize`, {
    method: "POST",
    headers: { ...headers(apiKey), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`MealMe finalizeOrder ${resp.status}: ${err}`);
  }

  return await resp.json();
}

// ── Shape helpers ─────────────────────────────────────────────────────────────
/**
 * Transforms raw MealMe store results into a cleaner shape for the Ounje API response.
 * Returns top N store options with matched products + estimated totals.
 */
export function shapeStoreOptions(rawStores, maxStores = 4) {
  return rawStores
    .slice(0, maxStores)
    .map((store) => {
      const products = (store.cart ?? store.products ?? []).map((p) => ({
        productId:    p.product_id ?? p._id,
        name:         p.name,
        brand:        p.brand ?? null,
        imageUrl:     p.main_photo ?? p.image ?? null,
        price:        p.price != null ? p.price / 100 : null,   // MealMe returns cents
        unit:         p.unit_size ?? p.unit ?? null,
        quantity:     p.quantity ?? 1,
        queryMatch:   p.query ?? null,
        inStock:      p.is_available ?? true,
      }));

      const subtotal = products.reduce((sum, p) => sum + (p.price ?? 0) * p.quantity, 0);

      return {
        storeId:       store._id,
        storeName:     store.name,
        logoUrl:       store.logo_photos?.[0] ?? null,
        address:       store.address?.street_addr
                         ? `${store.address.street_addr}, ${store.address.city}`
                         : null,
        miles:         store.miles ?? null,
        rating:        store.weighted_rating_value ?? null,
        isOpen:        store.is_open ?? true,
        deliveryEnabled: store.delivery_enabled ?? true,
        pickupEnabled:   store.pickup_enabled   ?? false,
        matchedCount:  products.filter((p) => p.inStock).length,
        totalItems:    products.length,
        products,
        subtotalEstimate: subtotal,
        quoteIds:      (store.quotes ?? []).map((q) => q.quote_id ?? q),
      };
    })
    .filter((s) => s.matchedCount > 0)
    .sort((a, b) => b.matchedCount - a.matchedCount || a.subtotalEstimate - b.subtotalEstimate);
}

// ── String utilities ──────────────────────────────────────────────────────────
const STRIP = new Set([
  "fresh","dried","frozen","canned","organic","raw","cooked","ground","whole",
  "large","medium","small","extra","ripe","boneless","skinless","peeled",
  "chopped","sliced","diced","minced","grated","shredded","divided","softened",
  "melted","room","temperature","optional",
]);

export function normalizeIngredientName(name) {
  return name
    .toLowerCase()
    .split(/\s+/)
    .filter((w) => !STRIP.has(w) && w.length > 1)
    .join(" ")
    .trim();
}

function extractStreetNum(line1) {
  return line1.match(/^\d+/)?.[0] ?? "";
}

function extractStreetName(line1) {
  return line1.replace(/^\d+\s*/, "").trim();
}
