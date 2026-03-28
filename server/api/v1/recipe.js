import express from "express";
import OpenAI from "openai";
import dotenv from "dotenv";
import { expandFlavorTerms, scoreFlavorAlignment, suggestAdaptationPairings, extractIngredientSignals } from "../../lib/flavorgraph.js";
import { findRecipeStyleExamples } from "../../lib/recipe-corpus.js";
import {
  getActiveRecipeRewriteModel,
  getDiscoverIntentModel,
  readRecipeModelRegistry,
  refreshRecipeFineTuneStatus,
} from "../../lib/recipe-model-registry.js";

const recipe_router = express.Router();

dotenv.config({ path: new URL("../../.env", import.meta.url).pathname });

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";

const openai = OPENAI_API_KEY ? new OpenAI({ apiKey: OPENAI_API_KEY }) : null;

const DISCOVER_INTENT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    user_intent: { type: "string" },
    canonical_query: { type: "string" },
    filter_type: {
      type: "string",
      enum: ["", "breakfast", "lunch", "dinner", "dessert", "vegetarian", "vegan"],
    },
    max_cook_minutes: { type: "integer", minimum: 0, maximum: 240 },
    must_include_terms: {
      type: "array",
      items: { type: "string" },
      maxItems: 8,
    },
    avoid_terms: {
      type: "array",
      items: { type: "string" },
      maxItems: 8,
    },
    semantic_expansion_terms: {
      type: "array",
      items: { type: "string" },
      maxItems: 10,
    },
    lexical_priority_terms: {
      type: "array",
      items: { type: "string" },
      maxItems: 10,
    },
    occasion_terms: {
      type: "array",
      items: { type: "string" },
      maxItems: 6,
    },
  },
  required: [
    "user_intent",
    "canonical_query",
    "filter_type",
    "max_cook_minutes",
    "must_include_terms",
    "avoid_terms",
    "semantic_expansion_terms",
    "lexical_priority_terms",
    "occasion_terms",
  ],
};

const DISCOVER_INTENT_SYSTEM_PROMPT = `You interpret recipe search prompts for Ounje, an agentic meal-prep app.

Take the user's raw prompt plus profile context and return a compact structured search intent.

Rules:
- Understand what the user actually wants, not just literal keywords.
- Keep all extracted terms concise and food-specific.
- filter_type must be one of: breakfast, lunch, dinner, dessert, vegetarian, vegan, or empty string.
- max_cook_minutes should be 0 if no explicit or strongly implied time cap exists.
- must_include_terms should contain dishes, ingredients, cuisine signals, or meal-shape terms that should be heavily favored.
- avoid_terms should contain ingredients or meal styles the user is clearly excluding from the prompt or profile.
- semantic_expansion_terms should include close variants and cuisine/meal concepts that help semantic retrieval.
- lexical_priority_terms should contain exact words or short phrases worth preserving for hybrid text search.
- occasion_terms should capture use-case framing like meal prep, high protein, comfort food, quick lunch, etc.
- Do not invent hard restrictions that were not provided.
- Return only valid JSON matching the schema.`;

const RECIPE_ADAPT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    title: { type: "string" },
    summary: { type: "string" },
    cook_time_text: { type: "string" },
    ingredients: {
      type: "array",
      minItems: 3,
      maxItems: 24,
      items: { type: "string" },
    },
    steps: {
      type: "array",
      minItems: 3,
      maxItems: 12,
      items: { type: "string" },
    },
    substitutions: {
      type: "array",
      maxItems: 8,
      items: { type: "string" },
    },
    pairing_notes: {
      type: "array",
      maxItems: 6,
      items: { type: "string" },
    },
    dietary_fit: {
      type: "array",
      maxItems: 8,
      items: { type: "string" },
    },
  },
  required: ["title", "summary", "cook_time_text", "ingredients", "steps", "substitutions", "pairing_notes", "dietary_fit"],
};

const RECIPE_ADAPT_SYSTEM_PROMPT = `You are Ounje's recipe adaptation model.

You take a base recipe, a user profile, and an adaptation goal, then return a revised recipe that still feels like a real recipe someone would cook.

Rules:
- Respect allergies, hard restrictions, and "never include" foods as absolute.
- Keep the core identity of the dish unless the request explicitly asks for a large change.
- If asked to make it quicker, simplify ingredients and shorten steps without making it incoherent.
- If asked to make it spicier, add heat in a cuisine-appropriate way.
- If asked to make it higher-protein, increase protein plausibly.
- Use the provided flavor-pairing hints as soft guidance, not mandatory additions.
- Return only valid JSON matching the schema.
- Ingredients should be practical grocery-list style lines.
- Steps should be short, concrete, and sequential.
- Do not mention unavailable tools or unsupported cooking methods unless they are already implied by the base recipe.`;

const RECIPE_SHAPE_SYSTEM_PROMPT = `You are Ounje's recipe shaping model.

Turn recipe source material into a clean, complete meal-prep-ready recipe object.

Rules:
- Return only valid JSON matching the schema.
- Preserve the core dish identity.
- Keep ingredient lines practical and grocery-list style.
- Keep the instructions clear, sequential, and cookable.
- Fill in a concise summary if one is missing.
- Respect any provided dietary or cuisine metadata.
- Do not invent long stories or commentary.`;

const DISCOVER_CURATION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    ordered_recipe_ids: {
      type: "array",
      items: { type: "string" },
      minItems: 1,
      maxItems: 18,
    },
  },
  required: ["ordered_recipe_ids"],
};

const DISCOVER_CURATION_SYSTEM_PROMPT = `You are Ounje's discover feed curator.

You receive:
- user profile context
- optional live search intent
- an optional selected filter
- a set of candidate recipes returned from retrieval

Your job is to rank only the provided candidate recipes into the best order for the discover feed.

Rules:
- Only return recipe IDs that exist in the provided candidate set.
- Respect allergies, hard restrictions, and disliked / never-include foods.
- For live searches, prioritize direct relevance first.
- For the initial feed, balance fit, appetite appeal, and variety.
- Prefer recipes that feel cookable, specific, and desirable.
- Avoid near-duplicate recipes when possible unless the query is extremely narrow.
- Return only valid JSON matching the schema.`;

recipe_router.get("/recipe/model-status", async (req, res) => {
  const registry = await refreshRecipeFineTuneStatus();
  return res.json({
    fine_tune: {
      job_id: registry.fineTune.jobId,
      status: registry.fineTune.status,
      fine_tuned_model: registry.fineTune.fineTunedModel,
      last_checked_at: registry.fineTune.lastCheckedAt,
      completed_at: registry.fineTune.completedAt,
      error: registry.fineTune.error,
      training_file: registry.fineTune.trainingFile,
      validation_file: registry.fineTune.validationFile,
    },
    models: {
      discover_intent_model: registry.models.discoverIntentModel,
      recipe_rewrite_base_model: registry.models.recipeRewriteBaseModel,
      recipe_rewrite_active_model: registry.models.recipeRewriteActiveModel,
      recipe_rewrite_effective_model: getActiveRecipeRewriteModel(),
    },
  });
});

recipe_router.get("/recipe/detail/:id", async (req, res) => {
  const recipeId = String(req.params.id ?? "").trim();

  if (!recipeId) {
    return res.status(400).json({ error: "Provide a recipe id." });
  }

  try {
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
      return res.status(500).json({ error: "Recipe detail requires Supabase configuration." });
    }

    const recipe = await fetchRecipeById(recipeId);
    if (!recipe) {
      return res.status(404).json({ error: "Recipe not found." });
    }

    return res.json({
      recipe: normalizeRecipeDetail(recipe),
    });
  } catch (error) {
    console.error("[recipe/detail] detail fetch failed:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

recipe_router.post("/recipe/discover", async (req, res) => {
  const { profile = null, filter = "All", query = "", limit = 30, feedContext = null } = req.body ?? {};

  try {
    if (!openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
      const recipes = await fetchLatestRecipes(limit);
      return res.json({
        recipes,
        filters: deriveDiscoverFilters(recipes),
        rankingMode: "fallback_latest",
      });
    }

    const trimmedQuery = String(query ?? "").trim();
    const llmIntent = trimmedQuery
      ? await inferDiscoverIntentWithLLM({ profile, filter, query: trimmedQuery })
      : null;
    const {
      primaryText,
      secondaryText,
      filterType,
      semanticQuery,
      lexicalQuery,
      richSearchText,
      maxCookMinutes,
      parsedQuery,
    } =
      buildDiscoverQueryContext({ profile, filter, query, llmIntent });

    let rankedIds = [];
    const candidateLimit = Math.max(limit * 2, 48);

    if (trimmedQuery) {
      if (trimmedQuery.length <= 80) {
        console.log(
          `[recipe/discover] query="${trimmedQuery}" filter="${filter}" resolvedFilter="${filterType ?? "null"}" maxCookMinutes="${maxCookMinutes ?? "null"}" exactPhrase="${parsedQuery?.exactPhrase ?? "null"}" lexicalQuery="${lexicalQuery}" intent="${llmIntent?.userIntent ?? "heuristic"}"`
        );
      }
      const [hybridEmbedding, richEmbedding] = await Promise.all([
        embedText(semanticQuery, "text-embedding-3-small"),
        embedText(richSearchText, "text-embedding-3-large"),
      ]);

      const [hybridMatches, richMatches] = await Promise.all([
        callRecipeRpc("match_recipes_hybrid", {
          query_embedding: toPgVector(hybridEmbedding),
          query_text: lexicalQuery,
          match_count: Math.max(limit * 4, 40),
          filter_type: filterType,
          max_cook_minutes: maxCookMinutes,
        }),
        callRecipeRpc("match_recipes_rich", {
          query_embedding: toPgVector(richEmbedding),
          match_count: Math.max(limit * 3, 30),
          filter_type: filterType,
          max_cook_minutes: maxCookMinutes,
        }),
      ]);

      rankedIds = fuseRankedIds(hybridMatches, richMatches, candidateLimit);
    } else {
      const [basicEmbedding, richEmbedding] = await Promise.all([
        embedText(primaryText, "text-embedding-3-small"),
        embedText(secondaryText, "text-embedding-3-large"),
      ]);

      const [basicMatches, richMatches] = await Promise.all([
        callRecipeRpc("match_recipes_basic", {
          query_embedding: toPgVector(basicEmbedding),
          match_count: Math.max(limit * 3, 30),
          filter_type: filterType,
        }),
        callRecipeRpc("match_recipes_rich", {
          query_embedding: toPgVector(richEmbedding),
          match_count: Math.max(limit * 3, 30),
          filter_type: filterType,
        }),
      ]);

      rankedIds = fuseRankedIds(basicMatches, richMatches, candidateLimit);
    }
    let recipes = rankedIds.length > 0
      ? await fetchRecipesByIds(rankedIds)
      : await fetchLatestRecipes(limit);

    if (trimmedQuery) {
      recipes = rerankSearchResults(recipes, parsedQuery, limit, profile);
    }

    recipes = await curateDiscoverRecipesWithLLM({
      recipes,
      profile,
      filter,
      query: trimmedQuery,
      parsedQuery,
      feedContext,
      limit,
    });

    recipes = diversifyDiscoverRecipes({
      recipes,
      profile,
      filter,
      query: trimmedQuery,
      parsedQuery,
      feedContext,
      limit,
    });

    return res.json({
      recipes,
      filters: deriveDiscoverFilters(recipes),
      rankingMode: trimmedQuery ? "hybrid_search_embeddings_llm_finetuned_curated" : "primary_secondary_embeddings_finetuned_curated",
    });
  } catch (error) {
    console.error("[recipe/discover] ranking failed:", error.message);

    try {
      const recipes = await fetchLatestRecipes(limit);
      return res.json({
        recipes,
        filters: deriveDiscoverFilters(recipes),
        rankingMode: "fallback_latest",
      });
    } catch (fallbackError) {
      return res.status(500).json({ error: fallbackError.message });
    }
  }
});

function diversifyDiscoverRecipes({
  recipes,
  profile = null,
  filter = "All",
  query = "",
  parsedQuery = null,
  feedContext = null,
  limit = 30,
}) {
  if (!Array.isArray(recipes) || recipes.length <= 2) return recipes;

  const trimmedQuery = String(query ?? "").trim();
  const filtered = normalizeFilterType(filter);
  const preferredCuisines = new Set((profile?.preferredCuisines ?? []).map((value) => String(value).toLowerCase()));
  const goalTerms = new Set((profile?.mealPrepGoals ?? []).map((value) => String(value).toLowerCase()));
  const favoriteFoods = new Set((profile?.favoriteFoods ?? []).map((value) => String(value).toLowerCase()));
  const daypart = String(feedContext?.daypart ?? "");
  const weekday = String(feedContext?.weekday ?? "");
  const isWeekend = Boolean(feedContext?.isWeekend);
  const weatherMood = String(feedContext?.weatherMood ?? "");
  const temperatureBand = String(feedContext?.temperatureBand ?? "");
  const seasonCue = String(feedContext?.seasonCue ?? "");
  const sweetTreatBias = Number(feedContext?.sweetTreatBias ?? 0.18);
  const coldComfortMode = weatherMood === "rainy" || weatherMood === "snowy" || temperatureBand === "cold";
  const hotRefreshMode = weatherMood === "sunny" || temperatureBand === "hot";
  const seedBase = `${feedContext?.sessionSeed ?? "default"}|${feedContext?.windowKey ?? "now"}|${trimmedQuery}|${filtered ?? "all"}|${weekday}`;

  const scored = recipes.map((recipe, index) => {
    let score = Math.max(0, 200 - index * 3.5);
    const type = String(recipe.recipe_type ?? recipe.category ?? "").toLowerCase();
    const title = String(recipe.title ?? "").toLowerCase();
    const description = String(recipe.description ?? "").toLowerCase();
    const source = String(recipe.source ?? "").toLowerCase();
    const cuisineBlob = `${source} ${(recipe.cuisine_tags ?? []).join(" ").toLowerCase()}`;
    const cookMinutes = parseCookMinutes(recipe.cook_time_text);
    const jitter = stableJitter(`${seedBase}|${recipe.id}`) * (trimmedQuery ? 6 : 18);

    if (daypart === "morning" && type === "breakfast") score += 20;
    if (daypart === "midday" && type === "lunch") score += 18;
    if (daypart === "evening" && type === "dinner") score += 18;
    if (["night", "late-night"].includes(daypart) && ["dessert", "breakfast"].includes(type)) score += 16;
    if (isWeekend && ["dessert", "dinner"].includes(type)) score += 12;

    if (coldComfortMode) {
      if (/(soup|stew|braise|curry|chili|roast|bake|comfort|pasta)/.test(`${title} ${description}`)) score += 14;
      if (/(ice cream|sorbet|smoothie|frozen)/.test(`${title} ${description}`)) score -= 6;
    }

    if (hotRefreshMode) {
      if (/(salad|citrus|grill|grilled|shrimp|bowl|fresh|watermelon|lemon|cold|mango|pineapple|tropical)/.test(`${title} ${description}`)) score += 16;
      if (/(stew|braise|heavy|pot roast)/.test(`${title} ${description}`)) score -= 5;
    }

    if (seasonCue === "summer" && /(grill|corn|berry|peach|watermelon|tomato|fresh)/.test(`${title} ${description}`)) score += 8;
    if (seasonCue === "winter" && /(stew|roast|casserole|braise|soup)/.test(`${title} ${description}`)) score += 8;
    if (sweetTreatBias > 0.25 && /(dessert|cake|cookie|brownie|ice cream|sweet|pudding|tart|cheesecake|bar)/.test(`${title} ${description} ${type}`)) {
      score += sweetTreatBias * 28;
    }

    if (hotRefreshMode && sweetTreatBias > 0.35 && /(dessert|sorbet|ice cream|berry|lemon|peach|watermelon|mango|coconut)/.test(`${title} ${description} ${type}`)) {
      score += 12;
    }

    if (goalTerms.has("speed") || goalTerms.has("minimal cleanup")) {
      if (cookMinutes > 0 && cookMinutes <= 30) score += 10;
    }
    if (goalTerms.has("taste")) {
      if (/(crispy|spicy|butter|roast|smoky|creamy|garlic|jollof)/.test(`${title} ${description}`)) score += 7;
    }
    if (goalTerms.has("variety")) {
      score += stableJitter(`variety|${feedContext?.windowKey ?? "now"}|${recipe.id}`) * 10;
    }

    if (preferredCuisines.size) {
      for (const cuisine of preferredCuisines) {
        if (cuisine && cuisineBlob.includes(cuisine)) {
          score += 12;
          break;
        }
      }
    }

    if (favoriteFoods.size) {
      for (const food of favoriteFoods) {
        if (food && `${title} ${description}`.includes(food)) {
          score += 8;
          break;
        }
      }
    }

    if (filtered && type === filtered) score += 10;
    if (trimmedQuery && parsedQuery?.mustIncludeTerms?.length) {
      for (const term of parsedQuery.mustIncludeTerms) {
        if (`${title} ${description}`.includes(term)) score += 8;
      }
    }

    return { recipe, score: score + jitter };
  });

  const sorted = scored
    .sort((left, right) => right.score - left.score)
    .map((entry) => entry.recipe);

  const rotationPoolSize = trimmedQuery
    ? Math.min(sorted.length, Math.max(limit * 3, 18))
    : Math.min(sorted.length, Math.max(limit * 4, 40));
  const rotationPool = sorted.slice(0, rotationPoolSize);
  const rotationSeed = `${seedBase}|${weatherMood}|${temperatureBand}|${seasonCue}|${sweetTreatBias}`;
  const rotationOffset = rotationPool.length <= 1
    ? 0
    : Math.floor(stableJitter(rotationSeed) * rotationPool.length);
  const rotated = rotationOffset > 0
    ? [...rotationPool.slice(rotationOffset), ...rotationPool.slice(0, rotationOffset), ...sorted.slice(rotationPoolSize)]
    : sorted;

  return selectDiverseRecipes(rotated, {
    limit,
    strictDiversity: !trimmedQuery,
    sweetTreatBias,
    coldComfortMode,
    hotRefreshMode,
  });
}

function selectDiverseRecipes(
  recipes,
  { limit = 30, strictDiversity = true, sweetTreatBias = 0.18, coldComfortMode = false, hotRefreshMode = false } = {}
) {
  if (!Array.isArray(recipes) || recipes.length <= 2) return recipes.slice(0, limit);

  const candidates = [...recipes];
  const selected = [];
  const typeCounts = new Map();
  const sourceCounts = new Map();

  if (coldComfortMode) {
    reserveCuratedSlot(candidates, selected, typeCounts, sourceCounts, {
      targetIndex: 0,
      maxTypeCount: strictDiversity ? 2 : 3,
      maxSourceCount: strictDiversity ? 2 : 3,
      matcher: isComfortRecipe,
    });
  }

  if (hotRefreshMode) {
    reserveCuratedSlot(candidates, selected, typeCounts, sourceCounts, {
      targetIndex: Math.min(selected.length, limit - 1),
      maxTypeCount: strictDiversity ? 2 : 3,
      maxSourceCount: strictDiversity ? 2 : 3,
      matcher: isCoolingRecipe,
    });
  }

  if (sweetTreatBias >= 0.3) {
    reserveCuratedSlot(candidates, selected, typeCounts, sourceCounts, {
      targetIndex: Math.min(Math.max(selected.length, 1), limit - 1),
      maxTypeCount: strictDiversity ? 2 : 3,
      maxSourceCount: strictDiversity ? 2 : 3,
      matcher: isSweetTreatRecipe,
    });
  }

  reserveCuratedSlot(candidates, selected, typeCounts, sourceCounts, {
    targetIndex: Math.min(selected.length > 0 ? 2 : 1, limit - 1),
    maxTypeCount: strictDiversity ? 2 : 3,
    maxSourceCount: strictDiversity ? 2 : 3,
    matcher: isSurpriseRecipe,
  });

  for (const recipe of candidates) {
    if (selected.length >= limit) break;
    const typeKey = normalizeRecipeGroup(recipe.recipe_type ?? recipe.category ?? "other");
    const sourceKey = String(recipe.source ?? "source").toLowerCase();
    const maxTypeCount = strictDiversity ? 2 : 3;
    const maxSourceCount = strictDiversity ? 2 : 3;

    if ((typeCounts.get(typeKey) ?? 0) >= maxTypeCount) continue;
    if ((sourceCounts.get(sourceKey) ?? 0) >= maxSourceCount) continue;

    selected.push(recipe);
    typeCounts.set(typeKey, (typeCounts.get(typeKey) ?? 0) + 1);
    sourceCounts.set(sourceKey, (sourceCounts.get(sourceKey) ?? 0) + 1);
  }

  if (selected.length < limit) {
    for (const recipe of candidates) {
      if (selected.length >= limit) break;
      if (selected.some((candidate) => candidate.id === recipe.id)) continue;
      selected.push(recipe);
    }
  }

  return selected.slice(0, limit);
}

function reserveCuratedSlot(candidates, selected, typeCounts, sourceCounts, { targetIndex = 0, maxTypeCount = 2, maxSourceCount = 2, matcher }) {
  if (!Array.isArray(candidates) || typeof matcher !== "function") return;

  const index = candidates.findIndex((recipe) => {
    if (!matcher(recipe)) return false;
    const typeKey = normalizeRecipeGroup(recipe.recipe_type ?? recipe.category ?? "other");
    const sourceKey = String(recipe.source ?? "source").toLowerCase();
    return (typeCounts.get(typeKey) ?? 0) < maxTypeCount && (sourceCounts.get(sourceKey) ?? 0) < maxSourceCount;
  });

  if (index < 0) return;

  const [recipe] = candidates.splice(index, 1);
  const insertIndex = Math.min(targetIndex, selected.length);
  selected.splice(insertIndex, 0, recipe);
  const typeKey = normalizeRecipeGroup(recipe.recipe_type ?? recipe.category ?? "other");
  const sourceKey = String(recipe.source ?? "source").toLowerCase();
  typeCounts.set(typeKey, (typeCounts.get(typeKey) ?? 0) + 1);
  sourceCounts.set(sourceKey, (sourceCounts.get(sourceKey) ?? 0) + 1);
}

function isComfortRecipe(recipe) {
  const text = recipeDescriptorText(recipe);
  return /(soup|stew|jollof|curry|braise|roast|pasta|creamy|comfort|baked|casserole|beans)/.test(text);
}

function isSweetTreatRecipe(recipe) {
  const type = String(recipe.recipe_type ?? recipe.category ?? "").toLowerCase();
  const text = recipeDescriptorText(recipe);
  return type === "dessert" || /(cake|cookie|brownie|ice cream|sweet|pudding|pie|cheesecake|treat)/.test(text);
}

function isSurpriseRecipe(recipe) {
  const text = recipeDescriptorText(recipe);
  const source = String(recipe.source ?? "").toLowerCase();
  return /(smoky|fiery|fusion|crispy|plantain|moi moi|levan|jollof|brothy|pickled|harissa|gochujang|peri peri)/.test(text)
    || /(african|ethiopian|caribbean|nigerian|korean|thai)/.test(source);
}

function isCoolingRecipe(recipe) {
  const text = recipeDescriptorText(recipe);
  return /(salad|shrimp|citrus|lemon|lime|mango|watermelon|pineapple|coconut|fresh|grilled|bowl|slaw)/.test(text);
}

function recipeDescriptorText(recipe) {
  return `${recipe.title ?? ""} ${recipe.description ?? ""} ${recipe.recipe_type ?? ""} ${recipe.category ?? ""}`.toLowerCase();
}

function normalizeRecipeGroup(value) {
  const lowered = String(value ?? "other").trim().toLowerCase();
  if (!lowered || lowered === "other") return "other";
  if (["breakfast", "lunch", "dinner", "dessert", "vegetarian", "vegan"].includes(lowered)) return lowered;
  return lowered;
}

function stableJitter(input) {
  let hash = 2166136261;
  const text = String(input ?? "");
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return ((hash >>> 0) % 1000) / 1000;
}

recipe_router.post("/recipe/adapt", async (req, res) => {
  const {
    recipe_id: recipeId = "",
    recipe = null,
    adaptation_prompt: adaptationPrompt = "",
    profile = null,
  } = req.body ?? {};

  if (!openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return res.status(500).json({ error: "Recipe adaptation requires OpenAI and Supabase configuration." });
  }

  try {
    const baseRecipe = recipe ?? (recipeId ? await fetchRecipeById(recipeId) : null);
    if (!baseRecipe) {
      return res.status(400).json({ error: "Provide a recipe or recipe_id." });
    }

    const styleExamples = findRecipeStyleExamples({ recipe: baseRecipe, profile, limit: 3 });
    const pairingTerms = suggestAdaptationPairings({
      ingredientsText: baseRecipe.ingredients_text ?? baseRecipe.ingredientsText ?? "",
      adaptationPrompt,
      profile,
      limit: 10,
    });

    const completion = await openai.chat.completions.create({
      model: getActiveRecipeRewriteModel(),
      temperature: 0.55,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "recipe_adaptation",
          strict: true,
          schema: RECIPE_ADAPT_SCHEMA,
        },
      },
      messages: [
        { role: "system", content: RECIPE_ADAPT_SYSTEM_PROMPT },
        {
          role: "user",
          content: JSON.stringify(
            {
              adaptation_prompt: adaptationPrompt,
              profile,
              base_recipe: baseRecipe,
              flavor_pairing_hints: pairingTerms,
              style_examples: styleExamples,
            },
            null,
            2
          ),
        },
      ],
    });

    const content = completion?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || !content.trim()) {
      return res.status(502).json({ error: "The model returned no recipe adaptation." });
    }

    return res.json({
      adapted_recipe: JSON.parse(content),
      pairing_terms: pairingTerms,
      style_examples_used: styleExamples.map((example) => example.title),
      model_mode: "flavorgraph_llm_recipe_adaptation",
      model: getActiveRecipeRewriteModel(),
    });
  } catch (error) {
    console.error("[recipe/adapt] adaptation failed:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

recipe_router.post("/recipe/shape", async (req, res) => {
  const {
    title = "",
    summary = "",
    recipe_type: recipeType = "",
    dietary_tags: dietaryTags = [],
    cuisine_tags: cuisineTags = [],
    cook_time_text: cookTimeText = "",
    ingredients_text: ingredientsText = "",
    instructions_text: instructionsText = "",
    source_recipe = null,
  } = req.body ?? {};

  if (!openai) {
    return res.status(500).json({ error: "Recipe shaping requires OpenAI configuration." });
  }

  const sourceRecipe = source_recipe ?? {
    title,
    summary,
    recipe_type: recipeType,
    dietary_tags: dietaryTags,
    cuisine_tags: cuisineTags,
    cook_time_text: cookTimeText,
    ingredients_text: ingredientsText,
    instructions_text: instructionsText,
  };

  try {
    const completion = await openai.chat.completions.create({
      model: getActiveRecipeRewriteModel(),
      temperature: 0.25,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "recipe_shape",
          strict: true,
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              title: { type: "string" },
              summary: { type: "string" },
              recipe_type: { type: "string" },
              dietary_tags: { type: "array", items: { type: "string" }, maxItems: 10 },
              cuisine_tags: { type: "array", items: { type: "string" }, maxItems: 10 },
              cook_time_text: { type: "string" },
              ingredients_text: { type: "string" },
              instructions_text: { type: "string" },
            },
            required: [
              "title",
              "summary",
              "recipe_type",
              "dietary_tags",
              "cuisine_tags",
              "cook_time_text",
              "ingredients_text",
              "instructions_text",
            ],
          },
        },
      },
      messages: [
        { role: "system", content: RECIPE_SHAPE_SYSTEM_PROMPT },
        { role: "user", content: JSON.stringify(sourceRecipe, null, 2) },
      ],
    });

    const content = completion?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || !content.trim()) {
      return res.status(502).json({ error: "The model returned no recipe object." });
    }

    return res.json({
      recipe: JSON.parse(content),
      model: getActiveRecipeRewriteModel(),
      model_mode: "recipe_shape_finetune_ready",
    });
  } catch (error) {
    console.error("[recipe/shape] shaping failed:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

async function inferDiscoverIntentWithLLM({ profile, filter, query }) {
  if (!openai) return null;

  try {
    const completion = await openai.chat.completions.create({
      model: getDiscoverIntentModel(),
      temperature: 0.2,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "discover_intent",
          strict: true,
          schema: DISCOVER_INTENT_SCHEMA,
        },
      },
      messages: [
        { role: "system", content: DISCOVER_INTENT_SYSTEM_PROMPT },
        {
          role: "user",
          content: JSON.stringify(
            {
              selected_filter: filter,
              query,
              profile: summarizeProfileForIntent(profile),
            },
            null,
            2
          ),
        },
      ],
    });

    const content = completion.choices?.[0]?.message?.content;
    if (typeof content !== "string" || !content.trim()) return null;
    return normalizeDiscoverIntent(JSON.parse(content));
  } catch (error) {
    console.warn("[recipe/discover] intent inference failed:", error.message);
    return null;
  }
}

async function curateDiscoverRecipesWithLLM({ recipes, profile = null, filter = "All", query = "", parsedQuery = null, feedContext = null, limit = 30 }) {
  if (!openai) return recipes;
  if (!Array.isArray(recipes) || recipes.length <= 1) return recipes;
  if (String(query ?? "").trim().length > 0 && String(query ?? "").trim().length < 4) return recipes;

  const candidateCount = String(query ?? "").trim()
    ? Math.min(recipes.length, Math.max(limit, 6), 8)
    : Math.min(recipes.length, Math.max(limit, 6), 10);
  const candidateRecipes = recipes.slice(0, candidateCount);

  try {
    const completion = await withTimeout(
      openai.chat.completions.create({
      model: getActiveRecipeRewriteModel(),
      temperature: 0.2,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "discover_curation",
          strict: true,
          schema: DISCOVER_CURATION_SCHEMA,
        },
      },
      messages: [
        { role: "system", content: DISCOVER_CURATION_SYSTEM_PROMPT },
        {
          role: "user",
          content: JSON.stringify(
            {
              selected_filter: filter,
              query,
              parsed_query: parsedQuery,
              feed_context: feedContext,
              profile: summarizeProfileForIntent(profile),
              candidate_recipes: candidateRecipes.map((recipe) => ({
                id: recipe.id,
                title: recipe.title,
                description: recipe.description,
                recipe_type: recipe.recipe_type,
                category: recipe.category,
                dietary_tags: recipe.dietary_tags ?? [],
                cuisine_tags: recipe.cuisine_tags ?? [],
                cook_time_text: recipe.cook_time_text,
                ingredients_text: recipe.ingredients_text,
              })),
            },
            null,
            2
          ),
        },
      ],
      }),
      2500,
      "discover curation timed out"
    );

    const content = completion?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || !content.trim()) return recipes;

    const parsed = JSON.parse(content);
    const orderedIds = Array.isArray(parsed?.ordered_recipe_ids)
      ? [...new Set(parsed.ordered_recipe_ids.map((value) => String(value).trim()).filter(Boolean))]
      : [];

    if (!orderedIds.length) return recipes;

    const byId = new Map(candidateRecipes.map((recipe) => [String(recipe.id), recipe]));
    const curated = orderedIds.map((id) => byId.get(id)).filter(Boolean);
    const curatedIds = new Set(curated.map((recipe) => String(recipe.id)));
    const remainder = candidateRecipes.filter((recipe) => !curatedIds.has(String(recipe.id)));
    const untouchedTail = recipes.slice(candidateRecipes.length);

    return [...curated, ...remainder, ...untouchedTail].slice(0, limit);
  } catch (error) {
    console.warn("[recipe/discover] fine-tuned curation failed:", error.message);
    return recipes;
  }
}

async function withTimeout(promise, timeoutMs, message = "request timed out") {
  let timeoutId;
  const timeoutPromise = new Promise((_, reject) => {
    timeoutId = setTimeout(() => reject(new Error(message)), timeoutMs);
  });

  try {
    return await Promise.race([promise, timeoutPromise]);
  } finally {
    clearTimeout(timeoutId);
  }
}

function summarizeProfileForIntent(profile) {
  if (!profile) return null;

  return {
    preferred_cuisines: profile.preferredCuisines ?? [],
    dietary_patterns: profile.dietaryPatterns ?? [],
    allergies: profile.allergies ?? [],
    hard_restrictions: profile.hardRestrictions ?? [],
    never_include_foods: profile.neverIncludeFoods ?? [],
    favorite_foods: profile.favoriteFoods ?? [],
    meal_prep_goals: profile.mealPrepGoals ?? [],
    budget_per_cycle: profile.budgetPerCycle ?? null,
    cadence: profile.deliveryCadence ?? null,
  };
}

function normalizeDiscoverIntent(intent) {
  if (!intent || typeof intent !== "object") return null;

  return {
    userIntent: String(intent.user_intent ?? "").trim(),
    canonicalQuery: String(intent.canonical_query ?? "").trim(),
    filterType: normalizeFilterType(intent.filter_type),
    maxCookMinutes: Number(intent.max_cook_minutes ?? 0) > 0 ? Number(intent.max_cook_minutes) : null,
    mustIncludeTerms: normalizeIntentTerms(intent.must_include_terms, 8),
    avoidTerms: normalizeIntentTerms(intent.avoid_terms, 8),
    semanticExpansionTerms: normalizeIntentTerms(intent.semantic_expansion_terms, 10),
    lexicalPriorityTerms: normalizeIntentTerms(intent.lexical_priority_terms, 10),
    occasionTerms: normalizeIntentTerms(intent.occasion_terms, 6),
  };
}

function normalizeIntentTerms(rawTerms, maxItems = 8) {
  if (!Array.isArray(rawTerms)) return [];

  return [...new Set(
    rawTerms
      .map((term) => String(term ?? "").trim().toLowerCase())
      .filter(Boolean)
      .slice(0, maxItems)
  )];
}

function buildDiscoverQueryContext({ profile, filter, query, llmIntent = null }) {
  const cuisines = (profile?.preferredCuisines ?? [])
    .map((value) => String(value).replace(/([A-Z])/g, " $1").trim())
    .join(", ");
  const dietaryPatterns = (profile?.dietaryPatterns ?? []).join(", ");
  const favoriteFoods = (profile?.favoriteFoods ?? []).join(", ");
  const favoriteFlavors = (profile?.favoriteFlavors ?? []).join(", ");
  const restrictions = [
    ...(profile?.allergies ?? []),
    ...(profile?.hardRestrictions ?? []),
    ...(profile?.neverIncludeFoods ?? []),
  ].join(", ");
  const goals = (profile?.mealPrepGoals ?? []).join(", ");
  const exploration = profile?.explorationLevel ?? "balanced";
  const explicitFilter = normalizeFilterType(filter);
  const parsedQuery = parseDiscoverSearchQuery(query, llmIntent);
  const resolvedFilter = explicitFilter ?? parsedQuery.filterType;
  const flavorBoostTerms = expandFlavorTerms([
    ...parsedQuery.mustIncludeTerms,
    ...parsedQuery.lexicalTerms,
    ...extractIngredientSignals(favoriteFoods),
  ], 8);

  const primarySegments = [
    "Discover recipes for the Ounje home feed.",
    cuisines ? `Preferred cuisines: ${cuisines}.` : null,
    resolvedFilter ? `Prioritize ${resolvedFilter} recipes.` : "Prioritize broadly appealing meals.",
    favoriteFoods ? `Lean toward foods like ${favoriteFoods}.` : null,
  ].filter(Boolean);

  const secondarySegments = [
    "Rank recipes for this user's discover feed using detailed meal preference context.",
    cuisines ? `Cuisine affinity: ${cuisines}.` : null,
    dietaryPatterns ? `Dietary patterns: ${dietaryPatterns}.` : null,
    favoriteFlavors ? `Flavor profile: ${favoriteFlavors}.` : null,
    goals ? `Meal-prep goals: ${goals}.` : null,
    restrictions ? `Avoid: ${restrictions}.` : null,
    `Exploration level: ${exploration}.`,
    resolvedFilter ? `Hard focus on ${resolvedFilter}.` : null,
  ].filter(Boolean);

  const semanticSegments = [
    parsedQuery.userIntent ? `Search intent: ${parsedQuery.userIntent}.` : null,
    parsedQuery.canonicalQuery ? `Canonical request: ${parsedQuery.canonicalQuery}.` : null,
    parsedQuery.semanticQuery ? `User is searching for: ${parsedQuery.semanticQuery}.` : null,
    cuisines ? `Preferred cuisines: ${cuisines}.` : null,
    favoriteFoods ? `Favorite foods: ${favoriteFoods}.` : null,
    flavorBoostTerms.length ? `Flavor pairings to consider: ${flavorBoostTerms.join(", ")}.` : null,
    dietaryPatterns ? `Dietary patterns: ${dietaryPatterns}.` : null,
    goals ? `Meal prep goals: ${goals}.` : null,
    resolvedFilter ? `Restrict to ${resolvedFilter}.` : null,
    parsedQuery.maxCookMinutes
      ? `Keep cook time under ${parsedQuery.maxCookMinutes} minutes.`
      : null,
  ].filter(Boolean);

  const richSearchSegments = [
    parsedQuery.userIntent ? `Intent: ${parsedQuery.userIntent}.` : null,
    parsedQuery.semanticQuery ? `Search intent: ${parsedQuery.semanticQuery}.` : null,
    resolvedFilter ? `Hard dietary/type constraint: ${resolvedFilter}.` : null,
    parsedQuery.maxCookMinutes
      ? `Hard time constraint: at most ${parsedQuery.maxCookMinutes} minutes.`
      : null,
    parsedQuery.mustIncludeTerms?.length
      ? `Strongly favor: ${parsedQuery.mustIncludeTerms.join(", ")}.`
      : null,
    parsedQuery.avoidTerms?.length
      ? `Avoid: ${parsedQuery.avoidTerms.join(", ")}.`
      : null,
    dietaryPatterns ? `Dietary patterns: ${dietaryPatterns}.` : null,
    restrictions ? `Avoid: ${restrictions}.` : null,
    cuisines ? `Preferred cuisines: ${cuisines}.` : null,
    favoriteFoods ? `Usually enjoys foods like ${favoriteFoods}, but obey the search intent first.` : null,
    flavorBoostTerms.length ? `FlavorGraph pairings worth considering: ${flavorBoostTerms.join(", ")}.` : null,
    goals ? `Meal prep goals: ${goals}.` : null,
  ].filter(Boolean);

  return {
    primaryText: primarySegments.join(" "),
    secondaryText: secondarySegments.join(" "),
    filterType: resolvedFilter,
    semanticQuery: semanticSegments.join(" "),
    lexicalQuery: parsedQuery.lexicalQuery,
    richSearchText: richSearchSegments.join(" "),
    maxCookMinutes: parsedQuery.maxCookMinutes,
    parsedQuery,
    flavorBoostTerms,
  };
}

function normalizeFilterType(filter) {
  if (!filter || filter === "All") return null;

  const lowered = String(filter).trim().toLowerCase();
  switch (lowered) {
    case "breakfast":
    case "lunch":
    case "dinner":
    case "dessert":
    case "vegetarian":
    case "vegan":
      return lowered;
    default:
      return null;
  }
}

function inferFilterTypeFromQuery(query) {
  const lowered = String(query ?? "").trim().toLowerCase();
  if (!lowered) return null;

  if (/\bvegan\b/.test(lowered)) return "vegan";
  if (/\bvegetarian\b|\bveggie\b/.test(lowered)) return "vegetarian";
  if (/\bbreakfasts?\b/.test(lowered)) return "breakfast";
  if (/\blunch(?:es)?\b/.test(lowered)) return "lunch";
  if (/\bdinners?\b/.test(lowered)) return "dinner";
  if (/\bdesserts?\b|\bsweets?\b/.test(lowered)) return "dessert";
  if (/\bice cream\b|\bgelato\b|\bsorbet\b|\bsundae\b|\bcookie\b|\bcookies\b|\bcake\b|\bbrownie\b|\bpudding\b|\bcobbler\b|\bpie\b/.test(lowered)) {
    return "dessert";
  }

  return null;
}

function parseDiscoverSearchQuery(query, llmIntent = null) {
  const rawQuery = String(query ?? "").trim();
  const lowered = rawQuery.toLowerCase();
  const filterType = llmIntent?.filterType ?? inferFilterTypeFromQuery(lowered);
  const maxCookMinutes = llmIntent?.maxCookMinutes ?? inferMaxCookMinutes(lowered);
  const keywordTerms = extractQueryTerms(lowered);
  const canonicalTerms = extractQueryTerms(llmIntent?.canonicalQuery ?? "");
  const intentPriorityTerms = llmIntent?.lexicalPriorityTerms ?? [];
  const mustIncludeTerms = llmIntent?.mustIncludeTerms ?? [];
  const avoidTerms = llmIntent?.avoidTerms ?? [];
  const occasionTerms = llmIntent?.occasionTerms ?? [];
  const expandedTerms = expandQueryTerms([
    ...keywordTerms,
    ...canonicalTerms,
    ...mustIncludeTerms,
    ...intentPriorityTerms,
  ]);
  const exactPhrase = normalizeExactPhrase(llmIntent?.canonicalQuery || lowered);

  const lexicalTerms = [
    ...new Set(
      [...keywordTerms, ...canonicalTerms, ...mustIncludeTerms, ...intentPriorityTerms]
        .filter((term) => !STOPWORDS.has(term))
    ),
  ];
  const semanticTerms = [
    ...new Set([
      ...lexicalTerms,
      ...expandedTerms,
      ...(llmIntent?.semanticExpansionTerms ?? []),
      ...occasionTerms,
      filterType,
      maxCookMinutes ? "quick" : null,
      maxCookMinutes ? "fast" : null,
    ].filter(Boolean)),
  ];

  return {
    rawQuery,
    filterType,
    maxCookMinutes,
    exactPhrase,
    userIntent: llmIntent?.userIntent ?? "",
    canonicalQuery: llmIntent?.canonicalQuery ?? "",
    lexicalTerms,
    lexicalQuery: lexicalTerms.join(" "),
    semanticQuery: semanticTerms.join(" "),
    mustIncludeTerms,
    avoidTerms,
    occasionTerms,
  };
}

function inferMaxCookMinutes(query) {
  const normalized = String(query ?? "").toLowerCase();
  if (!normalized) return null;

  const patterns = [
    /\bunder\s+(\d{1,3})\s*(?:minutes?|mins?)\b/,
    /\bless than\s+(\d{1,3})\s*(?:minutes?|mins?)\b/,
    /\bwithin\s+(\d{1,3})\s*(?:minutes?|mins?)\b/,
    /\bin\s+(\d{1,3})\s*(?:minutes?|mins?)\s+or less\b/,
    /\b(\d{1,3})\s*(?:minutes?|mins?)\s+or less\b/,
    /\bmax(?:imum)?\s+(\d{1,3})\s*(?:minutes?|mins?)\b/,
  ];

  for (const pattern of patterns) {
    const match = normalized.match(pattern);
    if (match) return Number(match[1]);
  }

  return null;
}

function extractQueryTerms(query) {
  if (!query) return [];

  const stripped = query
    .replace(/\b(?:i|im|i'm|need|want|looking|look|for|show|give|me|something|some|with|that|which|can|you|please)\b/g, " ")
    .replace(/\b(?:under|less than|within|in|max(?:imum)?|or less)\s+\d{1,3}\s*(?:minutes?|mins?)\b/g, " ")
    .replace(/\b\d{1,3}\s*(?:minutes?|mins?)\s+or less\b/g, " ")
    .replace(/[^\w\s-]/g, " ");

  return [...new Set(
    stripped
      .split(/\s+/)
      .map((term) => normalizeQueryTerm(term))
      .filter(Boolean)
  )];
}

function expandQueryTerms(terms) {
  const expanded = [];

  for (const term of terms) {
    const synonyms = QUERY_TERM_EXPANSIONS[term];
    if (synonyms) expanded.push(...synonyms);
  }

  return [...new Set(expanded)];
}

function normalizeQueryTerm(term) {
  if (!term) return null;

  const trimmed = String(term).trim().toLowerCase();
  if (!trimmed || STOPWORDS.has(trimmed)) return null;
  if (/^\d+$/.test(trimmed)) return null;
  if (trimmed.length <= 1) return null;

  return trimmed;
}

function normalizeExactPhrase(query) {
  const terms = extractQueryTerms(query);
  if (terms.length < 2 || terms.length > 4) return null;
  return terms.join(" ");
}

const STOPWORDS = new Set([
  "all",
  "dish",
  "dishes",
  "food",
  "foods",
  "meal",
  "meals",
  "recipe",
  "recipes",
  "thing",
  "things",
]);

const QUERY_TERM_EXPANSIONS = {
  calm: ["gentle", "soothing", "comforting"],
  cozy: ["comforting", "warm"],
  comforting: ["cozy", "warm"],
  fresh: ["light", "bright"],
  hearty: ["filling", "substantial"],
  quick: ["fast", "easy"],
};

async function embedText(input, model) {
  const response = await openai.embeddings.create({ model, input });
  return response.data[0]?.embedding ?? [];
}

async function callRecipeRpc(functionName, payload) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${functionName}`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  const data = await response.json().catch(() => []);
  if (!response.ok) {
    const message = data?.message ?? data?.error ?? `${functionName} failed`;
    throw new Error(message);
  }

  return Array.isArray(data) ? data : [];
}

async function fetchRecipesByIds(ids) {
  const select = [
    "id",
    "title",
    "description",
    "author_name",
    "author_handle",
    "category",
    "recipe_type",
    "dietary_tags",
    "flavor_tags",
    "cuisine_tags",
    "cook_time_text",
    "ingredients_text",
    "instructions_text",
    "published_date",
    "discover_card_image_url",
    "hero_image_url",
    "recipe_url",
    "source",
  ].join(",");

  const inClause = ids.join(",");
  const url = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(select)}&id=in.(${encodeURIComponent(inClause)})`;
  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });

  const data = await response.json().catch(() => []);
  if (!response.ok) {
    const message = data?.message ?? data?.error ?? "Recipe fetch failed";
    throw new Error(message);
  }

  const byId = new Map(data.map((recipe) => [recipe.id, recipe]));
  return ids.map((id) => byId.get(id)).filter(Boolean);
}

async function fetchLatestRecipes(limit) {
  const select = [
    "id",
    "title",
    "description",
    "author_name",
    "author_handle",
    "category",
    "recipe_type",
    "dietary_tags",
    "flavor_tags",
    "cuisine_tags",
    "cook_time_text",
    "ingredients_text",
    "instructions_text",
    "published_date",
    "discover_card_image_url",
    "hero_image_url",
    "recipe_url",
    "source",
  ].join(",");

  const url = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(select)}&order=updated_at.desc.nullslast,published_date.desc.nullslast&limit=${limit}`;
  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });

  const data = await response.json().catch(() => []);
  if (!response.ok) {
    const message = data?.message ?? data?.error ?? "Latest recipe fetch failed";
    throw new Error(message);
  }

  return Array.isArray(data) ? data : [];
}

function fuseRankedIds(primary, secondary, limit) {
  const scores = new Map();
  const k = 60;

  [primary, secondary].forEach((items) => {
    items.forEach((item, index) => {
      const current = scores.get(item.id) ?? 0;
      scores.set(item.id, current + 1 / (k + index + 1));
    });
  });

  return [...scores.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, limit)
    .map(([id]) => id);
}

function deriveDiscoverFilters(recipes) {
  const values = ["All"];
  for (const recipe of recipes) {
    const normalized = normalizeDiscoverFilter(recipe.recipe_type, recipe.category);
    if (normalized && !values.includes(normalized)) {
      values.push(normalized);
    }
    for (const tag of recipe.dietary_tags ?? []) {
      const dietaryFilter = normalizeDiscoverFilter(tag, null);
      if (dietaryFilter && !values.includes(dietaryFilter)) {
        values.push(dietaryFilter);
      }
    }
    if (values.length >= 6) break;
  }
  return values;
}

function rerankSearchResults(recipes, parsedQuery, limit, profile = null) {
  if (!parsedQuery) return recipes;

  const scored = recipes.map((recipe, index) => ({
    recipe,
    index,
    score: scoreRecipeSearchMatch(recipe, parsedQuery, profile),
  }));

  const strongMatches = scored.filter((entry) => entry.score >= 35);
  const mediumMatches = scored.filter((entry) => entry.score >= 16);
  const shouldTrimWeakMatches =
    (parsedQuery.exactPhrase && strongMatches.length >= Math.min(limit, 3))
    || mediumMatches.length >= Math.min(limit, 6);

  const pool = shouldTrimWeakMatches
    ? scored.filter((entry) => entry.score > 0)
    : scored;

  return pool
    .sort((left, right) => {
      if (right.score !== left.score) return right.score - left.score;
      return left.index - right.index;
    })
    .slice(0, limit)
    .map((entry) => entry.recipe);
}

function scoreRecipeSearchMatch(recipe, parsedQuery, profile = null) {
  const title = String(recipe.title ?? "").toLowerCase();
  const description = String(recipe.description ?? "").toLowerCase();
  const ingredients = String(recipe.ingredients_text ?? "").toLowerCase();
  const recipeType = String(recipe.recipe_type ?? recipe.recipeType ?? "").toLowerCase();
  const category = String(recipe.category ?? "").toLowerCase();
  const exactPhrase = parsedQuery.exactPhrase;
  const lexicalTerms = parsedQuery.lexicalTerms ?? [];

  let score = 0;

  if (parsedQuery.filterType) {
    const normalizedFilter = String(parsedQuery.filterType).toLowerCase();
    if (recipeType === normalizedFilter || category === normalizedFilter) {
      score += 18;
    }

    if (["vegan", "vegetarian"].includes(normalizedFilter)) {
      const dietaryTags = Array.isArray(recipe.dietary_tags) ? recipe.dietary_tags.map((tag) => String(tag).toLowerCase()) : [];
      if (dietaryTags.includes(normalizedFilter)) {
        score += 18;
      }
    }
  }

  if (exactPhrase) {
    if (title.includes(exactPhrase)) score += 48;
    else if (description.includes(exactPhrase) || ingredients.includes(exactPhrase)) score += 26;
  }

  let matchedTerms = 0;
  for (const term of lexicalTerms) {
    const inTitle = title.includes(term);
    const inDescription = description.includes(term);
    const inIngredients = ingredients.includes(term);
    const inType = recipeType.includes(term) || category.includes(term);

    if (inTitle) score += 14;
    else if (inType) score += 10;
    else if (inDescription) score += 6;
    else if (inIngredients) score += 4;

    if (inTitle || inDescription || inIngredients || inType) {
      matchedTerms += 1;
    }
  }

  if (lexicalTerms.length > 0) {
    const coverage = matchedTerms / lexicalTerms.length;
    score += coverage * 18;
    if (matchedTerms === lexicalTerms.length && matchedTerms > 0) {
      score += 12;
    }
  }

  for (const term of parsedQuery.mustIncludeTerms ?? []) {
    if (title.includes(term)) score += 16;
    else if (description.includes(term) || ingredients.includes(term) || recipeType.includes(term) || category.includes(term)) score += 9;
  }

  for (const term of parsedQuery.avoidTerms ?? []) {
    if (title.includes(term) || description.includes(term) || ingredients.includes(term)) {
      score -= 36;
    }
  }

  if (parsedQuery.maxCookMinutes) {
    const cookMinutes = parseCookMinutes(recipe.cook_time_text ?? recipe.cookTimeText ?? "");
    if (cookMinutes != null && cookMinutes <= parsedQuery.maxCookMinutes) {
      score += 10;
    } else if (cookMinutes != null) {
      score -= 20;
    }
  }

  const flavorSeedTerms = [
    ...(parsedQuery.mustIncludeTerms ?? []),
    ...(parsedQuery.lexicalTerms ?? []),
    ...extractIngredientSignals(((profile?.favoriteFoods) ?? []).join(", ")),
  ];
  score += scoreFlavorAlignment(recipe, flavorSeedTerms, parsedQuery.avoidTerms ?? []);

  return score;
}

async function fetchRecipeById(id) {
  const recipes = await fetchRecipesByIds([id]);
  return recipes[0] ?? null;
}

function normalizeRecipeDetail(recipe) {
  const ingredients = parseIngredientLines(recipe.ingredients_text);
  const steps = parseInstructionSteps(recipe.instructions_text);
  const servingsCount = parseFirstInteger(recipe.servings_text);

  return {
    id: recipe.id,
    title: recipe.title ?? "",
    description: recipe.description ?? "",
    author_name: recipe.author_name ?? null,
    author_handle: recipe.author_handle ?? null,
    source: recipe.source ?? null,
    source_platform: recipe.source_platform ?? null,
    category: recipe.category ?? null,
    subcategory: recipe.subcategory ?? null,
    recipe_type: recipe.recipe_type ?? null,
    skill_level: recipe.skill_level ?? null,
    cook_time_text: recipe.cook_time_text ?? null,
    servings_text: recipe.servings_text ?? null,
    serving_size_text: recipe.serving_size_text ?? null,
    daily_diet_text: recipe.daily_diet_text ?? null,
    est_cost_text: recipe.est_cost_text ?? null,
    est_calories_text: recipe.est_calories_text ?? null,
    carbs_text: recipe.carbs_text ?? null,
    protein_text: recipe.protein_text ?? null,
    fats_text: recipe.fats_text ?? null,
    calories_kcal: recipe.calories_kcal ?? null,
    protein_g: recipe.protein_g ?? null,
    carbs_g: recipe.carbs_g ?? null,
    fat_g: recipe.fat_g ?? null,
    prep_time_minutes: recipe.prep_time_minutes ?? null,
    cook_time_minutes: recipe.cook_time_minutes ?? null,
    hero_image_url: recipe.hero_image_url ?? null,
    discover_card_image_url: recipe.discover_card_image_url ?? null,
    recipe_url: recipe.recipe_url ?? null,
    original_recipe_url: recipe.original_recipe_url ?? null,
    detail_footnote: recipe.detail_footnote ?? null,
    image_caption: recipe.image_caption ?? null,
    dietary_tags: Array.isArray(recipe.dietary_tags) ? recipe.dietary_tags : [],
    flavor_tags: Array.isArray(recipe.flavor_tags) ? recipe.flavor_tags : [],
    cuisine_tags: Array.isArray(recipe.cuisine_tags) ? recipe.cuisine_tags : [],
    occasion_tags: Array.isArray(recipe.occasion_tags) ? recipe.occasion_tags : [],
    main_protein: recipe.main_protein ?? null,
    cook_method: recipe.cook_method ?? null,
    ingredients,
    steps,
    servings_count: servingsCount,
  };
}

function parseIngredientLines(value) {
  const text = sanitizeRecipeText(value);
  if (!text) return [];

  const newlineParts = text
    .split(/\n+/)
    .map((part) => normalizeRecipeLine(part))
    .filter(Boolean);

  if (newlineParts.length >= 2) {
    return dedupeStrings(newlineParts);
  }

  const commaParts = text
    .split(/,(?!\s?\d)/)
    .map((part) => normalizeRecipeLine(part))
    .filter(Boolean);

  return dedupeStrings(commaParts);
}

function parseInstructionSteps(value) {
  const htmlText = String(value ?? "")
    .replace(/<\/li>/gi, "\n")
    .replace(/<li[^>]*>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n");
  const text = sanitizeRecipeText(htmlText);
  if (!text) return [];

  const numbered = text
    .split(/\s*(?:^|\n|\r|\t)(?:step\s*)?\d{1,2}[.)]\s*/i)
    .map((part) => normalizeStepText(part))
    .filter(Boolean);

  if (numbered.length >= 2) {
    return numbered.map((line, index) => ({
      number: index + 1,
      text: line,
    }));
  }

  const newlineParts = text
    .split(/\n+/)
    .map((part) => normalizeStepText(part))
    .filter(Boolean);

  if (newlineParts.length >= 2) {
    return newlineParts.map((line, index) => ({
      number: index + 1,
      text: line,
    }));
  }

  const sentenceParts = text
    .split(/(?<=[.!?])\s+(?=[A-Z])/)
    .map((part) => normalizeStepText(part))
    .filter(Boolean);

  return sentenceParts.map((line, index) => ({
    number: index + 1,
    text: line,
  }));
}

function sanitizeRecipeText(value) {
  return String(value ?? "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;/gi, "'")
    .replace(/\r/g, "\n")
    .replace(/\n{2,}/g, "\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

function normalizeRecipeLine(value) {
  return String(value ?? "")
    .replace(/^[-*•\u2022]+\s*/, "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeStepText(value) {
  return normalizeRecipeLine(value)
    .replace(/^\d{1,2}[.)]\s*/, "")
    .replace(/\s+/g, " ")
    .trim();
}

function dedupeStrings(values) {
  const seen = new Set();
  return values.filter((value) => {
    const key = String(value).toLowerCase();
    if (!key || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function parseFirstInteger(value) {
  const match = String(value ?? "").match(/\d{1,3}/);
  return match ? Number(match[0]) : null;
}

function parseCookMinutes(cookTimeText) {
  const raw = String(cookTimeText ?? "").toLowerCase();
  if (!raw) return null;

  const values = [...raw.matchAll(/(\d{1,3})/g)].map((match) => Number(match[1]));
  if (values.length === 0) return null;
  return Math.max(...values);
}

function normalizeDiscoverFilter(recipeType, category) {
  const raw = recipeType || category;
  if (!raw) return null;

  const lowered = String(raw).trim().toLowerCase().replace(/ recipes$/, "");
  switch (lowered) {
    case "breakfast":
      return "Breakfast";
    case "lunch":
      return "Lunch";
    case "dinner":
      return "Dinner";
    case "dessert":
      return "Dessert";
    case "vegetarian":
      return "Vegetarian";
    case "vegan":
      return "Vegan";
    case "other":
    case "recipes":
      return null;
    default:
      return null;
  }
}

function toPgVector(values) {
  return `[${values.join(",")}]`;
}

export default recipe_router;
