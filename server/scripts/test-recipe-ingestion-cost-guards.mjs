import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";

const {
  RECIPE_GATE_MODEL,
  RECIPE_IMPORT_COMPLETION_MODEL,
  RECIPE_INGESTION_MODEL,
  RECIPE_SEARCH_SYNTHESIS_MODEL,
  isCanonicalCacheableSource,
  isOpenAITerminalModelError,
  isResumableIngestionJob,
  recipeNeedsCompletionPass,
  recipeNeedsSecondaryFill,
  shouldProcessImportInline,
} = await import("../lib/recipe-ingestion.js");

assert.equal(RECIPE_GATE_MODEL, "gpt-5-nano");
assert.equal(RECIPE_IMPORT_COMPLETION_MODEL, "gpt-5-nano");
assert.equal(RECIPE_SEARCH_SYNTHESIS_MODEL, "gpt-5-nano");
assert.equal(RECIPE_INGESTION_MODEL, "gpt-4o-mini");

assert.equal(shouldProcessImportInline({ source_url: "https://vt.tiktok.com/example" }), false);
assert.equal(shouldProcessImportInline({ source_url: "https://vt.tiktok.com/example", process_inline: false }), false);
assert.equal(shouldProcessImportInline({ source_url: "https://vt.tiktok.com/example", process_inline: true }), false);
process.env.OUNJE_ALLOW_INLINE_RECIPE_IMPORT = "1";
process.env.NODE_ENV = "development";
assert.equal(shouldProcessImportInline({ source_url: "https://vt.tiktok.com/example", process_inline: true }), true);
process.env.NODE_ENV = "production";
assert.equal(shouldProcessImportInline({ source_url: "https://vt.tiktok.com/example", process_inline: true }), false);

assert.equal(isCanonicalCacheableSource("tiktok", "https://vt.tiktok.com/example"), true);
assert.equal(isCanonicalCacheableSource("instagram", "https://www.instagram.com/reel/example"), true);
assert.equal(isCanonicalCacheableSource("web", "https://example.com/recipe"), false);

assert.equal(isOpenAITerminalModelError({ status: 400, message: "The model does not exist" }), true);
assert.equal(isOpenAITerminalModelError({ status: 429, message: "rate limit" }), false);
assert.equal(isOpenAITerminalModelError({ status: 500, message: "server error" }), false);

assert.equal(isResumableIngestionJob({
  status: "failed",
  source_type: "tiktok",
  source_url: "https://vt.tiktok.com/example",
  fetched_at: "2026-05-03T00:00:00Z",
}), true);
assert.equal(isResumableIngestionJob({
  status: "failed",
  source_type: "web",
  source_url: "https://example.com/recipe",
  fetched_at: "2026-05-03T00:00:00Z",
}), false);
assert.equal(isResumableIngestionJob({
  status: "failed",
  source_type: "tiktok",
  source_url: "https://vt.tiktok.com/example",
}), false);

assert.equal(recipeNeedsSecondaryFill({
  servings_text: "4 servings",
  cook_time_text: "30 min",
  ingredients: [
    { display_name: "Chicken", quantity_text: "1 lb" },
    { display_name: "Rice", quantity_text: "1 cup" },
  ],
}), false);

assert.equal(recipeNeedsSecondaryFill({
  ingredients: [
    { display_name: "Chicken" },
    { display_name: "Rice" },
    { display_name: "Salt" },
    { display_name: "Oil" },
  ],
}), true);

assert.equal(recipeNeedsSecondaryFill({
  servings_text: "4 servings",
  cook_time_text: "30 min",
  ingredients: [
    { display_name: "Chicken", quantity_text: "1 lb" },
    { display_name: "Rice" },
    { display_name: "Salt" },
    { display_name: "Oil" },
  ],
}), false);

assert.equal(recipeNeedsCompletionPass({
  servings_text: "4 servings",
  servings_count: 4,
  cook_time_text: "30 min",
  cook_time_minutes: 30,
  prep_time_minutes: 10,
  est_calories_text: "500 kcal",
  calories_kcal: 500,
  ingredients: [
    { display_name: "Salmon" },
    { display_name: "Lemon" },
    { display_name: "Butter" },
    { display_name: "Garlic" },
    { display_name: "Parsley" },
  ],
  steps: [
    { text: "Season the salmon." },
    { text: "Cook until just done." },
    { text: "Finish with lemon butter." },
  ],
}), true);

console.log("recipe ingestion cost guard tests passed");
