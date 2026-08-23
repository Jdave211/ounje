// Regression tests for recipe import quality: ingredient parsing, display macros,
// and per-source gate routing. These lock in fixes that previously regressed
// silently because there was no test covering them. Run: node server/scripts/test-recipe-ingestion-quality.mjs

import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";

const { parseIngredientObjects } = await import("../lib/recipe-detail-utils.js");
const { redisConfigStatus } = await import("../lib/redis-cache.js");
const {
  guaranteeRecipeDisplayMacros,
  hasCompleteDisplayMacros,
  hasUsableRecipeShape,
  assessRecipeLikelihood,
  buildFinalRecipeValidationIssues,
  buildRecipeGateUserContent,
  detectRecipeIngestionSourceType,
  isStaleLiveRecipeImportJob,
  normalizeCreatorHandle,
  selectedSocialHeroFrame,
  selectRecipeEvidenceFrameDataURLs,
  socialSourceHasPrimaryRecipeEvidence,
  socialFrameTimestamps,
  SOCIAL_VIDEO_RECIPE_MODEL,
} = await import("../lib/recipe-ingestion.js");

{
  const previousRuntime = process.env.OUNJE_RUNTIME_ENV;
  const previousDisabled = process.env.REDIS_DISABLED;
  const previousProductionRedis = process.env.OUNJE_ENABLE_PRODUCTION_REDIS;
  const previousURL = process.env.REDIS_URL;
  process.env.OUNJE_RUNTIME_ENV = "production";
  delete process.env.REDIS_DISABLED;
  process.env.REDIS_URL = "redis://legacy.example:6379";
  assert.equal(redisConfigStatus().disabled, true, "production must not contact a legacy Redis service by default");
  assert.equal(redisConfigStatus().configured, false);
  process.env.REDIS_DISABLED = "false";
  assert.equal(redisConfigStatus().configured, false, "a stale REDIS_DISABLED=false value must not reactivate production Redis");
  process.env.OUNJE_ENABLE_PRODUCTION_REDIS = "true";
  assert.equal(redisConfigStatus().configured, true, "a future managed Redis service can be explicitly enabled");
  if (previousRuntime == null) delete process.env.OUNJE_RUNTIME_ENV; else process.env.OUNJE_RUNTIME_ENV = previousRuntime;
  if (previousDisabled == null) delete process.env.REDIS_DISABLED; else process.env.REDIS_DISABLED = previousDisabled;
  if (previousProductionRedis == null) delete process.env.OUNJE_ENABLE_PRODUCTION_REDIS; else process.env.OUNJE_ENABLE_PRODUCTION_REDIS = previousProductionRedis;
  if (previousURL == null) delete process.env.REDIS_URL; else process.env.REDIS_URL = previousURL;
}

{
  const frameURL = "data:image/jpeg;base64,ZmFrZS1mcmFtZQ==";
  const content = buildRecipeGateUserContent({
    source_type: "tiktok",
    platform: "tiktok",
    frame_data_urls: [frameURL],
    frame_ocr_texts: [],
  }, {
    mediaMode: "video",
    structuredIngredientCount: 0,
    structuredInstructionCount: 0,
    ingredientCandidateCount: 0,
    instructionCandidateCount: 0,
    transcriptPresent: false,
    frameOcrCount: 0,
    pageImageCount: 0,
    positiveHits: [],
    negativeHits: [],
  });
  assert.equal(content[0].type, "text");
  assert.equal(content[1].image_url.url, frameURL, "social recipe gate must receive visual frame evidence");
  assert.equal(content[1].image_url.detail, "high", "frame text must be sent at readable detail");
}

{
  const timestamps = socialFrameTimestamps(34.67, 8);
  assert.equal(timestamps.length, 8);
  assert.ok(timestamps[0] <= 0.2, "video evidence must include the creator's opening hero shot");
  assert.ok(timestamps.at(-1) >= 34.4, "video evidence must include the creator's closing finished-dish shot");
}

{
  const frames = Array.from({ length: 10 }, (_, index) => `data:image/jpeg;base64,frame-${index + 1}`);
  const selected = selectedSocialHeroFrame(
    { source_type: "tiktok", frame_data_urls: frames },
    { hero_frame_position: 4 }
  );
  assert.equal(selected?.dataURL, frames[3], "hero selection must map to the same frames shown to vision");
  assert.equal(selectedSocialHeroFrame({ source_type: "web", frame_data_urls: frames }, { hero_frame_position: 1 }), null);
  assert.equal(selectedSocialHeroFrame({ source_type: "tiktok", frame_data_urls: frames }, { hero_frame_position: 99 }), null);
}

{
  const frames = Array.from({ length: 12 }, (_, index) => `frame-${index + 1}`);
  const selected = selectRecipeEvidenceFrameDataURLs(frames, [
    { frame_index: 1, confidence: 90, text: "Finished dish" },
    { frame_index: 2, confidence: 84, text: "Boil assorted meats with salt Maggi pepper curry" },
    { frame_index: 5, confidence: 87, text: "Bleach palm oil" },
    { frame_index: 6, confidence: 91, text: "Blend green bell pepper scotch bonnet onion" },
    { frame_index: 9, confidence: 86, text: "Add pepper mix salt crayfish Maggi iru" },
  ], 4);
  assert.deepEqual(
    selected,
    [frames[1], frames[4], frames[5], frames[8]],
    "vision input must prioritize OCR-rich recipe frames instead of visual spacing alone"
  );
}

{
  const ayamaseVideoEvidence = {
    source_type: "tiktok",
    frame_data_urls: Array.from({ length: 12 }, (_, index) => `frame-${index + 1}`),
    frame_ocr_texts: [
      { frame_index: 5, confidence: 87, text: "Bleach palm oil" },
      { frame_index: 6, confidence: 91, text: "Blend green bell pepper scotch bonnet onion" },
      { frame_index: 9, confidence: 86, text: "Add pepper mix salt crayfish Maggi iru" },
    ],
  };
  assert.equal(
    socialSourceHasPrimaryRecipeEvidence(ayamaseVideoEvidence),
    true,
    "explicit social frame recipe evidence must survive a weak metadata gate"
  );
  assert.match(
    buildFinalRecipeValidationIssues({
      ingredients: [{ display_name: "green bell pepper" }],
      steps: [{ number: 1, text: "Blend the green bell pepper.", ingredients: [{ display_name: "green bell pepper" }] }],
    }, ayamaseVideoEvidence).join(" "),
    /source-evidence coverage/i,
    "final validation must audit the saved recipe against social frame evidence"
  );
  assert.equal(SOCIAL_VIDEO_RECIPE_MODEL, "gpt-4.1-mini");
}

{
  assert.equal(
    hasUsableRecipeShape({
      ingredients: ["chicken", "salt", "pepper", "lemon"].map((display_name) => ({ display_name, quantity_text: null })),
      steps: ["Season the chicken.", "Air fry until cooked.", "Brush with lemon butter."].map((text) => ({ text })),
    }),
    true,
    "a source-faithful social recipe with missing quantities must still bypass generic web completion"
  );
  assert.equal(
    hasUsableRecipeShape({ ingredients: [{ display_name: "chicken" }], steps: [{ text: "Cook it." }] }),
    false
  );
}

{
  const captionRichVideoEvidence = {
    source_type: "tiktok",
    frame_data_urls: Array.from({ length: 12 }, (_, index) => `frame-${index + 1}`),
    frame_ocr_texts: [{ frame_index: 1, confidence: 28, text: "unreadable frame noise" }],
    caption_text: "Lemon pepper chicken skewers. Season chicken with salt, pepper, garlic, lemon zest, onion powder, paprika and olive oil. Air fry for 12 minutes, flip, then cook for 10 minutes. Mix butter with lemon juice and serve.",
    transcript_text: "Add the seasonings to the chicken and mix well. Put the skewers in the air fryer, flip them, then brush on the butter sauce.",
  };
  assert.equal(
    socialSourceHasPrimaryRecipeEvidence(captionRichVideoEvidence),
    true,
    "detailed caption and transcript evidence must not be discarded when local frame OCR is noisy"
  );
  assert.equal(
    socialSourceHasPrimaryRecipeEvidence({
      source_type: "tiktok",
      frame_data_urls: ["frame-1"],
      caption_text: "This was so good. You have to try it.",
      transcript_text: "Follow for more easy recipes.",
    }),
    false,
    "generic social captions must not bypass the recipe evidence gate"
  );
}

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

assert.equal(normalizeCreatorHandle("@9resha"), "@9resha");
assert.equal(
  normalizeCreatorHandle("MS4wLjABAAAApkyPUHodYpzzuTew33dYjEzer52vag7zyJ6i78LFgMz6l_YI17Xx7hunEXZN9EoC"),
  null,
  "TikTok secUid values must never render as public creator handles"
);

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
{
  const [r] = parseIngredientObjects([{ display_name: "Pinch of sugar", quantity_text: "pinch" }]);
  assert.equal(r.name, "sugar", "word-based quantity prefixes must not leave a leading 'of' in the ingredient name");
  assert.equal(r.quantity_text, "pinch");
}

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
