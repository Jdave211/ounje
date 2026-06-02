// Regression tests for recipe import quality: ingredient parsing, display macros,
// and per-source gate routing. These lock in fixes that previously regressed
// silently because there was no test covering them. Run: node server/scripts/test-recipe-ingestion-quality.mjs

import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";

const { parseIngredientObjects } = await import("../lib/recipe-detail-utils.js");
const {
  guaranteeRecipeDisplayMacros,
  hasCompleteDisplayMacros,
  assessRecipeLikelihood,
  detectRecipeIngestionSourceType,
} = await import("../lib/recipe-ingestion.js");

// ---------------------------------------------------------------------------
// 1. Ingredient parsing — compound quantities must not leak the fraction into
//    the name. Covers both parser entry points (string + object paths).
// ---------------------------------------------------------------------------
function parseFirst(line) {
  return parseIngredientObjects(line)[0] ?? {};
}

{
  const r = parseFirst("2 and 3/4 cups all-purpose flour");
  assert.equal(r.name, "all-purpose flour", `"and" connector should not stay in name (got "${r.name}")`);
  assert.equal(r.quantity, 2.75, `compound quantity should be 2.75 (got ${r.quantity})`);
}
{
  const r = parseFirst("1 and 1/4 teaspoons Platinum Yeast");
  assert.equal(r.name, "Platinum Yeast");
  assert.equal(r.quantity, 1.25);
}
{
  const r = parseFirst("2 ¾ cups all-purpose flour");
  assert.equal(r.name, "all-purpose flour");
  assert.equal(r.quantity, 2.75);
}
{
  // A parenthetical metric weight must become a note, never a separate ingredient.
  const all = parseIngredientObjects("2 3/4 cups (344g) all-purpose flour");
  assert.equal(all.length, 1, "metric weight in parens must not split into a second ingredient");
  assert.equal(all[0].name, "all-purpose flour");
  assert.equal(all[0].quantity, 2.75);
}
{
  // Plain ingredients must stay intact (no false-positive collapsing).
  const r = parseFirst("0.25 cup granulated sugar");
  assert.equal(r.name, "granulated sugar");
  assert.equal(r.quantity, 0.25);
}

// ---------------------------------------------------------------------------
// 2. Display macros — a stored 0 kcal means "no data", not a real value.
// ---------------------------------------------------------------------------
assert.equal(
  hasCompleteDisplayMacros({ calories_kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0 }),
  false,
  "all-zero macros must not count as complete"
);
assert.equal(
  hasCompleteDisplayMacros({ calories_kcal: 420, protein_g: 22, carbs_g: 44, fat_g: 16 }),
  true,
  "real macros must count as complete"
);

{
  // All-zero recipe must be re-estimated to positive calories + macros.
  const out = await guaranteeRecipeDisplayMacros({
    title: "Jollof Rice",
    category: "dinner",
    ingredients: [{ name: "rice", quantity: 2, unit: "cup" }, { name: "chicken", quantity: 1, unit: "lb" }],
    calories_kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0,
  });
  assert.ok(Number(out.calories_kcal) > 0, `zero-calorie recipe must get estimated calories (got ${out.calories_kcal})`);
  assert.ok(Number(out.protein_g) > 0 && Number(out.carbs_g) > 0 && Number(out.fat_g) > 0, "zero macros must be re-estimated");
}
{
  // A real recipe with a legitimately-0 macro (calories are real) keeps that 0.
  const out = await guaranteeRecipeDisplayMacros({
    title: "Plain rice", calories_kcal: 520, protein_g: 0, carbs_g: 58, fat_g: 18,
  });
  assert.equal(Number(out.calories_kcal), 520, "real calories must be preserved");
  assert.equal(Number(out.protein_g), 0, "a legitimate 0 g macro must be preserved when calories are real");
}

// ---------------------------------------------------------------------------
// 3. Gate routing — each source uses its own gate. A photo must NEVER be able
//    to reach the social/video "Source does not appear to be a recipe" gate.
// ---------------------------------------------------------------------------
assert.equal(detectRecipeIngestionSourceType({ attachments: [{ kind: "image" }] }), "media_image");
assert.equal(detectRecipeIngestionSourceType({ attachments: [{ kind: "video" }] }), "media_video");
assert.equal(detectRecipeIngestionSourceType({ sourceUrl: "https://www.tiktok.com/@x/video/1" }), "tiktok");
assert.equal(detectRecipeIngestionSourceType({ sourceUrl: "https://www.instagram.com/p/abc" }), "instagram");
assert.equal(detectRecipeIngestionSourceType({ sourceUrl: "https://sallysbakingaddiction.com/recipe" }), "web");
assert.equal(detectRecipeIngestionSourceType({ sourceText: "make me a high protein dinner" }), "text");

{
  const accepted = await assessRecipeLikelihood({ source_type: "media_image", photo_meal_gate: { is_meal: true, confidence: 0.8 } });
  assert.equal(accepted.is_recipe, true);
  assert.equal(accepted.method, "photo_meal_gate_accept", "a food photo must be accepted via the photo meal gate");
}
{
  const rejected = await assessRecipeLikelihood({ source_type: "media_image", photo_meal_gate: { is_meal: false, confidence: 0.9, reject_reason: "no food" } });
  assert.equal(rejected.is_recipe, false);
  assert.equal(rejected.method, "photo_meal_gate_reject", "a photo rejection must come from the photo meal gate, not the social recipe gate");
}

// ---------------------------------------------------------------------------
// 4. Quantity text preservation — fractions must not be converted to decimals
// ---------------------------------------------------------------------------
{
  const r = parseFirst("1/2 cup unsalted butter");
  assert.equal(r.quantity_text, "1/2 cup", `quantity_text must preserve the fraction "1/2 cup", got "${r.quantity_text}"`);
}
{
  const r = parseFirst("1 and 1/2 cups mini marshmallows");
  assert.equal(r.quantity_text, "1 1/2 cups", `compound fraction must collapse to "1 1/2 cups", got "${r.quantity_text}"`);
}
{
  const r = parseFirst("1/4 teaspoon Platinum Yeast from Red Star");
  assert.equal(r.name, "Platinum Yeast from Red Star");
  assert.equal(r.quantity_text, "1/4 teaspoon");
}
{
  // Decimal sources (model output) are fine to keep as-is
  const r = parseFirst("0.25 cup granulated sugar");
  assert.ok(r.quantity_text != null, "decimal quantities should also be preserved");
  assert.equal(r.name, "granulated sugar");
}

console.log("recipe-ingestion-quality: all assertions passed");
