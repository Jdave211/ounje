import assert from "node:assert/strict";

const {
  guaranteeRecipeDisplayMacros,
  hasCompleteDisplayMacros,
} = await import("../lib/recipe-ingestion.js");

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const DRY_RUN = process.argv.includes("--dry-run");
const LIMIT = Math.max(1, Math.min(Number(process.env.MACRO_BACKFILL_LIMIT ?? 500), 2000));

assert(SUPABASE_URL, "SUPABASE_URL is required");
assert(SUPABASE_SERVICE_ROLE_KEY, "SUPABASE_SERVICE_ROLE_KEY is required");

async function supabaseRequest(pathname, { method = "GET", body = null, prefer = "return=representation" } = {}) {
  const response = await fetch(`${SUPABASE_URL}${pathname}`, {
    method,
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      Prefer: prefer,
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(`${method} ${pathname} failed: ${response.status} ${text}`);
  }
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

function numberOrNull(value) {
  const number = Number(value);
  return value !== null
    && value !== undefined
    && String(value).trim() !== ""
    && Number.isFinite(number)
    ? number
    : null;
}

function isFiniteMacroValue(value) {
  return value !== null
    && value !== undefined
    && String(value).trim() !== ""
    && Number.isFinite(Number(value));
}

function macroPatch(existing, candidate) {
  const patch = {};
  for (const field of ["calories_kcal", "protein_g", "carbs_g", "fat_g"]) {
    if (!isFiniteMacroValue(existing[field]) && isFiniteMacroValue(candidate[field])) {
      patch[field] = Number(candidate[field]);
    }
  }
  if (!String(existing.est_calories_text ?? "").trim() && String(candidate.est_calories_text ?? "").trim()) {
    patch.est_calories_text = String(candidate.est_calories_text).trim();
  }
  return patch;
}

const select = [
  "id",
  "title",
  "description",
  "category",
  "recipe_type",
  "main_protein",
  "cook_method",
  "servings_text",
  "servings_count",
  "est_calories_text",
  "calories_kcal",
  "protein_g",
  "carbs_g",
  "fat_g",
  "ingredients_json",
  "steps_json",
].join(",");

const rows = await supabaseRequest(
  `/rest/v1/user_import_recipes?select=${encodeURIComponent(select)}&or=(calories_kcal.is.null,protein_g.is.null,carbs_g.is.null,fat_g.is.null)&order=updated_at.desc&limit=${LIMIT}`
);

let patched = 0;
let skipped = 0;

for (const row of Array.isArray(rows) ? rows : []) {
  const guaranteed = await guaranteeRecipeDisplayMacros({
    ...row,
    calories_kcal: numberOrNull(row.calories_kcal),
    protein_g: numberOrNull(row.protein_g),
    carbs_g: numberOrNull(row.carbs_g),
    fat_g: numberOrNull(row.fat_g),
    ingredients: Array.isArray(row.ingredients_json) ? row.ingredients_json : [],
    steps: Array.isArray(row.steps_json) ? row.steps_json : [],
  });
  if (!hasCompleteDisplayMacros(guaranteed)) {
    skipped += 1;
    continue;
  }
  const patch = macroPatch(row, guaranteed);
  if (!Object.keys(patch).length) {
    skipped += 1;
    continue;
  }
  if (!DRY_RUN) {
    await supabaseRequest(
      `/rest/v1/user_import_recipes?id=eq.${encodeURIComponent(row.id)}`,
      { method: "PATCH", body: patch, prefer: "return=minimal" }
    );
  }
  patched += 1;
  console.log(`${DRY_RUN ? "would patch" : "patched"} ${row.id}: ${JSON.stringify(patch)}`);
}

console.log(JSON.stringify({ dryRun: DRY_RUN, scanned: Array.isArray(rows) ? rows.length : 0, patched, skipped }, null, 2));
