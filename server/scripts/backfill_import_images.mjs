#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { maybeGenerateImportedRecipeImage } from "../lib/recipe-ingestion.js";

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

async function main() {
  const rows = await fetchRows(
    "user_import_recipes",
    "id,title,recipe_type,category,main_protein,cuisine_tags,occasion_tags,hero_image_url,discover_card_image_url,source,source_platform,recipe_url,original_recipe_url",
    {
      order: ["created_at.desc"],
      limit: 500,
    }
  );

  const missingImageRows = rows.filter((row) => !cleanURL(row.hero_image_url ?? row.discover_card_image_url ?? null));
  console.log(`Found ${missingImageRows.length} imported recipes without hero/card images.`);

  let updated = 0;
  for (const row of missingImageRows) {
    const recipeDetail = {
      id: row.id,
      title: row.title,
      recipe_type: row.recipe_type,
      category: row.category,
      main_protein: row.main_protein,
      cuisine_tags: Array.isArray(row.cuisine_tags) ? row.cuisine_tags : [],
      occasion_tags: Array.isArray(row.occasion_tags) ? row.occasion_tags : [],
      hero_image_url: cleanURL(row.hero_image_url ?? null),
      discover_card_image_url: cleanURL(row.discover_card_image_url ?? null),
    };

    const source = {
      source_type: cleanText(row.source_platform ?? row.source ?? "direct_input").toLowerCase(),
      title: row.title,
      recipe_type: row.recipe_type,
      category: row.category,
      main_protein: row.main_protein,
      cuisine_tags: Array.isArray(row.cuisine_tags) ? row.cuisine_tags : [],
      occasion_tags: Array.isArray(row.occasion_tags) ? row.occasion_tags : [],
      source_url: cleanURL(row.original_recipe_url ?? row.recipe_url ?? null),
    };

    try {
      const generated = await maybeGenerateImportedRecipeImage(recipeDetail, source, { accessToken: null });
      const hero = cleanURL(generated?.hero_image_url ?? null);
      if (!hero) {
        console.log(`- ${row.id} ${row.title}: no image generated`);
        continue;
      }
      await patchRow("user_import_recipes", row.id, {
        hero_image_url: hero,
        discover_card_image_url: cleanURL(generated?.discover_card_image_url ?? hero) ?? hero,
      });
      console.log(`- ${row.id} ${row.title}: updated`);
      updated += 1;
    } catch (error) {
      console.log(`- ${row.id} ${row.title}: failed -> ${error.message}`);
    }
  }

  console.log(`Backfill complete. Updated ${updated} rows.`);
}

await main();
