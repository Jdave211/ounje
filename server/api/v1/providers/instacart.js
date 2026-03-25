/**
 * Instacart Developer Platform (IDP) integration
 * Docs: https://docs.instacart.com/developer_platform_api/
 *
 * Creates a hosted "shoppable" recipe page from a list of GroceryItems.
 * The user lands on Instacart's own UI to pick products and checkout.
 * No payment data ever touches our server.
 */

const INSTACART_BASE = "https://connect.instacart.com";

/**
 * Normalize a GroceryItem into an Instacart line_item object.
 * Instacart expects clean ingredient names (no adjectives like "fresh" or "large").
 */
function toLineItem(item) {
  return {
    name: normalizeIngredientName(item.name),
    quantity: item.amount > 0 ? item.amount : 1,
    unit: normalizeUnit(item.unit),
    display_text: buildDisplayText(item),
  };
}

function normalizeIngredientName(name) {
  return name
    .toLowerCase()
    .replace(/\b(fresh|large|small|medium|organic|frozen|dried|chopped|sliced|diced|minced|grated|shredded)\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeUnit(unit) {
  const map = {
    tbsp: "tablespoon", tablespoons: "tablespoon", tablespoon: "tablespoon",
    tsp: "teaspoon",   teaspoons: "teaspoon",     teaspoon: "teaspoon",
    c: "cup", cups: "cup",
    oz: "ounce", ounces: "ounce",
    lb: "pound", lbs: "pound", pounds: "pound",
    g: "gram", grams: "gram",
    kg: "kilogram",
    ml: "milliliter", mls: "milliliter",
    l: "liter", liters: "liter",
    pcs: "piece", pieces: "piece", piece: "piece",
    cloves: "clove", clove: "clove",
  };
  const key = (unit || "").toLowerCase().trim();
  return map[key] || key || "unit";
}

function buildDisplayText(item) {
  const amt = item.amount > 0 ? item.amount : "";
  const unit = item.unit ? ` ${item.unit}` : "";
  return `${amt}${unit} ${item.name}`.trim();
}

/**
 * Creates an Instacart shoppable link for a recipe.
 *
 * @param {object} params
 * @param {string} params.recipeTitle   - e.g. "Party Jollof Rice"
 * @param {string} [params.recipeImageUrl] - hero image URL
 * @param {string} [params.recipeLinkbackUrl] - deep-link back to Ounje recipe
 * @param {Array}  params.items         - GroceryItem[]
 * @param {string} params.apiKey        - Instacart partner API key
 * @returns {Promise<{url: string, expiresAt: string}>}
 */
export async function createInstacartShoppableLink({
  recipeTitle,
  recipeImageUrl,
  recipeLinkbackUrl,
  items,
  apiKey,
}) {
  if (!apiKey) throw new Error("INSTACART_API_KEY not configured");
  if (!items?.length) throw new Error("No grocery items provided");

  const lineItems = items.map(toLineItem).filter((li) => li.name.length > 1);

  const body = {
    title: recipeTitle || "Recipe Ingredients",
    link_type: "recipe",
    ...(recipeImageUrl && { image_url: recipeImageUrl }),
    landing_page_configuration: {
      ...(recipeLinkbackUrl && { partner_linkback_url: recipeLinkbackUrl }),
      enable_pantry_items: true,
    },
    line_items: lineItems,
  };

  const resp = await fetch(`${INSTACART_BASE}/idp/v1/products/products_link`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`Instacart API ${resp.status}: ${err}`);
  }

  const data = await resp.json();
  return {
    url: data.products_link_url,
    expiresAt: data.expires_at ?? null,
  };
}
