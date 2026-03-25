/**
 * Kroger Developer API integration
 * Docs: https://developer.kroger.com/api-products/api/product-api
 *
 * Phase 1: Product search + cart deep-link (no user OAuth needed)
 * Phase 2: Full cart add (requires user OAuth — scaffold ready below)
 *
 * Kroger family: Kroger, Ralphs, Fred Meyer, King Soopers, Smith's,
 *                Fry's, QFC, City Market, Harris Teeter, Dillons, etc.
 */

const KROGER_BASE   = "https://api.kroger.com/v1";
const TOKEN_URL     = `${KROGER_BASE}/connect/oauth2/token`;
const PRODUCTS_URL  = `${KROGER_BASE}/products`;

// ── Client credentials token (catalog search — no user login needed) ──────────
let _clientToken = null;
let _clientTokenExpiry = 0;

async function getClientToken(clientId, clientSecret) {
  if (_clientToken && Date.now() < _clientTokenExpiry - 30_000) return _clientToken;

  const creds = Buffer.from(`${clientId}:${clientSecret}`).toString("base64");
  const resp = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      Authorization: `Basic ${creds}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials&scope=product.compact",
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`Kroger token error ${resp.status}: ${err}`);
  }

  const data = await resp.json();
  _clientToken = data.access_token;
  _clientTokenExpiry = Date.now() + data.expires_in * 1000;
  return _clientToken;
}

// ── Product search ────────────────────────────────────────────────────────────
/**
 * Search Kroger's catalog for a single ingredient.
 * Returns the top match (name, brand, price, upc, imageUrl).
 */
export async function searchKrogerProduct({ term, locationId, clientId, clientSecret }) {
  const token = await getClientToken(clientId, clientSecret);

  const params = new URLSearchParams({
    "filter.term": term,
    "filter.limit": "3",
    ...(locationId && { "filter.locationId": locationId }),
  });

  const resp = await fetch(`${PRODUCTS_URL}?${params}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`Kroger products ${resp.status}: ${err}`);
  }

  const data = await resp.json();
  const products = data.data ?? [];
  if (!products.length) return null;

  const p = products[0];
  const price = p.items?.[0]?.price?.regular ?? null;
  const image = p.images?.find((i) => i.perspective === "front")?.sizes?.find((s) => s.size === "medium")?.url ?? null;

  return {
    upc: p.upc,
    name: p.description,
    brand: p.brand ?? null,
    price,
    imageUrl: image,
    aisleLocation: p.aisleLocations?.[0]?.description ?? null,
  };
}

/**
 * Build a Kroger deep-link URL for a search query (fallback when no user OAuth).
 * Opens the Kroger website search — user adds items manually.
 */
export function buildKrogerSearchUrl(items) {
  const query = items
    .slice(0, 8)
    .map((i) => i.name)
    .join(" ");
  const encoded = encodeURIComponent(query);
  return `https://www.kroger.com/search?query=${encoded}`;
}

// ── Nearest store lookup ──────────────────────────────────────────────────────
export async function findNearestKrogerStore({ postalCode, clientId, clientSecret }) {
  const token = await getClientToken(clientId, clientSecret);
  const params = new URLSearchParams({
    "filter.zipCode.near": postalCode,
    "filter.limit": "1",
    "filter.chain": "KROGER",
  });

  const resp = await fetch(`${KROGER_BASE}/locations?${params}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
  });

  if (!resp.ok) return null;
  const data = await resp.json();
  return data.data?.[0]?.locationId ?? null;
}

// ── Phase 2 scaffold: user-authenticated cart add ─────────────────────────────
// Requires Kroger user OAuth token (auth_code flow, scope: cart.basic:write)
// Not wired to a route yet — ready when user auth is added.
export async function addToKrogerCart({ items, userAccessToken, locationId }) {
  if (!userAccessToken) throw new Error("Kroger user access token required for cart operations");

  const cartItems = items.slice(0, 50).map((item) => ({
    upc: item.upc,
    quantity: Math.max(1, Math.round(item.amount || 1)),
    modality: "PICKUP",
  }));

  const resp = await fetch(`${KROGER_BASE}/cart/add`, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${userAccessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ items: cartItems }),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`Kroger cart ${resp.status}: ${err}`);
  }

  return { success: true, locationId };
}
