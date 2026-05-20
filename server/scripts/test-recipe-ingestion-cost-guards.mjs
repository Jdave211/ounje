import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";

const {
  RECIPE_GATE_MODEL,
  RECIPE_IMPORT_COMPLETION_MODEL,
  RECIPE_INGESTION_MODEL,
  RECIPE_SEARCH_SYNTHESIS_MODEL,
  assessRecipeLikelihood,
  buildDedupeKey,
  buildPhotoImportDedupeKey,
  canonicalImportIdentityForURL,
  guaranteeRecipeDisplayMacros,
  hasCompleteDisplayMacros,
  isCanonicalCacheableSource,
  isOpenAITerminalModelError,
  isResumableIngestionJob,
  photoRecipeSearchQueries,
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
assert.equal(isCanonicalCacheableSource("web", "https://example.com/recipe"), true);
assert.equal(hasCompleteDisplayMacros({
  calories_kcal: null,
  protein_g: null,
  carbs_g: null,
  fat_g: null,
}), false);

assert.equal(
  canonicalImportIdentityForURL("https://www.tiktok.com/@xavierbigdd/video/7504813584021622059?_r=1&_t=8wZr"),
  "tiktok:video:7504813584021622059"
);
assert.equal(
  buildDedupeKey({
    sourceUrl: "https://www.tiktok.com/@xavierbigdd/video/7504813584021622059?_r=1&_t=8wZr",
  }),
  buildDedupeKey({
    sourceUrl: "https://www.tiktok.com/@xavierbigdd/video/7504813584021622059?_t=different",
  })
);

assert.equal(
  buildPhotoImportDedupeKey([
    {
      kind: "image",
      storage_bucket: "recipe-import-media",
      storage_path: "users/u/photo-imports/a/source.jpg",
    },
  ]),
  buildPhotoImportDedupeKey([
    {
      kind: "image",
      storage_bucket: "recipe-import-media",
      storage_path: "users/u/photo-imports/a/source.jpg",
    },
  ])
);
assert.equal(
  buildPhotoImportDedupeKey([{ kind: "image", data_url: "data:image/jpeg;base64,abc123" }]),
  buildPhotoImportDedupeKey([{ kind: "image", data_url: "data:image/jpeg;base64,abc123" }])
);

assert.equal(isOpenAITerminalModelError({ status: 400, message: "The model does not exist" }), true);
assert.equal(isOpenAITerminalModelError({ status: 429, message: "rate limit" }), false);
assert.equal(isOpenAITerminalModelError({ status: 500, message: "server error" }), false);

const acceptedPhotoGate = await assessRecipeLikelihood({
  source_type: "media_image",
  platform: "photo",
  title: "Chicken skewers",
  photo_meal_gate: { is_meal: true, confidence: 0.64 },
  ingredient_candidates: [],
  instruction_candidates: [],
});
assert.equal(acceptedPhotoGate.is_recipe, true);
assert.equal(acceptedPhotoGate.method, "photo_meal_gate_accept");

const rejectedPhotoGate = await assessRecipeLikelihood({
  source_type: "media_image",
  platform: "photo",
  title: "Receipt",
  photo_meal_gate: { is_meal: false, confidence: 0.91, reject_reason: "No visible food." },
  ingredient_candidates: [],
  instruction_candidates: [],
});
assert.equal(rejectedPhotoGate.is_recipe, false);
assert.equal(rejectedPhotoGate.method, "photo_meal_gate_reject");

const photoQueryFromDishCandidate = photoRecipeSearchQueries({
  dish_candidates: ["spaghetti with meat sauce"],
  visible_ingredients: ["spaghetti", "tomato sauce", "parmesan", "basil"],
}, {});
assert.equal(photoQueryFromDishCandidate[0], "spaghetti with meat sauce recipe");
assert.equal(
  photoRecipeSearchQueries({
    dish_candidates: [{ name: "Pasta al Pomodoro with Basil and Parmesan" }],
  }, {})[0],
  "Pasta al Pomodoro with Basil and Parmesan recipe"
);
assert.equal(
  photoRecipeSearchQueries({
    visible_ingredients: ["spaghetti", "tomato sauce", "parmesan", "basil"],
  }, {})[0],
  "spaghetti tomato sauce parmesan basil recipe"
);

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

const macroGuaranteed = await guaranteeRecipeDisplayMacros({
  title: "High protein banana brownies",
  description: "Chocolate protein brownies",
  servings_text: "4 servings",
  servings_count: 4,
  ingredients: [
    { display_name: "Ripe bananas", quantity_text: "300g" },
    { display_name: "Whole eggs", quantity_text: "5" },
    { display_name: "Greek yogurt", quantity_text: "200g" },
    { display_name: "Cocoa powder", quantity_text: "25g" },
  ],
  steps: [
    { text: "Blend the ingredients." },
    { text: "Bake until set." },
  ],
});
assert.equal(hasCompleteDisplayMacros(macroGuaranteed), true);
assert.equal(Number.isFinite(macroGuaranteed.calories_kcal), true);

const textOnlyCaloriesGuaranteed = await guaranteeRecipeDisplayMacros({
  title: "Garlic Parmesan Chicken Skewers",
  description: "Garlic parmesan chicken skewers cooked in an air fryer.",
  category: "Dinner",
  recipe_type: "Dinner",
  main_protein: "Chicken",
  cook_method: "air fryer",
  servings_text: "4 servings",
  servings_count: 4,
  est_calories_text: "Approximately 420 kcal per serving (estimate)",
  calories_kcal: null,
  protein_g: null,
  carbs_g: null,
  fat_g: null,
  ingredients: [
    { display_name: "Chicken breast", quantity_text: "2 lb" },
    { display_name: "Olive oil", quantity_text: "2 tbsp" },
    { display_name: "Grated parmesan cheese", quantity_text: "1/4 cup" },
    { display_name: "Light mayo", quantity_text: "2 tbsp" },
  ],
  steps: [
    { text: "Season the chicken and thread onto skewers." },
    { text: "Air fry until cooked through, then brush with garlic parmesan sauce." },
  ],
});
assert.equal(hasCompleteDisplayMacros(textOnlyCaloriesGuaranteed), true);
assert.equal(Number.isFinite(textOnlyCaloriesGuaranteed.calories_kcal), true);
assert.equal(Number.isFinite(textOnlyCaloriesGuaranteed.protein_g), true);
assert.equal(Number.isFinite(textOnlyCaloriesGuaranteed.carbs_g), true);
assert.equal(Number.isFinite(textOnlyCaloriesGuaranteed.fat_g), true);

const parsedCaloriesGuaranteed = await guaranteeRecipeDisplayMacros({
  title: "Mystery tray bake",
  servings_text: "4 servings",
  servings_count: 4,
  est_calories_text: "Approximately 420 kcal per serving (estimate)",
  ingredients: [
    { display_name: "Prepared filling", quantity_text: null },
    { display_name: "Prepared sauce", quantity_text: null },
  ],
  steps: [
    { text: "Assemble and bake until hot." },
  ],
});
assert.equal(hasCompleteDisplayMacros(parsedCaloriesGuaranteed), true);
assert.equal(parsedCaloriesGuaranteed.calories_kcal, 420);

const dedupedPhotoIngredients = await guaranteeRecipeDisplayMacros({
  title: "Spaghetti with meat sauce",
  servings_text: "4 servings",
  servings_count: 4,
  ingredients: [
    { display_name: "ground beef", quantity_text: "500 g" },
    { display_name: "meat sauce", quantity_text: "400 g" },
    { display_name: "canned tomatoes", quantity_text: "400 g" },
    { display_name: "tomato", quantity_text: "400 g" },
    { display_name: "fresh basil", quantity_text: "few leaves" },
    { display_name: "basil", quantity_text: "few leaves" },
    { display_name: "parmesan cheese, grated", quantity_text: "to serve" },
    { display_name: "parmesan cheese", quantity_text: "to serve" },
  ],
  steps: [
    {
      text: "Brown the ground beef, simmer with tomatoes, and serve over pasta with basil and parmesan.",
      ingredients: [
        { display_name: "meat sauce", quantity_text: "400 g" },
        { display_name: "ground meat", quantity_text: null },
        { display_name: "basil", quantity_text: "few leaves" },
        { display_name: "fresh basil", quantity_text: "few leaves" },
        { display_name: "parmesan cheese", quantity_text: "to serve" },
      ],
    },
  ],
});
assert.deepEqual(
  dedupedPhotoIngredients.ingredients.map((ingredient) => ingredient.display_name),
  ["ground beef", "canned tomatoes", "fresh basil", "parmesan cheese, grated"]
);
assert.deepEqual(
  dedupedPhotoIngredients.steps[0].ingredients.map((ingredient) => ingredient.display_name),
  ["ground beef", "fresh basil", "parmesan cheese, grated"]
);

console.log("recipe ingestion cost guard tests passed");
