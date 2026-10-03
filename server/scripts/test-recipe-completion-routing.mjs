// Real lookup, merge, and normalization; only provider/HTTP boundaries are doubled.
import assert from 'node:assert/strict';
for (const key of ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'REDIS_URL']) process.env[key] = '';
process.env.OPENAI_API_KEY = 'test-only';
process.env.PERPLEXITY_API_KEY = 'test-only';
process.env.REDIS_DISABLED = 'true';
process.env.OUNJE_ENABLE_AI_CALL_LOGGING = 'false';
const { Completions } = await import('openai/resources/chat/completions/completions');
const { Responses } = await import('openai/resources/responses/responses');
let recipe, schema, searchHost, calls, providerPatch;
let stepsComplete = true;
const source = () => ({ source_type: 'tiktok', title: recipe.title, author_handle: 'testkitchen', description: 'Full recipe on my blog, link in bio.', source_url: 'https://www.tiktok.com/@testkitchen/video/12345', frame_data_urls: ['data:image/jpeg;base64,AA=='] });
Responses.prototype.create = async () => {
  calls.push('search');
  return { output_text: JSON.stringify({ links: [{ title: recipe.title, url: `https://${searchHost}/recipe` }] }) };
};
Completions.prototype.create = async (payload) => {
  const text = JSON.stringify(payload.messages);
  calls.push(text.includes('Check all attached frames') ? 'validate' : text.includes('Fill only low-risk missing') ? 'light_fill' : 'extract_or_complete');
  return { choices: [{ message: { content: JSON.stringify({ recipe: providerPatch ?? recipe, quality_flags: ['partial_ingredients', 'partial_steps', 'quantities_inferred'], source_completeness: { ingredients_complete: true, steps_complete: stepsComplete } }) } }] };
};
globalThis.fetch = async (input) => {
  const url = new URL(String(input));
  if (url.hostname === 'duckduckgo.com') return new Response('<html></html>');
  if (url.hostname === searchHost) return new Response(`<html><title>${schema.name}</title><script type="application/ld+json">${JSON.stringify(schema)}</script><body>${'Recipe context. '.repeat(50)}</body></html>`);
  if (url.hostname === 'api.perplexity.ai') {
    calls.push('research');
    return Response.json({ choices: [{ message: { content: JSON.stringify({ exact_match_supported: false, match_confidence: 0.4, reference_urls: [`https://${searchHost}/recipe`], completion_ingredients: schema.recipeIngredient, completion_steps: schema.recipeInstructions }) } }] });
  }
  throw new Error(`Unexpected HTTP access: ${url.hostname}`);
};
const { completeImportedRecipeWithWebEvidence, buildNormalizedRecipe, validateAndRepairImportedRecipe, reconcileResolvedRecipeQualityFlags, buildFinalRecipeValidationIssues } = await import('../lib/recipe-ingestion.js');
const ingredient = (display_name, quantity_text) => ({ display_name, quantity_text });
for (const fixture of [
  { title: 'Pesto pasta', ingredients: [ingredient('basil', '50 g'), ingredient('pine nuts', '30 g'), ingredient('olive oil', '60 ml'), ingredient('pasta', '200 g')] },
  { title: 'Lemon tart', ingredients: [ingredient('lemon juice', '120 ml'), ingredient('sugar', '100 g'), ingredient('butter', '80 g'), ingredient('egg yolks', '4')] },
  { title: 'Praline dessert', ingredients: [ingredient('hazelnuts', '100 g'), ingredient('sugar', '150 g'), ingredient('dark chocolate', '100 g'), ingredient('heavy cream', '200 ml')] },
]) {
  recipe = { ...fixture, servings_text: '4 servings', servings_count: 4, prep_time_minutes: 10, cook_time_minutes: 20, cook_time_text: '30 min', skill_level: null, calories_kcal: 400, protein_g: 10, carbs_g: 40, fat_g: 20, hero_image_url: 'https://testkitchen.com/photo.jpg', steps: [
    { number: 1, text: `Combine ${fixture.ingredients.slice(0, 2).map(i => i.display_name).join(' and ')} in a bowl.` },
    { number: 2, text: `Add ${fixture.ingredients.slice(2).map(i => i.display_name).join(' and ')} and cook for 20 minutes.` },
  ] };
  schema = { '@context': 'https://schema.org', '@type': 'Recipe', name: recipe.title, recipeIngredient: recipe.ingredients.map(i => `${i.quantity_text} ${i.display_name}`), recipeInstructions: recipe.steps.map(s => s.text), recipeYield: '4 servings', prepTime: 'PT10M', cookTime: 'PT20M', totalTime: 'PT30M' };
  searchHost = 'testkitchen.com'; calls = [];
  const matchedSource = source();
  const matched = await completeImportedRecipeWithWebEvidence(recipe, matchedSource);
  assert.ok(matchedSource.creator_recipe_reference, 'matching creator page is verified');
  assert.deepEqual(calls, ['search', 'extract_or_complete'], 'verified source skips broad research');
  assert.ok(!matched.quality_flags.includes('perplexity_completion_context'), 'do not claim a provider was called when it was skipped');
  assert.deepEqual(buildFinalRecipeValidationIssues(matched.recipe, matchedSource), []);

  calls = [];
  const normalized = await buildNormalizedRecipe(source());
  assert.ok(calls.includes('validate'), 'final validation remains mandatory');
  assert.ok(!calls.includes('light_fill'), 'complete source fields avoid pre-lookup estimates');
  assert.ok(!normalized.quality_flags.includes('partial_ingredients'));
  assert.ok(!normalized.normalized_recipe.quality_flags.includes('partial_steps'), 'nested flags cannot reintroduce resolved issues');
  assert.ok(normalized.quality_flags.includes('quantities_inferred'), 'inference provenance remains');
  const history = normalized.normalized_recipe.source_provenance_json.quality_history;
  assert.ok(history.observed_flags.includes('partial_steps'));
  assert.ok(history.resolved_flags.includes('partial_steps'));

  stepsComplete = false;
  const incompleteMethod = await validateAndRepairImportedRecipe(recipe, matchedSource);
  assert.equal(incompleteMethod.verified_complete, false, 'unverified method completeness must retain partial warnings');
  assert.ok(reconcileResolvedRecipeQualityFlags(incompleteMethod.recipe, ['partial_steps', ...incompleteMethod.quality_flags], { source: matchedSource, verifiedComplete: incompleteMethod.verified_complete }).includes('partial_steps'));
  stepsComplete = true;

  // A model's claim of completeness cannot erase a real missing ingredient.
  const incomplete = { ...recipe, ingredients: recipe.ingredients.slice(1) };
  providerPatch = incomplete;
  const rejected = await validateAndRepairImportedRecipe(incomplete, matchedSource);
  assert.equal(rejected.verified_complete, false);
  const warnings = ['partial_ingredients', 'partial_steps', 'quantities_inferred', ...rejected.quality_flags];
  assert.ok(reconcileResolvedRecipeQualityFlags(rejected.recipe, warnings, { source: matchedSource, verifiedComplete: rejected.verified_complete }).includes('partial_ingredients'));
  providerPatch = null;
  assert.ok(reconcileResolvedRecipeQualityFlags(recipe, ['partial_steps', 'final_validator_checked'], { source: matchedSource }).includes('partial_steps'), 'no explicit completeness attestation means no clearing');

  searchHost = 'anothercook.com'; calls = [];
  const otherCreator = source();
  await completeImportedRecipeWithWebEvidence(recipe, otherCreator);
  assert.equal(otherCreator.creator_recipe_reference, null);
  assert.deepEqual(calls.slice(0, 2), ['search', 'research'], 'wrong creator retains broader research fallback');

  searchHost = 'testkitchen.com'; schema.name = 'Unrelated roasted vegetables'; calls = [];
  const otherDish = source();
  await completeImportedRecipeWithWebEvidence(recipe, otherDish);
  assert.equal(otherDish.creator_recipe_reference, null);
  assert.ok(calls.includes('research'), 'same creator but wrong dish retains research');

  schema.name = `Strawberry ${recipe.title}`; calls = [];
  await completeImportedRecipeWithWebEvidence(recipe, source());
  assert.ok(calls.includes('research'), 'similar title with an extra flavor must not bypass research');

  schema.name = recipe.title; schema.recipeIngredient = schema.recipeIngredient.slice(0, 2); calls = [];
  const sparseSource = source();
  await completeImportedRecipeWithWebEvidence(recipe, sparseSource);
  assert.equal(sparseSource.creator_recipe_reference, null);
  assert.ok(calls.includes('research'), 'sparse written evidence cannot enable the shortcut');

  calls = [];
  await completeImportedRecipeWithWebEvidence(recipe, { ...source(), description: '' });
  assert.equal(calls[0], 'research', 'ordinary social imports preserve the existing research-first route');
}
console.log('completion routing: 3 dishes preserve validation, research fallbacks, unresolved warnings, and quality history');
