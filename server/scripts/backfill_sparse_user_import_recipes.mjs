import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";
import { createClient } from "@supabase/supabase-js";
import OpenAI from "openai";
import { nanoid } from "nanoid";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, "../.env") });

const APPLY = process.argv.includes("--apply");
const INCLUDE_DEBUG = process.argv.includes("--include-debug");
const LIMIT_ARG = process.argv.find((arg) => arg.startsWith("--limit="));
const LIMIT = LIMIT_ARG ? Number(LIMIT_ARG.split("=")[1]) : 25;
const MODEL = process.env.RECIPE_IMPORT_COMPLETION_MODEL || "gpt-4o-mini";

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

assert(SUPABASE_URL, "SUPABASE_URL is required");
assert(SUPABASE_SERVICE_ROLE_KEY, "SUPABASE_SERVICE_ROLE_KEY is required");
assert(OPENAI_API_KEY, "OPENAI_API_KEY is required");

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
  },
});
const openai = new OpenAI({ apiKey: OPENAI_API_KEY });

function normalizeText(value) {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

function linesFromIngredients(ingredients = []) {
  return ingredients
    .map((ingredient) => [ingredient.quantity_text, ingredient.display_name].filter(Boolean).join(" ").trim())
    .filter(Boolean)
    .join("\n");
}

function linesFromSteps(steps = []) {
  return steps
    .map((step, index) => normalizeText(step.text ?? step.instruction_text ?? step) || `Step ${index + 1}`)
    .filter(Boolean)
    .join("\n");
}

function isSparse(row) {
  const ingredients = Array.isArray(row.ingredients_json) ? row.ingredients_json : [];
  const steps = Array.isArray(row.steps_json) ? row.steps_json : [];
  const flags = Array.isArray(row.quality_flags) ? row.quality_flags : [];
  const alreadyBackfilled = flags.includes("sparse_import_backfilled");
  return ingredients.length < 4
    || steps.length < 3
    || (!alreadyBackfilled && flags.includes("concept_prompt_fallback"))
    || (!alreadyBackfilled && flags.includes("low_ingredient_count"))
    || (!alreadyBackfilled && flags.includes("low_step_count"))
    || (row.review_state === "adapted_preview" && steps.length === 0);
}

function safeNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function normalizeGeneratedRecipe(row, generated) {
  const recipe = generated?.recipe && typeof generated.recipe === "object" ? generated.recipe : generated;
  const ingredients = Array.isArray(recipe?.ingredients)
    ? recipe.ingredients
        .map((ingredient) => ({
          display_name: normalizeText(ingredient?.display_name ?? ingredient?.name),
          quantity_text: normalizeText(ingredient?.quantity_text ?? ingredient?.quantity) || null,
        }))
        .filter((ingredient) => ingredient.display_name)
        .slice(0, 30)
    : [];
  const steps = Array.isArray(recipe?.steps)
    ? recipe.steps
        .map((step, index) => ({
          number: safeNumber(step?.number) ?? index + 1,
          text: normalizeText(step?.text ?? step?.instruction_text ?? step),
          tip_text: normalizeText(step?.tip_text) || null,
          ingredients: Array.isArray(step?.ingredients)
            ? step.ingredients
                .map((ingredient) => ({
                  display_name: normalizeText(ingredient?.display_name ?? ingredient?.name),
                  quantity_text: normalizeText(ingredient?.quantity_text ?? ingredient?.quantity) || null,
                }))
                .filter((ingredient) => ingredient.display_name)
                .slice(0, 10)
            : [],
        }))
        .filter((step) => step.text)
        .slice(0, 20)
    : [];

  if (ingredients.length < 4 || steps.length < 3) {
    throw new Error(`Generated recipe for ${row.id} is still sparse (${ingredients.length} ingredients, ${steps.length} steps).`);
  }

  return {
    title: normalizeText(recipe?.title) || row.title,
    description: normalizeText(recipe?.description ?? recipe?.summary) || row.description,
    recipe_type: normalizeText(recipe?.recipe_type) || row.recipe_type,
    skill_level: normalizeText(recipe?.skill_level) || row.skill_level,
    cook_time_text: normalizeText(recipe?.cook_time_text) || row.cook_time_text,
    prep_time_minutes: safeNumber(recipe?.prep_time_minutes) ?? row.prep_time_minutes,
    cook_time_minutes: safeNumber(recipe?.cook_time_minutes) ?? row.cook_time_minutes,
    servings_text: normalizeText(recipe?.servings_text) || row.servings_text,
    servings_count: safeNumber(recipe?.servings_count) ?? row.servings_count,
    est_calories_text: normalizeText(recipe?.est_calories_text) || row.est_calories_text,
    calories_kcal: safeNumber(recipe?.calories_kcal) ?? row.calories_kcal,
    protein_g: safeNumber(recipe?.protein_g) ?? row.protein_g,
    carbs_g: safeNumber(recipe?.carbs_g) ?? row.carbs_g,
    fat_g: safeNumber(recipe?.fat_g) ?? row.fat_g,
    main_protein: normalizeText(recipe?.main_protein) || row.main_protein,
    cook_method: normalizeText(Array.isArray(recipe?.cook_method) ? recipe.cook_method[0] : recipe?.cook_method) || row.cook_method,
    cuisine_tags: Array.isArray(recipe?.cuisine_tags) ? recipe.cuisine_tags.map(normalizeText).filter(Boolean).slice(0, 8) : row.cuisine_tags,
    dietary_tags: Array.isArray(recipe?.dietary_tags) ? recipe.dietary_tags.map(normalizeText).filter(Boolean).slice(0, 8) : row.dietary_tags,
    flavor_tags: Array.isArray(recipe?.flavor_tags) ? recipe.flavor_tags.map(normalizeText).filter(Boolean).slice(0, 10) : row.flavor_tags,
    occasion_tags: Array.isArray(recipe?.occasion_tags) ? recipe.occasion_tags.map(normalizeText).filter(Boolean).slice(0, 8) : row.occasion_tags,
    ingredients,
    steps,
  };
}

async function fetchSparseRows() {
  const { data, error } = await supabase
    .from("user_import_recipes")
    .select("*")
    .order("created_at", { ascending: false })
    .limit(250);

  if (error) throw error;

  return (data ?? [])
    .filter((row) => INCLUDE_DEBUG || !["debug-user", "00000000-0000-4000-8000-000000000001"].includes(row.user_id))
    .filter(isSparse)
    .slice(0, Number.isFinite(LIMIT) ? LIMIT : 25);
}

async function generateRepair(row) {
  const response = await openai.chat.completions.create({
    model: MODEL,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: [
          "You repair sparse imported recipe records for Ounje.",
          "Return JSON only with a recipe object.",
          "Preserve the exact dish identity and title unless there is an obvious typo.",
          "Use ordinary mainstream cooking structure for common dishes.",
          "If ingredients already exist, keep them unless they are clearly wrong.",
          "Do not invent source provenance.",
          "The result must be cookable, with at least 5 concrete ingredients and 4 clear steps.",
        ].join("\n"),
      },
      {
        role: "user",
        content: JSON.stringify({
          current_recipe: {
            id: row.id,
            title: row.title,
            description: row.description,
            recipe_type: row.recipe_type,
            cuisine_tags: row.cuisine_tags,
            dietary_tags: row.dietary_tags,
            flavor_tags: row.flavor_tags,
            main_protein: row.main_protein,
            cook_method: row.cook_method,
            servings_text: row.servings_text,
            cook_time_text: row.cook_time_text,
            ingredients: row.ingredients_json,
            steps: row.steps_json,
            ingredients_text: row.ingredients_text,
            instructions_text: row.instructions_text,
            quality_flags: row.quality_flags,
            review_state: row.review_state,
          },
          output_shape: {
            recipe: {
              title: "string",
              description: "string",
              recipe_type: "string",
              skill_level: "string",
              cook_time_text: "string",
              prep_time_minutes: 15,
              cook_time_minutes: 45,
              servings_text: "Serves 4",
              servings_count: 4,
              est_calories_text: "rough per serving estimate",
              calories_kcal: 520,
              protein_g: 28,
              carbs_g: 60,
              fat_g: 18,
              main_protein: "string|null",
              cook_method: "string|null",
              cuisine_tags: ["string"],
              dietary_tags: ["string"],
              flavor_tags: ["string"],
              occasion_tags: ["string"],
              ingredients: [{ display_name: "ingredient", quantity_text: "quantity" }],
              steps: [{ number: 1, text: "instruction", ingredients: [{ display_name: "ingredient", quantity_text: "quantity" }] }],
            },
          },
        }),
      },
    ],
  });

  return normalizeGeneratedRecipe(row, JSON.parse(response.choices?.[0]?.message?.content ?? "{}"));
}

async function replaceChildRows(row, repaired) {
  const { data: existingSteps, error: stepFetchError } = await supabase
    .from("user_import_recipe_steps")
    .select("id")
    .eq("recipe_id", row.id);
  if (stepFetchError) throw stepFetchError;

  const existingStepIDs = (existingSteps ?? []).map((step) => step.id).filter(Boolean);
  if (existingStepIDs.length) {
    const { error } = await supabase
      .from("user_import_recipe_step_ingredients")
      .delete()
      .in("recipe_step_id", existingStepIDs);
    if (error) throw error;
  }

  for (const table of ["user_import_recipe_ingredients", "user_import_recipe_steps"]) {
    const { error } = await supabase.from(table).delete().eq("recipe_id", row.id);
    if (error) throw error;
  }

  const ingredientRows = repaired.ingredients.map((ingredient, index) => ({
    id: `uiri_${nanoid(12)}`,
    recipe_id: row.id,
    display_name: ingredient.display_name,
    quantity_text: ingredient.quantity_text,
    sort_order: index + 1,
  }));
  const stepRows = repaired.steps.map((step, index) => ({
    id: `uirs_${nanoid(12)}`,
    recipe_id: row.id,
    step_number: index + 1,
    instruction_text: step.text,
    tip_text: step.tip_text ?? null,
  }));
  const ingredientByKey = new Map(repaired.ingredients.map((ingredient) => [normalizeText(ingredient.display_name).toLowerCase(), ingredient]));
  const stepIngredientRows = repaired.steps.flatMap((step, stepIndex) => {
    const stepID = stepRows[stepIndex]?.id;
    return (step.ingredients ?? [])
      .map((ingredient, index) => {
        const displayName = normalizeText(ingredient.display_name);
        if (!displayName || !stepID) return null;
        const canonical = ingredientByKey.get(displayName.toLowerCase());
        return {
          id: `uirsi_${nanoid(12)}`,
          recipe_step_id: stepID,
          display_name: displayName,
          quantity_text: normalizeText(ingredient.quantity_text) || canonical?.quantity_text || null,
          sort_order: index + 1,
        };
      })
      .filter(Boolean);
  });

  if (ingredientRows.length) {
    const { error } = await supabase.from("user_import_recipe_ingredients").insert(ingredientRows);
    if (error) throw error;
  }
  if (stepRows.length) {
    const { error } = await supabase.from("user_import_recipe_steps").insert(stepRows);
    if (error) throw error;
  }
  if (stepIngredientRows.length) {
    const { error } = await supabase.from("user_import_recipe_step_ingredients").insert(stepIngredientRows);
    if (error) throw error;
  }
}

async function updateRecipeRow(row, repaired) {
  const staleFlags = new Set(["low_ingredient_count", "low_step_count"]);
  const nextFlags = Array.from(new Set([
    ...(row.quality_flags ?? []).filter((flag) => !staleFlags.has(flag)),
    "sparse_import_backfilled",
  ]));
  const patch = {
    description: repaired.description,
    recipe_type: repaired.recipe_type,
    skill_level: repaired.skill_level,
    cook_time_text: repaired.cook_time_text,
    servings_text: repaired.servings_text,
    est_calories_text: repaired.est_calories_text,
    calories_kcal: repaired.calories_kcal,
    protein_g: repaired.protein_g,
    carbs_g: repaired.carbs_g,
    fat_g: repaired.fat_g,
    prep_time_minutes: repaired.prep_time_minutes,
    cook_time_minutes: repaired.cook_time_minutes,
    dietary_tags: repaired.dietary_tags,
    flavor_tags: repaired.flavor_tags,
    cuisine_tags: repaired.cuisine_tags,
    occasion_tags: repaired.occasion_tags,
    main_protein: repaired.main_protein,
    cook_method: repaired.cook_method,
    ingredients_text: linesFromIngredients(repaired.ingredients),
    instructions_text: linesFromSteps(repaired.steps),
    ingredients_json: repaired.ingredients,
    steps_json: repaired.steps,
    servings_count: repaired.servings_count,
    review_state: row.review_state === "adapted_preview" ? "adapted_preview" : "approved",
    confidence_score: Math.max(Number(row.confidence_score ?? 0), 0.86),
    quality_flags: nextFlags,
  };

  const { error } = await supabase
    .from("user_import_recipes")
    .update(patch)
    .eq("id", row.id);
  if (error) throw error;
}

const rows = await fetchSparseRows();
console.log(`[backfill] Found ${rows.length} sparse imported recipe rows${APPLY ? "" : " (dry run)"}.`);

for (const row of rows) {
  const beforeIngredients = Array.isArray(row.ingredients_json) ? row.ingredients_json.length : 0;
  const beforeSteps = Array.isArray(row.steps_json) ? row.steps_json.length : 0;
  const repaired = await generateRepair(row);
  console.log(`[backfill] ${row.id} ${row.title}: ${beforeIngredients}/${beforeSteps} -> ${repaired.ingredients.length}/${repaired.steps.length}`);
  if (!APPLY) continue;
  await updateRecipeRow(row, repaired);
  await replaceChildRows(row, repaired);
}

console.log(APPLY ? "[backfill] Applied sparse import repairs." : "[backfill] Dry run complete. Re-run with --apply to update production.");
