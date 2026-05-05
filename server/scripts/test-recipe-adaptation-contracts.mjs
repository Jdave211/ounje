import assert from "node:assert/strict";

process.env.OPENAI_API_KEY = "";
process.env.SUPABASE_URL = "";
process.env.SUPABASE_ANON_KEY = "";

const {
  getRecipeAdaptationContract,
  validateAdaptedRecipe,
} = await import("../lib/recipe-adaptation-contracts.js");

const baseChickenRecipe = {
  id: "recipe_chicken",
  title: "Crispy Chicken Wraps",
  description: "Crunchy chicken wraps with a creamy sauce.",
  cook_time_text: "45 mins",
  cook_time_minutes: 45,
  dietary_tags: [],
  ingredients: [
    { display_name: "Chicken breast", quantity_text: "1 pound" },
    { display_name: "Flour", quantity_text: "1 cup" },
    { display_name: "Eggs", quantity_text: "2" },
    { display_name: "Whole milk", quantity_text: "1 cup" },
    { display_name: "White sugar", quantity_text: "1 tablespoon" },
    { display_name: "Cayenne pepper", quantity_text: "1 teaspoon" },
    { display_name: "Tortillas", quantity_text: "4" },
  ],
  steps: [
    { text: "Cut the chicken breast into strips." },
    { text: "Whisk eggs with whole milk, flour, sugar, and cayenne." },
    { text: "Coat the chicken strips in batter and fry until crisp." },
    { text: "Wrap the fried chicken in tortillas with sauce." },
  ],
};

function recipe(overrides = {}) {
  return {
    title: overrides.title ?? "Adapted Crispy Chicken Wraps",
    summary: overrides.summary ?? "A rewritten version.",
    cook_time_text: overrides.cook_time_text ?? "40 mins",
    ingredients: overrides.ingredients ?? [
      { display_name: "Chicken breast", quantity_text: "1 pound" },
      { display_name: "Flour", quantity_text: "1 cup" },
      { display_name: "Eggs", quantity_text: "2" },
      { display_name: "Whole milk", quantity_text: "1 cup" },
      { display_name: "White sugar", quantity_text: "1 tablespoon" },
      { display_name: "Cayenne pepper", quantity_text: "1 teaspoon" },
      { display_name: "Tortillas", quantity_text: "4" },
    ],
    steps: overrides.steps ?? [
      "Cut the chicken breast into strips.",
      "Whisk eggs with whole milk, flour, sugar, and cayenne.",
      "Coat the chicken strips in batter and fry until crisp.",
      "Wrap the fried chicken in tortillas with sauce.",
    ],
    dietary_fit: overrides.dietary_fit ?? [],
    edit_summary: {
      changed_ingredients: [],
      changed_quantities: [],
      changed_steps: [],
      added_ingredients: [],
      removed_ingredients: [],
      validation_notes: [],
    },
  };
}

{
  const validation = validateAdaptedRecipe({
    baseDetail: baseChickenRecipe,
    adaptedRecipe: recipe({ title: "Vegetarian Crispy Wraps" }),
    contract: getRecipeAdaptationContract("vegetarian"),
  });
  assert.equal(validation.valid, false);
  assert(validation.failures.some((failure) => /no ingredients|changed no ingredients/i.test(failure)));
}

{
  const validation = validateAdaptedRecipe({
    baseDetail: baseChickenRecipe,
    adaptedRecipe: recipe({
      title: "Vegetarian Crispy Chickpea Wraps",
      ingredients: [
        { display_name: "Chickpeas", quantity_text: "2 cups" },
        { display_name: "Flour", quantity_text: "3/4 cup" },
        { display_name: "Eggs", quantity_text: "2" },
        { display_name: "Whole milk", quantity_text: "1 cup" },
        { display_name: "Cayenne pepper", quantity_text: "1 teaspoon" },
        { display_name: "Tortillas", quantity_text: "4" },
      ],
      steps: [
        "Mash the chickpeas until chunky.",
        "Whisk eggs with milk, flour, and cayenne.",
        "Form chickpea patties and pan-fry until crisp.",
        "Wrap the patties in tortillas with sauce.",
      ],
      dietary_fit: ["vegetarian"],
    }),
    contract: getRecipeAdaptationContract("vegetarian"),
  });
  assert.equal(validation.valid, true);
  assert(validation.editSummary.added_ingredients.includes("Chickpeas"));
  assert(validation.editSummary.removed_ingredients.includes("Chicken breast"));
}

{
  const validation = validateAdaptedRecipe({
    baseDetail: baseChickenRecipe,
    adaptedRecipe: recipe({
      title: "Dairy-Free Crispy Chicken Wraps",
      ingredients: [
        { display_name: "Chicken breast", quantity_text: "1 pound" },
        { display_name: "Flour", quantity_text: "1 cup" },
        { display_name: "Eggs", quantity_text: "2" },
        { display_name: "Oat milk", quantity_text: "1 cup" },
        { display_name: "White sugar", quantity_text: "1 tablespoon" },
        { display_name: "Cayenne pepper", quantity_text: "1 teaspoon" },
        { display_name: "Tortillas", quantity_text: "4" },
      ],
      steps: [
        "Cut the chicken breast into strips.",
        "Whisk eggs with oat milk, flour, sugar, and cayenne.",
        "Coat the chicken strips in dairy-free batter and fry until crisp.",
        "Wrap the fried chicken in tortillas with sauce.",
      ],
      dietary_fit: ["dairy-free"],
    }),
    contract: getRecipeAdaptationContract("dairy_free"),
  });
  assert.equal(validation.valid, true);
}

{
  const validation = validateAdaptedRecipe({
    baseDetail: baseChickenRecipe,
    adaptedRecipe: recipe({
      title: "Less Sweet Crispy Chicken Wraps",
      ingredients: [
        { display_name: "Chicken breast", quantity_text: "1 pound" },
        { display_name: "Flour", quantity_text: "1 cup" },
        { display_name: "Eggs", quantity_text: "2" },
        { display_name: "Whole milk", quantity_text: "1 cup" },
        { display_name: "White sugar", quantity_text: "1 teaspoon" },
        { display_name: "Cayenne pepper", quantity_text: "1 teaspoon" },
        { display_name: "Tortillas", quantity_text: "4" },
      ],
      steps: [
        "Cut the chicken breast into strips.",
        "Whisk eggs with whole milk, flour, a small teaspoon of sugar, and cayenne.",
        "Coat the chicken strips in the less-sweet batter and fry until crisp.",
        "Wrap the fried chicken in tortillas with sauce.",
      ],
    }),
    contract: getRecipeAdaptationContract("less_sugar"),
  });
  assert.equal(validation.valid, true);
}

{
  const validation = validateAdaptedRecipe({
    baseDetail: baseChickenRecipe,
    adaptedRecipe: recipe({
      title: "Higher-Protein Crispy Chicken Wraps",
      ingredients: [
        { display_name: "Chicken breast", quantity_text: "1 1/2 pounds" },
        { display_name: "Greek yogurt", quantity_text: "1/2 cup" },
        { display_name: "Flour", quantity_text: "3/4 cup" },
        { display_name: "Eggs", quantity_text: "2" },
        { display_name: "Cayenne pepper", quantity_text: "1 teaspoon" },
        { display_name: "Tortillas", quantity_text: "4" },
      ],
      steps: [
        "Cut the extra chicken breast into strips.",
        "Whisk Greek yogurt with eggs, flour, and cayenne.",
        "Coat the chicken strips in the protein-rich batter and fry until crisp.",
        "Wrap the fried chicken in tortillas with sauce.",
      ],
    }),
    contract: getRecipeAdaptationContract("more_protein"),
  });
  assert.equal(validation.valid, true);
}

{
  const validation = validateAdaptedRecipe({
    baseDetail: baseChickenRecipe,
    adaptedRecipe: recipe({
      title: "Higher-Protein Crispy Chicken Wraps",
      ingredients: [
        { display_name: "Chicken breast", quantity_text: "1 pound" },
        { display_name: "Extra protein", quantity_text: "1 serving" },
        { display_name: "Flour", quantity_text: "1 cup" },
        { display_name: "Eggs", quantity_text: "2" },
        { display_name: "Tortillas", quantity_text: "4" },
      ],
      steps: [
        "Cut the chicken breast into strips.",
        "Whisk eggs with flour.",
        "Coat and fry the chicken strips until crisp.",
        "Wrap the fried chicken in tortillas.",
      ],
    }),
    contract: getRecipeAdaptationContract("more_protein"),
  });
  assert.equal(validation.valid, false);
  assert(validation.failures.some((failure) => /placeholder ingredient|real, named protein|Use every added ingredient/i.test(failure)));
}

{
  const validation = validateAdaptedRecipe({
    baseDetail: baseChickenRecipe,
    adaptedRecipe: recipe({
      title: "Quick Crispy Chicken Wraps",
      cook_time_text: "25 mins",
      ingredients: [
        { display_name: "Chicken tenders", quantity_text: "1 pound" },
        { display_name: "Seasoned flour", quantity_text: "1 cup" },
        { display_name: "Eggs", quantity_text: "2" },
        { display_name: "Tortillas", quantity_text: "4" },
      ],
      steps: [
        "Use chicken tenders so there is no cutting.",
        "Dip tenders in egg, then seasoned flour.",
        "Pan-fry until crisp and wrap in tortillas.",
      ],
    }),
    contract: getRecipeAdaptationContract("quick"),
  });
  assert.equal(validation.valid, true);
}

console.log("recipe adaptation contract tests passed");
