import express from "express";
import crypto from "node:crypto";
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
import {
  normalizeRecipeDetail as canonicalizeRecipeDetail,
  parseIngredientObjects,
  parseInstructionSteps as parseStructuredInstructionSteps,
} from "../../lib/recipe-detail-utils.js";
import {
  fetchRecipeIngestionJob,
  listCompletedRecipeImportItems,
  persistNormalizedRecipe,
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
import { createLoggedOpenAI, withAIUsageContext } from "../../lib/openai-usage-logger.js";
import { createOrReuseRecipeShareLink, resolveRecipeShareLink } from "../../lib/recipe-share-links.js";
import {
  getRecipeAdaptationContract,
  mergeEditSummaries,
  validateAdaptedRecipe,
} from "../../lib/recipe-adaptation-contracts.js";

const recipe_router = express.Router();

dotenv.config({ path: new URL("../../.env", import.meta.url).pathname });

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";
const IFRAMELY_API_KEY = process.env.IFRAMELY_API_KEY ?? "";
const IFRAMELY_OEMBED_ENDPOINT = process.env.IFRAMELY_OEMBED_ENDPOINT ?? "https://iframe.ly/api/oembed";

const openai = OPENAI_API_KEY ? createLoggedOpenAI({ apiKey: OPENAI_API_KEY, service: "recipe-api" }) : null;

const SEARCH_RESPONSE_CACHE_TTL_MS = 2 * 60 * 1000;
const DISCOVER_FEED_CACHE_TTL_MS = 2 * 60 * 1000;
const DISCOVER_BROAD_POOL_CACHE_TTL_MS = 2 * 60 * 1000;
const INTENT_CACHE_TTL_MS = 15 * 60 * 1000;
const EMBEDDING_CACHE_TTL_MS = 30 * 60 * 1000;
const PREP_REGENERATION_INTENT_CACHE_TTL_MS = 5 * 60 * 1000;

const searchResponseCache = new Map();
const discoverFeedCache = new Map();
const discoverBroadPoolCache = new Map();
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
    retrieval_prompt: { type: "string" },
    hybrid_query: { type: "string" },
    adjudication_notes: { type: "string" },
    filter_type: {
      type: "string",
      enum: ["", "breakfast", "lunch", "dinner", "dessert", "vegetarian", "vegan"],
    },
    search_vertical: {
      type: "string",
      enum: ["", "meal", "drink", "snack", "dessert"],
    },
    temperature_requirement: {
      type: "string",
      enum: ["", "hot", "cold", "iced", "frozen", "room-temperature"],
    },
    max_cook_minutes: { type: "integer", minimum: 0, maximum: 240 },
    min_calories_kcal: { type: "integer", minimum: 0, maximum: 4000 },
    max_calories_kcal: { type: "integer", minimum: 0, maximum: 4000 },
    servings_hint: { type: "string" },
    required_ingredients: {
      type: "array",
      items: { type: "string" },
      maxItems: 8,
    },
    excluded_ingredients: {
      type: "array",
      items: { type: "string" },
      maxItems: 8,
    },
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
    "retrieval_prompt",
    "hybrid_query",
    "adjudication_notes",
    "filter_type",
    "search_vertical",
    "temperature_requirement",
    "max_cook_minutes",
    "min_calories_kcal",
    "max_calories_kcal",
    "servings_hint",
    "required_ingredients",
    "excluded_ingredients",
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
- Rewrite the prompt into the strongest retrieval phrasing for hybrid semantic search.
- Keep all extracted terms concise and food-specific.
- filter_type must be one of: breakfast, lunch, dinner, dessert, vegetarian, vegan, or empty string.
- search_vertical should be meal, drink, snack, dessert, or empty string when not needed.
- temperature_requirement should capture explicit service temperature cues like hot, cold, iced, or frozen, otherwise empty string.
- max_cook_minutes should be 0 if no explicit or strongly implied time cap exists.
- min_calories_kcal and max_calories_kcal should be 0 unless the prompt clearly imposes a calorie range or ceiling.
- servings_hint should capture any explicit serving or sizing constraint in short natural language, or empty string.
- required_ingredients should only contain ingredients or dish anchors that must be present.
- excluded_ingredients should only contain ingredients or dish anchors that must be absent.
- must_include_terms should contain dishes, ingredients, cuisine signals, or meal-shape terms that should be heavily favored.
- avoid_terms should contain ingredients or meal styles the user is clearly excluding from the prompt or profile.
- semantic_expansion_terms should include close variants and cuisine/meal concepts that help semantic retrieval.
- lexical_priority_terms should contain exact words or short phrases worth preserving for hybrid text search.
- occasion_terms should capture use-case framing like meal prep, high protein, comfort food, quick lunch, etc.
- retrieval_prompt should be a compact natural-language retrieval brief optimized for embeddings.
- hybrid_query should be a compact keyword-preserving query optimized for lexical + hybrid retrieval.
- adjudication_notes should explain what the final ranking stage must be strict about.
- Do not invent hard restrictions that were not provided.
- Return only valid JSON matching the schema.`;

const DISCOVER_RESULT_ADJUDICATION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    ordered_recipe_ids: {
      type: "array",
      items: { type: "string" },
      minItems: 0,
      maxItems: 96,
    },
    rationale: {
      type: "string",
    },
  },
  required: [
    "ordered_recipe_ids",
    "rationale",
  ],
};

const DISCOVER_RESULT_ADJUDICATION_SYSTEM_PROMPT = `You are Ounje's final discover/search result adjudicator.

You receive:
- the user's original prompt
- the selected discover filter
- a normalized search intent with hard constraints
- profile context
- a candidate list already retrieved from hybrid semantic search

Your job:
- decide which candidates are actually good enough to show
- drop off-target results, even if they are loosely related
- rank the kept results from best to worst

Rules:
- Respect hard restrictions absolutely: dietary constraints, excluded ingredients, calorie ceilings/floors, time ceilings, and explicit serving/sizing requirements when present.
- Respect explicit format cues absolutely: when the user wants a drink, do not keep plated foods or dessert bars/cakes unless the candidate is clearly a beverage.
- Respect explicit temperature or service-style cues absolutely: hot should not admit iced, frozen, or cold beverages; cold/iced should not admit hot beverages.
- Use common-sense serving temperature and format, not just overlapping flavor words. For example, cocktail-style drinks are usually cold unless the candidate clearly says otherwise.
- Prefer direct semantic fit over vague adjacency.
- It is better to return fewer results than to include obviously wrong ones.
- For broad prompts, keep a healthy spread of strong matches rather than near-duplicates.
- For narrow prompts, keep only recipes that genuinely satisfy the ask.
- Only return IDs that appear in the candidate list.
- Return valid JSON only.`;

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
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          display_name: { type: "string" },
          quantity_text: { type: "string" },
        },
        required: ["display_name", "quantity_text"],
      },
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
    change_summary: { type: "string" },
    edit_summary: {
      type: "object",
      additionalProperties: false,
      properties: {
        changed_ingredients: {
          type: "array",
          maxItems: 12,
          items: { type: "string" },
        },
        changed_quantities: {
          type: "array",
          maxItems: 12,
          items: { type: "string" },
        },
        changed_steps: {
          type: "array",
          maxItems: 12,
          items: { type: "string" },
        },
        added_ingredients: {
          type: "array",
          maxItems: 12,
          items: { type: "string" },
        },
        removed_ingredients: {
          type: "array",
          maxItems: 12,
          items: { type: "string" },
        },
        validation_notes: {
          type: "array",
          maxItems: 12,
          items: { type: "string" },
        },
      },
      required: [
        "changed_ingredients",
        "changed_quantities",
        "changed_steps",
        "added_ingredients",
        "removed_ingredients",
        "validation_notes",
      ],
    },
  },
  required: [
    "title",
    "summary",
    "cook_time_text",
    "ingredients",
    "steps",
    "substitutions",
    "pairing_notes",
    "dietary_fit",
    "change_summary",
    "edit_summary",
  ],
};

const RECIPE_ADAPT_SYSTEM_PROMPT = `You are Ounje's recipe adaptation model.

You take a base recipe, a user profile, and an adaptation goal, then return a revised recipe that still feels like a real recipe someone would cook.

Rules:
- Respect allergies, hard restrictions, and "never include" foods as absolute.
- Keep the core identity of the dish unless the request explicitly asks for a large change.
- Treat the request as a whole-recipe rewrite, not a local text patch.
- Inspect the entire base recipe before changing anything: ingredient list, quantities, units, recipe steps, prep/cook time, servings, nutrition/diet tags, cuisine/flavor tags, title, summary, and downstream grocery implications.
- When changing an ingredient, update all affected quantities, units, steps, timing, tags, and summary so the recipe remains internally consistent.
- When changing a quantity, keep the ingredient line and any step references aligned.
- When changing method or timing, update the steps and cook_time_text together.
- Use the user profile to respect allergies, dislikes, cooking rhythm, budget, household size, and preference context when provided.
- Treat adaptation_contract as binding. Apply every required action, avoid every forbidden ingredient or method, and satisfy the validation hints.
- If repair_context is provided, directly fix every listed validation failure before returning the final recipe.
- If asked to make it quicker, simplify ingredients and shorten steps without making it incoherent.
- If asked to make it spicier, add heat in a cuisine-appropriate way.
- If asked to make it higher-protein, increase protein plausibly.
- If asked to make it vegetarian, remove meat, seafood, gelatin, meat stock, fish sauce, and animal broth from ingredients and steps, then add a satisfying vegetarian protein or plant-forward base.
- If asked to make it dairy-free, remove dairy ingredients and update the texture/fat source with practical substitutions.
- If asked for less sugar, reduce sweetener quantities or replace sugary components, then update steps that rely on sweetness, glazing, caramelization, or dessert texture.
- Use the provided flavor-pairing hints as soft guidance, not mandatory additions.
- Return a concise change_summary and an edit_summary listing what changed across ingredients, quantities, and steps.
- Return only valid JSON matching the schema.
- Do not return an unchanged copy of the base recipe. The title, ingredient list, quantities, and steps should clearly reflect the adaptation goal.
- Ingredients must be practical grocery-list objects with display_name and quantity_text. Every ingredient needs a useful quantity_text; use "to taste" only for seasonings or finishing ingredients where exact amounts would be misleading.
- Steps should be short, concrete, sequential, and updated to reference changed ingredients and quantities where relevant.
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

recipe_router.post("/recipe/share-links", async (req, res) => {
  const recipeId = String(req.body?.recipe_id ?? req.body?.recipeID ?? "").trim();
  const userID = String(req.body?.user_id ?? req.body?.userID ?? "").trim() || null;

  if (!recipeId) {
    return res.status(400).json({ error: "recipe_id is required." });
  }

  try {
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
      return res.status(500).json({ error: "Recipe share links require Supabase configuration." });
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
    const recipeDetail = normalizeRecipeDetail(recipe, {
      recipeIngredients,
      recipeSteps,
      stepIngredients,
    });
    const recipeCard = toRecipeCardPayload(recipeDetail);

    const link = await createOrReuseRecipeShareLink({
      recipeID: recipeId,
      recipeKind: recipeId.startsWith("uir_") ? "user_import" : "public",
      userID,
      snapshot: {
        version: 1,
        recipe_card: recipeCard,
        recipe_detail: recipeDetail,
      },
    });

    return res.status(201).json({
      share_id: link.share_id,
      recipe_id: link.recipe_id,
      url: link.url,
      app_url: link.app_url,
      web_url: link.web_url,
    });
  } catch (error) {
    console.error("[recipe/share-links] create failed:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

recipe_router.get("/recipe/share-links/:shareID", async (req, res) => {
  try {
    const link = await resolveRecipeShareLink(req.params.shareID);
    if (!link) {
      return res.status(404).json({ error: "Recipe share link not found." });
    }
    const snapshot = link.snapshot_json ?? {};
    return res.json({
      share_id: link.share_id,
      recipe_id: link.recipe_id,
      url: link.url,
      app_url: link.app_url,
      web_url: link.web_url,
      recipe_card: snapshot.recipe_card ?? null,
      recipe_detail: snapshot.recipe_detail ?? null,
    });
  } catch (error) {
    console.error("[recipe/share-links] resolve failed:", error.message);
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
      query_embedding: toPgVector(embedding),
      match_count: 32,
    });

    const candidateIDs = [...new Set(
      (semanticMatches ?? [])
        .map((match) => String(match?.id ?? "").trim())
        .filter((id) => id && id !== recipeId)
    )];

    if (!candidateIDs.length) {
      const fallback = await fallbackSimilarRecipeCards({ detail, recipeId, limit });
      return res.json({ recipes: fallback, rankingMode: "similar_fallback_contextual_empty_semantic" });
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

    const recipePayloads = curatedRecipes.map(({ recipe: candidate }) => toRecipeCardPayload(candidate));
    if (!recipePayloads.length) {
      const fallback = await fallbackSimilarRecipeCards({ detail, recipeId, limit });
      return res.json({ recipes: fallback, rankingMode: "similar_fallback_contextual_empty_curation" });
    }

    return res.json({
      recipes: recipePayloads,
      rankingMode: "similar_semantic_flavorgraph",
    });
  } catch (error) {
    console.error("[recipe/detail/similar] failed:", error.message);
    try {
      const fallback = await fetchLatestRecipes(Math.max(limit + 1, 12));
      return res.json({
        recipes: fallback
          .filter((recipe) => String(recipe.id) !== recipeId)
          .slice(0, limit)
          .map(toRecipeCardPayload),
        rankingMode: "similar_fallback_latest_after_error",
      });
    } catch {
      return res.status(500).json({ error: error.message });
    }
  }
});

recipe_router.post("/recipe/similar", async (req, res) => {
  const requestedLimit = Number.parseInt(String(req.body?.limit ?? req.query.limit ?? "5"), 10);
  const limit = Number.isFinite(requestedLimit)
    ? Math.max(3, Math.min(requestedLimit, 8))
    : 5;
  const detail = normalizeSimilarRecipeInput(req.body?.recipe ?? req.body ?? {});
  const recipeId = String(detail.id ?? "").trim();

  if (!String(detail.title ?? "").trim()) {
    return res.status(400).json({ error: "Provide recipe title or detail context." });
  }

  try {
    const recipes = await fallbackSimilarRecipeCards({ detail, recipeId, limit });
    return res.json({ recipes, rankingMode: "similar_fallback_contextual_detail" });
  } catch (error) {
    console.error("[recipe/similar] fallback failed:", error.message);
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
  const {
    profile = null,
    filter = "All",
    query = "",
    limit = 30,
    offset = 0,
    feedContext = null,
  } = req.body ?? {};
  const trimmedQuery = String(query ?? "").trim();
  const normalizedFilter = String(filter ?? "All").trim().toLowerCase();
  const isBaseDiscover = normalizedFilter === "all";
  const requestedLimit = Number.isFinite(Number(limit)) ? Math.max(1, Number(limit)) : 30;
  const requestedOffset = Number.isFinite(Number(offset)) ? Math.max(0, Number(offset)) : 0;
  const requestedWindowLimit = Math.max(requestedLimit + requestedOffset, requestedLimit);

  try {
    if (trimmedQuery) {
      const searchCacheKey = buildDiscoverSearchCacheKey({
        query: trimmedQuery,
        filter,
        limit: requestedLimit,
        offset: requestedOffset,
        profile,
      });
      const cachedPayload = readTimedCache(searchResponseCache, searchCacheKey, SEARCH_RESPONSE_CACHE_TTL_MS);
      if (cachedPayload) {
        return res.json(cachedPayload);
      }
    }

    if (!trimmedQuery) {
      const feedCacheKey = buildDiscoverFeedCacheKey({
        profile,
        filter,
        feedContext,
        limit: requestedLimit,
        offset: requestedOffset,
      });
      const cachedPayload = readTimedCache(discoverFeedCache, feedCacheKey, DISCOVER_FEED_CACHE_TTL_MS);
      if (cachedPayload) {
        return res.json(cachedPayload);
      }

      const { recipes, rankingMode } = isBaseDiscover
        ? await buildBaseDiscoverRecipes({
            profile,
            filter,
            feedContext,
            limit: requestedWindowLimit,
          })
        : await buildPresetDiscoverRecipes({
            profile,
            filter,
            feedContext,
            limit: requestedWindowLimit,
          });

      const payload = pageDiscoverResults({
        recipes,
        filters: deriveDiscoverFilters(recipes),
        rankingMode,
      }, requestedOffset, requestedLimit);
      discoverFeedCache.set(feedCacheKey, { value: payload, createdAt: Date.now() });
      return res.json(payload);
    }

    if (!openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
      return res.status(503).json({
        error: "Semantic discover dependencies are unavailable.",
        rankingMode: "semantic_unavailable",
      });
    }

    const llmIntent = await inferDiscoverIntentWithLLM({ profile, filter, query: trimmedQuery });
    const {
      filterType,
      semanticQuery,
      lexicalQuery,
      richSearchText,
      maxCookMinutes,
      parsedQuery,
    } = buildDiscoverQueryContext({ profile, filter, query: trimmedQuery, llmIntent });

    const candidateLimit = Math.max(requestedWindowLimit * 3, 60);

    if (trimmedQuery.length <= 80) {
      console.log(
        `[recipe/discover] query="${trimmedQuery}" filter="${filter}" resolvedFilter="${filterType ?? "null"}" maxCookMinutes="${maxCookMinutes ?? "null"}" maxCalories="${parsedQuery?.maxCaloriesKcal ?? "null"}" exactPhrase="${parsedQuery?.exactPhrase ?? "null"}" lexicalQuery="${lexicalQuery}" retrievalPrompt="${llmIntent?.retrievalPrompt ?? parsedQuery?.semanticQuery ?? ""}" intent="${llmIntent?.userIntent ?? "heuristic"}"`
      );
    }

    const [hybridEmbedding, richEmbedding] = await Promise.all([
      embedTextCached(semanticQuery, "text-embedding-3-small"),
      embedTextCached(richSearchText, "text-embedding-3-large"),
    ]);

    const lexicalAnchorPromise = fetchLexicalAnchorRecipes({
      query: trimmedQuery,
      parsedQuery,
      limit: Math.max(requestedWindowLimit, 24),
    }).catch((error) => {
      console.warn("[recipe/discover] lexical anchors failed:", error.message);
      return [];
    });

    const basicMatchesPromise = withTimeout(callRecipeRpc("match_recipes_basic", {
      query_embedding: toPgVector(hybridEmbedding),
      match_count: Math.max(requestedWindowLimit * 8, 80),
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
          match_count: Math.max(requestedWindowLimit * 4, 48),
          filter_type: filterType,
          max_cook_minutes: maxCookMinutes,
        }), 3000, "hybrid rpc timed out").catch((error) => {
          console.warn("[recipe/discover] hybrid rpc failed:", error.message);
          return [];
        })
      : Promise.resolve([]);

    const richMatchesPromise = !Array.isArray(richEmbedding) || richEmbedding.length === 0
      ? Promise.resolve([])
      : withTimeout(callRecipeRpc("match_recipes_rich", {
          query_embedding: toPgVector(richEmbedding),
          match_count: Math.max(requestedWindowLimit * 2, 20),
          filter_type: filterType,
          max_cook_minutes: maxCookMinutes,
        }), 2200, "rich rpc timed out").catch((error) => {
          console.warn("[recipe/discover] rich rpc failed:", error.message);
          return [];
        });

    const [basicMatches, hybridMatches, richMatches, lexicalAnchorRecipes] = await Promise.all([
      basicMatchesPromise,
      hybridMatchesPromise,
      richMatchesPromise,
      lexicalAnchorPromise,
    ]);

    const rankedIds = fuseRankedIds([basicMatches, hybridMatches, richMatches], candidateLimit);
    let recipes = rankedIds.length > 0
      ? await fetchSearchRecipesByIds(rankedIds)
      : [];

    recipes = dedupeRecipesById([
      ...lexicalAnchorRecipes,
      ...recipes,
    ]);

    recipes = applySearchFilterGate(recipes, parsedQuery, filter);
    recipes = applyIntentHardConstraints(recipes, parsedQuery);
    recipes = applyPresetHardConstraints(recipes, filter);
    recipes = rerankSearchResults(recipes, parsedQuery, candidateLimit, profile);
    recipes = diversifyDiscoverRecipes({
      recipes,
      profile,
      filter,
      query: trimmedQuery,
      parsedQuery,
      feedContext,
      limit: requestedWindowLimit,
    });
    recipes = dedupeRecipesById([
      ...lexicalAnchorRecipes,
      ...recipes,
    ]).slice(0, requestedWindowLimit);
    const preAdjudicationRecipes = recipes;

    recipes = await adjudicateDiscoverSearchResultsWithLLM({
      recipes,
      profile,
      filter,
      query: trimmedQuery,
      parsedQuery,
      llmIntent,
      limit: requestedLimit,
      offset: requestedOffset,
    });
    recipes = completeSearchResultsFromCandidatePool({
      selectedRecipes: recipes,
      candidateRecipes: preAdjudicationRecipes,
      query: trimmedQuery,
      parsedQuery,
      limit: requestedWindowLimit,
    });
    recipes = applyPresetHardConstraints(recipes, filter);

    if (recipes.length === 0) {
      const fallbackPayload = await buildLexicalSearchFallbackPayload({
        query: trimmedQuery,
        profile,
        filter,
        feedContext,
        requestedLimit,
        requestedOffset,
        requestedWindowLimit,
      });
      searchResponseCache.set(
        buildDiscoverSearchCacheKey({
          query: trimmedQuery,
          filter,
          limit: requestedLimit,
          offset: requestedOffset,
          profile,
        }),
        { value: fallbackPayload, createdAt: Date.now() }
      );
      return res.json(fallbackPayload);
    }

    const payload = pageDiscoverResults({
      recipes,
      filters: deriveSearchFilters(recipes),
      rankingMode: lexicalAnchorRecipes.length
        ? "hybrid_search_embeddings_lexical_anchors_llm_adjudicated"
        : "hybrid_search_embeddings_llm_adjudicated",
    }, requestedOffset, requestedLimit);
    searchResponseCache.set(
      buildDiscoverSearchCacheKey({
        query: trimmedQuery,
        filter,
        limit: requestedLimit,
        offset: requestedOffset,
        profile,
      }),
      { value: payload, createdAt: Date.now() }
    );
    return res.json(payload);
  } catch (error) {
    console.error("[recipe/discover] ranking failed:", error.message);

    try {
      if (trimmedQuery) {
        const payload = await buildLexicalSearchFallbackPayload({
          query: trimmedQuery,
          profile,
          filter,
          feedContext,
          requestedLimit,
          requestedOffset,
          requestedWindowLimit,
        });
        return res.json(payload);
      }

      const recipes = isBaseDiscover
        ? await fetchRandomDiscoverRecipes({
            limit: requestedWindowLimit,
            seed: `${feedContext?.sessionSeed ?? "discover"}|fallback|${feedContext?.windowKey ?? "now"}|${String(filter ?? "All").toLowerCase()}`,
            filter,
          })
        : applyPresetCategoryGate(
            await fetchRandomDiscoverRecipes({
              limit: Math.max(requestedWindowLimit * 2, 72),
              seed: `${feedContext?.sessionSeed ?? "discover"}|fallback-preset|${feedContext?.windowKey ?? "now"}|${String(filter ?? "All").toLowerCase()}`,
              filter,
            }),
            filter
          ).slice(0, requestedWindowLimit);
      return res.json(pageDiscoverResults({
        recipes,
        filters: deriveDiscoverFilters(recipes),
        rankingMode: isBaseDiscover ? "fallback_latest" : "fallback_latest_preset_gate",
      }, requestedOffset, requestedLimit));
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
    saved_recipe_titles: savedRecipeTitles = [],
    recurring_recipe_ids: recurringRecipeIds = [],
    recurring_recipe_titles: recurringRecipeTitles = [],
    fast_regeneration: fastRegenerationRaw = false,
    regeneration_context: regenerationContextRaw = null,
  } = req.body ?? {};
  const regenerationContext = normalizePrepRegenerationContext(regenerationContextRaw);
  const fastRegeneration = Boolean(regenerationContext && fastRegenerationRaw);
  const normalizedSavedRecipeIDs = uniqueStrings(Array.isArray(savedRecipeIds) ? savedRecipeIds : []);
  const normalizedSavedRecipeTitles = uniqueStrings(Array.isArray(savedRecipeTitles) ? savedRecipeTitles : []);
  const normalizedRecurringRecipeIDs = uniqueStrings(Array.isArray(recurringRecipeIds) ? recurringRecipeIds : []);
  const normalizedRecurringRecipeTitles = uniqueStrings(Array.isArray(recurringRecipeTitles) ? recurringRecipeTitles : []);

  try {
    const rankedPayload = await buildBaseDiscoverRecipes({
      profile,
      filter: "All",
      feedContext,
      limit: Math.max(limit, 72),
    });

    let recipes = filterRecipesByAllergies(rankedPayload.recipes, profile);
    let regenerationIntent = null;
    let prepFocusSearchRecipes = [];
    let savedAnchorRecipes = [];
    let savedAnchorBoostRecipes = [];
    let recurringAnchorRecipes = [];
    let recurringAnchorBoostRecipes = [];

    if (normalizedSavedRecipeIDs.length) {
      try {
        const savedAnchorRecipeIDs = normalizedSavedRecipeIDs.slice(0, 24);
        const publicRecipeIDs = savedAnchorRecipeIDs.filter(isUUIDLike);
        const importedRecipeIDs = savedAnchorRecipeIDs.filter((recipeID) => String(recipeID).trim().startsWith("uir_"));
        const [publicRecipes, importedRecipes] = await Promise.all([
          publicRecipeIDs.length ? fetchRecipesByIds(publicRecipeIDs) : Promise.resolve([]),
          importedRecipeIDs.length
            ? Promise.all(importedRecipeIDs.map((recipeID) => fetchRecipeById(recipeID).catch(() => null)))
            : Promise.resolve([]),
        ]);

        savedAnchorRecipes = dedupeRecipesById([
          ...publicRecipes,
          ...importedRecipes.filter(Boolean),
        ]);
        if (savedAnchorRecipes.length && openai && SUPABASE_URL && SUPABASE_ANON_KEY) {
          const savedBoostPool = await buildPrepRegenerationBoostPool({
            profile,
            regenerationContext: {
              focus: regenerationContext?.focus ?? "closerToFavorites",
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

    if (normalizedRecurringRecipeIDs.length) {
      try {
        const recurringAnchorRecipeIDs = normalizedRecurringRecipeIDs.slice(0, 18);
        const publicRecipeIDs = recurringAnchorRecipeIDs.filter(isUUIDLike);
        const importedRecipeIDs = recurringAnchorRecipeIDs.filter((recipeID) => String(recipeID).trim().startsWith("uir_"));
        const [publicRecipes, importedRecipes] = await Promise.all([
          publicRecipeIDs.length ? fetchRecipesByIds(publicRecipeIDs) : Promise.resolve([]),
          importedRecipeIDs.length
            ? Promise.all(importedRecipeIDs.map((recipeID) => fetchRecipeById(recipeID).catch(() => null)))
            : Promise.resolve([]),
        ]);

        recurringAnchorRecipes = dedupeRecipesById([
          ...publicRecipes,
          ...importedRecipes.filter(Boolean),
        ]);
        if (recurringAnchorRecipes.length && openai && SUPABASE_URL && SUPABASE_ANON_KEY) {
          const recurringBoostPool = await buildPrepRegenerationBoostPool({
            profile,
            regenerationContext: {
              focus: regenerationContext?.focus ?? "closerToFavorites",
              currentRecipeIDs: recurringAnchorRecipes.map((recipe) => recipe.id),
              currentRecipes: recurringAnchorRecipes,
              userPrompt: [
                regenerationContext?.userPrompt ?? null,
                normalizedRecurringRecipeTitles.length
                  ? `Keep recurring anchors like ${normalizedRecurringRecipeTitles.slice(0, 6).join(", ")} in the next prep cycle.`
                  : null,
              ].filter(Boolean).join(" "),
            },
            limit: Math.max(limit * 2, 48),
          });
          recurringAnchorBoostRecipes = recurringBoostPool.recipes ?? [];
          regenerationIntent = regenerationIntent ?? recurringBoostPool.intent ?? null;
        }
      } catch (error) {
        console.warn("[recipe/prep-candidates] recurring-anchor boost failed:", error.message);
      }
    }

    if (regenerationContext && !fastRegeneration) {
      const syntheticSearchQuery = buildPrepFocusSearchQuery({
        profile,
        regenerationContext,
        savedRecipeTitles: normalizedSavedRecipeTitles,
        recurringRecipeTitles: normalizedRecurringRecipeTitles,
      });
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

    if (regenerationContext && fastRegeneration) {
      regenerationIntent = fallbackPrepRegenerationIntent(regenerationContext);
      recipes = dedupeRecipesById([
        ...recurringAnchorRecipes,
        ...recurringAnchorBoostRecipes,
        ...savedAnchorRecipes,
        ...savedAnchorBoostRecipes,
        ...recipes,
      ]);
    } else if (regenerationContext && openai && SUPABASE_URL && SUPABASE_ANON_KEY) {
      const regenPool = await buildPrepRegenerationBoostPool({
        profile,
        regenerationContext,
        limit: Math.max(limit * 2, 48),
      });
      regenerationIntent = regenPool.intent;
      recipes = dedupeRecipesById([
        ...recurringAnchorRecipes,
        ...recurringAnchorBoostRecipes,
        ...savedAnchorRecipes,
        ...savedAnchorBoostRecipes,
        ...prepFocusSearchRecipes,
        ...regenPool.recipes,
        ...recipes,
      ]);
    } else {
      recipes = dedupeRecipesById([
        ...recurringAnchorRecipes,
        ...recurringAnchorBoostRecipes,
        ...savedAnchorRecipes,
        ...savedAnchorBoostRecipes,
        ...prepFocusSearchRecipes,
        ...recipes,
      ]);
    }

    recipes = avoidCurrentPrepRecipesForReroll(
      recipes,
      regenerationContext,
      normalizedRecurringRecipeIDs,
      Math.max(Number(regenerationContext?.targetRecipeCount ?? 0) + 8, 18)
    );
    recipes = deprioritizeHistoricalRecipes(recipes, historyRecipeIds);
    recipes = rerankPrepCandidateRecipes(recipes, profile, regenerationContext, regenerationIntent);

    if (!fastRegeneration && openai && recipes.length > 1) {
      const preCurationRecipes = recipes;
      const curatedRecipes = await curateDiscoverRecipesWithLLM({
        recipes,
        profile,
        filter: "All",
        query: buildPrepCandidateCurationQuery(profile, regenerationContext, regenerationIntent, {
          savedRecipeTitles: normalizedSavedRecipeTitles,
          recurringRecipeTitles: normalizedRecurringRecipeTitles,
        }),
        parsedQuery: null,
        feedContext,
        limit: recipes.length,
      });
      recipes = curatedRecipes.length > 0 ? curatedRecipes : preCurationRecipes;
    }

    const normalizationPool = recipes.slice(0, Math.max(limit * 2, limit + 48));
    const hydratedNormalizationPool = await hydrateRecipesWithIngredientRows(normalizationPool);
    let normalized = hydratedNormalizationPool
      .map(normalizePrepCandidateRecipe)
      .filter((recipe) => Array.isArray(recipe.ingredients) && recipe.ingredients.length >= 3)
      .slice(0, limit);

    if (normalized.length === 0) {
      const fallbackPool = await hydrateRecipesWithIngredientRows(await fetchLatestRecipes(Math.max(limit * 4, 48)));
      normalized = fallbackPool
        .map(normalizePrepCandidateRecipe)
        .filter((recipe) => Array.isArray(recipe.ingredients) && recipe.ingredients.length >= 3)
        .slice(0, limit);
    }

    const rankingMode = [
      `${rankedPayload.rankingMode}_prep_candidates`,
      regenerationContext ? `focus_${regenerationContext.focus}` : null,
      normalizedSavedRecipeIDs.length ? "saved_anchors" : null,
      normalizedRecurringRecipeIDs.length ? "recurring_anchors" : null,
      prepFocusSearchRecipes.length ? "focus_search" : null,
      fastRegeneration ? "fast_regen" : null,
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
      const fallbackPool = await hydrateRecipesWithIngredientRows(await fetchLatestRecipes(Math.max(limit, 48)));
      const fallback = fallbackPool
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

function buildPrepFocusSearchQuery({
  profile = null,
  regenerationContext = null,
  savedRecipeTitles = [],
  recurringRecipeTitles = [],
}) {
  if (!regenerationContext) return "";

  const focus = String(regenerationContext.focus ?? "balanced");
  const preferredCuisines = uniqueStrings((profile?.preferredCuisines ?? []).map(formatPreferenceToken));
  const favoriteFoods = uniqueStrings((profile?.favoriteFoods ?? []).map((value) => String(value ?? "").trim()));
  const favoriteFlavors = uniqueStrings((profile?.favoriteFlavors ?? []).map((value) => String(value ?? "").trim()));
  const currentRecipeTitles = uniqueStrings((regenerationContext.currentRecipes ?? []).map((recipe) => recipe?.title));
  const normalizedSavedRecipeTitles = uniqueStrings(savedRecipeTitles);
  const normalizedRecurringRecipeTitles = uniqueStrings(recurringRecipeTitles);
  const userPrompt = String(regenerationContext.userPrompt ?? "").trim();
  const seed = `${focus}|${preferredCuisines.join(",")}|${currentRecipeTitles.join(",")}`;
  const explorationCuisine = pickExplorationCuisine(preferredCuisines, seed);

  const queryByFocus = {
    balanced: [
      "What would I like for next meal prep?",
      preferredCuisines.length ? `Lean toward cuisines like ${preferredCuisines.join(", ")}.` : null,
      favoriteFoods.length ? `Include flavors around ${favoriteFoods.slice(0, 5).join(", ")}.` : null,
      normalizedSavedRecipeTitles.length ? `Use saved meals like ${normalizedSavedRecipeTitles.slice(0, 5).join(", ")} as taste anchors.` : null,
      normalizedRecurringRecipeTitles.length ? `Keep recurring staples like ${normalizedRecurringRecipeTitles.slice(0, 4).join(", ")} in the lane.` : null,
      "Keep broad appeal and high cookability.",
    ],
    closerToFavorites: [
      "Build the next prep around my taste.",
      preferredCuisines.length ? `Mostly my cuisines: ${preferredCuisines.join(", ")}.` : null,
      favoriteFoods.length ? `Stay close to foods I love: ${favoriteFoods.slice(0, 6).join(", ")}.` : null,
      favoriteFlavors.length ? `Flavor lane: ${favoriteFlavors.slice(0, 4).join(", ")}.` : null,
      normalizedSavedRecipeTitles.length ? `Pull harder from saved hits like ${normalizedSavedRecipeTitles.slice(0, 5).join(", ")}.` : null,
      normalizedRecurringRecipeTitles.length ? `Keep recurring meals like ${normalizedRecurringRecipeTitles.slice(0, 4).join(", ")} locked in.` : null,
      "Meal prep friendly, familiar, and repeatable.",
    ],
    moreVariety: [
      "Give me imaginative meal prep ideas with mass appeal.",
      preferredCuisines.length ? `Go outside my usual cuisines (${preferredCuisines.join(", ")}) while staying craveable.` : null,
      explorationCuisine ? `Push toward something like ${explorationCuisine} or similarly distinct cuisines.` : null,
      normalizedSavedRecipeTitles.length ? `Still feel adjacent to saved meals like ${normalizedSavedRecipeTitles.slice(0, 4).join(", ")}.` : null,
      "Avoid boring repeats from my current prep.",
    ],
    lessPrepTime: [
      "Quick meal prep ideas under 30 minutes.",
      preferredCuisines.length ? `Still aligned with ${preferredCuisines.join(", ")}.` : null,
      normalizedRecurringRecipeTitles.length ? `Preserve the convenience profile of recurring meals like ${normalizedRecurringRecipeTitles.slice(0, 4).join(", ")}.` : null,
      "Simple ingredient lists and low effort execution.",
    ],
    tighterOverlap: [
      "Meal prep ideas with strong ingredient overlap.",
      preferredCuisines.length ? `Cuisine lane: ${preferredCuisines.join(", ")}.` : null,
      normalizedRecurringRecipeTitles.length ? `Keep recurring staples like ${normalizedRecurringRecipeTitles.slice(0, 4).join(", ")} in play.` : null,
      "Optimize for shared proteins, produce, and pantry staples across multiple meals.",
    ],
    savedRecipeRefresh: [
      "Build the next prep around my taste.",
      preferredCuisines.length ? `Anchor in ${preferredCuisines.join(", ")}.` : null,
      favoriteFoods.length ? `Stay close to foods I love: ${favoriteFoods.slice(0, 5).join(", ")}.` : null,
      normalizedSavedRecipeTitles.length ? `Pull harder from saved hits like ${normalizedSavedRecipeTitles.slice(0, 6).join(", ")}.` : null,
      normalizedRecurringRecipeTitles.length ? `Recurring anchors to protect: ${normalizedRecurringRecipeTitles.slice(0, 4).join(", ")}.` : null,
      "Comfortable, familiar, and meal-prep ready.",
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

  if (!openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    throw new Error("Semantic discover dependencies are unavailable.");
  }
  const llmIntent = await inferDiscoverIntentWithLLM({ profile, filter, query: trimmedQuery });
  const {
    filterType,
    semanticQuery,
    lexicalQuery,
    richSearchText,
    maxCookMinutes,
    parsedQuery,
  } = buildDiscoverQueryContext({ profile, filter, query: trimmedQuery, llmIntent });

  const candidateLimit = Math.max(limit * 2, 36);
  const hybridEmbeddingPromise = embedTextCached(semanticQuery, "text-embedding-3-small");
  const richEmbeddingPromise = embedTextCached(richSearchText, "text-embedding-3-large");

  const [hybridEmbedding, richEmbedding] = await Promise.all([
    hybridEmbeddingPromise,
    richEmbeddingPromise,
  ]);

  const lexicalAnchorPromise = fetchLexicalAnchorRecipes({
    query: trimmedQuery,
    parsedQuery,
    limit: Math.max(limit, 24),
  }).catch((error) => {
    console.warn("[recipe/prep-candidates] focus-search lexical anchors failed:", error.message);
    return [];
  });

  const basicMatchesPromise = withTimeout(callRecipeRpc("match_recipes_basic", {
    query_embedding: toPgVector(hybridEmbedding),
    match_count: Math.max(limit * 4, 48),
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
          match_count: Math.max(limit * 2, 24),
          filter_type: filterType,
          max_cook_minutes: maxCookMinutes,
        }), 3000, "hybrid rpc timed out").catch((error) => {
        console.warn("[recipe/prep-candidates] focus-search hybrid rpc failed:", error.message);
        return [];
      })
    : Promise.resolve([]);

    const richMatchesPromise = !Array.isArray(richEmbedding) || richEmbedding.length === 0
      ? Promise.resolve([])
      : withTimeout(callRecipeRpc("match_recipes_rich", {
          query_embedding: toPgVector(richEmbedding),
          match_count: Math.max(limit, 12),
          filter_type: filterType,
          max_cook_minutes: maxCookMinutes,
        }), 2200, "rich rpc timed out").catch((error) => {
        console.warn("[recipe/prep-candidates] focus-search rich rpc failed:", error.message);
        return [];
      });

  const [basicMatches, hybridMatches, richMatches, lexicalAnchorRecipes] = await Promise.all([
    basicMatchesPromise,
    hybridMatchesPromise,
    richMatchesPromise,
    lexicalAnchorPromise,
  ]);

  const rankedIds = fuseRankedIds([basicMatches, hybridMatches, richMatches], candidateLimit);
  let recipes = rankedIds.length > 0
    ? await fetchSearchRecipesByIds(rankedIds)
    : [];

  recipes = dedupeRecipesById([
    ...lexicalAnchorRecipes,
    ...recipes,
  ]);

  recipes = applySearchFilterGate(recipes, parsedQuery, filter);
  recipes = applyIntentHardConstraints(recipes, parsedQuery);
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
  recipes = dedupeRecipesById([
    ...lexicalAnchorRecipes,
    ...recipes,
  ]).slice(0, limit);
  recipes = await adjudicateDiscoverSearchResultsWithLLM({
    recipes,
    profile,
    filter,
    query: trimmedQuery,
    parsedQuery,
    llmIntent,
    limit,
    offset: 0,
  });

  recipes = applyPresetHardConstraints(recipes, filter);

  return {
    recipes,
    rankingMode: "prep_focus_hybrid_semantic_llm_adjudicated",
  };
}

async function buildBaseDiscoverRecipes({
  profile = null,
  filter = "All",
  feedContext = null,
  limit = 360,
}) {
  const normalizedFilter = String(filter ?? "All").trim().toLowerCase();
  const minimumPoolTarget = normalizedFilter === "all" ? 360 : 240;
  const target = Math.max(limit, minimumPoolTarget);
  const baseSeed = `${feedContext?.sessionSeed ?? "base"}|${feedContext?.windowKey ?? "now"}|${String(filter ?? "All").toLowerCase()}|${target}`;

  const sharedPool = await fetchDiscoverBroadPool({
    profile,
    filter,
    feedContext,
    seed: baseSeed,
    limit: Math.max(target * 2, 150),
  });

  const randomRecipes = rankPresetFocusedRecipes(sharedPool, {
    filter,
    seed: `${baseSeed}|random`,
  });
  const cueRecipes = rankCueDrivenRecipes(sharedPool, {
    filter,
    feedContext,
    seed: `${baseSeed}|cue`,
  });
  const profileRecipes = rankProfileDrivenRecipes(filterRecipesByAllergies(sharedPool, profile), {
    filter,
    profile,
    seed: `${baseSeed}|profile`,
  });

  let recipes = composeBaseDiscoverFeed({
    randomRecipes: applyPresetHardConstraints(randomRecipes, filter),
    cueRecipes: applyPresetHardConstraints(cueRecipes, filter),
    profileRecipes: applyPresetHardConstraints(profileRecipes, filter),
    limit: target,
    seed: baseSeed,
  });

  if (String(filter ?? "All").trim().toLowerCase() !== "all") {
    recipes = frontloadPresetRecipes(recipes, filter, target);
  }

  if (recipes.length < target) {
    const fallbackRandom = await fetchDiscoverBroadPool({
      profile,
      filter,
      feedContext,
      seed: `${baseSeed}|fallback`,
      limit: Math.max(target, 180),
    }).catch((error) => {
      console.warn("[recipe/discover] base fallback pool failed:", error.message);
      return [];
    });
    const fallbackPool = applyPresetHardConstraints(
      dedupeRecipesById([
        ...randomRecipes,
        ...cueRecipes,
        ...profileRecipes,
        ...fallbackRandom,
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
  limit = 240,
}) {
  const normalizedFilter = String(filter ?? "All").trim().toLowerCase();
  if (normalizedFilter === "all") {
    return buildBaseDiscoverRecipes({ profile, filter, feedContext, limit: Math.max(limit, 360) });
  }

  const target = Math.max(limit, 240);
  const seedRoot = `${feedContext?.sessionSeed ?? "preset"}|${feedContext?.windowKey ?? "now"}|${normalizedFilter}`;

  const presetPool = await fetchPresetBracketRecipes({
    filter,
    limit: Math.max(target * 2, 180),
    seed: `${seedRoot}|pool`,
  }).catch((error) => {
    console.warn("[recipe/discover] preset pool failed:", error.message);
    return [];
  });
  const presetLatestFallback = await fetchLatestRecipes(Math.max(target, 180)).catch((error) => {
    console.warn("[recipe/discover] preset latest fallback failed:", error.message);
    return [];
  });
  const fallbackWidePool = dedupeRecipesById(
    applyPresetCategoryGate(
      applyPresetHardConstraints(
        [
          ...presetPool,
          ...presetLatestFallback,
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
    recipes: ranked.slice(0, target),
    rankingMode: "preset_bracket_shelf_rotating",
  };
}

function composeBaseDiscoverFeed({
  randomRecipes,
  cueRecipes,
  profileRecipes,
  limit = 20,
  seed = "base-compose",
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

  return stableShuffle(composed, `${seed}|shuffled`).slice(0, target);
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

async function fetchRecipeDetailForAdaptation(recipeId, fallbackRecipe = null) {
  const baseRecipe = fallbackRecipe ?? (recipeId ? await fetchRecipeById(recipeId) : null);
  if (!baseRecipe) return null;

  const normalizedID = String(baseRecipe.id ?? recipeId ?? "").trim();
  const [recipeIngredients, recipeSteps] = normalizedID
    ? await Promise.all([
        fetchRecipeIngredientRows(normalizedID),
        fetchRecipeStepRows(normalizedID),
      ])
    : [[], []];
  const stepIngredients = recipeSteps.length
    ? await fetchRecipeStepIngredientRows(recipeSteps.map((step) => step.id))
    : [];

  return canonicalizeRecipeDetail(baseRecipe, {
    recipeIngredients,
    recipeSteps,
    stepIngredients,
  });
}

function adaptedIngredientRows(lines = []) {
  return parseIngredientObjects(lines)
    .filter(Boolean)
    .map((ingredient, index) => ({
      display_name: ingredient.display_name ?? ingredient.name,
      quantity_text: ingredient.quantity_text ?? ([ingredient.quantity != null ? String(ingredient.quantity) : null, ingredient.unit].filter(Boolean).join(" ").trim() || null),
      image_url: null,
      sort_order: index + 1,
    }))
    .filter((ingredient) => ingredient.display_name);
}

function buildAdaptedRecipeCandidate({
  baseDetail,
  adaptedRecipe,
  adaptationPrompt,
  adaptationContract = null,
  validationStatus = "passed",
  computedEditSummary = null,
  validationFailures = [],
  intentKey = "",
  intentLabel = "",
  rerollNonce = "",
}) {
  const ingredients = adaptedIngredientRows(adaptedRecipe.ingredients);
  const steps = parseStructuredInstructionSteps(adaptedRecipe.steps ?? [], ingredients).map((step, index) => ({
    number: step.number ?? index + 1,
    text: step.text,
    tip_text: step.tip_text ?? null,
    ingredients: step.ingredients ?? [],
  }));
  const cookMinutes = parseFirstInteger(adaptedRecipe.cook_time_text) ?? baseDetail.cook_time_minutes ?? null;

  return {
    title: String(adaptedRecipe.title ?? baseDetail.title ?? "").trim(),
    description: String(adaptedRecipe.summary ?? baseDetail.description ?? "").trim() || null,
    author_name: "Ounje",
    author_handle: null,
    author_url: null,
    source: "Ounje adaptation",
    source_platform: "Ounje",
    category: baseDetail.category ?? null,
    subcategory: baseDetail.subcategory ?? null,
    recipe_type: baseDetail.recipe_type ?? null,
    skill_level: baseDetail.skill_level ?? null,
    cook_time_text: String(adaptedRecipe.cook_time_text ?? baseDetail.cook_time_text ?? "").trim() || null,
    servings_text: baseDetail.servings_text ?? null,
    serving_size_text: baseDetail.serving_size_text ?? null,
    daily_diet_text: baseDetail.daily_diet_text ?? null,
    est_cost_text: baseDetail.est_cost_text ?? null,
    est_calories_text: baseDetail.est_calories_text ?? null,
    carbs_text: baseDetail.carbs_text ?? null,
    protein_text: baseDetail.protein_text ?? null,
    fats_text: baseDetail.fats_text ?? null,
    calories_kcal: baseDetail.calories_kcal ?? null,
    protein_g: baseDetail.protein_g ?? null,
    carbs_g: baseDetail.carbs_g ?? null,
    fat_g: baseDetail.fat_g ?? null,
    prep_time_minutes: baseDetail.prep_time_minutes ?? null,
    cook_time_minutes: cookMinutes,
    hero_image_url: baseDetail.hero_image_url ?? baseDetail.discover_card_image_url ?? null,
    discover_card_image_url: baseDetail.discover_card_image_url ?? baseDetail.hero_image_url ?? null,
    recipe_url: null,
    original_recipe_url: baseDetail.original_recipe_url ?? baseDetail.recipe_url ?? null,
    attached_video_url: baseDetail.attached_video_url ?? null,
    detail_footnote: `Adapted from ${baseDetail.title}.`,
    image_caption: baseDetail.image_caption ?? null,
    dietary_tags: uniqueStrings([
      ...(Array.isArray(baseDetail.dietary_tags) ? baseDetail.dietary_tags : []),
      ...(Array.isArray(adaptedRecipe.dietary_fit) ? adaptedRecipe.dietary_fit : []),
      adaptationContract?.key === "vegetarian" ? "vegetarian" : null,
      adaptationContract?.key === "dairy_free" ? "dairy-free" : null,
      adaptationContract?.key === "low_carb" ? "low-carb" : null,
    ], 12),
    flavor_tags: Array.isArray(baseDetail.flavor_tags) ? baseDetail.flavor_tags : [],
    cuisine_tags: Array.isArray(baseDetail.cuisine_tags) ? baseDetail.cuisine_tags : [],
    occasion_tags: Array.isArray(baseDetail.occasion_tags) ? baseDetail.occasion_tags : [],
    main_protein: baseDetail.main_protein ?? null,
    cook_method: baseDetail.cook_method ?? null,
    ingredients,
    steps,
    servings_count: baseDetail.servings_count ?? parseFirstInteger(baseDetail.servings_text) ?? 4,
    source_provenance_json: {
      kind: "recipe_adaptation",
      adapted_from_recipe_id: baseDetail.id,
      adapted_from_title: baseDetail.title ?? null,
      adaptation_prompt: adaptationPrompt,
      intent_key: intentKey || adaptationContract?.key || null,
      intent_label: intentLabel || adaptationContract?.label || null,
      reroll_nonce: rerollNonce || null,
      adaptation_contract: adaptationContract,
      validation_status: validationStatus,
      validation_failures: validationFailures,
      chat_messages: [
        {
          role: "user",
          content: adaptationPrompt,
        },
        {
          role: "assistant",
          content: adaptedRecipe?.change_summary || adaptedRecipe?.summary || adaptedRecipe?.title || "Recipe rewritten for preview.",
        },
      ],
      edit_summary: mergeEditSummaries(adaptedRecipe?.edit_summary ?? {}, computedEditSummary ?? {}),
    },
  };
}

function adaptationDedupeKey({ userID, recipeID, prompt, rerollNonce = "" }) {
  const digest = crypto
    .createHash("sha256")
    .update(JSON.stringify({
      userID: String(userID ?? ""),
      recipeID: String(recipeID ?? ""),
      prompt: String(prompt ?? "").trim().toLowerCase(),
      rerollNonce: String(rerollNonce ?? ""),
      nonce: Date.now(),
    }))
    .digest("hex")
    .slice(0, 24);
  return `adapt:${digest}`;
}

function adaptationRecipePayloadFromDetail(detail) {
  const ingredients = (detail.ingredients ?? [])
    .map((ingredient) => [ingredient.quantity_text, ingredient.display_name ?? ingredient.name]
      .filter(Boolean)
      .join(" ")
      .trim())
    .filter(Boolean);
  const steps = (detail.steps ?? [])
    .map((step) => String(step.text ?? step.instruction_text ?? "").trim())
    .filter(Boolean);

  return {
    title: detail.title ?? "",
    summary: detail.description ?? "",
    cook_time_text: detail.cook_time_text ?? "",
    ingredients,
    steps,
    substitutions: [],
    pairing_notes: [],
    dietary_fit: Array.isArray(detail.dietary_tags) ? detail.dietary_tags : [],
  };
}

function adaptationResponseFromDetail({ detail, row, adaptedFromRecipeID }) {
  const provenance = row?.source_provenance_json ?? {};
  return {
    adapted_recipe: adaptationRecipePayloadFromDetail(detail),
    recipe_id: detail.id,
    adapted_from_recipe_id: adaptedFromRecipeID ?? provenance.adapted_from_recipe_id ?? null,
    recipe_card: toRecipeCardPayload(detail),
    recipe_detail: detail,
    change_summary: provenance?.chat_messages?.find((message) => message?.role === "assistant")?.content ?? detail.description ?? null,
    edit_summary: provenance?.edit_summary ?? null,
    validation_status: provenance?.validation_status ?? null,
    pairing_terms: [],
    style_examples_used: [],
    model_mode: "persisted_recipe_adaptation",
    model: "persisted",
  };
}

async function runRecipeAdaptationCompletion({
  baseDetail,
  adaptationPrompt,
  profile,
  pairingTerms,
  styleExamples,
  adaptationContract,
  repairContext = null,
  userID = null,
  recipeID = null,
}) {
  const model = getActiveRecipeRewriteModel();
  const requestPayload = {
    model,
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
            adaptation_contract: adaptationContract,
            repair_context: repairContext,
            profile,
            base_recipe: baseDetail,
            flavor_pairing_hints: pairingTerms,
            style_examples: styleExamples,
          },
          null,
          2
        ),
      },
    ],
  };

  if (!/^gpt-5/i.test(model)) {
    requestPayload.temperature = repairContext ? 0.35 : 0.55;
  }

  const completion = await withAIUsageContext({
    route: "POST /v1/recipe/adapt",
    operation: repairContext ? "recipe-adapt-repair" : "recipe-adapt",
    user_id: userID,
    recipe_id: recipeID,
    intent_key: adaptationContract?.key ?? null,
    service: "recipe-api",
  }, () => openai.chat.completions.create(requestPayload));

  const content = completion?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("The model returned no recipe adaptation.");
  }

  return JSON.parse(content);
}

recipe_router.get("/recipe/adapt/history", async (req, res) => {
  const userID = String(req.query.user_id ?? "").trim();
  const recipeID = String(req.query.recipe_id ?? "").trim();
  const limit = Math.max(1, Math.min(parseInt(String(req.query.limit ?? "8"), 10) || 8, 20));

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return res.status(500).json({ error: "Recipe adaptation history requires Supabase configuration." });
  }
  if (!userID || !recipeID) {
    return res.status(400).json({ error: "recipe_id and user_id are required." });
  }

  try {
    const rows = await fetchSupabaseTableRows(
      "user_import_recipes",
      "id,user_id,title,description,author_name,author_handle,author_url,source,source_platform,category,subcategory,recipe_type,skill_level,cook_time_text,servings_text,serving_size_text,daily_diet_text,est_cost_text,est_calories_text,carbs_text,protein_text,fats_text,calories_kcal,protein_g,carbs_g,fat_g,prep_time_minutes,cook_time_minutes,hero_image_url,discover_card_image_url,recipe_url,original_recipe_url,attached_video_url,detail_footnote,image_caption,dietary_tags,flavor_tags,cuisine_tags,occasion_tags,main_protein,cook_method,published_date,ingredients_json,steps_json,servings_count,source_provenance_json,created_at,updated_at",
      [
        `user_id=eq.${encodeURIComponent(userID)}`,
        "source_platform=eq.Ounje",
      ],
      ["updated_at.desc", "created_at.desc"],
      80
    );

    const matches = [];
    for (const row of rows) {
      const provenance = row?.source_provenance_json ?? {};
      if (provenance.kind !== "recipe_adaptation") continue;
      if (String(provenance.adapted_from_recipe_id ?? "").trim() !== recipeID) continue;

      const detail = await fetchRecipeDetailForAdaptation(row.id, row);
      if (!detail) continue;
      matches.push(adaptationResponseFromDetail({ detail, row, adaptedFromRecipeID: recipeID }));
      if (matches.length >= limit) break;
    }

    return res.json({ history: matches });
  } catch (error) {
    console.error("[recipe/adapt/history] fetch failed:", error.message);
    return res.status(500).json({ error: error.message });
  }
});

recipe_router.post("/recipe/adapt", async (req, res) => {
  const {
    recipe_id: recipeId = "",
    recipe = null,
    adaptation_prompt: adaptationPrompt = "",
    intent_key: intentKey = "",
    intent_label: intentLabel = "",
    reroll_nonce: rerollNonce = "",
    strict_edit_validation: strictEditValidation = true,
    profile = null,
    user_id: userID = null,
  } = req.body ?? {};

  if (!openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return res.status(500).json({ error: "Recipe adaptation requires OpenAI and Supabase configuration." });
  }
  const normalizedUserID = String(userID ?? "").trim();
  if (!normalizedUserID) {
    return res.status(400).json({ error: "Recipe adaptation requires user_id." });
  }

  try {
    const baseDetail = await fetchRecipeDetailForAdaptation(recipeId, recipe);
    if (!baseDetail) {
      return res.status(400).json({ error: "Provide a recipe or recipe_id." });
    }

    const styleExamples = findRecipeStyleExamples({ recipe: baseDetail, profile, limit: 3 });
    const pairingTerms = suggestAdaptationPairings({
      ingredientsText: (baseDetail.ingredients ?? []).map((ingredient) =>
        [ingredient.quantity_text, ingredient.display_name].filter(Boolean).join(" ").trim()
      ).join("\n"),
      adaptationPrompt,
      profile,
      limit: 10,
    });

    const adaptationContract = getRecipeAdaptationContract(intentKey, intentLabel, adaptationPrompt);
    const strictValidation = strictEditValidation !== false;
    let adaptedRecipe = await runRecipeAdaptationCompletion({
      baseDetail,
      adaptationPrompt,
      profile,
      pairingTerms,
      styleExamples,
      adaptationContract,
      userID: normalizedUserID,
      recipeID: baseDetail.id,
    });

    let validation = validateAdaptedRecipe({
      baseDetail,
      adaptedRecipe,
      contract: adaptationContract,
      strict: strictValidation,
    });
    let validationStatus = "passed";

    if (!validation.valid && strictValidation) {
      adaptedRecipe = await runRecipeAdaptationCompletion({
        baseDetail,
        adaptationPrompt,
        profile,
        pairingTerms,
        styleExamples,
        adaptationContract,
        userID: normalizedUserID,
        recipeID: baseDetail.id,
        repairContext: {
          validation_failures: validation.failures,
          instruction: "Return a corrected full recipe. Do not preserve invalid ingredients, unchanged steps, or title-only edits.",
        },
      });
      const repairedValidation = validateAdaptedRecipe({
        baseDetail,
        adaptedRecipe,
        contract: adaptationContract,
        strict: strictValidation,
      });
      if (!repairedValidation.valid) {
        return res.status(422).json({
          error: "Ounje could not produce a reliable recipe rewrite for that request.",
          validation_failures: repairedValidation.failures,
        });
      }
      validation = repairedValidation;
      validationStatus = "repaired";
    }

    const finalEditSummary = mergeEditSummaries(adaptedRecipe.edit_summary ?? {}, validation.editSummary ?? {});
    adaptedRecipe = {
      ...adaptedRecipe,
      edit_summary: finalEditSummary,
    };
    const normalizedCandidate = buildAdaptedRecipeCandidate({
      baseDetail,
      adaptedRecipe,
      adaptationPrompt,
      adaptationContract,
      validationStatus,
      computedEditSummary: validation.editSummary,
      validationFailures: validation.failures,
      intentKey,
      intentLabel,
      rerollNonce,
    });
    const persisted = await persistNormalizedRecipe(normalizedCandidate, {
      userID: normalizedUserID,
      targetState: "adapted_preview",
      dedupeKey: adaptationDedupeKey({ userID, recipeID: baseDetail.id, prompt: adaptationPrompt, rerollNonce }),
      reviewState: "adapted_preview",
      confidenceScore: 0.92,
      qualityFlags: ["recipe_adaptation_preview", `adapt_intent_${adaptationContract.key}`],
    });

    return res.json({
      adapted_recipe: adaptedRecipe,
      recipe_id: persisted.recipe_id,
      adapted_from_recipe_id: baseDetail.id,
      recipe_card: toRecipeCardPayload({ id: persisted.recipe_id, ...persisted.recipe_card }),
      recipe_detail: persisted.recipe_detail,
      change_summary: adaptedRecipe.change_summary ?? adaptedRecipe.summary ?? null,
      edit_summary: finalEditSummary,
      validation_status: validationStatus,
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

function summarizeRecipeForDiscoverAdjudication(recipe, heuristicScore = null) {
  return {
    id: recipe?.id ?? "",
    title: recipe?.title ?? "",
    description: recipe?.description ?? "",
    recipe_type: recipe?.recipe_type ?? recipe?.recipeType ?? "",
    category: recipe?.category ?? "",
    dietary_tags: recipe?.dietary_tags ?? [],
    cuisine_tags: recipe?.cuisine_tags ?? [],
    flavor_tags: recipe?.flavor_tags ?? [],
    occasion_tags: recipe?.occasion_tags ?? [],
    discover_brackets: recipe?.discover_brackets ?? [],
    cook_time_text: recipe?.cook_time_text ?? "",
    cook_time_minutes: recipe?.cook_time_minutes ?? null,
    servings_text: recipe?.servings_text ?? "",
    servings_count: recipe?.servings_count ?? null,
    calories_kcal: parseCalories(recipe) || null,
    main_protein: recipe?.main_protein ?? "",
    source: recipe?.source ?? "",
    ingredients_text: recipe?.ingredients_text ?? "",
    heuristic_score: heuristicScore,
  };
}

async function adjudicateDiscoverSearchResultsWithLLM({
  recipes,
  profile = null,
  filter = "All",
  query = "",
  parsedQuery = null,
  llmIntent = null,
  limit = 30,
  offset = 0,
}) {
  if (!openai) return recipes;
  const candidateRecipes = Array.isArray(recipes) ? recipes.filter(Boolean) : [];
  if (candidateRecipes.length <= 2) return candidateRecipes;

  const adjudicationPoolSize = Math.min(
    candidateRecipes.length,
    Math.max(limit + offset + Math.max(limit * 2, 24), 24),
    72
  );
  const adjudicationPool = candidateRecipes.slice(0, adjudicationPoolSize);

  try {
    const completion = await withTimeout(
      openai.chat.completions.create({
        model: getActiveRecipeRewriteModel(),
        temperature: 0,
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "discover_result_adjudication",
            strict: true,
            schema: DISCOVER_RESULT_ADJUDICATION_SCHEMA,
          },
        },
        messages: [
          { role: "system", content: DISCOVER_RESULT_ADJUDICATION_SYSTEM_PROMPT },
          {
            role: "user",
            content: JSON.stringify(
              {
                original_prompt: query,
                selected_filter: filter,
                profile: summarizeProfileForIntent(profile),
                normalized_intent: {
                  user_intent: parsedQuery?.userIntent ?? llmIntent?.userIntent ?? "",
                  canonical_query: parsedQuery?.canonicalQuery ?? llmIntent?.canonicalQuery ?? "",
                  search_vertical: parsedQuery?.searchVertical ?? llmIntent?.searchVertical ?? "",
                  temperature_requirement: parsedQuery?.temperatureRequirement ?? llmIntent?.temperatureRequirement ?? "",
                  filter_type: parsedQuery?.filterType ?? llmIntent?.filterType ?? "",
                  servings_hint: parsedQuery?.servingsHint ?? llmIntent?.servingsHint ?? "",
                  max_cook_minutes: parsedQuery?.maxCookMinutes ?? llmIntent?.maxCookMinutes ?? 0,
                  min_calories_kcal: parsedQuery?.minCaloriesKcal ?? llmIntent?.minCaloriesKcal ?? 0,
                  max_calories_kcal: parsedQuery?.maxCaloriesKcal ?? llmIntent?.maxCaloriesKcal ?? 0,
                  required_ingredients: parsedQuery?.requiredIngredients ?? llmIntent?.requiredIngredients ?? [],
                  excluded_ingredients: parsedQuery?.excludedIngredients ?? llmIntent?.excludedIngredients ?? [],
                  must_include_terms: parsedQuery?.mustIncludeTerms ?? llmIntent?.mustIncludeTerms ?? [],
                  avoid_terms: parsedQuery?.avoidTerms ?? llmIntent?.avoidTerms ?? [],
                  occasion_terms: parsedQuery?.occasionTerms ?? llmIntent?.occasionTerms ?? [],
                  adjudication_notes: parsedQuery?.adjudicationNotes ?? llmIntent?.adjudicationNotes ?? "",
                },
                candidate_recipes: adjudicationPool.map((recipe, index) => summarizeRecipeForDiscoverAdjudication(
                  recipe,
                  Math.round(scoreRecipeSearchMatch(recipe, parsedQuery ?? {}, profile) * 100) / 100 + (index * -0.001)
                )),
              },
              null,
              2
            ),
          },
        ],
      }),
      5500,
      "discover result adjudication timed out"
    );

    const content = completion?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || !content.trim()) return candidateRecipes;

    const parsed = JSON.parse(content);
    const orderedIds = Array.isArray(parsed?.ordered_recipe_ids)
      ? [...new Set(parsed.ordered_recipe_ids.map((value) => String(value).trim()).filter(Boolean))]
      : [];

    if (!orderedIds.length) return candidateRecipes;

    const byId = new Map(adjudicationPool.map((recipe) => [String(recipe.id), recipe]));
    const adjudicated = orderedIds.map((id) => byId.get(id)).filter(Boolean);
    if (!adjudicated.length) return candidateRecipes;

    return adjudicated;
  } catch (error) {
    console.warn("[recipe/discover] final adjudication failed:", error.message);
    return candidateRecipes;
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
    retrievalPrompt: normalizeIntentText(intent.retrieval_prompt),
    hybridQuery: normalizeIntentText(intent.hybrid_query),
    adjudicationNotes: normalizeIntentText(intent.adjudication_notes),
    filterType: normalizeFilterType(intent.filter_type),
    searchVertical: normalizeSearchVertical(intent.search_vertical),
    temperatureRequirement: normalizeTemperatureRequirement(intent.temperature_requirement),
    maxCookMinutes: Number(intent.max_cook_minutes ?? 0) > 0 ? Number(intent.max_cook_minutes) : null,
    minCaloriesKcal: Number(intent.min_calories_kcal ?? 0) > 0 ? Number(intent.min_calories_kcal) : null,
    maxCaloriesKcal: Number(intent.max_calories_kcal ?? 0) > 0 ? Number(intent.max_calories_kcal) : null,
    servingsHint: normalizeIntentText(intent.servings_hint, 80),
    requiredIngredients: normalizeIntentTerms(intent.required_ingredients, 8),
    excludedIngredients: normalizeIntentTerms(intent.excluded_ingredients, 8),
    mustIncludeTerms: normalizeIntentTerms(intent.must_include_terms, 8),
    avoidTerms: normalizeIntentTerms(intent.avoid_terms, 8),
    semanticExpansionTerms: normalizeIntentTerms(intent.semantic_expansion_terms, 10),
    lexicalPriorityTerms: normalizeIntentTerms(intent.lexical_priority_terms, 10),
    occasionTerms: normalizeIntentTerms(intent.occasion_terms, 6),
  };
}

function normalizeIntentText(value, maxLength = 240) {
  const normalized = String(value ?? "").trim();
  if (!normalized) return "";
  return normalized.slice(0, maxLength);
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

function normalizeSearchVertical(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (!normalized) return null;
  if (["meal", "drink", "snack", "dessert"].includes(normalized)) {
    return normalized;
  }
  return null;
}

function normalizeTemperatureRequirement(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (!normalized) return null;
  if (["hot", "cold", "iced", "frozen", "room-temperature"].includes(normalized)) {
    return normalized;
  }
  return null;
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
  const queryIntentFilter = parsedQuery.filterType;
  const retrievalFilter = explicitFilter;
  const displayFilter = explicitFilter ?? queryIntentFilter;
  const flavorBoostTerms = expandFlavorTerms([
    ...parsedQuery.mustIncludeTerms,
    ...parsedQuery.lexicalTerms,
    ...extractIngredientSignals(favoriteFoods),
  ], 8);

  const primarySegments = [
    "Discover recipes for the Ounje home feed.",
    cuisines ? `Preferred cuisines: ${cuisines}.` : null,
    explicitFilter ? `Restrict to ${explicitFilter} recipes.` : null,
    !explicitFilter && queryIntentFilter ? `Prioritize ${queryIntentFilter}-style recipes without excluding mislabeled matches.` : null,
    !displayFilter ? "Prioritize broadly appealing meals." : null,
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
    explicitFilter ? `Hard focus on ${explicitFilter}.` : null,
    !explicitFilter && queryIntentFilter ? `Soft query intent: ${queryIntentFilter}. Retrieve globally first because recipe type metadata can be noisy.` : null,
  ].filter(Boolean);

  const semanticSegments = [
    llmIntent?.retrievalPrompt ? llmIntent.retrievalPrompt : null,
    parsedQuery.userIntent ? `Search intent: ${parsedQuery.userIntent}.` : null,
    parsedQuery.canonicalQuery ? `Canonical request: ${parsedQuery.canonicalQuery}.` : null,
    parsedQuery.semanticQuery ? `User is searching for: ${parsedQuery.semanticQuery}.` : null,
    parsedQuery.maxCaloriesKcal
      ? `Keep calories at or below ${parsedQuery.maxCaloriesKcal} kcal.`
      : null,
    parsedQuery.minCaloriesKcal
      ? `Keep calories at or above ${parsedQuery.minCaloriesKcal} kcal.`
      : null,
    parsedQuery.requiredIngredients?.length
      ? `Must include: ${parsedQuery.requiredIngredients.join(", ")}.`
      : null,
    parsedQuery.excludedIngredients?.length
      ? `Exclude: ${parsedQuery.excludedIngredients.join(", ")}.`
      : null,
    parsedQuery.servingsHint
      ? `Serving guidance: ${parsedQuery.servingsHint}.`
      : null,
    parsedQuery.temperatureRequirement
      ? `Service temperature: ${parsedQuery.temperatureRequirement}.`
      : null,
    cuisines ? `Preferred cuisines: ${cuisines}.` : null,
    favoriteFoods ? `Favorite foods: ${favoriteFoods}.` : null,
    flavorBoostTerms.length ? `Flavor pairings to consider: ${flavorBoostTerms.join(", ")}.` : null,
    dietaryPatterns ? `Dietary patterns: ${dietaryPatterns}.` : null,
    goals ? `Meal prep goals: ${goals}.` : null,
    explicitFilter ? `Restrict to ${explicitFilter}.` : null,
    !explicitFilter && queryIntentFilter ? `User intent leans ${queryIntentFilter}; keep retrieval broad and rank after search.` : null,
    parsedQuery.maxCookMinutes
      ? `Keep cook time under ${parsedQuery.maxCookMinutes} minutes.`
      : null,
  ].filter(Boolean);

  const richSearchSegments = [
    llmIntent?.adjudicationNotes ? `Ranking notes: ${llmIntent.adjudicationNotes}.` : null,
    parsedQuery.userIntent ? `Intent: ${parsedQuery.userIntent}.` : null,
    parsedQuery.semanticQuery ? `Search intent: ${parsedQuery.semanticQuery}.` : null,
    explicitFilter ? `Hard dietary/type constraint: ${explicitFilter}.` : null,
    !explicitFilter && queryIntentFilter ? `Soft type cue: ${queryIntentFilter}; do not exclude candidates solely because stored recipe_type differs.` : null,
    parsedQuery.maxCookMinutes
      ? `Hard time constraint: at most ${parsedQuery.maxCookMinutes} minutes.`
      : null,
    parsedQuery.mustIncludeTerms?.length
      ? `Strongly favor: ${parsedQuery.mustIncludeTerms.join(", ")}.`
      : null,
    parsedQuery.requiredIngredients?.length
      ? `Must include ingredients: ${parsedQuery.requiredIngredients.join(", ")}.`
      : null,
    parsedQuery.avoidTerms?.length
      ? `Avoid: ${parsedQuery.avoidTerms.join(", ")}.`
      : null,
    parsedQuery.excludedIngredients?.length
      ? `Do not include: ${parsedQuery.excludedIngredients.join(", ")}.`
      : null,
    parsedQuery.maxCaloriesKcal
      ? `Max calories: ${parsedQuery.maxCaloriesKcal} kcal.`
      : null,
    parsedQuery.minCaloriesKcal
      ? `Min calories: ${parsedQuery.minCaloriesKcal} kcal.`
      : null,
    parsedQuery.servingsHint
      ? `Serving target: ${parsedQuery.servingsHint}.`
      : null,
    parsedQuery.temperatureRequirement
      ? `Temperature requirement: ${parsedQuery.temperatureRequirement}.`
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
    filterType: retrievalFilter,
    semanticQuery: semanticSegments.join(" "),
    lexicalQuery: llmIntent?.hybridQuery || parsedQuery.lexicalQuery,
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
  const searchVertical = llmIntent?.searchVertical ?? null;
  const temperatureRequirement = llmIntent?.temperatureRequirement ?? inferTemperatureRequirementFromQuery(lowered);
  const beverageIntent = searchVertical === "drink" || detectBeverageIntent(lowered, llmIntent);
  const filterType = llmIntent?.filterType ?? inferFilterTypeFromQuery(lowered);
  const maxCookMinutes = llmIntent?.maxCookMinutes ?? inferMaxCookMinutes(lowered);
  const minCaloriesKcal = llmIntent?.minCaloriesKcal ?? null;
  const maxCaloriesKcal = llmIntent?.maxCaloriesKcal ?? null;
  const keywordTerms = extractQueryTerms(lowered);
  const canonicalTerms = extractQueryTerms(llmIntent?.canonicalQuery ?? "");
  const hybridTerms = extractQueryTerms(llmIntent?.hybridQuery ?? "");
  const intentPriorityTerms = llmIntent?.lexicalPriorityTerms ?? [];
  const requiredIngredients = llmIntent?.requiredIngredients ?? [];
  const excludedIngredients = llmIntent?.excludedIngredients ?? [];
  const mustIncludeTerms = [...new Set([...(llmIntent?.mustIncludeTerms ?? []), ...requiredIngredients])];
  const avoidTerms = [...new Set([...(llmIntent?.avoidTerms ?? []), ...excludedIngredients])];
  const occasionTerms = llmIntent?.occasionTerms ?? [];
  const temperatureTerms = keywordTerms.filter((term) => BEVERAGE_TEMPERATURE_TERMS.has(term));
  const expandedTerms = expandQueryTerms([
    ...keywordTerms,
    ...canonicalTerms,
    ...hybridTerms,
    ...mustIncludeTerms,
    ...intentPriorityTerms,
  ]);
  const exactPhrase = normalizeExactPhrase(llmIntent?.canonicalQuery || lowered);

  let lexicalTerms = [
    ...new Set(
      [...keywordTerms, ...canonicalTerms, ...mustIncludeTerms, ...intentPriorityTerms, ...requiredIngredients]
        .concat(hybridTerms)
        .filter((term) => !STOPWORDS.has(term))
    ),
  ];
  if (beverageIntent) {
    lexicalTerms = lexicalTerms.filter((term) => !BEVERAGE_TEMPERATURE_TERMS.has(term) && !["drink", "beverage"].includes(term));
  }
  const semanticTerms = [
    ...new Set([
      ...lexicalTerms,
      ...expandedTerms,
      ...(llmIntent?.semanticExpansionTerms ?? []),
      ...occasionTerms,
      ...(beverageIntent ? BEVERAGE_ANCHOR_TERMS : []),
      ...(beverageIntent ? temperatureTerms : []),
      filterType,
      maxCookMinutes ? "quick" : null,
      maxCookMinutes ? "fast" : null,
    ].filter(Boolean)),
  ];

  return {
    rawQuery,
    selectedFilter: null,
    filterType,
    searchVertical,
    temperatureRequirement,
    maxCookMinutes,
    minCaloriesKcal,
    maxCaloriesKcal,
    exactPhrase,
    userIntent: llmIntent?.userIntent ?? "",
    canonicalQuery: llmIntent?.canonicalQuery ?? "",
    retrievalPrompt: llmIntent?.retrievalPrompt ?? "",
    hybridQuery: llmIntent?.hybridQuery ?? "",
    adjudicationNotes: llmIntent?.adjudicationNotes ?? "",
    servingsHint: llmIntent?.servingsHint ?? "",
    requiredIngredients,
    excludedIngredients,
    lexicalTerms,
    lexicalQuery: lexicalTerms.join(" "),
    semanticQuery: semanticTerms.join(" "),
    mustIncludeTerms,
    avoidTerms,
    occasionTerms,
    beverageIntent,
    temperatureTerms,
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

function inferTemperatureRequirementFromQuery(query) {
  const normalized = String(query ?? "").toLowerCase();
  if (!normalized) return null;
  if (/\biced\b/.test(normalized)) return "iced";
  if (/\bfrozen\b/.test(normalized)) return "frozen";
  if (/\bcold\b|\bchilled\b/.test(normalized)) return "cold";
  if (/\bhot\b|\bwarm\b/.test(normalized)) return "hot";
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

  const trimmed = singularizeQueryTerm(String(term).trim().toLowerCase());
  if (!trimmed || STOPWORDS.has(trimmed)) return null;
  if (/^\d+$/.test(trimmed)) return null;
  if (trimmed.length <= 1) return null;

  return trimmed;
}

function singularizeQueryTerm(term) {
  const normalized = String(term ?? "").trim().toLowerCase();
  if (!normalized) return "";
  if (normalized.endsWith("ies") && normalized.length > 4) {
    return `${normalized.slice(0, -3)}y`;
  }
  if (normalized.endsWith("s") && !normalized.endsWith("ss") && normalized.length > 4) {
    return normalized.slice(0, -1);
  }
  return normalized;
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
  drink: ["beverage", "tea", "coffee", "latte", "chai", "matcha", "cocoa", "hot chocolate", "espresso", "mocha"],
  beverage: ["drink", "tea", "coffee", "latte", "chai", "matcha", "cocoa", "smoothie", "juice"],
};

const BEVERAGE_TEMPERATURE_TERMS = new Set([
  "hot",
  "cold",
  "iced",
  "warm",
  "frozen",
  "chilled",
]);

const BEVERAGE_QUERY_TERMS = new Set([
  "drink",
  "beverage",
  "tea",
  "coffee",
  "latte",
  "chai",
  "matcha",
  "cocoa",
  "espresso",
  "mocha",
  "smoothie",
  "juice",
  "lemonade",
  "cider",
  "milkshake",
]);

const BEVERAGE_ANCHOR_TERMS = [
  "tea",
  "coffee",
  "latte",
  "chai",
  "matcha",
  "cocoa",
  "hot chocolate",
  "espresso",
  "mocha",
  "smoothie",
  "juice",
  "lemonade",
  "milkshake",
  "cider",
  "cocktail",
  "mocktail",
  "tonic",
  "margarita",
  "spritz",
  "old fashioned",
  "eggnog",
  "drink",
  "beverage",
];

const BEVERAGE_STRONG_TERMS = [
  "tea",
  "coffee",
  "latte",
  "chai",
  "hot chocolate",
  "espresso",
  "mocha",
  "smoothie",
  "juice",
  "lemonade",
  "milkshake",
  "cider",
  "cocktail",
  "mocktail",
  "tonic",
  "margarita",
  "spritz",
  "old fashioned",
  "eggnog",
  "drink",
  "beverage",
];

const BEVERAGE_SOFT_TERMS = [
  "matcha",
  "cocoa",
];

const BEVERAGE_BLOCKLIST_TERMS = [
  "cookie",
  "cookies",
  "brownie",
  "cake",
  "cheesecake",
  "brookie",
  "brookies",
  "bar",
  "bars",
  "munch",
  "pudding",
  "flan",
  "tres leches",
  "tart",
  "tiramisu",
  "bread",
  "banana bread",
  "brulee",
  "crème brûlée",
  "parfait",
  "cluster",
  "clusters",
  "overnight oats",
  "oatmeal",
  "focaccia",
  "quiche",
  "salad",
  "chicken",
  "beef",
  "salmon",
  "pasta",
  "bowl",
  "toast",
  "burger",
  "sandwich",
  "wrap",
  "potato",
  "potatoes",
  "fries",
  "nuggets",
  "parm",
];

function normalizeSearchSurface(value) {
  return ` ${String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()} `;
}

function containsSearchTerm(value, term) {
  const normalizedTerm = normalizeSearchSurface(term).trim();
  if (!normalizedTerm) return false;
  return normalizeSearchSurface(value).includes(` ${normalizedTerm} `);
}

function detectBeverageIntent(query, llmIntent = null) {
  const haystack = `${String(query ?? "").toLowerCase()} ${String(llmIntent?.canonicalQuery ?? "").toLowerCase()} ${String(llmIntent?.userIntent ?? "").toLowerCase()}`;
  return BEVERAGE_ANCHOR_TERMS.some((term) => haystack.includes(term));
}

function isBeverageLikeRecipe(recipe) {
  const title = String(recipe?.title ?? "");
  const description = String(recipe?.description ?? "");
  const recipeType = String(recipe?.recipe_type ?? recipe?.recipeType ?? "");
  const category = String(recipe?.category ?? "");
  const tags = [
    ...(normalizeSearchTagTerms(recipe?.cuisine_tags) ?? []),
    ...(normalizeSearchTagTerms(recipe?.dietary_tags) ?? []),
    ...(normalizeSearchTagTerms(recipe?.flavor_tags) ?? []),
    ...(normalizeSearchTagTerms(recipe?.occasion_tags) ?? []),
    ...(normalizeSearchTagTerms(recipe?.discover_brackets) ?? []),
  ].join(" ");
  const primarySurface = `${title} ${recipeType} ${category} ${tags}`;
  const contextualSurface = `${primarySurface} ${description}`;
  const hasStrongAnchor = BEVERAGE_STRONG_TERMS.some((term) => containsSearchTerm(primarySurface, term));
  const hasSoftAnchor = BEVERAGE_SOFT_TERMS.some((term) => containsSearchTerm(contextualSurface, term));
  const hasDrinkBracket = containsSearchTerm(tags, "drinks") || containsSearchTerm(tags, "drink") || containsSearchTerm(primarySurface, "beverage");
  const hasAnchor = hasStrongAnchor || (hasSoftAnchor && hasDrinkBracket);
  if (!hasAnchor) return false;
  const blocked = BEVERAGE_BLOCKLIST_TERMS.some((term) => containsSearchTerm(title, term) || containsSearchTerm(category, term) || containsSearchTerm(recipeType, term) || containsSearchTerm(tags, term));
  return !blocked;
}

async function embedText(input, model) {
  const response = await withAIUsageContext({
    service: "recipe-api",
    operation: "recipe_embedding",
    metadata: {
      input_length: String(input ?? "").length,
    },
  }, () => openai.embeddings.create({ model, input }));
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
    const rawSnippet = String(raw ?? "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 240);
    const looksLikeHtml = /<!doctype html>|<html[\s>]/i.test(raw ?? "");
    const message = data?.message
      ?? data?.error
      ?? (response.status >= 500 || looksLikeHtml
        ? "Recipe source temporarily unavailable"
        : rawSnippet || "Recipe fetch failed");
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
  const batches = [];
  for (let index = 0; index < orderedIds.length; index += normalizedBatchSize) {
    batches.push(orderedIds.slice(index, index + normalizedBatchSize));
  }

  const chunks = (await Promise.all(
    batches.map((batch) => fetchRecipesWithSelect({
      ids: batch,
      fields,
    }))
  )).flat();

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

function safeLexicalTerm(term) {
  return String(term ?? "")
    .replace(/[*,()]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 80);
}

function buildLexicalSearchTerms(query) {
  const extracted = extractQueryTerms(query);
  return uniqueStrings([
    normalizeExactPhrase(query),
    ...extracted,
    ...expandQueryTerms(extracted),
  ].map(safeLexicalTerm), 8);
}

const SEARCH_ANCHOR_STOPWORDS = new Set([
  ...STOPWORDS,
  "breakfast",
  "lunch",
  "dinner",
  "dessert",
  "desserts",
  "sweet",
  "sweets",
  "snack",
  "snacks",
  "drink",
  "drinks",
  "beverage",
  "beverages",
  "hot",
  "cold",
  "iced",
  "frozen",
  "warm",
  "quick",
  "easy",
  "healthy",
  "light",
]);

function buildLexicalAnchorTerms(query, parsedQuery = null) {
  const terms = buildLexicalSearchTerms(query);
  return uniqueStrings(
    terms
      .map((term) => {
        const normalizedTokens = String(term ?? "")
          .split(/\s+/)
          .map((token) => normalizeQueryTerm(token))
          .filter(Boolean)
          .filter((token) => !SEARCH_ANCHOR_STOPWORDS.has(token));
        return normalizedTokens.join(" ");
      })
      .filter((term) => term.length >= 3),
    5
  );
}

async function fetchLexicalAnchorRecipes({ query, parsedQuery = null, limit = 24 }) {
  const terms = buildLexicalAnchorTerms(query, parsedQuery);
  if (!terms.length) return [];

  const fetchLimit = Math.max(1, Math.min(Number(limit) || 24, 48));
  const fetched = (await Promise.all(
    terms.slice(0, 4).map((term) => fetchRecipesByFullTextTerm(term, fetchLimit).catch((error) => {
      console.warn("[recipe/discover] lexical anchor term failed:", term, error.message);
      return [];
    }))
  )).flat();

  return dedupeRecipesById(fetched)
    .filter((recipe) => terms.some((term) => containsSearchTerm(lexicalRecipeSurface(recipe), term)))
    .sort((left, right) => scoreLexicalSearchRecipe(right, terms, query) - scoreLexicalSearchRecipe(left, terms, query))
    .slice(0, fetchLimit);
}

function completeSearchResultsFromCandidatePool({
  selectedRecipes,
  candidateRecipes,
  query,
  parsedQuery = null,
  limit = 30,
}) {
  const selected = dedupeRecipesById(selectedRecipes ?? []);
  const candidates = dedupeRecipesById(candidateRecipes ?? []);
  const safeLimit = Math.max(1, Number(limit) || 30);
  if (!candidates.length) return selected.slice(0, safeLimit);

  const anchorTerms = buildLexicalAnchorTerms(query, parsedQuery);
  if (!anchorTerms.length) {
    return dedupeRecipesById([...selected, ...candidates]).slice(0, safeLimit);
  }

  const matchesAnchor = (recipe) => anchorTerms.some((term) => containsSearchTerm(lexicalRecipeSurface(recipe), term));
  const selectedMatches = selected.filter(matchesAnchor);
  const candidateMatches = candidates.filter(matchesAnchor);
  const minimumConcreteSet = Math.min(safeLimit, 4);

  if (candidateMatches.length >= minimumConcreteSet || selectedMatches.length > 0) {
    return dedupeRecipesById([
      ...selectedMatches,
      ...candidateMatches,
    ]).slice(0, safeLimit);
  }

  return dedupeRecipesById([...selected, ...candidates]).slice(0, safeLimit);
}

async function fetchRecipesByFullTextTerm(term, limit = 48) {
  const safeTerm = safeLexicalTerm(term);
  if (!safeTerm) return [];

  const select = CANONICAL_RECIPE_SELECT_FIELDS.join(",");
  const safeLimit = Math.max(1, Math.min(Number(limit) || 48, 120));
  const url = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(select)}&fts_doc=plfts.${encodeURIComponent(safeTerm)}&limit=${safeLimit}`;

  try {
    return await fetchRecipesFromUrl(url);
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }

    const fallbackSelect = LEGACY_RECIPE_SELECT_FIELDS.join(",");
    const fallbackUrl = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(fallbackSelect)}&fts_doc=plfts.${encodeURIComponent(safeTerm)}&limit=${safeLimit}`;
    return fetchRecipesFromUrl(fallbackUrl);
  }
}

async function fetchRecipesByLexicalTerm(term, limit = 48) {
  const safeTerm = safeLexicalTerm(term);
  if (!safeTerm) return [];

  const fullTextMatches = await fetchRecipesByFullTextTerm(safeTerm, limit).catch(() => []);
  if (fullTextMatches.length) {
    return fullTextMatches;
  }

  const select = CANONICAL_RECIPE_SELECT_FIELDS.join(",");
  const orClause = [
    `title.ilike.*${safeTerm}*`,
    `description.ilike.*${safeTerm}*`,
    `ingredients_text.ilike.*${safeTerm}*`,
    `category.ilike.*${safeTerm}*`,
    `recipe_type.ilike.*${safeTerm}*`,
  ].join(",");
  const safeLimit = Math.max(1, Math.min(Number(limit) || 48, 120));
  const url = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(select)}&or=${encodeURIComponent(`(${orClause})`)}&order=${encodeURIComponent("published_date.desc.nullslast")}&limit=${safeLimit}`;

  try {
    return await fetchRecipesFromUrl(url);
  } catch (error) {
    if (!isMissingRecipeColumnError(error.message)) {
      throw error;
    }

    const fallbackSelect = LEGACY_RECIPE_SELECT_FIELDS.join(",");
    const fallbackUrl = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(fallbackSelect)}&or=${encodeURIComponent(`(${orClause})`)}&order=${encodeURIComponent("published_date.desc.nullslast")}&limit=${safeLimit}`;
    return fetchRecipesFromUrl(fallbackUrl);
  }
}

function lexicalRecipeSurface(recipe) {
  return [
    recipe?.title,
    recipe?.description,
    recipe?.recipe_type,
    recipe?.category,
    recipe?.subcategory,
    recipe?.main_protein,
    recipe?.ingredients_text,
    ...(Array.isArray(recipe?.dietary_tags) ? recipe.dietary_tags : []),
    ...(Array.isArray(recipe?.flavor_tags) ? recipe.flavor_tags : []),
    ...(Array.isArray(recipe?.cuisine_tags) ? recipe.cuisine_tags : []),
    ...(Array.isArray(recipe?.occasion_tags) ? recipe.occasion_tags : []),
    ...(Array.isArray(recipe?.discover_brackets) ? recipe.discover_brackets : []),
  ].map((value) => String(value ?? "")).join(" ");
}

function scoreLexicalSearchRecipe(recipe, terms, query) {
  const title = normalizeSearchSurface(recipe?.title);
  const surface = normalizeSearchSurface(lexicalRecipeSurface(recipe));
  const exactPhrase = safeLexicalTerm(query).toLowerCase();
  let score = stableJitter(`lexical|${query}|${recipe?.id ?? recipe?.title ?? ""}`) * 0.5;

  if (exactPhrase && title.includes(` ${exactPhrase} `)) score += 12;
  if (exactPhrase && surface.includes(` ${exactPhrase} `)) score += 6;

  for (const term of terms) {
    const normalized = normalizeSearchSurface(term).trim();
    if (!normalized) continue;
    if (title.includes(` ${normalized} `)) score += 5;
    if (surface.includes(` ${normalized} `)) score += 2;
  }

  return score;
}

async function buildLexicalSearchFallbackPayload({
  query,
  profile,
  filter,
  feedContext,
  requestedLimit,
  requestedOffset,
  requestedWindowLimit,
}) {
  const terms = buildLexicalSearchTerms(query);
  const fetchLimit = Math.max(requestedWindowLimit * 8, 72);
  const fetched = (await Promise.all(
    terms.slice(0, 5).map((term) => fetchRecipesByLexicalTerm(term, fetchLimit).catch((error) => {
      console.warn("[recipe/discover] lexical fallback term failed:", term, error.message);
      return [];
    }))
  )).flat();

  let recipes = dedupeRecipesById(fetched);
  if (recipes.length === 0) {
    recipes = await fetchRandomDiscoverRecipes({
      limit: Math.max(requestedWindowLimit * 4, 72),
      seed: `${feedContext?.sessionSeed ?? "discover"}|lexical-empty|${query}`,
      filter,
    });
  }

  recipes = recipes
    .filter((recipe) => terms.length === 0 || terms.some((term) => containsSearchTerm(lexicalRecipeSurface(recipe), term)))
    .sort((left, right) => scoreLexicalSearchRecipe(right, terms, query) - scoreLexicalSearchRecipe(left, terms, query));
  recipes = filterRecipesByAllergies(recipes, profile);
  recipes = applyPresetCategoryGate(recipes, filter);
  recipes = applyPresetHardConstraints(recipes, filter);

  return pageDiscoverResults({
    recipes,
    filters: deriveSearchFilters(recipes),
    rankingMode: "lexical_search_fallback",
  }, requestedOffset, requestedLimit);
}

async function fetchRecipesByIdBatches(ids, batchSize = 70) {
  const orderedIds = normalizeOrderedRecipeIDs(ids);
  if (!orderedIds.length) return [];

  try {
    return await fetchRecipesByIdsWithFields(orderedIds, CANONICAL_RECIPE_SELECT_FIELDS, batchSize);
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
      Prefer: "count=planned",
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
    const fallbackRecipes = await fetchLatestRecipes(Math.max(limit, 48));
    return rankPresetFocusedRecipes(fallbackRecipes, { filter, seed: `${seed}|fallback-random` }).slice(0, limit);
  }

  const windowSize = Math.min(Math.max(limit, 24), 48);
  const windowCount = Math.max(3, Math.ceil(limit / 24));
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

async function fetchDiscoverBroadPool({
  profile = null,
  filter = "All",
  feedContext = null,
  seed = "discover-broad",
  limit = 360,
}) {
  const cacheKey = JSON.stringify({
    filter: String(filter ?? "All"),
    seed,
    limit,
    profile: summarizeProfileForIntent(profile),
    feedContext: {
      sessionSeed: feedContext?.sessionSeed ?? null,
      windowKey: feedContext?.windowKey ?? null,
      daypart: feedContext?.daypart ?? null,
      weekday: feedContext?.weekday ?? null,
      weatherMood: feedContext?.weatherMood ?? null,
      temperatureBand: feedContext?.temperatureBand ?? null,
      seasonCue: feedContext?.seasonCue ?? null,
    },
  });

  const cachedPool = readTimedCache(discoverBroadPoolCache, cacheKey, DISCOVER_BROAD_POOL_CACHE_TTL_MS);
  if (cachedPool) {
    return cachedPool;
  }

  const [randomPool, latestPool] = await Promise.all([
    fetchRandomDiscoverRecipes({
      limit: Math.min(Math.max(limit, 120), 360),
      seed: `${seed}|random`,
      filter,
    }).catch((error) => {
      console.warn("[recipe/discover] broad random pool failed:", error.message);
      return [];
    }),
    fetchLatestRecipes(Math.min(Math.max(limit, 90), 240)).catch((error) => {
      console.warn("[recipe/discover] broad latest pool failed:", error.message);
      return [];
    }),
  ]);

  const pool = dedupeRecipesById([
    ...randomPool,
    ...latestPool,
  ]);
  discoverBroadPoolCache.set(cacheKey, { value: pool, createdAt: Date.now() });
  return pool;
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

  let bracketIds = getCachedRecipeIdsForBracket(filter);
  if (!bracketIds.length) {
    try {
      bracketIds = await fetchDbBracketRecipeIds(filter);
    } catch (error) {
      if (!isMissingRecipeColumnError(error.message)) {
        throw error;
      }
    }
  }

  if (!bracketIds.length) {
    return [];
  }

  const shuffledIds = stableShuffle(
    bracketIds.map((id) => ({ id })),
    `${seed}|${preset.key}|ids`
  ).map((item) => item.id);

  const idsToFetch = shuffledIds.slice(0, Math.min(shuffledIds.length, Math.max(1, limit)));
  const recipes = await fetchRecipesByIdBatches(idsToFetch);
  return applyPresetCategoryGate(
    applyPresetHardConstraints(recipes, filter),
    filter
  ).slice(0, Math.max(1, limit));
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
  const broadPool = await fetchDiscoverBroadPool({
    profile: null,
    filter,
    feedContext,
    seed,
    limit: Math.min(Math.max(limit * 3, 90), 150),
  });
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
  const broadPool = await fetchDiscoverBroadPool({
    profile,
    filter,
    feedContext,
    seed,
    limit: Math.min(Math.max(limit * 3, 96), 150),
  });
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

function applyIntentHardConstraints(recipes, parsedQuery = null) {
  if (!Array.isArray(recipes) || recipes.length === 0) return [];
  if (!parsedQuery || typeof parsedQuery !== "object") return recipes;

  return recipes.filter((recipe) => {
    if (parsedQuery.maxCookMinutes) {
      const cookMinutes = parseCookMinutes(recipe?.cook_time_text ?? recipe?.cookTimeText ?? "");
      if (cookMinutes != null && cookMinutes > parsedQuery.maxCookMinutes) {
        return false;
      }
    }

    if (parsedQuery.maxCaloriesKcal) {
      const calories = parseCalories(recipe);
      if (calories > 0 && calories > parsedQuery.maxCaloriesKcal) {
        return false;
      }
    }

    if (parsedQuery.minCaloriesKcal) {
      const calories = parseCalories(recipe);
      if (calories > 0 && calories < parsedQuery.minCaloriesKcal) {
        return false;
      }
    }

    return true;
  });
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
  const conversationalCue = /\b(what|should|would|could|please|recommend|suggest|best|good|idea|ideas|tonight|today|tomorrow|week|month|for me)\b/.test(trimmed);
  if (trimmed.length <= 2) return true;
  if (semanticCueTerms.some((term) => trimmed.includes(term))) {
    return false;
  }
  if (
    termCount <= 6
    && trimmed.length <= 48
    && !conversationalCue
    && !(parsedQuery?.occasionTerms?.length)
    && !(parsedQuery?.avoidTerms?.length)
    && !(parsedQuery?.mustIncludeTerms?.length > 3)
  ) {
    return true;
  }
  return false;
}

function buildDiscoverSearchCacheKey({ query, filter, limit, offset = 0, profile }) {
  return JSON.stringify({
    query: String(query ?? "").trim().toLowerCase(),
    filter: String(filter ?? "All"),
    limit,
    offset,
    profile: summarizeProfileForIntent(profile),
  });
}

function buildDiscoverFeedCacheKey({ profile, filter, feedContext, limit, offset = 0 }) {
  return JSON.stringify({
    filter: String(filter ?? "All"),
    limit,
    offset,
    profile: summarizeProfileForIntent(profile),
    feedContext: {
      sessionSeed: feedContext?.sessionSeed ?? null,
      windowKey: feedContext?.windowKey ?? null,
      daypart: feedContext?.daypart ?? null,
      weekday: feedContext?.weekday ?? null,
      weatherMood: feedContext?.weatherMood ?? null,
      temperatureBand: feedContext?.temperatureBand ?? null,
      seasonCue: feedContext?.seasonCue ?? null,
    },
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

function pageDiscoverResults(payload, offset = 0, limit = 30) {
  const recipes = Array.isArray(payload?.recipes) ? payload.recipes : [];
  const safeOffset = Number.isFinite(Number(offset)) ? Math.max(0, Number(offset)) : 0;
  const safeLimit = Number.isFinite(Number(limit)) ? Math.max(1, Number(limit)) : 30;
  const pagedRecipes = recipes.slice(safeOffset, safeOffset + safeLimit);
  const hasMore = safeOffset + pagedRecipes.length < recipes.length;
  return {
    ...payload,
    recipes: pagedRecipes,
    totalAvailable: recipes.length,
    hasMore,
    nextOffset: hasMore ? safeOffset + pagedRecipes.length : null,
  };
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
  const beverageIntent = Boolean(parsedQuery.beverageIntent);
  const beverageLikeRecipe = isBeverageLikeRecipe(recipe);

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
    if (containsSearchTerm(title, exactPhrase)) score += 48;
    else if (containsSearchTerm(description, exactPhrase) || containsSearchTerm(ingredients, exactPhrase)) score += 26;
  }

  if (beverageIntent) {
    score += beverageLikeRecipe ? 28 : -18;
  }

  let matchedTerms = 0;
  for (const term of lexicalTerms) {
    const inTitle = containsSearchTerm(title, term);
    const inDescription = containsSearchTerm(description, term);
    const inIngredients = containsSearchTerm(ingredients, term);
    const inType = containsSearchTerm(recipeType, term) || containsSearchTerm(category, term);
    const inSource = containsSearchTerm(source, term);
    const inCuisine = cuisineTags.some((value) => containsSearchTerm(value, term));
    const inDietary = dietaryTags.some((value) => containsSearchTerm(value, term));
    const inFlavor = flavorTags.some((value) => containsSearchTerm(value, term));
    const inOccasion = occasionTags.some((value) => containsSearchTerm(value, term));
    const inBracket = discoverBrackets.some((value) => containsSearchTerm(value, term));

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
    if (containsSearchTerm(title, term)) score += 16;
    else if (
      containsSearchTerm(description, term)
      || containsSearchTerm(ingredients, term)
      || containsSearchTerm(recipeType, term)
      || containsSearchTerm(category, term)
      || containsSearchTerm(source, term)
      || cuisineTags.some((value) => containsSearchTerm(value, term))
      || dietaryTags.some((value) => containsSearchTerm(value, term))
      || flavorTags.some((value) => containsSearchTerm(value, term))
      || occasionTags.some((value) => containsSearchTerm(value, term))
      || discoverBrackets.some((value) => containsSearchTerm(value, term))
    ) score += 9;
  }

  for (const term of parsedQuery.avoidTerms ?? []) {
    if (containsSearchTerm(title, term) || containsSearchTerm(description, term) || containsSearchTerm(ingredients, term)) {
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
  const matchedLexicalTerms = lexicalTerms.filter((term) => containsSearchTerm(haystack, term));
  const matchedMustTerms = mustIncludeTerms.filter((term) => containsSearchTerm(haystack, term));
  const matchesFilter = filterType
    ? recipeType === filterType
      || category === filterType
      || discoverBrackets.includes(filterType)
      || dietaryTags.includes(filterType)
    : false;
  const titleMatchedLexicalTerms = lexicalTerms.filter((term) => containsSearchTerm(title, term));
  const titleOrTypeMatchedLexicalTerms = lexicalTerms.filter((term) => {
    return containsSearchTerm(title, term) || containsSearchTerm(recipeType, term) || containsSearchTerm(category, term);
  });
  const lexicalCoverage = lexicalTerms.length > 0 ? matchedLexicalTerms.length / lexicalTerms.length : 0;
  const isTightPhraseSearch = exactPhrase && lexicalTerms.length >= 2 && lexicalTerms.length <= 4;
  const beverageIntent = Boolean(parsedQuery.beverageIntent);
  const beverageLikeRecipe = isBeverageLikeRecipe(recipe);
  const dessertIntent =
    filterType === "dessert"
    || lexicalTerms.some((term) => /(ice cream|gelato|sorbet|cake|cookie|brownie|pie|dessert|sweet)/.test(term));

  if (score < -8) return false;
  if (exactPhrase && containsSearchTerm(haystack, exactPhrase)) return true;
  if (matchedMustTerms.length > 0) return score >= 6;

  if (beverageIntent) {
    if (!beverageLikeRecipe) return false;
    return score >= 8 || titleMatchedLexicalTerms.length > 0 || lexicalCoverage >= 0.34 || lexicalTerms.length === 0;
  }

  if (isTightPhraseSearch) {
    if (containsSearchTerm(title, exactPhrase) || containsSearchTerm(description, exactPhrase) || containsSearchTerm(category, exactPhrase)) {
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

async function fetchSupabaseTableRows(tableName, select, filters = [], orderClauses = [], limit = null) {
  let url = `${SUPABASE_URL}/rest/v1/${tableName}?select=${encodeURIComponent(select)}`;

  for (const filter of filters) {
    if (filter) url += `&${filter}`;
  }

  for (const orderClause of orderClauses) {
    if (orderClause) url += `&order=${orderClause}`;
  }
  if (limit != null) {
    url += `&limit=${Math.max(1, Math.min(Number(limit) || 1, 500))}`;
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

async function fetchRecipeIngredientRowsByRecipeIds(recipeIds, tableName, batchSize = 80) {
  const orderedIds = normalizeOrderedRecipeIDs(recipeIds);
  if (!orderedIds.length) return [];

  const batches = [];
  const normalizedBatchSize = Math.max(1, Math.min(batchSize, 120));
  for (let index = 0; index < orderedIds.length; index += normalizedBatchSize) {
    batches.push(orderedIds.slice(index, index + normalizedBatchSize));
  }

  const chunks = await Promise.all(
    batches.map((batch) => fetchSupabaseTableRows(
      tableName,
      "id,recipe_id,ingredient_id,display_name,quantity_text,image_url,sort_order",
      [`recipe_id=in.(${batch.map((id) => encodeURIComponent(id)).join(",")})`],
      ["recipe_id.asc", "sort_order.asc", "created_at.asc"]
    ))
  );

  return chunks.flat();
}

async function hydrateRecipesWithIngredientRows(recipes) {
  if (!Array.isArray(recipes) || !recipes.length) return [];

  const publicRecipeIds = [];
  const importedRecipeIds = [];

  for (const recipe of recipes) {
    const id = String(recipe?.id ?? "").trim();
    if (!id) continue;
    if (id.startsWith("uir_")) {
      importedRecipeIds.push(id);
    } else {
      publicRecipeIds.push(id);
    }
  }

  const [publicRows, importedRows] = await Promise.all([
    publicRecipeIds.length
      ? fetchRecipeIngredientRowsByRecipeIds(publicRecipeIds, "recipe_ingredients")
      : Promise.resolve([]),
    importedRecipeIds.length
      ? fetchRecipeIngredientRowsByRecipeIds(importedRecipeIds, "user_import_recipe_ingredients")
      : Promise.resolve([]),
  ]);

  const rowsByRecipeId = new Map();
  for (const row of [...publicRows, ...importedRows]) {
    const recipeId = String(row?.recipe_id ?? "").trim();
    if (!recipeId) continue;
    if (!rowsByRecipeId.has(recipeId)) {
      rowsByRecipeId.set(recipeId, []);
    }
    rowsByRecipeId.get(recipeId).push(row);
  }

  return recipes.map((recipe) => {
    const id = String(recipe?.id ?? "").trim();
    const ingredientRows = rowsByRecipeId.get(id) ?? [];
    if (!ingredientRows.length) return recipe;
    return {
      ...recipe,
      recipe_ingredients: ingredientRows,
    };
  });
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

function normalizeSimilarRecipeInput(value = {}) {
  const recipe = value && typeof value === "object" ? value : {};
  return {
    id: String(recipe.id ?? "").trim(),
    title: String(recipe.title ?? "").trim(),
    description: String(recipe.description ?? "").trim(),
    recipe_type: recipe.recipe_type ?? recipe.recipeType ?? null,
    category: recipe.category ?? null,
    main_protein: recipe.main_protein ?? recipe.mainProtein ?? null,
    cuisine_tags: Array.isArray(recipe.cuisine_tags) ? recipe.cuisine_tags : (Array.isArray(recipe.cuisineTags) ? recipe.cuisineTags : []),
    flavor_tags: Array.isArray(recipe.flavor_tags) ? recipe.flavor_tags : (Array.isArray(recipe.flavorTags) ? recipe.flavorTags : []),
    occasion_tags: Array.isArray(recipe.occasion_tags) ? recipe.occasion_tags : (Array.isArray(recipe.occasionTags) ? recipe.occasionTags : []),
    ingredients: Array.isArray(recipe.ingredients) ? recipe.ingredients : [],
  };
}

async function fallbackSimilarRecipeCards({ detail, recipeId, limit }) {
  const sourceTitle = normalizeSearchName(detail?.title);
  const sourceType = normalizeSearchName(detail?.recipe_type ?? detail?.category);
  const sourceProtein = normalizeSearchName(detail?.main_protein);
  const sourceTags = new Set([
    ...(detail?.cuisine_tags ?? []),
    ...(detail?.flavor_tags ?? []),
    ...(detail?.occasion_tags ?? []),
  ].map(normalizeSearchName).filter(Boolean));
  const sourceIngredients = new Set(
    (detail?.ingredients ?? [])
      .map((ingredient) => normalizeSearchName(ingredient?.display_name ?? ingredient?.name ?? ""))
      .filter(Boolean)
  );
  const seedTerms = uniqueStrings([
    detail?.title,
    detail?.recipe_type,
    detail?.category,
    detail?.main_protein,
    ...(detail?.cuisine_tags ?? []),
    ...(detail?.flavor_tags ?? []),
    ...(detail?.occasion_tags ?? []),
    ...Array.from(sourceIngredients).slice(0, 6),
  ], 16);

  const latest = await fetchLatestRecipes(Math.max(limit + 20, 32));
  return latest
    .filter((recipe) => String(recipe.id) !== String(recipeId))
    .map((recipe, index) => {
      const candidateType = normalizeSearchName(recipe.recipe_type ?? recipe.category);
      const candidateProtein = normalizeSearchName(recipe.main_protein);
      const candidateTags = [
        ...(recipe.cuisine_tags ?? []),
        ...(recipe.flavor_tags ?? []),
        ...(recipe.occasion_tags ?? []),
      ].map(normalizeSearchName).filter(Boolean);
      const candidateIngredients = extractCandidateIngredientNames(recipe).map(normalizeSearchName).filter(Boolean);
      const tagOverlap = candidateTags.reduce((count, tag) => count + (sourceTags.has(tag) ? 1 : 0), 0);
      const ingredientOverlap = candidateIngredients.reduce((count, ingredient) => count + (sourceIngredients.has(ingredient) ? 1 : 0), 0);
      const typeOverlap = sourceType && candidateType === sourceType ? 2 : 0;
      const proteinOverlap = sourceProtein && candidateProtein === sourceProtein ? 1.6 : 0;
      const titlePenalty = sourceTitle && normalizeSearchName(recipe.title) === sourceTitle ? -10 : 0;
      return {
        recipe,
        score:
          typeOverlap
          + proteinOverlap
          + tagOverlap * 0.9
          + ingredientOverlap * 0.55
          + scoreFlavorAlignment(recipe, seedTerms, []) * 0.9
          + (1 / (index + 8))
          + titlePenalty,
      };
    })
    .sort((left, right) => right.score - left.score)
    .slice(0, limit)
    .map(({ recipe }) => toRecipeCardPayload(recipe));
}

function normalizeSearchName(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function normalizedRecipeTitleKey(value) {
  return normalizeSearchName(value)
    .replace(/\b(the|a|an)\b/g, " ")
    .replace(/\s+/g, " ")
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
  const rerollNonce = String(value.reroll_nonce ?? value.rerollNonce ?? "").trim();

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
    targetRecipeCount: Number.isFinite(Number(value.target_recipe_count ?? value.targetRecipeCount))
      ? Math.max(1, Math.floor(Number(value.target_recipe_count ?? value.targetRecipeCount)))
      : null,
    currentRecipeIDs,
    currentRecipes,
    userPrompt: userPrompt.length ? userPrompt : null,
    rerollNonce: rerollNonce.length ? rerollNonce : null,
  };
}

function avoidCurrentPrepRecipesForReroll(recipes, regenerationContext, recurringRecipeIds = [], minimumFreshCount = 18) {
  if (!Array.isArray(recipes) || !regenerationContext?.rerollNonce) return recipes;

  const currentIDs = new Set((regenerationContext.currentRecipeIDs ?? []).map((value) => String(value ?? "").trim()).filter(Boolean));
  const currentTitleKeys = new Set(
    (regenerationContext.currentRecipes ?? [])
      .map((recipe) => normalizedRecipeTitleKey(recipe?.title))
      .filter(Boolean)
  );
  const recurringIDs = new Set((recurringRecipeIds ?? []).map((value) => String(value ?? "").trim()).filter(Boolean));
  if (!currentIDs.size && !currentTitleKeys.size) return recipes;

  const fresh = [];
  const repeated = [];

  for (const recipe of recipes) {
    const id = String(recipe?.id ?? "").trim();
    const titleKey = normalizedRecipeTitleKey(recipe?.title);
    const isRecurring = id && recurringIDs.has(id);
    const isCurrent = (id && currentIDs.has(id)) || (titleKey && currentTitleKeys.has(titleKey));
    if (isCurrent && !isRecurring) {
      repeated.push(recipe);
    } else {
      fresh.push(recipe);
    }
  }

  if (fresh.length < Math.max(1, minimumFreshCount)) {
    return recipes;
  }

  return [...fresh, ...repeated];
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
  const currentRecipeTitleSet = new Set(
    (regenerationContext.currentRecipes ?? [])
      .map((recipe) => normalizeSearchName(recipe.title))
      .filter(Boolean)
  );
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
    .filter((recipe) => {
      if (currentRecipeIDSet.has(String(recipe.id))) return false;
      const normalizedTitle = normalizeSearchName(recipe.title);
      if (!normalizedTitle) return true;
      if (currentRecipeTitleSet.has(normalizedTitle)) return false;
      return true;
    })
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
    savedRecipeRefresh: "familiar saved favorites and trusted meals",
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
    rerollNonce: regenerationContext?.rerollNonce ?? "",
    profile: summarizeProfileForIntent(profile),
  });
  const cached = readTimedCache(prepRegenerationIntentCache, cacheKey, PREP_REGENERATION_INTENT_CACHE_TTL_MS);
  if (cached) return cached;

  if (!openai) {
    return fallbackPrepRegenerationIntent(regenerationContext);
  }

  const fallback = fallbackPrepRegenerationIntent(regenerationContext);

  try {
    const completion = await withAIUsageContext({
      service: "recipe-api",
      operation: "prep_regeneration_intent",
      metadata: {
        current_recipe_count: regenerationContext?.currentRecipeIDs?.length ?? 0,
        focus: regenerationContext?.focus ?? "balanced",
      },
    }, () => withTimeout(openai.chat.completions.create({
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
    }), 9000));

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
      summary: "Lean harder into saved meals, favorite cuisines, and familiar ingredients.",
      boostTerms: ["familiar", "favorite", "saved meals", "comfort", "meal prep"],
      avoidTerms: [],
      noveltyBias: 0.12,
      overlapBias: 0.68,
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
      summary: "Lean harder into saved meals, favorite cuisines, and familiar ingredients.",
      boostTerms: ["trusted", "familiar", "saved meals", "favorite", "meal prep"],
      avoidTerms: [],
      noveltyBias: 0.12,
      overlapBias: 0.68,
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
      score += overlap * 10;
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
      score += scorePrepProfileAffinity(recipe, profile) * 0.72;
      score += overlap * 10;
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

function isUUIDLike(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value ?? "").trim());
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
  const seed = [
    profile?.trimmedPreferredName ?? "anon",
    "prep-rerank",
    (profile?.preferredCuisines ?? []).join(","),
    (profile?.favoriteFoods ?? []).join(","),
    regenerationContext?.rerollNonce ?? "",
  ].join("|");

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

function buildPrepCandidateCurationQuery(
  profile = null,
  regenerationContext = null,
  regenerationIntent = null,
  {
    savedRecipeTitles = [],
    recurringRecipeTitles = [],
  } = {}
) {
  const cuisines = (profile?.preferredCuisines ?? []).join(", ");
  const favoriteFoods = (profile?.favoriteFoods ?? []).join(", ");
  const favoriteFlavors = (profile?.favoriteFlavors ?? []).join(", ");
  const regenerationFocus = regenerationContext?.focus ?? null;
  const regenerationPrompt = String(regenerationContext?.userPrompt ?? "").trim();
  const regenerationSummary = regenerationIntent?.summary ?? null;
  const regenerationBoostTerms = (regenerationIntent?.boostTerms ?? []).join(", ");
  const regenerationAvoidTerms = (regenerationIntent?.avoidTerms ?? []).join(", ");
  const savedTitleHints = uniqueStrings(savedRecipeTitles).join(", ");
  const recurringTitleHints = uniqueStrings(recurringRecipeTitles).join(", ");

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
    savedTitleHints ? `Saved recipe titles that reveal what the user already likes: ${savedTitleHints}.` : null,
    recurringTitleHints ? `Recurring prep anchors that should come back often: ${recurringTitleHints}.` : null,
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
