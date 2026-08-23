// Regression tests for recipe import quality: ingredient parsing, display macros,
// and per-source gate routing. These lock in fixes that previously regressed
// silently because there was no test covering them. Run: node server/scripts/test-recipe-ingestion-quality.mjs

import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";
process.env.PERPLEXITY_API_KEY = "test-perplexity-key";

const { parseIngredientObjects } = await import("../lib/recipe-detail-utils.js");
const { redisConfigStatus } = await import("../lib/redis-cache.js");
const {
  guaranteeRecipeDisplayMacros,
  hasCompleteDisplayMacros,
  hasUsableRecipeShape,
  assessRecipeLikelihood,
  buildFinalRecipeValidationIssues,
  shouldRunFinalRecipeValidation,
  buildRecipeGateUserContent,
  detectRecipeIngestionSourceType,
  isStaleLiveRecipeImportJob,
  normalizeCreatorHandle,
  selectedSocialHeroFrame,
  selectRecipeEvidenceFrameDataURLs,
  socialSourceHasPrimaryRecipeEvidence,
  socialImportNeedsGroundedCompletion,
  shouldRunGroundedRecipeCompletion,
  mergeGroundedSocialCompletion,
  calibrateSocialRecipeAssessment,
  normalizeRecipeDisplayFields,
  runSocialRecipeCompletionContext,
  socialFrameTimestamps,
  SOCIAL_VIDEO_RECIPE_MODEL,
} = await import("../lib/recipe-ingestion.js");

{
  const previousRuntime = process.env.OUNJE_RUNTIME_ENV;
  const previousNodeEnv = process.env.NODE_ENV;
  const previousDisabled = process.env.REDIS_DISABLED;
  const previousProductionRedis = process.env.OUNJE_ENABLE_PRODUCTION_REDIS;
  const previousURL = process.env.REDIS_URL;
  delete process.env.OUNJE_RUNTIME_ENV;
  process.env.NODE_ENV = "production";
  delete process.env.REDIS_DISABLED;
  process.env.REDIS_URL = "redis://legacy.example:6379";
  assert.equal(redisConfigStatus().disabled, true, "production must not contact a legacy Redis service by default");
  assert.equal(redisConfigStatus().configured, false);
  process.env.REDIS_DISABLED = "false";
  assert.equal(redisConfigStatus().configured, false, "a stale REDIS_DISABLED=false value must not reactivate production Redis");
  process.env.OUNJE_ENABLE_PRODUCTION_REDIS = "true";
  assert.equal(redisConfigStatus().configured, true, "a future managed Redis service can be explicitly enabled");
  if (previousRuntime == null) delete process.env.OUNJE_RUNTIME_ENV; else process.env.OUNJE_RUNTIME_ENV = previousRuntime;
  if (previousNodeEnv == null) delete process.env.NODE_ENV; else process.env.NODE_ENV = previousNodeEnv;
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
  assert.equal(
    shouldRunFinalRecipeValidation({
      ingredients: [{ display_name: "green bell pepper" }],
      steps: [{ number: 1, text: "Blend the green bell pepper.", ingredients: [{ display_name: "green bell pepper" }] }],
    }, ayamaseVideoEvidence),
    true,
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

{
  const pepperFishRecipe = {
    title: "Pepper Grilled Fish",
    author_handle: "@chefttk",
    ingredients: [
      "tilapia",
      "oil-based seasoning",
      "red pepper-based seasoning",
      "plantain",
      "fried yam",
      "pop pepper sauce",
    ].map((display_name) => ({ display_name, quantity_text: "1" })),
    steps: Array.from({ length: 8 }, (_, index) => ({ text: `Broad step ${index + 1}` })),
  };
  const sparsePepperFishSource = {
    source_type: "tiktok",
    canonical_url: "https://www.tiktok.com/@chefttk/video/7270184253428600097",
    transcript_text: "Let's make pepper grilled fish. Use tilapia, oil-based seasoning and red pepper-based seasoning. Serve with yam or plantain.",
    frame_data_urls: [],
    frame_ocr_texts: [],
    ingredient_candidates: ["tilapia", "oil-based seasoning", "red pepper-based seasoning"],
    instruction_candidates: [],
  };
  assert.equal(
    socialImportNeedsGroundedCompletion(
      pepperFishRecipe,
      sparsePepperFishSource,
      ["incomplete", "missing_steps"]
    ),
    true,
    "a broad social recipe with no frame evidence must receive grounded completion even when its generated shape looks complete"
  );
  assert.equal(
    socialImportNeedsGroundedCompletion(
      pepperFishRecipe,
      {
        ...sparsePepperFishSource,
        frame_data_urls: Array.from({ length: 12 }, (_, index) => `frame-${index + 1}`),
        frame_ocr_texts: Array.from({ length: 12 }, (_, index) => ({
          frame_index: index + 1,
          text: "unusable visual OCR noise",
        })),
      },
      ["partial_ingredients", "partial_steps"]
    ),
    true,
    "production partial flags must trigger Sonar even when frame sampling and generated recipe shape look complete"
  );
  assert.equal(
    socialImportNeedsGroundedCompletion(
      pepperFishRecipe,
      {
        ...sparsePepperFishSource,
        transcript_text: "Serve grilled tilapia with yam, plantain and pepper sauce.",
        frame_data_urls: Array.from({ length: 12 }, (_, index) => `frame-${index + 1}`),
        frame_ocr_texts: Array.from({ length: 12 }, (_, index) => ({
          frame_index: index + 1,
          text: "unusable visual OCR noise",
        })),
        ingredient_candidates: [],
        instruction_candidates: [],
      },
      []
    ),
    true,
    "nonempty OCR noise must not count as detailed frame recipe evidence"
  );
  assert.equal(
    shouldRunGroundedRecipeCompletion(
      pepperFishRecipe,
      {
        source_type: "tiktok",
        frame_data_urls: ["frame-1", "frame-2", "frame-3"],
        frame_ocr_texts: [
          { frame_index: 1, text: "Blend green pepper onion and scotch bonnet" },
          { frame_index: 2, text: "Bleach palm oil then add pepper mix" },
          { frame_index: 3, text: "Season with salt crayfish Maggi and iru" },
        ],
        ingredient_candidates: ["palm oil", "pepper", "onion", "crayfish"],
        instruction_candidates: ["Blend peppers", "Bleach oil", "Cook sauce"],
      },
      []
    ),
    false,
    "rich creator-provided frame evidence must remain the primary recipe instead of paying for a needless web completion"
  );

  const unsafeReplacement = {
    ...pepperFishRecipe,
    ingredients: ["tilapia", "garlic", "paprika", "lemon"].map((display_name) => ({ display_name, quantity_text: "1" })),
    steps: Array.from({ length: 6 }, (_, index) => ({ text: `Replacement step ${index + 1}` })),
  };
  const guarded = mergeGroundedSocialCompletion(pepperFishRecipe, unsafeReplacement);
  assert.deepEqual(
    guarded.ingredients.map((ingredient) => ingredient.display_name),
    pepperFishRecipe.ingredients.map((ingredient) => ingredient.display_name),
    "grounded completion must not replace source-specific sides or sauces with a generic fish recipe"
  );
  assert.equal(guarded.author_handle, "@chefttk", "completion must preserve the creator");

  const concreteGroundedCompletion = {
    ...pepperFishRecipe,
    ingredients: [
      "tilapia",
      "neutral oil",
      "red bell pepper",
      "onion",
      "garlic",
      "ginger",
      "paprika",
      "plantain",
      "fried yam",
      "pop pepper sauce",
    ].map((display_name) => ({ display_name, quantity_text: "1" })),
    steps: Array.from({ length: 6 }, (_, index) => ({ text: `Grounded completion step ${index + 1}` })),
  };
  const expanded = mergeGroundedSocialCompletion(pepperFishRecipe, concreteGroundedCompletion);
  assert.deepEqual(
    expanded.ingredients.map((ingredient) => ingredient.display_name),
    concreteGroundedCompletion.ingredients.map((ingredient) => ingredient.display_name),
    "grounded completion may expand generic seasoning labels when it preserves source-specific protein and sides"
  );
  assert.equal(expanded.author_handle, "@chefttk", "constituent expansion must preserve the creator");

  const normalizationIssues = buildFinalRecipeValidationIssues({
    ingredients: [
      { display_name: "1 whole tilapia fish (700–900 g), scaled and gutted", quantity_text: "1 whole" },
      { display_name: "vegetable oil", quantity_text: "2 tablespoons" },
      { display_name: "vegetable oil (for pepper sauce)", quantity_text: "2 tablespoons" },
    ],
    steps: [
      { text: "Rub the tilapia with vegetable oil." },
      { text: "Cook the pepper sauce with the remaining vegetable oil." },
    ],
  });
  assert.ok(
    normalizationIssues.some((issue) => issue.includes("Move quantities and size ranges")),
    "validator must catch quantity text leaking into ingredient names"
  );
  assert.ok(
    normalizationIssues.some((issue) => issue.includes("Consolidate repeated ingredient rows")),
    "validator must catch role-suffixed duplicate ingredient rows before they reach cart"
  );

  const preparedComponentIssues = buildFinalRecipeValidationIssues({
    ingredients: [
      { display_name: "whole tilapia fish", quantity_text: "1 whole" },
      { display_name: "red bell pepper", quantity_text: "2" },
      { display_name: "vegetable oil", quantity_text: "2 tablespoons" },
    ],
    steps: [
      { text: "Score the cleaned whole tilapia, then rub it with vegetable oil." },
      {
        number: 2,
        text: "Coat the tilapia with the prepared red pepper seasoning.",
        ingredients: [{ display_name: "red pepper seasoning", quantity_text: null }],
      },
    ],
  });
  assert.ok(
    !preparedComponentIssues.some((issue) => issue.includes('Ingredient "whole tilapia fish" is listed but not clearly used')),
    "validator must recognize a distinctive ingredient name used without its generic suffix"
  );
  assert.ok(
    !preparedComponentIssues.some((issue) => issue.includes("red pepper seasoning")),
    "prepared component labels must not be forced back into the shopping ingredient list"
  );

  const cleanedStepLinks = normalizeRecipeDisplayFields({
    title: "Pepper Grilled Tilapia",
    ingredients: [{ display_name: "tilapia fish", quantity_text: "1 whole" }],
    steps: [{
      text: "Grill the tilapia, then serve with fried yam if desired.",
      ingredients: [{ display_name: "fried yam", quantity_text: null }],
    }],
  });
  assert.deepEqual(
    cleanedStepLinks.steps[0].ingredients.map((ingredient) => ingredient.display_name),
    ["tilapia fish"],
    "step links must keep referenced shopping ingredients and discard optional prepared sides that are not top-level ingredients"
  );

  const specificPowderLink = normalizeRecipeDisplayFields({
    title: "Seasoned fish",
    ingredients: [
      { display_name: "onion", quantity_text: "1" },
      { display_name: "onion powder", quantity_text: "1 teaspoon" },
    ],
    steps: [{ text: "Rub the fish with onion powder.", ingredients: [] }],
  });
  assert.deepEqual(
    specificPowderLink.steps[0].ingredients.map((ingredient) => ingredient.display_name),
    ["onion powder"],
    "step-link inference must prefer the explicitly named ingredient over a shorter overlapping ingredient"
  );

  const inferredContextSource = {
    ...sparsePepperFishSource,
    social_completion_context: {
      exact_match_supported: false,
      completion_ingredients: ["garlic, ginger, paprika and salt for the pepper seasoning"],
      completion_steps: ["Blend the pepper seasoning and marinate the tilapia before grilling"],
    },
  };
  const calibrated = calibrateSocialRecipeAssessment(
    { confidence_score: 0.93, quality_flags: [], review_state: "approved", review_reason: null },
    pepperFishRecipe,
    inferredContextSource,
    ["incomplete", "missing_steps"]
  );
  assert.equal(calibrated.confidence_score, 0.82, "inferred completion must not masquerade as 0.93 creator-source confidence");
  assert.ok(calibrated.quality_flags.includes("grounded_completion_inferred"));

  const originalFetch = globalThis.fetch;
  let capturedPerplexityPayload = null;
  globalThis.fetch = async (url, options) => {
    assert.equal(String(url), "https://api.perplexity.ai/chat/completions");
    capturedPerplexityPayload = JSON.parse(String(options?.body ?? "{}"));
    return new Response(JSON.stringify({
      choices: [{
        message: {
          content: JSON.stringify({
            exact_match_supported: false,
            match_confidence: 0.61,
            matched_creator_or_source: "Temi Tyrese pepper grilled fish",
            reference_urls: ["https://example.com/pepper-grilled-fish"],
            source_supported_ingredients: ["tilapia", "plantain", "fried yam", "pepper sauce"],
            source_supported_steps: ["grill the seasoned tilapia"],
            completion_ingredients: ["garlic, ginger and paprika can complete the pepper seasoning"],
            completion_steps: ["marinate before grilling and baste while cooking"],
            quantity_guidance: ["use conservative amounts for four tilapia fillets"],
            cautions: ["No exact written creator recipe was found"],
          }),
        },
      }],
      citations: ["https://example.com/pepper-grilled-fish"],
      usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 },
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
  try {
    const context = await runSocialRecipeCompletionContext(pepperFishRecipe, sparsePepperFishSource);
    assert.equal(context.exact_match_supported, false);
    assert.equal(context.match_confidence, 0.61);
    assert.ok(context.completion_ingredients.some((item) => item.includes("paprika")));
    assert.equal(capturedPerplexityPayload.model, "sonar-pro");
    assert.match(capturedPerplexityPayload.messages[0].content, /research context, not a replacement recipe/i);
    assert.match(capturedPerplexityPayload.messages[0].content, /one concrete shoppable ingredient per completion_ingredients entry/i);
    assert.match(capturedPerplexityPayload.messages[0].content, /must not mean unusably broad/i);
    assert.match(capturedPerplexityPayload.messages[1].content, /chefttk/);
  } finally {
    globalThis.fetch = originalFetch;
  }
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
