import "server-only";

import { cache } from "react";
import { parseRecipeSnapshot, RecipeSnapshotError, safeHTTPURL } from "./recipe-schema.js";

const SHARE_ID_PATTERN = /^[A-Za-z0-9_-]{12}$/;
const TRANSIENT_STATUS_CODES = new Set([502, 503, 504, 520]);

export class ShareDataError extends Error {
  constructor(kind, message, options = {}) {
    super(message, options);
    this.name = "ShareDataError";
    this.kind = kind;
  }
}

export function isValidShareID(value) {
  return SHARE_ID_PATTERN.test(String(value ?? "").trim());
}

function serverConfig(environment) {
  const supabaseURL = String(environment.SUPABASE_URL ?? "").trim().replace(/\/+$/, "");
  const secretKey = String(environment.SUPABASE_SECRET_KEY ?? "").trim();
  const serviceRoleKey = String(environment.SUPABASE_SERVICE_ROLE_KEY ?? "").trim();
  const apiKey = secretKey || serviceRoleKey;
  if (!supabaseURL || !apiKey) {
    throw new ShareDataError("configuration", "Recipe sharing is not configured.");
  }
  return { supabaseURL, apiKey, usesLegacyJWT: !secretKey };
}

function requestHeaders({ apiKey, usesLegacyJWT }) {
  return {
    Accept: "application/json",
    apikey: apiKey,
    ...(usesLegacyJWT ? { Authorization: `Bearer ${apiKey}` } : {}),
  };
}

function normalizedIngredientImageKey(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function singularIngredientKey(value) {
  const words = String(value ?? "").split(/\s+/).filter(Boolean);
  const last = words.at(-1);
  if (!last) return "";

  if (last.endsWith("ies") && last.length > 3) words[words.length - 1] = `${last.slice(0, -3)}y`;
  else if (last.endsWith("oes") && last.length > 3) words[words.length - 1] = last.slice(0, -2);
  else if (last.endsWith("s") && !last.endsWith("ss") && last.length > 2) words[words.length - 1] = last.slice(0, -1);
  return words.join(" ");
}

export function ingredientImageLookupKeys(value) {
  const normalized = normalizedIngredientImageKey(value);
  if (!normalized) return [];

  const keys = [];
  const append = (candidate) => {
    const key = normalizedIngredientImageKey(candidate);
    if (key && !keys.includes(key)) keys.push(key);
  };

  append(normalized);
  append(normalized.replaceAll("chilli", "chili"));
  append(singularIngredientKey(normalized));

  const phraseAliases = {
    "unsalted butter": "butter",
    "salted butter": "butter",
    "melted butter": "butter",
    "softened butter": "butter",
    "caster sugar": "sugar",
    "granulated sugar": "sugar",
    "brown sugar": "sugar",
    "vanilla extract": "vanilla",
    "vanilla paste": "vanilla",
    "lemon juice": "lemon",
    "fresh lemon juice": "lemon",
    "lemon zest": "lemon",
    "lime juice": "lime",
    "fresh lime juice": "lime",
    "lime zest": "lime",
    "orange juice": "orange",
    "orange zest": "orange",
    "tilapia fish": "tilapia",
    "canola oil": "vegetable oil",
    "prawns": "shrimp",
    "bouillon cube": "bouillon",
    "all purpose seasoning": "seasoning",
  };

  for (const [needle, alias] of Object.entries(phraseAliases)) {
    if (normalized.includes(needle)) append(alias);
  }

  const descriptorTokens = new Set([
    "active", "boneless", "chopped", "cold", "coarsely", "crushed", "divided",
    "dried", "dry", "finely", "fresh", "freshly", "grated", "granulated", "ground",
    "hot", "large", "medium", "melted", "minced", "optional", "peeled", "raw",
    "salted", "skinless", "sliced", "small", "softened", "unsalted", "warm", "whole",
  ]);
  const tokens = normalized.split(/\s+/).filter(Boolean);
  const stripped = tokens.filter((token) => !descriptorTokens.has(token)).join(" ");
  append(stripped);
  append(singularIngredientKey(stripped));

  const beforePurpose = normalized.split(/\bfor\b/)[0]?.trim();
  if (beforePurpose && beforePurpose !== normalized) append(beforePurpose);

  if (tokens.includes("butter")) append("butter");
  if (tokens.includes("sugar")) append("sugar");
  if (tokens.includes("milk")) append("milk");
  if (tokens.includes("yeast")) append("yeast");
  if (tokens.includes("lemon") && tokens.some((token) => ["juice", "zest", "wedge", "wedges", "slice", "slices"].includes(token))) {
    append("lemon");
  }
  if (tokens.includes("lime") && tokens.some((token) => ["juice", "zest", "wedge", "wedges", "slice", "slices"].includes(token))) {
    append("lime");
  }

  return keys;
}

function postgrestIn(values) {
  return `in.(${values.map((value) => `"${value.replaceAll('"', '\\"')}"`).join(",")})`;
}

export async function hydrateRecipeIngredientImages(recipe, options = {}) {
  const missingIngredients = (recipe?.ingredients ?? []).filter((ingredient) => ingredient.name && !ingredient.imageURL);
  if (!missingIngredients.length) return recipe;

  const environment = options.environment ?? process.env;
  const fetchImplementation = options.fetchImplementation ?? fetch;
  let config;
  try {
    config = serverConfig(environment);
  } catch {
    return recipe;
  }

  const lookupKeys = [...new Set(missingIngredients.flatMap((ingredient) => ingredientImageLookupKeys(ingredient.name)))].slice(0, 120);
  if (!lookupKeys.length) return recipe;

  const endpoint = new URL(`${config.supabaseURL}/rest/v1/ingredients`);
  endpoint.searchParams.set("select", "normalized_name,display_name,default_image_url");
  endpoint.searchParams.set("normalized_name", postgrestIn(lookupKeys));
  endpoint.searchParams.set("default_image_url", "not.is.null");
  endpoint.searchParams.set("limit", "200");

  try {
    const response = await fetchImplementation(endpoint, {
      method: "GET",
      headers: requestHeaders(config),
      cache: "force-cache",
      next: { revalidate: 3600 },
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) return recipe;

    const rows = await response.json();
    if (!Array.isArray(rows) || !rows.length) return recipe;

    const imageByKey = new Map();
    for (const row of rows) {
      const imageURL = safeHTTPURL(row?.default_image_url);
      if (!imageURL) continue;
      for (const value of [row?.normalized_name, row?.display_name]) {
        const key = normalizedIngredientImageKey(value);
        if (key && !imageByKey.has(key)) imageByKey.set(key, imageURL);
      }
    }

    return {
      ...recipe,
      ingredients: recipe.ingredients.map((ingredient) => {
        if (ingredient.imageURL) return ingredient;
        const imageURL = ingredientImageLookupKeys(ingredient.name).map((key) => imageByKey.get(key)).find(Boolean) ?? null;
        return imageURL ? { ...ingredient, imageURL } : ingredient;
      }),
    };
  } catch {
    return recipe;
  }
}

export async function fetchActiveShareRow(shareID, options = {}) {
  const normalizedID = String(shareID ?? "").trim();
  if (!isValidShareID(normalizedID)) return null;

  const environment = options.environment ?? process.env;
  const fetchImplementation = options.fetchImplementation ?? fetch;
  const config = serverConfig(environment);
  const endpoint = new URL(`${config.supabaseURL}/rest/v1/recipe_share_links`);
  endpoint.searchParams.set("select", "share_id,status,snapshot_json");
  endpoint.searchParams.set("share_id", `eq.${normalizedID}`);
  endpoint.searchParams.set("status", "eq.active");
  endpoint.searchParams.set("limit", "1");

  for (let attempt = 0; attempt < 2; attempt += 1) {
    let response;
    try {
      response = await fetchImplementation(endpoint, {
        method: "GET",
        headers: requestHeaders(config),
        cache: "no-store",
        signal: AbortSignal.timeout(7000),
      });
    } catch (error) {
      if (attempt === 0) continue;
      throw new ShareDataError("upstream", "Recipe data could not be reached.", { cause: error });
    }

    if (response.ok) {
      let rows;
      try {
        rows = await response.json();
      } catch (error) {
        throw new ShareDataError("upstream", "Recipe data returned an invalid response.", { cause: error });
      }
      return Array.isArray(rows) ? rows[0] ?? null : null;
    }

    if (attempt === 0 && TRANSIENT_STATUS_CODES.has(response.status)) continue;
    throw new ShareDataError("upstream", `Recipe data request failed with status ${response.status}.`);
  }

  return null;
}

export async function resolveShareRecipeOnce(shareID, options = {}) {
  const normalizedID = String(shareID ?? "").trim();
  if (!isValidShareID(normalizedID)) return { kind: "not_found" };

  const row = await fetchActiveShareRow(normalizedID, options);
  if (!row || row.status !== "active") return { kind: "not_found" };

  try {
    const parsedRecipe = parseRecipeSnapshot(row.snapshot_json);
    return {
      kind: "ready",
      shareID: normalizedID,
      recipe: options.hydrateIngredientImages === false
        ? parsedRecipe
        : await hydrateRecipeIngredientImages(parsedRecipe, options),
    };
  } catch (error) {
    if (error instanceof RecipeSnapshotError) return { kind: "malformed" };
    throw error;
  }
}

export const resolveShareRecipe = cache(resolveShareRecipeOnce);

export function websiteBaseURL(environment = process.env) {
  const explicit = String(environment.OUNJE_WEBSITE_URL ?? "").trim();
  const vercelProduction = String(environment.VERCEL_PROJECT_PRODUCTION_URL ?? "").trim();
  const vercelDeployment = String(environment.VERCEL_URL ?? "").trim();
  const candidate = explicit || vercelProduction || vercelDeployment || "http://localhost:3000";
  const withProtocol = /^https?:\/\//i.test(candidate) ? candidate : `https://${candidate}`;
  return new URL(withProtocol.replace(/\/+$/, ""));
}

export function sharePageURL(shareID, environment = process.env) {
  return new URL(`/r/${encodeURIComponent(shareID)}`, websiteBaseURL(environment)).toString();
}
