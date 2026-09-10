// Exercise shared source checks and the real validator merge with adversarial
// provider responses. No live providers, database, queue, or storage are used.
import assert from 'node:assert/strict';
for (const key of ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'REDIS_URL', 'PERPLEXITY_API_KEY']) process.env[key] = '';
process.env.OPENAI_API_KEY = 'test-only';
process.env.REDIS_DISABLED = 'true';
process.env.OUNJE_ENABLE_AI_CALL_LOGGING = 'false';
globalThis.fetch = async () => { throw new Error('Unexpected network access in source-integrity test'); };
const { Completions } = await import('openai/resources/chat/completions/completions');
let response;
let providerCalls = 0;
Completions.prototype.create = async () => {
  providerCalls += 1;
  return { choices: [{ message: { content: JSON.stringify(response) } }] };
};
const {
  sourceRecipeIngredientIssues, sourceRecipeQuantityIssues,
  validateAndRepairImportedRecipe, calibrateSocialRecipeAssessment,
  assessSocialCompletionContext, recipeExtractionModelForSource, SOCIAL_VIDEO_RECIPE_MODEL,
  buildFinalRecipeValidationIssues,
} = await import('../lib/recipe-ingestion.js');
const ingredient = (display_name, quantity_text) => ({ display_name, quantity_text });
const fixtures = [
  { title: 'Pesto pasta', component: 'pesto', ingredients: [ingredient('basil', '50 g'), ingredient('pine nuts', '30 g'), ingredient('parmesan cheese', '40 g'), ingredient('olive oil', '60 ml'), ingredient('pasta', '200 g')] },
  { title: 'Lemon tart', component: 'lemon curd', ingredients: [ingredient('lemon juice', '120 ml'), ingredient('sugar', '100 g'), ingredient('butter', '80 g'), ingredient('egg yolks', '4'), ingredient('pastry shell', '1')] },
  { title: 'Praline dessert', component: 'praline', ingredients: [ingredient('hazelnuts', '100 g'), ingredient('sugar', '150 g'), ingredient('dark chocolate', '100 g'), ingredient('heavy cream', '200 ml')] },
];
for (const fixture of fixtures) {
  const recipe = { title: fixture.title, ingredients: fixture.ingredients, steps: [
    { text: `Make the ${fixture.component}: Combine ${fixture.ingredients.slice(0, 2).map((i) => i.display_name).join(' and ')}.` },
    { text: `Use ${fixture.ingredients.slice(2).map((i) => i.display_name).join(', ')} to finish the dish.` },
    { text: `Add the ${fixture.component} and serve.` },
  ] };
  const source = { source_type: 'tiktok', frame_data_urls: ['data:image/jpeg;base64,AA=='], creator_recipe_reference: { structured_recipe: {
    recipeIngredient: fixture.ingredients.map((i) => `${i.quantity_text} ${i.display_name}`),
    recipeInstructions: recipe.steps.map((s) => s.text),
  } } };
  assert.deepEqual(sourceRecipeIngredientIssues(recipe, source), [], fixture.title);
  const duplicate = { ...recipe, ingredients: [...recipe.ingredients, ingredient(fixture.component, '50 g')] };
  assert.ok(sourceRecipeIngredientIssues(duplicate, source).some((issue) => issue.includes('prepared component')), `${fixture.component} is made, not purchased`);
  const permitted = structuredClone(source);
  permitted.creator_recipe_reference.structured_recipe.recipeIngredient.push(`50 g ${fixture.component}`);
  assert.deepEqual(sourceRecipeIngredientIssues(duplicate, permitted), [], 'an explicitly listed prepared product remains allowed');

  // The provider attempts to corrupt a valid recipe by adding its own component.
  response = { recipe: duplicate };
  const rejected = await validateAndRepairImportedRecipe(recipe, source);
  assert.equal(rejected.applied, false, `${fixture.title}: reject the provider's duplicate shopping item`);
  assert.equal(rejected.recipe.ingredients.length, recipe.ingredients.length);
  assert.equal(rejected.review_reason, null, 'a rejected bad candidate must not taint the accepted good recipe');

  const missing = { ...recipe, ingredients: recipe.ingredients.slice(1) };
  response = { recipe };
  const restored = await validateAndRepairImportedRecipe(missing, source);
  assert.equal(restored.applied, true, `${fixture.title}: restore a missing source ingredient`);
  assert.deepEqual(sourceRecipeIngredientIssues(restored.recipe, source), []);

  response = { recipe: missing };
  const unresolved = await validateAndRepairImportedRecipe(missing, source);
  assert.ok(unresolved.quality_flags.includes('final_validator_review_needed'), 'failed repair cannot approve incomplete source ingredients');
  assert.equal(calibrateSocialRecipeAssessment({ confidence_score: 0.99 }, unresolved.recipe, source, unresolved.quality_flags).review_state, 'draft');
}

// Divided quantities are independent of dish, ingredient, and social platform.
for (const [name, unit, parts] of [['butter', 'g', [80, 20]], ['olive oil', 'ml', [30, 15]], ['flour', 'g', [200, 50]]]) {
  const source = { creator_recipe_reference: { structured_recipe: { recipeIngredient: parts.map((amount) => `${amount} ${unit} ${name}`) } } };
  const total = parts.reduce((a, b) => a + b, 0);
  assert.deepEqual(sourceRecipeQuantityIssues({ ingredients: [ingredient(name, `${total} ${unit}, divided`)] }, source), []);
  assert.deepEqual(sourceRecipeQuantityIssues({ ingredients: [ingredient(name, parts.map((amount) => `${amount} ${unit}`).join(' plus '))] }, source), []);
  assert.equal(sourceRecipeQuantityIssues({ ingredients: [ingredient(name, `${parts[0]} ${unit}`)] }, source).length, 1, 'dropping the second component is detected');
}
for (const source_type of ['tiktok', 'instagram', 'youtube']) {
  assert.equal(recipeExtractionModelForSource({ source_type, frame_data_urls: ['frame'], transcript_text: '', frame_ocr_texts: [] }), SOCIAL_VIDEO_RECIPE_MODEL);
}
for (const reference of ['https://www.tiktok.com/@cook/video/123', 'https://www.instagram.com/reel/123/', 'https://www.youtube.com/watch?v=123']) {
  const context = { exact_match_supported: true, match_confidence: 0.99, reference_urls: [reference], source_supported_ingredients: ['basil', 'pine nuts', 'parmesan cheese', 'olive oil'], source_supported_steps: ['Blend the basil with pine nuts until combined.', 'Add the parmesan cheese and olive oil to finish.'] };
  assert.equal(assessSocialCompletionContext(context).hasDetails, false, 'self-citation is not independent recipe research');
}
assert.equal(providerCalls, fixtures.length * 3);
for (const [primary, alternative] of [['vanilla bean', 'vanilla extract'], ['butter', 'coconut oil']]) {
  const source = { creator_recipe_reference: { structured_recipe: {
    recipeIngredient: [`1 tsp ${primary} or 1 tsp ${alternative}`],
    recipeInstructions: [`Add the ${primary} to the pan.`, `If using ${alternative}, stir it in now.`],
  } } };
  const ingredients = [ingredient(alternative, '1 tsp')];
  const singleAddition = { ingredients, steps: [{ text: `If using ${alternative}, stir it in now.` }] };
  const doubleAddition = { ingredients, steps: [{ text: `Add the ${primary} or ${alternative} to the pan.` }, ...singleAddition.steps] };
  assert.ok(!buildFinalRecipeValidationIssues(singleAddition, source).some((issue) => issue.startsWith('Source alternative')));
  assert.ok(buildFinalRecipeValidationIssues(doubleAddition, source).some((issue) => issue.startsWith('Source alternative')), 'an alternative must not be added at both preparation times');
  const legitimatelyDivided = structuredClone(source);
  legitimatelyDivided.creator_recipe_reference.structured_recipe.recipeInstructions = doubleAddition.steps.map((step) => step.text);
  assert.ok(!buildFinalRecipeValidationIssues(doubleAddition, legitimatelyDivided).some((issue) => issue.startsWith('Source alternative')), 'source-supported repeated additions remain allowed');
}
console.log('source integrity: 3 dishes, 9 adversarial validator responses, divided quantities and 3 social platforms passed');
