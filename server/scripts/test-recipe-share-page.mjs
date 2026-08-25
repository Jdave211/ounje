import assert from "node:assert/strict";
import { renderRecipeSharePage } from "../lib/recipe-share-links.js";

const ingredientCount = 18;
const stepCount = 8;
const ingredients = Array.from({ length: ingredientCount }, (_, index) => ({
  display_name: `Ingredient ${index + 1}`,
  quantity_text: `${index + 1} tbsp`,
  image_url: `https://images.example.com/ingredient-${index + 1}.jpg`,
}));
const steps = Array.from({ length: stepCount }, (_, index) => ({
  number: index + 1,
  text: `Complete cooking step ${index + 1}.`,
}));

const html = renderRecipeSharePage({
  app_url: "net.ounje://r/share-test",
  web_url: "https://ounje.example/r/share-test",
  snapshot_json: {
    recipe_card: { title: "Peppered Grilled Fish" },
    recipe_detail: {
      title: "Peppered Grilled Fish",
      description: "Whole grilled fish finished with a rich pepper sauce.",
      author_handle: "ounje",
      source_platform: "TikTok",
      original_recipe_url: "https://www.tiktok.com/@ounje/video/123",
      hero_image_url: "https://images.example.com/fish.jpg",
      cook_time_text: "45 mins",
      servings_count: 4,
      calories_kcal: 410,
      protein_g: 42,
      carbs_g: 12,
      fat_g: 19,
      recipe_type: "Dinner",
      cuisine_tags: ["Nigerian"],
      ingredients,
      steps,
    },
  },
});

assert.match(html, /<title>Peppered Grilled Fish \| Ounje<\/title>/);
assert.match(html, /@ounje/);
assert.match(html, /See original link/);
assert.match(html, /Ingredient 18/);
assert.match(html, /Complete cooking step 8\./);
assert.doesNotMatch(html, /more ingredients in the app/i);
assert.doesNotMatch(html, /preview steps/i);
assert.equal((html.match(/class="ingredient"/g) ?? []).length, ingredientCount);
assert.equal((html.match(/class="step"/g) ?? []).length, stepCount);

console.log("Recipe share page checks passed.");
