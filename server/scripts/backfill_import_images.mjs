#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, "../.env") });

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_ANON_KEY in server/.env");
  process.exit(1);
}

const HEADERS = {
  apikey: SUPABASE_ANON_KEY,
  Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
  Accept: "application/json",
  "Content-Type": "application/json",
};

function cleanText(value) {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

function cleanURL(value) {
  const text = cleanText(value);
  return text ? text : null;
}

async function fetchRows(table, select, { filters = [], order = [], limit = 1000, offset = 0 } = {}) {
  let url = `${SUPABASE_URL}/rest/v1/${table}?select=${encodeURIComponent(select)}&limit=${limit}&offset=${offset}`;
  for (const filter of filters) {
    if (filter) url += `&${filter}`;
  }
  for (const clause of order) {
    if (clause) url += `&order=${clause}`;
  }

  const response = await fetch(url, { headers: HEADERS });
  const data = await response.json().catch(() => []);
  if (!response.ok) {
    throw new Error(`${table} fetch failed: ${data?.message ?? data?.error ?? JSON.stringify(data).slice(0, 200)}`);
  }
  return Array.isArray(data) ? data : [];
}

async function patchRow(table, id, payload) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/${table}?id=eq.${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: HEADERS,
    body: JSON.stringify(payload),
  });
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(`${table} patch failed for ${id}: ${data?.message ?? data?.error ?? JSON.stringify(data).slice(0, 200)}`);
  }
  return data;
}

async function patchSavedRecipeRow(userID, recipeID, payload) {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/saved_recipes?user_id=eq.${encodeURIComponent(userID)}&recipe_id=eq.${encodeURIComponent(recipeID)}`,
    {
      method: "PATCH",
      headers: HEADERS,
      body: JSON.stringify(payload),
    }
  );
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(
      `saved_recipes patch failed for ${userID}/${recipeID}: ${data?.message ?? data?.error ?? JSON.stringify(data).slice(0, 200)}`
    );
  }
  return data;
}

function isEphemeralSocialURL(value) {
  const cleaned = cleanURL(value);
  if (!cleaned) return false;

  try {
    const host = new URL(cleaned).host.toLowerCase();
    return host.includes("cdninstagram") || host.includes("instagram") || host.includes("fbcdn");
  } catch {
    return false;
  }
}

function preferredImagePair(row) {
  const hero = cleanURL(row.hero_image_url ?? null);
  const card = cleanURL(row.discover_card_image_url ?? null);
  const preferredHero = hero ?? card ?? null;
  const preferredCard = card ?? hero ?? null;
  return {
    hero_image_url: preferredHero,
    discover_card_image_url: preferredCard,
  };
}

async function main() {
  const importRows = await fetchRows(
    "user_import_recipes",
    "id,title,recipe_type,category,main_protein,cuisine_tags,occasion_tags,hero_image_url,discover_card_image_url,source,source_platform,recipe_url,original_recipe_url",
    {
      order: ["created_at.desc"],
      limit: 1500,
    }
  );

  console.log(`Loaded ${importRows.length} imported recipes.`);

  let canonicalUpdated = 0;
  for (const row of importRows) {
    const preferred = preferredImagePair(row);
    const canonicalNeedsMirror =
      cleanURL(row.hero_image_url ?? null) !== preferred.hero_image_url ||
      cleanURL(row.discover_card_image_url ?? null) !== preferred.discover_card_image_url;

    if (!canonicalNeedsMirror || !preferred.hero_image_url) {
      continue;
    }

    try {
      await patchRow("user_import_recipes", row.id, preferred);
      canonicalUpdated += 1;
      console.log(`- canonical ${row.id} ${row.title}: mirrored source image fields`);
    } catch (error) {
      console.log(`- canonical ${row.id} ${row.title}: failed -> ${error.message}`);
    }
  }

  const importedByID = new Map(
    importRows.map((row) => [row.id, { row, preferred: preferredImagePair(row) }])
  );

  const savedRows = await fetchRows(
    "saved_recipes",
    "user_id,recipe_id,title,hero_image_url,discover_card_image_url",
    {
      filters: ["recipe_id=like.uir_%"],
      order: ["saved_at.desc"],
      limit: 3000,
    }
  );

  console.log(`Loaded ${savedRows.length} saved imported recipe snapshots.`);

  let savedUpdated = 0;
  for (const savedRow of savedRows) {
    const canonical = importedByID.get(savedRow.recipe_id);
    if (!canonical?.preferred.hero_image_url) continue;

    const snapshotHero = cleanURL(savedRow.hero_image_url ?? null);
    const snapshotCard = cleanURL(savedRow.discover_card_image_url ?? null);
    const snapshotNeedsHydration =
      !snapshotHero ||
      !snapshotCard ||
      isEphemeralSocialURL(snapshotHero) ||
      isEphemeralSocialURL(snapshotCard);

    if (!snapshotNeedsHydration) {
      continue;
    }

    try {
      await patchSavedRecipeRow(savedRow.user_id, savedRow.recipe_id, canonical.preferred);
      savedUpdated += 1;
      console.log(`- saved ${savedRow.recipe_id} ${savedRow.title ?? canonical.row.title}: hydrated from canonical import`);
    } catch (error) {
      console.log(`- saved ${savedRow.recipe_id} ${savedRow.title ?? canonical.row.title}: failed -> ${error.message}`);
    }
  }

  console.log(`Backfill complete. Updated ${canonicalUpdated} canonical import rows and ${savedUpdated} saved snapshots.`);
}

await main();
