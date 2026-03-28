import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';
import { buildCanonicalRecipePayload } from '../lib/recipe-detail-utils.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, '../.env') });

const SUPABASE_URL = process.env.SUPABASE_URL ?? '';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? '';

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error('Missing SUPABASE_URL or SUPABASE_ANON_KEY');
  process.exit(1);
}

const headers = {
  apikey: SUPABASE_ANON_KEY,
  Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
};

async function fetchBatch(offset, limit) {
  const select = [
    'id',
    'ingredients_text',
    'instructions_text',
    'servings_text',
    'ingredients_json',
    'steps_json',
    'servings_count',
  ].join(',');
  const url = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(select)}&order=updated_at.desc.nullslast,id.asc&limit=${limit}&offset=${offset}`;
  const response = await fetch(url, { headers });
  const data = await response.json().catch(() => []);
  if (!response.ok) {
    throw new Error(data?.message ?? data?.error ?? 'Failed to fetch recipes for canonical backfill');
  }
  return Array.isArray(data) ? data : [];
}

async function updateRecipe(id, payload) {
  const url = `${SUPABASE_URL}/rest/v1/recipes?id=eq.${encodeURIComponent(id)}`;
  const response = await fetch(url, {
    method: 'PATCH',
    headers: {
      ...headers,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(data?.message ?? data?.error ?? `Failed to update recipe ${id}`);
  }
}

function shouldUpdate(recipe, payload) {
  if (!Array.isArray(recipe.ingredients_json) || recipe.ingredients_json.length === 0) return true;
  if (!Array.isArray(recipe.steps_json) || recipe.steps_json.length === 0) return true;
  if (recipe.servings_count == null && payload.servings_count != null) return true;
  return false;
}

async function main() {
  const limit = 100;
  let offset = 0;
  let scanned = 0;
  let updated = 0;

  while (true) {
    const recipes = await fetchBatch(offset, limit);
    if (recipes.length === 0) break;

    for (const recipe of recipes) {
      scanned += 1;
      const payload = buildCanonicalRecipePayload(recipe);
      if (!shouldUpdate(recipe, payload)) continue;
      await updateRecipe(recipe.id, payload);
      updated += 1;
      if (updated % 50 === 0) {
        console.log(`Updated ${updated} recipes...`);
      }
    }

    offset += recipes.length;
  }

  console.log(JSON.stringify({ scanned, updated }, null, 2));
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
