import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const repoRoot = path.resolve(import.meta.dirname, "../..");
const catalogPath = path.join(
  repoRoot,
  "client/ios/ounje/Features/FirstRunGuide/FirstRunGuideCatalog.v1.json",
);

const envFile = await readEnv(path.join(repoRoot, "server/.env"));
const supabaseURL = String(process.env.SUPABASE_URL ?? envFile.SUPABASE_URL ?? "").replace(/\/+$/, "");
const supabaseAnonKey = String(process.env.SUPABASE_ANON_KEY ?? envFile.SUPABASE_ANON_KEY ?? "");

if (!supabaseURL || !supabaseAnonKey) {
  throw new Error("Set SUPABASE_URL and SUPABASE_ANON_KEY, or provide them in server/.env.");
}

const catalog = JSON.parse(await fs.readFile(catalogPath, "utf8"));
const errors = validateCatalogShape(catalog);
const recipeIDs = allRecipeIDs(catalog);

const [recipes, ingredients, steps] = await Promise.all([
  getRows(
    "recipes",
    "id,title,dietary_tags,discover_card_image_url,hero_image_url,source,source_platform,recipe_url,original_recipe_url,attached_video_url",
    recipeIDs,
  ),
  getRows("recipe_ingredients", "recipe_id,display_name", recipeIDs),
  getRows("recipe_steps", "recipe_id", recipeIDs),
]);

const recipeByID = new Map(recipes.map((recipe) => [recipe.id, recipe]));
const ingredientRowsByRecipe = groupBy(ingredients, "recipe_id");
const stepRowsByRecipe = groupBy(steps, "recipe_id");

for (const recipeID of recipeIDs) {
  const recipe = recipeByID.get(recipeID);
  if (!recipe) {
    errors.push(`Missing recipe ${recipeID}.`);
    continue;
  }
  if (!isTikTokRecipe(recipe)) {
    errors.push(`${recipe.title || recipeID} is not a public TikTok-origin catalog recipe.`);
  }
  const imageURL = recipe.discover_card_image_url || recipe.hero_image_url;
  if (!imageURL) errors.push(`${recipe.title || recipeID} has no usable image URL.`);
  if (!(ingredientRowsByRecipe.get(recipeID)?.length > 0)) {
    errors.push(`${recipe.title || recipeID} has no ingredients.`);
  }
  if (!(stepRowsByRecipe.get(recipeID)?.length > 0)) {
    errors.push(`${recipe.title || recipeID} has no steps.`);
  }
}

for (const preset of catalog.plan_presets ?? []) {
  const ingredientText = preset.recipe_ids
    .flatMap((id) => ingredientRowsByRecipe.get(id) ?? [])
    .map((row) => String(row.display_name ?? "").toLowerCase())
    .join(" ");
  for (const excludedAllergen of preset.allergen_exclusions) {
    if (allergenTerms(excludedAllergen).some((term) => ingredientText.includes(term))) {
      errors.push(`Preset ${preset.id} claims to exclude ${excludedAllergen}, but a plan ingredient contains it.`);
    }
  }

  for (const diet of preset.dietary_compatibility_tags.filter((tag) => tag !== "omnivore")) {
    const acceptedTags = acceptedDietaryTags(diet);
    for (const recipeID of preset.recipe_ids) {
      const tags = (recipeByID.get(recipeID)?.dietary_tags ?? []).map((tag) => String(tag).toLowerCase());
      if (!tags.some((tag) => acceptedTags.has(tag))) {
        errors.push(`Preset ${preset.id} is listed for ${diet}, but recipe ${recipeID} is not compatible.`);
      }
    }
  }
}

for (const [diet, safeRecipeIDs] of Object.entries(catalog.safe_suggestion_ids_by_diet ?? {})) {
  const expectedTag = diet === "keto" ? "low-carb" : diet;
  const acceptedTags = acceptedDietaryTags(diet);
  for (const recipeID of safeRecipeIDs) {
    const tags = (recipeByID.get(recipeID)?.dietary_tags ?? []).map((tag) => String(tag).toLowerCase());
    if (!tags.some((tag) => acceptedTags.has(tag))) {
      errors.push(`Safe fallback ${recipeID} is listed for ${diet} but is not tagged ${expectedTag}.`);
    }
  }
}

function acceptedDietaryTags(diet) {
  if (diet === "dairy-free") return new Set(["dairy-free", "vegan"]);
  if (diet === "vegetarian") return new Set(["vegetarian", "vegan"]);
  if (diet === "keto") return new Set(["keto", "low-carb"]);
  return new Set([diet]);
}

const imageURLs = [...new Set(recipes
  .map((recipe) => recipe.discover_card_image_url || recipe.hero_image_url)
  .filter(Boolean))];
const imageChecks = await Promise.all(imageURLs.map(checkImageURL));
for (const check of imageChecks) {
  if (!check.ok) errors.push(`Image is unavailable: ${check.url} (${check.status}).`);
}

if (errors.length > 0) {
  console.error(`First-run guide catalog failed with ${errors.length} issue(s):`);
  for (const error of errors) console.error(`- ${error}`);
  process.exitCode = 1;
} else {
  console.log(`First-run guide catalog v${catalog.version} is valid.`);
  console.log(`${catalog.plan_presets.length} preset plans, ${catalog.templates.length} onboarding mappings, ${recipeIDs.length} public TikTok recipes, ${imageURLs.length} images checked.`);
}

function validateCatalogShape(value) {
  const issues = [];
  if (!Number.isInteger(value.version) || value.version < 1) issues.push("Catalog version must be a positive integer.");
  if (!Array.isArray(value.templates) || value.templates.length !== 4) issues.push("Catalog must contain the four onboarding seed templates.");
  if (!Array.isArray(value.plan_presets) || value.plan_presets.length === 0) issues.push("Catalog must contain preset plans.");
  const presetsByID = new Map((value.plan_presets ?? []).map((preset) => [preset.id, preset]));
  if (presetsByID.size !== (value.plan_presets ?? []).length) issues.push("Preset plan IDs must be unique.");
  const mappedPresetIDs = new Set();
  const starterRecipeIDs = new Set();
  for (const template of value.templates ?? []) {
    const presetIDs = template.preset_plan_ids ?? [];
    starterRecipeIDs.add(template.seed_recipe_id);
    if (presetIDs.length < 4) {
      issues.push(`Template ${template.seed_recipe_id} must map to at least four preset plans.`);
    }
    if (new Set(presetIDs).size !== presetIDs.length) {
      issues.push(`Template ${template.seed_recipe_id} contains duplicate preset IDs.`);
    }
    for (const presetID of presetIDs) {
      const preset = presetsByID.get(presetID);
      if (!preset) {
        issues.push(`Template ${template.seed_recipe_id} references missing preset ${presetID || "(empty)"}.`);
        continue;
      }
      if (mappedPresetIDs.has(presetID)) {
        issues.push(`Preset ${presetID} is mapped to more than one onboarding seed.`);
      }
      mappedPresetIDs.add(presetID);
      if (!(preset.recipe_ids ?? []).includes(template.seed_recipe_id)) {
        issues.push(`Preset ${presetID} does not include its onboarding seed ${template.seed_recipe_id}.`);
      }
    }
  }
  if (starterRecipeIDs.size !== 4) issues.push("Starter recipes must be four distinct public TikTok imports.");
  for (const preset of value.plan_presets ?? []) {
    const recipeIDs = preset.recipe_ids ?? [];
    if (!preset.id) issues.push("Every preset plan needs a stable ID.");
    if (!preset.title) issues.push(`Preset ${preset.id ?? "(empty)"} needs a title.`);
    if (recipeIDs.length !== 4) issues.push(`Preset ${preset.id} must contain exactly four recipes.`);
    if (new Set(recipeIDs).size !== recipeIDs.length) issues.push(`Preset ${preset.id} contains duplicate recipes.`);
    if (!Array.isArray(preset.dietary_compatibility_tags) || preset.dietary_compatibility_tags.length === 0) {
      issues.push(`Preset ${preset.id} needs dietary compatibility tags.`);
    }
    if (!Array.isArray(preset.allergen_exclusions)) issues.push(`Preset ${preset.id} needs allergen exclusions.`);
    if (!Array.isArray(preset.selection_tags) || preset.selection_tags.length === 0) {
      issues.push(`Preset ${preset.id} needs selection tags.`);
    }
    if (!mappedPresetIDs.has(preset.id)) issues.push(`Preset ${preset.id} is not mapped to an onboarding seed.`);
  }
  return issues;
}

function isTikTokRecipe(recipe) {
  const platformText = [recipe.source, recipe.source_platform]
    .map((value) => String(value ?? "").toLowerCase())
    .join(" ");
  if (platformText.includes("tiktok")) return true;
  return [recipe.recipe_url, recipe.original_recipe_url, recipe.attached_video_url].some((value) => {
    try {
      return new URL(value).hostname.toLowerCase().includes("tiktok.com");
    } catch {
      return false;
    }
  });
}

function allergenTerms(value) {
  switch (String(value ?? "").trim().toLowerCase()) {
  case "shellfish":
    return ["shellfish", "shrimp", "prawn", "crab", "lobster", "crayfish", "oyster", "mussel", "clam", "scallop"];
  case "peanut":
    return ["peanut", "groundnut"];
  default:
    return [String(value ?? "").trim().toLowerCase()].filter(Boolean);
  }
}

function allRecipeIDs(value) {
  return [...new Set([
    ...(value.templates ?? []).flatMap((template) => [
      template.seed_recipe_id,
    ]),
    ...(value.plan_presets ?? []).flatMap((preset) => preset.recipe_ids ?? []),
    ...Object.values(value.safe_suggestion_ids_by_diet ?? {}).flat(),
  ].filter(Boolean))];
}

async function getRows(table, select, recipeIDs) {
  const filterColumn = table === "recipes" ? "id" : "recipe_id";
  const params = new URLSearchParams({ select });
  params.set(filterColumn, `in.(${recipeIDs.join(",")})`);
  const response = await fetch(`${supabaseURL}/rest/v1/${table}?${params}`, {
    headers: {
      apikey: supabaseAnonKey,
      Authorization: `Bearer ${supabaseAnonKey}`,
    },
  });
  if (!response.ok) {
    throw new Error(`${table} lookup failed (${response.status}): ${await response.text()}`);
  }
  return response.json();
}

function groupBy(rows, key) {
  const groups = new Map();
  for (const row of rows) {
    const group = groups.get(row[key]) ?? [];
    group.push(row);
    groups.set(row[key], group);
  }
  return groups;
}

async function checkImageURL(url) {
  try {
    const response = await fetch(url, { method: "HEAD", redirect: "follow" });
    return { url, ok: response.ok, status: response.status };
  } catch (error) {
    return { url, ok: false, status: error instanceof Error ? error.message : "network error" };
  }
}

async function readEnv(filePath) {
  try {
    const contents = await fs.readFile(filePath, "utf8");
    return Object.fromEntries(contents
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("#") && line.includes("="))
      .map((line) => {
        const separator = line.indexOf("=");
        return [line.slice(0, separator), line.slice(separator + 1).replace(/^['"]|['"]$/g, "")];
      }));
  } catch {
    return {};
  }
}
