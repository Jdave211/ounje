// Regression tests for recipe import quality: ingredient parsing, display macros,
// and per-source gate routing. These lock in fixes that previously regressed
// silently because there was no test covering them. Run: node server/scripts/test-recipe-ingestion-quality.mjs

import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";
process.env.RECIPE_INGESTION_SOCIAL_VIDEO_EAGER = "false";

const { parseIngredientObjects } = await import("../lib/recipe-detail-utils.js");
const {
  guaranteeRecipeDisplayMacros,
  normalizeRecipeDisplayFields,
  hasCompleteDisplayMacros,
  assessRecipeLikelihood,
  photoRecipeDocumentHasUsableCore,
  detectRecipeIngestionSourceType,
  socialRecipeTextCanSkipVideoDownload,
  selectRecipeEvidenceFrameDataURLs,
  socialSourceHasPrimaryRecipeEvidence,
  buildFinalRecipeValidationIssues,
  isOCRSafeFrameDataURL,
  canonicalTikTokURLFromMetadata,
  preferredTikTokProcessingURL,
  normalizeImportPayload,
  isStaleLiveRecipeImportJob,
  SOCIAL_VIDEO_RECIPE_MODEL,
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
  const publicCatalogImport = normalizeImportPayload({
    source_url: "https://www.tiktok.com/@chef/video/1234567890123456789",
    public_catalog_import: true,
  });
  assert.equal(publicCatalogImport.public_catalog_import, true, "public catalog approval must survive queue normalization");
}

{
  const accepted = await assessRecipeLikelihood({ source_type: "media_image", photo_meal_gate: { is_meal: true, confidence: 0.8 } });
  assert.equal(accepted.is_recipe, true);
  assert.equal(accepted.method, "photo_meal_gate_accept", "a food photo must be accepted via the photo meal gate");
}

assert.equal(
  photoRecipeDocumentHasUsableCore({
    title: "Banana bread",
    ingredients: ["3 bananas", "2 eggs", "2 cups flour"],
    steps: ["Mix the batter.", "Bake until set."],
  }),
  true,
  "a readable recipe screenshot or cookbook page must pass the photo import gate"
);
assert.equal(
  photoRecipeDocumentHasUsableCore({
    title: "Menu",
    ingredients: ["Chicken"],
    steps: [],
  }),
  false,
  "an isolated food word must not turn a menu or unrelated screenshot into a recipe"
);

{
  const cleaned = normalizeRecipeDisplayFields({
    ingredients: [
      { display_name: "1-2 tablespoons cooking oil", quantity_text: "1-2 tablespoons" },
      { display_name: "salt to taste", quantity_text: "to taste" },
    ],
    steps: [],
  });
  assert.equal(cleaned.ingredients[0].display_name, "cooking oil");
  assert.equal(cleaned.ingredients[0].quantity_text, "1-2 tablespoons");
  assert.equal(cleaned.ingredients[1].display_name, "salt");
  assert.equal(cleaned.ingredients[1].quantity_text, "to taste");
}
{
  const rejected = await assessRecipeLikelihood({ source_type: "media_image", photo_meal_gate: { is_meal: false, confidence: 0.9, reject_reason: "no food" } });
  assert.equal(rejected.is_recipe, false);
  assert.equal(rejected.method, "photo_meal_gate_reject", "a photo rejection must come from the photo meal gate, not the social recipe gate");
}

// ---------------------------------------------------------------------------
// 4. Social media fast path — rich captions should avoid a video download,
//    while video-first posts still receive the full media pipeline.
// ---------------------------------------------------------------------------
const captionRecipe = [
  "This quick coconut chicken recipe makes an easy weeknight dinner.",
  "Ingredients: 2 chicken breasts, 1 can coconut milk, 1 tablespoon curry powder, 1 onion, garlic, salt, lime, and cilantro.",
  "Instructions: Heat oil in a skillet, saute the onion and garlic, stir in the curry powder, then add chicken and cook until browned.",
  "Pour in the coconut milk, simmer for 12 minutes, season with lime and salt, then serve over rice with cilantro.",
].join(" ");
assert.equal(
  socialRecipeTextCanSkipVideoDownload({ metadata: { description: captionRecipe } }),
  true,
  "a complete recipe caption should use the text fast path"
);
assert.equal(
  socialRecipeTextCanSkipVideoDownload({ metadata: { description: "Watch until the end for the final dish." } }),
  false,
  "video-first social posts must retain the media pipeline"
);
assert.equal(isOCRSafeFrameDataURL("data:image/webp;base64,AAAA"), false, "WebP frames must bypass OCR");
assert.equal(isOCRSafeFrameDataURL("data:image/jpeg;base64,AAAA"), true, "JPEG frames remain eligible for OCR");

{
  const frames = Array.from({ length: 10 }, (_, index) => `frame-${index + 1}`);
  const selected = selectRecipeEvidenceFrameDataURLs(frames, [
    { frame_index: 1, text: "Easy Ayamase recipe", confidence: 30 },
    { frame_index: 5, text: "Bleach palm oil", confidence: 63 },
    { frame_index: 6, text: "Blend green bell pepper scotch bonnet onion", confidence: 40 },
    { frame_index: 9, text: "Add pepper mix. Season with salt, crayfish, Maggi, iru", confidence: 38 },
  ], 4);
  assert.deepEqual(
    selected,
    ["frame-1", "frame-5", "frame-6", "frame-9"],
    "vision extraction must receive OCR-rich recipe frames instead of unrelated evenly spaced frames"
  );
}

const ayamaseVideoEvidence = {
  source_type: "tiktok",
  frame_data_urls: ["frame-1", "frame-2"],
  frame_ocr_texts: [
    { frame_index: 1, text: "Bleach palm oil", confidence: 63 },
    { frame_index: 2, text: "Season with salt, crayfish, Maggi and iru", confidence: 50 },
  ],
};
assert.equal(
  socialSourceHasPrimaryRecipeEvidence(ayamaseVideoEvidence),
  true,
  "recipe-like video frames must remain the primary source even when audio is unrelated"
);
assert.equal(
  SOCIAL_VIDEO_RECIPE_MODEL,
  "gpt-4.1-mini",
  "video-only imports must use the tested higher-fidelity extraction model"
);
assert.ok(
  buildFinalRecipeValidationIssues({
    ingredients: [{ display_name: "green pepper", quantity_text: "4" }],
    steps: [{ number: 1, text: "Blend the green pepper.", ingredients: [] }],
  }, ayamaseVideoEvidence).some((issue) => issue.includes("source-evidence coverage")),
  "the final validator must audit the saved ingredient list against video evidence"
);
assert.equal(
  preferredTikTokProcessingURL(
    "https://www.tiktok.com/@/video/7616089987406368022?_r=1",
    "https://vt.tiktok.com/ZSHw9pH5N/"
  ),
  "https://vt.tiktok.com/ZSHw9pH5N/",
  "a malformed TikTok canonical URL must fall back to the shared URL"
);
assert.equal(
  canonicalTikTokURLFromMetadata({
    id: "7616089987406368022",
    uploader: "emmy_jiggy",
    webpage_url: "https://www.tiktok.com/@/video/7616089987406368022",
  }, "https://vt.tiktok.com/ZSHw9pH5N/"),
  "https://www.tiktok.com/@emmy_jiggy/video/7616089987406368022",
  "TikTok metadata should restore a creator-qualified canonical URL"
);

const fourMinutesAgo = new Date(Date.now() - 4 * 60_000).toISOString();
const oneMinuteAgo = new Date(Date.now() - 60_000).toISOString();
assert.equal(
  isStaleLiveRecipeImportJob({ status: "queued", queued_at: fourMinutesAgo }),
  true,
  "queued imports must become retryable when no worker claims them"
);
assert.equal(
  isStaleLiveRecipeImportJob({ status: "queued", queued_at: oneMinuteAgo }),
  false,
  "fresh queued imports must remain live"
);

console.log("recipe-ingestion-quality: all assertions passed");
