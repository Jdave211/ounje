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
  fetchRecipeIngestionJob,
  listCompletedRecipeImportItems,
  listRecipeImportReviewItems,
  processRecipeIngestionJob,
  queueRecipeIngestion,
} from "../../lib/recipe-ingestion.js";
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
const PREP_REGENERATION_INTENT_CACHE_TTL_MS = 5 * 60 * 1000;

const searchResponseCache = new Map();
const discoverIntentCache = new Map();
const prepRegenerationIntentCache = new Map();
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

const SIMILAR_RECIPE_CURATION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    selected_recipe_ids: {
      type: "array",
      items: { type: "string" },
      minItems: 2,
      maxItems: 5,
    },
    rationale: {
      type: "string",
    },
  },
  required: [
    "selected_recipe_ids",
    "rationale",
  ],
};

const SIMILAR_RECIPE_CURATION_SYSTEM_PROMPT = `You are the final taste checker for Ounje's recipe-page recommendations.

You receive one source recipe and a short list of high-ranked candidate recipes.
Your job is to choose only the 2-5 candidates that are actually similar enough to show under "Enjoy." on the recipe page.

Rules:
- Prefer recipes that feel genuinely adjacent in flavor, ingredients, technique, meal format, or overall craving.
- It is okay to include slightly broader neighbors when they would still feel like a natural "you'd probably also like this" follow-up.
- Reject weak cousins, vague category matches, and recipes that only share a single broad ingredient unless the overall dish format and flavor direction still feel close.
- Use the source recipe's ingredients, cuisine, recipe type, and flavor profile as the main filter.
- Do not invent new candidates or reorder beyond what is provided.
- Return only recipe ids that appear in the candidate list.
- If several candidates are borderline, keep the ones that would still feel natural and appetizing to a user finishing the source recipe.
- If the pool is very small, still choose the closest 2-5 from what is available.
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

const PREP_REGENERATION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    intent_summary: { type: "string" },
    boost_terms: {
      type: "array",
      items: { type: "string" },
      maxItems: 14,
    },
    avoid_terms: {
      type: "array",
      items: { type: "string" },
      maxItems: 10,
    },
    novelty_bias: { type: "number", minimum: 0, maximum: 1 },
    overlap_bias: { type: "number", minimum: 0, maximum: 1 },
    max_prep_minutes: { type: "integer", minimum: 0, maximum: 240 },
    preserve_recipe_ids: {
      type: "array",
      items: { type: "string" },
      maxItems: 12,
    },
    replace_recipe_ids: {
      type: "array",
      items: { type: "string" },
      maxItems: 12,
    },
  },
  required: [
    "intent_summary",
    "boost_terms",
    "avoid_terms",
    "novelty_bias",
    "overlap_bias",
    "max_prep_minutes",
    "preserve_recipe_ids",
    "replace_recipe_ids",
  ],
};

const PREP_REGENERATION_SYSTEM_PROMPT = `You interpret prep-regeneration feedback for Ounje.

Input contains:
- selected regeneration focus option
- current prep recipes (titles, tags, ingredients, prep minutes)
- user profile context

Output a compact strategy for selecting the next prep candidate pool.

Rules:
- Respect allergies, hard restrictions, and never-include foods.
- Translate vague user intent into concrete food terms.
- boost_terms should be specific dish, ingredient, cuisine, texture, or meal-shape terms.
- avoid_terms should include terms likely to frustrate this regeneration request.
- novelty_bias is high when variety/newness should be prioritized.
- overlap_bias is high when ingredient reuse should be prioritized.
- max_prep_minutes should be 0 unless time should be constrained.
- preserve_recipe_ids are recipes worth keeping close to.
- replace_recipe_ids are recipes to rotate away from.
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

recipe_router.get("/recipe/detail/:id/similar", async (req, res) => {
  const recipeId = String(req.params.id ?? "").trim();
  const requestedLimit = Number.parseInt(String(req.query.limit ?? "5"), 10);
  const limit = Number.isFinite(requestedLimit)
    ? Math.max(3, Math.min(requestedLimit, 8))
    : 5;

  if (!recipeId) {
    return res.status(400).json({ error: "Provide a recipe id." });
  }

  try {
    if (!openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
      const latest = await fetchLatestRecipes(Math.max(limit + 1, 12));
      return res.json({
        recipes: latest
          .filter((recipe) => String(recipe.id) !== recipeId)
          .slice(0, limit)
          .map(toRecipeCardPayload),
        rankingMode: "similar_fallback_latest",
      });
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
    const detail = normalizeRecipeDetail(recipe, {
      recipeIngredients,
      recipeSteps,
      stepIngredients,
    });

    const ingredientNames = (detail.ingredients ?? [])
      .map((ingredient) => String(ingredient.name ?? ingredient.display_name ?? "").trim())
      .filter(Boolean)
      .slice(0, 8);

    const seedTerms = uniqueStrings([
      ...extractIngredientSignals([
        detail.title,
        detail.description,
        detail.recipe_type,
        detail.category,
        detail.main_protein,
        ...(detail.cuisine_tags ?? []),
        ...(detail.flavor_tags ?? []),
        ...ingredientNames,
      ].filter(Boolean).join(", ")),
      ...expandFlavorTerms([
        ...(detail.cuisine_tags ?? []),
        ...(detail.flavor_tags ?? []),
        ...(detail.occasion_tags ?? []),
        detail.main_protein,
        detail.recipe_type,
        ...ingredientNames.slice(0, 4),
      ].filter(Boolean), 12),
    ]);

    const semanticQuery = uniqueStrings([
      detail.title,
      detail.recipe_type,
      detail.category,
      detail.main_protein,
      ...(detail.cuisine_tags ?? []),
      ...ingredientNames.slice(0, 5),
      ...seedTerms.slice(0, 8),
    ]).join(", ");

    const embedding = await embedTextCached(semanticQuery, "text-embedding-3-small");
    const semanticMatches = await callRecipeRpc("match_recipes_basic", {
      query_embedding: embedding,
      match_count: 32,
    });

    const candidateIDs = [...new Set(
      (semanticMatches ?? [])
        .map((match) => String(match?.id ?? "").trim())
        .filter((id) => id && id !== recipeId)
    )];

    if (!candidateIDs.length) {
      return res.json({ recipes: [], rankingMode: "similar_semantic_empty" });
    }

    const candidates = await fetchRecipesByIds(candidateIDs.slice(0, 24));
    const normalizedIngredientSet = new Set(
      ingredientNames.map((name) => normalizeSearchName(name)).filter(Boolean)
    );

    const scored = candidates
      .filter((candidate) => String(candidate.id) !== recipeId)
      .map((candidate, index) => {
        const candidateIngredients = extractCandidateIngredientNames(candidate);
        const overlapCount = candidateIngredients.reduce((count, ingredient) => (
          normalizedIngredientSet.has(normalizeSearchName(ingredient)) ? count + 1 : count
        ), 0);
        const cuisineOverlap = (candidate.cuisine_tags ?? []).some((tag) =>
          (detail.cuisine_tags ?? []).some((needle) => normalizeSearchName(tag) === normalizeSearchName(needle))
        ) ? 1.2 : 0;
        const typeOverlap = normalizeSearchName(candidate.recipe_type) === normalizeSearchName(detail.recipe_type)
          || normalizeSearchName(candidate.category) === normalizeSearchName(detail.category)
          ? 0.9
          : 0;
        const proteinOverlap = normalizeSearchName(candidate.main_protein) === normalizeSearchName(detail.main_protein)
          ? 1
          : 0;
        const semanticScore = Number(candidateIDs.length - index) / candidateIDs.length;

        return {
          recipe: candidate,
          score:
            semanticScore * 2.4
            + overlapCount * 0.8
            + cuisineOverlap
            + typeOverlap
            + proteinOverlap
            + scoreFlavorAlignment(candidate, seedTerms, []) * 1.35,
        };
      })
      .sort((left, right) => right.score - left.score)
      .slice(0, Math.max(limit + 3, 10));

    const curatedRecipes = await curateSimilarRecipesForDisplay({
      sourceRecipe: detail,
      candidates: scored,
      limit,
    });

    return res.json({
      recipes: curatedRecipes.map(({ recipe: candidate }) => toRecipeCardPayload(candidate)),
      rankingMode: "similar_semantic_flavorgraph",
    });
  } catch (error) {
    console.error("[recipe/detail/similar] failed:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

recipe_router.post("/recipe/imports", async (req, res) => {
  try {
    const body = req.body ?? {};
    const preview = String(body.source_text ?? body.sourceText ?? "").trim().slice(0, 120);
    console.log("[recipe/imports] POST", {
      user_id: body.user_id ?? body.userID ?? null,
      target_state: body.target_state ?? body.targetState ?? null,
      source_preview: preview || null,
    });
    const result = await queueRecipeIngestion(body);
    return res.status(202).json(result);
  } catch (error) {
    console.error("[recipe/imports] queue failed:", error.message);
    return res.status(400).json({ error: error.message });
  }
});

recipe_router.get("/recipe/imports/review", async (req, res) => {
  try {
    const userID = String(req.query.user_id ?? req.query.userID ?? "").trim() || null;
    const limit = Number.parseInt(String(req.query.limit ?? "20"), 10) || 20;
    const items = await listRecipeImportReviewItems({ userID, limit });
    return res.json({
      items,
      count: items.length,
    });
  } catch (error) {
    console.error("[recipe/imports/review] failed:", error.message);
    return res.status(400).json({ error: error.message });
  }
});

recipe_router.get("/recipe/imports/completed", async (req, res) => {
  try {
    const userID = String(req.query.user_id ?? req.query.userID ?? "").trim() || null;
    const limit = Number.parseInt(String(req.query.limit ?? "20"), 10) || 20;
    const items = await listCompletedRecipeImportItems({ userID, limit });
    return res.json({
      items,
      count: items.length,
    });
  } catch (error) {
    console.error("[recipe/imports/completed] failed:", error.message);
    return res.status(400).json({ error: error.message });
  }
});

recipe_router.get("/recipe/imports/:id", async (req, res) => {
  try {
    const result = await fetchRecipeIngestionJob(String(req.params.id ?? "").trim());
    return res.json(result);
  } catch (error) {
    return res.status(404).json({ error: error.message });
  }
});

recipe_router.post("/recipe/imports/:id/process", async (req, res) => {
  try {
    const result = await processRecipeIngestionJob(String(req.params.id ?? "").trim());
    return res.json(result);
  } catch (error) {
    console.error("[recipe/imports/process] failed:", error.message);
    return res.status(400).json({ error: error.message });
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

    if (!hasMeaningfulSearchIntent(parsedQuery)) {
      const genericFallback = await buildGenericSearchFallbackRecipes({
        profile,
        filter,
        parsedQuery,
        feedContext,
        limit,
        reason: "search_generic_intent",
      });
      searchResponseCache.set(
        buildDiscoverSearchCacheKey({ query: trimmedQuery, filter, limit, profile }),
        { value: genericFallback, createdAt: Date.now() }
      );
      return res.json(genericFallback);
    }

    let rankedIds = [];
    const candidateLimit = Math.max(limit * 3, 60);

    if (trimmedQuery.length <= 80) {
      console.log(
        `[recipe/discover] query="${trimmedQuery}" filter="${filter}" resolvedFilter="${filterType ?? "null"}" maxCookMinutes="${maxCookMinutes ?? "null"}" exactPhrase="${parsedQuery?.exactPhrase ?? "null"}" lexicalQuery="${lexicalQuery}" intent="${llmIntent?.userIntent ?? "heuristic"}"`
      );
    }
    const lexicalFallbackPromise = withTimeout(fetchSearchFallbackRecipes({
      parsedQuery,
      limit: candidateLimit,
    }), 4000, "lexical fallback timed out").catch((error) => {
      console.warn("[recipe/discover] lexical fallback failed:", error.message);
      return [];
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

    const basicMatchesPromise = withTimeout(callRecipeRpc("match_recipes_basic", {
      query_embedding: toPgVector(hybridEmbedding),
      match_count: Math.max(limit * 8, 80),
      filter_type: filterType,
      max_cook_minutes: maxCookMinutes,
    }), 2500, "basic rpc timed out").catch((error) => {
      console.warn("[recipe/discover] basic rpc failed:", error.message);
      return [];
    });

    const hybridMatchesPromise = shouldUseHybridLexicalSearch(parsedQuery)
      ? withTimeout(callRecipeRpc("match_recipes_hybrid", {
          query_embedding: toPgVector(hybridEmbedding),
          query_text: lexicalQuery,
          match_count: Math.max(limit * 4, 48),
          filter_type: filterType,
          max_cook_minutes: maxCookMinutes,
        }), 3000, "hybrid rpc timed out").catch((error) => {
          console.warn("[recipe/discover] hybrid rpc failed:", error.message);
          return [];
        })
      : Promise.resolve([]);

    const richMatchesPromise = shouldUseFastSearchPath || !Array.isArray(richEmbedding) || richEmbedding.length === 0
      ? Promise.resolve([])
      : withTimeout(callRecipeRpc("match_recipes_rich", {
          query_embedding: toPgVector(richEmbedding),
          match_count: Math.max(limit * 2, 20),
          filter_type: filterType,
          max_cook_minutes: maxCookMinutes,
        }), 2200, "rich rpc timed out").catch((error) => {
          console.warn("[recipe/discover] rich rpc failed:", error.message);
          return [];
        });

    const [basicMatches, hybridMatches, richMatches] = await Promise.all([
      basicMatchesPromise,
      hybridMatchesPromise,
      richMatchesPromise,
    ]);

    rankedIds = fuseRankedIds([basicMatches, hybridMatches, richMatches], candidateLimit);
    let recipes = rankedIds.length > 0
      ? await fetchSearchRecipesByIds(rankedIds)
      : [];

    recipes = dedupeRecipesById([
      ...recipes,
      ...lexicalFallbackRecipes,
    ]);

    if (!lexicalFallbackRecipes.length) {
      try {
        const lexicalRescueRecipes = await fetchSearchFallbackRecipes({
          parsedQuery,
          limit: candidateLimit,
        });
        recipes = dedupeRecipesById([
          ...recipes,
          ...lexicalRescueRecipes,
        ]);
      } catch (lexicalRescueError) {
        console.warn("[recipe/discover] lexical rescue failed:", lexicalRescueError.message);
      }
    }

    recipes = applySearchFilterGate(recipes, parsedQuery, filter);
    recipes = applyPresetHardConstraints(recipes, filter);

    if (trimmedQuery) {
      recipes = rerankSearchResults(recipes, parsedQuery, candidateLimit, profile);
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
        : (trimmedQuery ? "hybrid_search_embeddings_semantic_strict" : "primary_secondary_embeddings_finetuned_curated"),
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
            applySearchFilterGate(
              filterStrictSearchResults(recipes, parsedQuery, limit),
              parsedQuery,
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
  const {
    profile = null,
    limit = 72,
    feedContext = null,
    history_recipe_ids: historyRecipeIds = [],
    saved_recipe_ids: savedRecipeIds = [],
    regeneration_context: regenerationContextRaw = null,
  } = req.body ?? {};
  const regenerationContext = normalizePrepRegenerationContext(regenerationContextRaw);
  const normalizedSavedRecipeIDs = uniqueStrings(Array.isArray(savedRecipeIds) ? savedRecipeIds : []);

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
    let regenerationIntent = null;
    let prepFocusSearchRecipes = [];
    let savedAnchorRecipes = [];
    let savedAnchorBoostRecipes = [];

    if (normalizedSavedRecipeIDs.length) {
      try {
        savedAnchorRecipes = await fetchRecipesByIds(normalizedSavedRecipeIDs.slice(0, 24));
        if (savedAnchorRecipes.length && openai && SUPABASE_URL && SUPABASE_ANON_KEY) {
          const savedBoostPool = await buildPrepRegenerationBoostPool({
            profile,
            regenerationContext: {
              focus: regenerationContext?.focus ?? "savedRecipeRefresh",
              currentRecipeIDs: savedAnchorRecipes.map((recipe) => recipe.id),
              currentRecipes: savedAnchorRecipes,
              userPrompt: regenerationContext?.userPrompt ?? null,
            },
            limit: Math.max(limit * 2, 48),
          });
          savedAnchorBoostRecipes = savedBoostPool.recipes ?? [];
          regenerationIntent = regenerationIntent ?? savedBoostPool.intent ?? null;
        }
      } catch (error) {
        console.warn("[recipe/prep-candidates] saved-anchor boost failed:", error.message);
      }
    }

    if (regenerationContext) {
      const syntheticSearchQuery = buildPrepFocusSearchQuery({ profile, regenerationContext });
      if (syntheticSearchQuery) {
        try {
          const searchPayload = await buildDiscoverSearchRecipes({
            profile,
            filter: "All",
            query: syntheticSearchQuery,
            limit: Math.max(limit * 3, 72),
            feedContext,
          });
          prepFocusSearchRecipes = searchPayload.recipes ?? [];
          console.log(
            `[recipe/prep-candidates] focus="${regenerationContext.focus}" query="${syntheticSearchQuery}" search_mode="${searchPayload.rankingMode}" search_count=${prepFocusSearchRecipes.length}`
          );
        } catch (error) {
          console.warn("[recipe/prep-candidates] focus-search failed:", error.message);
        }
      }
    }

    if (regenerationContext && openai && SUPABASE_URL && SUPABASE_ANON_KEY) {
      const regenPool = await buildPrepRegenerationBoostPool({
        profile,
        regenerationContext,
        limit: Math.max(limit * 2, 48),
      });
      regenerationIntent = regenPool.intent;
      recipes = dedupeRecipesById([
        ...savedAnchorRecipes,
        ...savedAnchorBoostRecipes,
        ...prepFocusSearchRecipes,
        ...regenPool.recipes,
        ...recipes,
      ]);
    } else {
      recipes = dedupeRecipesById([
        ...savedAnchorRecipes,
        ...savedAnchorBoostRecipes,
        ...prepFocusSearchRecipes,
        ...recipes,
      ]);
    }

    recipes = deprioritizeHistoricalRecipes(recipes, historyRecipeIds);
    recipes = rerankPrepCandidateRecipes(recipes, profile, regenerationContext, regenerationIntent);

    if (openai && recipes.length > 1) {
      recipes = await curateDiscoverRecipesWithLLM({
        recipes,
        profile,
        filter: "All",
        query: buildPrepCandidateCurationQuery(profile, regenerationContext, regenerationIntent),
        parsedQuery: null,
        feedContext,
        limit: recipes.length,
      });
    }

    const normalized = recipes
      .map(normalizePrepCandidateRecipe)
      .filter((recipe) => Array.isArray(recipe.ingredients) && recipe.ingredients.length >= 3)
      .slice(0, limit);

    const rankingMode = [
      `${rankedPayload.rankingMode}_prep_candidates`,
      regenerationContext ? `focus_${regenerationContext.focus}` : null,
      normalizedSavedRecipeIDs.length ? "saved_anchors" : null,
      prepFocusSearchRecipes.length ? "focus_search" : null,
      regenerationIntent ? "regen_intent" : null,
    ]
      .filter(Boolean)
      .join("_");

    return res.json({
      recipes: normalized,
      rankingMode,
    });
  } catch (error) {
    console.error("[recipe/prep-candidates] ranking failed:", error.message);

    try {
      const fallback = (await fetchLatestRecipes(Math.max(limit, 48)))
        .map(normalizePrepCandidateRecipe)
        .filter((recipe) => String(recipe?.title ?? "").trim().length > 0)
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

function buildPrepFocusSearchQuery({ profile = null, regenerationContext = null }) {
  if (!regenerationContext) return "";

  const focus = String(regenerationContext.focus ?? "balanced");
  const preferredCuisines = uniqueStrings((profile?.preferredCuisines ?? []).map(formatPreferenceToken));
  const favoriteFoods = uniqueStrings((profile?.favoriteFoods ?? []).map((value) => String(value ?? "").trim()));
  const favoriteFlavors = uniqueStrings((profile?.favoriteFlavors ?? []).map((value) => String(value ?? "").trim()));
  const currentRecipeTitles = uniqueStrings((regenerationContext.currentRecipes ?? []).map((recipe) => recipe?.title));
  const userPrompt = String(regenerationContext.userPrompt ?? "").trim();
  const seed = `${focus}|${preferredCuisines.join(",")}|${currentRecipeTitles.join(",")}`;
  const explorationCuisine = pickExplorationCuisine(preferredCuisines, seed);

  const queryByFocus = {
    balanced: [
      "What would I like for next meal prep?",
      preferredCuisines.length ? `Lean toward cuisines like ${preferredCuisines.join(", ")}.` : null,
      favoriteFoods.length ? `Include flavors around ${favoriteFoods.slice(0, 5).join(", ")}.` : null,
      "Keep broad appeal and high cookability.",
    ],
    closerToFavorites: [
      "What would I like?",
      preferredCuisines.length ? `Mostly my cuisines: ${preferredCuisines.join(", ")}.` : null,
      favoriteFoods.length ? `Similar to foods I love: ${favoriteFoods.slice(0, 6).join(", ")}.` : null,
      favoriteFlavors.length ? `Flavor lane: ${favoriteFlavors.slice(0, 4).join(", ")}.` : null,
      "Meal prep friendly and repeatable.",
    ],
    moreVariety: [
      "Give me imaginative meal prep ideas with mass appeal.",
      preferredCuisines.length ? `Go outside my usual cuisines (${preferredCuisines.join(", ")}) while staying craveable.` : null,
      explorationCuisine ? `Push toward something like ${explorationCuisine} or similarly distinct cuisines.` : null,
      "Avoid boring repeats from my current prep.",
    ],
    lessPrepTime: [
      "Quick meal prep ideas under 30 minutes.",
      preferredCuisines.length ? `Still aligned with ${preferredCuisines.join(", ")}.` : null,
      "Simple ingredient lists and low effort execution.",
    ],
    tighterOverlap: [
      "Meal prep ideas with strong ingredient overlap.",
      preferredCuisines.length ? `Cuisine lane: ${preferredCuisines.join(", ")}.` : null,
      "Optimize for shared proteins, produce, and pantry staples across multiple meals.",
    ],
    savedRecipeRefresh: [
      "Refresh my trusted meal prep favorites.",
      preferredCuisines.length ? `Anchor in ${preferredCuisines.join(", ")}.` : null,
      favoriteFoods.length ? `Keep the spirit of ${favoriteFoods.slice(0, 5).join(", ")} but with fresh twists.` : null,
      "Comfortable but not repetitive.",
    ],
  };

  const selected = queryByFocus[focus] ?? queryByFocus.balanced;
  return uniqueStrings([
    ...selected,
    ...(userPrompt ? [userPrompt] : []),
  ])
    .filter(Boolean)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 380);
}

function pickExplorationCuisine(preferredCuisines, seed) {
  const pool = [
    "Japanese",
    "Korean",
    "Thai",
    "Ethiopian",
    "Greek",
    "Caribbean",
    "Spanish",
    "Vietnamese",
    "Turkish",
    "Brazilian",
    "Peruvian",
  ];
  const blocked = new Set((preferredCuisines ?? []).map((value) => String(value).toLowerCase()));
  const candidates = pool.filter((value) => !blocked.has(String(value).toLowerCase()));
  if (!candidates.length) return pool[0];
  const index = Math.floor(stableJitter(`${seed}|explore-cuisine`) * candidates.length);
  return candidates[Math.max(0, Math.min(index, candidates.length - 1))];
}

function formatPreferenceToken(value) {
  return String(value ?? "")
    .replace(/([A-Z])/g, " $1")
    .replace(/[_-]+/g, " ")
    .trim();
}

async function buildDiscoverSearchRecipes({
  profile = null,
  filter = "All",
  query = "",
  limit = 30,
  feedContext = null,
}) {
  const trimmedQuery = String(query ?? "").trim();
  if (!trimmedQuery) {
    return { recipes: [], rankingMode: "search_query_empty" };
  }

  const heuristicQuery = parseDiscoverSearchQuery(trimmedQuery, null);
  const shouldUseFastSearchPath = isFastSearchEligible(trimmedQuery, heuristicQuery);
  const llmIntent = shouldUseFastSearchPath
    ? null
    : await inferDiscoverIntentWithLLM({ profile, filter, query: trimmedQuery });
  const {
    filterType,
    semanticQuery,
    lexicalQuery,
    richSearchText,
    maxCookMinutes,
    parsedQuery,
  } = buildDiscoverQueryContext({ profile, filter, query: trimmedQuery, llmIntent });

  if (!hasMeaningfulSearchIntent(parsedQuery)) {
    return buildGenericSearchFallbackRecipes({
      profile,
      filter,
      parsedQuery,
      feedContext,
      limit,
      reason: "prep_focus_generic_intent",
    });
  }

  const candidateLimit = Math.max(limit * 3, 60);
  const lexicalFallbackPromise = withTimeout(fetchSearchFallbackRecipes({
    parsedQuery,
    limit: candidateLimit,
  }), 4000, "lexical fallback timed out").catch((error) => {
    console.warn("[recipe/prep-candidates] focus-search lexical fallback failed:", error.message);
    return [];
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

  const basicMatchesPromise = withTimeout(callRecipeRpc("match_recipes_basic", {
    query_embedding: toPgVector(hybridEmbedding),
    match_count: Math.max(limit * 8, 80),
    filter_type: filterType,
    max_cook_minutes: maxCookMinutes,
  }), 2500, "basic rpc timed out").catch((error) => {
    console.warn("[recipe/prep-candidates] focus-search basic rpc failed:", error.message);
    return [];
  });

  const hybridMatchesPromise = shouldUseHybridLexicalSearch(parsedQuery)
    ? withTimeout(callRecipeRpc("match_recipes_hybrid", {
        query_embedding: toPgVector(hybridEmbedding),
        query_text: lexicalQuery,
        match_count: Math.max(limit * 4, 48),
        filter_type: filterType,
        max_cook_minutes: maxCookMinutes,
      }), 3000, "hybrid rpc timed out").catch((error) => {
        console.warn("[recipe/prep-candidates] focus-search hybrid rpc failed:", error.message);
        return [];
      })
    : Promise.resolve([]);

  const richMatchesPromise = shouldUseFastSearchPath || !Array.isArray(richEmbedding) || richEmbedding.length === 0
    ? Promise.resolve([])
    : withTimeout(callRecipeRpc("match_recipes_rich", {
        query_embedding: toPgVector(richEmbedding),
        match_count: Math.max(limit * 2, 20),
        filter_type: filterType,
        max_cook_minutes: maxCookMinutes,
      }), 2200, "rich rpc timed out").catch((error) => {
        console.warn("[recipe/prep-candidates] focus-search rich rpc failed:", error.message);
        return [];
      });

  const [basicMatches, hybridMatches, richMatches] = await Promise.all([
    basicMatchesPromise,
    hybridMatchesPromise,
    richMatchesPromise,
  ]);

  const rankedIds = fuseRankedIds([basicMatches, hybridMatches, richMatches], candidateLimit);
  let recipes = rankedIds.length > 0
    ? await fetchSearchRecipesByIds(rankedIds)
    : [];

  recipes = dedupeRecipesById([
    ...recipes,
    ...lexicalFallbackRecipes,
  ]);

  if (!lexicalFallbackRecipes.length) {
    try {
      const lexicalRescueRecipes = await fetchSearchFallbackRecipes({
        parsedQuery,
        limit: candidateLimit,
      });
      recipes = dedupeRecipesById([
        ...recipes,
        ...lexicalRescueRecipes,
      ]);
    } catch (lexicalRescueError) {
      console.warn("[recipe/prep-candidates] focus-search lexical rescue failed:", lexicalRescueError.message);
    }
  }

  recipes = applySearchFilterGate(recipes, parsedQuery, filter);
  recipes = applyPresetHardConstraints(recipes, filter);
  recipes = rerankSearchResults(recipes, parsedQuery, candidateLimit, profile);

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

  return {
    recipes,
    rankingMode: shouldUseFastSearchPath
      ? "prep_focus_hybrid_fast"
      : "prep_focus_hybrid_semantic",
  };
}

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
      feedContext,
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
    }), 3500, "discover intent timed out");

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
      temperature: 0,
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
      5000,
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

async function curateSimilarRecipesForDisplay({ sourceRecipe, candidates = [], limit = 5 }) {
  const candidateRecipes = Array.isArray(candidates) ? candidates.filter(Boolean) : [];
  const maxDisplayCount = Math.max(2, Math.min(Number(limit) || 5, 5));
  const displayPool = candidateRecipes.slice(0, Math.max(maxDisplayCount + 2, 7));

  if (!displayPool.length) return [];
  if (!openai || displayPool.length <= 2) return displayPool.slice(0, maxDisplayCount);

  try {
    const completion = await withTimeout(openai.chat.completions.create({
      model: getDiscoverIntentModel(),
      temperature: 0,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "similar_recipe_curation",
          strict: true,
          schema: SIMILAR_RECIPE_CURATION_SCHEMA,
        },
      },
      messages: [
        { role: "system", content: SIMILAR_RECIPE_CURATION_SYSTEM_PROMPT },
        {
          role: "user",
          content: JSON.stringify(
            {
              source_recipe: {
                id: sourceRecipe?.id ?? "",
                title: sourceRecipe?.title ?? "",
                description: sourceRecipe?.description ?? "",
                recipe_type: sourceRecipe?.recipe_type ?? "",
                category: sourceRecipe?.category ?? "",
                main_protein: sourceRecipe?.main_protein ?? "",
                cuisine_tags: sourceRecipe?.cuisine_tags ?? [],
                flavor_tags: sourceRecipe?.flavor_tags ?? [],
                ingredient_names: (sourceRecipe?.ingredients ?? [])
                  .map((ingredient) => String(ingredient.name ?? ingredient.display_name ?? "").trim())
                  .filter(Boolean)
                  .slice(0, 10),
              },
              candidate_recipes: displayPool.map((candidate, index) => ({
                index,
                id: candidate.recipe?.id ?? "",
                title: candidate.recipe?.title ?? "",
                description: candidate.recipe?.description ?? "",
                recipe_type: candidate.recipe?.recipe_type ?? "",
                category: candidate.recipe?.category ?? "",
                main_protein: candidate.recipe?.main_protein ?? "",
                cuisine_tags: candidate.recipe?.cuisine_tags ?? [],
                flavor_tags: candidate.recipe?.flavor_tags ?? [],
                cook_time_text: candidate.recipe?.cook_time_text ?? "",
                ingredient_names: extractCandidateIngredientNames(candidate.recipe).slice(0, 10),
                score: candidate.score ?? 0,
              })),
            },
            null,
            2
          ),
        },
      ],
    }), 4500, "similar recipe curation timed out");

    const content = completion?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || !content.trim()) {
      return displayPool.slice(0, maxDisplayCount);
    }

    const parsed = JSON.parse(content);
    const selectedIDs = Array.isArray(parsed?.selected_recipe_ids)
      ? [...new Set(parsed.selected_recipe_ids.map((value) => String(value).trim()).filter(Boolean))]
      : [];
    if (!selectedIDs.length) {
      return displayPool.slice(0, maxDisplayCount);
    }

    const byId = new Map(displayPool.map((candidate) => [String(candidate.recipe?.id ?? ""), candidate]));
    const curated = selectedIDs.map((id) => byId.get(id)).filter(Boolean);
    if (curated.length < 2) {
      return displayPool.slice(0, maxDisplayCount);
    }

    return curated.slice(0, maxDisplayCount);
  } catch (error) {
    console.warn("[recipe/detail/similar] final curation failed:", error.message);
    return displayPool.slice(0, maxDisplayCount);
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

function uniqueStrings(values, maxItems = Infinity) {
  if (!Array.isArray(values)) return [];

  const seen = new Set();
  const out = [];

  for (const value of values) {
    const normalized = String(value ?? "").trim();
    if (!normalized) continue;
    const key = normalized.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(normalized);
    if (out.length >= maxItems) break;
  }

  return out;
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

function hasMeaningfulSearchIntent(parsedQuery = null) {
  if (!parsedQuery || typeof parsedQuery !== "object") return false;

  if (Array.isArray(parsedQuery.lexicalTerms) && parsedQuery.lexicalTerms.length > 0) return true;
  if (Array.isArray(parsedQuery.mustIncludeTerms) && parsedQuery.mustIncludeTerms.length > 0) return true;
  if (Array.isArray(parsedQuery.avoidTerms) && parsedQuery.avoidTerms.length > 0) return true;
  if (Array.isArray(parsedQuery.occasionTerms) && parsedQuery.occasionTerms.length > 0) return true;
  if (String(parsedQuery.exactPhrase ?? "").trim()) return true;
  if (String(parsedQuery.filterType ?? "").trim()) return true;

  const maxCookMinutes = Number(parsedQuery.maxCookMinutes);
  if (Number.isFinite(maxCookMinutes) && maxCookMinutes > 0) return true;

  return false;
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
    .replace(/\b(?:i|im|i'm|need|want|looking|look|for|show|give|me|my|something|some|anything|any|ideas?|with|that|which|can|could|would|should|you|please|find|suggest|recommend|what|like|today|tonight|now)\b/g, " ")
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
  "what",
  "would",
  "could",
  "should",
  "like",
  "want",
  "need",
  "find",
  "show",
  "give",
  "suggest",
  "recommend",
  "any",
  "anything",
  "something",
  "ideas",
  "idea",
  "my",
  "today",
  "tonight",
  "now",
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
  "main_protein",
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
  "main_protein",
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

  const raw = await response.text().catch(() => "");
  let data = [];
  if (raw) {
    try {
      data = JSON.parse(raw);
    } catch (_error) {
      data = [];
    }
  }

  if (!response.ok) {
    const message = data?.message
      ?? data?.error
      ?? String(raw ?? "").slice(0, 240)
      ?? "Recipe fetch failed";
    throw new Error(`Recipe fetch failed (${response.status}): ${message}`);
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

function normalizeOrderedRecipeIDs(ids = []) {
  return [...new Set((ids ?? []).map((id) => String(id ?? "").trim()).filter(Boolean))];
}

async function fetchRecipesByIdsWithFields(ids, fields, batchSize = 48) {
  const orderedIds = normalizeOrderedRecipeIDs(ids);
  if (!orderedIds.length) return [];

  const normalizedBatchSize = Math.max(1, Math.min(batchSize, 120));
  const chunks = [];
  for (let index = 0; index < orderedIds.length; index += normalizedBatchSize) {
    const batch = orderedIds.slice(index, index + normalizedBatchSize);
    const batchRecipes = await fetchRecipesWithSelect({
      ids: batch,
      fields,
    });
    chunks.push(...batchRecipes);
  }

  const byId = new Map(chunks.flat().map((recipe) => [String(recipe.id), recipe]));
  return orderedIds.map((id) => byId.get(id)).filter(Boolean);
}

async function fetchRecipesByIds(ids) {
  const orderedIds = normalizeOrderedRecipeIDs(ids);
  if (!orderedIds.length) return [];

  let data = [];
  try {
    data = await fetchRecipesByIdsWithFields(orderedIds, CANONICAL_RECIPE_SELECT_FIELDS, 32);
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }

    data = await fetchRecipesByIdsWithFields(orderedIds, LEGACY_RECIPE_SELECT_FIELDS, 32);
  }

  const byId = new Map(data.map((recipe) => [recipe.id, recipe]));
  return orderedIds.map((id) => byId.get(id)).filter(Boolean);
}

async function fetchSearchRecipesByIds(ids) {
  const orderedIds = normalizeOrderedRecipeIDs(ids);
  if (!orderedIds.length) return [];

  let data = [];
  try {
    data = await fetchRecipesByIdsWithFields(orderedIds, SEARCH_RECIPE_SELECT_FIELDS, 24);
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }

    data = await fetchRecipesByIdsWithFields(orderedIds, LEGACY_RECIPE_SELECT_FIELDS, 24);
  }

  const byId = new Map(data.map((recipe) => [recipe.id, recipe]));
  return orderedIds.map((id) => byId.get(id)).filter(Boolean);
}

async function fetchRecipesByIdBatches(ids, batchSize = 70) {
  const orderedIds = normalizeOrderedRecipeIDs(ids);
  if (!orderedIds.length) return [];

  try {
    return fetchRecipesByIdsWithFields(orderedIds, CANONICAL_RECIPE_SELECT_FIELDS, batchSize);
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }
    return fetchRecipesByIdsWithFields(orderedIds, LEGACY_RECIPE_SELECT_FIELDS, batchSize);
  }
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

  if (!terms.length) {
    const genericFallback = await buildGenericSearchFallbackRecipes({
      profile: null,
      filter: selectedPresetFilter,
      parsedQuery,
      feedContext: null,
      limit: Math.max(limit, 30),
      reason: "search_lexical_generic_fallback",
    });
    return genericFallback.recipes;
  }

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

async function buildGenericSearchFallbackRecipes({
  profile = null,
  filter = "All",
  parsedQuery = null,
  feedContext = null,
  limit = 30,
  reason = "search_generic",
}) {
  const normalizedLimit = Math.max(1, Number.isFinite(Number(limit)) ? Number(limit) : 30);
  const poolSize = Math.max(normalizedLimit * 4, 120);
  const safeQuery = String(parsedQuery?.rawQuery ?? "").trim().toLowerCase();
  const seed = `${feedContext?.sessionSeed ?? "discover"}|${feedContext?.windowKey ?? "now"}|generic|${String(filter ?? "all").toLowerCase()}|${safeQuery}`;

  const [randomPool, latestPool] = await Promise.all([
    fetchRandomDiscoverRecipes({
      limit: poolSize,
      seed: `${seed}|random`,
      filter,
    }).catch(() => []),
    fetchLatestRecipes(Math.max(normalizedLimit * 2, 60)).catch(() => []),
  ]);

  let recipes = dedupeRecipesById([
    ...randomPool,
    ...latestPool,
  ]);

  recipes = applySearchFilterGate(recipes, parsedQuery, filter);
  recipes = applyPresetHardConstraints(recipes, filter);

  if (!recipes.length) {
    recipes = applyPresetHardConstraints(
      applyPresetCategoryGate(await fetchLatestRecipes(Math.max(normalizedLimit * 3, 90)), filter),
      filter
    );
  }

  const parsedForRanking = parsedQuery ?? parseDiscoverSearchQuery("", null);
  const reranked = rerankSearchResults(recipes, parsedForRanking, Math.max(normalizedLimit * 2, 24), profile);
  const diversified = diversifyDiscoverRecipes({
    recipes: reranked.length ? reranked : recipes,
    profile,
    filter,
    query: "",
    parsedQuery: null,
    feedContext,
    limit: normalizedLimit,
  }).slice(0, normalizedLimit);

  return {
    recipes: diversified,
    filters: deriveSearchFilters(diversified),
    rankingMode: reason,
  };
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
    ...(await fetchRandomDiscoverRecipes({
      limit: Math.max(limit * 6, 260),
      seed,
      filter,
    })),
    ...(await fetchLatestRecipes(Math.max(limit, 72))),
  ]);
  const ranked = rankCueDrivenRecipes(broadPool, { filter, feedContext, seed });
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

async function buildProfileDrivenDiscoverRecipes({ profile = null, filter = "All", feedContext = null, limit = 60 }) {
  const seed = `${profile?.trimmedPreferredName ?? "anon"}|profile-local|${feedContext?.sessionSeed ?? "base"}|${feedContext?.windowKey ?? "now"}|${limit}|${filter}`;
  const broadPool = dedupeRecipesById([
    ...(await fetchRandomDiscoverRecipes({
      limit: Math.max(limit * 6, 260),
      seed,
      filter,
    })),
    ...(await fetchLatestRecipes(Math.max(limit, 72))),
  ]);
  const allergySafePool = filterRecipesByAllergies(broadPool, profile);
  const ranked = rankProfileDrivenRecipes(allergySafePool, { filter, profile, seed });
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

function rankCueDrivenRecipes(recipes, { filter = "All", feedContext = null, seed = "cue" }) {
  return stableShuffle([...recipes], `${seed}|pre`)
    .map((recipe, index) => ({
      recipe,
      score:
        scoreCueAffinity(recipe, feedContext, filter)
        + Math.max(0, 34 - index * 0.45)
        + stableJitter(`${seed}|${recipe.id}`) * 22,
    }))
    .sort((left, right) => right.score - left.score)
    .map((entry) => entry.recipe);
}

function rankProfileDrivenRecipes(recipes, { filter = "All", profile = null, seed = "profile" }) {
  return stableShuffle([...recipes], `${seed}|pre`)
    .map((recipe, index) => ({
      recipe,
      score:
        scoreProfileAffinity(recipe, profile, filter)
        + Math.max(0, 34 - index * 0.45)
        + stableJitter(`${seed}|${recipe.id}`) * 20,
    }))
    .sort((left, right) => right.score - left.score)
    .map((entry) => entry.recipe);
}

function fuseRankedIds(resultSets, limit) {
  const scores = new Map();
  const k = 60;

  (Array.isArray(resultSets) ? resultSets : []).forEach((items) => {
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

function shouldUseHybridLexicalSearch(parsedQuery) {
  if (!parsedQuery) return false;

  const lexicalTerms = parsedQuery.lexicalTerms ?? [];
  if (!lexicalTerms.length) return false;
  if (parsedQuery.filterType) return true;
  if (parsedQuery.exactPhrase) return true;
  if (lexicalTerms.length >= 2) return true;

  return false;
}

function applySearchFilterGate(recipes, parsedQuery, filter = "All") {
  if (!Array.isArray(recipes) || recipes.length === 0) return [];

  const filterType = normalizeFilterType(parsedQuery?.selectedFilter ?? parsedQuery?.filterType ?? filter);
  const preset = getDiscoverPreset(filter);
  const requiresUnder500 = preset?.key === "under500";

  if (!filterType && !requiresUnder500) {
    return recipes;
  }

  return recipes.filter((recipe) => {
    let matchesType = true;
    if (filterType) {
      const recipeType = normalizeFilterType(recipe.recipe_type ?? recipe.recipeType ?? "");
      const category = normalizeFilterType(recipe.category ?? "");

      if (filterType === "vegan" || filterType === "vegetarian") {
        const dietaryTags = normalizeSearchTagTerms(recipe.dietary_tags);
        matchesType = dietaryTags.includes(filterType);
      } else {
        matchesType = recipeType === filterType || category === filterType;
      }
    }

    if (!matchesType) return false;
    if (!requiresUnder500) return true;

    const calories = parseCalories(recipe);
    return calories > 0 && calories <= 500;
  });
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
  const source = String(recipe.source ?? "").toLowerCase();
  const cuisineTags = normalizeSearchTagTerms(recipe.cuisine_tags);
  const dietaryTags = normalizeSearchTagTerms(recipe.dietary_tags);
  const flavorTags = normalizeSearchTagTerms(recipe.flavor_tags);
  const occasionTags = normalizeSearchTagTerms(recipe.occasion_tags);
  const discoverBrackets = normalizeSearchTagTerms(recipe.discover_brackets);
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
    const inSource = source.includes(term);
    const inCuisine = cuisineTags.some((value) => value.includes(term));
    const inDietary = dietaryTags.some((value) => value.includes(term));
    const inFlavor = flavorTags.some((value) => value.includes(term));
    const inOccasion = occasionTags.some((value) => value.includes(term));
    const inBracket = discoverBrackets.some((value) => value.includes(term));

    if (inTitle) score += 14;
    else if (inType) score += 10;
    else if (inSource || inCuisine) score += 12;
    else if (inOccasion || inBracket) score += 10;
    else if (inDietary || inFlavor) score += 7;
    else if (inDescription) score += 6;
    else if (inIngredients) score += 4;

    if (inTitle || inDescription || inIngredients || inType || inSource || inCuisine || inDietary || inFlavor || inOccasion || inBracket) {
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
    else if (
      description.includes(term)
      || ingredients.includes(term)
      || recipeType.includes(term)
      || category.includes(term)
      || source.includes(term)
      || cuisineTags.some((value) => value.includes(term))
      || dietaryTags.some((value) => value.includes(term))
      || flavorTags.some((value) => value.includes(term))
      || occasionTags.some((value) => value.includes(term))
      || discoverBrackets.some((value) => value.includes(term))
    ) score += 9;
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
  const source = String(recipe.source ?? "").toLowerCase();
  const cuisineTags = normalizeSearchTagTerms(recipe.cuisine_tags);
  const dietaryTags = normalizeSearchTagTerms(recipe.dietary_tags);
  const flavorTags = normalizeSearchTagTerms(recipe.flavor_tags);
  const occasionTags = normalizeSearchTagTerms(recipe.occasion_tags);
  const discoverBrackets = normalizeSearchTagTerms(recipe.discover_brackets);
  const tagHaystack = [...cuisineTags, ...dietaryTags, ...flavorTags, ...occasionTags, ...discoverBrackets].join(" ");
  const haystack = `${title} ${description} ${ingredients} ${recipeType} ${category} ${source} ${tagHaystack}`;
  const lexicalTerms = parsedQuery.lexicalTerms ?? [];
  const mustIncludeTerms = parsedQuery.mustIncludeTerms ?? [];
  const exactPhrase = parsedQuery.exactPhrase ? String(parsedQuery.exactPhrase).toLowerCase() : "";
  const filterType = parsedQuery.filterType ? String(parsedQuery.filterType).toLowerCase() : "";
  const matchedLexicalTerms = lexicalTerms.filter((term) => haystack.includes(String(term).toLowerCase()));
  const matchedMustTerms = mustIncludeTerms.filter((term) => haystack.includes(String(term).toLowerCase()));
  const matchesFilter = filterType
    ? recipeType === filterType
      || category === filterType
      || discoverBrackets.includes(filterType)
      || dietaryTags.includes(filterType)
    : false;
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

function normalizeSearchTagTerms(values) {
  if (!Array.isArray(values)) return [];

  return values
    .map((value) => String(value ?? "").trim().toLowerCase())
    .filter(Boolean);
}

async function fetchRecipeById(id) {
  const normalizedID = String(id ?? "").trim();
  if (normalizedID.startsWith("uir_")) {
    const rows = await fetchSupabaseTableRows(
      "user_import_recipes",
      "id,title,description,author_name,author_handle,author_url,source,source_platform,category,subcategory,recipe_type,skill_level,cook_time_text,servings_text,serving_size_text,daily_diet_text,est_cost_text,est_calories_text,carbs_text,protein_text,fats_text,calories_kcal,protein_g,carbs_g,fat_g,prep_time_minutes,cook_time_minutes,hero_image_url,discover_card_image_url,recipe_url,original_recipe_url,attached_video_url,detail_footnote,image_caption,dietary_tags,flavor_tags,cuisine_tags,occasion_tags,main_protein,cook_method,published_date,ingredients_json,steps_json,servings_count",
      [`id=eq.${encodeURIComponent(normalizedID)}`],
      []
    );
    return rows[0] ?? null;
  }

  const recipes = await fetchRecipesByIds([normalizedID]);
  return recipes[0] ?? null;
}

function recipeTableConfigForID(recipeID) {
  const normalizedID = String(recipeID ?? "").trim();
  return normalizedID.startsWith("uir_")
    ? {
        ingredientTable: "user_import_recipe_ingredients",
        stepTable: "user_import_recipe_steps",
        stepIngredientTable: "user_import_recipe_step_ingredients",
      }
    : {
        ingredientTable: "recipe_ingredients",
        stepTable: "recipe_steps",
        stepIngredientTable: "recipe_step_ingredients",
      };
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
  const config = recipeTableConfigForID(recipeId);
  return fetchSupabaseTableRows(
    config.ingredientTable,
    "id,recipe_id,ingredient_id,display_name,quantity_text,image_url,sort_order",
    [`recipe_id=eq.${encodeURIComponent(recipeId)}`],
    ["sort_order.asc", "created_at.asc"]
  );
}

async function fetchRecipeStepRows(recipeId) {
  const config = recipeTableConfigForID(recipeId);
  return fetchSupabaseTableRows(
    config.stepTable,
    "id,recipe_id,step_number,instruction_text,tip_text",
    [`recipe_id=eq.${encodeURIComponent(recipeId)}`],
    ["step_number.asc", "created_at.asc"]
  );
}

async function fetchRecipeStepIngredientRows(stepIDs) {
  const normalizedIDs = [...new Set((stepIDs ?? []).map((value) => String(value ?? "").trim()).filter(Boolean))];
  if (!normalizedIDs.length) return [];
  const config = normalizedIDs[0]?.startsWith("uirs_")
    ? { stepIngredientTable: "user_import_recipe_step_ingredients" }
    : { stepIngredientTable: "recipe_step_ingredients" };

  return fetchSupabaseTableRows(
    config.stepIngredientTable,
    "id,recipe_step_id,ingredient_id,display_name,quantity_text,sort_order",
    [`recipe_step_id=in.(${encodeURIComponent(normalizedIDs.join(","))})`],
    ["recipe_step_id.asc", "sort_order.asc"]
  );
}

function normalizeRecipeDetail(recipe, related = {}) {
  return canonicalizeRecipeDetail(recipe, related);
}

function normalizeSearchName(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function extractCandidateIngredientNames(recipe) {
  if (Array.isArray(recipe.ingredients_json)) {
    return recipe.ingredients_json
      .map((entry) => String(entry?.display_name ?? entry?.name ?? "").trim())
      .filter(Boolean);
  }

  if (typeof recipe.ingredients_text === "string" && recipe.ingredients_text.trim()) {
    return recipe.ingredients_text
      .split(/\n|,/g)
      .map((value) => value.replace(/^[\-\u2022]\s*/, "").trim())
      .filter(Boolean)
      .slice(0, 12);
  }

  return [];
}

function toRecipeCardPayload(recipe) {
  return {
    id: recipe.id,
    title: recipe.title,
    description: recipe.description ?? null,
    author_name: recipe.author_name ?? null,
    author_handle: recipe.author_handle ?? null,
    category: recipe.category ?? null,
    recipe_type: recipe.recipe_type ?? null,
    cook_time_text: recipe.cook_time_text ?? null,
    cook_time_minutes: recipe.cook_time_minutes ?? null,
    published_date: recipe.published_date ?? null,
    discover_card_image_url: recipe.discover_card_image_url ?? null,
    hero_image_url: recipe.hero_image_url ?? null,
    recipe_url: recipe.recipe_url ?? null,
    source: recipe.source ?? null,
  };
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

function normalizePrepRegenerationContext(value) {
  if (!value || typeof value !== "object") return null;

  const focusCandidates = new Set([
    "balanced",
    "closerToFavorites",
    "moreVariety",
    "lessPrepTime",
    "tighterOverlap",
    "savedRecipeRefresh",
  ]);
  const focus = String(value.focus ?? "").trim();
  const normalizedFocus = focusCandidates.has(focus) ? focus : "balanced";

  const rawRecipes = Array.isArray(value.current_recipes)
    ? value.current_recipes
    : Array.isArray(value.currentRecipes)
      ? value.currentRecipes
      : [];
  const currentRecipes = rawRecipes.map(normalizePrepRegenerationRecipe).filter(Boolean);
  const userPrompt = String(value.user_prompt ?? value.userPrompt ?? value.prompt ?? "").trim();

  const currentRecipeIDs = uniqueStrings([
    ...(Array.isArray(value.current_recipe_ids) ? value.current_recipe_ids : []),
    ...(Array.isArray(value.currentRecipeIDs) ? value.currentRecipeIDs : []),
    ...currentRecipes.map((recipe) => recipe.id),
  ]);

  if (!currentRecipeIDs.length && !currentRecipes.length) {
    return null;
  }

  return {
    focus: normalizedFocus,
    currentRecipeIDs,
    currentRecipes,
    userPrompt: userPrompt.length ? userPrompt : null,
  };
}

function normalizePrepRegenerationRecipe(value) {
  if (!value || typeof value !== "object") return null;

  const id = String(value.id ?? "").trim();
  const title = String(value.title ?? "").trim();
  const cuisine = String(value.cuisine ?? "").trim();
  const prepMinutes = Number.parseInt(String(value.prep_minutes ?? value.prepMinutes ?? 0), 10);
  const tags = uniqueStrings(Array.isArray(value.tags) ? value.tags : []);
  const ingredients = uniqueStrings(Array.isArray(value.ingredients) ? value.ingredients : []);

  if (!id || !title) return null;

  return {
    id,
    title,
    cuisine,
    prepMinutes: Number.isFinite(prepMinutes) ? prepMinutes : 0,
    tags,
    ingredients,
  };
}

async function buildPrepRegenerationBoostPool({
  profile = null,
  regenerationContext = null,
  limit = 96,
}) {
  if (!regenerationContext || !openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return { recipes: [], intent: fallbackPrepRegenerationIntent(regenerationContext) };
  }

  const currentSignals = buildCurrentPrepSignals(regenerationContext.currentRecipes);
  const intent = await inferPrepRegenerationIntent({
    profile,
    regenerationContext,
    currentSignals,
  });
  const seedQueries = buildPrepRegenerationSemanticQueries({
    regenerationContext,
    intent,
    currentSignals,
  });

  if (!seedQueries.length) {
    return { recipes: [], intent };
  }

  const aggregatedMatchScores = new Map();
  await Promise.all(seedQueries.map(async ({ query, weight }) => {
    if (!query) return;
    try {
      const embedding = await embedTextCached(query, "text-embedding-3-small");
      const matches = await callRecipeRpc("match_recipes_basic", {
        query_embedding: embedding,
        match_count: Math.max(24, Math.min(limit * 2, 64)),
      });

      matches.forEach((match, index) => {
        const id = String(match?.id ?? "").trim();
        if (!id) return;
        const rankWeight = Math.max(0.15, 1 - (index / Math.max(matches.length, 1)));
        const similarity = Number(match?.similarity ?? match?.score ?? 0);
        const score = rankWeight * weight + Math.max(0, similarity);
        aggregatedMatchScores.set(id, (aggregatedMatchScores.get(id) ?? 0) + score);
      });
    } catch (error) {
      console.warn("[recipe/prep-candidates] regen semantic query failed:", error.message);
    }
  }));

  const currentRecipeIDSet = new Set(regenerationContext.currentRecipeIDs);
  const candidateIDs = [...aggregatedMatchScores.entries()]
    .filter(([id]) => !currentRecipeIDSet.has(id))
    .sort((left, right) => right[1] - left[1])
    .map(([id]) => id)
    .slice(0, Math.max(limit * 3, 120));

  if (!candidateIDs.length) {
    return { recipes: [], intent };
  }

  const candidates = await fetchRecipesByIds(candidateIDs);
  const flavorSeedTerms = uniqueStrings([
    ...(intent.boostTerms ?? []),
    ...extractIngredientSignals(currentSignals.ingredientTerms.slice(0, 20).join(", ")),
  ]);

  const scored = candidates
    .filter((recipe) => !currentRecipeIDSet.has(String(recipe.id)))
    .map((recipe, index) => {
      const semanticScore = aggregatedMatchScores.get(String(recipe.id)) ?? Math.max(0, 1 - index * 0.03);
      const shiftScore = scorePrepRegenerationShift({
        recipe,
        focus: regenerationContext.focus,
        currentSignals,
        intent,
        profile,
      });

      return {
        recipe,
        score:
          semanticScore * 22
          + shiftScore
          + scoreFlavorAlignment(recipe, flavorSeedTerms, intent.avoidTerms ?? []) * 1.15,
      };
    })
    .sort((left, right) => right.score - left.score)
    .slice(0, Math.max(limit, 24))
    .map((entry) => entry.recipe);

  return { recipes: scored, intent };
}

function buildPrepRegenerationSemanticQueries({ regenerationContext, intent, currentSignals }) {
  const queries = [];
  const focus = regenerationContext?.focus ?? "balanced";
  const focusDescriptors = {
    balanced: "balanced satisfying meal prep rotation",
    closerToFavorites: "familiar favorite comfort meals",
    moreVariety: "novel diverse cuisines and formats",
    lessPrepTime: "quick easy weeknight meal prep under 30 minutes",
    tighterOverlap: "ingredient overlap pantry-efficient meal prep",
    savedRecipeRefresh: "saved-style trusted favorites refresh",
  };

  queries.push({
    query: uniqueStrings([
      focusDescriptors[focus],
      ...(intent?.boostTerms ?? []).slice(0, 8),
      ...currentSignals.cuisineTerms.slice(0, 4),
      ...currentSignals.ingredientTerms.slice(0, 8),
    ]).join(", "),
    weight: 1.35,
  });

  for (const recipe of regenerationContext?.currentRecipes ?? []) {
    const base = [
      recipe.title,
      recipe.cuisine,
      ...(recipe.tags ?? []).slice(0, 4),
      ...(recipe.ingredients ?? []).slice(0, 6),
      ...(intent?.boostTerms ?? []).slice(0, 4),
    ]
      .filter(Boolean)
      .join(", ");
    if (!base) continue;
    queries.push({
      query: `${focusDescriptors[focus]} | ${base}`,
      weight: focus === "tighterOverlap" ? 1.2 : 1.0,
    });
  }

  return queries
    .map((entry) => ({
      query: String(entry.query ?? "").trim(),
      weight: Number.isFinite(entry.weight) ? entry.weight : 1,
    }))
    .filter((entry) => entry.query.length >= 6)
    .slice(0, 8);
}

async function inferPrepRegenerationIntent({ profile = null, regenerationContext = null, currentSignals = null }) {
  const cacheKey = JSON.stringify({
    focus: regenerationContext?.focus ?? "balanced",
    recipeIds: regenerationContext?.currentRecipeIDs ?? [],
    userPrompt: regenerationContext?.userPrompt ?? "",
    profile: summarizeProfileForIntent(profile),
  });
  const cached = readTimedCache(prepRegenerationIntentCache, cacheKey, PREP_REGENERATION_INTENT_CACHE_TTL_MS);
  if (cached) return cached;

  if (!openai) {
    return fallbackPrepRegenerationIntent(regenerationContext);
  }

  const fallback = fallbackPrepRegenerationIntent(regenerationContext);

  try {
    const completion = await withTimeout(openai.chat.completions.create({
      model: getDiscoverIntentModel(),
      temperature: 0.2,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "prep_regeneration_intent",
          strict: true,
          schema: PREP_REGENERATION_SCHEMA,
        },
      },
      messages: [
        { role: "system", content: PREP_REGENERATION_SYSTEM_PROMPT },
        {
          role: "user",
          content: JSON.stringify({
            focus: regenerationContext?.focus ?? "balanced",
            current_prep_recipes: regenerationContext?.currentRecipes ?? [],
            current_prep_signals: currentSignals ?? {},
            user_prompt: regenerationContext?.userPrompt ?? null,
            profile,
          }, null, 2),
        },
      ],
    }), 9000);

    const content = completion?.choices?.[0]?.message?.content;
    const parsed = typeof content === "string" && content.trim()
      ? JSON.parse(content)
      : null;
    const normalized = normalizePrepRegenerationIntent(parsed, fallback);
    prepRegenerationIntentCache.set(cacheKey, { value: normalized, createdAt: Date.now() });
    return normalized;
  } catch (error) {
    console.warn("[recipe/prep-candidates] regen intent inference failed:", error.message);
    return fallback;
  }
}

function fallbackPrepRegenerationIntent(regenerationContext = null) {
  const focus = regenerationContext?.focus ?? "balanced";
  const defaults = {
    balanced: {
      summary: "Shift toward more satisfying but still practical prep recipes.",
      boostTerms: ["meal prep", "high protein", "batch friendly", "comfort"],
      avoidTerms: [],
      noveltyBias: 0.35,
      overlapBias: 0.5,
      maxPrepMinutes: 0,
    },
    closerToFavorites: {
      summary: "Increase familiarity with favorite cuisines and ingredients.",
      boostTerms: ["familiar", "favorite", "comfort", "high protein"],
      avoidTerms: [],
      noveltyBias: 0.2,
      overlapBias: 0.62,
      maxPrepMinutes: 0,
    },
    moreVariety: {
      summary: "Rotate farther from current prep and broaden cuisine/format variety.",
      boostTerms: ["global", "new", "creative", "varied"],
      avoidTerms: [],
      noveltyBias: 0.85,
      overlapBias: 0.2,
      maxPrepMinutes: 0,
    },
    lessPrepTime: {
      summary: "Prioritize faster prep and lighter execution load.",
      boostTerms: ["quick", "fast", "easy", "under 30"],
      avoidTerms: ["slow cooker", "braise", "multi-step"],
      noveltyBias: 0.3,
      overlapBias: 0.45,
      maxPrepMinutes: 32,
    },
    tighterOverlap: {
      summary: "Maximize ingredient reuse across the prep cycle.",
      boostTerms: ["ingredient overlap", "pantry", "batch", "reuse"],
      avoidTerms: [],
      noveltyBias: 0.25,
      overlapBias: 0.92,
      maxPrepMinutes: 0,
    },
    savedRecipeRefresh: {
      summary: "Favor trusted meal shapes with enough freshness to avoid fatigue.",
      boostTerms: ["trusted", "familiar", "refresh", "meal prep"],
      avoidTerms: [],
      noveltyBias: 0.45,
      overlapBias: 0.58,
      maxPrepMinutes: 0,
    },
  };

  const strategy = defaults[focus] ?? defaults.balanced;
  return {
    summary: strategy.summary,
    boostTerms: strategy.boostTerms,
    avoidTerms: strategy.avoidTerms,
    noveltyBias: strategy.noveltyBias,
    overlapBias: strategy.overlapBias,
    maxPrepMinutes: strategy.maxPrepMinutes,
    preserveRecipeIDs: [],
    replaceRecipeIDs: [],
  };
}

function normalizePrepRegenerationIntent(value, fallback) {
  if (!value || typeof value !== "object") return fallback;

  const normalized = {
    summary: String(value.intent_summary ?? fallback.summary ?? "").trim() || fallback.summary,
    boostTerms: uniqueStrings(Array.isArray(value.boost_terms) ? value.boost_terms : fallback.boostTerms),
    avoidTerms: uniqueStrings(Array.isArray(value.avoid_terms) ? value.avoid_terms : fallback.avoidTerms),
    noveltyBias: clampNumber(value.novelty_bias, fallback.noveltyBias, 0, 1),
    overlapBias: clampNumber(value.overlap_bias, fallback.overlapBias, 0, 1),
    maxPrepMinutes: clampNumber(value.max_prep_minutes, fallback.maxPrepMinutes, 0, 240),
    preserveRecipeIDs: uniqueStrings(Array.isArray(value.preserve_recipe_ids) ? value.preserve_recipe_ids : []),
    replaceRecipeIDs: uniqueStrings(Array.isArray(value.replace_recipe_ids) ? value.replace_recipe_ids : []),
  };

  return normalized;
}

function buildCurrentPrepSignals(currentRecipes = []) {
  const ingredientTerms = uniqueStrings(
    currentRecipes
      .flatMap((recipe) => recipe.ingredients ?? [])
      .map((value) => normalizeSearchName(value))
      .filter(Boolean)
  );

  const cuisineTerms = uniqueStrings(
    currentRecipes
      .map((recipe) => normalizeSearchName(recipe.cuisine))
      .filter(Boolean)
  );

  const prepMinutes = currentRecipes
    .map((recipe) => Number(recipe.prepMinutes ?? 0))
    .filter((value) => Number.isFinite(value) && value > 0);
  const avgPrepMinutes = prepMinutes.length
    ? prepMinutes.reduce((sum, value) => sum + value, 0) / prepMinutes.length
    : 0;

  return {
    ingredientTerms,
    cuisineTerms,
    avgPrepMinutes,
  };
}

function ingredientOverlapRatio(recipe, currentSignals) {
  const currentIngredients = new Set(currentSignals?.ingredientTerms ?? []);
  if (!currentIngredients.size) return 0;
  const candidate = new Set(
    extractCandidateIngredientNames(recipe)
      .map((value) => normalizeSearchName(value))
      .filter(Boolean)
  );
  if (!candidate.size) return 0;

  let overlap = 0;
  for (const ingredient of candidate) {
    if (currentIngredients.has(ingredient)) overlap += 1;
  }
  return overlap / candidate.size;
}

function scorePrepRegenerationShift({ recipe, focus, currentSignals, intent, profile }) {
  const descriptor = [
    recipe.title,
    recipe.description,
    recipe.recipe_type,
    recipe.category,
    recipe.ingredients_text,
    ...(recipe.flavor_tags ?? []),
    ...(recipe.cuisine_tags ?? []),
    ...(recipe.occasion_tags ?? []),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  const overlap = ingredientOverlapRatio(recipe, currentSignals);
  const cookMinutes = Number(recipe.cook_time_minutes ?? recipe.prep_time_minutes ?? parseCookMinutes(recipe.cook_time_text) ?? 0);
  const cuisineSet = new Set((currentSignals?.cuisineTerms ?? []).map((value) => normalizeSearchName(value)));
  const candidateCuisine = normalizeSearchName((recipe.cuisine_tags ?? [])[0] ?? recipe.source ?? "");
  const hasCuisineOverlap = candidateCuisine && cuisineSet.has(candidateCuisine);

  let score = 0;

  const maxPrepMinutes = Number(intent?.maxPrepMinutes ?? 0);
  if (maxPrepMinutes > 0 && cookMinutes > 0) {
    score += cookMinutes <= maxPrepMinutes ? 16 : -12;
  }

  const boostTerms = intent?.boostTerms ?? [];
  for (const term of boostTerms) {
    const normalized = normalizeSearchName(term);
    if (normalized && descriptor.includes(normalized)) score += 2.6;
  }

  const avoidTerms = intent?.avoidTerms ?? [];
  for (const term of avoidTerms) {
    const normalized = normalizeSearchName(term);
    if (normalized && descriptor.includes(normalized)) score -= 4.1;
  }

  switch (focus) {
    case "closerToFavorites":
      score += scorePrepProfileAffinity(recipe, profile) * 0.72;
      score += overlap * 8;
      break;
    case "moreVariety":
      score += (1 - overlap) * 11;
      if (!hasCuisineOverlap) score += 7;
      break;
    case "lessPrepTime":
      if (cookMinutes > 0) score += Math.max(-16, 22 - cookMinutes * 0.6);
      break;
    case "tighterOverlap":
      score += overlap * 18;
      if (hasCuisineOverlap) score += 4;
      break;
    case "savedRecipeRefresh":
      score += scorePrepProfileAffinity(recipe, profile) * 0.42;
      score += (1 - Math.abs(overlap - 0.5)) * 7;
      break;
    case "balanced":
    default:
      score += scorePrepProfileAffinity(recipe, profile) * 0.34;
      score += (1 - Math.abs(overlap - 0.45)) * 6;
      break;
  }

  const noveltyBias = Number(intent?.noveltyBias ?? 0);
  const overlapBias = Number(intent?.overlapBias ?? 0);
  score += (1 - overlap) * noveltyBias * 11;
  score += overlap * overlapBias * 11;

  return score;
}

function clampNumber(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function rerankPrepCandidateRecipes(recipes, profile = null, regenerationContext = null, regenerationIntent = null) {
  if (!Array.isArray(recipes) || recipes.length <= 1) return recipes;

  const seedTerms = [
    ...(profile?.favoriteFoods ?? []),
    ...(profile?.favoriteFlavors ?? []),
    ...(profile?.mealPrepGoals ?? []),
    ...(profile?.preferredCuisines ?? []),
    ...(regenerationIntent?.boostTerms ?? []),
  ]
    .flatMap((value) => extractIngredientSignals(String(value ?? "")))
    .filter(Boolean);

  const avoidTerms = [
    ...(profile?.allergies ?? []),
    ...(profile?.hardRestrictions ?? []),
    ...(profile?.neverIncludeFoods ?? []),
    ...(regenerationIntent?.avoidTerms ?? []),
  ];

  const currentSignals = buildCurrentPrepSignals(regenerationContext?.currentRecipes ?? []);
  const currentRecipeIDSet = new Set(regenerationContext?.currentRecipeIDs ?? []);
  const seed = `${profile?.trimmedPreferredName ?? "anon"}|prep-rerank|${(profile?.preferredCuisines ?? []).join(",")}|${(profile?.favoriteFoods ?? []).join(",")}`;

  return stableShuffle([...recipes], `${seed}|pre`)
    .map((recipe, index) => ({
      recipe,
      score:
        Math.max(0, 82 - index * 0.65)
        + scoreFlavorAlignment(recipe, seedTerms, avoidTerms) * 1.2
        + scorePrepProfileAffinity(recipe, profile)
        + (currentRecipeIDSet.has(String(recipe.id)) ? -40 : 0)
        + scorePrepRegenerationShift({
          recipe,
          focus: regenerationContext?.focus ?? "balanced",
          currentSignals,
          intent: regenerationIntent ?? fallbackPrepRegenerationIntent(regenerationContext),
          profile,
        })
        + stableJitter(`${seed}|${recipe.id}`) * 10,
    }))
    .sort((left, right) => right.score - left.score)
    .map((entry) => entry.recipe);
}

function scorePrepProfileAffinity(recipe, profile = null) {
  if (!profile) return 0;

  const descriptor = [
    recipe.title,
    recipe.description,
    recipe.recipe_type,
    recipe.category,
    recipe.ingredients_text,
    ...(recipe.flavor_tags ?? []),
    ...(recipe.cuisine_tags ?? []),
    ...(recipe.dietary_tags ?? []),
    ...(recipe.occasion_tags ?? []),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  let score = 0;

  for (const cuisine of profile.preferredCuisines ?? []) {
    const normalized = String(cuisine ?? "").toLowerCase().replace(/([A-Z])/g, " $1");
    if (descriptor.includes(normalized.trim())) score += 8;
  }

  for (const food of profile.favoriteFoods ?? []) {
    const normalized = String(food ?? "").trim().toLowerCase();
    if (normalized && descriptor.includes(normalized)) score += 8;
  }

  for (const flavor of profile.favoriteFlavors ?? []) {
    const normalized = String(flavor ?? "").trim().toLowerCase();
    if (normalized && descriptor.includes(normalized)) score += 5;
  }

  for (const goal of profile.mealPrepGoals ?? []) {
    const normalized = String(goal ?? "").trim().toLowerCase();
    if (!normalized) continue;
    if (normalized.includes("speed") && /quick|easy|fast|under 30/.test(descriptor)) score += 6;
    if (normalized.includes("taste") && /spicy|savory|crispy|comfort|creamy/.test(descriptor)) score += 5;
    if (normalized.includes("variety") && /global|inspired|thai|indian|mexican|mediterranean|nigerian/.test(descriptor)) score += 4;
    if (normalized.includes("cost") && /budget|bean|lentil|rice|pasta|potato/.test(descriptor)) score += 5;
    if (normalized.includes("macros") && /protein|chicken|salmon|shrimp|turkey|egg|tofu/.test(descriptor)) score += 5;
  }

  return score;
}

function buildPrepCandidateCurationQuery(profile = null, regenerationContext = null, regenerationIntent = null) {
  const cuisines = (profile?.preferredCuisines ?? []).join(", ");
  const favoriteFoods = (profile?.favoriteFoods ?? []).join(", ");
  const favoriteFlavors = (profile?.favoriteFlavors ?? []).join(", ");
  const regenerationFocus = regenerationContext?.focus ?? null;
  const regenerationPrompt = String(regenerationContext?.userPrompt ?? "").trim();
  const regenerationSummary = regenerationIntent?.summary ?? null;
  const regenerationBoostTerms = (regenerationIntent?.boostTerms ?? []).join(", ");
  const regenerationAvoidTerms = (regenerationIntent?.avoidTerms ?? []).join(", ");

  return [
    "Build a meal-prep candidate shelf for breakfast, lunch, and dinner.",
    "Prefer recipes that can work together as one prep cycle.",
    "Reward ingredient overlap that reduces total cart cost without making every meal feel the same.",
    "Keep the shelf diverse in cuisine, dominant protein, and format.",
    regenerationFocus ? `Regeneration focus: ${regenerationFocus}.` : null,
    regenerationPrompt ? `User prompt: ${regenerationPrompt}.` : null,
    regenerationSummary ? `Regeneration intent: ${regenerationSummary}.` : null,
    regenerationBoostTerms ? `Boost terms: ${regenerationBoostTerms}.` : null,
    regenerationAvoidTerms ? `Avoid terms: ${regenerationAvoidTerms}.` : null,
    cuisines ? `Lean toward cuisines like ${cuisines}.` : null,
    favoriteFoods ? `Favorite foods: ${favoriteFoods}.` : null,
    favoriteFlavors ? `Flavor lean: ${favoriteFlavors}.` : null,
  ]
    .filter(Boolean)
    .join(" ");
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
  if (/(breakfast|brunch|oat|oatmeal|yogurt|granola|pancake|waffle|toast|egg bite|muffin)/.test(descriptor)) {
    tags.add("breakfast");
  }
  if (/(lunch|salad|sandwich|wrap|bowl|soup)/.test(descriptor)) {
    tags.add("lunch");
  }
  if (/(dinner|curry|stew|pasta|roast|sheet pan|tray bake|skillet|salmon|chicken|beef|shrimp)/.test(descriptor)) {
    tags.add("dinner");
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
