import express from "express";
import OpenAI from "openai";
import dotenv from "dotenv";
import ytdl from "youtube-dl-exec";
import { expandFlavorTerms, scoreFlavorAlignment, suggestAdaptationPairings, extractIngredientSignals } from "../../lib/flavorgraph.js";
import { findRecipeStyleExamples } from "../../lib/recipe-corpus.js";
import {
  getActiveRecipeRewriteModel,
  getDiscoverIntentModel,
  readRecipeModelRegistry,
  refreshRecipeFineTuneStatus,
} from "../../lib/recipe-model-registry.js";
import { normalizeRecipeDetail as canonicalizeRecipeDetail } from "../../lib/recipe-detail-utils.js";
import {
  attachDiscoverBrackets,
  getCachedRecipeIdsForBracket,
  getDiscoverPreset,
  getDiscoverPresetTitles,
  recipeHasDiscoverBracket,
} from "../../lib/discover-brackets.js";

const recipe_router = express.Router();

dotenv.config({ path: new URL("../../.env", import.meta.url).pathname });

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";
const IFRAMELY_API_KEY = process.env.IFRAMELY_API_KEY ?? "";
const IFRAMELY_OEMBED_ENDPOINT = process.env.IFRAMELY_OEMBED_ENDPOINT ?? "https://iframe.ly/api/oembed";

const openai = OPENAI_API_KEY ? new OpenAI({ apiKey: OPENAI_API_KEY }) : null;

const SEARCH_RESPONSE_CACHE_TTL_MS = 2 * 60 * 1000;
const INTENT_CACHE_TTL_MS = 15 * 60 * 1000;
const EMBEDDING_CACHE_TTL_MS = 30 * 60 * 1000;

const searchResponseCache = new Map();
const discoverIntentCache = new Map();
const embeddingCache = new Map();
const recipeVideoResolveCache = new Map();

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

    const [recipeIngredients, recipeSteps] = await Promise.all([
      fetchRecipeIngredientRows(recipeId),
      fetchRecipeStepRows(recipeId),
    ]);

    const stepIngredients = recipeSteps.length
      ? await fetchRecipeStepIngredientRows(recipeSteps.map((step) => step.id))
      : [];

    return res.json({
      recipe: normalizeRecipeDetail(recipe, {
        recipeIngredients,
        recipeSteps,
        stepIngredients,
      }),
    });
  } catch (error) {
    console.error("[recipe/detail] detail fetch failed:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

recipe_router.get("/recipe/video/resolve", async (req, res) => {
  const rawURL = String(req.query.url ?? "").trim();

  if (!rawURL) {
    return res.status(400).json({ error: "Provide a video url." });
  }

  try {
    const video = await resolveRecipeVideoURL(rawURL);
    return res.json({ video });
  } catch (error) {
    return res.status(500).json({
      error: error instanceof Error ? error.message : "Unable to resolve recipe video.",
    });
  }
});

recipe_router.post("/recipe/discover", async (req, res) => {
  const { profile = null, filter = "All", query = "", limit = 30, feedContext = null } = req.body ?? {};

  try {
    const trimmedQuery = String(query ?? "").trim();
    const normalizedFilter = String(filter ?? "All").trim().toLowerCase();
    const isBaseDiscover = normalizedFilter === "all";
    const requestedLimit = trimmedQuery
      ? limit
      : isBaseDiscover
        ? Math.max(limit, 300)
        : Math.max(limit, 180);

    if (trimmedQuery) {
      const searchCacheKey = buildDiscoverSearchCacheKey({
        query: trimmedQuery,
        filter,
        limit,
        profile,
      });
      const cachedPayload = readTimedCache(searchResponseCache, searchCacheKey, SEARCH_RESPONSE_CACHE_TTL_MS);
      if (cachedPayload) {
        return res.json(cachedPayload);
      }
    }

    if (!openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
      const parsedFallbackQuery = parseDiscoverSearchQuery(query, null);
      parsedFallbackQuery.selectedFilter = filter;
      const recipes = trimmedQuery
        ? await fetchSearchFallbackRecipes({
            parsedQuery: parsedFallbackQuery,
            limit,
          })
        : String(filter ?? "All").trim().toLowerCase() === "all"
          ? await fetchLatestRecipes(requestedLimit)
          : applyPresetCategoryGate(
              await fetchLatestRecipes(Math.max(requestedLimit * 4, 120)),
              filter
            ).slice(0, requestedLimit);
      const payload = {
        recipes,
        filters: trimmedQuery ? deriveSearchFilters(recipes) : deriveDiscoverFilters(recipes),
        rankingMode: trimmedQuery
          ? "search_lexical_fallback"
          : isBaseDiscover
            ? "fallback_latest"
            : "fallback_latest_preset_gate",
      };
      if (trimmedQuery) {
        searchResponseCache.set(
          buildDiscoverSearchCacheKey({ query: trimmedQuery, filter, limit, profile }),
          { value: payload, createdAt: Date.now() }
        );
      }
      return res.json(payload);
    }

    if (!trimmedQuery) {
      const { recipes, rankingMode } = isBaseDiscover
        ? await buildBaseDiscoverRecipes({
            profile,
            filter,
            feedContext,
            limit: requestedLimit,
          })
        : await buildPresetDiscoverRecipes({
            profile,
            filter,
            feedContext,
            limit: requestedLimit,
          });

      return res.json({
        recipes,
        filters: deriveDiscoverFilters(recipes),
        rankingMode,
      });
    }

    const heuristicQuery = parseDiscoverSearchQuery(trimmedQuery, null);
    const shouldUseFastSearchPath = isFastSearchEligible(trimmedQuery, heuristicQuery);

    const llmIntent = shouldUseFastSearchPath
      ? null
      : await inferDiscoverIntentWithLLM({ profile, filter, query: trimmedQuery });
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
    const candidateLimit = Math.max(limit * 3, 60);

    if (trimmedQuery.length <= 80) {
      console.log(
        `[recipe/discover] query="${trimmedQuery}" filter="${filter}" resolvedFilter="${filterType ?? "null"}" maxCookMinutes="${maxCookMinutes ?? "null"}" exactPhrase="${parsedQuery?.exactPhrase ?? "null"}" lexicalQuery="${lexicalQuery}" intent="${llmIntent?.userIntent ?? "heuristic"}"`
      );
    }
    const lexicalFallbackPromise = fetchSearchFallbackRecipes({
      parsedQuery,
      limit: candidateLimit,
    });

    const hybridEmbeddingPromise = embedTextCached(semanticQuery, "text-embedding-3-small");
    const richEmbeddingPromise = shouldUseFastSearchPath
      ? Promise.resolve([])
      : embedTextCached(richSearchText, "text-embedding-3-large");

    const [hybridEmbedding, richEmbedding, lexicalFallbackRecipes] = await Promise.all([
      hybridEmbeddingPromise,
      richEmbeddingPromise,
      lexicalFallbackPromise,
    ]);

    const hybridMatchesPromise = callRecipeRpc("match_recipes_hybrid", {
      query_embedding: toPgVector(hybridEmbedding),
      query_text: lexicalQuery,
      match_count: Math.max(limit * 3, 36),
      filter_type: filterType,
      max_cook_minutes: maxCookMinutes,
    }).catch((error) => {
      console.warn("[recipe/discover] hybrid rpc failed:", error.message);
      return [];
    });

    const richMatchesPromise = shouldUseFastSearchPath || !Array.isArray(richEmbedding) || richEmbedding.length === 0
      ? Promise.resolve([])
      : callRecipeRpc("match_recipes_rich", {
          query_embedding: toPgVector(richEmbedding),
          match_count: Math.max(limit * 2, 24),
          filter_type: filterType,
          max_cook_minutes: maxCookMinutes,
        }).catch((error) => {
          console.warn("[recipe/discover] rich rpc failed:", error.message);
          return [];
        });

    const [hybridMatches, richMatches] = await Promise.all([hybridMatchesPromise, richMatchesPromise]);

    rankedIds = fuseRankedIds(hybridMatches, richMatches, candidateLimit);
    let recipes = rankedIds.length > 0
      ? await fetchSearchRecipesByIds(rankedIds)
      : [];

    recipes = dedupeRecipesById([
      ...recipes,
      ...lexicalFallbackRecipes,
    ]);

    recipes = applyPresetCategoryGate(recipes, filter);
    recipes = applyPresetHardConstraints(recipes, filter);

    if (trimmedQuery) {
      recipes = rerankSearchResults(recipes, parsedQuery, candidateLimit, profile);
    }

    if (!shouldUseFastSearchPath) {
      recipes = await curateDiscoverRecipesWithLLM({
        recipes,
        profile,
        filter,
        query: trimmedQuery,
        parsedQuery,
        feedContext,
        limit,
      });
    }

    recipes = diversifyDiscoverRecipes({
      recipes,
      profile,
      filter,
      query: trimmedQuery,
      parsedQuery,
      feedContext,
      limit,
    });

    const strictRecipes = filterStrictSearchResults(recipes, parsedQuery, limit);
    recipes = strictRecipes.length >= Math.min(4, limit)
      ? strictRecipes
      : relaxSearchResults(recipes, parsedQuery, limit);
    recipes = applyPresetHardConstraints(recipes, filter).slice(0, limit);

    const payload = {
      recipes,
      filters: deriveSearchFilters(recipes),
      rankingMode: shouldUseFastSearchPath
        ? "hybrid_search_embeddings_fast_strict"
        : (trimmedQuery ? "hybrid_search_embeddings_llm_finetuned_curated_strict" : "primary_secondary_embeddings_finetuned_curated"),
    };
    searchResponseCache.set(
      buildDiscoverSearchCacheKey({ query: trimmedQuery, filter, limit, profile }),
      { value: payload, createdAt: Date.now() }
    );
    return res.json(payload);
  } catch (error) {
    console.error("[recipe/discover] ranking failed:", error.message);

    try {
      if (trimmedQuery) {
        const parsedQuery = parseDiscoverSearchQuery(query, null);
        parsedQuery.selectedFilter = filter;
        const recipes = await fetchSearchFallbackRecipes({ parsedQuery, limit });
        return res.json({
          recipes: applyPresetHardConstraints(
            applyPresetCategoryGate(
              filterStrictSearchResults(recipes, parsedQuery, limit),
              filter
            ),
            filter
          ).slice(0, limit),
          filters: deriveSearchFilters(recipes),
          rankingMode: "search_lexical_fallback_strict",
        });
      }

      const recipes = isBaseDiscover
        ? await fetchLatestRecipes(requestedLimit)
        : applyPresetCategoryGate(
            await fetchLatestRecipes(Math.max(requestedLimit * 4, 120)),
            filter
          ).slice(0, requestedLimit);
      return res.json({
        recipes,
        filters: deriveDiscoverFilters(recipes),
        rankingMode: isBaseDiscover ? "fallback_latest" : "fallback_latest_preset_gate",
      });
    } catch (fallbackError) {
      return res.status(500).json({ error: fallbackError.message });
    }
  }
});

recipe_router.post("/recipe/prep-candidates", async (req, res) => {
  const { profile = null, limit = 72, feedContext = null, history_recipe_ids: historyRecipeIds = [] } = req.body ?? {};

  try {
    let rankedPayload;
    if (!openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
      rankedPayload = {
        recipes: await fetchLatestRecipes(Math.max(limit, 48)),
        rankingMode: "fallback_latest",
      };
    } else {
      rankedPayload = await buildBaseDiscoverRecipes({
        profile,
        filter: "All",
        feedContext,
        limit: Math.max(limit, 72),
        candidateLimit: Math.max(limit * 6, 140),
        basicMatchCount: Math.max(limit * 5, 100),
        richMatchCount: Math.max(limit * 5, 100),
      });
    }

    let recipes = filterRecipesByAllergies(rankedPayload.recipes, profile);
    recipes = deprioritizeHistoricalRecipes(recipes, historyRecipeIds);

    const normalized = recipes
      .map(normalizePrepCandidateRecipe)
      .filter((recipe) => Array.isArray(recipe.ingredients) && recipe.ingredients.length >= 3)
      .slice(0, limit);

    return res.json({
      recipes: normalized,
      rankingMode: `${rankedPayload.rankingMode}_prep_candidates`,
    });
  } catch (error) {
    console.error("[recipe/prep-candidates] ranking failed:", error.message);

    try {
      const fallback = (await fetchLatestRecipes(Math.max(limit, 48)))
        .map(normalizePrepCandidateRecipe)
        .filter((recipe) => Array.isArray(recipe.ingredients) && recipe.ingredients.length >= 3)
        .slice(0, limit);

      return res.json({
        recipes: fallback,
        rankingMode: "fallback_latest_prep_candidates",
      });
    } catch (fallbackError) {
      return res.status(500).json({ error: fallbackError.message });
    }
  }
});

async function buildBaseDiscoverRecipes({
  profile = null,
  filter = "All",
  feedContext = null,
  limit = 300,
}) {
  const target = Math.max(limit, 300);
  const randomTarget = Math.max(1, Math.floor(target * 0.5));
  const cueTarget = Math.max(1, Math.floor(target * (7 / 30)));
  const profileTarget = Math.max(0, target - randomTarget - cueTarget);

  const [randomRecipes, cueRecipes, profileRecipes] = await Promise.all([
    fetchRandomDiscoverRecipes({
      limit: Math.min(Math.max(randomTarget * 2, 120), 220),
      seed: `${feedContext?.sessionSeed ?? "base"}|random|${feedContext?.windowKey ?? "now"}`,
      filter,
    }),
    buildCueDrivenDiscoverRecipes({
      filter,
      feedContext,
      limit: Math.min(Math.max(cueTarget * 2, 60), 110),
    }),
    buildProfileDrivenDiscoverRecipes({
      profile,
      filter,
      limit: Math.min(Math.max(profileTarget * 2, 80), 120),
    }),
  ]);

  let recipes = composeBaseDiscoverFeed({
    randomRecipes: applyPresetHardConstraints(randomRecipes, filter),
    cueRecipes: applyPresetHardConstraints(cueRecipes, filter),
    profileRecipes: applyPresetHardConstraints(profileRecipes, filter),
    limit: target,
  });

  if (String(filter ?? "All").trim().toLowerCase() !== "all") {
    recipes = frontloadPresetRecipes(recipes, filter, target);
  }

  if (recipes.length < target) {
    const fallbackPool = applyPresetHardConstraints(
      dedupeRecipesById([
        ...randomRecipes,
        ...cueRecipes,
        ...profileRecipes,
        ...(await fetchLatestRecipes(Math.min(Math.max(target, 120), 220))),
      ]),
      filter
    );
    for (const recipe of fallbackPool) {
      if (recipes.length >= target) break;
      if (recipes.some((candidate) => candidate.id === recipe.id)) continue;
      recipes.push(recipe);
    }
  }

  return {
    recipes: recipes.slice(0, target),
    rankingMode: "base_random_cues_profile_composed",
  };
}

async function buildPresetDiscoverRecipes({
  profile = null,
  filter = "All",
  feedContext = null,
  limit = 180,
}) {
  const normalizedFilter = String(filter ?? "All").trim().toLowerCase();
  if (normalizedFilter === "all") {
    return buildBaseDiscoverRecipes({ profile, filter, feedContext, limit: Math.max(limit, 300) });
  }

  const target = Math.max(limit, 180);
  const seedRoot = `${feedContext?.sessionSeed ?? "preset"}|${feedContext?.windowKey ?? "now"}|${normalizedFilter}`;

  const presetPool = await fetchPresetBracketRecipes({
    filter,
    limit: Math.max(target, 600),
    seed: `${seedRoot}|pool`,
  });
  const fallbackWidePool = dedupeRecipesById(
    applyPresetCategoryGate(
      applyPresetHardConstraints(
        [
          ...presetPool,
          ...(await fetchLatestRecipes(Math.max(target, 180))),
        ],
        filter
      ),
      filter
    )
  );

  const ranked = rankPresetShelfRecipes(
    dedupeRecipesById([
      ...presetPool,
      ...fallbackWidePool,
    ]),
    { filter, profile, feedContext, seed: `${seedRoot}|shelf` }
  );

  return {
    recipes: ranked.slice(0, Math.max(target, ranked.length)),
    rankingMode: "preset_bracket_shelf_rotating",
  };
}

function composeBaseDiscoverFeed({
  randomRecipes,
  cueRecipes,
  profileRecipes,
  limit = 20,
}) {
  const target = Math.max(20, limit);
  const cueTarget = Math.min(7, Math.max(0, target - 15));
  const profileTarget = Math.max(0, target - 15 - cueTarget);
  const randomTarget = Math.min(15, target);
  const selectedIds = new Set();
  const randomSelected = selectBucketRecipes(randomRecipes, randomTarget, selectedIds, {
    maxTypeCount: 5,
    maxSourceCount: 5,
  });
  const cueSelected = selectBucketRecipes(cueRecipes, cueTarget, selectedIds, {
    maxTypeCount: 3,
    maxSourceCount: 3,
  });
  const profileSelected = selectBucketRecipes(profileRecipes, profileTarget, selectedIds, {
    maxTypeCount: 2,
    maxSourceCount: 2,
  });
  const composed = dedupeRecipesById(interleaveRecipeBuckets([
    randomSelected,
    cueSelected,
    profileSelected,
  ]));

  const fallbackPool = dedupeRecipesById([
    ...randomRecipes,
    ...cueRecipes,
    ...profileRecipes,
  ]);
  for (const recipe of fallbackPool) {
    if (composed.length >= target) break;
    if (selectedIds.has(recipe.id)) continue;
    composed.push(recipe);
    selectedIds.add(recipe.id);
  }

  return composed.slice(0, target);
}

function frontloadPresetRecipes(recipes, filter, limit) {
  return [...recipes]
    .map((recipe, index) => ({
      recipe,
      index,
      score: scorePresetAffinity(recipe, filter),
    }))
    .sort((left, right) => {
      const leftStrong = left.score >= 24 ? 1 : 0;
      const rightStrong = right.score >= 24 ? 1 : 0;
      if (rightStrong !== leftStrong) return rightStrong - leftStrong;

      const leftMedium = left.score > 0 ? 1 : 0;
      const rightMedium = right.score > 0 ? 1 : 0;
      if (rightMedium !== leftMedium) return rightMedium - leftMedium;

      if (right.score !== left.score) return right.score - left.score;
      return left.index - right.index;
    })
    .slice(0, limit)
    .map((entry) => entry.recipe);
}

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
  const allowExploration = !trimmedQuery;
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
          score += trimmedQuery ? 12 : 5;
          break;
        }
      }
    }

    if (favoriteFoods.size) {
      for (const food of favoriteFoods) {
        if (food && `${title} ${description}`.includes(food)) {
          score += trimmedQuery ? 8 : 3;
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

    if (allowExploration) {
      if (daypart === "morning" && isBreakfastRecipe(recipe)) score += 12;
      if (["midday", "afternoon"].includes(daypart) && isDrinkRecipe(recipe)) score += 10;
      if (["afternoon", "evening", "late-night"].includes(daypart) && isSweetTreatRecipe(recipe)) score += 10;
      if (isWeekend && (isBreakfastRecipe(recipe) || isSweetTreatRecipe(recipe))) score += 8;
      if (seasonCue === "summer" && (isCoolingRecipe(recipe) || isDrinkRecipe(recipe))) score += 8;
      if (seasonCue === "winter" && isComfortRecipe(recipe)) score += 8;
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
    allowExploration,
    daypart,
    isWeekend,
    seasonCue,
  });
}

function selectDiverseRecipes(
  recipes,
  {
    limit = 30,
    strictDiversity = true,
    sweetTreatBias = 0.18,
    coldComfortMode = false,
    hotRefreshMode = false,
    allowExploration = false,
    daypart = "",
    isWeekend = false,
    seasonCue = "",
  } = {}
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

  if (allowExploration) {
    if (daypart === "morning" || isWeekend) {
      reserveCuratedSlot(candidates, selected, typeCounts, sourceCounts, {
        targetIndex: Math.min(selected.length > 0 ? 1 : 0, limit - 1),
        maxTypeCount: strictDiversity ? 2 : 3,
        maxSourceCount: strictDiversity ? 2 : 3,
        matcher: isBreakfastRecipe,
      });
    }

    if (["midday", "afternoon", "evening"].includes(daypart) || seasonCue === "summer") {
      reserveCuratedSlot(candidates, selected, typeCounts, sourceCounts, {
        targetIndex: Math.min(Math.max(selected.length, 2), limit - 1),
        maxTypeCount: strictDiversity ? 2 : 3,
        maxSourceCount: strictDiversity ? 2 : 3,
        matcher: isDrinkRecipe,
      });
    }

    reserveCuratedSlot(candidates, selected, typeCounts, sourceCounts, {
      targetIndex: Math.min(Math.max(selected.length, 3), limit - 1),
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

function scoredRotationPool(recipes, scorer, seed, poolSize) {
  const scored = recipes.map((recipe, index) => ({
    recipe,
    score: scorer(recipe) + Math.max(0, 120 - index * 2.2) + stableJitter(`${seed}|${recipe.id}`) * 16,
  }));

  return scored
    .sort((left, right) => right.score - left.score)
    .slice(0, Math.min(poolSize, scored.length))
    .map((entry) => entry.recipe);
}

function selectBucketRecipes(recipes, targetCount, selectedIds, { maxTypeCount = 2, maxSourceCount = 2 } = {}) {
  if (!targetCount) return [];

  const selected = [];
  const typeCounts = new Map();
  const sourceCounts = new Map();

  for (const recipe of recipes) {
    if (selected.length >= targetCount) break;
    if (selectedIds.has(recipe.id)) continue;

    const typeKey = normalizeRecipeGroup(recipe.recipe_type ?? recipe.category ?? "other");
    const sourceKey = String(recipe.source ?? "source").toLowerCase();

    if ((typeCounts.get(typeKey) ?? 0) >= maxTypeCount) continue;
    if ((sourceCounts.get(sourceKey) ?? 0) >= maxSourceCount) continue;

    selected.push(recipe);
    selectedIds.add(recipe.id);
    typeCounts.set(typeKey, (typeCounts.get(typeKey) ?? 0) + 1);
    sourceCounts.set(sourceKey, (sourceCounts.get(sourceKey) ?? 0) + 1);
  }

  if (selected.length < targetCount) {
    for (const recipe of recipes) {
      if (selected.length >= targetCount) break;
      if (selectedIds.has(recipe.id)) continue;
      selected.push(recipe);
      selectedIds.add(recipe.id);
    }
  }

  return selected;
}

function interleaveRecipeBuckets(buckets) {
  const result = [];
  const normalized = buckets.map((bucket) => [...bucket]);

  while (normalized.some((bucket) => bucket.length > 0)) {
    for (const bucket of normalized) {
      const recipe = bucket.shift();
      if (recipe) {
        result.push(recipe);
      }
    }
  }

  return result;
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
  if (recipeHasDiscoverBracket(recipe, "Dinner")) return true;
  const text = recipeDescriptorText(recipe);
  return /(soup|stew|jollof|curry|braise|roast|pasta|creamy|comfort|baked|casserole|beans)/.test(text);
}

function isSweetTreatRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Dessert")) return true;
  const type = String(recipe.recipe_type ?? recipe.category ?? "").toLowerCase();
  const text = recipeDescriptorText(recipe);
  return type === "dessert" || /(cake|cookie|brownie|ice cream|sweet|pudding|pie|cheesecake|treat)/.test(text);
}

function isBreakfastRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Breakfast")) return true;
  const type = String(recipe.recipe_type ?? recipe.category ?? "").toLowerCase();
  const text = recipeDescriptorText(recipe);
  return type === "breakfast" || /(breakfast|oat|eggs|omelet|waffle|pancake|granola|toast|brunch)/.test(text);
}

function recipeIdentityText(recipe) {
  return `${recipe.title ?? ""} ${recipe.recipe_type ?? ""} ${recipe.category ?? ""}`.toLowerCase();
}

function isDrinkRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Drinks")) return true;
  const type = String(recipe.recipe_type ?? recipe.category ?? "").toLowerCase();
  const identity = recipeIdentityText(recipe);
  if (type === "drinks" || type === "drink" || type === "beverage") {
    return true;
  }

  const unmistakableDrink = /\b(cocktail|mocktail|smoothie|juice|latte|lemonade|spritz|margarita|mojito|martini|carajillo|milkshake|punch|soda|sour|tea|old fashioned|frappe)\b/.test(identity);
  const mealConflict = /\b(cake|brownie|cookie|pie|tart|cheesecake|dessert|pudding|bar|baked oats|potato|potatoes|omelet|omelette|chicken|beef|pasta|salad|sandwich|toast|bowl|soup|stir fry|stir-fry|gnocchi|burrito|rice|beans|wings|pizza|bread)\b/.test(identity);
  return unmistakableDrink && !mealConflict;
}

function isPastaRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Pasta")) return true;
  return /\b(pasta|spaghetti|linguine|penne|rigatoni|fusilli|macaroni|gnocchi|orzo)\b/.test(recipeIdentityText(recipe));
}

function isChickenRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Chicken")) return true;
  return /\b(chicken|thigh|breast|wing|drumstick)\b/.test(recipeIdentityText(recipe));
}

function isSteakRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Steak")) return true;
  return /\b(steak|beef|sirloin|ribeye|flank|striploin)\b/.test(recipeIdentityText(recipe));
}

function isFishRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Fish") || recipeHasDiscoverBracket(recipe, "Salmon")) return true;
  return /\b(fish|salmon|cod|tilapia|snapper|trout|halibut|sea bass|seabass|mahi|tuna)\b/.test(recipeIdentityText(recipe));
}

function isSaladRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Salad")) return true;
  return /\b(salad|slaw|caesar|greens)\b/.test(recipeIdentityText(recipe));
}

function isSandwichRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Sandwich")) return true;
  return /\b(sandwich|burger|wrap|panini|toastie|sub|slider|toast)\b/.test(recipeIdentityText(recipe));
}

function isBeanRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Beans")) return true;
  return /\b(bean|beans|lentil|chickpea|legume)\b/.test(recipeIdentityText(recipe));
}

function isPotatoRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Potatoes")) return true;
  return /\b(potato|potatoes|sweet potato|hash brown|tater)\b/.test(recipeIdentityText(recipe));
}

function isSalmonRecipe(recipe) {
  if (recipeHasDiscoverBracket(recipe, "Salmon")) return true;
  return /\bsalmon\b/.test(recipeIdentityText(recipe));
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

function stableShuffle(items, seed) {
  return [...items]
    .map((item, index) => ({
      item,
      weight: stableJitter(`${seed}|${item.id ?? index}`),
    }))
    .sort((left, right) => left.weight - right.weight)
    .map((entry) => entry.item);
}

function dedupeRecipesById(recipes) {
  const seenIds = new Set();
  const seenTitles = new Set();
  return recipes.filter((recipe) => {
    const id = String(recipe?.id ?? "").trim();
    const titleKey = String(recipe?.title ?? "").trim().toLowerCase().replace(/\s+/g, " ");
    if (!id && !titleKey) return false;
    if ((id && seenIds.has(id)) || (titleKey && seenTitles.has(titleKey))) return false;
    if (id) seenIds.add(id);
    if (titleKey) seenTitles.add(titleKey);
    return true;
  });
}

function scoreCueAffinity(recipe, feedContext = null, filter = "All") {
  const text = recipeDescriptorText(recipe);
  const type = String(recipe.recipe_type ?? recipe.category ?? "").toLowerCase();
  const daypart = String(feedContext?.daypart ?? "");
  const isWeekend = Boolean(feedContext?.isWeekend);
  const weatherMood = String(feedContext?.weatherMood ?? "");
  const temperatureBand = String(feedContext?.temperatureBand ?? "");
  const seasonCue = String(feedContext?.seasonCue ?? "");
  const sweetTreatBias = Number(feedContext?.sweetTreatBias ?? 0.18);
  const locationLabel = String(feedContext?.locationLabel ?? "").toLowerCase();
  const regionCode = String(feedContext?.regionCode ?? "").toLowerCase();

  let score = 0;

  if (daypart === "morning" && isBreakfastRecipe(recipe)) score += 20;
  if (daypart === "midday" && type === "lunch") score += 18;
  if (daypart === "evening" && type === "dinner") score += 18;
  if (["afternoon", "late-night"].includes(daypart) && isSweetTreatRecipe(recipe)) score += 14;
  if (["afternoon", "evening"].includes(daypart) && isDrinkRecipe(recipe)) score += 16;

  if (isWeekend && (isBreakfastRecipe(recipe) || isSweetTreatRecipe(recipe))) score += 12;

  if (weatherMood === "rainy" || weatherMood === "snowy" || temperatureBand === "cold") {
    if (isComfortRecipe(recipe)) score += 22;
  }

  if (weatherMood === "sunny" || temperatureBand === "hot") {
    if (isCoolingRecipe(recipe) || isDrinkRecipe(recipe)) score += 20;
    if (/(ice cream|sorbet|gelato|lemon|mango|berry|peach|coconut)/.test(text)) score += 12;
  }

  if (seasonCue === "summer") {
    if (isCoolingRecipe(recipe) || isDrinkRecipe(recipe) || isSweetTreatRecipe(recipe)) score += 16;
  }
  if (seasonCue === "winter") {
    if (isComfortRecipe(recipe)) score += 16;
  }
  if (seasonCue === "fall" && /(pumpkin|apple|cinnamon|maple|squash)/.test(text)) score += 12;
  if (seasonCue === "spring" && /(berry|lemon|herb|salad|pea|asparagus)/.test(text)) score += 12;

  if (sweetTreatBias >= 0.28 && isSweetTreatRecipe(recipe)) {
    score += sweetTreatBias * 32;
  }

  if (regionCode === "ng" || /lagos|abuja|nigeria/.test(locationLabel)) {
    if (/(jollof|plantain|moi moi|beans|ofada|suya)/.test(text)) score += 12;
  }
  if (regionCode === "ca" || /toronto|canada/.test(locationLabel)) {
    if (/(soup|comfort|chili|pasta|bake)/.test(text)) score += 8;
  }

  score += scorePresetAffinity(recipe, filter) * 1.15;
  return score;
}

function scoreProfileAffinity(recipe, profile = null, filter = "All") {
  if (!profile) return 0;

  const preferredCuisines = new Set((profile.preferredCuisines ?? []).map((value) => String(value).toLowerCase()));
  const goalTerms = new Set((profile.mealPrepGoals ?? []).map((value) => String(value).toLowerCase()));
  const favoriteFoods = new Set((profile.favoriteFoods ?? []).map((value) => String(value).toLowerCase()));
  const favoriteFlavors = new Set((profile.favoriteFlavors ?? []).map((value) => String(value).toLowerCase()));
  const source = String(recipe.source ?? "").toLowerCase();
  const cuisineBlob = `${source} ${(recipe.cuisine_tags ?? []).join(" ").toLowerCase()}`;
  const descriptor = `${recipeDescriptorText(recipe)} ${String(recipe.cook_time_text ?? "").toLowerCase()}`;
  const cookMinutes = parseCookMinutes(recipe.cook_time_text);

  let score = 0;

  for (const cuisine of preferredCuisines) {
    if (cuisine && cuisineBlob.includes(cuisine)) {
      score += 14;
      break;
    }
  }

  for (const food of favoriteFoods) {
    if (food && descriptor.includes(food)) {
      score += 10;
      break;
    }
  }

  for (const flavor of favoriteFlavors) {
    if (flavor && descriptor.includes(flavor)) {
      score += 7;
      break;
    }
  }

  if (goalTerms.has("speed") || goalTerms.has("minimal cleanup")) {
    if (cookMinutes > 0 && cookMinutes <= 30) score += 12;
  }
  if (goalTerms.has("taste") && /(crispy|spicy|butter|smoky|garlic|creamy|jollof)/.test(descriptor)) {
    score += 8;
  }
  if (goalTerms.has("variety")) {
    score += 5;
  }
  if (goalTerms.has("cost") && /(budget|beans|rice|pasta|lentil)/.test(descriptor)) {
    score += 8;
  }
  if (goalTerms.has("macros") && /(protein|chicken|turkey|beef|salmon|shrimp|eggs)/.test(descriptor)) {
    score += 8;
  }

  score += scorePresetAffinity(recipe, filter) * 1.45;
  return score;
}

function scorePresetAffinity(recipe, filter = "All") {
  const preset = getDiscoverPreset(filter);
  if (!preset || preset.key === "all") return 0;

  const hardType = normalizeFilterType(filter);
  const recipeType = String(recipe.recipe_type ?? recipe.category ?? "").toLowerCase();
  let score = 0;

  if (recipeHasDiscoverBracket(recipe, filter)) {
    score += 36;
  } else if (hardType && recipeType === hardType) {
    score += 12;
  }

  if (preset.key === "under500") {
    const calories = parseCalories(recipe);
    if (calories > 0 && calories <= 500) score += 32;
    else if (calories > 500 && calories <= 650) score += 10;
    else if (calories > 650) score -= 8;
  }

  if (preset.key === "beginner") {
    if (recipeHasDiscoverBracket(recipe, "Beginner")) score += 20;
  }

  return score;
}

function passesPresetCategoryGate(recipe, filter = "All") {
  const preset = getDiscoverPreset(filter);
  if (!preset || preset.key === "all" || preset.key === "under500") {
    return true;
  }

  if (recipeHasDiscoverBracket(recipe, filter)) {
    return true;
  }

  const hardType = normalizeFilterType(filter);
  const recipeType = String(recipe.recipe_type ?? recipe.category ?? "").trim().toLowerCase();
  return Boolean(hardType && recipeType === hardType);
}

function applyPresetCategoryGate(recipes, filter = "All") {
  return (recipes ?? []).filter((recipe) => passesPresetCategoryGate(recipe, filter));
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

  const cacheKey = JSON.stringify({
    filter,
    query: String(query ?? "").trim().toLowerCase(),
    profile: summarizeProfileForIntent(profile),
  });
  const cached = readTimedCache(discoverIntentCache, cacheKey, INTENT_CACHE_TTL_MS);
  if (cached) return cached;

  try {
    const completion = await withTimeout(openai.chat.completions.create({
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
    }), 1200, "discover intent timed out");

    const content = completion.choices?.[0]?.message?.content;
    if (typeof content !== "string" || !content.trim()) return null;
    const normalized = normalizeDiscoverIntent(JSON.parse(content));
    discoverIntentCache.set(cacheKey, { value: normalized, createdAt: Date.now() });
    return normalized;
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
  parsedQuery.selectedFilter = filter;
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
    selectedFilter: null,
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

async function embedTextCached(input, model) {
  const normalizedInput = String(input ?? "").trim();
  const cacheKey = `${model}|${normalizedInput}`;
  const cached = readTimedCache(embeddingCache, cacheKey, EMBEDDING_CACHE_TTL_MS);
  if (cached) return cached;
  const embedding = await embedText(normalizedInput, model);
  embeddingCache.set(cacheKey, { value: embedding, createdAt: Date.now() });
  return embedding;
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

const LEGACY_RECIPE_SELECT_FIELDS = [
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
  "calories_kcal",
];

const CANONICAL_RECIPE_SELECT_FIELDS = [
  ...LEGACY_RECIPE_SELECT_FIELDS,
  "subcategory",
  "skill_level",
  "occasion_tags",
  "discover_brackets",
  "discover_brackets_enriched_at",
  "servings_text",
  "servings_count",
  "cook_time_minutes",
  "prep_time_minutes",
  "ingredients_json",
  "steps_json",
];

const SEARCH_RECIPE_SELECT_FIELDS = [
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
  "cook_time_minutes",
  "ingredients_text",
  "published_date",
  "discover_card_image_url",
  "hero_image_url",
  "recipe_url",
  "source",
  "calories_kcal",
  "subcategory",
  "skill_level",
  "occasion_tags",
  "discover_brackets",
  "discover_brackets_enriched_at",
  "servings_text",
  "servings_count",
  "prep_time_minutes",
];

function getPresetHardConstraints(filter = "All") {
  const preset = getDiscoverPreset(filter);
  if (preset.key === "under500") {
    return { maxCaloriesKcal: 500 };
  }
  return {};
}

function passesPresetHardConstraints(recipe, filter = "All") {
  const { maxCaloriesKcal } = getPresetHardConstraints(filter);
  if (maxCaloriesKcal == null) return true;

  const calories = parseCalories(recipe);
  return calories > 0 && calories <= maxCaloriesKcal;
}

function applyPresetHardConstraints(recipes, filter = "All") {
  return (recipes ?? []).filter((recipe) => passesPresetHardConstraints(recipe, filter));
}

function isMissingRecipeColumnError(message) {
  const normalized = String(message ?? "").toLowerCase();
  return normalized.includes("column recipes.") && normalized.includes("does not exist");
}

async function fetchRecipesFromUrl(url) {
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

  return attachDiscoverBrackets(Array.isArray(data) ? data : []);
}

async function fetchRecipesWithSelect({
  ids = null,
  limit = null,
  offset = null,
  orderClause = null,
  fields,
}) {
  const select = fields.join(",");
  let url = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(select)}`;

  if (ids?.length) {
    const inClause = ids.join(",");
    url += `&id=in.(${encodeURIComponent(inClause)})`;
  }

  if (orderClause) {
    url += `&order=${orderClause}`;
  }

  if (limit != null) {
    url += `&limit=${limit}`;
  }

  if (offset != null) {
    url += `&offset=${offset}`;
  }

  return fetchRecipesFromUrl(url);
}

async function fetchRecipesByIds(ids) {
  let data;
  try {
    data = await fetchRecipesWithSelect({
      ids,
      fields: CANONICAL_RECIPE_SELECT_FIELDS,
    });
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }

    data = await fetchRecipesWithSelect({
      ids,
      fields: LEGACY_RECIPE_SELECT_FIELDS,
    });
  }

  const byId = new Map(data.map((recipe) => [recipe.id, recipe]));
  return ids.map((id) => byId.get(id)).filter(Boolean);
}

async function fetchSearchRecipesByIds(ids) {
  let data;
  try {
    data = await fetchRecipesWithSelect({
      ids,
      fields: SEARCH_RECIPE_SELECT_FIELDS,
    });
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }

    data = await fetchRecipesWithSelect({
      ids,
      fields: LEGACY_RECIPE_SELECT_FIELDS,
    });
  }

  const byId = new Map(data.map((recipe) => [recipe.id, recipe]));
  return ids.map((id) => byId.get(id)).filter(Boolean);
}

async function fetchRecipesByIdBatches(ids, batchSize = 70) {
  const orderedIds = [...new Set((ids ?? []).map((id) => String(id ?? "").trim()).filter(Boolean))];
  if (!orderedIds.length) return [];

  const batches = [];
  for (let index = 0; index < orderedIds.length; index += batchSize) {
    batches.push(orderedIds.slice(index, index + batchSize));
  }

  const chunks = await Promise.all(batches.map((batch) => fetchRecipesByIds(batch)));
  const byId = new Map(chunks.flat().map((recipe) => [String(recipe.id), recipe]));
  return orderedIds.map((id) => byId.get(id)).filter(Boolean);
}

async function fetchLatestRecipes(limit) {
  try {
    return await fetchRecipesWithSelect({
      limit,
      orderClause: "updated_at.desc.nullslast,published_date.desc.nullslast",
      fields: CANONICAL_RECIPE_SELECT_FIELDS,
    });
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }

    return fetchRecipesWithSelect({
      limit,
      orderClause: "updated_at.desc.nullslast,published_date.desc.nullslast",
      fields: LEGACY_RECIPE_SELECT_FIELDS,
    });
  }
}

async function fetchSearchFallbackRecipes({ parsedQuery, limit = 30 }) {
  if (!parsedQuery) return [];

  const selectedPresetFilter = parsedQuery.selectedFilter ?? "All";
  const { maxCaloriesKcal } = getPresetHardConstraints(selectedPresetFilter);

  const terms = [...new Set([
    ...(parsedQuery.mustIncludeTerms ?? []),
    ...(parsedQuery.lexicalTerms ?? []),
  ])]
    .map((term) => String(term ?? "").trim().toLowerCase())
    .filter(Boolean)
    .slice(0, 6);

  if (!terms.length) return [];

  const clauses = [];
  for (const term of terms) {
    const escaped = term.replace(/[%*,()]/g, " ").trim();
    if (!escaped) continue;
    clauses.push(`title.ilike.*${escaped}*`);
    clauses.push(`description.ilike.*${escaped}*`);
    clauses.push(`ingredients_text.ilike.*${escaped}*`);
    clauses.push(`recipe_type.ilike.*${escaped}*`);
    clauses.push(`category.ilike.*${escaped}*`);
  }

  if (!clauses.length) return [];

  const select = CANONICAL_RECIPE_SELECT_FIELDS.join(",");
  let url = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(select)}&or=${encodeURIComponent(`(${clauses.join(",")})`)}`;

  if (parsedQuery.filterType) {
    url += `&recipe_type=ilike.*${encodeURIComponent(parsedQuery.filterType)}*`;
  }

  if (maxCaloriesKcal != null) {
    url += `&calories_kcal=lte.${encodeURIComponent(maxCaloriesKcal)}`;
  }

  url += `&order=updated_at.desc.nullslast,published_date.desc.nullslast&limit=${Math.max(limit, 30)}`;

  try {
    return await fetchRecipesFromUrl(url);
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }

    const legacySelect = LEGACY_RECIPE_SELECT_FIELDS.join(",");
    let legacyUrl = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(legacySelect)}&or=${encodeURIComponent(`(${clauses.join(",")})`)}`;

    if (parsedQuery.filterType) {
      legacyUrl += `&recipe_type=ilike.*${encodeURIComponent(parsedQuery.filterType)}*`;
    }

    if (maxCaloriesKcal != null) {
      legacyUrl += `&calories_kcal=lte.${encodeURIComponent(maxCaloriesKcal)}`;
    }

    legacyUrl += `&order=updated_at.desc.nullslast,published_date.desc.nullslast&limit=${Math.max(limit, 30)}`;
    return fetchRecipesFromUrl(legacyUrl);
  }
}

let recipeCountCache = {
  value: null,
  fetchedAt: 0,
};

async function fetchRecipeCount() {
  const now = Date.now();
  if (recipeCountCache.value != null && (now - recipeCountCache.fetchedAt) < 10 * 60 * 1000) {
    return recipeCountCache.value;
  }

  const url = `${SUPABASE_URL}/rest/v1/recipes?select=id&limit=1`;
  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      Prefer: "count=exact",
    },
  });

  if (!response.ok) {
    throw new Error("Recipe count fetch failed");
  }

  const contentRange = response.headers.get("content-range") ?? "";
  const total = Number(contentRange.split("/").pop() ?? "0");
  recipeCountCache = {
    value: Number.isFinite(total) ? total : 0,
    fetchedAt: now,
  };
  return recipeCountCache.value;
}

async function fetchRandomDiscoverRecipes({ limit, seed, filter = "All" }) {
  const totalCount = await fetchRecipeCount().catch(() => 0);
  if (!totalCount || totalCount <= limit) {
    const fallbackRecipes = await fetchLatestRecipes(Math.max(limit, 60));
    return rankPresetFocusedRecipes(fallbackRecipes, { filter, seed: `${seed}|fallback-random` }).slice(0, limit);
  }

  const windowSize = Math.min(Math.max(limit, 36), 60);
  const windowCount = Math.max(4, Math.ceil(limit / 18));
  const maxOffset = Math.max(0, totalCount - windowSize);

  const windows = await Promise.all(
    Array.from({ length: windowCount }, (_, index) => {
      const offset = Math.floor(stableJitter(`${seed}|window|${index}`) * (maxOffset + 1));
      return fetchRecipesWithSelect({
        limit: windowSize,
        offset,
        orderClause: "id.asc",
        fields: CANONICAL_RECIPE_SELECT_FIELDS,
      }).catch(async (error) => {
        if (!isMissingRecipeColumnError(error.message)) throw error;
        return fetchRecipesWithSelect({
          limit: windowSize,
          offset,
          orderClause: "id.asc",
          fields: LEGACY_RECIPE_SELECT_FIELDS,
        });
      });
    })
  );

  return rankPresetFocusedRecipes(dedupeRecipesById(windows.flat()), {
    filter,
    seed: `${seed}|shuffle`,
  }).slice(0, limit);
}

async function fetchDbBracketRecipeIds(filter = "All") {
  const preset = getDiscoverPreset(filter);
  if (!preset || preset.key === "all") {
    return [];
  }

  const bracketPayload = `{${preset.key}}`;
  const url = `${SUPABASE_URL}/rest/v1/recipes?select=id&discover_brackets=cs.${encodeURIComponent(bracketPayload)}&limit=2000`;

  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });

  const data = await response.json().catch(() => []);
  if (!response.ok) {
    const message = data?.message ?? data?.error ?? "Bracket id fetch failed";
    throw new Error(message);
  }

  return Array.isArray(data)
    ? data.map((row) => String(row?.id ?? "").trim()).filter(Boolean)
    : [];
}

async function fetchPresetBracketRecipes({ filter = "All", limit = 600, seed = "preset" }) {
  const preset = getDiscoverPreset(filter);
  if (!preset || preset.key === "all") {
    return fetchRandomDiscoverRecipes({ limit, seed, filter: "All" });
  }

  let bracketIds = [];
  try {
    bracketIds = await fetchDbBracketRecipeIds(filter);
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }
  }

  if (!bracketIds.length) {
    bracketIds = getCachedRecipeIdsForBracket(filter);
  }

  if (!bracketIds.length) {
    return [];
  }

  const shuffledIds = stableShuffle(
    bracketIds.map((id) => ({ id })),
    `${seed}|${preset.key}|ids`
  ).map((item) => item.id);

  const idsToFetch = shuffledIds.slice(0, Math.max(limit, shuffledIds.length));
  const recipes = await fetchRecipesByIdBatches(idsToFetch);
  return applyPresetCategoryGate(
    applyPresetHardConstraints(recipes, filter),
    filter
  ).slice(0, Math.max(limit, recipes.length));
}

function rankPresetShelfRecipes(recipes, { filter = "All", profile = null, feedContext = null, seed = "preset-shelf" }) {
  return [...recipes]
    .map((recipe, index) => {
      const presetScore = scorePresetAffinity(recipe, filter) * 4.5;
      const cueScore = scoreCueAffinity(recipe, feedContext, filter) * 0.45;
      const profileScore = scoreProfileAffinity(recipe, profile, filter) * 0.35;
      const freshness = Math.max(0, 140 - index * 0.38);
      const jitter = stableJitter(`${seed}|${recipe.id}`) * 46;

      return {
        recipe,
        score: presetScore + cueScore + profileScore + freshness + jitter,
      };
    })
    .sort((left, right) => right.score - left.score)
    .map((entry) => entry.recipe);
}

function buildCueOnlyDiscoverContext({ filter = "All", feedContext = null }) {
  const preset = getDiscoverPreset(filter);
  const explicitFilter = normalizeFilterType(filter);
  const cueSegments = [
    "Discover recipes for the Ounje home feed using outside cues only.",
    preset.key !== "all" ? `Preset category: ${preset.title}. ${preset.description}` : "Keep the feed broad across recipe types.",
    explicitFilter ? `Restrict to ${explicitFilter}.` : null,
    feedContext?.daypart ? `Daypart: ${feedContext.daypart}.` : null,
    feedContext?.weatherMood ? `Weather mood: ${feedContext.weatherMood}.` : null,
    feedContext?.temperatureBand ? `Temperature band: ${feedContext.temperatureBand}.` : null,
    feedContext?.seasonCue ? `Season: ${feedContext.seasonCue}.` : null,
    feedContext?.isWeekend ? "Weekend context." : "Weekday context.",
    Number(feedContext?.sweetTreatBias ?? 0) > 0.25 ? "Include a stronger dessert and drinks signal." : null,
    buildTrendCue(feedContext),
  ].filter(Boolean);

  return {
    primaryText: cueSegments.join(" "),
    secondaryText: cueSegments.join(" "),
    filterType: explicitFilter,
  };
}

function buildTrendCue(feedContext = null) {
  const daypart = String(feedContext?.daypart ?? "");
  const season = String(feedContext?.seasonCue ?? "");
  const weather = String(feedContext?.weatherMood ?? "");
  const hot = String(feedContext?.temperatureBand ?? "") === "hot";
  const cold = String(feedContext?.temperatureBand ?? "") === "cold";

  if (hot || season === "summer") {
    return "Trend cues: iced drinks, chilled desserts, grill plates, fresh bowls, bright salads.";
  }
  if (cold || season === "winter" || weather === "rainy" || weather === "snowy") {
    return "Trend cues: soups, braises, noodles, baked comfort, cozy dinner recipes.";
  }
  if (daypart === "morning") {
    return "Trend cues: brunch, breakfast, coffee pairings, pastries, quick egg dishes.";
  }
  if (daypart === "afternoon") {
    return "Trend cues: sweet snacks, salads, bowls, wraps, drinks.";
  }
  return "Trend cues: dinners, treats, drinks, globally inspired meals, playful surprises.";
}

function buildProfileOnlyDiscoverContext({ profile = null, filter = "All" }) {
  const preset = getDiscoverPreset(filter);
  const explicitFilter = normalizeFilterType(filter);
  const cuisines = (profile?.preferredCuisines ?? [])
    .map((value) => String(value).replace(/([A-Z])/g, " $1").trim())
    .join(", ");
  const favoriteFoods = (profile?.favoriteFoods ?? []).join(", ");
  const favoriteFlavors = (profile?.favoriteFlavors ?? []).join(", ");
  const restrictions = [
    ...(profile?.allergies ?? []),
    ...(profile?.hardRestrictions ?? []),
    ...(profile?.neverIncludeFoods ?? []),
  ].join(", ");
  const goals = (profile?.mealPrepGoals ?? []).join(", ");

  const segments = [
    "Discover recipes for the Ounje home feed using user taste signals.",
    preset.key !== "all" ? `Preset category: ${preset.title}. ${preset.description}` : null,
    explicitFilter ? `Restrict to ${explicitFilter}.` : null,
    cuisines ? `Soft cuisine preferences: ${cuisines}.` : null,
    favoriteFoods ? `Usually enjoys foods like ${favoriteFoods}.` : null,
    favoriteFlavors ? `Flavor lean: ${favoriteFlavors}.` : null,
    goals ? `Goals: ${goals}.` : null,
    restrictions ? `Avoid only these hard restrictions: ${restrictions}.` : null,
  ].filter(Boolean);

  return {
    primaryText: segments.join(" "),
    secondaryText: segments.join(" "),
    filterType: explicitFilter,
  };
}

async function buildCueDrivenDiscoverRecipes({ filter = "All", feedContext = null, limit = 48 }) {
  const seed = `${feedContext?.sessionSeed ?? "base"}|cue-local|${feedContext?.windowKey ?? "now"}|${filter}`;
  const broadPool = dedupeRecipesById([
    ...(await fetchLatestRecipes(Math.max(limit * 3, 180))),
    ...(await fetchRandomDiscoverRecipes({
      limit: Math.max(limit * 5, 240),
      seed,
      filter,
    })),
  ]);
  const ranked = rankCueDrivenRecipes(broadPool, { filter, feedContext });
  return diversifyDiscoverRecipes({
    recipes: ranked,
    profile: null,
    filter,
    query: "",
    parsedQuery: null,
    feedContext,
    limit,
  });
}

async function buildProfileDrivenDiscoverRecipes({ profile = null, filter = "All", limit = 60 }) {
  const seed = `${profile?.trimmedPreferredName ?? "anon"}|profile-local|${limit}|${filter}`;
  const broadPool = dedupeRecipesById([
    ...(await fetchLatestRecipes(Math.max(limit * 3, 180))),
    ...(await fetchRandomDiscoverRecipes({
      limit: Math.max(limit * 5, 240),
      seed,
      filter,
    })),
  ]);
  const allergySafePool = filterRecipesByAllergies(broadPool, profile);
  const ranked = rankProfileDrivenRecipes(allergySafePool, { filter, profile });
  return diversifyDiscoverRecipes({
    recipes: ranked,
    profile,
    filter,
    query: "",
    parsedQuery: null,
    feedContext: null,
    limit,
  });
}

function rankPresetFocusedRecipes(recipes, { filter = "All", seed = "preset" }) {
  const shuffled = stableShuffle(recipes, seed);
  const preset = getDiscoverPreset(filter);
  if (preset.key === "all") {
    return shuffled;
  }

  return shuffled
    .map((recipe, index) => ({
      recipe,
      score: scorePresetAffinity(recipe, filter) + stableJitter(`${seed}|${recipe.id}|${index}`) * 8,
    }))
    .sort((left, right) => right.score - left.score)
    .map((entry) => entry.recipe);
}

function rankCueDrivenRecipes(recipes, { filter = "All", feedContext = null }) {
  return [...recipes]
    .map((recipe, index) => ({
      recipe,
      score: scoreCueAffinity(recipe, feedContext, filter) + Math.max(0, 120 - index * 1.4),
    }))
    .sort((left, right) => right.score - left.score)
    .map((entry) => entry.recipe);
}

function rankProfileDrivenRecipes(recipes, { filter = "All", profile = null }) {
  return [...recipes]
    .map((recipe, index) => ({
      recipe,
      score: scoreProfileAffinity(recipe, profile, filter) + Math.max(0, 120 - index * 1.4),
    }))
    .sort((left, right) => right.score - left.score)
    .map((entry) => entry.recipe);
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
  return getDiscoverPresetTitles();
}

function deriveSearchFilters(recipes) {
  return [];
}

function rerankSearchResults(recipes, parsedQuery, limit, profile = null) {
  if (!parsedQuery) return recipes;

  const scored = recipes.map((recipe, index) => ({
    recipe,
    index,
    score: scoreRecipeSearchMatch(recipe, parsedQuery, profile),
  }));

  const gated = scored.filter((entry) => passesSearchIntentGate(entry.recipe, parsedQuery, entry.score));
  const activePool = gated.length >= Math.min(limit, 4) ? gated : scored;
  const strongMatches = activePool.filter((entry) => entry.score >= 35);
  const mediumMatches = activePool.filter((entry) => entry.score >= 16);
  const shouldTrimWeakMatches =
    (parsedQuery.exactPhrase && strongMatches.length >= Math.min(limit, 3))
    || mediumMatches.length >= Math.min(limit, 6);

  const pool = shouldTrimWeakMatches
    ? activePool.filter((entry) => entry.score > 0)
    : activePool;

  return pool
    .sort((left, right) => {
      if (right.score !== left.score) return right.score - left.score;
      return left.index - right.index;
    })
    .slice(0, limit)
    .map((entry) => entry.recipe);
}

function filterStrictSearchResults(recipes, parsedQuery, limit) {
  if (!parsedQuery) return recipes.slice(0, limit);

  const strict = recipes.filter((recipe) => {
    const score = scoreRecipeSearchMatch(recipe, parsedQuery, null);
    return passesSearchIntentGate(recipe, parsedQuery, score);
  });

  return strict.slice(0, limit);
}

function relaxSearchResults(recipes, parsedQuery, limit) {
  if (!parsedQuery) return recipes.slice(0, limit);

  const reranked = rerankSearchResults(recipes, parsedQuery, Math.max(limit * 2, 20));
  const scored = reranked
    .map((recipe) => ({
      recipe,
      score: scoreRecipeSearchMatch(recipe, parsedQuery, null),
    }))
    .filter((entry) => entry.score > 0)
    .sort((left, right) => right.score - left.score)
    .map((entry) => entry.recipe);

  return (scored.length > 0 ? scored : reranked).slice(0, limit);
}

function isFastSearchEligible(query, parsedQuery) {
  const trimmed = String(query ?? "").trim().toLowerCase();
  const termCount = trimmed.split(/\s+/).filter(Boolean).length;
  const semanticCueTerms = [
    "summer", "winter", "spring", "fall", "autumn",
    "comfort", "comforting", "cozy", "healthy", "light",
    "party", "potluck", "weeknight", "holiday", "christmas",
    "thanksgiving", "easter", "ramadan", "iftar",
    "high protein", "meal prep", "quick", "easy", "under",
  ];
  if (trimmed.length <= 2) return true;
  if (semanticCueTerms.some((term) => trimmed.includes(term))) {
    return false;
  }
  if (termCount <= 3 && trimmed.length <= 24 && !(parsedQuery?.occasionTerms?.length) && !(parsedQuery?.avoidTerms?.length) && !(parsedQuery?.mustIncludeTerms?.length > 3)) {
    return true;
  }
  return false;
}

function buildDiscoverSearchCacheKey({ query, filter, limit, profile }) {
  return JSON.stringify({
    query: String(query ?? "").trim().toLowerCase(),
    filter: String(filter ?? "All"),
    limit,
    profile: summarizeProfileForIntent(profile),
  });
}

function readTimedCache(cache, key, ttlMs) {
  const entry = cache.get(key);
  if (!entry) return null;
  if ((Date.now() - entry.createdAt) > ttlMs) {
    cache.delete(key);
    return null;
  }
  return entry.value;
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

function passesSearchIntentGate(recipe, parsedQuery, score) {
  const title = String(recipe.title ?? "").toLowerCase();
  const description = String(recipe.description ?? "").toLowerCase();
  const ingredients = String(recipe.ingredients_text ?? "").toLowerCase();
  const recipeType = String(recipe.recipe_type ?? recipe.recipeType ?? "").toLowerCase();
  const category = String(recipe.category ?? "").toLowerCase();
  const haystack = `${title} ${description} ${ingredients} ${recipeType} ${category}`;
  const lexicalTerms = parsedQuery.lexicalTerms ?? [];
  const mustIncludeTerms = parsedQuery.mustIncludeTerms ?? [];
  const exactPhrase = parsedQuery.exactPhrase ? String(parsedQuery.exactPhrase).toLowerCase() : "";
  const filterType = parsedQuery.filterType ? String(parsedQuery.filterType).toLowerCase() : "";
  const matchedLexicalTerms = lexicalTerms.filter((term) => haystack.includes(String(term).toLowerCase()));
  const matchedMustTerms = mustIncludeTerms.filter((term) => haystack.includes(String(term).toLowerCase()));
  const matchesFilter = filterType ? recipeType === filterType || category === filterType : false;
  const titleMatchedLexicalTerms = lexicalTerms.filter((term) => title.includes(String(term).toLowerCase()));
  const titleOrTypeMatchedLexicalTerms = lexicalTerms.filter((term) => {
    const normalized = String(term).toLowerCase();
    return title.includes(normalized) || recipeType.includes(normalized) || category.includes(normalized);
  });
  const lexicalCoverage = lexicalTerms.length > 0 ? matchedLexicalTerms.length / lexicalTerms.length : 0;
  const isTightPhraseSearch = exactPhrase && lexicalTerms.length >= 2 && lexicalTerms.length <= 4;
  const dessertIntent =
    filterType === "dessert"
    || lexicalTerms.some((term) => /(ice cream|gelato|sorbet|cake|cookie|brownie|pie|dessert|sweet|milkshake|drink|smoothie)/.test(term));

  if (score < -8) return false;
  if (exactPhrase && haystack.includes(exactPhrase)) return true;
  if (matchedMustTerms.length > 0) return score >= 6;

  if (isTightPhraseSearch) {
    if (title.includes(exactPhrase) || description.includes(exactPhrase) || category.includes(exactPhrase)) {
      return true;
    }

    const allTermsPresent = matchedLexicalTerms.length === lexicalTerms.length && lexicalTerms.length > 0;
    const strongSurfaceMatch = titleOrTypeMatchedLexicalTerms.length >= Math.max(1, lexicalTerms.length - 1);
    if (allTermsPresent && strongSurfaceMatch) {
      return true;
    }

    return false;
  }

  if (dessertIntent) {
    return matchesFilter || titleMatchedLexicalTerms.length > 0 || lexicalCoverage >= 0.75;
  }

  if (lexicalTerms.length > 0 && lexicalTerms.length <= 4) {
    return titleOrTypeMatchedLexicalTerms.length > 0 || lexicalCoverage >= 0.6 || matchesFilter || score >= 22;
  }

  return score >= 4 || matchedLexicalTerms.length > 0 || matchesFilter;
}

async function fetchRecipeById(id) {
  const recipes = await fetchRecipesByIds([id]);
  return recipes[0] ?? null;
}

async function fetchSupabaseTableRows(tableName, select, filters = [], orderClauses = []) {
  let url = `${SUPABASE_URL}/rest/v1/${tableName}?select=${encodeURIComponent(select)}`;

  for (const filter of filters) {
    if (filter) url += `&${filter}`;
  }

  for (const orderClause of orderClauses) {
    if (orderClause) url += `&order=${orderClause}`;
  }

  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });

  const data = await response.json().catch(() => []);
  if (!response.ok) {
    const message = data?.message ?? data?.error ?? `${tableName} fetch failed`;
    throw new Error(message);
  }

  return Array.isArray(data) ? data : [];
}

async function fetchRecipeIngredientRows(recipeId) {
  return fetchSupabaseTableRows(
    "recipe_ingredients",
    "id,recipe_id,ingredient_id,display_name,quantity_text,image_url,sort_order",
    [`recipe_id=eq.${encodeURIComponent(recipeId)}`],
    ["sort_order.asc", "created_at.asc"]
  );
}

async function fetchRecipeStepRows(recipeId) {
  return fetchSupabaseTableRows(
    "recipe_steps",
    "id,recipe_id,step_number,instruction_text,tip_text",
    [`recipe_id=eq.${encodeURIComponent(recipeId)}`],
    ["step_number.asc", "created_at.asc"]
  );
}

async function fetchRecipeStepIngredientRows(stepIDs) {
  const normalizedIDs = [...new Set((stepIDs ?? []).map((value) => String(value ?? "").trim()).filter(Boolean))];
  if (!normalizedIDs.length) return [];

  return fetchSupabaseTableRows(
    "recipe_step_ingredients",
    "id,recipe_step_id,ingredient_id,display_name,quantity_text,sort_order",
    [`recipe_step_id=in.(${encodeURIComponent(normalizedIDs.join(","))})`],
    ["recipe_step_id.asc", "sort_order.asc"]
  );
}

function normalizeRecipeDetail(recipe, related = {}) {
  return canonicalizeRecipeDetail(recipe, related);
}

function filterRecipesByAllergies(recipes, profile) {
  const allergies = Array.isArray(profile?.allergies)
    ? profile.allergies.map((value) => String(value ?? "").trim().toLowerCase()).filter(Boolean)
    : [];

  if (!allergies.length) return recipes;

  return recipes.filter((recipe) => {
    const normalized = canonicalizeRecipeDetail(recipe);
    const haystack = [
      normalized.title,
      normalized.description,
      ...(normalized.ingredients ?? []).map((ingredient) => ingredient.name),
    ]
      .join(" ")
      .toLowerCase();

    return !allergies.some((allergen) => haystack.includes(allergen));
  });
}

function deprioritizeHistoricalRecipes(recipes, historyRecipeIds) {
  const seen = new Set((historyRecipeIds ?? []).map((value) => String(value ?? "").trim()).filter(Boolean));
  if (!seen.size) return recipes;

  const fresh = [];
  const repeated = [];

  for (const recipe of recipes) {
    if (seen.has(String(recipe.id))) {
      repeated.push(recipe);
    } else {
      fresh.push(recipe);
    }
  }

  return [...fresh, ...repeated];
}

function normalizePrepCandidateRecipe(recipe) {
  const normalized = canonicalizeRecipeDetail(recipe);
  const descriptor = [
    normalized.title,
    normalized.description,
    normalized.recipe_type,
    normalized.category,
    ...(normalized.dietary_tags ?? []),
    ...(normalized.flavor_tags ?? []),
    ...(normalized.cuisine_tags ?? []),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  const prepMinutes = normalized.cook_time_minutes
    ?? parseCookMinutes(normalized.cook_time_text)
    ?? normalized.prep_time_minutes
    ?? 35;
  const servings = normalized.servings_count ?? 4;
  const tags = inferPrepTags(descriptor, normalized);

  return {
    id: normalized.id,
    title: normalized.title,
    cuisine: inferCuisinePreferenceRaw(normalized),
    prepMinutes,
    servings,
    storageFootprint: inferStorageFootprint(prepMinutes, servings, descriptor),
    tags,
    ingredients: (normalized.ingredients ?? []).map((ingredient) => ({
      name: ingredient.name,
      amount: ingredient.quantity ?? 1,
      unit: ingredient.unit ?? "ct",
      estimatedUnitPrice: estimateIngredientUnitPrice(ingredient.name, ingredient.unit),
    })),
    cardImageURLString: normalized.discover_card_image_url ?? null,
    heroImageURLString: normalized.hero_image_url ?? null,
    source: normalized.source ?? null,
  };
}

function inferPrepTags(descriptor, normalized) {
  const tags = new Set(
    [
      normalized.recipe_type,
      normalized.category,
      ...(normalized.dietary_tags ?? []),
      ...(normalized.flavor_tags ?? []),
      ...(normalized.occasion_tags ?? []),
      ...(normalized.cuisine_tags ?? []),
    ]
      .map((value) => String(value ?? "").trim().toLowerCase())
      .filter(Boolean)
  );

  if ((normalized.cook_time_minutes ?? parseCookMinutes(normalized.cook_time_text) ?? 999) <= 30) {
    tags.add("quick");
  }
  if (/(meal prep|batch|leftover|reheat|tray bake|sheet pan|bowl|salad|stew|chili|curry|pasta)/.test(descriptor)) {
    tags.add("meal-prep");
  }
  if (/(protein|chicken|turkey|beef|salmon|shrimp|beans|lentil|egg)/.test(descriptor)) {
    tags.add("protein-forward");
  }
  if (/(one pan|sheet pan|skillet|tray bake|one-pot)/.test(descriptor)) {
    tags.add("one-pan");
  }
  if (/(chili|stew|curry|bake|comfort|creamy|pasta|jollof)/.test(descriptor)) {
    tags.add("comfort");
  }
  if ((normalized.servings_count ?? 0) >= 5 || /(batch|tray|sheet pan|chili|stew|bake|casserole)/.test(descriptor)) {
    tags.add("batch-friendly");
  }
  if (/(freeze|freezer|chili|stew|meatball|casserole)/.test(descriptor)) {
    tags.add("freezer-friendly");
  }
  if (/(family|kid|crowd|potluck)/.test(descriptor)) {
    tags.add("family-friendly");
  }
  if (/(budget|beans|rice|lentil|pasta|potato)/.test(descriptor)) {
    tags.add("budget");
  }

  return [...tags];
}

function inferStorageFootprint(prepMinutes, servings, descriptor) {
  if (servings >= 6 || /(chili|stew|curry|casserole|bake|meatball|soup)/.test(descriptor)) {
    return { pantry: 2, fridge: 3, freezer: 3 };
  }

  if (prepMinutes <= 30 && /(salad|bowl|shrimp|salmon|fresh|grill|grilled)/.test(descriptor)) {
    return { pantry: 1, fridge: 2, freezer: 0 };
  }

  return { pantry: 2, fridge: 2, freezer: 1 };
}

function inferCuisinePreferenceRaw(normalizedRecipe) {
  const blob = [
    ...(normalizedRecipe.cuisine_tags ?? []),
    normalizedRecipe.source ?? "",
    normalizedRecipe.category ?? "",
    normalizedRecipe.recipe_type ?? "",
    normalizedRecipe.title ?? "",
    normalizedRecipe.description ?? "",
  ]
    .join(" ")
    .toLowerCase();

  const mappings = [
    ["westafrican", /(west african|nigerian|jollof|ofada|moi moi)/],
    ["middleEastern", /(middle eastern|levant|shawarma|harissa|falafel)/],
    ["mediterranean", /(mediterranean|greek|halloumi|orzo)/],
    ["asian", /(asian|stir fry|soy|sesame|udon|rice bowl)/],
    ["indian", /(indian|curry|tandoori|masala|dal)/],
    ["mexican", /(mexican|chipotle|burrito|quesadilla|taco)/],
    ["italian", /(italian|pasta|risotto|parmesan|alfredo)/],
    ["american", /(american|bbq|chili|skillet|cobbler)/],
    ["caribbean", /(caribbean|jerk|plantain|coconut rice)/],
    ["ethiopian", /(ethiopian|berbere|injera)/],
    ["japanese", /(japanese|miso|ramen|teriyaki|onigiri)/],
    ["thai", /(thai|satay|lemongrass|pad thai)/],
    ["korean", /(korean|gochujang|bulgogi|kimchi)/],
    ["chinese", /(chinese|fried rice|mapo|szechuan)/],
    ["french", /(french|gratin|cassoulet|ratatouille)/],
    ["spanish", /(spanish|paella|patatas|salsa verde)/],
    ["vegan", /\bvegan\b/],
  ];

  for (const [rawValue, matcher] of mappings) {
    if (matcher.test(blob)) {
      return rawValue;
    }
  }

  return "american";
}

function estimateIngredientUnitPrice(name, unit) {
  const normalizedName = String(name ?? "").toLowerCase();
  const normalizedUnit = String(unit ?? "").toLowerCase();

  if (/(salmon|shrimp|beef|steak|lamb)/.test(normalizedName)) return 6.4;
  if (/(chicken|turkey|pork|tofu)/.test(normalizedName)) return 4.1;
  if (/(rice|pasta|lentil|beans|potato|oats|flour)/.test(normalizedName)) return 1.1;
  if (/(cheese|feta|halloumi|yogurt|cream)/.test(normalizedName)) return 2.6;
  if (/(herb|spice|garlic|ginger|pepper|salt)/.test(normalizedName)) return 0.8;
  if (/(berry|avocado|mango|pineapple|peach|apple|banana)/.test(normalizedName)) return 1.8;
  if (/(oil|butter|sauce|paste)/.test(normalizedName)) return 1.7;
  if (["lb", "lbs", "pound", "pounds"].includes(normalizedUnit)) return 3.8;
  if (["oz", "ounce", "ounces"].includes(normalizedUnit)) return 1.3;
  if (["cup", "cups"].includes(normalizedUnit)) return 1.2;
  return 1.5;
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

function parseCalories(recipe) {
  const direct = Number(recipe?.calories_kcal);
  if (Number.isFinite(direct) && direct > 0) return direct;

  const raw = String(recipe?.est_calories_text ?? "").toLowerCase();
  const match = raw.match(/(\d{2,4})/);
  return match ? Number(match[1]) : 0;
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

async function resolveRecipeVideoURL(sourceURL) {
  const normalizedSourceURL = String(sourceURL ?? "").trim();
  if (!normalizedSourceURL) {
    throw new Error("Recipe video URL is empty.");
  }

  const expandedSourceURL = await expandCanonicalVideoSourceURL(normalizedSourceURL);

  const cached = recipeVideoResolveCache.get(normalizedSourceURL);
  if (cached && Date.now() - cached.timestamp < 1000 * 60 * 60 * 6) {
    return cached.value;
  }

  const iframeFallback = await buildHostedIframeFallback(expandedSourceURL);
  const fallbackEmbed = iframeFallback ?? buildVideoEmbedFallback(expandedSourceURL);
  let resolved = fallbackEmbed ?? {
    mode: "unavailable",
    provider: inferVideoProvider(expandedSourceURL),
    source_url: expandedSourceURL,
    resolved_url: null,
    poster_url: null,
    duration_seconds: null,
  };

  try {
    const directVideo = await resolveDirectVideoURL(expandedSourceURL);
    if (directVideo) {
      resolved = directVideo;
    }
  } catch (error) {
    console.warn("[recipe/video/resolve] direct resolve failed", expandedSourceURL, error instanceof Error ? error.message : error);
  }

  recipeVideoResolveCache.set(normalizedSourceURL, {
    timestamp: Date.now(),
    value: resolved,
  });
  return resolved;
}

async function expandCanonicalVideoSourceURL(sourceURL) {
  try {
    const url = new URL(sourceURL);
    const host = url.host.toLowerCase();
    const components = url.pathname.split("/").filter(Boolean);

    if (host.includes("tiktok.com") && (components[0] === "t" || components[0] === "vm")) {
      const response = await fetch(sourceURL, {
        redirect: "follow",
        headers: {
          "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        },
      });

      if (response.url && isCanonicalTikTokVideoURL(response.url)) {
        return response.url;
      }
    }
  } catch {
    return sourceURL;
  }

  return sourceURL;
}

function isCanonicalTikTokVideoURL(sourceURL) {
  try {
    const url = new URL(sourceURL);
    const host = url.host.toLowerCase();
    if (!host.includes("tiktok.com")) {
      return false;
    }

    const components = url.pathname.split("/").filter(Boolean);
    const videoIndex = components.findIndex((value) => value === "video");
    return videoIndex > 0 && Boolean(components[videoIndex + 1]);
  } catch {
    return false;
  }
}

async function resolveDirectVideoURL(sourceURL) {
  const extraction = await ytdl(sourceURL, {
    dumpSingleJson: true,
    noWarnings: true,
    skipDownload: true,
    preferFreeFormats: true,
    noCheckCertificates: true,
  });

  const candidates = [
    ...normalizeExtractorFormats(extraction?.requested_formats),
    ...normalizeExtractorFormats(extraction?.formats),
  ];

  const bestFormat = chooseBestDirectVideoFormat(candidates);
  const directURL = bestFormat?.url || (typeof extraction?.url === "string" ? extraction.url : null);
  if (!directURL) return null;

  return {
    mode: "native",
    provider: inferVideoProvider(sourceURL),
    source_url: sourceURL,
    resolved_url: directURL,
    poster_url: typeof extraction?.thumbnail === "string" ? extraction.thumbnail : null,
    duration_seconds: Number.isFinite(extraction?.duration) ? extraction.duration : null,
  };
}

function normalizeExtractorFormats(formats) {
  if (!Array.isArray(formats)) return [];
  return formats
    .filter((format) => format && typeof format.url === "string" && format.url.startsWith("http"))
    .map((format) => ({
      url: format.url,
      ext: String(format.ext ?? "").toLowerCase(),
      height: Number(format.height ?? 0),
      width: Number(format.width ?? 0),
      protocol: String(format.protocol ?? "").toLowerCase(),
      hasVideo: String(format.vcodec ?? "none") !== "none",
      hasAudio: String(format.acodec ?? "none") !== "none",
    }));
}

function chooseBestDirectVideoFormat(formats) {
  const supportedExtensions = new Set(["mp4", "m4v", "mov", "m3u8"]);
  return formats
    .filter((format) => format.hasVideo)
    .filter((format) => supportedExtensions.has(format.ext))
    .sort((left, right) => scoreDirectVideoFormat(right) - scoreDirectVideoFormat(left))[0] ?? null;
}

function scoreDirectVideoFormat(format) {
  const preferredHeight = format.height > 0 ? Math.min(format.height, 1080) : 0;
  const audioBonus = format.hasAudio ? 4000 : 0;
  const mp4Bonus = format.ext === "mp4" ? 2000 : format.ext === "m3u8" ? 800 : 0;
  const httpsBonus = format.protocol.startsWith("http") ? 300 : 0;
  return preferredHeight + audioBonus + mp4Bonus + httpsBonus;
}

function buildVideoEmbedFallback(sourceURL) {
  try {
    const url = new URL(sourceURL);
    const host = url.host.toLowerCase();

    if (host.includes("instagram.com")) {
      const components = url.pathname.split("/").filter(Boolean);
      const kinds = new Set(["reel", "p", "tv"]);
      const kindIndex = components.findIndex((value) => kinds.has(value.toLowerCase()));
      if (kindIndex >= 0 && components[kindIndex + 1]) {
        const kind = components[kindIndex].toLowerCase();
        const mediaID = components[kindIndex + 1];
        return {
          mode: "embed",
          provider: "instagram",
          source_url: sourceURL,
          resolved_url: `https://www.instagram.com/${kind}/${mediaID}/embed/captioned/`,
          poster_url: null,
          duration_seconds: null,
        };
      }
    }

    if (host.includes("tiktok.com")) {
      const components = url.pathname.split("/").filter(Boolean);
      const videoIndex = components.findIndex((value) => value === "video");
      if (videoIndex >= 0 && components[videoIndex + 1]) {
        return {
          mode: "iframe",
          provider: "tiktok",
          source_url: sourceURL,
          resolved_url: `https://www.tiktok.com/player/v1/${components[videoIndex + 1]}?controls=0&progress_bar=0&play_button=0&volume_control=0&fullscreen_button=0&timestamp=0&description=0&music_info=0&rel=0&native_context_menu=0&closed_caption=0&autoplay=1`,
          poster_url: null,
          duration_seconds: null,
        };
      }
    }

    if (host === "youtu.be" || host.includes("youtube.com")) {
      const videoID =
        host === "youtu.be"
          ? url.pathname.split("/").filter(Boolean)[0]
          : new URLSearchParams(url.search).get("v");
      if (videoID) {
        return {
          mode: "embed",
          provider: "youtube",
          source_url: sourceURL,
          resolved_url: `https://www.youtube.com/embed/${videoID}?playsinline=1&autoplay=1&rel=0`,
          poster_url: null,
          duration_seconds: null,
        };
      }
    }
  } catch {
    return null;
  }

  return null;
}

async function buildHostedIframeFallback(sourceURL) {
  try {
    const url = new URL(sourceURL);
    const host = url.host.toLowerCase();
    const provider = inferVideoProvider(sourceURL);

    if (!host.includes("instagram.com") && !host.includes("tiktok.com")) {
      return null;
    }

    const iframeURL = await resolveIframelyIframeURL(sourceURL);
    if (!iframeURL) {
      return null;
    }

    return {
      mode: "iframe",
      provider,
      source_url: sourceURL,
      resolved_url: iframeURL,
      poster_url: null,
      duration_seconds: null,
    };
  } catch {
    return null;
  }
}

async function resolveIframelyIframeURL(sourceURL) {
  if (!IFRAMELY_API_KEY) {
    return null;
  }

  const requestURL = new URL(IFRAMELY_OEMBED_ENDPOINT);
  requestURL.searchParams.set("url", sourceURL);
  requestURL.searchParams.set("api_key", IFRAMELY_API_KEY);
  requestURL.searchParams.set("iframe", "1");
  requestURL.searchParams.set("omit_script", "1");
  requestURL.searchParams.set("playerjs", "1");

  const response = await fetch(requestURL, {
    headers: {
      "user-agent": "Ounje/1.0",
      accept: "application/json",
    },
  });
  if (!response.ok) {
    throw new Error(`Iframely request failed (${response.status})`);
  }

  const payload = await response.json();
  const html = typeof payload?.html === "string" ? payload.html : "";
  if (!html) {
    return null;
  }

  const iframeMatch =
    html.match(/src="([^"]+)"/i) ||
    html.match(/data-iframely-url="([^"]+)"/i);

  if (!iframeMatch?.[1]) {
    return null;
  }

  return iframeMatch[1]
    .replace(/&amp;/g, "&")
    .trim();
}

function inferVideoProvider(sourceURL) {
  try {
    const host = new URL(sourceURL).host.toLowerCase();
    if (host.includes("instagram.com")) return "instagram";
    if (host.includes("tiktok.com")) return "tiktok";
    if (host.includes("youtube.com") || host === "youtu.be") return "youtube";
    if (host.includes("vimeo.com")) return "vimeo";
    return host || "video";
  } catch {
    return "video";
  }
}

function toPgVector(values) {
  return `[${values.join(",")}]`;
}

export default recipe_router;
