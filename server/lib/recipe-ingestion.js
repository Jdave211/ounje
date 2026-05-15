import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFile as execFileCallback } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import dotenv from "dotenv";
import { nanoid } from "nanoid";
import { createWorker, OEM } from "tesseract.js";
import { expandFlavorTerms, extractIngredientSignals, scoreFlavorAlignment } from "./flavorgraph.js";
import { findRecipeStyleExamples } from "./recipe-corpus.js";
import { sanitizeDiscoverBrackets } from "./discover-brackets.js";
import { runYoutubeDl as ytdl } from "./youtube-dl-wrapper.js";
import { buildPlaywrightLaunchOptions } from "./playwright-runtime.js";
import { broadcastUserInvalidation } from "./realtime-invalidation.js";
import { acquireRedisLock, publishRedisJSON, readRedisJSON, releaseRedisLock, writeRedisJSON } from "./redis-cache.js";
import { invalidateUserBootstrapCache } from "./user-bootstrap-cache.js";
import { createLoggedOpenAI, isOpenAIQuotaError, recordExternalAICall, verifyAIUsageLoggingConfiguration, withAIUsageContext } from "./openai-usage-logger.js";

import {
  normalizeRecipeDetail as canonicalizeRecipeDetail,
  parseFirstInteger,
  parseIngredientObjects,
  parseInstructionSteps,
  sanitizeRecipeText,
} from "./recipe-detail-utils.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const RECIPE_IMAGE_BUCKET = process.env.RECIPE_IMAGE_BUCKET ?? "recipe-images";
const RECIPE_IMPORT_MEDIA_BUCKET = process.env.RECIPE_IMPORT_MEDIA_BUCKET ?? "recipe-import-media";
const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const RECIPE_INGESTION_MODEL = process.env.RECIPE_INGESTION_MODEL ?? "gpt-4o-mini";
const RECIPE_SEARCH_SYNTHESIS_MODEL = process.env.RECIPE_SEARCH_SYNTHESIS_MODEL ?? "gpt-5-nano";
const RECIPE_IMPORT_COMPLETION_MODEL = process.env.RECIPE_IMPORT_COMPLETION_MODEL ?? "gpt-5-nano";
const RECIPE_WEB_REFERENCE_MODEL = process.env.RECIPE_WEB_REFERENCE_MODEL ?? "gpt-5-nano";
const RECIPE_FINAL_VALIDATOR_MODEL = process.env.RECIPE_FINAL_VALIDATOR_MODEL ?? RECIPE_IMPORT_COMPLETION_MODEL;
const RECIPE_GATE_MODEL = process.env.RECIPE_GATE_MODEL ?? "gpt-5-nano";
const PHOTO_RECIPE_VISION_MODEL = process.env.PHOTO_RECIPE_VISION_MODEL ?? RECIPE_INGESTION_MODEL;
const PHOTO_MEAL_GATE_MODEL = process.env.PHOTO_MEAL_GATE_MODEL ?? PHOTO_RECIPE_VISION_MODEL;
const PHOTO_RECIPE_CLEANUP_MODEL = process.env.PHOTO_RECIPE_CLEANUP_MODEL ?? RECIPE_IMPORT_COMPLETION_MODEL;
const PHOTO_RECIPE_SONAR_MODEL = process.env.PHOTO_RECIPE_SONAR_MODEL ?? "sonar";
const PERPLEXITY_API_KEY = process.env.PERPLEXITY_API_KEY ?? "";
const PERPLEXITY_API_URL = process.env.PERPLEXITY_API_URL ?? "https://api.perplexity.ai/chat/completions";
const ENABLE_AI_WEB_REFERENCE_SEARCH = !["0", "false", "no", "off"].includes(String(process.env.RECIPE_ENABLE_AI_WEB_REFERENCE_SEARCH ?? "1").trim().toLowerCase());
const PLAYWRIGHT_FALLBACK_PATH = "/Users/davejaga/.openclaw/skills/playwright-scraper-skill/node_modules/playwright/index.js";
const DEFAULT_USER_AGENT =
  process.env.USER_AGENT ||
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36";
const SHORT_VIDEO_TRANSCRIBE_MODEL = process.env.SHORT_VIDEO_TRANSCRIBE_MODEL ?? "gpt-4o-mini-transcribe";
const MAX_SOCIAL_FRAME_COUNT = Math.max(2, Number.parseInt(process.env.RECIPE_INGESTION_MAX_SOCIAL_FRAMES ?? "4", 10) || 4);
const SOCIAL_METADATA_TIMEOUT_MS = Math.max(
  5_000,
  Number.parseInt(process.env.RECIPE_INGESTION_SOCIAL_METADATA_TIMEOUT_MS ?? "20000", 10) || 20_000
);
const SOCIAL_VIDEO_DOWNLOAD_TIMEOUT_MS = Math.max(
  5_000,
  Number.parseInt(process.env.RECIPE_INGESTION_SOCIAL_VIDEO_DOWNLOAD_TIMEOUT_MS ?? "45000", 10) || 45_000
);
const SOCIAL_FETCH_TIMEOUT_MS = Math.max(
  3_000,
  Number.parseInt(process.env.RECIPE_INGESTION_SOCIAL_FETCH_TIMEOUT_MS ?? "10000", 10) || 10_000
);
const SOCIAL_FRAME_PROBE_TIMEOUT_MS = Math.max(
  2_000,
  Number.parseInt(process.env.RECIPE_INGESTION_SOCIAL_FRAME_PROBE_TIMEOUT_MS ?? "5000", 10) || 5_000
);
const SOCIAL_FRAME_EXTRACT_TIMEOUT_MS = Math.max(
  3_000,
  Number.parseInt(process.env.RECIPE_INGESTION_SOCIAL_FRAME_EXTRACT_TIMEOUT_MS ?? "7000", 10) || 7_000
);
const SOCIAL_AUDIO_EXTRACT_TIMEOUT_MS = Math.max(
  3_000,
  Number.parseInt(process.env.RECIPE_INGESTION_SOCIAL_AUDIO_EXTRACT_TIMEOUT_MS ?? "10000", 10) || 10_000
);
const SOCIAL_OCR_FRAME_TIMEOUT_MS = Math.max(
  3_000,
  Number.parseInt(process.env.RECIPE_INGESTION_SOCIAL_OCR_FRAME_TIMEOUT_MS ?? "8000", 10) || 8_000
);
const RECIPE_SEARCH_MAX_LINKS = Math.max(2, Math.min(Number.parseInt(process.env.RECIPE_SEARCH_MAX_LINKS ?? "3", 10) || 3, 6));
const RECIPE_REFERENCE_MAX_SOURCES = Math.max(2, Math.min(Number.parseInt(process.env.RECIPE_REFERENCE_MAX_SOURCES ?? "3", 10) || 3, 3));
const RECIPE_EXTRACTION_MAX_IMAGE_INPUTS = Math.max(
  1,
  Math.min(Number.parseInt(process.env.RECIPE_EXTRACTION_MAX_IMAGE_INPUTS ?? "3", 10) || 3, 4)
);
const OCR_PROMPT_MIN_CONFIDENCE = Math.max(
  0,
  Math.min(Number.parseFloat(process.env.RECIPE_INGESTION_OCR_PROMPT_MIN_CONFIDENCE ?? "45") || 45, 100)
);
const RECIPE_INGESTION_WORKER_CONCURRENCY = Math.max(
  1,
  Number.parseInt(process.env.RECIPE_INGESTION_WORKER_CONCURRENCY ?? "2", 10) || 2
);
const RECIPE_INGESTION_HEARTBEAT_MS = Math.max(
  15_000,
  Number.parseInt(process.env.RECIPE_INGESTION_HEARTBEAT_MS ?? "60000", 10) || 60_000
);
const REDIS_DISABLED_FOR_INGESTION_LOCK = ["1", "true", "yes", "on"].includes(
  String(process.env.REDIS_DISABLED ?? "").trim().toLowerCase()
);
const execFile = promisify(execFileCallback);

async function maybeGenerateImportedRecipeImage(recipe = null) {
  const heroImageURL = cleanURL(recipe?.hero_image_url ?? recipe?.discover_card_image_url ?? null);
  const cardImageURL = cleanURL(recipe?.discover_card_image_url ?? heroImageURL ?? null);
  return {
    hero_image_url: heroImageURL,
    discover_card_image_url: cardImageURL,
  };
}

const openai = OPENAI_API_KEY ? createLoggedOpenAI({ apiKey: OPENAI_API_KEY, service: "recipe-ingestion" }) : null;
verifyAIUsageLoggingConfiguration({ service: "recipe-ingestion" });
let ocrWorkerPromise = null;
let recipeImageBucketReadyPromise = null;

function withTimeout(promise, timeoutMs, label) {
  let timeoutID;
  const timeout = new Promise((_, reject) => {
    timeoutID = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms.`)), timeoutMs);
  });

  return Promise.race([promise, timeout]).finally(() => {
    if (timeoutID) clearTimeout(timeoutID);
  });
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, Number(ms) || 0)));
}

async function timeRecipeImportStage(stage, { jobID = null, metadata = null } = {}, fn) {
  const startedAt = Date.now();
  const context = {
    job_id: jobID ?? null,
    ...(metadata && typeof metadata === "object" ? metadata : {}),
  };
  console.info(`[recipe-ingestion][timing] ${stage} start`, context);
  try {
    const result = await fn();
    console.info(`[recipe-ingestion][timing] ${stage} done`, {
      ...context,
      duration_ms: Date.now() - startedAt,
    });
    return result;
  } catch (error) {
    console.warn(`[recipe-ingestion][timing] ${stage} failed`, {
      ...context,
      duration_ms: Date.now() - startedAt,
      error: errorSummary(error),
    });
    throw error;
  }
}

function socialYTDLOptions(overrides = {}) {
  return {
    noWarnings: true,
    noCallHome: true,
    noCheckCertificates: true,
    preferFreeFormats: true,
    socketTimeout: 15,
    retries: 1,
    fragmentRetries: 1,
    extractorRetries: 1,
    ...overrides,
  };
}

function ytdlExecOptions(timeoutMs) {
  return {
    timeout: timeoutMs,
    killSignal: "SIGKILL",
  };
}

async function fetchWithTimeout(url, options = {}, timeoutMs = SOCIAL_FETCH_TIMEOUT_MS, label = "fetch") {
  const controller = new AbortController();
  const timeoutID = setTimeout(() => controller.abort(new Error(`${label} timed out after ${timeoutMs}ms.`)), timeoutMs);
  try {
    return await fetch(url, {
      ...options,
      signal: options.signal ?? controller.signal,
    });
  } finally {
    clearTimeout(timeoutID);
  }
}

async function execFileWithTimeout(command, args = [], timeoutMs = 10_000) {
  return execFile(command, args, {
    timeout: timeoutMs,
    killSignal: "SIGKILL",
  });
}

// In-memory canonical URL cache — avoids a DB round-trip when the same URL
// has already been imported in this process lifetime.
const CANONICAL_IMPORT_CACHE_MAX = 500;
const CANONICAL_IMPORT_CACHE_TTL_MS = 60 * 60 * 1000; // 1 hour
const WARM_RECIPE_DETAIL_CACHE_TTL_SECONDS = 24 * 60 * 60;
const IMPORT_ENQUEUE_LOCK_TTL_SECONDS = 15;
const IMPORT_PROCESS_LOCK_TTL_SECONDS = 30 * 60;
const SOURCE_METADATA_CACHE_TTL_SECONDS = 6 * 60 * 60;
const GLOBAL_IMPORT_CACHE_NAMESPACE = "__global__";
const RECIPE_IMPORT_WAKE_CHANNEL = "ounje:recipe-ingestion:queued";
const _canonicalImportCache = new Map();

function _canonicalImportCacheKey(userID, canonicalURL, dedupeKey) {
  const ns = userID ? String(userID) : "anon";
  if (canonicalURL) return `${ns}:url:${canonicalURL}`;
  if (dedupeKey) return `${ns}:dk:${dedupeKey}`;
  return null;
}

function _canonicalImportRedisCacheKey(key) {
  if (!key) return null;
  const digest = crypto.createHash("sha256").update(String(key)).digest("hex");
  return `ounje:canonical-import:${digest}`;
}

function _sharedRedisCacheKey(namespace, key) {
  if (!namespace || !key) return null;
  const digest = crypto.createHash("sha256").update(String(key)).digest("hex");
  return `ounje:${namespace}:${digest}`;
}

async function warmRecipeDetailCache({ userID = null, recipeID = null, recipeDetail = null } = {}) {
  const normalizedRecipeID = normalizeText(recipeID);
  if (!normalizedRecipeID || !recipeDetail) return;

  const detailCacheKey = normalizedRecipeID.startsWith("uir_")
    ? `user:${normalizeText(userID)}:${normalizedRecipeID}`
    : `public:${normalizedRecipeID}`;
  if (normalizedRecipeID.startsWith("uir_") && !normalizeText(userID)) return;

  await writeRedisJSON(
    _sharedRedisCacheKey("recipe-detail", detailCacheKey),
    { recipe: canonicalizeRecipeDetail({ ...recipeDetail, id: normalizedRecipeID }) },
    WARM_RECIPE_DETAIL_CACHE_TTL_SECONDS
  );
}

function recipeImportLockKey(kind, key) {
  if (!kind || !key) return null;
  const digest = crypto.createHash("sha256").update(String(key)).digest("hex");
  return `ounje:recipe-import:${kind}:${digest}`;
}

function sourceMetadataCacheKey(kind, sourceURL) {
  const normalizedURL = cleanURL(sourceURL);
  if (!kind || !normalizedURL) return null;
  const digest = crypto.createHash("sha256").update(normalizedURL).digest("hex");
  return `ounje:source-metadata:${kind}:${digest}`;
}

function compactYtdlMetadataForCache(info = null) {
  if (!info || typeof info !== "object") return null;
  const compactSubtitleBucket = (bucket) => {
    if (!bucket || typeof bucket !== "object") return {};
    return Object.fromEntries(
      Object.entries(bucket).slice(0, 12).map(([language, tracks]) => [
        language,
        Array.isArray(tracks)
          ? tracks.slice(0, 4).map((track) => ({
              ext: track?.ext ?? null,
              url: cleanURL(track?.url ?? null),
            })).filter((track) => track.url)
          : [],
      ])
    );
  };
  return {
    id: info.id ?? null,
    title: info.title ?? null,
    description: info.description ?? null,
    uploader: info.uploader ?? null,
    uploader_id: info.uploader_id ?? null,
    uploader_url: info.uploader_url ?? null,
    channel: info.channel ?? null,
    channel_url: info.channel_url ?? null,
    webpage_url: cleanURL(info.webpage_url ?? null),
    original_url: cleanURL(info.original_url ?? null),
    url: cleanURL(info.url ?? null),
    webpage_url_basename: info.webpage_url_basename ?? null,
    duration: info.duration ?? null,
    upload_date: info.upload_date ?? null,
    thumbnails: Array.isArray(info.thumbnails) ? info.thumbnails.slice(-12) : [],
    subtitles: compactSubtitleBucket(info.subtitles),
    automatic_captions: compactSubtitleBucket(info.automatic_captions),
  };
}

function compactPageSignalsForCache(pageSignals = null) {
  if (!pageSignals || typeof pageSignals !== "object") return null;
  return {
    source_type: pageSignals.source_type ?? "web",
    platform: pageSignals.platform ?? "web",
    source_url: cleanURL(pageSignals.source_url ?? null),
    canonical_url: cleanURL(pageSignals.canonical_url ?? pageSignals.source_url ?? null),
    title: normalizeText(pageSignals.title ?? ""),
    meta_title: normalizeText(pageSignals.meta_title ?? ""),
    meta_description: normalizeText(pageSignals.meta_description ?? ""),
    hero_image_url: cleanURL(pageSignals.hero_image_url ?? null),
    attached_video_url: cleanURL(pageSignals.attached_video_url ?? null),
    site_name: normalizeText(pageSignals.site_name ?? ""),
    author_name: normalizeText(pageSignals.author_name ?? ""),
    ingredient_candidates: Array.isArray(pageSignals.ingredient_candidates) ? pageSignals.ingredient_candidates.slice(0, 80) : [],
    instruction_candidates: Array.isArray(pageSignals.instruction_candidates) ? pageSignals.instruction_candidates.slice(0, 80) : [],
    page_image_urls: Array.isArray(pageSignals.page_image_urls) ? pageSignals.page_image_urls.slice(0, 12) : [],
    body_text: normalizeText(pageSignals.body_text ?? "", 6000),
    structured_recipe: pageSignals.structured_recipe ?? null,
  };
}

async function fetchYtdlMetadataCached(sourceURL, { options = {}, timeoutMs = SOCIAL_METADATA_TIMEOUT_MS, label = "metadata resolve", cacheKind = "ytdl" } = {}) {
  const cacheKey = sourceMetadataCacheKey(cacheKind, sourceURL);
  const cached = await readRedisJSON(cacheKey);
  if (cached) return cached;

  const metadata = await withTimeout(
    ytdl(sourceURL, socialYTDLOptions({
      dumpSingleJson: true,
      skipDownload: true,
      ...options,
    }), ytdlExecOptions(timeoutMs)),
    timeoutMs,
    label
  );
  const compact = compactYtdlMetadataForCache(metadata);
  if (compact) {
    void writeRedisJSON(cacheKey, compact, SOURCE_METADATA_CACHE_TTL_SECONDS);
  }
  return metadata;
}

function _setCanonicalImportCache(userID, canonicalURL, dedupeKey, job) {
  const key = _canonicalImportCacheKey(userID, canonicalURL, dedupeKey);
  if (!key || !job) return;
  _canonicalImportCache.delete(key); // refresh insertion order for LRU
  _canonicalImportCache.set(key, { job, cachedAt: Date.now() });
  void writeRedisJSON(_canonicalImportRedisCacheKey(key), job, Math.ceil(CANONICAL_IMPORT_CACHE_TTL_MS / 1000));
  if (_canonicalImportCache.size > CANONICAL_IMPORT_CACHE_MAX) {
    _canonicalImportCache.delete(_canonicalImportCache.keys().next().value);
  }
}

async function _getCanonicalImportCache(userID, canonicalURL, dedupeKey) {
  const key = _canonicalImportCacheKey(userID, canonicalURL, dedupeKey);
  if (!key) return null;
  const entry = _canonicalImportCache.get(key);
  if (entry) {
    if (Date.now() - entry.cachedAt <= CANONICAL_IMPORT_CACHE_TTL_MS) {
      return entry.job;
    }
    _canonicalImportCache.delete(key);
  }

  const redisJob = await readRedisJSON(_canonicalImportRedisCacheKey(key));
  if (!redisJob) return null;
  _canonicalImportCache.set(key, { job: redisJob, cachedAt: Date.now() });
  return redisJob;
}

function withRecipeAIStage(operation, fn) {
  return withAIUsageContext({ operation }, fn);
}

function chatCompletionTemperatureParams(model, temperature) {
  const normalized = String(model ?? "").trim().toLowerCase();
  if (normalized.startsWith("gpt-5")) return {};
  return Number.isFinite(Number(temperature)) ? { temperature } : {};
}

function chatCompletionLatencyParams(model, maxCompletionTokens = null) {
  const normalized = String(model ?? "").trim().toLowerCase();
  const tokenBudget = Number(maxCompletionTokens);
  if (normalized.startsWith("gpt-5")) {
    return {
      reasoning_effort: "minimal",
      ...(Number.isFinite(tokenBudget) && tokenBudget > 0 ? { max_completion_tokens: Math.floor(tokenBudget) } : {}),
    };
  }
  return Number.isFinite(tokenBudget) && tokenBudget > 0 ? { max_tokens: Math.floor(tokenBudget) } : {};
}

const PUBLIC_RECIPE_TABLE_CONFIG = {
  recipeTable: "recipes",
  ingredientTable: "recipe_ingredients",
  stepTable: "recipe_steps",
  stepIngredientTable: "recipe_step_ingredients",
  recipePrefix: "recipe_",
  ingredientPrefix: "ri_",
  stepPrefix: "rs_",
  stepIngredientPrefix: "rsi_",
};

const USER_IMPORTED_RECIPE_TABLE_CONFIG = {
  recipeTable: "user_import_recipes",
  ingredientTable: "user_import_recipe_ingredients",
  stepTable: "user_import_recipe_steps",
  stepIngredientTable: "user_import_recipe_step_ingredients",
  recipePrefix: "uir_",
  ingredientPrefix: "uiri_",
  stepPrefix: "uirs_",
  stepIngredientPrefix: "uirsi_",
};

const RECIPE_ROW_SELECT =
  "id,title,description,author_name,author_handle,author_url,source,source_platform,category,subcategory,recipe_type,skill_level,cook_time_text,servings_text,serving_size_text,daily_diet_text,est_cost_text,est_calories_text,carbs_text,protein_text,fats_text,calories_kcal,protein_g,carbs_g,fat_g,prep_time_minutes,cook_time_minutes,hero_image_url,discover_card_image_url,recipe_url,original_recipe_url,attached_video_url,detail_footnote,image_caption,source_provenance_json,dietary_tags,flavor_tags,cuisine_tags,occasion_tags,main_protein,cook_method,published_date,discover_brackets,discover_brackets_enriched_at,ingredients_json,steps_json,servings_count";
const RECIPE_CARD_SELECT =
  "id,title,description,author_name,author_handle,category,recipe_type,cook_time_text,cook_time_minutes,published_date,discover_card_image_url,hero_image_url,recipe_url,source,discover_brackets";

const RECIPE_EXTRACTION_SYSTEM_PROMPT = `You turn recipe source material into normalized Ounje recipe JSON.

Rules:
- Return JSON only.
- Never hallucinate ingredients, quantities, steps, nutrition, or timings that are not supported by the source.
- Preserve source provenance and media links when available.
- Prefer explicit quantities exactly as shown in the source.
- If a field is unknown, use null, an empty string, or an empty array.
- If a source is weak or incomplete, keep the recipe partial and set review flags instead of inventing detail.
- Ingredients must be returned as structured objects with display_name and quantity_text.
- Never collapse distinct grocery items into a generic bucket label like "spices", "seasoning", "sauce", or "garnish" when the source exposes the individual items.
- Preserve concrete ingredients such as honey, paprika, chili powder, garlic powder, and similar shoppable items as their own ingredient rows.
- Steps must be sequential and cookable. If step-linked ingredients are visible, include them under the step.
- Keep titles and descriptions clean and consumer-facing.
- Do not include commentary outside the JSON object.`;

const RECIPE_CONCEPT_SYSTEM_PROMPT = `You turn a recipe idea into a realistic, structured Ounje recipe JSON.

Rules:
- Return JSON only.
- Use the user's prompt, creation-intent classification, web references, and nearby example recipes as grounding. Do not copy reference text.
- Build a coherent recipe that feels like a real recipe Ounje would save.
- If the user asks to combine recipes, act like a chef: preserve the recognizable base dishes while making one viable home-cookable method.
- Be conservative with quantities and timings. If a detail is not easy to infer, leave it null.
- Estimate practical per-serving macros when ingredient quantities and serving count are clear enough; otherwise leave nutrition null.
- Ingredients must be practical and cookable.
- Steps must be sequential, specific, and usable.
- Never fabricate source provenance. This is a direct_input prompt-generated recipe, not a scraped web recipe.
- Do not include commentary outside the JSON object.`;

const RECIPE_LIGHT_FILL_SYSTEM_PROMPT = `You are filling only low-risk gaps in an already structured recipe.

Rules:
- Return JSON only.
- Only fill fields that are directly supported by the supplied evidence.
- Allowed fields to fill:
  - servings_text
  - servings_count
  - prep_time_minutes
  - cook_time_minutes
  - cook_time_text
  - skill_level
  - est_calories_text
  - calories_kcal
  - protein_g
  - carbs_g
  - fat_g
  - missing ingredient quantity_text values
- Do not change title, description, source, recipe type, cuisine, main protein, cook method, or steps.
- If evidence is weak, return null for that field.
- If the dish identity, serving count, and ingredient quantities are clear enough, provide conservative best-guess per-serving calories_kcal, protein_g, carbs_g, and fat_g for app display.
- Never guess cooking method, cuisine, or protein.
- Never add ingredient rows that do not already exist.
- Only fill ingredient quantities if the quantity is explicit or trivially implied by the source evidence.
- When filling ingredient quantities, preserve the current ingredient display_name exactly and only change quantity_text.
- Do not include commentary outside the JSON object.`;

const RECIPE_SECONDARY_FILL_SYSTEM_PROMPT = `You are doing the final low-stakes cleanup pass on an already structured recipe.

Rules:
- Return JSON only.
- Only fill small missing details that do not change the identity of the recipe.
- Allowed fields to fill:
  - servings_text
  - servings_count
  - prep_time_minutes
  - cook_time_minutes
  - cook_time_text
  - skill_level
  - est_calories_text
  - calories_kcal
  - protein_g
  - carbs_g
  - fat_g
  - missing ingredient quantity_text values for obvious, common, countable ingredients
- Do not change title, description, source, recipe type, cuisine, main protein, cook method, ingredient names, or steps.
- If a value is not clearly supported by the supplied evidence, return null.
- Calories may be estimated if the recipe clearly points to a common dish and the estimate is conservative.
- Per-serving protein_g, carbs_g, and fat_g may be estimated when ingredient quantities and serving count are clear enough. Use null only when the recipe is too ambiguous.
- Ingredient quantities may be inferred only when the source makes the amount obvious or trivially implied.
- When filling ingredient quantities, preserve the current ingredient display_name exactly and only change quantity_text.
- Do not include commentary outside the JSON object.`;

const RECIPE_REPAIR_SYSTEM_PROMPT = `You repair sparse imported recipes using the source evidence plus nearby grounded examples.

Rules:
- Return JSON only.
- Preserve the dish identity implied by the source title, description, transcript, captions, and images.
- Use nearby examples only for structure, realism, and completion, not as text to copy verbatim.
- Be conservative with unsupported details, but do not leave the recipe near-empty when the source clearly indicates a common dish.
- Fill missing ingredients and steps when the source strongly suggests them.
- Never invent nutrition unless it is directly supplied.
- Never fabricate source provenance.
- Do not include commentary outside the JSON object.`;

const RECIPE_SEARCH_SYSTEM_PROMPT = `You are building one grounded, consensus recipe from multiple scraped recipe pages for the same dish.

Rules:
- Return JSON only.
- Use only details supported by the scraped pages.
- Prefer ingredient, timing, and step details that appear across multiple sources.
- If sources disagree, choose the most common or most plausible mainstream version and avoid niche embellishments.
- Never invent ingredients, times, or techniques that are not supported by at least one source.
- Keep the final recipe coherent and cookable.
- Match Ounje / Julienne style: clean title, concise description, structured ingredients, sequential steps.
- Include a quality_flags array and review_reason if the source set is weak or contradictory.
- Do not include commentary outside the JSON object.`;

const RECIPE_SEARCH_VERIFY_SYSTEM_PROMPT = `You verify a synthesized recipe against scraped recipe source evidence.

Rules:
- Return JSON only.
- Remove or downgrade claims that are not supported by the supplied sources.
- Preserve the dish identity.
- Prefer consensus details.
- If the recipe is strong and grounded, keep it mostly intact.
- If an ingredient, measurement, or step appears unsupported, either delete it or soften it rather than hallucinating a justification.
- Do not include commentary outside the JSON object.`;

const RECIPE_CREATE_INTENT_SYSTEM_PROMPT = `You classify a user's "create recipe" request before recipe generation.

Intent labels:
- base_recipe: the user primarily wants a normal recipe for one known dish.
- fusion_recipe: the user wants to combine, mash up, hybridize, or reconcile multiple dishes/recipes/styles.
- custom_recipe: the user gives constraints, ingredients, macros, diet, mood, or meal-prep goals and wants a new viable recipe.
- direct_recipe_text: the user pasted an existing recipe with ingredients/steps that should be extracted, not invented.

Rules:
- Return JSON only.
- Use fusion_recipe when the user asks to combine different recipes, create a viable version of two dishes together, or make an "X meets Y" recipe.
- Use base_recipe for short dish names like "chicken tikka masala" or "banana bread".
- Use custom_recipe for "make/create/generate" prompts with dietary, macro, ingredient, or meal-prep constraints.
- Include 1-3 web search queries when web references would improve grounding. For fusion_recipe, include separate base-dish queries and a combined query.
- Do not include commentary outside the JSON object.`;

const RECIPE_IMPORT_COMPLETION_SYSTEM_PROMPT = `You are the final import completion pass for Ounje recipes.

Rules:
- Return JSON only.
- Preserve the identity of the imported dish from the original source evidence.
- Use web recipe references only to complete weak or missing structure, not to replace the dish with something adjacent.
- Improve ingredient sizing, timings, servings, nutrition text, and missing or sparse steps when the imported recipe is clearly incomplete.
- For short social videos with weak/no transcript, infer useful mainstream ingredient quantities when the dish identity is clear and web references support a plausible common range.
- Best-guess quantities are allowed for common dishes, but keep them conservative and ordinary for the stated serving size.
- Do not collapse distinct grocery items into generic buckets. If the source or web references expose individual ingredients, keep them as individual shoppable rows instead of "spices", "seasoning", "sauce", or similar umbrella labels.
- Preserve ingredients like honey, paprika, chili powder, garlic powder, fresh herbs, and other concrete grocery items explicitly when the source supports them.
- If web references disagree, prefer the most mainstream consensus version that still matches the original source.
- Never add niche embellishments that are not needed to make the recipe cookable.
- Do not remove strong source-supported details from the imported recipe.
- If a quantity would be arbitrary even for a mainstream version of this dish, leave it null rather than forcing certainty.
- Add quality_flags entries for inferred work, especially quantities_inferred when you fill missing quantity_text values by inference.
- Do not include commentary outside the JSON object.`;

const RECIPE_FINAL_VALIDATOR_SYSTEM_PROMPT = `You are the final recipe consistency validator for Ounje imports.

Rules:
- Return JSON only.
- Fix only concrete consistency issues in the provided recipe. Do not rewrite for style alone.
- Preserve source-supported dish identity, title, cuisine, and author/source metadata.
- Ensure ingredients, quantities, and steps agree with each other.
- If a step mentions an ingredient that is not listed, either add a conservative ingredient only when clearly necessary, or rewrite the step to use an already listed equivalent.
- If a step mentions a listed ingredient, keep that ingredient linked in the step's ingredients array with the same practical quantity.
- Prefer not to add non-shopping pantry liquids like water unless the recipe would be confusing without it.
- Replace vague or technically wrong cooking verbs with practical cooking actions.
- Keep steps concise, sequential, and cookable.
- Keep ingredient quantities practical for the stated servings.
- Return compact repairs only: include full ingredients or steps arrays only when those arrays need changes, and omit unchanged fields.
- Do not include commentary outside the JSON object.`;

const RECIPE_GATE_SYSTEM_PROMPT = `You decide whether imported content is actually a recipe.

Rules:
- Return JSON only.
- Accept only if the content is clearly about making or cooking a dish.
- Reject if it is lifestyle content, restaurant content, comedy, vlog content, product promo, general food inspiration with no real recipe, or unrelated media.
- If accepted, provide a short reason.
- If rejected, provide a short reason that can be shown in logs.
- Do not include commentary outside the JSON object.`;

function assertSupabaseConfig() {
  if (!SUPABASE_URL || !(SUPABASE_SERVICE_ROLE_KEY || SUPABASE_ANON_KEY)) {
    throw new Error("Recipe ingestion requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY or SUPABASE_ANON_KEY.");
  }
}

function normalizeText(value) {
  return String(value ?? "")
    .replace(/\s+/g, " ")
    .trim();
}

function finiteNumberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function normalizeKey(value) {
  return normalizeText(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function htmlDecode(value) {
  return String(value ?? "")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => {
      const codePoint = Number.parseInt(hex, 16);
      return Number.isFinite(codePoint) ? String.fromCodePoint(codePoint) : " ";
    })
    .replace(/&#(\d+);/g, (_, raw) => {
      const codePoint = Number.parseInt(raw, 10);
      return Number.isFinite(codePoint) ? String.fromCodePoint(codePoint) : " ";
    })
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, " ");
}

function errorSummary(error) {
  if (!error) return null;
  return {
    name: normalizeText(error.name ?? "") || "Error",
    message: normalizeText(error.message ?? error) || "Unknown error",
    code: normalizeText(error.code ?? "") || null,
  };
}

function uniqueStrings(values) {
  const seen = new Set();
  const result = [];
  for (const value of values ?? []) {
    const normalized = normalizeText(value);
    if (!normalized) continue;
    const key = normalized.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(normalized);
  }
  return result;
}

function firstNormalizedText(...values) {
  for (const value of values) {
    const normalized = normalizeText(value);
    if (normalized) return normalized;
  }
  return null;
}

function normalizeCreatorHandle(value) {
  const normalized = normalizeText(value);
  if (!normalized) return null;
  const withoutURL = normalized
    .replace(/^https?:\/\/(?:www\.)?(?:tiktok\.com|instagram\.com|youtube\.com|youtu\.be)\/@?/i, "")
    .replace(/[/?#].*$/g, "")
    .trim();
  const cleaned = withoutURL
    .replace(/^@+/, "")
    .replace(/\s+/g, "")
    .trim();
  if (!cleaned) return null;
  if (/^\d{8,}$/.test(cleaned)) return null;
  if (!/[a-z_]/i.test(cleaned)) return null;
  return cleaned.startsWith("@") ? cleaned : `@${cleaned}`;
}

function normalizeCreatorHandleFromURL(value) {
  const raw = normalizeText(value);
  if (!raw) return null;
  try {
    const parsed = new URL(raw);
    const pathParts = parsed.pathname.split("/").map((part) => part.trim()).filter(Boolean);
    const atPart = pathParts.find((part) => part.startsWith("@"));
    if (atPart) return normalizeCreatorHandle(atPart);
    if (parsed.hostname.includes("instagram.com") || parsed.hostname.includes("tiktok.com")) {
      return normalizeCreatorHandle(pathParts[0] ?? "");
    }
    return null;
  } catch {
    return normalizeCreatorHandle(raw);
  }
}

function firstCreatorHandle(...values) {
  for (const value of values) {
    const normalized = normalizeCreatorHandle(value) ?? normalizeCreatorHandleFromURL(value);
    if (normalized) return normalized;
  }
  return null;
}

function normalizeStringArray(value, limit = 12) {
  if (Array.isArray(value)) return uniqueStrings(value).slice(0, limit);
  const normalized = normalizeText(value);
  return normalized ? [normalized].slice(0, limit) : [];
}

function isUserImportedRecipeID(value) {
  return String(value ?? "").trim().startsWith(USER_IMPORTED_RECIPE_TABLE_CONFIG.recipePrefix);
}

function tableConfigForRecipeID(recipeID) {
  return isUserImportedRecipeID(recipeID) ? USER_IMPORTED_RECIPE_TABLE_CONFIG : PUBLIC_RECIPE_TABLE_CONFIG;
}

function tableConfigForStepID(stepID) {
  return String(stepID ?? "").trim().startsWith(USER_IMPORTED_RECIPE_TABLE_CONFIG.stepPrefix)
    ? USER_IMPORTED_RECIPE_TABLE_CONFIG
    : PUBLIC_RECIPE_TABLE_CONFIG;
}

function uniqueBy(values, keyBuilder) {
  const seen = new Set();
  const result = [];
  for (const value of values ?? []) {
    const key = keyBuilder(value);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    result.push(value);
  }
  return result;
}

function isProbablyURL(value) {
  return /^https?:\/\//i.test(String(value ?? "").trim());
}

function hostForURL(raw) {
  try {
    return new URL(raw).hostname.toLowerCase();
  } catch {
    return "";
  }
}

function cleanURL(raw) {
  try {
    const url = new URL(String(raw ?? "").trim());
    url.hash = "";
    const host = url.hostname.toLowerCase();
    if (url.hostname.includes("youtube.com") && url.searchParams.has("v")) {
      return `https://www.youtube.com/watch?v=${url.searchParams.get("v")}`;
    }
    if (url.hostname === "youtu.be") {
      const id = url.pathname.split("/").filter(Boolean)[0] ?? "";
      return id ? `https://www.youtube.com/watch?v=${id}` : url.toString();
    }
    if (host.includes("tiktok.com")) {
      const videoMatch = url.pathname.match(/^\/(@[^/]+)\/video\/(\d+)/i);
      if (videoMatch) {
        return `https://www.tiktok.com/${videoMatch[1]}/video/${videoMatch[2]}`;
      }
    }
    const removable = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "si", "feature", "_t", "_r"];
    removable.forEach((key) => url.searchParams.delete(key));
    return url.toString();
  } catch {
    return normalizeText(raw) || null;
  }
}

function canonicalImportIdentityForURL(raw) {
  const cleaned = cleanURL(raw);
  if (!cleaned || !isProbablyURL(cleaned)) return null;

  try {
    const url = new URL(cleaned);
    const host = url.hostname.toLowerCase();
    if (host.includes("tiktok.com")) {
      const videoMatch = url.pathname.match(/^\/@[^/]+\/video\/(\d+)/i);
      if (videoMatch?.[1]) return `tiktok:video:${videoMatch[1]}`;
    }
    if (host === "youtu.be") {
      const id = url.pathname.split("/").filter(Boolean)[0];
      if (id) return `youtube:video:${id}`;
    }
    if (host.includes("youtube.com")) {
      const id = url.searchParams.get("v");
      if (id) return `youtube:video:${id}`;
    }
    if (host.includes("instagram.com")) {
      const match = url.pathname.match(/^\/(reel|p|tv)\/([^/?#]+)/i);
      if (match?.[1] && match?.[2]) return `instagram:${match[1].toLowerCase()}:${match[2]}`;
    }
  } catch {
    return null;
  }

  return null;
}

function canonicalImportIdentityForRequest({ sourceUrl = null, canonicalUrl = null } = {}) {
  return canonicalImportIdentityForURL(canonicalUrl) ?? canonicalImportIdentityForURL(sourceUrl);
}

function urlLookupVariants(...values) {
  const variants = [];
  for (const value of values) {
    const cleaned = cleanURL(value);
    if (!cleaned || !isProbablyURL(cleaned)) continue;
    variants.push(cleaned);

    try {
      const url = new URL(cleaned);
      if (!url.search && url.pathname && url.pathname !== "/") {
        const originalPath = url.pathname;
        url.pathname = originalPath.endsWith("/") ? originalPath.replace(/\/+$/, "") : `${originalPath}/`;
        variants.push(url.toString());
      }
    } catch {
      // Ignore malformed variants; cleanURL already returned the canonical candidate.
    }
  }
  return uniqueStrings(variants).filter(Boolean);
}

function isRecipeImageStorageURL(raw) {
  const normalized = cleanURL(raw);
  if (!normalized || !SUPABASE_URL) return false;
  return normalized.startsWith(`${SUPABASE_URL}/storage/v1/object/public/${RECIPE_IMAGE_BUCKET}/`);
}

function guessImageExtension(contentType = "", sourceURL = "") {
  const loweredContentType = String(contentType ?? "").toLowerCase();
  if (loweredContentType.includes("png")) return "png";
  if (loweredContentType.includes("webp")) return "webp";
  if (loweredContentType.includes("gif")) return "gif";
  if (loweredContentType.includes("jpeg") || loweredContentType.includes("jpg")) return "jpg";

  const loweredURL = String(sourceURL ?? "").toLowerCase();
  if (loweredURL.includes(".png")) return "png";
  if (loweredURL.includes(".webp")) return "webp";
  if (loweredURL.includes(".gif")) return "gif";
  if (loweredURL.includes(".jpeg") || loweredURL.includes(".jpg")) return "jpg";
  return "jpg";
}

function recipeImageStoragePath({ recipeKey, imageRole, sourceURL, contentType }) {
  const safeRecipeKey = normalizeText(recipeKey || "recipe").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "recipe";
  const safeRole = normalizeText(imageRole || "hero").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "hero";
  const digest = crypto.createHash("sha256").update(String(sourceURL ?? "")).digest("hex").slice(0, 24);
  const ext = guessImageExtension(contentType, sourceURL);
  return `${safeRecipeKey}/${safeRole}/${digest}.${ext}`;
}

async function ensureRecipeImageBucket() {
  if (!SUPABASE_URL || !RECIPE_IMAGE_BUCKET || !SUPABASE_SERVICE_ROLE_KEY) return false;
  if (!recipeImageBucketReadyPromise) {
    recipeImageBucketReadyPromise = (async () => {
      const headers = {
        apikey: SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        "Content-Type": "application/json",
      };

      try {
        const existingResponse = await fetch(
          `${SUPABASE_URL}/storage/v1/bucket/${encodeURIComponent(RECIPE_IMAGE_BUCKET)}`,
          { headers }
        );

        if (existingResponse.ok) return true;
        if (existingResponse.status !== 404) return false;

        const createResponse = await fetch(`${SUPABASE_URL}/storage/v1/bucket`, {
          method: "POST",
          headers,
          body: JSON.stringify({
            id: RECIPE_IMAGE_BUCKET,
            name: RECIPE_IMAGE_BUCKET,
            public: true,
          }),
        });

        return createResponse.ok;
      } catch {
        return false;
      }
    })();
  }

  return recipeImageBucketReadyPromise;
}

async function persistRecipeImageToStorage(sourceURL, { recipeKey, imageRole = "hero", accessToken = null } = {}) {
  const normalized = cleanURL(sourceURL);
  if (!normalized) return null;
  if (isRecipeImageStorageURL(normalized)) return normalized;
  if (!SUPABASE_URL || !RECIPE_IMAGE_BUCKET) return normalized;

  const storageBearer = (normalizeText(accessToken ?? "") || SUPABASE_SERVICE_ROLE_KEY || SUPABASE_ANON_KEY).trim();
  if (!storageBearer) return normalized;

  try {
    await ensureRecipeImageBucket();
    const response = await fetch(normalized, {
      redirect: "follow",
      headers: {
        "user-agent": DEFAULT_USER_AGENT,
        accept: "image/*,*/*;q=0.8",
      },
    });

    if (!response.ok) return normalized;

    const contentType = response.headers.get("content-type") ?? "";
    if (!String(contentType).toLowerCase().startsWith("image/")) return normalized;

    const buffer = Buffer.from(await response.arrayBuffer());
    if (!buffer.length) return normalized;

    const storagePath = recipeImageStoragePath({
      recipeKey,
      imageRole,
      sourceURL: normalized,
      contentType,
    });

    const uploadURL = `${SUPABASE_URL}/storage/v1/object/${encodeURIComponent(RECIPE_IMAGE_BUCKET)}/${storagePath
      .split("/")
      .map((segment) => encodeURIComponent(segment))
      .join("/")}`;

    const uploadResponse = await fetch(uploadURL, {
      method: "POST",
      headers: {
        apikey: SUPABASE_ANON_KEY || storageBearer,
        Authorization: `Bearer ${storageBearer}`,
        "Content-Type": contentType || "application/octet-stream",
        "x-upsert": "true",
      },
      body: buffer,
    });

    if (!uploadResponse.ok) {
      return normalized;
    }

    return `${SUPABASE_URL}/storage/v1/object/public/${RECIPE_IMAGE_BUCKET}/${storagePath}`;
  } catch {
    return normalized;
  }
}

async function uploadRecipeImageBufferToStorage(buffer, { recipeKey, imageRole = "hero", accessToken = null, contentType = "image/png", sourceKey = null } = {}) {
  if (!buffer || !buffer.length || !SUPABASE_URL || !RECIPE_IMAGE_BUCKET) return null;

  const storageBearer = (normalizeText(accessToken ?? "") || SUPABASE_SERVICE_ROLE_KEY || SUPABASE_ANON_KEY).trim();
  if (!storageBearer) return null;

  const storagePath = recipeImageStoragePath({
    recipeKey,
    imageRole,
    sourceURL: sourceKey ?? `${recipeKey}:${imageRole}`,
    contentType,
  });

  const uploadURL = `${SUPABASE_URL}/storage/v1/object/${encodeURIComponent(RECIPE_IMAGE_BUCKET)}/${storagePath
    .split("/")
    .map((segment) => encodeURIComponent(segment))
    .join("/")}`;

  try {
    await ensureRecipeImageBucket();
    const uploadResponse = await fetch(uploadURL, {
      method: "POST",
      headers: {
        apikey: SUPABASE_ANON_KEY || storageBearer,
        Authorization: `Bearer ${storageBearer}`,
        "Content-Type": contentType,
        "x-upsert": "true",
      },
      body: buffer,
    });
    if (!uploadResponse.ok) return null;
    return `${SUPABASE_URL}/storage/v1/object/public/${RECIPE_IMAGE_BUCKET}/${storagePath}`;
  } catch {
    return null;
  }
}

function ingredientDisplayNameFromKey(value) {
  const normalized = normalizeKey(value);
  if (!normalized) return null;
  const smallWords = new Set(["and", "or", "of", "in", "with"]);
  return normalized
    .split(" ")
    .filter(Boolean)
    .map((part, index) => {
      if (index > 0 && smallWords.has(part)) return part;
      return `${part.charAt(0).toUpperCase()}${part.slice(1)}`;
    })
    .join(" ");
}

function isUtilityIngredient(name) {
  const normalized = normalizeKey(name);
  if (!normalized) return true;
  const utilityIngredients = new Set([
    "water",
    "hot water",
    "cold water",
    "warm water",
    "boiling water",
    "ice",
    "ice cube",
    "ice cubes",
  ]);
  return utilityIngredients.has(normalized);
}

async function expandCanonicalSourceURL(sourceURL, sourceType = null) {
  const normalized = cleanURL(sourceURL);
  if (!normalized) return null;

  const host = hostForURL(normalized);
  const loweredSourceType = normalizeText(sourceType).toLowerCase();
  const isTikTok = loweredSourceType === "tiktok" || host.includes("tiktok.com");
  if (!isTikTok) return normalized;

  const canonicalCacheKey = sourceMetadataCacheKey("canonical-url", normalized);
  const cachedCanonical = await readRedisJSON(canonicalCacheKey);
  if (cachedCanonical?.canonical_url) {
    return cachedCanonical.canonical_url;
  }

  try {
    const response = await fetchWithTimeout(normalized, {
      redirect: "follow",
      headers: {
        "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      },
    }, SOCIAL_FETCH_TIMEOUT_MS, "TikTok redirect resolve");

    const redirected = cleanURL(response.url ?? normalized);
    if (redirected && redirected !== normalized) {
      void writeRedisJSON(canonicalCacheKey, { canonical_url: redirected }, SOURCE_METADATA_CACHE_TTL_SECONDS);
      return redirected;
    }
  } catch {
    // Try alternate resolvers below.
  }

  try {
    const info = await fetchYtdlMetadataCached(normalized, {
      label: "TikTok canonical metadata resolve",
      cacheKind: "tiktok-canonical",
    });

    const resolved = cleanURL(info?.webpage_url ?? info?.original_url ?? info?.url ?? info?.webpage_url_basename ?? null);
    if (resolved) {
      void writeRedisJSON(canonicalCacheKey, { canonical_url: resolved }, SOURCE_METADATA_CACHE_TTL_SECONDS);
      return resolved;
    }
  } catch {
    // Try browser fallback below.
  }

  try {
    const pageSignals = await extractWebSource(normalized);
    const resolved = cleanURL(pageSignals?.canonical_url ?? pageSignals?.source_url ?? null);
    if (resolved) {
      void writeRedisJSON(canonicalCacheKey, { canonical_url: resolved }, SOURCE_METADATA_CACHE_TTL_SECONDS);
      return resolved;
    }
  } catch {
    // Final fallback below.
  }

  return normalized;
}

function buildDedupeKey({ sourceUrl = null, canonicalUrl = null, sourceText = null }) {
  const candidate = canonicalImportIdentityForRequest({ sourceUrl, canonicalUrl })
    || cleanURL(canonicalUrl)
    || cleanURL(sourceUrl)
    || normalizeText(sourceText).slice(0, 3000);
  if (!candidate) return null;
  return crypto.createHash("sha256").update(candidate).digest("hex");
}

function isSocialRecipeSource(sourceType, sourceURL) {
  const host = hostForURL(sourceURL);
  const type = normalizeText(sourceType).toLowerCase();
  return ["tiktok", "instagram", "youtube"].includes(type)
    || host.includes("tiktok.com")
    || host.includes("instagram.com")
    || host.includes("youtube.com")
    || host.includes("youtu.be");
}

function isCanonicalCacheableSource(sourceType, sourceURL) {
  return isSocialRecipeSource(sourceType, sourceURL) || Boolean(hostForURL(sourceURL));
}

function isOpenAITerminalModelError(error) {
  const status = Number(error?.status ?? error?.code ?? 0);
  const message = String(error?.message ?? error?.error?.message ?? "").toLowerCase();
  return status === 400 && (
    message.includes("model")
    || message.includes("unsupported")
    || message.includes("does not exist")
    || message.includes("invalid_request")
  );
}

function isResumableIngestionJob(job) {
  if (!job || job.status !== "failed") return false;
  if (!isSocialRecipeSource(job.source_type, job.canonical_url ?? job.source_url)) return false;
  return Boolean(job.normalized_at || job.fetched_at || job.evidence_bundle_id);
}

function nowIso() {
  return new Date().toISOString();
}

function compactJSON(value, limit = 120_000) {
  try {
    const raw = JSON.stringify(value);
    if (raw.length <= limit) return JSON.parse(raw);
    return {
      truncated: true,
      preview: raw.slice(0, limit),
    };
  } catch {
    return null;
  }
}

function limitText(value, limit = 120_000) {
  const text = sanitizeRecipeText(value);
  return text.length <= limit ? text : `${text.slice(0, limit)}…`;
}

function buildInClause(values) {
  const quoted = (values ?? [])
    .map((value) => String(value ?? "").replace(/"/g, '\\"'))
    .filter(Boolean)
    .map((value) => `"${value}"`)
    .join(",");
  const clause = `(${quoted})`;
  return encodeURIComponent(clause);
}

const OPTIONAL_RECIPE_INGESTION_JOB_COLUMNS = new Set([
  "canonical_url",
  "evidence_bundle_id",
]);

const OPTIONAL_RECIPE_ROW_COLUMNS = new Set([
  "source_provenance_json",
  "discover_brackets",
  "discover_brackets_enriched_at",
  "external_id",
  "recipe_path",
]);

function missingSchemaColumnName(error) {
  const raw = normalizeText(error?.message ?? error?.error ?? "");
  if (!raw) return null;

  const quotedMatch = raw.match(/Could not find the '([^']+)' column/i);
  if (quotedMatch?.[1]) return quotedMatch[1];

  const postgresMatch = raw.match(/column ["`]([^"'`]+)["`] does not exist/i);
  if (postgresMatch?.[1]) return postgresMatch[1];

  return null;
}

function stripOptionalRecipeIngestionJobColumns(payload = {}, disallowedColumns = new Set()) {
  return Object.fromEntries(
    Object.entries(payload).filter(([key, value]) => (
      value !== undefined
      && (!OPTIONAL_RECIPE_INGESTION_JOB_COLUMNS.has(key) || !disallowedColumns.has(key))
    ))
  );
}

async function insertRecipeIngestionJobRow(row) {
  const disallowedColumns = new Set();

  while (true) {
    try {
      const [created] = await insertRows("recipe_ingestion_jobs", [
        stripOptionalRecipeIngestionJobColumns(row, disallowedColumns),
      ]);
      return created;
    } catch (error) {
      const missingColumn = missingSchemaColumnName(error);
      if (!missingColumn || !OPTIONAL_RECIPE_INGESTION_JOB_COLUMNS.has(missingColumn) || disallowedColumns.has(missingColumn)) {
        throw error;
      }
      disallowedColumns.add(missingColumn);
    }
  }
}

function stripOptionalRecipeRowColumns(payload = {}, disallowedColumns = new Set()) {
  return Object.fromEntries(
    Object.entries(payload).filter(([key, value]) => (
      value !== undefined
      && (!OPTIONAL_RECIPE_ROW_COLUMNS.has(key) || !disallowedColumns.has(key))
    ))
  );
}

function stripSelectColumns(select, columns = []) {
  let next = String(select ?? "");
  for (const column of columns) {
    next = next.replace(`,${column}`, "");
  }
  return next;
}

async function insertRecipeTableRow(table, row) {
  const disallowedColumns = new Set();

  while (true) {
    try {
      const [created] = await insertRows(table, [
        stripOptionalRecipeRowColumns(row, disallowedColumns),
      ], {
        prefer: "return=minimal",
      });
      return created;
    } catch (error) {
      const missingColumn = missingSchemaColumnName(error);
      if (!missingColumn || !OPTIONAL_RECIPE_ROW_COLUMNS.has(missingColumn) || disallowedColumns.has(missingColumn)) {
        throw error;
      }
      disallowedColumns.add(missingColumn);
    }
  }
}

async function patchRecipeTableRow(table, recipeID, payload) {
  const disallowedColumns = new Set();
  while (true) {
    try {
      return await patchRows(
        table,
        [`id=eq.${encodeURIComponent(recipeID)}`],
        stripOptionalRecipeRowColumns(payload, disallowedColumns),
        { prefer: "return=minimal" }
      );
    } catch (error) {
      const missingColumn = missingSchemaColumnName(error);
      if (!missingColumn || !OPTIONAL_RECIPE_ROW_COLUMNS.has(missingColumn) || disallowedColumns.has(missingColumn)) {
        throw error;
      }
      disallowedColumns.add(missingColumn);
    }
  }
}

async function patchRecipeIngestionJobRow(jobID, payload) {
  const disallowedColumns = new Set();

  while (true) {
    try {
      return await patchRows(
        "recipe_ingestion_jobs",
        [`id=eq.${encodeURIComponent(jobID)}`],
        stripOptionalRecipeIngestionJobColumns(payload, disallowedColumns)
      );
    } catch (error) {
      const missingColumn = missingSchemaColumnName(error);
      if (!missingColumn || !OPTIONAL_RECIPE_INGESTION_JOB_COLUMNS.has(missingColumn) || disallowedColumns.has(missingColumn)) {
        throw error;
      }
      disallowedColumns.add(missingColumn);
    }
  }
}

export async function heartbeatRecipeIngestionJob({ jobID, workerID } = {}) {
  const normalizedJobID = normalizeText(jobID);
  const normalizedWorkerID = normalizeText(workerID);
  if (!normalizedJobID || !normalizedWorkerID) return false;

  await patchRows(
    "recipe_ingestion_jobs",
    [
      `id=eq.${encodeURIComponent(normalizedJobID)}`,
      `worker_id=eq.${encodeURIComponent(normalizedWorkerID)}`,
      "status=in.(processing,fetching,parsing,normalized)",
    ],
    { leased_at: nowIso() },
    { prefer: "return=minimal" }
  );
  return true;
}

function startRecipeIngestionHeartbeat(jobID, workerID) {
  const normalizedJobID = normalizeText(jobID);
  const normalizedWorkerID = normalizeText(workerID);
  if (!normalizedJobID || !normalizedWorkerID) return () => {};

  const interval = setInterval(() => {
    heartbeatRecipeIngestionJob({
      jobID: normalizedJobID,
      workerID: normalizedWorkerID,
    }).catch((error) => {
      console.warn(`[recipe-ingestion] heartbeat failed job=${normalizedJobID}:`, error.message);
    });
  }, RECIPE_INGESTION_HEARTBEAT_MS);
  interval.unref?.();
  return () => clearInterval(interval);
}

function normalizeIngredientMatchSignature(value) {
  return normalizeKey(value)
    .split(/\s+/)
    .filter(Boolean)
    .map((token) => token
      .replace(/ies$/i, "y")
      .replace(/(ses|xes|zes|ches|shes)$/i, "")
      .replace(/s$/i, ""))
    .join(" ");
}

function ingredientNameMatches(left, right) {
  const normalizedLeft = normalizeText(left);
  const normalizedRight = normalizeText(right);
  if (!normalizedLeft || !normalizedRight) return false;

  const leftKey = normalizeKey(normalizedLeft);
  const rightKey = normalizeKey(normalizedRight);
  if (!leftKey || !rightKey) return false;
  if (leftKey === rightKey) return true;

  const leftSignature = normalizeIngredientMatchSignature(normalizedLeft);
  const rightSignature = normalizeIngredientMatchSignature(normalizedRight);
  if (leftSignature === rightSignature) return true;

  if (leftSignature.includes(` ${rightSignature}`) || rightSignature.includes(` ${leftSignature}`)) {
    return true;
  }

  const leftCore = leftSignature.split(/\s+/).at(-1) ?? "";
  const rightCore = rightSignature.split(/\s+/).at(-1) ?? "";
  return Boolean(leftCore && rightCore && leftCore === rightCore);
}

function pickEvenlySpacedItems(items = [], maxCount = 3) {
  const values = Array.isArray(items) ? items.filter(Boolean) : [];
  if (values.length <= maxCount) return values;
  if (maxCount <= 1) return values.slice(0, 1);

  const result = [];
  for (let index = 0; index < maxCount; index += 1) {
    const sourceIndex = Math.round((index * (values.length - 1)) / (maxCount - 1));
    result.push(values[sourceIndex]);
  }
  return result;
}

function shouldIncludeFrameOCRInPrompt(frame) {
  const text = normalizeText(frame?.text ?? "");
  if (!text) return false;
  const confidence = Number(frame?.confidence);
  if (!Number.isFinite(confidence)) return true;
  if (confidence >= OCR_PROMPT_MIN_CONFIDENCE) return true;
  return /\b(ingredients?|cups?|tbsp|tsp|teaspoons?|tablespoons?|grams?|ounces?|oil|salt|pepper|rice|onion|tomato|chicken|beef|fish|cook|bake|fry|boil|simmer)\b/i.test(text);
}

function summarizeFrameOCRTexts(frameOcrTexts = [], { maxFrames = 4, textLimit = 700 } = {}) {
  return pickEvenlySpacedItems(
    (Array.isArray(frameOcrTexts) ? frameOcrTexts : []).filter(shouldIncludeFrameOCRInPrompt),
    maxFrames
  )
    .map((frame) => {
      const label = Number.isFinite(Number(frame?.frame_index)) ? `frame ${Number(frame.frame_index)}` : "frame";
      const confidence = Number.isFinite(Number(frame?.confidence)) ? ` conf ${Number(frame.confidence).toFixed(0)}` : "";
      return `${label}${confidence}: ${limitText(frame?.text ?? "", textLimit)}`;
    })
    .filter(Boolean)
    .join("\n");
}

function collectRecipeEvidenceImageInputs(source, { maxCount = RECIPE_EXTRACTION_MAX_IMAGE_INPUTS } = {}) {
  const attachments = [
    ...(Array.isArray(source.frame_data_urls) ? source.frame_data_urls.map((url) => ({ kind: "frame", data_url: url })) : []),
    ...(Array.isArray(source.attachments) ? source.attachments : []),
  ];

  return pickEvenlySpacedItems(attachments, maxCount)
    .flatMap((attachment) => {
      if (attachment.kind === "frame" && attachment.data_url) {
        return [{ type: "image_url", image_url: { url: attachment.data_url, detail: "low" } }];
      }
      if (attachment.kind === "image" && (attachment.data_url || attachment.source_url)) {
        return [{ type: "image_url", image_url: { url: attachment.data_url ?? attachment.source_url, detail: "low" } }];
      }
      if (attachment.kind === "video") {
        return pickEvenlySpacedItems(attachment.preview_frame_urls ?? [], Math.min(maxCount, 3))
          .map((url) => ({ type: "image_url", image_url: { url, detail: "low" } }));
      }
      return [];
    })
    .slice(0, maxCount);
}

async function getOCRWorker() {
  if (!ocrWorkerPromise) {
    ocrWorkerPromise = (async () => {
      const worker = await createWorker("eng", OEM.LSTM_ONLY, { logger: () => {} });
      return worker;
    })().catch((error) => {
      ocrWorkerPromise = null;
      throw error;
    });
  }

  return ocrWorkerPromise;
}

async function ocrFrameDataURLs(frameDataURLs = []) {
  if (!Array.isArray(frameDataURLs) || !frameDataURLs.length) return [];

  try {
    const worker = await getOCRWorker();
    const results = [];

    for (const [index, dataURL] of frameDataURLs.entries()) {
      if (!dataURL) continue;
      try {
        const recognition = await withTimeout(
          worker.recognize(dataURL),
          SOCIAL_OCR_FRAME_TIMEOUT_MS,
          `frame OCR ${index + 1}`
        );
        const text = normalizeText(recognition?.data?.text ?? "");
        const confidence = Number(recognition?.data?.confidence);
        if (!text) continue;
        results.push({
          frame_index: index + 1,
          text,
          confidence: Number.isFinite(confidence) ? Number(confidence.toFixed(2)) : null,
        });
      } catch {
        continue;
      }
    }

    return results;
  } catch {
    return [];
  }
}

async function imageURLsToDataURLs(imageURLs = [], limit = 4) {
  const normalizedURLs = uniqueStrings(imageURLs.map(cleanURL).filter(Boolean)).slice(0, limit);
  const results = [];
  for (const imageURL of normalizedURLs) {
    try {
      const response = await fetchWithTimeout(imageURL, {
        redirect: "follow",
        headers: {
          "user-agent": DEFAULT_USER_AGENT,
          accept: "image/*,*/*;q=0.8",
        },
      }, SOCIAL_FETCH_TIMEOUT_MS, "image fetch");
      if (!response.ok) continue;
      const contentType = response.headers.get("content-type") ?? "image/jpeg";
      if (!contentType.toLowerCase().startsWith("image/")) continue;
      const buffer = Buffer.from(await response.arrayBuffer());
      if (!buffer.length) continue;
      results.push(toDataURL(buffer, contentType));
    } catch {
      continue;
    }
  }
  return results;
}

function buildVideoEvidenceBundle(source, { transcriptText = "", frameOcrTexts = [], downloadedVideo = false } = {}) {
  const frameCount = Array.isArray(source.frame_data_urls) ? source.frame_data_urls.length : 0;
  const frameOCRCount = Array.isArray(frameOcrTexts) ? frameOcrTexts.filter((frame) => normalizeText(frame?.text)).length : 0;
  const pageImageCount = Array.isArray(source.page_image_urls) ? source.page_image_urls.length : 0;
  const mediaMode = normalizeText(source.media_mode ?? "")
    || (downloadedVideo ? "video" : frameCount > 0 || pageImageCount > 0 ? "slideshow" : null);

  return {
    source_type: source.source_type ?? null,
    platform: source.platform ?? null,
    source_url: cleanURL(source.source_url ?? null),
    canonical_url: cleanURL(source.canonical_url ?? null),
    title: normalizeText(source.title ?? "") || null,
    description: normalizeText(source.description ?? source.meta_description ?? "") || null,
    author_name: normalizeText(source.author_name ?? "") || null,
    author_handle: normalizeText(source.author_handle ?? "") || null,
    attached_video_url: cleanURL(source.attached_video_url ?? null),
    transcript_text: normalizeText(transcriptText) || null,
    frame_count: frameCount,
    frame_ocr_texts: frameOcrTexts,
    page_image_count: pageImageCount,
    downloaded_video: Boolean(downloadedVideo),
    media_mode: mediaMode || null,
    caption_text: normalizeText(source.description ?? source.meta_description ?? "") || null,
    page_signal_summary: source.page_signals_summary ?? null,
    evidence_summary: {
      transcript_present: Boolean(normalizeText(transcriptText)),
      frame_ocr_count: frameOCRCount,
      frame_count: frameCount,
      page_image_count: pageImageCount,
      downloaded_video: Boolean(downloadedVideo),
      media_mode: mediaMode || null,
    },
  };
}

function inferSocialMediaMode({ downloadedVideo = false, pageSignals = null, metadata = null } = {}) {
  if (downloadedVideo) return "video";

  const pageImageCount = Array.isArray(pageSignals?.page_image_urls) ? pageSignals.page_image_urls.length : 0;
  if (pageImageCount >= 2) return "slideshow";

  const title = normalizeText(metadata?.title ?? pageSignals?.title ?? "");
  const description = normalizeText(metadata?.description ?? pageSignals?.meta_description ?? pageSignals?.body_text ?? "");
  const text = `${title}\n${description}`;

  if (/\b(carousel|slideshow|swipe|slide\s*\d+|photo\s*dump)\b/i.test(text)) {
    return "slideshow";
  }

  return "unknown";
}

function assessRecipeSignals(source) {
  const structuredIngredientCount = Array.isArray(source?.structured_recipe?.recipeIngredient) ? source.structured_recipe.recipeIngredient.length : 0;
  const structuredInstructionCount = Array.isArray(source?.structured_recipe?.recipeInstructions) ? source.structured_recipe.recipeInstructions.length : 0;
  const ingredientCandidateCount = Array.isArray(source?.ingredient_candidates) ? source.ingredient_candidates.length : 0;
  const instructionCandidateCount = Array.isArray(source?.instruction_candidates) ? source.instruction_candidates.length : 0;
  const frameOcrText = summarizeFrameOCRTexts(source?.frame_ocr_texts ?? [], { maxFrames: 4, textLimit: 700 });
  const transcriptText = normalizeText(source?.transcript_text ?? "");
  const descriptionText = normalizeText(source?.description ?? source?.meta_description ?? "");
  const titleText = normalizeText(source?.title ?? "");
  const bodyText = limitText(source?.raw_text ?? source?.body_text ?? "", 8000);
  const combinedText = [titleText, descriptionText, transcriptText, frameOcrText, bodyText]
    .filter(Boolean)
    .join("\n")
    .slice(0, 12000);

  const positivePatterns = [
    /\bingredients?\b/i,
    /\binstructions?\b/i,
    /\bdirections?\b/i,
    /\bmethod\b/i,
    /\brecipe\b/i,
    /\bcook\b/i,
    /\bsimmer\b/i,
    /\bboil\b/i,
    /\bbake\b/i,
    /\bfry\b/i,
    /\bwhisk\b/i,
    /\bchop\b/i,
    /\bsaute\b/i,
    /\bserve\b/i,
    /\bpreheat\b/i,
    /\badd\b.{0,20}\bto\b/i,
    /\bcups?\b/i,
    /\btsp\b/i,
    /\btbsp\b/i,
  ];
  const negativePatterns = [
    /\bgrwm\b/i,
    /\boutfit\b/i,
    /\bvlog\b/i,
    /\bday in the life\b/i,
    /\btravel\b/i,
    /\bprank\b/i,
    /\bcomedy\b/i,
    /\breaction\b/i,
    /\bmukbang\b/i,
    /\brestaurant review\b/i,
    /\bpromo\b/i,
    /\bunboxing\b/i,
    /\bha(u)?l\b/i,
    /\bskit\b/i,
    /\bget ready with me\b/i,
  ];

  const positiveHits = positivePatterns.filter((pattern) => pattern.test(combinedText)).length;
  const negativeHits = negativePatterns.filter((pattern) => pattern.test(combinedText)).length;

  return {
    structuredIngredientCount,
    structuredInstructionCount,
    ingredientCandidateCount,
    instructionCandidateCount,
    frameOcrCount: Array.isArray(source?.frame_ocr_texts) ? source.frame_ocr_texts.filter((frame) => normalizeText(frame?.text)).length : 0,
    transcriptPresent: Boolean(transcriptText),
    pageImageCount: Array.isArray(source?.page_image_urls) ? source.page_image_urls.length : 0,
    mediaMode: normalizeText(source?.media_mode ?? "") || null,
    combinedText,
    positiveHits,
    negativeHits,
  };
}

async function assessRecipeLikelihood(source) {
  const signals = assessRecipeSignals(source);
  let score = 0;

  if (signals.structuredIngredientCount >= 3) score += 5;
  if (signals.structuredInstructionCount >= 2) score += 4;
  if (signals.ingredientCandidateCount >= 4) score += 3;
  if (signals.instructionCandidateCount >= 2) score += 3;
  if (signals.transcriptPresent) score += 2;
  if (signals.frameOcrCount >= 1) score += 1;
  score += Math.min(signals.positiveHits, 4);
  score -= Math.min(signals.negativeHits, 4) * 2;

  if (score >= 8) {
    return {
      is_recipe: true,
      confidence: 0.9,
      reason: "Source includes strong recipe structure and cooking evidence.",
      method: "heuristic_accept",
      signals,
    };
  }

  if (
    score <= -2
    || (
      signals.structuredIngredientCount === 0
      && signals.ingredientCandidateCount === 0
      && signals.structuredInstructionCount === 0
      && signals.instructionCandidateCount === 0
      && !signals.transcriptPresent
      && signals.frameOcrCount === 0
    )
  ) {
    return {
      is_recipe: false,
      confidence: 0.92,
      reason: "Source does not include enough recipe evidence to justify parsing.",
      method: "heuristic_reject",
      signals,
    };
  }

  if (!openai) {
    return {
      is_recipe: score >= 4,
      confidence: score >= 4 ? 0.62 : 0.58,
      reason: score >= 4
        ? "Source shows some cooking evidence, but the gate model is unavailable."
        : "Source lacks clear enough recipe evidence, and the gate model is unavailable.",
      method: "heuristic_fallback",
      signals,
    };
  }

  const response = await withRecipeAIStage("recipe_import.gate", () => openai.chat.completions.create({
    model: RECIPE_GATE_MODEL,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: RECIPE_GATE_SYSTEM_PROMPT },
      {
        role: "user",
        content: [
          "Decide if this source is actually a recipe.",
          "",
          "Signals:",
          JSON.stringify({
            source_type: source.source_type ?? null,
            platform: source.platform ?? null,
            media_mode: signals.mediaMode ?? null,
            structured_ingredient_count: signals.structuredIngredientCount,
            structured_instruction_count: signals.structuredInstructionCount,
            ingredient_candidate_count: signals.ingredientCandidateCount,
            instruction_candidate_count: signals.instructionCandidateCount,
            transcript_present: signals.transcriptPresent,
            frame_ocr_count: signals.frameOcrCount,
            page_image_count: signals.pageImageCount,
            positive_hits: signals.positiveHits,
            negative_hits: signals.negativeHits,
          }),
          "",
          "Title:",
          source.title ?? "",
          "",
          "Description / caption:",
          source.description ?? source.meta_description ?? "",
          "",
          "Ingredient candidates:",
          JSON.stringify((source.ingredient_candidates ?? []).slice(0, 24)),
          "",
          "Instruction candidates:",
          JSON.stringify((source.instruction_candidates ?? []).slice(0, 18)),
          "",
          "Transcript excerpt:",
          limitText(source.transcript_text ?? "", 3000),
          "",
          "Frame OCR excerpt:",
          limitText(summarizeFrameOCRTexts(source.frame_ocr_texts ?? [], { maxFrames: 4, textLimit: 700 }), 3000),
          "",
          "Return JSON like:",
          JSON.stringify({
            is_recipe: true,
            confidence: 0.0,
            reason: "string",
          }),
        ].join("\n"),
      },
    ],
  }));

  const rawContent = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(rawContent);
  return {
    is_recipe: Boolean(parsed?.is_recipe),
    confidence: Number.isFinite(Number(parsed?.confidence)) ? Number(parsed.confidence) : 0.5,
    reason: normalizeText(parsed?.reason ?? "") || "Recipe gate could not explain the decision.",
    method: "llm_gate",
    signals,
  };
}

function shouldContinueRecipeImportDespiteGate(recipeGate, source) {
  const sourceType = normalizeText(source?.source_type ?? source?.platform ?? "").toLowerCase();
  const isSocialSource = ["tiktok", "instagram", "youtube", "shorts", "reel", "social"].some((token) => sourceType.includes(token));
  if (!isSocialSource) return false;

  const reason = normalizeText(recipeGate?.reason ?? "").toLowerCase();
  const text = [
    source?.title,
    source?.description,
    source?.meta_description,
    source?.transcript_text,
  ].map((value) => normalizeText(value).toLowerCase()).filter(Boolean).join("\n");

  const looksLikeRecipeLead = /\b(recipe|ingredients?|method|cook|bake|meal prep|protein|calories|macros?)\b/i.test(text);
  const gateRejectedForMissingDetails = /\b(no actual recipe content|no ingredients?|no steps?|promotion|promotional|full recipe|recipe link|link in bio)\b/i.test(reason);
  return looksLikeRecipeLead && gateRejectedForMissingDetails;
}

function socialSourceHasFoodIdentity(source) {
  const sourceType = normalizeText(source?.source_type ?? source?.platform ?? "").toLowerCase();
  const isSocialSource = ["tiktok", "instagram", "youtube", "shorts", "reel", "social"].some((token) => sourceType.includes(token));
  if (!isSocialSource) return false;

  const text = [
    source?.title,
    source?.description,
    source?.meta_description,
    source?.transcript_text,
  ].map((value) => normalizeText(value).toLowerCase()).filter(Boolean).join("\n");

  if (!text) return false;
  return /\b(recipe|food|dish|meal|cook|bake|fried|roasted|grilled|cheesy|garlic|rolls?|bread|pizza|pasta|noodles?|rice|bowl|taco|burger|sandwich|chicken|beef|pork|salmon|shrimp|egg|tofu|sauce|dessert|cake|cookie|brownie|soup|stew|salad)\b/i.test(text);
}

function buildReferenceRecipeQueryFromSocialSource(source) {
  const candidates = [
    source?.title,
    source?.description,
    source?.meta_description,
    source?.transcript_text,
  ].map((value) => normalizeText(value)).filter(Boolean);

  const cleaned = candidates
    .map((value) => value
      .replace(/https?:\/\/\S+/gi, " ")
      .replace(/[@#][\w.-]+/g, " ")
      .replace(/\b(link in bio|follow for more|full recipe|recipe below|ad|sponsored|promo|promotion|limited time|order now)\b/gi, " ")
      .replace(/[^\p{L}\p{N}\s'&-]/gu, " ")
      .replace(/\s+/g, " ")
      .trim())
    .find((value) => value.split(/\s+/).length >= 2);

  if (!cleaned) return "";
  const words = cleaned
    .split(/\s+/)
    .filter((word) => !/^(the|and|with|for|this|that|from|make|made|easy|best|viral|food|recipe)$/i.test(word))
    .slice(0, 10);
  const query = words.join(" ").trim() || cleaned.split(/\s+/).slice(0, 10).join(" ");
  return normalizeText(`${query} recipe`);
}

function looksLikeRecipeSearchRequest(text) {
  const normalized = normalizeText(text);
  if (!normalized || isProbablyURL(normalized)) return false;
  if (normalized.length > 120) return false;
  if (/\n/.test(normalized)) return false;
  if (/(ingredients|instructions|method|directions|step\s*\d|prep time|cook time|serves)/i.test(normalized)) return false;
  if (looksLikeRecipeIdeaPrompt(normalized)) return false;

  const words = normalized.split(/\s+/).filter(Boolean);
  if (words.length < 2 || words.length > 12) return false;
  return true;
}

function fallbackRecipeCreateIntent(text) {
  const normalized = normalizeText(text);
  const lowered = normalized.toLowerCase();
  const hasStructuredRecipeText = /(ingredients|instructions|method|directions|step\s*\d|prep time|cook time|serves)/i.test(normalized)
    || /(^|\n)\s*\d+[\).\s]/m.test(text)
    || /(^|\n)\s*[-*•]\s+/m.test(text);
  if (hasStructuredRecipeText) {
    return {
      intent: "direct_recipe_text",
      confidence: 0.72,
      recipe_brief: normalized,
      search_queries: [],
      reason: "Input appears to include existing recipe structure.",
    };
  }

  const fusionPattern = /\b(combine|mash\s*up|mashup|fusion|hybrid|cross between|mix|merge|blend|meets|inspired by|take on|version of)\b/i;
  if (fusionPattern.test(lowered) || /\bwith\b.+\b(twist|style|vibe|flavors?)\b/i.test(lowered)) {
    return {
      intent: "fusion_recipe",
      confidence: 0.68,
      recipe_brief: normalized,
      search_queries: uniqueStrings([normalized, ...normalized.split(/\b(?:and|with|meets|plus|\+)\b/i).map((part) => normalizeText(`${part} recipe`))]).slice(0, 3),
      reason: "Prompt asks to combine or adapt recipe ideas.",
    };
  }

  if (looksLikeRecipeSearchRequest(normalized)) {
    return {
      intent: "base_recipe",
      confidence: 0.7,
      recipe_brief: normalized,
      search_queries: [normalized],
      reason: "Short dish name is best grounded as a base recipe.",
    };
  }

  return {
    intent: looksLikeRecipeIdeaPrompt(normalized) ? "custom_recipe" : "direct_recipe_text",
    confidence: 0.58,
    recipe_brief: normalized,
    search_queries: looksLikeRecipeIdeaPrompt(normalized) ? [normalized] : [],
    reason: "Fallback heuristic classification.",
  };
}

function normalizeRecipeCreateIntent(value, fallbackText) {
  const fallback = fallbackRecipeCreateIntent(fallbackText);
  const allowed = new Set(["base_recipe", "fusion_recipe", "custom_recipe", "direct_recipe_text"]);
  const intent = allowed.has(normalizeText(value?.intent).toLowerCase())
    ? normalizeText(value.intent).toLowerCase()
    : fallback.intent;
  const searchQueries = uniqueStrings(Array.isArray(value?.search_queries) ? value.search_queries : fallback.search_queries)
    .slice(0, intent === "fusion_recipe" ? 3 : 2);
  return {
    intent,
    confidence: Number.isFinite(Number(value?.confidence)) ? Math.max(0, Math.min(Number(value.confidence), 1)) : fallback.confidence,
    recipe_brief: limitText(normalizeText(value?.recipe_brief ?? value?.brief ?? fallback.recipe_brief), 500) || fallback.recipe_brief,
    search_queries: searchQueries,
    reason: limitText(normalizeText(value?.reason ?? fallback.reason), 300) || fallback.reason,
  };
}

async function classifyRecipeCreateIntent(text) {
  const fallback = fallbackRecipeCreateIntent(text);
  if (!openai) return fallback;
  try {
    const response = await withRecipeAIStage("recipe_import.create_intent", () => openai.chat.completions.create({
      model: RECIPE_GATE_MODEL,
      ...chatCompletionTemperatureParams(RECIPE_GATE_MODEL, 0),
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: RECIPE_CREATE_INTENT_SYSTEM_PROMPT },
        {
          role: "user",
          content: [
            "Classify this create-recipe request.",
            "",
            `request: ${limitText(text, 1200)}`,
            "",
            "Return JSON like:",
            JSON.stringify({
              intent: "base_recipe|fusion_recipe|custom_recipe|direct_recipe_text",
              confidence: 0.0,
              recipe_brief: "short normalized brief",
              search_queries: ["query"],
              reason: "short reason",
            }),
          ].join("\n"),
        },
      ],
    }));
    const parsed = JSON.parse(response.choices?.[0]?.message?.content ?? "{}");
    return normalizeRecipeCreateIntent(parsed, text);
  } catch {
    return fallback;
  }
}

async function collectCreateIntentReferenceSources(intent, prompt, { maxQueries = 2 } = {}) {
  const normalizedIntent = normalizeText(intent?.intent).toLowerCase();
  if (!["fusion_recipe", "custom_recipe"].includes(normalizedIntent)) return { recipeSources: [], referenceLookups: [] };

  const queryLimit = normalizedIntent === "fusion_recipe" ? Math.max(2, maxQueries) : 1;
  const queries = uniqueStrings([
    ...(Array.isArray(intent?.search_queries) ? intent.search_queries : []),
    prompt,
  ]).slice(0, queryLimit);
  const referenceLookups = [];
  const recipeSources = [];
  const seenURLs = new Set();

  for (const query of queries) {
    try {
      const lookup = await extractRecipeSearchSource(query, [], {
        source: {
          source_type: "concept_prompt",
          platform: "direct_input",
          raw_text: prompt,
          creation_intent: intent,
        },
      });
      const sources = Array.isArray(lookup?.recipe_sources) ? lookup.recipe_sources : [];
      referenceLookups.push({
        query,
        source_count: sources.length,
        search_methods: lookup?.search_methods ?? [],
      });
      for (const source of sources) {
        const url = cleanURL(source.canonical_url ?? source.source_url ?? "");
        const key = url || normalizeKey([source.title, source.site_name].filter(Boolean).join(" "));
        if (!key || seenURLs.has(key)) continue;
        seenURLs.add(key);
        recipeSources.push(source);
        if (recipeSources.length >= 6) break;
      }
    } catch (error) {
      referenceLookups.push({
        query,
        source_count: 0,
        error: errorSummary(error),
      });
    }
    if (recipeSources.length >= 6) break;
  }

  return { recipeSources, referenceLookups };
}

function scoreScrapedRecipeSource(source, query = "") {
  const title = normalizeText(source?.title ?? "");
  const description = normalizeText(source?.description ?? source?.meta_description ?? "");
  const ingredientCount = Array.isArray(source?.ingredient_candidates) ? source.ingredient_candidates.length : 0;
  const instructionCount = Array.isArray(source?.instruction_candidates) ? source.instruction_candidates.length : 0;
  const structuredIngredientCount = Array.isArray(source?.structured_recipe?.recipeIngredient) ? source.structured_recipe.recipeIngredient.length : 0;
  const queryTokens = normalizeKey(query).split(/\s+/).filter(Boolean);
  const haystack = normalizeKey([title, description].join(" "));

  let score = 0;
  score += Math.min(ingredientCount, 20) * 1.4;
  score += Math.min(instructionCount, 16) * 1.7;
  score += Math.min(structuredIngredientCount, 20) * 2.4;
  for (const token of queryTokens) {
    if (haystack.includes(token)) score += 4;
  }
  if (source?.structured_recipe) score += 12;
  if (source?.hero_image_url) score += 3;
  if (source?.site_name) score += 2;
  return score;
}

function normalizeRecipeSearchResultURL(href) {
  const raw = htmlDecode(href);
  const absoluteCandidate = /^\//.test(raw) ? `https://duckduckgo.com${raw}` : raw;
  const cleaned = cleanURL(absoluteCandidate);
  if (!cleaned) return null;
  try {
    const parsed = new URL(cleaned);
    const host = parsed.hostname.replace(/^www\./i, "").toLowerCase();
    const encodedTarget = parsed.searchParams.get("uddg") || parsed.searchParams.get("u") || parsed.searchParams.get("url");
    if (host.includes("duckduckgo.com") && encodedTarget) {
      return cleanURL(decodeURIComponent(encodedTarget));
    }
    return cleaned;
  } catch {
    return cleaned;
  }
}

function isUsableRecipeSearchLink(url) {
  const cleaned = cleanURL(url);
  if (!cleaned || !/^https?:\/\//i.test(cleaned)) return false;
  const host = hostForURL(cleaned);
  if (!host) return false;
  if (host.includes("duckduckgo.com")) return false;
  if (host.includes("tiktok.com") || host.includes("instagram.com") || host.includes("youtube.com") || host === "youtu.be") return false;
  if (/\.(jpg|jpeg|png|gif|webp|pdf)(?:[?#].*)?$/i.test(cleaned)) return false;
  return true;
}

async function searchRecipeLinksWithFetch(query, { limit = RECIPE_SEARCH_MAX_LINKS } = {}) {
  const normalizedQuery = normalizeText(query);
  if (!normalizedQuery) return [];

  const searchQuery = `${normalizedQuery} recipe`;
  const searchURL = `https://duckduckgo.com/html/?q=${encodeURIComponent(searchQuery)}`;
  const response = await fetch(searchURL, {
    headers: {
      "user-agent": DEFAULT_USER_AGENT,
      accept: "text/html,application/xhtml+xml",
    },
  });
  if (!response.ok) {
    throw new Error(`DuckDuckGo search returned HTTP ${response.status}`);
  }

  const html = await response.text();
  const links = [];
  const seen = new Set();
  const anchorPattern = /<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
  let match = null;
  while ((match = anchorPattern.exec(html)) && links.length < limit) {
    const url = normalizeRecipeSearchResultURL(match[1]);
    if (!isUsableRecipeSearchLink(url)) continue;
    if (seen.has(url)) continue;
    seen.add(url);
    links.push({
      title: normalizeText(htmlDecode(String(match[2] ?? "").replace(/<[^>]+>/g, " "))) || null,
      url,
    });
  }
  return links;
}

async function searchRecipeLinksWithAI(query, { limit = RECIPE_SEARCH_MAX_LINKS, source = null } = {}) {
  if (!openai || !ENABLE_AI_WEB_REFERENCE_SEARCH || typeof openai.responses?.create !== "function") {
    return [];
  }

  const normalizedQuery = normalizeText(query);
  if (!normalizedQuery) return [];

  const response = await withRecipeAIStage("recipe_import.web_reference_search", () => openai.responses.create({
    model: RECIPE_WEB_REFERENCE_MODEL,
    tools: [{ type: "web_search_preview", search_context_size: "low" }],
    tool_choice: "auto",
    max_output_tokens: 3000,
    instructions: [
      "Find real recipe reference pages for Ounje's recipe import completion pass.",
      "Return JSON only.",
      "Prefer actual recipe pages with ingredients and instructions.",
      "Avoid social media, video-only pages, restaurant pages, listicles, PDFs, and generic search pages.",
      "Return canonical URLs when possible.",
    ].join("\n"),
    input: [
      `dish_query: ${normalizedQuery}`,
      "",
      "Original source hints:",
      JSON.stringify({
        title: source?.title ?? null,
        description: source?.description ?? source?.meta_description ?? null,
        platform: source?.platform ?? source?.source_type ?? null,
        author: source?.author_name ?? source?.author_handle ?? null,
      }),
      "",
      `Return up to ${limit} links as JSON:`,
      JSON.stringify({
        links: [
          {
            title: "Recipe title",
            url: "https://example.com/recipe",
            reason: "short relevance reason",
          },
        ],
      }),
    ].join("\n"),
  }));

  const rawText = normalizeText(response.output_text ?? response.output?.flatMap((item) => (
    Array.isArray(item.content)
      ? item.content.map((content) => content.text ?? content.output_text ?? "").filter(Boolean)
      : []
  )).join("\n") ?? "");
  const jsonText = rawText.match(/\{[\s\S]*\}/)?.[0] ?? rawText;
  const parsed = JSON.parse(jsonText);
  const links = Array.isArray(parsed?.links) ? parsed.links : [];
  const seen = new Set();
  const results = [];
  for (const entry of links) {
    const url = normalizeRecipeSearchResultURL(entry?.url ?? entry?.source_url ?? entry?.href ?? "");
    if (!isUsableRecipeSearchLink(url)) continue;
    if (seen.has(url)) continue;
    seen.add(url);
    results.push({
      title: normalizeText(entry?.title ?? "") || null,
      url,
      reason: normalizeText(entry?.reason ?? "") || null,
      source: "ai_web_reference_search",
    });
    if (results.length >= limit) break;
  }
  return results;
}

async function searchRecipeLinksWithPlaywright(query, { limit = RECIPE_SEARCH_MAX_LINKS } = {}) {
  const normalizedQuery = normalizeText(query);
  if (!normalizedQuery) return [];

  const { browser, context } = await createBrowserContext({ headless: true });
  const page = await context.newPage();
  page.setDefaultTimeout(30_000);
  page.setDefaultNavigationTimeout(45_000);

  try {
    const searchQuery = `${normalizedQuery} recipe`;
    const searchURL = `https://duckduckgo.com/html/?q=${encodeURIComponent(searchQuery)}`;
    await page.goto(searchURL, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(1500);

    const rawLinks = await page.evaluate(() => {
      const normalize = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
      const anchors = Array.from(document.querySelectorAll("a[href]"));
      return anchors.map((anchor) => ({
        title: normalize(anchor.textContent),
        href: anchor.href,
      }));
    });

    const links = [];
    const seen = new Set();
    for (const candidate of rawLinks) {
      const href = normalizeRecipeSearchResultURL(candidate.href);
      if (!isUsableRecipeSearchLink(href)) continue;
      if (seen.has(href)) continue;
      seen.add(href);
      links.push({
        title: normalizeText(candidate.title) || null,
        url: href,
      });
      if (links.length >= limit) break;
    }

    return links;
  } finally {
    await page.close().catch(() => {});
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
  }
}

function mergeRecipeSearchLinks(...buckets) {
  const links = [];
  const seen = new Set();
  for (const bucket of buckets) {
    for (const entry of bucket ?? []) {
      const url = normalizeRecipeSearchResultURL(entry?.url ?? entry?.source_url ?? entry?.href ?? "");
      if (!isUsableRecipeSearchLink(url)) continue;
      if (seen.has(url)) continue;
      seen.add(url);
      links.push({
        title: normalizeText(entry?.title ?? "") || null,
        url,
        reason: normalizeText(entry?.reason ?? "") || null,
        source: normalizeText(entry?.source ?? "") || null,
      });
    }
  }
  return links;
}

async function extractRecipeSearchSource(query, attachments = [], { source = null, jobID = null } = {}) {
  const searchMethods = [];
  let searchError = null;
  let aiSearchError = null;
  let browserLinks = [];
  let aiLinks = [];

  await timeRecipeImportStage("web_reference_search", { jobID, metadata: { query: normalizeText(query, 180) } }, async () => {
    const aiSearch = (async () => {
      try {
        const links = await searchRecipeLinksWithAI(query, { limit: RECIPE_SEARCH_MAX_LINKS, source });
        if (links.length) searchMethods.push("ai_web_reference_search");
        return links;
      } catch (error) {
        aiSearchError = errorSummary(error);
        return [];
      }
    })();

    const fetchSearch = (async () => {
      try {
        const links = await searchRecipeLinksWithFetch(query, { limit: RECIPE_SEARCH_MAX_LINKS });
        if (links.length) searchMethods.push("fetch");
        return links;
      } catch (error) {
        searchError = errorSummary(error);
        return [];
      }
    })();

    [aiLinks, browserLinks] = await Promise.all([aiSearch, fetchSearch]);
  });

  if (!browserLinks.length && !aiLinks.length) {
    try {
      const playwrightLinks = await timeRecipeImportStage(
        "web_reference_playwright_fallback",
        { jobID, metadata: { query: normalizeText(query, 180) } },
        () => searchRecipeLinksWithPlaywright(query, { limit: RECIPE_SEARCH_MAX_LINKS })
      );
      if (playwrightLinks.length) {
        searchMethods.push("playwright_fallback_empty_fetch");
        browserLinks = playwrightLinks;
      }
    } catch (error) {
      searchError = errorSummary(error);
    }
  }
  const links = mergeRecipeSearchLinks(aiLinks, browserLinks).slice(0, RECIPE_SEARCH_MAX_LINKS);
  const scrapeResults = await timeRecipeImportStage(
    "scraping",
    { jobID, metadata: { link_count: links.length } },
    () => Promise.all(links.map(async (link) => {
      try {
        const source = await extractWebSource(link.url);
        return {
          ok: true,
          source: {
            ...source,
            search_result_title: link.title,
            search_result_url: link.url,
            search_score: scoreScrapedRecipeSource(source, query),
          },
        };
      } catch (error) {
        return {
          ok: false,
          error: {
            url: link.url,
            title: link.title ?? null,
            error: errorSummary(error),
          },
        };
      }
    }))
  );
  const scraped = scrapeResults.filter((entry) => entry.ok).map((entry) => entry.source);
  const scrapeErrors = scrapeResults.filter((entry) => !entry.ok).map((entry) => entry.error);

  const rankedSources = scraped
    .sort((left, right) => right.search_score - left.search_score)
    .slice(0, Math.max(2, Math.min(scraped.length, RECIPE_REFERENCE_MAX_SOURCES)));

  const lead = rankedSources[0] ?? null;
  const title = normalizeText(lead?.title ?? query) || query;
  const description = normalizeText(lead?.description ?? lead?.meta_description ?? "") || null;
  const heroImageURL = cleanURL(lead?.hero_image_url ?? null);

  return {
    source_type: "recipe_search",
    platform: "web_search",
    source_url: null,
    canonical_url: null,
    raw_text: normalizeText(query),
    title,
    description,
    hero_image_url: heroImageURL,
    discover_card_image_url: heroImageURL,
    attachments,
    recipe_sources: rankedSources.map((source) => ({
      title: source.title ?? null,
      site_name: source.site_name ?? null,
      source_url: source.source_url ?? source.search_result_url ?? null,
      canonical_url: source.canonical_url ?? null,
      hero_image_url: source.hero_image_url ?? null,
      ingredient_candidates: source.ingredient_candidates ?? [],
      instruction_candidates: source.instruction_candidates ?? [],
      structured_recipe: source.structured_recipe ?? null,
      search_score: source.search_score ?? 0,
    })),
    source_provenance_json: buildSourceProvenanceRecord({
      source_type: "recipe_search",
      platform: "web_search",
      source_url: null,
      canonical_url: null,
      title,
      description,
      hero_image_url: heroImageURL,
    }, {
      evidenceBundle: {
        source_type: "recipe_search",
        query,
        links,
        source_count: rankedSources.length,
        search_method: searchMethods.join("+") || "none",
        ai_link_count: aiLinks.length,
        browser_link_count: browserLinks.length,
        ai_search_error: aiSearchError,
        search_error: searchError,
        scrape_error_count: scrapeErrors.length,
        scrape_errors: scrapeErrors.slice(0, 6),
        recipe_sources: rankedSources.map((source) => ({
          title: source.title ?? null,
          site_name: source.site_name ?? null,
          canonical_url: source.canonical_url ?? null,
          ingredient_count: Array.isArray(source.ingredient_candidates) ? source.ingredient_candidates.length : 0,
          instruction_count: Array.isArray(source.instruction_candidates) ? source.instruction_candidates.length : 0,
          has_structured_recipe: Boolean(source.structured_recipe),
        })),
      },
    }),
    artifacts: [
      {
        artifact_type: "recipe_search_query",
        content_type: "text/plain",
        text_content: normalizeText(query),
      },
      {
        artifact_type: "recipe_search_results",
        content_type: "application/json",
        raw_json: compactJSON({
          query,
          links,
          search_method: searchMethods.join("+") || "none",
          ai_link_count: aiLinks.length,
          browser_link_count: browserLinks.length,
          ai_search_error: aiSearchError,
          search_error: searchError,
          source_count: rankedSources.length,
          scrape_error_count: scrapeErrors.length,
          scrape_errors: scrapeErrors.slice(0, 6),
        }),
      },
      ...rankedSources.map((source) => ({
        artifact_type: "recipe_search_source",
        content_type: "application/json",
        source_url: source.canonical_url ?? source.search_result_url ?? source.source_url ?? null,
        raw_json: compactJSON({
          title: source.title ?? null,
          site_name: source.site_name ?? null,
          source_url: source.source_url ?? source.search_result_url ?? null,
          canonical_url: source.canonical_url ?? null,
          ingredient_candidates: source.ingredient_candidates ?? [],
          instruction_candidates: source.instruction_candidates ?? [],
          structured_recipe: source.structured_recipe ?? null,
          search_score: source.search_score ?? 0,
        }),
      })),
    ],
  };
}

function buildSourceProvenanceRecord(source, { reviewState = null, confidenceScore = null, qualityFlags = [], evidenceBundle = null } = {}) {
  return {
    source_type: source.source_type ?? null,
    platform: source.platform ?? null,
    media_mode: normalizeText(source.media_mode ?? "") || null,
    source_url: cleanURL(source.source_url ?? null),
    canonical_url: cleanURL(source.canonical_url ?? null),
    attached_video_url: cleanURL(source.attached_video_url ?? null),
    title: normalizeText(source.title ?? "") || null,
    description: normalizeText(source.description ?? source.meta_description ?? "") || null,
    author_name: normalizeText(source.author_name ?? "") || null,
    author_handle: normalizeText(source.author_handle ?? "") || null,
    hero_image_url: cleanURL(source.hero_image_url ?? null),
    transcript_present: Boolean(normalizeText(source.transcript_text ?? "")),
    frame_count: Array.isArray(source.frame_data_urls) ? source.frame_data_urls.length : 0,
    frame_ocr_count: Array.isArray(source.frame_ocr_texts) ? source.frame_ocr_texts.filter((frame) => normalizeText(frame?.text)).length : 0,
    review_state: reviewState ?? null,
    confidence_score: Number.isFinite(confidenceScore) ? Number(confidenceScore) : null,
    quality_flags: uniqueStrings(qualityFlags ?? []),
    evidence_bundle: evidenceBundle ? compactJSON(evidenceBundle) : null,
  };
}

async function supabaseRequest(pathname, { method = "GET", body = null, headers = {} } = {}) {
  assertSupabaseConfig();
  const url = pathname.startsWith("http") ? pathname : `${SUPABASE_URL}${pathname}`;
  const supabaseRestKey = SUPABASE_SERVICE_ROLE_KEY || SUPABASE_ANON_KEY;
  const request = {
    method,
    headers: {
      apikey: supabaseRestKey,
      Authorization: `Bearer ${supabaseRestKey}`,
      Accept: "application/json",
      ...headers,
    },
  };

  if (body != null) {
    request.headers["Content-Type"] = "application/json";
    request.body = JSON.stringify(body);
  }

  const response = await fetch(url, request);
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(data?.message ?? data?.error ?? `${method} ${pathname} failed`);
  }
  return data;
}

async function callSupabaseRpc(functionName, payload) {
  return supabaseRequest(`/rest/v1/rpc/${functionName}`, {
    method: "POST",
    body: payload,
  });
}

async function fetchRows(table, select, { filters = [], order = [], limit = null, offset = null } = {}) {
  let pathname = `/rest/v1/${table}?select=${encodeURIComponent(select)}`;
  for (const filter of filters) {
    if (filter) pathname += `&${filter}`;
  }
  for (const clause of order) {
    if (clause) pathname += `&order=${clause}`;
  }
  if (limit != null) pathname += `&limit=${limit}`;
  if (offset != null) pathname += `&offset=${offset}`;
  const rows = await supabaseRequest(pathname);
  return Array.isArray(rows) ? rows : [];
}

async function countRows(table, { filters = [] } = {}) {
  assertSupabaseConfig();
  let pathname = `/rest/v1/${table}?select=id&limit=1`;
  for (const filter of filters) {
    if (filter) pathname += `&${filter}`;
  }

  const url = `${SUPABASE_URL}${pathname}`;
  const supabaseRestKey = SUPABASE_SERVICE_ROLE_KEY || SUPABASE_ANON_KEY;
  const response = await fetch(url, {
    method: "HEAD",
    headers: {
      apikey: supabaseRestKey,
      Authorization: `Bearer ${supabaseRestKey}`,
      Prefer: "count=exact",
    },
  });
  if (!response.ok) {
    throw new Error(`HEAD ${pathname} failed`);
  }

  const contentRange = response.headers.get("content-range") ?? "";
  const total = Number.parseInt(contentRange.split("/").pop() ?? "", 10);
  return Number.isFinite(total) ? total : 0;
}

async function fetchOneRow(table, select, filters = []) {
  const rows = await fetchRows(table, select, { filters, limit: 1 });
  return rows[0] ?? null;
}

async function insertRows(table, rows, { prefer = "return=representation", onConflict = null } = {}) {
  let pathname = `/rest/v1/${table}`;
  if (onConflict) {
    pathname += `?on_conflict=${encodeURIComponent(onConflict)}`;
  }
  const data = await supabaseRequest(pathname, {
    method: "POST",
    body: rows,
    headers: { Prefer: prefer },
  });
  return Array.isArray(data) ? data : [];
}

async function patchRows(table, filters, payload, { prefer = "return=representation" } = {}) {
  let pathname = `/rest/v1/${table}?${filters.filter(Boolean).join("&")}`;
  const data = await supabaseRequest(pathname, {
    method: "PATCH",
    body: payload,
    headers: { Prefer: prefer },
  });
  return Array.isArray(data) ? data : [];
}

async function deleteRows(table, filters) {
  const pathname = `/rest/v1/${table}?${filters.filter(Boolean).join("&")}`;
  return supabaseRequest(pathname, { method: "DELETE", headers: { Prefer: "return=minimal" } });
}

async function callRpc(name, payload) {
  return supabaseRequest(`/rest/v1/rpc/${name}`, {
    method: "POST",
    body: payload,
  });
}

async function fetchSupabaseStorageObject(bucket, objectPath) {
  const normalizedBucket = normalizeText(bucket ?? "");
  const normalizedPath = normalizeText(objectPath ?? "", 1400);
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !normalizedBucket || !normalizedPath) return null;

  const encodedPath = normalizedPath
    .split("/")
    .map((part) => encodeURIComponent(part))
    .join("/");
  const url = `${SUPABASE_URL.replace(/\/+$/, "")}/storage/v1/object/${encodeURIComponent(normalizedBucket)}/${encodedPath}`;
  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    },
  });
  if (!response.ok) {
    throw new Error(`Storage object fetch failed (${response.status}) for ${normalizedBucket}/${normalizedPath}`);
  }
  const arrayBuffer = await response.arrayBuffer();
  return {
    buffer: Buffer.from(arrayBuffer),
    mime_type: normalizeText(response.headers.get("content-type") ?? "") || null,
  };
}

function normalizeImportPayload(payload = {}) {
  const directSourceText = normalizeText(
    payload.source_text
      ?? payload.sourceText
      ?? payload.text
      ?? payload.source
      ?? ""
  );
  const directSourceURL = cleanURL(payload.source_url ?? payload.sourceURL ?? payload.url ?? null);
  const targetState = ["saved", "prepped"].includes(String(payload.target_state ?? payload.targetState ?? "saved"))
    ? String(payload.target_state ?? payload.targetState ?? "saved")
    : "saved";

  const attachments = Array.isArray(payload.attachments)
    ? payload.attachments.map(normalizeAttachment).filter(Boolean)
    : [];
  const accessToken = normalizeText(payload.access_token ?? payload.accessToken ?? "") || null;
  const photoContext = normalizePhotoRecipeContext(payload.photo_context ?? payload.photoContext ?? null);

  return {
    user_id: normalizeText(payload.user_id ?? payload.userID ?? "") || null,
    source_url: directSourceURL || (directSourceText && isProbablyURL(directSourceText) ? cleanURL(directSourceText) : null),
    source_text: directSourceURL && directSourceText === directSourceURL ? "" : directSourceText,
    attachments,
    target_state: targetState,
    access_token: accessToken,
    photo_context: photoContext,
    source_type: detectRecipeIngestionSourceType({
      sourceUrl: directSourceURL || (directSourceText && isProbablyURL(directSourceText) ? directSourceText : null),
      sourceText: directSourceText,
      attachments,
    }),
  };
}

function normalizePhotoRecipeContext(value) {
  if (!value || typeof value !== "object") return null;
  const pipeline = normalizeText(value.pipeline ?? value.source_pipeline ?? "");
  const dishHint = normalizeText(value.dish_hint ?? value.dishHint ?? value.title_hint ?? "", 180) || null;
  const coarsePlaceContext = normalizeText(value.coarse_place_context ?? value.coarsePlaceContext ?? value.place_context ?? "", 260) || null;
  const normalizedPipeline = pipeline === "photo_to_recipe" || dishHint || coarsePlaceContext ? "photo_to_recipe" : null;
  if (!normalizedPipeline) return null;
  return {
    pipeline: normalizedPipeline,
    dish_hint: dishHint,
    coarse_place_context: coarsePlaceContext,
  };
}

function requiresUserScopedRecipeImport(request) {
  const sourceType = normalizeText(request?.source_type ?? "").toLowerCase();
  return ["tiktok", "instagram", "youtube", "media_video", "media_image"].includes(sourceType);
}

function allowsPublicCatalogRecipeImport(request) {
  const payload = request?.request_payload && typeof request.request_payload === "object"
    ? request.request_payload
    : request ?? {};
  return Boolean(
    payload.public_catalog_import === true
    || payload.publicCatalogImport === true
    || payload.catalog_import === true
    || payload.catalogImport === true
    || process.env.OUNJE_ALLOW_PUBLIC_SOCIAL_RECIPE_IMPORT === "1"
  );
}

function normalizeAttachment(attachment) {
  if (!attachment || typeof attachment !== "object") return null;
  const kind = normalizeText(attachment.kind ?? attachment.type ?? attachment.media_type ?? "").toLowerCase();
  const sourceURL = cleanURL(attachment.url ?? attachment.source_url ?? attachment.sourceURL ?? null);
  const dataURL = normalizeText(attachment.data_url ?? attachment.dataURL ?? attachment.base64 ?? "");
  const mimeType = normalizeText(attachment.mime_type ?? attachment.mimeType ?? "");
  const fileName = normalizeText(attachment.file_name ?? attachment.fileName ?? "");
  const storageBucket = normalizeText(attachment.storage_bucket ?? attachment.storageBucket ?? "");
  const storagePath = normalizeText(attachment.storage_path ?? attachment.storagePath ?? "", 1200);
  const publicHeroURL = cleanURL(attachment.public_hero_url ?? attachment.publicHeroURL ?? null);
  const width = Number.parseInt(attachment.width ?? attachment.pixel_width ?? attachment.pixelWidth ?? "", 10);
  const height = Number.parseInt(attachment.height ?? attachment.pixel_height ?? attachment.pixelHeight ?? "", 10);
  const previewFrames = Array.isArray(attachment.preview_frame_urls)
    ? attachment.preview_frame_urls.map(cleanURL).filter(Boolean)
    : [];
  if (!kind && !sourceURL && !dataURL && !(storageBucket && storagePath)) return null;
  return {
    kind: kind || (mimeType.startsWith("image/") ? "image" : mimeType.startsWith("video/") ? "video" : "unknown"),
    source_url: sourceURL,
    data_url: dataURL || null,
    mime_type: mimeType || null,
    file_name: fileName || null,
    storage_bucket: storageBucket || null,
    storage_path: storagePath || null,
    public_hero_url: publicHeroURL || null,
    width: Number.isFinite(width) && width > 0 ? width : null,
    height: Number.isFinite(height) && height > 0 ? height : null,
    preview_frame_urls: previewFrames,
  };
}

export function detectRecipeIngestionSourceType({ sourceUrl = null, sourceText = "", attachments = [] } = {}) {
  const resolvedURL = cleanURL(sourceUrl ?? (isProbablyURL(sourceText) ? sourceText : null));
  const host = hostForURL(resolvedURL);

  if (resolvedURL) {
    if (/(youtube\.com|youtu\.be)$/i.test(host) || host.includes("youtube.com") || host === "youtu.be") return "youtube";
    if (host.includes("tiktok.com")) return "tiktok";
    if (host.includes("instagram.com")) return "instagram";
    return "web";
  }

  if (Array.isArray(attachments) && attachments.length > 0) {
    if (attachments.some((attachment) => attachment.kind === "video")) return "media_video";
    if (attachments.some((attachment) => attachment.kind === "image")) return "media_image";
  }

  return "text";
}

function looksLikeRecipeIdeaPrompt(value = "") {
  const text = normalizeText(value);
  if (!text) return false;
  if (isProbablyURL(text)) return false;

  const lowered = text.toLowerCase();
  const structuredSignals = [
    "ingredients",
    "instructions",
    "method",
    "directions",
    "step 1",
    "prep time",
    "cook time",
    "serves ",
  ];
  if (structuredSignals.some((signal) => lowered.includes(signal))) {
    return false;
  }

  const promptSignals = [
    /\b(make|create|build|invent|design|generate|suggest|help me|give me|i want|i'd like|can you|please|turn this into)\b/i,
    /\b(healthy|high[- ]protein|low[- ]carb|quick|easy|weeknight|meal prep|comfort food|budget|family[- ]friendly|vegetarian|vegan|keto)\b/i,
  ];
  if (!promptSignals.some((signal) => signal.test(lowered))) {
    return false;
  }

  const lineCount = text.split(/\n+/).filter(Boolean).length;
  const wordCount = text.split(/\s+/).filter(Boolean).length;
  const hasBulletList = /(^|\n)\s*[-*•]\s+/m.test(text);
  const hasNumberedSteps = /(^|\n)\s*\d+[\).\s]/m.test(text);

  if (hasBulletList || hasNumberedSteps || lineCount >= 8) return false;
  return wordCount > 3 && wordCount <= 80;
}

async function fetchPromptRecipeExamples(prompt, limit = 5) {
  if (!openai || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return [];
  }

  try {
    const embedding = await withRecipeAIStage("recipe_import.prompt_examples_embedding", () => openai.embeddings.create({
      model: "text-embedding-3-small",
      input: prompt,
    }));
    const vector = embedding.data?.[0]?.embedding ?? [];
    if (!vector.length) return [];

    const ids = await callSupabaseRpc("match_recipes_basic", {
      query_embedding: `[${vector.join(",")}]`,
      match_count: Math.max(limit * 4, 18),
      filter_type: null,
      max_cook_minutes: null,
    });

    const rankedIds = (ids ?? [])
      .map((row) => String(row?.id ?? row?.recipe_id ?? "").trim())
      .filter(Boolean);

    if (!rankedIds.length) return [];

    const rows = await fetchRows(
      "recipes",
      "id,title,description,recipe_type,cuisine_tags,dietary_tags,cook_time_text,ingredients_text,instructions_text",
      {
        filters: [`id=in.${buildInClause(rankedIds)}`],
      }
    );

    const promptSignals = extractIngredientSignals(prompt);
    return rows
      .map((row) => ({
        ...row,
        _score: scoreFlavorAlignment(row, promptSignals, []) + (rankedIds.length - rankedIds.indexOf(row.id)),
      }))
      .sort((left, right) => right._score - left._score)
      .slice(0, limit)
      .map(({ _score, ...row }) => row);
  } catch {
    return [];
  }
}

async function fetchJobRow(jobID) {
  try {
    return await fetchOneRow(
      "recipe_ingestion_jobs",
      "id,user_id,target_state,source_type,source_url,canonical_url,input_text,request_payload,dedupe_key,dedupe_recipe_id,evidence_bundle_id,recipe_id,status,review_state,confidence_score,quality_flags,review_reason,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,fetched_at,parsed_at,normalized_at,saved_at,completed_at,created_at,updated_at,event_log",
      [`id=eq.${encodeURIComponent(jobID)}`]
    );
  } catch {
    return fetchOneRow(
      "recipe_ingestion_jobs",
      "id,user_id,target_state,source_type,source_url,canonical_url,input_text,request_payload,dedupe_key,dedupe_recipe_id,recipe_id,status,review_state,confidence_score,quality_flags,review_reason,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,fetched_at,parsed_at,normalized_at,saved_at,completed_at,created_at,updated_at,event_log",
      [`id=eq.${encodeURIComponent(jobID)}`]
    );
  }
}

async function fetchLatestJobArtifact(jobID, artifactType) {
  if (!jobID || !artifactType) return null;
  const rows = await fetchRows(
    "recipe_ingestion_artifacts",
    "id,job_id,artifact_type,content_type,source_url,text_content,raw_json,metadata,created_at",
    {
      filters: [
        `job_id=eq.${encodeURIComponent(jobID)}`,
        `artifact_type=eq.${encodeURIComponent(artifactType)}`,
      ],
      order: ["created_at.desc"],
      limit: 1,
    }
  );
  return rows[0] ?? null;
}

function summarizeCompletedImportJob(jobRow, recipeProjection = null) {
  const requestPayload = jobRow?.request_payload && typeof jobRow.request_payload === "object"
    ? jobRow.request_payload
    : {};
  const rawSourceURL = normalizeText(
    jobRow?.canonical_url
      ?? jobRow?.source_url
      ?? requestPayload?.canonical_url
      ?? requestPayload?.source_url
      ?? recipeProjection?.recipe_url
      ?? null
  );
  const title = normalizeText(
    recipeProjection?.title
      ?? requestPayload?.title
      ?? jobRow?.input_text
      ?? rawSourceURL
      ?? "Imported recipe"
  ) || "Imported recipe";

  return {
    id: jobRow.id,
    recipe_id: jobRow.recipe_id ?? null,
    title,
    status: jobRow.status ?? "saved",
    review_state: jobRow.review_state ?? "approved",
    source_type: normalizeText(jobRow.source_type ?? requestPayload?.source_type ?? null) || "shared_import",
    source_url: rawSourceURL || null,
    canonical_url: normalizeText(jobRow?.canonical_url ?? requestPayload?.canonical_url ?? null) || null,
    source_text: normalizeText(jobRow?.input_text ?? requestPayload?.source_text ?? null) || null,
    recipe_url: rawSourceURL || null,
    image_url: recipeProjection?.discover_card_image_url
      ?? recipeProjection?.hero_image_url
      ?? null,
    source: recipeProjection?.source ?? null,
    cook_time_text: recipeProjection?.cook_time_text ?? null,
    completed_at: jobRow.completed_at ?? jobRow.saved_at ?? jobRow.updated_at ?? null,
    created_at: jobRow.created_at ?? null,
  };
}

function summarizeCompletedImportedRecipe(row) {
  const rawSourceURL = normalizeText(
    row?.original_recipe_url
      ?? row?.recipe_url
      ?? row?.attached_video_url
      ?? null
  );
  const sourceType = normalizeText(row?.source_platform ?? row?.source ?? "");

  return {
    id: row?.source_job_id ?? `imported:${row.id}`,
    recipe_id: row?.id ?? null,
    title: normalizeText(row?.title) || "Imported recipe",
    status: "saved",
    review_state: row?.review_state ?? "approved",
    source_type: sourceType || null,
    source_url: rawSourceURL || null,
    canonical_url: normalizeText(row?.original_recipe_url ?? null) || null,
    source_text: null,
    recipe_url: rawSourceURL || null,
    image_url: row?.discover_card_image_url ?? row?.hero_image_url ?? null,
    source: row?.source ?? null,
    cook_time_text: row?.cook_time_text ?? null,
    completed_at: row?.updated_at ?? row?.created_at ?? null,
    created_at: row?.created_at ?? null,
  };
}

function summarizeRecipeImportQueueJob(jobRow) {
  const requestPayload = jobRow?.request_payload && typeof jobRow.request_payload === "object"
    ? jobRow.request_payload
    : {};
  return {
    id: jobRow.id,
    user_id: jobRow.user_id ?? null,
    target_state: jobRow.target_state ?? requestPayload?.target_state ?? "saved",
    source_type: jobRow.source_type ?? requestPayload?.source_type ?? null,
    source_url: normalizeText(jobRow.source_url ?? requestPayload?.source_url ?? null) || null,
    canonical_url: normalizeText(jobRow.canonical_url ?? requestPayload?.canonical_url ?? null) || null,
    source_text: normalizeText(jobRow.input_text ?? requestPayload?.source_text ?? null) || null,
    recipe_id: jobRow.recipe_id ?? null,
    status: jobRow.status ?? "queued",
    review_state: jobRow.review_state ?? "pending",
    confidence_score: jobRow.confidence_score ?? null,
    quality_flags: Array.isArray(jobRow.quality_flags) ? jobRow.quality_flags : [],
    review_reason: jobRow.review_reason ?? null,
    error_message: jobRow.error_message ?? null,
    attempts: Number.isFinite(Number(jobRow.attempts)) ? Number(jobRow.attempts) : null,
    max_attempts: Number.isFinite(Number(jobRow.max_attempts)) ? Number(jobRow.max_attempts) : null,
    created_at: jobRow.created_at ?? null,
    updated_at: jobRow.updated_at ?? null,
  };
}

export async function listRecipeImportQueueItems({ userID = null, limit = null } = {}) {
  const filters = [
    `status=in.${buildInClause(["queued", "retryable", "processing", "fetching", "parsing", "normalized", "failed"])}`,
  ];
  if (userID) {
    filters.push(`user_id=eq.${encodeURIComponent(userID)}`);
  }

  const parsedLimit = Number.parseInt(String(limit ?? ""), 10);
  const resolvedLimit = Number.isFinite(parsedLimit) && parsedLimit > 0
    ? Math.min(parsedLimit, 200)
    : 100;

  let totalCount = 0;
  try {
    totalCount = await countRows("recipe_ingestion_jobs", { filters });
  } catch {
    totalCount = 0;
  }

  const rows = await fetchRows(
    "recipe_ingestion_jobs",
    "id,user_id,target_state,source_type,source_url,canonical_url,input_text,request_payload,recipe_id,status,review_state,confidence_score,quality_flags,review_reason,error_message,attempts,max_attempts,created_at,updated_at",
    {
      filters,
      order: ["updated_at.desc", "created_at.desc"],
      limit: resolvedLimit,
    }
  );

  return {
    items: rows.map(summarizeRecipeImportQueueJob),
    totalCount,
  };
}

export async function listCompletedRecipeImportItems({ userID = null, limit = null } = {}) {
  const filters = [
    `status=in.${buildInClause(["saved", "needs_review", "draft"])}`,
  ];
  if (userID) {
    filters.push(`user_id=eq.${encodeURIComponent(userID)}`);
  }

  const selectVariants = [
    "id,user_id,target_state,source_type,source_url,canonical_url,input_text,request_payload,dedupe_key,dedupe_recipe_id,evidence_bundle_id,recipe_id,status,review_state,confidence_score,quality_flags,review_reason,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,fetched_at,parsed_at,normalized_at,saved_at,completed_at,created_at,updated_at,event_log",
    "id,user_id,target_state,source_type,source_url,canonical_url,input_text,request_payload,dedupe_key,dedupe_recipe_id,recipe_id,status,review_state,confidence_score,quality_flags,review_reason,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,fetched_at,parsed_at,normalized_at,saved_at,completed_at,created_at,updated_at,event_log",
  ];

  let rows = [];
  let importedRows = [];
  let lastError = null;
  let totalCount = 0;
  let importedTotalCount = 0;
  try {
    totalCount = await countRows("recipe_ingestion_jobs", { filters });
  } catch {
    totalCount = 0;
  }
  try {
    const importedFilters = userID ? [`user_id=eq.${encodeURIComponent(userID)}`] : [];
    importedTotalCount = await countRows(USER_IMPORTED_RECIPE_TABLE_CONFIG.recipeTable, { filters: importedFilters });
  } catch {
    importedTotalCount = 0;
  }

  const parsedLimit = Number.parseInt(String(limit ?? ""), 10);
  const resolvedLimit = Number.isFinite(parsedLimit) && parsedLimit > 0
    ? Math.min(parsedLimit, 500)
    : null;

  for (const select of selectVariants) {
    try {
      rows = await fetchRows(
        "recipe_ingestion_jobs",
        select,
        {
          filters,
          order: ["completed_at.desc", "updated_at.desc", "created_at.desc"],
          limit: resolvedLimit,
        }
      );
      lastError = null;
      break;
    } catch (error) {
      lastError = error;
    }
  }

  if (lastError) {
    throw lastError;
  }

  try {
    const importedFilters = userID ? [`user_id=eq.${encodeURIComponent(userID)}`] : [];
    importedRows = await fetchRows(
      USER_IMPORTED_RECIPE_TABLE_CONFIG.recipeTable,
      "id,user_id,source_job_id,title,source,source_platform,recipe_url,original_recipe_url,attached_video_url,hero_image_url,discover_card_image_url,cook_time_text,review_state,created_at,updated_at",
      {
        filters: importedFilters,
        order: ["updated_at.desc", "created_at.desc"],
        limit: resolvedLimit,
      }
    );
  } catch {
    importedRows = [];
  }

  const importedRecipeIDs = new Set(importedRows.map((row) => normalizeText(row?.id)).filter(Boolean));
  const importedSourceJobIDs = new Set(importedRows.map((row) => normalizeText(row?.source_job_id)).filter(Boolean));
  const importedItems = importedRows.map(summarizeCompletedImportedRecipe);
  const jobItems = rows
    .filter((row) => {
      const recipeID = normalizeText(row?.recipe_id);
      const jobID = normalizeText(row?.id);
      return (!recipeID || !importedRecipeIDs.has(recipeID)) && (!jobID || !importedSourceJobIDs.has(jobID));
    })
    .map((row) => summarizeCompletedImportJob(row, null));
  const timestampValue = (item) => {
    const parsed = Date.parse(item?.completed_at ?? item?.created_at ?? "");
    return Number.isFinite(parsed) ? parsed : 0;
  };
  const items = [...jobItems, ...importedItems]
    .sort((left, right) => timestampValue(right) - timestampValue(left));
  return {
    items,
    totalCount: Math.max(importedTotalCount || 0, items.length),
  };
}

async function appendJobEvent(jobID, eventName, details = {}, patch = {}) {
  const current = await fetchJobRow(jobID);
  if (!current) {
    throw new Error(`Ingestion job ${jobID} not found.`);
  }

  const eventLog = Array.isArray(current.event_log) ? current.event_log : [];
  const nextLog = [
    ...eventLog,
    {
      event: eventName,
      at: nowIso(),
      ...details,
    },
  ];

  const rows = await patchRecipeIngestionJobRow(jobID, { ...patch, event_log: nextLog });
  const nextJob = rows[0] ?? { ...current, ...patch, event_log: nextLog };
  await broadcastRecipeImportInvalidation(nextJob, eventName);
  return nextJob;
}

async function broadcastRecipeImportInvalidation(job, eventName) {
  const userID = normalizeText(job?.user_id);
  if (!userID) return;

  const status = normalizeText(job?.status);
  let realtimeEvent = "recipe_import.updated";
  if (status === "failed") {
    realtimeEvent = "recipe_import.failed";
  } else if (["saved", "draft"].includes(status)) {
    realtimeEvent = "recipe_import.completed";
  }

  await broadcastUserInvalidation(userID, realtimeEvent, {
    job_id: job?.id ?? null,
    recipe_id: job?.recipe_id ?? null,
    source_type: job?.source_type ?? null,
    status: status || null,
    review_state: job?.review_state ?? null,
    event: eventName,
  });

  // Also drop a row into app_notification_events so the user gets a banner
  // / APNs push for completed / failed transitions. The client/share
  // extension owns the immediate queued notification to avoid duplicate
  // "Added to queue" alerts from local + backend delivery paths.
  try {
    await maybeEmitRecipeImportNotification(job, eventName);
  } catch (cause) {
    console.warn("[recipe-ingestion] notification emit failed:", cause.message);
  }
}

async function maybeEmitRecipeImportNotification(job, eventName) {
  const userID = normalizeText(job?.user_id);
  if (!userID) return;
  const status = normalizeText(job?.status);
  const jobID = normalizeText(job?.id);
  if (!jobID) return;

  // Lazy-load the notification helper to avoid a cycle (notification-events
  // → push-tokens → recipe-ingestion would loop on import resolution).
  const { createNotificationEvent } = await import("./notification-events.js");

  const title = pickRecipeTitle(job);

  if (status === "queued" && eventName === "queued") {
    return;
  } else if (["saved", "draft"].includes(status)) {
    await createNotificationEvent({
      userId: userID,
      kind: "recipe_import_completed",
      dedupeKey: `recipe-import-completed:${jobID}`,
      title: title ? `Your recipe is ready` : "Your recipe is ready",
      body: title ? `"${title}" is now in your cookbook. Tap to take a look.` : "Tap to take a look at your new recipe.",
      recipeId: normalizeText(job?.recipe_id) || null,
      actionUrl: job?.recipe_id ? `ounje://recipe/${encodeURIComponent(job.recipe_id)}` : null,
      actionLabel: "Open recipe",
      metadata: { job_id: jobID, status },
    });
  } else if (status === "failed") {
    await createNotificationEvent({
      userId: userID,
      kind: "recipe_import_failed",
      dedupeKey: `recipe-import-failed:${jobID}`,
      title: "Recipe import didn't work",
      body: title ? `We couldn't build "${title}". Tap to try again.` : "Something went wrong importing your recipe. Tap to try again.",
      actionUrl: "ounje://cookbook/import",
      actionLabel: "Try again",
      metadata: { job_id: jobID, status, error: normalizeText(job?.error_message) || null },
    });
  }
}

function pickRecipeTitle(job) {
  if (!job) return null;
  // The job's request_payload sometimes carries a parsed title; fall back to
  // the source url or null. Avoid throwing on weird shapes.
  try {
    const payload = job.request_payload;
    if (payload && typeof payload === "object") {
      if (typeof payload.title === "string" && payload.title.trim()) return payload.title.trim();
      if (typeof payload.parsed_title === "string" && payload.parsed_title.trim()) return payload.parsed_title.trim();
    }
  } catch (_) { /* noop */ }
  return null;
}

async function findExistingJobForRequest(request, dedupeKey) {
  if (!dedupeKey) return null;

  const userFilter = request.user_id
    ? `user_id=eq.${encodeURIComponent(request.user_id)}`
    : "user_id=is.null";

  const rows = await fetchRows(
    "recipe_ingestion_jobs",
    "id,user_id,target_state,source_type,source_url,canonical_url,input_text,request_payload,dedupe_key,dedupe_recipe_id,recipe_id,status,review_state,confidence_score,quality_flags,review_reason,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,fetched_at,parsed_at,normalized_at,saved_at,completed_at,created_at,updated_at,event_log",
    {
      filters: [
        `dedupe_key=eq.${encodeURIComponent(dedupeKey)}`,
        userFilter,
      ],
      order: ["created_at.desc"],
      limit: 1,
    }
  );

  const existing = rows[0] ?? null;
  if (!existing) return null;

  return normalizeText(existing.status).toLowerCase() === "failed" ? null : existing;
}

async function findExistingJobForRequestSource(request, dedupeKey = null) {
  const candidateURLs = urlLookupVariants(
    request.source_url,
    request.canonical_url,
  );
  if (!candidateURLs.length && !dedupeKey) return null;

  const sourceFilters = [];
  for (const url of candidateURLs) {
    sourceFilters.push(`source_url.eq.${encodeURIComponent(url)}`);
    sourceFilters.push(`canonical_url.eq.${encodeURIComponent(url)}`);
  }
  if (dedupeKey) {
    sourceFilters.push(`dedupe_key.eq.${encodeURIComponent(dedupeKey)}`);
  }
  if (!sourceFilters.length) return null;

  const userFilter = request.user_id
    ? `user_id=eq.${encodeURIComponent(request.user_id)}`
    : "user_id=is.null";

  const rows = await fetchRows(
    "recipe_ingestion_jobs",
    "id,user_id,target_state,source_type,source_url,canonical_url,input_text,request_payload,dedupe_key,dedupe_recipe_id,recipe_id,status,review_state,confidence_score,quality_flags,review_reason,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,fetched_at,parsed_at,normalized_at,saved_at,completed_at,created_at,updated_at,event_log",
    {
      filters: [
        userFilter,
        `or=(${sourceFilters.join(",")})`,
      ],
      order: ["completed_at.desc", "updated_at.desc", "created_at.desc"],
      limit: 8,
    }
  );

  return rows.find((row) => normalizeText(row.status).toLowerCase() !== "failed") ?? null;
}

async function findCompletedCanonicalImportForRequest(request, { canonicalURL = null, dedupeKey = null, excludeJobID = null, scope = "user" } = {}) {
  const cacheableURL = cleanURL(canonicalURL ?? request.canonical_url ?? request.source_url ?? null);
  const cacheDedupeKey = dedupeKey ?? buildDedupeKey({
    sourceUrl: request.source_url,
    canonicalUrl: cacheableURL,
    sourceText: request.source_text,
  });
  if (!cacheableURL && !cacheDedupeKey) return null;
  if (!isCanonicalCacheableSource(request.source_type, cacheableURL ?? request.source_url)) return null;

  // Fast path: in-memory cache hit (avoids DB round-trip for repeated URLs).
  const cacheUserID = scope === "global" ? GLOBAL_IMPORT_CACHE_NAMESPACE : request.user_id;
  const memCached = await _getCanonicalImportCache(cacheUserID, cacheableURL, cacheDedupeKey);
  if (memCached && (!excludeJobID || memCached.id !== excludeJobID)) return memCached;

  const sourceFilters = [];
  const candidateURLs = urlLookupVariants(
    cacheableURL,
    request.canonical_url,
    request.source_url,
  );
  for (const url of candidateURLs) {
    sourceFilters.push(`canonical_url.eq.${encodeURIComponent(url)}`);
    sourceFilters.push(`source_url.eq.${encodeURIComponent(url)}`);
  }
  if (cacheDedupeKey) {
    sourceFilters.push(`dedupe_key.eq.${encodeURIComponent(cacheDedupeKey)}`);
  }
  if (!sourceFilters.length) return null;

  const filters = [
    `status=in.${buildInClause(["saved", "draft", "needs_review"])}`,
    "recipe_id=not.is.null",
    `or=(${sourceFilters.join(",")})`,
  ];
  if (scope !== "global") {
    filters.unshift(request.user_id
      ? `user_id=eq.${encodeURIComponent(request.user_id)}`
      : "user_id=is.null");
  }
  if (excludeJobID) {
    filters.push(`id=neq.${encodeURIComponent(excludeJobID)}`);
  }

  const rows = await fetchRows(
    "recipe_ingestion_jobs",
    "id,user_id,target_state,source_type,source_url,canonical_url,input_text,request_payload,dedupe_key,dedupe_recipe_id,recipe_id,status,review_state,confidence_score,quality_flags,review_reason,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,fetched_at,parsed_at,normalized_at,saved_at,completed_at,created_at,updated_at,event_log",
    {
      filters,
      order: ["completed_at.desc", "saved_at.desc", "updated_at.desc", "created_at.desc"],
      limit: 1,
    }
  );

  const result = rows[0] ?? null;
  if (result) {
    _setCanonicalImportCache(cacheUserID, cacheableURL, cacheDedupeKey, result);
  }
  return result;
}

async function findExistingUserImportedRecipeForRequest(request, { canonicalURL = null, dedupeKey = null } = {}) {
  const userID = normalizeText(request?.user_id ?? "");
  if (!userID) return null;

  if (dedupeKey) {
    const rows = await fetchRows(
      USER_IMPORTED_RECIPE_TABLE_CONFIG.recipeTable,
      "id,title,source,recipe_url,original_recipe_url,attached_video_url,dedupe_key",
      {
        filters: [
          `user_id=eq.${encodeURIComponent(userID)}`,
          `dedupe_key=eq.${encodeURIComponent(dedupeKey)}`,
        ],
        order: ["updated_at.desc", "created_at.desc"],
        limit: 1,
      }
    );
    if (rows[0]) return rows[0];
  }

  const candidateURLs = urlLookupVariants(
    canonicalURL,
    request?.canonical_url,
    request?.source_url,
  );
  if (!candidateURLs.length) return null;

  for (const column of ["recipe_url", "original_recipe_url", "attached_video_url"]) {
    const rows = await fetchRows(
      USER_IMPORTED_RECIPE_TABLE_CONFIG.recipeTable,
      "id,title,source,recipe_url,original_recipe_url,attached_video_url,dedupe_key",
      {
        filters: [
          `user_id=eq.${encodeURIComponent(userID)}`,
          `${column}=in.${buildInClause(candidateURLs)}`,
        ],
        order: ["updated_at.desc", "created_at.desc"],
        limit: 1,
      }
    );
    if (rows[0]) return rows[0];
  }

  return null;
}

async function completeJobFromCachedCanonicalImport(job, cachedJob, { workerID, canonicalURL = null } = {}) {
  if (!cachedJob?.recipe_id) return null;
  const now = nowIso();
  const completed = await appendJobEvent(job.id, "canonical_cache_hit", {
    worker_id: workerID,
    cached_job_id: cachedJob.id,
    recipe_id: cachedJob.recipe_id,
  }, {
    status: "saved",
    canonical_url: canonicalURL ?? cachedJob.canonical_url ?? cachedJob.source_url ?? job.canonical_url ?? job.source_url ?? null,
    dedupe_recipe_id: cachedJob.recipe_id,
    recipe_id: cachedJob.recipe_id,
    review_state: cachedJob.review_state ?? "approved",
    confidence_score: cachedJob.confidence_score ?? job.confidence_score ?? null,
    quality_flags: uniqueStrings([...(job.quality_flags ?? []), "canonical_cache_hit"]),
    review_reason: cachedJob.review_reason ?? job.review_reason ?? null,
    error_message: null,
    saved_at: job.saved_at ?? now,
    completed_at: now,
  });
  const recipe = await fetchRecipeCardProjection(cachedJob.recipe_id).catch(() => null);
  const recipeDetail = await fetchCanonicalRecipeDetailByID(cachedJob.recipe_id).catch(() => null);
  await warmRecipeDetailCache({
    userID: completed.user_id,
    recipeID: cachedJob.recipe_id,
    recipeDetail,
  });
  invalidateUserBootstrapCache(completed.user_id);
  return formatJobResponse(completed, {
    recipe,
    recipe_detail: recipeDetail,
  });
}

async function completeJobByCloningGlobalImportedRecipe(job, cachedJob, { workerID, canonicalURL = null, dedupeKey = null } = {}) {
  const sourceRecipeID = normalizeText(cachedJob?.recipe_id ?? "");
  const targetUserID = normalizeText(job?.user_id ?? "");
  if (!sourceRecipeID || !targetUserID) return null;

  const sourceDetail = await fetchCanonicalRecipeDetailByID(sourceRecipeID).catch(() => null);
  if (!sourceDetail) return null;

  const cloneSource = { ...sourceDetail };
  delete cloneSource.id;

  const persisted = await persistNormalizedRecipe(cloneSource, {
    userID: targetUserID,
    targetState: job.target_state,
    sourceJobID: job.id,
    dedupeKey: dedupeKey ?? job.dedupe_key ?? cachedJob.dedupe_key ?? null,
    reviewState: cachedJob.review_state ?? "approved",
    confidenceScore: cachedJob.confidence_score ?? 0.98,
    qualityFlags: uniqueStrings([...(cachedJob.quality_flags ?? []), "global_import_cache_hit"]),
  });

  const now = nowIso();
  const completed = await appendJobEvent(job.id, "global_import_cache_hit", {
    worker_id: workerID,
    cached_job_id: cachedJob.id,
    cached_recipe_id: sourceRecipeID,
    recipe_id: persisted.recipe_id,
  }, {
    status: "saved",
    canonical_url: canonicalURL ?? cachedJob.canonical_url ?? cachedJob.source_url ?? job.canonical_url ?? job.source_url ?? null,
    dedupe_key: dedupeKey ?? job.dedupe_key ?? cachedJob.dedupe_key ?? null,
    dedupe_recipe_id: sourceRecipeID,
    recipe_id: persisted.recipe_id,
    review_state: cachedJob.review_state ?? "approved",
    confidence_score: cachedJob.confidence_score ?? job.confidence_score ?? null,
    quality_flags: uniqueStrings([...(job.quality_flags ?? []), "global_import_cache_hit"]),
    review_reason: cachedJob.review_reason ?? job.review_reason ?? null,
    error_message: null,
    saved_at: job.saved_at ?? now,
    completed_at: now,
  });

  _setCanonicalImportCache(targetUserID, completed.canonical_url ?? canonicalURL ?? null, completed.dedupe_key ?? null, completed);
  _setCanonicalImportCache(GLOBAL_IMPORT_CACHE_NAMESPACE, completed.canonical_url ?? canonicalURL ?? null, completed.dedupe_key ?? null, completed);
  await warmRecipeDetailCache({
    userID: completed.user_id,
    recipeID: persisted.recipe_id,
    recipeDetail: persisted.recipe_detail,
  });
  if (persisted.saved_state === "inserted") {
    scheduleUserImportEmbedding(persisted.recipe_id, persisted.recipe_detail, { jobID: job.id });
  }
  invalidateUserBootstrapCache(completed.user_id);
  return formatJobResponse(completed, {
    recipe: persisted.recipe_card,
    recipe_detail: persisted.recipe_detail,
  });
}

async function completeJobFromExistingImportedRecipe(job, recipeRow, { workerID, canonicalURL = null, dedupeKey = null } = {}) {
  const recipeID = normalizeText(recipeRow?.id ?? "");
  if (!recipeID) return null;
  const now = nowIso();
  const completed = await appendJobEvent(job.id, "existing_import_cache_hit", {
    worker_id: workerID,
    recipe_id: recipeID,
  }, {
    status: "saved",
    canonical_url: canonicalURL ?? job.canonical_url ?? job.source_url ?? null,
    dedupe_key: dedupeKey ?? job.dedupe_key ?? recipeRow?.dedupe_key ?? null,
    dedupe_recipe_id: recipeID,
    recipe_id: recipeID,
    review_state: "approved",
    confidence_score: job.confidence_score ?? 0.98,
    quality_flags: uniqueStrings([...(job.quality_flags ?? []), "existing_import_cache_hit"]),
    review_reason: null,
    error_message: null,
    saved_at: job.saved_at ?? now,
    completed_at: now,
  });
  _setCanonicalImportCache(job.user_id, completed.canonical_url ?? canonicalURL ?? null, completed.dedupe_key ?? null, completed);
  const recipe = await fetchRecipeCardProjection(recipeID).catch(() => null);
  const recipeDetail = await fetchCanonicalRecipeDetailByID(recipeID).catch(() => null);
  await warmRecipeDetailCache({
    userID: completed.user_id,
    recipeID,
    recipeDetail,
  });
  invalidateUserBootstrapCache(completed.user_id);
  return formatJobResponse(completed, {
    recipe,
    recipe_detail: recipeDetail,
  });
}

async function createCompletedJobRowFromExistingImportedRecipe(request, recipeRow, { dedupeKey = null, canonicalURL = null } = {}) {
  const recipeID = normalizeText(recipeRow?.id ?? "");
  if (!recipeID) return null;
  const now = nowIso();
  const completed = await insertRecipeIngestionJobRow({
    id: `ri_${nanoid(14)}`,
    user_id: request.user_id,
    target_state: request.target_state,
    source_type: request.source_type,
    source_url: request.source_url,
    canonical_url: canonicalURL ?? request.canonical_url ?? request.source_url ?? null,
    input_text: request.source_text || null,
    request_payload: {
      source_url: request.source_url,
      canonical_url: canonicalURL ?? request.canonical_url ?? request.source_url ?? null,
      source_text: request.source_text || null,
      attachments: request.attachments ?? [],
      photo_context: request.photo_context ?? null,
      target_state: request.target_state,
    },
    dedupe_key: dedupeKey ?? recipeRow?.dedupe_key ?? null,
    dedupe_recipe_id: recipeID,
    recipe_id: recipeID,
    status: "saved",
    review_state: "approved",
    confidence_score: 0.98,
    quality_flags: ["existing_import_cache_hit"],
    review_reason: null,
    error_message: null,
    saved_at: now,
    completed_at: now,
    event_log: [
      {
        event: "existing_import_cache_hit",
        at: now,
        recipe_id: recipeID,
        source_type: request.source_type,
        target_state: request.target_state,
      },
    ],
  });
  _setCanonicalImportCache(request.user_id, completed.canonical_url ?? null, completed.dedupe_key ?? null, completed);
  return completed;
}

function isCompletedImportJobWithRecipe(job) {
  const status = normalizeText(job?.status).toLowerCase();
  return ["saved", "draft", "needs_review"].includes(status) && Boolean(normalizeText(job?.recipe_id ?? ""));
}

async function createCompletedJobRowFromExistingJob(request, job, { dedupeKey = null, canonicalURL = null } = {}) {
  if (!isCompletedImportJobWithRecipe(job)) return null;
  return createCompletedJobRowFromExistingImportedRecipe(
    request,
    {
      id: job.recipe_id,
      dedupe_key: job.dedupe_key ?? dedupeKey ?? null,
    },
    {
      dedupeKey: dedupeKey ?? job.dedupe_key ?? null,
      canonicalURL: canonicalURL ?? job.canonical_url ?? job.source_url ?? request.canonical_url ?? request.source_url ?? null,
    }
  );
}

async function createJobRow(request) {
  const jobID = `ri_${nanoid(14)}`;
  const photoAttachmentKey = request.source_type === "media_image"
    ? (request.attachments ?? [])
        .map((attachment) => [
          attachment.storage_bucket,
          attachment.storage_path,
          attachment.public_hero_url,
          attachment.source_url,
        ].filter(Boolean).join("/"))
        .find(Boolean)
    : null;
  const dedupeKey = photoAttachmentKey
    ? crypto.createHash("sha256").update(photoAttachmentKey).digest("hex")
    : buildDedupeKey({
        sourceUrl: request.source_url,
        canonicalUrl: request.canonical_url ?? request.source_url,
        sourceText: request.source_text,
      });

  const enqueueLockKey = dedupeKey
    ? recipeImportLockKey("enqueue", `${request.user_id ?? "anon"}:${dedupeKey}`)
    : null;
  const enqueueLockToken = enqueueLockKey
    ? await acquireRedisLock(enqueueLockKey, IMPORT_ENQUEUE_LOCK_TTL_SECONDS)
    : null;

  if (enqueueLockKey && !enqueueLockToken) {
    const lockedExisting = await findExistingJobForRequest(request, dedupeKey)
      ?? await findExistingJobForRequestSource(request, dedupeKey);
    if (lockedExisting) {
      const completed = await createCompletedJobRowFromExistingJob(request, lockedExisting, {
        dedupeKey: lockedExisting.dedupe_key ?? dedupeKey ?? null,
        canonicalURL: lockedExisting.canonical_url ?? lockedExisting.source_url ?? request.canonical_url ?? request.source_url ?? null,
      });
      if (completed) return completed;
      return lockedExisting;
    }
    await delay(200);
    const settledExisting = await findExistingJobForRequest(request, dedupeKey)
      ?? await findExistingJobForRequestSource(request, dedupeKey);
    if (settledExisting) {
      const completed = await createCompletedJobRowFromExistingJob(request, settledExisting, {
        dedupeKey: settledExisting.dedupe_key ?? dedupeKey ?? null,
        canonicalURL: settledExisting.canonical_url ?? settledExisting.source_url ?? request.canonical_url ?? request.source_url ?? null,
      });
      if (completed) return completed;
      return settledExisting;
    }
  }

  try {
  const existing = await findExistingJobForRequest(request, dedupeKey);
  if (existing) {
    const completed = await createCompletedJobRowFromExistingJob(request, existing, {
      dedupeKey,
      canonicalURL: request.canonical_url ?? request.source_url ?? null,
    });
    if (completed) return completed;
    return existing;
  }

  const existingForSource = await findExistingJobForRequestSource(request, dedupeKey);
  if (existingForSource) {
    _setCanonicalImportCache(
      request.user_id,
      existingForSource.canonical_url ?? existingForSource.source_url ?? request.source_url ?? null,
      existingForSource.dedupe_key ?? dedupeKey ?? null,
      existingForSource
    );
    const completed = await createCompletedJobRowFromExistingJob(request, existingForSource, {
      dedupeKey: existingForSource.dedupe_key ?? dedupeKey ?? null,
      canonicalURL: existingForSource.canonical_url ?? existingForSource.source_url ?? request.canonical_url ?? request.source_url ?? null,
    });
    if (completed) return completed;
    return existingForSource;
  }

  const completedCanonical = await findCompletedCanonicalImportForRequest(request, {
    canonicalURL: request.canonical_url ?? request.source_url ?? null,
    dedupeKey,
  });
  if (completedCanonical) {
    const completed = await createCompletedJobRowFromExistingJob(request, completedCanonical, {
      dedupeKey: completedCanonical.dedupe_key ?? dedupeKey ?? null,
      canonicalURL: completedCanonical.canonical_url ?? completedCanonical.source_url ?? request.canonical_url ?? request.source_url ?? null,
    });
    if (completed) return completed;
    return completedCanonical;
  }

  const existingImportedRecipe = await findExistingUserImportedRecipeForRequest(request, {
    canonicalURL: request.canonical_url ?? request.source_url ?? null,
    dedupeKey,
  });
  if (existingImportedRecipe) {
    const completed = await createCompletedJobRowFromExistingImportedRecipe(request, existingImportedRecipe, {
      dedupeKey,
      canonicalURL: request.canonical_url ?? request.source_url ?? null,
    });
    if (completed) return completed;
  }

  const created = await insertRecipeIngestionJobRow({
    id: jobID,
    user_id: request.user_id,
    target_state: request.target_state,
    source_type: request.source_type,
    source_url: request.source_url,
    canonical_url: request.canonical_url ?? request.source_url ?? null,
    evidence_bundle_id: null,
    input_text: request.source_text || null,
    request_payload: {
      source_url: request.source_url,
      canonical_url: request.canonical_url ?? request.source_url ?? null,
      source_text: request.source_text || null,
      attachments: request.attachments ?? [],
      photo_context: request.photo_context ?? null,
      target_state: request.target_state,
    },
    dedupe_key: dedupeKey,
    status: "queued",
    review_state: "pending",
    event_log: [
      {
        event: "queued",
        at: nowIso(),
        source_type: request.source_type,
        target_state: request.target_state,
      },
    ],
  });

  return created;
  } finally {
    if (enqueueLockToken) {
      void releaseRedisLock(enqueueLockKey, enqueueLockToken);
    }
  }
}

async function storeArtifact(jobID, artifact) {
  const payload = {
    id: `ria_${nanoid(14)}`,
    job_id: jobID,
    artifact_type: normalizeText(artifact.artifact_type ?? artifact.artifactType ?? "artifact") || "artifact",
    content_type: normalizeText(artifact.content_type ?? artifact.contentType ?? "") || null,
    source_url: cleanURL(artifact.source_url ?? artifact.sourceURL ?? null),
    text_content: artifact.text_content ? limitText(artifact.text_content) : null,
    raw_json: artifact.raw_json ?? null,
    metadata: artifact.metadata ?? {},
  };

  await insertRows("recipe_ingestion_artifacts", [payload], {
    prefer: "return=minimal",
  });
}

async function storeEvidenceBundle(jobID, bundle) {
  const payload = {
    id: `reb_${nanoid(14)}`,
    job_id: jobID,
    source_type: normalizeText(bundle?.source_type ?? "") || null,
    platform: normalizeText(bundle?.platform ?? "") || null,
    source_url: cleanURL(bundle?.source_url ?? null),
    canonical_url: cleanURL(bundle?.canonical_url ?? null),
    title: normalizeText(bundle?.title ?? "") || null,
    description: normalizeText(bundle?.description ?? "") || null,
    author_name: normalizeText(bundle?.author_name ?? "") || null,
    author_handle: normalizeText(bundle?.author_handle ?? "") || null,
    transcript_text: normalizeText(bundle?.transcript_text ?? "") || null,
    frame_count: Number.isFinite(bundle?.frame_count) ? Number(bundle.frame_count) : null,
    frame_ocr_json: compactJSON(Array.isArray(bundle?.frame_ocr_texts) ? bundle.frame_ocr_texts : []),
    metadata_json: compactJSON({
      attached_video_url: cleanURL(bundle?.attached_video_url ?? null),
      downloaded_video: Boolean(bundle?.downloaded_video),
      evidence_summary: bundle?.evidence_summary ?? null,
      caption_text: normalizeText(bundle?.caption_text ?? "") || null,
      page_signal_summary: bundle?.page_signal_summary ?? null,
    }),
    evidence_json: compactJSON(bundle ?? {}),
  };

  try {
    const [created] = await insertRows("recipe_ingestion_evidence_bundles", [payload], {
      prefer: "return=minimal",
    });

    return created ?? payload;
  } catch {
    return {
      ...payload,
      id: payload.id,
      local_only: true,
    };
  }
}

async function fetchRecipeRowByID(recipeID, config = tableConfigForRecipeID(recipeID)) {
  const configs = recipeTableConfigsForID(recipeID, config);
  let lastError = null;
  for (const nextConfig of configs) {
    try {
      return await fetchOneRow(
        nextConfig.recipeTable,
        RECIPE_ROW_SELECT,
        [`id=eq.${encodeURIComponent(recipeID)}`]
      );
    } catch (error) {
      lastError = error;
      try {
        return await fetchOneRow(
          nextConfig.recipeTable,
          stripSelectColumns(RECIPE_ROW_SELECT, ["source_provenance_json", "discover_brackets", "discover_brackets_enriched_at"]),
          [`id=eq.${encodeURIComponent(recipeID)}`]
        );
      } catch (fallbackError) {
        lastError = fallbackError;
      }
    }
  }
  throw lastError ?? new Error(`Recipe ${recipeID} could not be found.`);
}

async function fetchRecipeCardProjection(recipeID) {
  const configs = recipeTableConfigsForID(recipeID, tableConfigForRecipeID(recipeID));
  let lastError = null;
  for (const config of configs) {
    try {
      const row = await fetchOneRow(
        config.recipeTable,
        RECIPE_CARD_SELECT,
        [`id=eq.${encodeURIComponent(recipeID)}`]
      );
      if (row) return row;
    } catch (error) {
      lastError = error;
      try {
        const row = await fetchOneRow(
          config.recipeTable,
          stripSelectColumns(RECIPE_CARD_SELECT, ["discover_brackets"]),
          [`id=eq.${encodeURIComponent(recipeID)}`]
        );
        if (row) return row;
      } catch (fallbackError) {
        lastError = fallbackError;
      }
    }
  }
  if (lastError) {
    throw lastError;
  }
  return null;
}

async function fetchRecipeIngredientRowsForConfig(recipeID, config = tableConfigForRecipeID(recipeID)) {
  const configs = recipeTableConfigsForID(recipeID, config);
  let lastError = null;
  for (const nextConfig of configs) {
    try {
      return await fetchRows(
        nextConfig.ingredientTable,
        "id,recipe_id,ingredient_id,display_name,quantity_text,image_url,sort_order",
        {
          filters: [`recipe_id=eq.${encodeURIComponent(recipeID)}`],
          order: ["sort_order.asc"],
        }
      );
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error(`Recipe ${recipeID} ingredients could not be found.`);
}

async function fetchRecipeStepRowsForConfig(recipeID, config = tableConfigForRecipeID(recipeID)) {
  const configs = recipeTableConfigsForID(recipeID, config);
  let lastError = null;
  for (const nextConfig of configs) {
    try {
      return await fetchRows(
        nextConfig.stepTable,
        "id,recipe_id,step_number,instruction_text,tip_text",
        {
          filters: [`recipe_id=eq.${encodeURIComponent(recipeID)}`],
          order: ["step_number.asc"],
        }
      );
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error(`Recipe ${recipeID} steps could not be found.`);
}

async function fetchRecipeStepIngredientRowsForConfig(stepIDs, config = PUBLIC_RECIPE_TABLE_CONFIG) {
  const normalizedIDs = [...new Set((stepIDs ?? []).map((value) => String(value ?? "").trim()).filter(Boolean))];
  if (!normalizedIDs.length) return [];

  return fetchRows(
    config.stepIngredientTable,
    "id,recipe_step_id,ingredient_id,display_name,quantity_text,sort_order",
    {
      filters: [`recipe_step_id=in.${buildInClause(normalizedIDs)}`],
      order: ["recipe_step_id.asc", "sort_order.asc"],
    }
  );
}

async function fetchCanonicalRecipeDetailByID(recipeID, config = tableConfigForRecipeID(recipeID)) {
  const recipe = await fetchRecipeRowByID(recipeID, config);
  if (!recipe) return null;

  const [recipeIngredients, recipeSteps] = await Promise.all([
    fetchRecipeIngredientRowsForConfig(recipeID, config),
    fetchRecipeStepRowsForConfig(recipeID, config),
  ]);

  const stepIngredients = recipeSteps.length
    ? await fetchRecipeStepIngredientRowsForConfig(recipeSteps.map((step) => step.id), config)
    : [];

  return canonicalizeRecipeDetail(recipe, {
    recipeIngredients,
    recipeSteps,
    stepIngredients,
  });
}

function buildSavedProjection(recipeDetail) {
  return {
    recipe_id: recipeDetail.id,
    title: recipeDetail.title,
    description: recipeDetail.description ?? null,
    author_name: recipeDetail.author_name ?? null,
    author_handle: recipeDetail.author_handle ?? null,
    category: recipeDetail.category ?? null,
    recipe_type: recipeDetail.recipe_type ?? null,
    cook_time_text: recipeDetail.cook_time_text ?? null,
    published_date: recipeDetail.published_date ?? null,
    discover_card_image_url: recipeDetail.discover_card_image_url ?? recipeDetail.hero_image_url ?? null,
    hero_image_url: recipeDetail.hero_image_url ?? recipeDetail.discover_card_image_url ?? null,
    recipe_url: recipeDetail.recipe_url ?? null,
    source: recipeDetail.source ?? recipeDetail.source_platform ?? "user import",
  };
}

async function fetchRecipeImageReference(normalizedRecipe) {
  const recipeType = normalizeText(normalizedRecipe?.recipe_type ?? normalizedRecipe?.category ?? "");
  const title = normalizeText(normalizedRecipe?.title ?? "");
  const category = normalizeText(normalizedRecipe?.category ?? "");
  const mainProtein = normalizeText(normalizedRecipe?.main_protein ?? "");
  const cuisineTags = Array.isArray(normalizedRecipe?.cuisine_tags) ? normalizedRecipe.cuisine_tags : [];
  const occasionTags = Array.isArray(normalizedRecipe?.occasion_tags) ? normalizedRecipe.occasion_tags : [];
  const searchSignals = uniqueStrings([
    ...title.split(/\s+/),
    recipeType,
    category,
    mainProtein,
    ...cuisineTags,
    ...occasionTags,
  ])
    .map((value) => normalizeKey(value))
    .filter(Boolean);

  try {
    const [publicRows, importedRows] = await Promise.all([
      fetchRows(
        "recipes",
        "id,title,recipe_type,category,main_protein,cuisine_tags,occasion_tags,hero_image_url,discover_card_image_url",
        {
          order: ["updated_at.desc"],
          limit: 80,
        }
      ),
      fetchRows(
        "user_import_recipes",
        "id,title,recipe_type,category,main_protein,cuisine_tags,occasion_tags,hero_image_url,discover_card_image_url,source",
        {
          order: ["updated_at.desc"],
          limit: 80,
        }
      ),
    ]);

    const rows = [...(publicRows ?? []), ...(importedRows ?? [])];

    const scored = rows
      .map((row) => {
        const rowTitle = normalizeKey(row.title ?? "");
        const rowType = normalizeKey(row.recipe_type ?? row.category ?? "");
        const rowCategory = normalizeKey(row.category ?? "");
        const rowProtein = normalizeKey(row.main_protein ?? "");
        const rowTags = uniqueStrings([...(row.cuisine_tags ?? []), ...(row.occasion_tags ?? [])].map((value) => normalizeKey(value)).filter(Boolean));

        let score = 0;
        if (recipeType && rowType.includes(normalizeKey(recipeType))) score += 4;
        if (category && rowCategory.includes(normalizeKey(category))) score += 3;
        if (mainProtein && rowProtein.includes(normalizeKey(mainProtein))) score += 3;
        for (const signal of searchSignals.slice(0, 8)) {
          if (rowTitle.includes(signal) || rowCategory.includes(signal) || rowType.includes(signal)) score += 1.8;
          if (rowTags.some((tag) => tag.includes(signal))) score += 1.2;
        }
        if (cleanURL(row.hero_image_url ?? row.discover_card_image_url ?? null)) score += 2;
        return { row, score };
      })
      .filter(({ row }) => cleanURL(row.hero_image_url ?? row.discover_card_image_url ?? null))
      .sort((left, right) => right.score - left.score);

    return scored[0]?.row ?? null;
  } catch {
    return null;
  }
}

function isOunjeGeneratedSourceType(sourceType) {
  return ["concept_prompt", "direct_input", "text", "recipe_search"].includes(normalizeText(sourceType).toLowerCase());
}

async function hasSavedRecipeTombstone(userID, recipeID) {
  const normalizedUserID = normalizeText(userID);
  const normalizedRecipeID = normalizeText(recipeID);
  if (!normalizedUserID || !normalizedRecipeID) return false;

  const rows = await fetchRows("saved_recipe_tombstones", "recipe_id", {
    filters: [
      `user_id=eq.${encodeURIComponent(normalizedUserID)}`,
      `recipe_id=eq.${encodeURIComponent(normalizedRecipeID)}`,
    ],
    limit: 1,
  });
  return rows.length > 0;
}

async function upsertSavedRecipeForUser(userID, recipeDetail) {
  if (!userID) return false;
  const savedProjection = buildSavedProjection(recipeDetail);
  if (!savedProjection.recipe_id) return false;
  if (await hasSavedRecipeTombstone(userID, savedProjection.recipe_id)) {
    console.info("[recipe-ingestion] Skipping saved recipe upsert because user tombstoned it", {
      userID,
      recipeID: savedProjection.recipe_id,
    });
    return false;
  }

  await insertRows(
    "saved_recipes",
    [
      {
        user_id: userID,
        ...savedProjection,
      },
    ],
    {
      onConflict: "user_id,recipe_id",
      prefer: "resolution=merge-duplicates,return=minimal",
    }
  );
  return true;
}

function normalizeCuisinePreference(rawValue) {
  const key = normalizeKey(rawValue);
  const mapping = new Map([
    ["italian", "italian"],
    ["mexican", "mexican"],
    ["mediterranean", "mediterranean"],
    ["asian", "asian"],
    ["indian", "indian"],
    ["american", "american"],
    ["middle eastern", "middleEastern"],
    ["levantine", "middleEastern"],
    ["japanese", "japanese"],
    ["thai", "thai"],
    ["korean", "korean"],
    ["chinese", "chinese"],
    ["greek", "greek"],
    ["french", "french"],
    ["spanish", "spanish"],
    ["caribbean", "caribbean"],
    ["west african", "westAfrican"],
    ["nigerian", "westAfrican"],
    ["ethiopian", "ethiopian"],
    ["brazilian", "brazilian"],
    ["vegan", "vegan"],
  ]);
  return mapping.get(key) ?? "american";
}

function parseQuantityAmount(text) {
  const raw = normalizeText(text);
  if (!raw) return null;
  if (/^\d+(\.\d+)?$/.test(raw)) return Number(raw);
  const vulgarFractions = {
    "¼": 0.25,
    "½": 0.5,
    "¾": 0.75,
    "⅐": 1 / 7,
    "⅑": 1 / 9,
    "⅒": 0.1,
    "⅓": 1 / 3,
    "⅔": 2 / 3,
    "⅕": 0.2,
    "⅖": 0.4,
    "⅗": 0.6,
    "⅘": 0.8,
    "⅙": 1 / 6,
    "⅚": 5 / 6,
    "⅛": 0.125,
    "⅜": 0.375,
    "⅝": 0.625,
    "⅞": 0.875,
  };
  if (vulgarFractions[raw] != null) return vulgarFractions[raw];
  const compactVulgar = raw.match(/^(\d+)([¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞])$/u);
  if (compactVulgar) return Number(compactVulgar[1]) + vulgarFractions[compactVulgar[2]];
  if (/^\d+\s+\d\/\d$/.test(raw)) {
    const [whole, fraction] = raw.split(/\s+/, 2);
    const [numerator, denominator] = fraction.split("/").map(Number);
    if (!denominator) return null;
    return Number(whole) + numerator / denominator;
  }
  if (/^\d+\/\d+$/.test(raw)) {
    const [numerator, denominator] = raw.split("/").map(Number);
    if (!denominator) return null;
    return numerator / denominator;
  }
  return null;
}

function parseIngredientMeasurement(quantityText) {
  const raw = normalizeText(quantityText);
  if (!raw) return null;
  const match = raw.match(/^(\d+\s+\d\/\d|\d+\/\d|\d+(?:\.\d+)?[¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞]?|[¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞])\s*([a-zA-Z][a-zA-Z.-]*)?(?:\s+(.*))?$/u);
  if (!match) return null;
  const amount = parseQuantityAmount(match[1]);
  if (amount == null) return null;
  const unitParts = [match[2], match[3]].filter(Boolean).join(" ");
  return {
    amount,
    unit: normalizeText(unitParts) || "ct",
  };
}

async function upsertPrepOverrideForUser(userID, recipeDetail) {
  if (!userID) return;

  const ingredients = (recipeDetail.ingredients ?? []).map((ingredient) => {
    const parsed = parseIngredientMeasurement(ingredient.quantity_text);
    return {
      name: ingredient.display_name,
      amount: parsed?.amount ?? 1,
      unit: parsed?.unit ?? "ct",
      estimatedUnitPrice: 0,
    };
  });

  const recipePayload = {
    id: recipeDetail.id,
    title: recipeDetail.title,
    cuisine: normalizeCuisinePreference(recipeDetail.cuisine_tags?.[0] ?? recipeDetail.category ?? recipeDetail.recipe_type),
    prepMinutes: recipeDetail.prep_time_minutes ?? recipeDetail.cook_time_minutes ?? parseFirstInteger(recipeDetail.cook_time_text) ?? 0,
    servings: Math.max(1, recipeDetail.servings_count ?? parseFirstInteger(recipeDetail.servings_text) ?? 4),
    storageFootprint: { pantry: 2, fridge: 2, freezer: 1 },
    tags: uniqueStrings([
      ...(recipeDetail.dietary_tags ?? []),
      ...(recipeDetail.flavor_tags ?? []),
      ...(recipeDetail.occasion_tags ?? []),
      recipeDetail.recipe_type,
      recipeDetail.category,
    ]),
    ingredients,
    cardImageURLString: recipeDetail.discover_card_image_url ?? recipeDetail.hero_image_url ?? null,
    heroImageURLString: recipeDetail.hero_image_url ?? recipeDetail.discover_card_image_url ?? null,
    source: recipeDetail.source ?? recipeDetail.source_platform ?? null,
  };

  await insertRows(
    "prep_recipe_overrides",
    [
      {
        user_id: userID,
        recipe_id: recipeDetail.id,
        recipe: recipePayload,
        servings: recipePayload.servings,
        is_included_in_prep: true,
      },
    ],
    {
      onConflict: "user_id,recipe_id",
      prefer: "resolution=merge-duplicates,return=minimal",
    }
  );
}

function coerceIngredientItem(item) {
  if (typeof item === "string") {
    const parsed = parseIngredientObjects(item)[0];
    if (!parsed?.name) return null;
    return {
      display_name: parsed.name,
      quantity_text: normalizeText([parsed.quantity != null ? String(parsed.quantity) : null, parsed.unit].filter(Boolean).join(" ")) || null,
      image_url: null,
    };
  }
  if (!item || typeof item !== "object") return null;
  const displayName = normalizeText(item.display_name ?? item.displayName ?? item.name ?? item.ingredient ?? "");
  if (!displayName) return null;
  return {
    display_name: displayName,
    quantity_text: normalizeText(item.quantity_text ?? item.quantityText ?? item.amount_text ?? item.amountText ?? item.quantity ?? item.measure ?? "") || null,
    image_url: cleanURL(item.image_url ?? item.imageUrl ?? null),
  };
}

function coerceStepIngredientItem(item) {
  if (typeof item === "string") {
    return {
      display_name: normalizeText(item),
      quantity_text: null,
    };
  }
  if (!item || typeof item !== "object") return null;
  const displayName = normalizeText(item.display_name ?? item.displayName ?? item.name ?? item.ingredient ?? "");
  if (!displayName) return null;
  return {
    display_name: displayName,
    quantity_text: normalizeText(item.quantity_text ?? item.quantityText ?? item.amount_text ?? item.amountText ?? item.quantity ?? "") || null,
  };
}

function coerceStepItem(item, index) {
  if (typeof item === "string") {
    const text = normalizeText(item);
    if (!text) return null;
    return {
      number: index + 1,
      text,
      tip_text: null,
      ingredients: [],
    };
  }
  if (!item || typeof item !== "object") return null;
  const text = normalizeText(item.text ?? item.instruction_text ?? item.instructionText ?? item.body ?? "");
  if (!text) return null;
  const ingredientRefs = [
    ...(Array.isArray(item.ingredients) ? item.ingredients : []),
    ...(Array.isArray(item.ingredient_refs) ? item.ingredient_refs : []),
    ...(Array.isArray(item.ingredientRefs) ? item.ingredientRefs : []),
  ]
    .map(coerceStepIngredientItem)
    .filter(Boolean);

  return {
    number: Number.isFinite(item.number) ? Number(item.number) : index + 1,
    text,
    tip_text: normalizeText(item.tip_text ?? item.tipText ?? item.tip ?? "") || null,
    ingredients: uniqueBy(ingredientRefs, (ingredient) => normalizeKey(ingredient.display_name)),
  };
}

function buildFallbackIngredientLines(source) {
  return uniqueStrings([
    ...(Array.isArray(source.ingredient_candidates) ? source.ingredient_candidates : []),
    ...(Array.isArray(source.structured_recipe?.recipeIngredient) ? source.structured_recipe.recipeIngredient : []),
  ]);
}

function buildFallbackInstructionLines(source) {
  const schemaInstructions = Array.isArray(source.structured_recipe?.recipeInstructions)
    ? source.structured_recipe.recipeInstructions
    : [];
  return uniqueStrings([
    ...(Array.isArray(source.instruction_candidates) ? source.instruction_candidates : []),
    ...schemaInstructions
      .map((entry) => {
        if (typeof entry === "string") return entry;
        if (!entry || typeof entry !== "object") return "";
        return entry.text ?? entry.name ?? "";
      }),
  ]);
}

function parseDurationMinutes(value) {
  const raw = normalizeText(value);
  if (!raw) return null;
  if (/^\d+$/.test(raw)) return Number(raw);
  const match = raw.match(/^P(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)$/i);
  if (!match) return null;
  const hours = Number(match[1] ?? 0);
  const minutes = Number(match[2] ?? 0);
  const seconds = Number(match[3] ?? 0);
  return hours * 60 + minutes + Math.round(seconds / 60);
}

function durationText(minutes) {
  if (!Number.isFinite(minutes) || minutes <= 0) return null;
  if (minutes >= 60) {
    const hours = Math.floor(minutes / 60);
    const remaining = minutes % 60;
    return remaining > 0 ? `${hours} hr ${remaining} min` : `${hours} hr`;
  }
  return `${minutes} mins`;
}

function coerceStructuredRecipeCandidate(candidate, source) {
  const sourceIngredients = Array.isArray(candidate.ingredients) ? candidate.ingredients : [];
  const ingredients = uniqueBy(
    [
      ...sourceIngredients.map(coerceIngredientItem).filter(Boolean),
      ...buildFallbackIngredientLines(source).map(coerceIngredientItem).filter(Boolean),
    ],
    (ingredient) => normalizeKey(ingredient.display_name)
  ).map((ingredient, index) => ({
    ...ingredient,
    sort_order: index + 1,
  }));

  const sourceSteps = Array.isArray(candidate.steps) ? candidate.steps : [];
  let steps = sourceSteps.map(coerceStepItem).filter(Boolean);
  if (!steps.length) {
    steps = parseInstructionSteps(buildFallbackInstructionLines(source).join("\n"), ingredients).map((step, index) => ({
      number: step.number ?? index + 1,
      text: step.text,
      tip_text: step.tip_text ?? null,
      ingredients: (step.ingredients ?? []).map((ingredient) => ({
        display_name: ingredient.display_name ?? ingredient.name ?? ingredient.displayName,
        quantity_text: ingredient.quantity_text ?? null,
      })).filter((ingredient) => normalizeText(ingredient.display_name)),
    }));
  }
  steps = steps
    .map((step, index) => ({
      ...step,
      number: step.number ?? index + 1,
      ingredients: uniqueBy(step.ingredients ?? [], (ingredient) => normalizeKey(ingredient.display_name)),
    }))
    .filter((step) => normalizeText(step.text));

  const prepMinutes = Number.isFinite(candidate.prep_time_minutes)
    ? Number(candidate.prep_time_minutes)
    : parseDurationMinutes(candidate.prep_time_iso ?? candidate.prepTime);
  const cookMinutes = Number.isFinite(candidate.cook_time_minutes)
    ? Number(candidate.cook_time_minutes)
    : parseDurationMinutes(candidate.cook_time_iso ?? candidate.cookTime);
  const totalMinutes = Number.isFinite(candidate.total_time_minutes)
    ? Number(candidate.total_time_minutes)
    : parseDurationMinutes(candidate.total_time_iso ?? candidate.totalTime);
  const servingsCount = Number.isFinite(candidate.servings_count)
    ? Number(candidate.servings_count)
    : parseFirstInteger(candidate.servings_text ?? candidate.recipeYield ?? candidate.servings);

  const description = normalizeText(candidate.description ?? source.meta_description ?? source.description ?? "") || null;
  const heroImageURL = cleanURL(
    candidate.hero_image_url
      ?? candidate.heroImageUrl
      ?? candidate.discover_card_image_url
      ?? source.hero_image_url
      ?? source.meta_image_url
      ?? source.thumbnail_url
      ?? null
  );

  const authorName = firstNormalizedText(candidate.author_name, candidate.authorName, source.author_name, source.author, source.uploader);
  const authorHandle = normalizeCreatorHandle(
    firstNormalizedText(
      candidate.author_handle,
      candidate.authorHandle,
      source.author_handle,
      source.uploader_id,
      source.username,
      source.channel_id
    )
  );

  return {
    title: normalizeText(candidate.title ?? source.title ?? source.meta_title ?? "") || null,
    description,
    author_name: authorName,
    author_handle: authorHandle,
    author_url: cleanURL(candidate.author_url ?? candidate.authorURL ?? source.author_url ?? null),
    source: normalizeText(candidate.source ?? source.site_name ?? source.source ?? "") || null,
    source_platform: normalizeText(candidate.source_platform ?? source.source_platform ?? source.platform ?? "") || null,
    category: normalizeText(candidate.category ?? candidate.recipe_category ?? source.category ?? "") || null,
    subcategory: normalizeText(candidate.subcategory ?? source.subcategory ?? "") || null,
    recipe_type: normalizeText(candidate.recipe_type ?? candidate.recipeType ?? source.recipe_type ?? "") || null,
    skill_level: normalizeText(candidate.skill_level ?? candidate.skillLevel ?? "") || null,
    cook_time_text: normalizeText(candidate.cook_time_text ?? candidate.cookTimeText ?? durationText(cookMinutes ?? totalMinutes) ?? "") || null,
    servings_text: normalizeText(candidate.servings_text ?? candidate.recipeYield ?? candidate.servings ?? "") || (servingsCount ? `${servingsCount}` : null),
    serving_size_text: normalizeText(candidate.serving_size_text ?? candidate.servingSizeText ?? "") || null,
    est_calories_text: normalizeText(candidate.est_calories_text ?? candidate.calories_text ?? "") || null,
    calories_kcal: finiteNumberOrNull(candidate.calories_kcal),
    protein_g: finiteNumberOrNull(candidate.protein_g),
    carbs_g: finiteNumberOrNull(candidate.carbs_g),
    fat_g: finiteNumberOrNull(candidate.fat_g),
    prep_time_minutes: prepMinutes ?? null,
    cook_time_minutes: cookMinutes ?? totalMinutes ?? null,
    hero_image_url: heroImageURL,
    discover_card_image_url: cleanURL(candidate.discover_card_image_url ?? candidate.discoverCardImageUrl ?? heroImageURL),
    recipe_url: cleanURL(candidate.recipe_url ?? candidate.recipeURL ?? source.source_url ?? source.canonical_url ?? null),
    original_recipe_url: cleanURL(candidate.original_recipe_url ?? candidate.originalRecipeUrl ?? source.canonical_url ?? source.source_url ?? null),
    attached_video_url: cleanURL(candidate.attached_video_url ?? candidate.attachedVideoUrl ?? source.attached_video_url ?? null),
    detail_footnote: normalizeText(candidate.detail_footnote ?? "") || null,
    image_caption: normalizeText(candidate.image_caption ?? "") || null,
    dietary_tags: uniqueStrings(candidate.dietary_tags ?? candidate.dietaryTags ?? []),
    flavor_tags: uniqueStrings(candidate.flavor_tags ?? candidate.flavorTags ?? []),
    cuisine_tags: uniqueStrings(candidate.cuisine_tags ?? candidate.cuisineTags ?? []),
    occasion_tags: uniqueStrings(candidate.occasion_tags ?? candidate.occasionTags ?? []),
    main_protein: normalizeText(candidate.main_protein ?? candidate.mainProtein ?? "") || null,
    cook_method: normalizeText(candidate.cook_method ?? candidate.cookMethod ?? "") || null,
    ingredients,
    steps,
    servings_count: servingsCount ?? null,
  };
}

function buildRecipeArtifacts(normalized, config, recipeRowExtras = {}) {
  const discoverBrackets = sanitizeDiscoverBrackets(normalized, normalized.discover_brackets ?? []);
  const recipeID = config.recipeTable === PUBLIC_RECIPE_TABLE_CONFIG.recipeTable
    ? crypto.randomUUID()
    : (
        String(normalized?.id ?? "").trim().startsWith(config.recipePrefix)
          ? String(normalized.id).trim()
          : `${config.recipePrefix}${nanoid(14)}`
      );
  const recipeIngredients = (normalized.ingredients ?? []).map((ingredient, index) => ({
    id: `${config.ingredientPrefix}${nanoid(12)}`,
    recipe_id: recipeID,
    ingredient_id: ingredient.ingredient_id ?? null,
    display_name: ingredient.display_name,
    quantity_text: ingredient.quantity_text ?? null,
    image_url: ingredient.image_url ?? null,
    sort_order: ingredient.sort_order ?? index + 1,
  }));

  const recipeSteps = [];
  const stepIngredients = [];

  for (const step of normalized.steps ?? []) {
    const stepID = `${config.stepPrefix}${nanoid(12)}`;
    recipeSteps.push({
      id: stepID,
      recipe_id: recipeID,
      step_number: step.number,
      instruction_text: step.text,
      tip_text: step.tip_text ?? null,
    });

    for (const [index, ingredient] of (step.ingredients ?? []).entries()) {
      stepIngredients.push({
        id: `${config.stepIngredientPrefix}${nanoid(12)}`,
        recipe_step_id: stepID,
        ingredient_id: ingredient.ingredient_id ?? recipeIngredients.find((row) => normalizeKey(row.display_name) === normalizeKey(ingredient.display_name))?.ingredient_id ?? null,
        display_name: ingredient.display_name,
        quantity_text: ingredient.quantity_text ?? null,
        sort_order: index + 1,
      });
    }
  }

  const recipeRow = {
    id: recipeID,
    title: normalized.title,
    description: normalized.description,
    author_name: normalized.author_name,
    author_handle: normalized.author_handle,
    author_url: normalized.author_url,
    source: normalized.source ?? normalized.source_platform ?? (config.recipeTable === PUBLIC_RECIPE_TABLE_CONFIG.recipeTable ? "Ounje" : "user import"),
    source_platform: normalized.source_platform,
    category: normalized.category,
    subcategory: normalized.subcategory,
    recipe_type: normalized.recipe_type,
    skill_level: normalized.skill_level,
    cook_time_text: normalized.cook_time_text,
    servings_text: normalized.servings_text,
    serving_size_text: normalized.serving_size_text,
    est_calories_text: normalized.est_calories_text,
    calories_kcal: normalized.calories_kcal,
    protein_g: normalized.protein_g,
    carbs_g: normalized.carbs_g,
    fat_g: normalized.fat_g,
    prep_time_minutes: normalized.prep_time_minutes,
    cook_time_minutes: normalized.cook_time_minutes,
    hero_image_url: normalized.hero_image_url,
    discover_card_image_url: normalized.discover_card_image_url,
    external_id: normalizeText(normalized.external_id ?? "") || cleanURL(normalized.recipe_url ?? normalized.original_recipe_url ?? normalized.attached_video_url ?? null) || recipeID,
    recipe_path: normalizeText(normalized.recipe_path ?? "") || `/recipes/${recipeID}`,
    recipe_url: cleanURL(normalized.recipe_url ?? normalized.original_recipe_url ?? normalized.attached_video_url ?? null)
      || (config.recipeTable === PUBLIC_RECIPE_TABLE_CONFIG.recipeTable ? `https://ounje.local/recipes/${recipeID}` : null),
    original_recipe_url: cleanURL(normalized.original_recipe_url ?? normalized.recipe_url ?? normalized.attached_video_url ?? null)
      || (config.recipeTable === PUBLIC_RECIPE_TABLE_CONFIG.recipeTable ? `https://ounje.local/recipes/${recipeID}` : null),
    attached_video_url: normalized.attached_video_url,
    detail_footnote: normalized.detail_footnote,
    image_caption: normalized.image_caption,
    source_provenance_json: normalized.source_provenance_json ?? null,
    dietary_tags: normalized.dietary_tags,
    flavor_tags: normalized.flavor_tags,
    cuisine_tags: normalized.cuisine_tags,
    occasion_tags: normalized.occasion_tags,
    main_protein: normalized.main_protein,
    cook_method: config.recipeTable === PUBLIC_RECIPE_TABLE_CONFIG.recipeTable
      ? normalizeStringArray(normalized.cook_method, 6)
      : normalizeText(Array.isArray(normalized.cook_method) ? normalized.cook_method[0] : normalized.cook_method) || null,
    discover_brackets: discoverBrackets,
    discover_brackets_enriched_at: discoverBrackets.length ? nowIso() : null,
    ...recipeRowExtras,
  };

  const canonical = canonicalizeRecipeDetail(recipeRow, {
    recipeIngredients,
    recipeSteps,
    stepIngredients,
  });

  return {
    recipe_id: recipeID,
    recipe_row: {
      ...recipeRow,
      ingredients_text: canonical.ingredients.map((ingredient) =>
        [ingredient.quantity_text, ingredient.display_name].filter(Boolean).join(" ").trim()
      ).join("\n"),
      instructions_text: canonical.steps.map((step) => step.text).join("\n"),
      ingredients_json: canonical.ingredients,
      steps_json: canonical.steps,
      servings_count: canonical.servings_count,
    },
    recipe_ingredients: recipeIngredients.map((ingredient, index) => ({
      ...ingredient,
      ingredient_id: ingredient.ingredient_id ?? canonical.ingredients[index]?.ingredient_id ?? null,
      image_url: ingredient.image_url ?? canonical.ingredients[index]?.image_url ?? null,
    })),
    recipe_steps: recipeSteps,
    recipe_step_ingredients: stepIngredients,
    canonical_detail: canonical,
  };
}

function buildCanonicalRecipeArtifacts(normalized) {
  return buildRecipeArtifacts(normalized, PUBLIC_RECIPE_TABLE_CONFIG);
}

function buildUserImportedRecipeArtifacts(normalized, { userID, sourceJobID = null, dedupeKey = null, reviewState = "pending", confidenceScore = null, qualityFlags = [] } = {}) {
  const recipeID = String(normalized?.id ?? "").trim().startsWith(USER_IMPORTED_RECIPE_TABLE_CONFIG.recipePrefix)
    ? String(normalized.id).trim()
    : `${USER_IMPORTED_RECIPE_TABLE_CONFIG.recipePrefix}${nanoid(14)}`;
  return buildRecipeArtifacts({
    ...normalized,
    id: recipeID,
  }, USER_IMPORTED_RECIPE_TABLE_CONFIG, {
    user_id: userID,
    source_job_id: sourceJobID,
    dedupe_key: dedupeKey,
    review_state: reviewState,
    confidence_score: confidenceScore,
    quality_flags: qualityFlags,
  });
}

function recipeTableConfigsForID(recipeID, preferredConfig = null) {
  const id = String(recipeID ?? "").trim();
  const configs = [];
  if (preferredConfig) {
    configs.push(preferredConfig);
  }
  if (id.startsWith(USER_IMPORTED_RECIPE_TABLE_CONFIG.recipePrefix)) {
    configs.push(USER_IMPORTED_RECIPE_TABLE_CONFIG);
  } else if (id.startsWith(PUBLIC_RECIPE_TABLE_CONFIG.recipePrefix)) {
    configs.push(USER_IMPORTED_RECIPE_TABLE_CONFIG);
    configs.push(PUBLIC_RECIPE_TABLE_CONFIG);
  } else {
    configs.push(PUBLIC_RECIPE_TABLE_CONFIG);
    configs.push(USER_IMPORTED_RECIPE_TABLE_CONFIG);
  }
  return uniqueBy(configs, (config) => config.recipeTable);
}

async function resolveIngredientCatalog(ingredients) {
  const names = uniqueStrings((ingredients ?? []).map((ingredient) => normalizeKey(ingredient.display_name))).filter(Boolean);
  if (!names.length) return new Map();

  let rows = await fetchRows(
    "ingredients",
    "id,display_name,normalized_name,default_image_url",
    {
      filters: [`normalized_name=in.${buildInClause(names)}`],
      limit: 200,
    }
  );

  const existingKeys = new Set(rows.map((row) => normalizeKey(row.normalized_name ?? row.display_name)));
  const missingNames = names.filter((name) => !existingKeys.has(normalizeKey(name)));
  if (missingNames.length) {
    const displayNameByKey = new Map(
      (ingredients ?? [])
        .map((ingredient) => [normalizeKey(ingredient.display_name), normalizeText(ingredient.display_name)])
        .filter(([key, value]) => key && value)
    );
    const inserted = await insertRows(
      "ingredients",
      missingNames.map((name) => ({
        id: crypto.randomUUID(),
        normalized_name: normalizeKey(name),
        display_name: displayNameByKey.get(normalizeKey(name)) ?? ingredientDisplayNameFromKey(name) ?? name,
      })),
      {
        onConflict: "normalized_name",
        prefer: "resolution=merge-duplicates,return=representation",
      }
    ).catch((error) => {
      console.warn("[recipe-ingestion] canonical ingredient insert failed:", error.message);
      return [];
    });
    rows = [...rows, ...inserted];
  }

  return new Map(
    rows.map((row) => [normalizeKey(row.normalized_name ?? row.display_name), row])
  );
}

async function resolveTrustedIngredientImageLookup(catalog, ingredients) {
  const lookup = new Map();
  const candidates = [];
  const seenIngredientIDs = new Set();

  for (const ingredient of ingredients ?? []) {
    const key = normalizeKey(ingredient.display_name);
    if (!key || isUtilityIngredient(key)) continue;
    const row = catalog.get(key);
    const defaultImageURL = cleanURL(row?.default_image_url ?? null);
    if (defaultImageURL) {
      lookup.set(key, defaultImageURL);
      continue;
    }
    const ingredientID = normalizeText(row?.id ?? ingredient.ingredient_id ?? "");
    if (!ingredientID || seenIngredientIDs.has(ingredientID)) continue;
    seenIngredientIDs.add(ingredientID);
    candidates.push({ key, ingredientID });
  }

  if (!candidates.length) return lookup;

  const rows = await fetchRows(
    "recipe_ingredients",
    "ingredient_id,display_name,image_url",
    {
      filters: [
        `ingredient_id=in.${buildInClause(candidates.map((candidate) => candidate.ingredientID))}`,
        "image_url=not.is.null",
      ],
      order: ["ingredient_id.asc"],
      limit: 1000,
    }
  ).catch((error) => {
    console.warn("[recipe-ingestion] trusted ingredient image lookup failed:", error.message);
    return [];
  });

  const imageByIngredientID = new Map();
  for (const row of rows) {
    const ingredientID = normalizeText(row?.ingredient_id ?? "");
    const imageURL = cleanURL(row?.image_url ?? null);
    if (!ingredientID || !imageURL || imageByIngredientID.has(ingredientID)) continue;
    imageByIngredientID.set(ingredientID, imageURL);
  }

  for (const candidate of candidates) {
    const imageURL = imageByIngredientID.get(candidate.ingredientID);
    if (imageURL && !lookup.has(candidate.key)) {
      lookup.set(candidate.key, imageURL);
    }
  }

  return lookup;
}

async function hydrateIngredientIdentity(normalized) {
  const catalog = await resolveIngredientCatalog(normalized.ingredients);
  const trustedImageByIngredientKey = await resolveTrustedIngredientImageLookup(catalog, normalized.ingredients);
  const nextIngredients = normalized.ingredients.map((ingredient) => {
    const key = normalizeKey(ingredient.display_name);
    const match = catalog.get(key);
    return {
      ...ingredient,
      ingredient_id: ingredient.ingredient_id ?? match?.id ?? null,
      image_url: ingredient.image_url ?? trustedImageByIngredientKey.get(key) ?? null,
    };
  });

  const matchByName = new Map(nextIngredients.map((ingredient) => [normalizeKey(ingredient.display_name), ingredient]));
  const nextSteps = normalized.steps.map((step) => ({
    ...step,
    ingredients: (step.ingredients ?? []).map((ingredient) => {
      const linked = matchByName.get(normalizeKey(ingredient.display_name));
      return {
        ...ingredient,
        ingredient_id: ingredient.ingredient_id ?? linked?.ingredient_id ?? null,
      };
    }),
  }));

  return {
    ...normalized,
    ingredients: nextIngredients,
    steps: nextSteps,
  };
}

async function findExistingCatalogRecipe(normalized) {
  const candidateURLs = uniqueStrings([
    cleanURL(normalized.recipe_url),
    cleanURL(normalized.original_recipe_url),
    cleanURL(normalized.attached_video_url),
  ]).filter(Boolean);

  for (const column of ["recipe_url", "original_recipe_url", "attached_video_url"]) {
    if (!candidateURLs.length) break;
    const rows = await fetchRows(
      "recipes",
      "id,title,source,recipe_url,original_recipe_url,attached_video_url",
      {
        filters: [`${column}=in.${buildInClause(candidateURLs)}`],
        limit: 12,
      }
    );
    if (rows.length) {
      return rows[0];
    }
  }

  const title = normalizeText(normalized.title);
  if (!title) return null;

  const rows = await fetchRows(
    "recipes",
    "id,title,source,recipe_url,original_recipe_url,attached_video_url",
    {
      filters: [`title=ilike.${encodeURIComponent(title)}`],
      limit: 12,
    }
  );

  const titleKey = normalizeKey(title);
  const sourceKey = normalizeKey(normalized.source ?? normalized.source_platform ?? "");
  return rows.find((row) => {
    const rowTitleKey = normalizeKey(row.title);
    const rowSourceKey = normalizeKey(row.source ?? "");
    return rowTitleKey === titleKey && (!sourceKey || !rowSourceKey || rowSourceKey === sourceKey);
  }) ?? null;
}

async function findExistingUserImportedRecipe(userID, normalized, dedupeKey = null) {
  if (!userID) return null;

  if (dedupeKey) {
    const direct = await fetchRows(
      USER_IMPORTED_RECIPE_TABLE_CONFIG.recipeTable,
      "id,title,source,recipe_url,original_recipe_url,attached_video_url,dedupe_key",
      {
        filters: [
          `user_id=eq.${encodeURIComponent(userID)}`,
          `dedupe_key=eq.${encodeURIComponent(dedupeKey)}`,
        ],
        order: ["created_at.desc"],
        limit: 1,
      }
    );
    if (direct[0]) return direct[0];
  }

  const candidateURLs = uniqueStrings([
    cleanURL(normalized.recipe_url),
    cleanURL(normalized.original_recipe_url),
    cleanURL(normalized.attached_video_url),
  ]).filter(Boolean);

  for (const column of ["recipe_url", "original_recipe_url", "attached_video_url"]) {
    if (!candidateURLs.length) break;
    const rows = await fetchRows(
      USER_IMPORTED_RECIPE_TABLE_CONFIG.recipeTable,
      "id,title,source,recipe_url,original_recipe_url,attached_video_url,dedupe_key",
      {
        filters: [
          `user_id=eq.${encodeURIComponent(userID)}`,
          `${column}=in.${buildInClause(candidateURLs)}`,
        ],
        limit: 12,
      }
    );
    if (rows.length) return rows[0];
  }

  const title = normalizeText(normalized.title);
  if (!title) return null;

  const rows = await fetchRows(
    USER_IMPORTED_RECIPE_TABLE_CONFIG.recipeTable,
    "id,title,source,recipe_url,original_recipe_url,attached_video_url,dedupe_key",
    {
      filters: [
        `user_id=eq.${encodeURIComponent(userID)}`,
        `title=ilike.${encodeURIComponent(title)}`,
      ],
      limit: 12,
    }
  );

  const titleKey = normalizeKey(title);
  const sourceKey = normalizeKey(normalized.source ?? normalized.source_platform ?? "");
  return rows.find((row) => {
    const rowTitleKey = normalizeKey(row.title);
    const rowSourceKey = normalizeKey(row.source ?? "");
    return rowTitleKey === titleKey && (!sourceKey || !rowSourceKey || rowSourceKey === sourceKey);
  }) ?? null;
}

async function persistNormalizedRecipe(
  normalized,
  {
    userID = null,
    targetState = "saved",
    sourceJobID = null,
    dedupeKey = null,
    dedupeExisting = true,
    reviewState = "pending",
    confidenceScore = null,
    qualityFlags = [],
  } = {}
) {
  normalized = await guaranteeRecipeDisplayMacros(normalized);
  const existing = dedupeExisting && userID
    ? await findExistingUserImportedRecipe(userID, normalized, dedupeKey)
    : dedupeExisting
      ? await findExistingCatalogRecipe(normalized)
      : null;
  let recipeID = existing?.id ?? null;
  let savedState = existing ? "deduped" : "inserted";

  if (!recipeID) {
    const hydrated = await hydrateIngredientIdentity(normalized);
    const recipeArtifacts = userID
      ? buildUserImportedRecipeArtifacts(hydrated, {
          userID,
          sourceJobID,
          dedupeKey,
          reviewState,
          confidenceScore,
          qualityFlags,
        })
      : buildCanonicalRecipeArtifacts(hydrated);
    const tableConfig = userID ? USER_IMPORTED_RECIPE_TABLE_CONFIG : PUBLIC_RECIPE_TABLE_CONFIG;

    await insertRecipeTableRow(tableConfig.recipeTable, recipeArtifacts.recipe_row);

    if (recipeArtifacts.recipe_ingredients.length) {
      await insertRows(tableConfig.ingredientTable, recipeArtifacts.recipe_ingredients, {
        prefer: "return=minimal",
      });
    }

    if (recipeArtifacts.recipe_steps.length) {
      await insertRows(tableConfig.stepTable, recipeArtifacts.recipe_steps, {
        prefer: "return=minimal",
      });
    }

    if (recipeArtifacts.recipe_step_ingredients.length) {
      await insertRows(tableConfig.stepIngredientTable, recipeArtifacts.recipe_step_ingredients, {
        prefer: "return=minimal",
      });
    }

    recipeID = recipeArtifacts.recipe_id;
    normalized = recipeArtifacts.canonical_detail;
  } else {
    const existingDetail = await fetchCanonicalRecipeDetailByID(recipeID);
    if (existingDetail) {
      const tableConfig = userID ? USER_IMPORTED_RECIPE_TABLE_CONFIG : tableConfigForRecipeID(recipeID);
      const patch = missingDisplayMacroPatch(existingDetail, normalized);
      if (userID && dedupeKey && !normalizeText(existing?.dedupe_key)) {
        patch.dedupe_key = dedupeKey;
      }
      if (Object.keys(patch).length > 0) {
        await patchRows(
          tableConfig.recipeTable,
          [`id=eq.${encodeURIComponent(recipeID)}`],
          patch,
          { prefer: "return=minimal" }
        ).catch((error) => {
          console.warn("[recipe-ingestion] failed to patch deduped recipe display macros:", error.message);
        });
      }
      normalized = {
        ...existingDetail,
        ...patch,
      };
    }
  }

  const recipeCard = await fetchRecipeCardProjection(recipeID);
  const recipeDetail = recipeCard
    ? {
        ...normalized,
        ...recipeCard,
        id: recipeID,
      }
    : {
        ...normalized,
        id: recipeID,
      };

  if (userID && String(targetState ?? "").trim() === "saved") {
    await upsertSavedRecipeForUser(userID, recipeDetail);
  }

  if (userID && String(targetState ?? "").trim() === "prepped") {
    await upsertPrepOverrideForUser(userID, recipeDetail);
  }

  return {
    recipe_id: recipeID,
    saved_state: savedState,
    recipe_card: recipeCard ?? buildSavedProjection(recipeDetail),
    recipe_detail: recipeDetail,
  };
}

function scheduleUserImportEmbedding(recipeID, recipeDetail, { jobID = null } = {}) {
  if (!openai || !recipeID || !recipeDetail) return;

  setTimeout(() => {
    void (async () => {
      const embeddingInput = [
        `title: ${normalizeText(recipeDetail.title ?? "", 240)}`,
        `description: ${normalizeText(recipeDetail.description ?? "", 600)}`,
        `recipe_type: ${normalizeText(recipeDetail.recipe_type ?? recipeDetail.category ?? "", 80)}`,
        `main_protein: ${normalizeText(recipeDetail.main_protein ?? "", 80)}`,
        `cuisine_tags: ${(recipeDetail.cuisine_tags ?? []).join(", ")}`,
        `dietary_tags: ${(recipeDetail.dietary_tags ?? []).join(", ")}`,
        `flavor_tags: ${(recipeDetail.flavor_tags ?? []).join(", ")}`,
        `ingredients: ${normalizeText(recipeDetail.ingredients_text ?? (recipeDetail.ingredients ?? []).map((entry) => [entry.quantity_text, entry.display_name].filter(Boolean).join(" ")).join(", "), 1600)}`,
      ].join("\n");

      const resp = await timeRecipeImportStage(
        "post_completion_embedding",
        { jobID, metadata: { recipe_id: recipeID } },
        () => openai.embeddings.create({ model: "text-embedding-3-small", input: embeddingInput })
      );
      const vector = resp.data?.[0]?.embedding;
      if (!Array.isArray(vector) || vector.length === 0) return;
      await patchRows(
        USER_IMPORTED_RECIPE_TABLE_CONFIG.recipeTable,
        [`id=eq.${encodeURIComponent(recipeID)}`],
        { embedding_basic: `[${vector.join(",")}]` },
        { prefer: "return=minimal" }
      );
    })().catch((embeddingError) => {
      console.warn("[recipe-ingestion] user-import embedding failed:", embeddingError.message);
    });
  }, 0);
}

function assessRecipeQuality(normalized, source) {
  const flags = new Set();
  let confidence = 0.2;
  const isShortFormVideo = ["youtube", "tiktok", "instagram", "media_video"].includes(source.source_type);

  if (normalized.title) confidence += 0.16;
  else flags.add("missing_title");

  if ((normalized.ingredients ?? []).length >= 3) confidence += 0.22;
  else flags.add("low_ingredient_count");

  const ingredientsWithoutQuantities = (normalized.ingredients ?? []).filter((ingredient) => !normalizeText(ingredient.quantity_text)).length;
  if ((normalized.ingredients ?? []).length > 0 && ingredientsWithoutQuantities > Math.ceil(normalized.ingredients.length * 0.6)) {
    flags.add("many_missing_quantities");
  }

  if ((normalized.steps ?? []).length >= 2) confidence += 0.22;
  else flags.add("low_step_count");

  if (normalized.servings_count || normalized.servings_text) confidence += 0.08;
  else flags.add("missing_servings");

  if (source.source_type === "web" && source.structured_recipe?.recipeIngredient?.length) confidence += 0.12;
  if (source.source_type === "youtube" && source.transcript_text) confidence += 0.1;
  if (["tiktok", "instagram"].includes(source.source_type) && !source.transcript_text) flags.add("social_source_without_transcript");
  if (source.blocked) flags.add("source_blocked");
  if (source.used_llm) confidence += 0.05;

  confidence = Math.min(0.99, Math.max(0.05, confidence));
  let reviewState = confidence >= 0.72 && !flags.has("source_blocked") ? "approved" : "needs_review";
  if (
    reviewState !== "approved"
    && ["text", "concept_prompt", "recipe_search"].includes(normalizeText(source.source_type).toLowerCase())
    && confidence >= 0.38
    && confidence < 0.72
    && !flags.has("source_blocked")
  ) {
    reviewState = "draft";
    flags.add("draft_text_import");
  }
  if (
    reviewState !== "approved"
    && isShortFormVideo
    && confidence >= 0.38
    && confidence < 0.72
    && ((normalizeText(source.transcript_text).length > 0) || (Array.isArray(source.frame_ocr_texts) && source.frame_ocr_texts.some((frame) => normalizeText(frame?.text))))
  ) {
    reviewState = "draft";
    flags.add("draft_short_form_video");
  }

  return {
    confidence_score: Number(confidence.toFixed(4)),
    quality_flags: [...flags],
    review_state: reviewState,
    review_reason: reviewState === "needs_review"
      ? uniqueStrings([
          flags.has("source_blocked") ? "Source could not be scraped reliably." : null,
          flags.has("social_source_without_transcript") ? "Social source lacked strong transcript/caption support." : null,
          flags.has("many_missing_quantities") ? "Most ingredients did not include explicit quantities." : null,
          flags.has("low_step_count") ? "Instruction coverage is thin and should be reviewed." : null,
        ])[0] ?? "Recipe import needs a quick review before trusting it fully."
      : reviewState === "draft"
        ? "Imported from short-form video with enough evidence for a usable draft, but it still deserves a quick human check."
      : null,
  };
}

function parseSchemaRecipeInstructions(recipeInstructions) {
  if (Array.isArray(recipeInstructions)) {
    return recipeInstructions
      .map((entry) => {
        if (typeof entry === "string") return normalizeText(entry);
        if (!entry || typeof entry !== "object") return "";
        if (Array.isArray(entry.itemListElement)) {
          return entry.itemListElement.map((value) => {
            if (typeof value === "string") return normalizeText(value);
            return normalizeText(value?.text ?? value?.name ?? "");
          }).filter(Boolean);
        }
        return normalizeText(entry.text ?? entry.name ?? "");
      })
      .flat()
      .filter(Boolean);
  }

  if (typeof recipeInstructions === "string") {
    return uniqueStrings(
      sanitizeRecipeText(recipeInstructions)
        .split(/\n+/)
        .map(normalizeText)
    );
  }

  return [];
}

function pickBestSchemaRecipe(jsonLdRecipes) {
  const flattened = [];

  const visit = (value) => {
    if (!value) return;
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (typeof value !== "object") return;

    const graph = Array.isArray(value["@graph"]) ? value["@graph"] : [];
    if (graph.length) graph.forEach(visit);

    const type = value["@type"];
    const types = Array.isArray(type) ? type : [type];
    if (types.some((entry) => String(entry ?? "").toLowerCase() === "recipe")) {
      flattened.push(value);
    }
  };

  visit(jsonLdRecipes);

  return flattened
    .map((recipe) => ({
      recipe,
      score:
        (Array.isArray(recipe.recipeIngredient) ? recipe.recipeIngredient.length : 0) * 5
        + parseSchemaRecipeInstructions(recipe.recipeInstructions).length * 7
        + (normalizeText(recipe.name) ? 10 : 0)
        + (normalizeText(recipe.description) ? 4 : 0),
    }))
    .sort((left, right) => right.score - left.score)[0]?.recipe ?? null;
}

async function loadPlaywright() {
  try {
    const localModule = await import(PLAYWRIGHT_FALLBACK_PATH);
    return localModule.default ?? localModule;
  } catch {
    const module = await import("playwright");
    return module.default ?? module;
  }
}

async function createBrowserContext({ headless = true } = {}) {
  const playwright = await loadPlaywright();
  const browser = await playwright.chromium.launch(
    buildPlaywrightLaunchOptions({ headless })
  );
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1800 },
    locale: "en-US",
    userAgent: DEFAULT_USER_AGENT,
  });
  await context.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
  });
  return { browser, context };
}

function absoluteURLFrom(baseURL, value) {
  const raw = htmlDecode(value);
  if (!raw) return null;
  try {
    return cleanURL(new URL(raw, baseURL).toString());
  } catch {
    return cleanURL(raw);
  }
}

function stripHTML(value) {
  return normalizeText(
    htmlDecode(String(value ?? "")
      .replace(/<script[\s\S]*?<\/script>/gi, " ")
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<[^>]+>/g, " "))
  );
}

function htmlAttribute(tag, attributeName) {
  const pattern = new RegExp(`${attributeName}\\s*=\\s*([\"'])(.*?)\\1`, "i");
  return htmlDecode(tag.match(pattern)?.[2] ?? "");
}

function htmlMetaContent(html, names = []) {
  for (const name of names) {
    const escaped = String(name).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const patterns = [
      new RegExp(`<meta\\b(?=[^>]*(?:property|name)=[\"']${escaped}[\"'])[^>]*>`, "i"),
      new RegExp(`<meta\\b(?=[^>]*content=[\"'][^\"']*[\"'])(?=[^>]*(?:property|name)=[\"']${escaped}[\"'])[^>]*>`, "i"),
    ];
    for (const pattern of patterns) {
      const tag = html.match(pattern)?.[0];
      const content = tag ? htmlAttribute(tag, "content") : "";
      if (content) return normalizeText(content);
    }
  }
  return "";
}

function parseJsonLdFromHTML(html) {
  const records = [];
  const pattern = /<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let match = null;
  while ((match = pattern.exec(html))) {
    const raw = htmlDecode(match[1] ?? "").trim();
    if (!raw) continue;
    try {
      records.push(JSON.parse(raw));
    } catch {
      continue;
    }
  }
  return records;
}

function extractImageURLsFromHTML(html, baseURL) {
  const urls = [
    htmlMetaContent(html, ["og:image", "twitter:image"]),
  ];
  const pattern = /<img\b[^>]*(?:src|data-src)=["']([^"']+)["'][^>]*>/gi;
  let match = null;
  while ((match = pattern.exec(html)) && urls.length < 30) {
    urls.push(absoluteURLFrom(baseURL, match[1]));
  }
  return uniqueStrings(urls.map(cleanURL).filter(Boolean)).slice(0, 24);
}

async function extractWebSourceWithFetch(sourceURL, { playwrightError = null } = {}) {
  const response = await fetchWithTimeout(sourceURL, {
    redirect: "follow",
    headers: {
      "user-agent": DEFAULT_USER_AGENT,
      accept: "text/html,application/xhtml+xml",
    },
  }, SOCIAL_FETCH_TIMEOUT_MS, "web source fetch");
  const html = await response.text();
  if (!response.ok) {
    throw new Error(`Fetch fallback returned HTTP ${response.status} for ${sourceURL}`);
  }

  const jsonLd = parseJsonLdFromHTML(html);
  const structuredRecipe = pickBestSchemaRecipe(jsonLd);
  const instructions = parseSchemaRecipeInstructions(structuredRecipe?.recipeInstructions);
  const title = stripHTML(html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i)?.[1])
    || htmlMetaContent(html, ["og:title", "twitter:title"])
    || stripHTML(html.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i)?.[1]);
  const pageImageURLs = extractImageURLsFromHTML(html, response.url || sourceURL);
  const metaImageURL = htmlMetaContent(html, ["og:image", "twitter:image"]);
  const bodyText = stripHTML(html).slice(0, 120000);

  return {
    source_type: "web",
    platform: "web",
    source_url: cleanURL(response.url || sourceURL),
    canonical_url: cleanURL(html.match(/<link\b(?=[^>]*rel=["']canonical["'])[^>]*href=["']([^"']+)["'][^>]*>/i)?.[1]) ?? cleanURL(response.url || sourceURL),
    title: title || null,
    meta_title: htmlMetaContent(html, ["og:title", "twitter:title"]) || null,
    meta_description: htmlMetaContent(html, ["description", "og:description", "twitter:description"]) || null,
    hero_image_url: cleanURL(absoluteURLFrom(response.url || sourceURL, metaImageURL)),
    attached_video_url: cleanURL(htmlMetaContent(html, ["og:video", "og:video:url"])),
    site_name: htmlMetaContent(html, ["og:site_name"]) || hostForURL(response.url || sourceURL),
    author_name: htmlMetaContent(html, ["author"]) || null,
    ingredient_candidates: Array.isArray(structuredRecipe?.recipeIngredient) ? structuredRecipe.recipeIngredient : [],
    instruction_candidates: instructions,
    page_image_urls: pageImageURLs,
    body_text: bodyText,
    structured_recipe: structuredRecipe
      ? {
          ...structuredRecipe,
          recipeIngredient: Array.isArray(structuredRecipe.recipeIngredient) ? structuredRecipe.recipeIngredient : [],
          recipeInstructions: instructions,
        }
      : null,
    artifacts: [
      {
        artifact_type: "web_metadata",
        content_type: "application/json",
        source_url: cleanURL(response.url || sourceURL),
        raw_json: compactJSON({
          extraction_method: "fetch_fallback",
          playwright_error: errorSummary(playwrightError),
          meta_title: htmlMetaContent(html, ["og:title", "twitter:title"]),
          meta_description: htmlMetaContent(html, ["description", "og:description", "twitter:description"]),
          meta_image_url: metaImageURL,
          site_name: htmlMetaContent(html, ["og:site_name"]),
          author_name: htmlMetaContent(html, ["author"]),
          page_image_urls: pageImageURLs,
          structured_recipe: structuredRecipe,
        }),
      },
      {
        artifact_type: "web_text",
        content_type: "text/plain",
        source_url: cleanURL(response.url || sourceURL),
        text_content: bodyText,
      },
    ],
  };
}

async function extractWebSourceWithPlaywright(sourceURL) {
  const { browser, context } = await createBrowserContext({ headless: true });
  const page = await context.newPage();
  page.setDefaultTimeout(45_000);
  page.setDefaultNavigationTimeout(60_000);

  try {
    await page.goto(sourceURL, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(2_000);

    const pageData = await page.evaluate(() => {
      const normalize = (value) =>
        String(value ?? "")
          .replace(/\s+/g, " ")
          .trim();

      const unique = (values) => {
        const seen = new Set();
        const result = [];
        for (const value of values) {
          const normalized = normalize(value);
          if (!normalized) continue;
          const key = normalized.toLowerCase();
          if (seen.has(key)) continue;
          seen.add(key);
          result.push(normalized);
        }
        return result;
      };

      const meta = (name) =>
        document.querySelector(`meta[property="${name}"]`)?.getAttribute("content")
        || document.querySelector(`meta[name="${name}"]`)?.getAttribute("content")
        || null;

      const parseJsonLd = () => {
        return Array.from(document.querySelectorAll('script[type="application/ld+json"]'))
          .map((node) => node.textContent || "")
          .map((raw) => {
            try {
              return JSON.parse(raw);
            } catch {
              return null;
            }
          })
          .filter(Boolean);
      };

      const findSectionItems = (labels, selectors = ["li", "p"]) => {
        const heading = Array.from(document.querySelectorAll("h1,h2,h3,h4,strong"))
          .find((node) => labels.includes(normalize(node.textContent).toLowerCase()));
        if (!heading) return [];

        const containers = [];
        let node = heading.parentElement;
        let depth = 0;
        while (node && depth < 4) {
          containers.push(node);
          node = node.parentElement;
          depth += 1;
        }

        const lines = [];
        for (const container of containers) {
          for (const selector of selectors) {
            for (const item of Array.from(container.querySelectorAll(selector))) {
              const text = normalize(item.textContent);
              if (text) lines.push(text);
            }
          }
          if (lines.length >= 4) break;
        }
        return unique(lines).slice(0, 80);
      };

      const ingredientCandidates = unique([
        ...Array.from(document.querySelectorAll('[itemprop="recipeIngredient"]')).map((node) => node.textContent || ""),
        ...Array.from(document.querySelectorAll('li[class*="ingredient"], [class*="ingredient"] li, [data-ingredient]')).map((node) => node.textContent || ""),
        ...findSectionItems(["ingredients"], ["li", "p", "span"]),
      ]).slice(0, 120);

      const instructionCandidates = unique([
        ...Array.from(document.querySelectorAll('[itemprop="recipeInstructions"] li, [itemprop="recipeInstructions"] p')).map((node) => node.textContent || ""),
        ...Array.from(document.querySelectorAll('li[class*="instruction"], li[class*="direction"], [class*="instructions"] li')).map((node) => node.textContent || ""),
        ...findSectionItems(["instructions", "method", "directions"], ["li", "p"]),
      ]).slice(0, 120);

      const pageImageURLs = unique([
        meta("og:image"),
        meta("twitter:image"),
        ...Array.from(document.images)
          .map((node) => node.getAttribute("src") || node.getAttribute("data-src") || node.currentSrc || "")
          .filter(Boolean),
      ])
        .filter((url) => /^https?:\/\//i.test(url))
        .slice(0, 24);

      return {
        source_url: window.location.href,
        canonical_url: document.querySelector('link[rel="canonical"]')?.getAttribute("href") || window.location.href,
        title: normalize(document.querySelector("h1")?.textContent) || normalize(document.title),
        meta_title: normalize(meta("og:title") || meta("twitter:title") || document.title),
        meta_description: normalize(meta("description") || meta("og:description") || meta("twitter:description")),
        meta_image_url: meta("og:image") || meta("twitter:image") || null,
        meta_video_url: meta("og:video") || meta("og:video:url") || null,
        site_name: normalize(meta("og:site_name")),
        author_name: normalize(meta("author")),
        body_text: normalize(document.body?.innerText || "").slice(0, 120000),
        ingredient_candidates: ingredientCandidates,
        instruction_candidates: instructionCandidates,
        page_image_urls: pageImageURLs,
        json_ld: parseJsonLd(),
      };
    });

    const structuredRecipe = pickBestSchemaRecipe(pageData.json_ld);
    const instructions = parseSchemaRecipeInstructions(structuredRecipe?.recipeInstructions);

    return {
      source_type: "web",
      platform: "web",
      source_url: cleanURL(pageData.source_url),
      canonical_url: cleanURL(pageData.canonical_url) ?? cleanURL(sourceURL),
      title: pageData.title || pageData.meta_title || null,
      meta_title: pageData.meta_title || null,
      meta_description: pageData.meta_description || null,
      hero_image_url: cleanURL(pageData.meta_image_url),
      attached_video_url: cleanURL(pageData.meta_video_url),
      site_name: pageData.site_name || hostForURL(sourceURL),
      author_name: pageData.author_name || null,
      ingredient_candidates: pageData.ingredient_candidates ?? [],
      instruction_candidates: pageData.instruction_candidates ?? [],
      page_image_urls: pageData.page_image_urls ?? [],
      body_text: pageData.body_text ?? "",
      structured_recipe: structuredRecipe
        ? {
            ...structuredRecipe,
            recipeIngredient: Array.isArray(structuredRecipe.recipeIngredient) ? structuredRecipe.recipeIngredient : [],
            recipeInstructions: instructions,
          }
        : null,
      artifacts: [
        {
          artifact_type: "web_metadata",
          content_type: "application/json",
          source_url: cleanURL(pageData.source_url),
          raw_json: compactJSON({
            meta_title: pageData.meta_title,
            meta_description: pageData.meta_description,
            meta_image_url: pageData.meta_image_url,
            meta_video_url: pageData.meta_video_url,
            site_name: pageData.site_name,
            author_name: pageData.author_name,
            page_image_urls: pageData.page_image_urls ?? [],
            structured_recipe: structuredRecipe,
          }),
        },
        {
          artifact_type: "web_text",
          content_type: "text/plain",
          source_url: cleanURL(pageData.source_url),
          text_content: pageData.body_text,
        },
      ],
    };
  } finally {
    await page.close().catch(() => {});
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
  }
}

async function extractWebSource(sourceURL) {
  try {
    return await extractWebSourceWithPlaywright(sourceURL);
  } catch (error) {
    return extractWebSourceWithFetch(sourceURL, { playwrightError: error });
  }
}

async function extractSocialPageSignals(sourceURL, platform) {
  const cacheKey = sourceMetadataCacheKey(`${platform}-page-signals`, sourceURL);
  const cached = await readRedisJSON(cacheKey);
  if (cached) return cached;

  try {
    const pageSignals = await extractWebSourceWithFetch(sourceURL, { playwrightError: new Error(`${platform} browser extraction skipped`) });
    const compact = compactPageSignalsForCache(pageSignals);
    if (compact) {
      void writeRedisJSON(cacheKey, compact, SOURCE_METADATA_CACHE_TTL_SECONDS);
    }
    return pageSignals;
  } catch (error) {
    console.warn(`[recipe-ingestion] ${platform} page signals skipped:`, error instanceof Error ? error.message : error);
    return null;
  }
}

function pickSubtitleTrack(info) {
  const candidates = [];
  for (const sourceName of ["subtitles", "automatic_captions"]) {
    const bucket = info?.[sourceName];
    if (!bucket || typeof bucket !== "object") continue;
    for (const [language, tracks] of Object.entries(bucket)) {
      if (!Array.isArray(tracks)) continue;
      for (const track of tracks) {
        candidates.push({
          source_name: sourceName,
          language,
          ext: track.ext ?? null,
          url: track.url ?? null,
        });
      }
    }
  }

  return candidates
    .filter((candidate) => candidate.url)
    .sort((left, right) => {
      const leftEnglish = /^en/i.test(left.language) ? 1 : 0;
      const rightEnglish = /^en/i.test(right.language) ? 1 : 0;
      if (rightEnglish !== leftEnglish) return rightEnglish - leftEnglish;
      const leftJson = left.ext === "json3" ? 1 : 0;
      const rightJson = right.ext === "json3" ? 1 : 0;
      return rightJson - leftJson;
    })[0] ?? null;
}

async function downloadTranscript(track) {
  if (!track?.url) return "";
  const response = await fetchWithTimeout(track.url, {}, SOCIAL_FETCH_TIMEOUT_MS, "subtitle fetch");
  const raw = await response.text();
  if (!response.ok) {
    return "";
  }

  if (track.ext === "json3" || raw.trim().startsWith("{")) {
    try {
      const parsed = JSON.parse(raw);
      return uniqueStrings(
        (parsed.events ?? [])
          .flatMap((event) => event.segs ?? [])
          .map((segment) => segment.utf8 ?? "")
      ).join(" ");
    } catch {
      return "";
    }
  }

  return raw
    .replace(/^WEBVTT.*$/gim, "")
    .replace(/^\d+$/gim, "")
    .replace(/^\d{2}:\d{2}(?::\d{2})?\.\d+\s+-->\s+\d{2}:\d{2}(?::\d{2})?\.\d+.*$/gim, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function bestThumbnail(info) {
  const thumbnails = Array.isArray(info?.thumbnails) ? info.thumbnails : [];
  return thumbnails
    .map((thumbnail) => ({
      url: cleanURL(thumbnail.url),
      area: (thumbnail.width ?? 0) * (thumbnail.height ?? 0),
    }))
    .filter((thumbnail) => thumbnail.url)
    .sort((left, right) => right.area - left.area)[0]?.url ?? null;
}

function toDataURL(buffer, mimeType = "image/jpeg") {
  return `data:${mimeType};base64,${Buffer.from(buffer).toString("base64")}`;
}

function imageBufferFromDataURL(dataURL) {
  const raw = normalizeText(dataURL ?? "");
  const match = raw.match(/^data:([^;,]+)?(?:;charset=[^;,]+)?;base64,(.+)$/i);
  if (!match) return null;
  try {
    const buffer = Buffer.from(match[2], "base64");
    if (!buffer.length) return null;
    return {
      buffer,
      contentType: normalizeText(match[1] ?? "image/jpeg") || "image/jpeg",
    };
  } catch {
    return null;
  }
}

async function commandExists(command) {
  try {
    await execFileWithTimeout("which", [command], 2_000);
    return true;
  } catch {
    return false;
  }
}

async function findDownloadedVideoPath(directory) {
  const entries = await fsp.readdir(directory, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(directory, entry.name))
    .find((filePath) => /\.(mp4|mov|m4v|webm)$/i.test(filePath)) ?? null;
}

async function sampleVideoFrames(videoPath, maxFrames = MAX_SOCIAL_FRAME_COUNT) {
  if (!(await commandExists("ffmpeg")) || !(await commandExists("ffprobe"))) {
    return [];
  }

  let duration = 12;
  try {
    const { stdout } = await execFileWithTimeout("ffprobe", [
      "-v", "error",
      "-show_entries", "format=duration",
      "-of", "default=noprint_wrappers=1:nokey=1",
      videoPath,
    ], SOCIAL_FRAME_PROBE_TIMEOUT_MS);
    const parsed = Number.parseFloat(String(stdout ?? "").trim());
    if (Number.isFinite(parsed) && parsed > 0) {
      duration = parsed;
    }
  } catch {
    // Keep the default.
  }

  const frameDir = await fsp.mkdtemp(path.join(os.tmpdir(), "ounje-social-frames-"));
  const timestamps = Array.from({ length: maxFrames }, (_, index) => {
    const safeDuration = Math.max(duration - 0.4, 1);
    const fraction = (index + 1) / (maxFrames + 1);
    return Math.max(0.1, safeDuration * fraction);
  });

  const frameDataURLs = [];
  try {
    for (const [index, seconds] of timestamps.entries()) {
      const outputPath = path.join(frameDir, `frame-${index + 1}.jpg`);
      await execFileWithTimeout("ffmpeg", [
        "-y",
        "-ss", seconds.toFixed(2),
        "-i", videoPath,
        "-frames:v", "1",
        "-vf", "scale='min(720,iw)':-2",
        "-q:v", "2",
        outputPath,
      ], SOCIAL_FRAME_EXTRACT_TIMEOUT_MS);
      const buffer = await fsp.readFile(outputPath);
      frameDataURLs.push(toDataURL(buffer, "image/jpeg"));
    }
  } catch {
    // Best effort.
  } finally {
    await fsp.rm(frameDir, { recursive: true, force: true }).catch(() => {});
  }

  return frameDataURLs;
}

async function transcribeShortVideo(videoPath) {
  if (!openai || !(await commandExists("ffmpeg"))) {
    return "";
  }

  const audioPath = path.join(os.tmpdir(), `ounje-short-video-${nanoid(8)}.mp3`);
  try {
    await execFileWithTimeout("ffmpeg", [
      "-y",
      "-i", videoPath,
      "-vn",
      "-ac", "1",
      "-ar", "16000",
      audioPath,
    ], SOCIAL_AUDIO_EXTRACT_TIMEOUT_MS);

    const stat = await fsp.stat(audioPath).catch(() => null);
    if (!stat || stat.size === 0) return "";

    const transcript = await withRecipeAIStage("recipe_import.short_video_transcription", () => withTimeout(
      openai.audio.transcriptions.create({
        file: fs.createReadStream(audioPath),
        model: SHORT_VIDEO_TRANSCRIBE_MODEL,
      }),
      SOCIAL_VIDEO_DOWNLOAD_TIMEOUT_MS,
      "short video transcription"
    ));
    return normalizeText(transcript?.text ?? "");
  } catch {
    return "";
  } finally {
    await fsp.rm(audioPath, { force: true }).catch(() => {});
  }
}

async function enrichDownloadedShortVideoSource(sourceURL, platform, metadata = null) {
  const tempDir = await fsp.mkdtemp(path.join(os.tmpdir(), `ounje-${platform}-`));
  try {
    await withTimeout(
      ytdl(sourceURL, socialYTDLOptions({
        output: path.join(tempDir, "asset.%(ext)s"),
        format: "mp4/best",
        mergeOutputFormat: "mp4",
      }), ytdlExecOptions(SOCIAL_VIDEO_DOWNLOAD_TIMEOUT_MS)),
      SOCIAL_VIDEO_DOWNLOAD_TIMEOUT_MS,
      `${platform} video download`
    );

    const videoPath = await findDownloadedVideoPath(tempDir);
    if (!videoPath) {
      return {
        transcript_text: "",
        frame_data_urls: [],
        downloaded_video: false,
      };
    }

    const [transcriptText, frameDataURLs] = await Promise.all([
      transcribeShortVideo(videoPath),
      sampleVideoFrames(videoPath, MAX_SOCIAL_FRAME_COUNT),
    ]);
    const frameOCRTexts = await ocrFrameDataURLs(frameDataURLs);

    return {
      transcript_text: transcriptText,
      frame_data_urls: frameDataURLs,
      frame_ocr_texts: frameOCRTexts,
      downloaded_video: true,
      metadata_preview: compactJSON({
        id: metadata?.id ?? null,
        title: metadata?.title ?? null,
        description: metadata?.description ?? null,
        uploader: metadata?.uploader ?? null,
        uploader_id: metadata?.uploader_id ?? null,
      }),
    };
  } catch (error) {
    console.warn(`[recipe-ingestion] ${platform} video download skipped:`, error instanceof Error ? error.message : error);
    return {
      transcript_text: "",
      frame_data_urls: [],
      frame_ocr_texts: [],
      downloaded_video: false,
    };
  } finally {
    await fsp.rm(tempDir, { recursive: true, force: true }).catch(() => {});
  }
}

async function extractYouTubeSource(sourceURL) {
  const info = await fetchYtdlMetadataCached(sourceURL, {
    label: "youtube metadata resolve",
    cacheKind: "youtube-metadata",
  });

  const subtitleTrack = pickSubtitleTrack(info);
  const transcriptText = await downloadTranscript(subtitleTrack);
  const thumbnailURL = bestThumbnail(info);
  const downloadedSignals = await enrichDownloadedShortVideoSource(sourceURL, "youtube", info);
  const resolvedTranscript = normalizeText(downloadedSignals.transcript_text || transcriptText);
  const evidenceBundle = buildVideoEvidenceBundle({
    source_type: "youtube",
    platform: "youtube",
    source_url: cleanURL(sourceURL),
    canonical_url: cleanURL(info.webpage_url ?? sourceURL),
    title: normalizeText(info.title),
    description: normalizeText(info.description),
    author_name: normalizeText(info.channel ?? info.uploader),
    author_handle: normalizeText(info.uploader_id ? `@${info.uploader_id}` : ""),
    author_url: cleanURL(info.channel_url ?? info.uploader_url ?? null),
    attached_video_url: cleanURL(info.webpage_url ?? sourceURL),
    meta_description: normalizeText(info.description),
    frame_data_urls: downloadedSignals.frame_data_urls ?? [],
  }, {
    transcriptText: resolvedTranscript || transcriptText || "",
    frameOcrTexts: downloadedSignals.frame_ocr_texts ?? [],
    downloadedVideo: downloadedSignals.downloaded_video,
  });

  return {
    source_type: "youtube",
    platform: "youtube",
    source_url: cleanURL(sourceURL),
    canonical_url: cleanURL(info.webpage_url ?? sourceURL),
    title: normalizeText(info.title),
    description: normalizeText(info.description),
    author_name: normalizeText(info.channel ?? info.uploader),
    author_handle: normalizeText(info.uploader_id ? `@${info.uploader_id}` : ""),
    author_url: cleanURL(info.channel_url ?? info.uploader_url ?? null),
    hero_image_url: thumbnailURL,
    thumbnail_url: thumbnailURL,
    attached_video_url: cleanURL(info.webpage_url ?? sourceURL),
    transcript_text: resolvedTranscript || null,
    frame_data_urls: downloadedSignals.frame_data_urls ?? [],
    frame_ocr_texts: downloadedSignals.frame_ocr_texts ?? [],
    raw_text: limitText([info.description, resolvedTranscript].filter(Boolean).join("\n\n")),
    source_provenance_json: evidenceBundle,
    artifacts: [
      {
        artifact_type: "youtube_metadata",
        content_type: "application/json",
        source_url: cleanURL(info.webpage_url ?? sourceURL),
        raw_json: compactJSON({
          id: info.id,
          title: info.title,
          description: info.description,
          uploader: info.uploader,
          uploader_id: info.uploader_id,
          duration: info.duration,
          upload_date: info.upload_date,
          subtitle_track: subtitleTrack,
          thumbnails: info.thumbnails,
        }),
      },
      resolvedTranscript
        ? {
            artifact_type: "youtube_transcript",
            content_type: "text/plain",
            source_url: cleanURL(info.webpage_url ?? sourceURL),
            text_content: resolvedTranscript,
          }
        : null,
      downloadedSignals.downloaded_video
        ? {
            artifact_type: "youtube_video_inference",
            content_type: "application/json",
            source_url: cleanURL(info.webpage_url ?? sourceURL),
            raw_json: compactJSON({
              downloaded_video: true,
              frame_count: downloadedSignals.frame_data_urls?.length ?? 0,
              transcript_excerpt: resolvedTranscript ? resolvedTranscript.slice(0, 2000) : null,
              frame_ocr_texts: downloadedSignals.frame_ocr_texts ?? [],
              metadata_preview: downloadedSignals.metadata_preview ?? null,
            }),
          }
        : null,
      {
        artifact_type: "youtube_evidence_bundle",
        content_type: "application/json",
        source_url: cleanURL(info.webpage_url ?? sourceURL),
        raw_json: compactJSON(evidenceBundle),
      },
    ].filter(Boolean),
  };
}

async function extractSocialSource(sourceURL, platform) {
  let metadata = null;
  let blocked = false;
  try {
    metadata = await fetchYtdlMetadataCached(sourceURL, {
      label: `${platform} metadata resolve`,
      cacheKind: `${platform}-metadata`,
    });
  } catch (error) {
    blocked = true;
    console.warn(`[recipe-ingestion] ${platform} metadata skipped:`, error instanceof Error ? error.message : error);
  }

  const transcriptTrack = metadata ? pickSubtitleTrack(metadata) : null;
  const [pageSignals, transcriptText, downloadedSignals] = await Promise.all([
    extractSocialPageSignals(sourceURL, platform),
    downloadTranscript(transcriptTrack),
    enrichDownloadedShortVideoSource(sourceURL, platform, metadata),
  ]);
  const mediaMode = inferSocialMediaMode({
    downloadedVideo: downloadedSignals.downloaded_video,
    pageSignals,
    metadata,
  });
  const fallbackCarouselFrames = !downloadedSignals.downloaded_video
    ? await imageURLsToDataURLs([
        ...(pageSignals?.page_image_urls ?? []),
        pageSignals?.hero_image_url ?? null,
        bestThumbnail(metadata),
      ].filter(Boolean), MAX_SOCIAL_FRAME_COUNT)
    : [];
  const effectiveFrameDataURLs = (downloadedSignals.frame_data_urls?.length ? downloadedSignals.frame_data_urls : fallbackCarouselFrames) ?? [];
  const effectiveFrameOCRTexts = downloadedSignals.frame_ocr_texts?.length
    ? downloadedSignals.frame_ocr_texts
    : await ocrFrameDataURLs(effectiveFrameDataURLs);
  const resolvedTranscript = normalizeText(downloadedSignals.transcript_text || transcriptText);
  const title = normalizeText(metadata?.title ?? pageSignals?.title ?? "");
  const description = normalizeText(metadata?.description ?? pageSignals?.meta_description ?? pageSignals?.body_text ?? "");
  const thumbnailURL = cleanURL(bestThumbnail(metadata) ?? pageSignals?.hero_image_url ?? null);
  const creatorHandle = firstCreatorHandle(
    metadata?.uploader_id,
    metadata?.channel_id,
    metadata?.creator,
    metadata?.uploader_url,
    metadata?.channel_url,
    pageSignals?.author_handle,
    pageSignals?.author_url
  );

  const evidenceBundle = buildVideoEvidenceBundle({
    source_type: platform,
    platform,
    media_mode: mediaMode,
    source_url: cleanURL(sourceURL),
    canonical_url: cleanURL(metadata?.webpage_url ?? pageSignals?.canonical_url ?? sourceURL),
    title,
    description,
    author_name: normalizeText(metadata?.uploader ?? pageSignals?.author_name ?? "") || null,
    author_handle: creatorHandle,
    author_url: cleanURL(metadata?.uploader_url ?? metadata?.channel_url ?? null),
    attached_video_url: cleanURL(metadata?.webpage_url ?? sourceURL),
    meta_description: description,
    page_signals_summary: compactJSON({
      title: pageSignals?.title ?? null,
      meta_title: pageSignals?.meta_title ?? null,
      meta_description: pageSignals?.meta_description ?? null,
      site_name: pageSignals?.site_name ?? null,
    }),
    frame_data_urls: effectiveFrameDataURLs,
  }, {
    transcriptText: resolvedTranscript || transcriptText || "",
    frameOcrTexts: effectiveFrameOCRTexts,
    downloadedVideo: downloadedSignals.downloaded_video,
  });

  return {
    source_type: platform,
    platform,
    source_url: cleanURL(sourceURL),
    canonical_url: cleanURL(metadata?.webpage_url ?? pageSignals?.canonical_url ?? sourceURL),
    title: title || null,
    description: description || null,
    author_name: normalizeText(metadata?.uploader ?? pageSignals?.author_name ?? "") || null,
    author_handle: creatorHandle,
    author_url: cleanURL(metadata?.uploader_url ?? metadata?.channel_url ?? null),
    hero_image_url: thumbnailURL,
    thumbnail_url: thumbnailURL,
    attached_video_url: cleanURL(metadata?.webpage_url ?? sourceURL),
    transcript_text: resolvedTranscript || null,
    frame_data_urls: effectiveFrameDataURLs,
    frame_ocr_texts: effectiveFrameOCRTexts,
    page_image_urls: pageSignals?.page_image_urls ?? [],
    media_mode: mediaMode,
    blocked,
    raw_text: limitText([description, resolvedTranscript].filter(Boolean).join("\n\n")),
    source_provenance_json: evidenceBundle,
    artifacts: [
      metadata
        ? {
            artifact_type: `${platform}_metadata`,
            content_type: "application/json",
            source_url: cleanURL(metadata.webpage_url ?? sourceURL),
            raw_json: compactJSON({
              id: metadata.id,
              title: metadata.title,
              description: metadata.description,
              uploader: metadata.uploader,
              uploader_id: metadata.uploader_id,
              duration: metadata.duration,
              subtitles: metadata.subtitles,
              automatic_captions: metadata.automatic_captions,
              thumbnails: metadata.thumbnails,
              media_mode: mediaMode,
            }),
          }
        : null,
      mediaMode === "slideshow"
        ? {
            artifact_type: `${platform}_slideshow_inference`,
            content_type: "application/json",
            source_url: cleanURL(metadata?.webpage_url ?? sourceURL),
            raw_json: compactJSON({
              media_mode: mediaMode,
              page_image_urls: (pageSignals?.page_image_urls ?? []).slice(0, 12),
              frame_count: effectiveFrameDataURLs.length,
              frame_ocr_texts: effectiveFrameOCRTexts,
            }),
          }
        : null,
      downloadedSignals.downloaded_video
        ? {
            artifact_type: `${platform}_video_inference`,
            content_type: "application/json",
            source_url: cleanURL(metadata?.webpage_url ?? sourceURL),
            raw_json: compactJSON({
              downloaded_video: true,
              frame_count: downloadedSignals.frame_data_urls?.length ?? 0,
              transcript_excerpt: resolvedTranscript ? resolvedTranscript.slice(0, 2000) : null,
              frame_ocr_texts: downloadedSignals.frame_ocr_texts ?? [],
              metadata_preview: downloadedSignals.metadata_preview ?? null,
            }),
          }
        : null,
      {
        artifact_type: `${platform}_evidence_bundle`,
        content_type: "application/json",
        source_url: cleanURL(metadata?.webpage_url ?? sourceURL),
        raw_json: compactJSON(evidenceBundle),
      },
      pageSignals
        ? {
            artifact_type: `${platform}_page_signals`,
            content_type: "application/json",
            source_url: pageSignals.source_url,
            raw_json: compactJSON({
              title: pageSignals.title,
              meta_title: pageSignals.meta_title,
              meta_description: pageSignals.meta_description,
              site_name: pageSignals.site_name,
              ingredient_candidates: pageSignals.ingredient_candidates,
              instruction_candidates: pageSignals.instruction_candidates,
            }),
          }
        : null,
    ].filter(Boolean),
  };
}

async function extractTextSource(text, attachments = []) {
  const trimmedText = limitText(text);
  let creationIntent = null;
  if (!attachments.length) {
    creationIntent = await classifyRecipeCreateIntent(trimmedText);
    if (creationIntent.intent === "base_recipe") {
      return extractRecipeSearchSource(creationIntent.search_queries?.[0] ?? trimmedText, attachments);
    }
  }
  const isConceptPrompt = ["fusion_recipe", "custom_recipe"].includes(creationIntent?.intent)
    || looksLikeRecipeIdeaPrompt(trimmedText);
  const promptExamples = isConceptPrompt ? await fetchPromptRecipeExamples(trimmedText) : [];
  const styleExamples = isConceptPrompt
    ? findRecipeStyleExamples({
        recipe: {
          recipe_type: null,
          cuisine_tags: extractIngredientSignals(trimmedText),
        },
        profile: null,
        limit: 3,
      })
    : [];
  const flavorSeeds = isConceptPrompt ? extractIngredientSignals(trimmedText) : [];
  const referenceContext = isConceptPrompt
    ? await collectCreateIntentReferenceSources(creationIntent ?? fallbackRecipeCreateIntent(trimmedText), trimmedText)
    : { recipeSources: [], referenceLookups: [] };

  return {
    source_type: attachments.some((attachment) => attachment.kind === "image") ? "media_image" : attachments.some((attachment) => attachment.kind === "video") ? "media_video" : isConceptPrompt ? "concept_prompt" : "text",
    platform: "direct_input",
    source_url: null,
    canonical_url: null,
    raw_text: trimmedText,
    attachments,
    creation_intent: creationIntent,
    recipe_sources: referenceContext.recipeSources,
    reference_lookups: referenceContext.referenceLookups,
    prompt_examples: promptExamples,
    style_examples: styleExamples,
    flavor_seed_terms: uniqueStrings([
      ...flavorSeeds,
      ...expandFlavorTerms(flavorSeeds, 8),
    ]),
    source_provenance_json: buildSourceProvenanceRecord({
      source_type: attachments.some((attachment) => attachment.kind === "image") ? "media_image" : attachments.some((attachment) => attachment.kind === "video") ? "media_video" : isConceptPrompt ? "concept_prompt" : "text",
      platform: "direct_input",
      source_url: null,
      canonical_url: null,
      attached_video_url: null,
      title: isConceptPrompt ? "Concept prompt" : "Direct input",
      description: trimmedText,
      author_name: null,
      author_handle: null,
      hero_image_url: null,
      frame_data_urls: [],
      frame_ocr_texts: [],
      transcript_text: trimmedText,
    }, {
      reviewState: isConceptPrompt ? "draft" : null,
      evidenceBundle: {
        source_type: attachments.some((attachment) => attachment.kind === "image") ? "media_image" : attachments.some((attachment) => attachment.kind === "video") ? "media_video" : isConceptPrompt ? "concept_prompt" : "text",
        raw_text: trimmedText,
        creation_intent: creationIntent,
        reference_lookups: referenceContext.referenceLookups,
        attachments: attachments.map((attachment) => ({
          kind: attachment.kind,
          source_url: attachment.source_url ?? null,
          mime_type: attachment.mime_type ?? null,
          file_name: attachment.file_name ?? null,
        })),
      },
    }),
    artifacts: [
      {
        artifact_type: "input_text",
        content_type: "text/plain",
        text_content: trimmedText,
      },
      ...(isConceptPrompt
        ? [{
            artifact_type: "prompt_examples",
            content_type: "application/json",
            raw_json: compactJSON({
              prompt_examples: promptExamples,
              style_examples: styleExamples,
              recipe_sources: referenceContext.recipeSources,
              creation_intent: creationIntent,
            }),
          }]
        : []),
      ...attachments.map((attachment) => ({
        artifact_type: "input_attachment",
        content_type: attachment.mime_type ?? "application/octet-stream",
        source_url: attachment.source_url,
        raw_json: compactJSON({
          kind: attachment.kind,
          source_url: attachment.source_url,
          mime_type: attachment.mime_type,
          file_name: attachment.file_name,
          preview_frame_urls: attachment.preview_frame_urls,
          has_data_url: Boolean(attachment.data_url),
        }),
      })),
    ],
  };
}

async function collectPhotoRecipeImageInputs(attachments = []) {
  const imageAttachments = (attachments ?? []).filter((attachment) => String(attachment?.kind ?? "").toLowerCase() === "image");
  const results = [];
  for (const attachment of imageAttachments.slice(0, 4)) {
    const mimeType = attachment.mime_type || "image/jpeg";
    let dataURL = attachment.data_url ?? null;
    let fetchError = null;
    if (!dataURL && attachment.storage_bucket && attachment.storage_path) {
      try {
        const object = await fetchSupabaseStorageObject(attachment.storage_bucket, attachment.storage_path);
        if (object?.buffer?.length) dataURL = toDataURL(object.buffer, object.mime_type || mimeType);
      } catch (error) {
        fetchError = errorSummary(error);
      }
    }
    results.push({
      data_url: dataURL,
      source_url: attachment.source_url ?? null,
      public_hero_url: attachment.public_hero_url ?? null,
      storage_bucket: attachment.storage_bucket ?? null,
      storage_path: attachment.storage_path ?? null,
      mime_type: mimeType,
      width: attachment.width ?? null,
      height: attachment.height ?? null,
      fetch_error: fetchError,
    });
  }
  return results.filter((entry) => entry.data_url || entry.source_url || entry.public_hero_url);
}

function primaryPhotoImageURL(imageInput) {
  const dataURL = imageInput?.data_url === "[omitted]" ? null : imageInput?.data_url;
  return dataURL ?? imageInput?.source_url ?? imageInput?.public_hero_url ?? null;
}

function photoImageContentPart(imageInput) {
  const url = primaryPhotoImageURL(imageInput);
  return url ? { type: "image_url", image_url: { url } } : null;
}

async function persistPhotoRecipeHeroImage(imageInput, { recipeKey, accessToken = null } = {}) {
  const uploadedHeroURL = cleanURL(imageInput?.public_hero_url ?? null);
  if (uploadedHeroURL) return uploadedHeroURL;

  const sourceURL = cleanURL(imageInput?.source_url ?? null);
  if (sourceURL) {
    return await persistRecipeImageToStorage(sourceURL, {
      recipeKey,
      imageRole: "photo-hero",
      accessToken,
    });
  }

  const parsedDataURL = imageBufferFromDataURL(imageInput?.data_url);
  if (!parsedDataURL) return null;

  return await uploadRecipeImageBufferToStorage(parsedDataURL.buffer, {
    recipeKey,
    imageRole: "photo-hero",
    accessToken,
    contentType: parsedDataURL.contentType,
    sourceKey: `${recipeKey ?? "photo-recipe"}:${imageInput?.width ?? "w"}x${imageInput?.height ?? "h"}`,
  });
}

async function runPhotoMealGate(imageInput, photoContext = {}) {
  if (!openai) {
    return {
      is_meal: false,
      confidence: 0,
      visible_food_components: [],
      likely_meal_type: null,
      reject_reason: "OpenAI vision is unavailable.",
    };
  }
  const imagePart = photoImageContentPart(imageInput);
  if (!imagePart) {
    return {
      is_meal: false,
      confidence: 0,
      visible_food_components: [],
      likely_meal_type: null,
      reject_reason: "No readable photo was provided.",
    };
  }
  const response = await withRecipeAIStage("recipe_import.photo_meal_gate", () => openai.chat.completions.create({
    model: PHOTO_MEAL_GATE_MODEL,
    ...chatCompletionTemperatureParams(PHOTO_MEAL_GATE_MODEL, 0),
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: [
          "Decide whether this image contains any food — a prepared meal, dish, raw ingredients, baked goods, snack, beverage, or any edible item that could form the basis of a recipe.",
          "Accept: homemade food, restaurant meals, raw ingredients, baked goods, snacks, drinks, and any real food even if imperfectly plated, lit, or photographed.",
          "Reject ONLY: images with absolutely no food present — pure scenery, text-only images, menus/receipts/screenshots, packaged products with no visible food, non-food objects, or completely unrecognizable images.",
          "When in doubt, lean toward accepting — it is better to attempt a recipe extraction than to reject a real food photo.",
          "Return strict JSON only. Do not invent or describe a recipe.",
        ].join("\n"),
      },
      {
        role: "user",
        content: [
          {
            type: "text",
            text: [
              "Optional context:",
              JSON.stringify({
                dish_hint: photoContext?.dish_hint ?? null,
                coarse_place_context: photoContext?.coarse_place_context ?? null,
              }),
              "Return JSON with is_meal (boolean), confidence (0-1), visible_food_components (array of strings), likely_meal_type (string or null), reject_reason (string or null, only set if rejecting).",
            ].join("\n"),
          },
          imagePart,
        ],
      },
    ],
  }));
  const parsed = JSON.parse(response.choices?.[0]?.message?.content ?? "{}");
  const isMeal = Boolean(parsed?.is_meal);
  const confidence = Number.isFinite(Number(parsed?.confidence)) ? Number(parsed.confidence) : 0.5;
  const visibleFoodComponents = uniqueStrings(Array.isArray(parsed?.visible_food_components) ? parsed.visible_food_components : []);
  // If the LLM said is_meal=false but has decent confidence AND found food components, override the rejection.
  // This handles cases where the model is overly conservative about imperfect food photos.
  const confidenceOverride = !isMeal && confidence >= 0.35 && visibleFoodComponents.length > 0;
  return {
    is_meal: isMeal || confidenceOverride,
    confidence,
    visible_food_components: visibleFoodComponents,
    likely_meal_type: normalizeText(parsed?.likely_meal_type ?? "") || null,
    reject_reason: (isMeal || confidenceOverride) ? null : (normalizeText(parsed?.reject_reason ?? "") || null),
  };
}

async function runPhotoVisualAnalysis(imageInput, mealGate, photoContext = {}) {
  if (!openai) {
    return {
      dish_candidates: [],
      visible_ingredients: mealGate?.visible_food_components ?? [],
      likely_hidden_ingredients: [],
      cooking_methods: [],
      cuisine_hints: [],
      plating_context: null,
      uncertainty: "OpenAI vision is unavailable.",
    };
  }
  const imagePart = photoImageContentPart(imageInput);
  if (!imagePart) {
    return {
      dish_candidates: [],
      visible_ingredients: [],
      likely_hidden_ingredients: [],
      cooking_methods: [],
      cuisine_hints: [],
      plating_context: null,
      uncertainty: "No readable photo was provided.",
    };
  }
  const response = await withRecipeAIStage("recipe_import.photo_visual_analysis", () => openai.chat.completions.create({
    model: PHOTO_RECIPE_VISION_MODEL,
    ...chatCompletionTemperatureParams(PHOTO_RECIPE_VISION_MODEL, 0.05),
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: [
          "Analyze the food photo for recipe reconstruction.",
          "Do not create the final recipe. Extract visual evidence only.",
          "Call out uncertainty clearly when ingredients or method are not visible.",
        ].join("\n"),
      },
      {
        role: "user",
        content: [
          {
            type: "text",
            text: [
              "Known context:",
              JSON.stringify({
                dish_hint: photoContext?.dish_hint ?? null,
                coarse_place_context: photoContext?.coarse_place_context ?? null,
                meal_gate: mealGate,
              }),
              "Return JSON with dish_candidates, visible_ingredients, likely_hidden_ingredients, cooking_methods, cuisine_hints, plating_context, uncertainty.",
            ].join("\n"),
          },
          imagePart,
        ],
      },
    ],
  }));
  const parsed = JSON.parse(response.choices?.[0]?.message?.content ?? "{}");
  return {
    dish_candidates: Array.isArray(parsed?.dish_candidates) ? parsed.dish_candidates.slice(0, 5) : [],
    visible_ingredients: uniqueStrings(Array.isArray(parsed?.visible_ingredients) ? parsed.visible_ingredients : []),
    likely_hidden_ingredients: uniqueStrings(Array.isArray(parsed?.likely_hidden_ingredients) ? parsed.likely_hidden_ingredients : []),
    cooking_methods: uniqueStrings(Array.isArray(parsed?.cooking_methods) ? parsed.cooking_methods : []),
    cuisine_hints: uniqueStrings(Array.isArray(parsed?.cuisine_hints) ? parsed.cuisine_hints : []),
    plating_context: normalizeText(parsed?.plating_context ?? "", 500) || null,
    uncertainty: normalizeText(parsed?.uncertainty ?? "", 700) || null,
  };
}

function photoRecipeSearchQuery(visualAnalysis = {}, photoContext = {}) {
  const candidate = visualAnalysis?.dish_candidates?.[0]?.name
    ?? photoContext?.dish_hint
    ?? visualAnalysis?.visible_ingredients?.slice(0, 4).join(" ");
  const place = photoContext?.coarse_place_context ? ` ${photoContext.coarse_place_context}` : "";
  return normalizeText(`${candidate ?? "plated dish"}${place}`.trim(), 180) || "plated dish recipe";
}

async function runPhotoFallbackWebContext(visualAnalysis, photoContext, source) {
  const query = photoRecipeSearchQuery(visualAnalysis, photoContext);
  try {
    const recipeSearchSource = await extractRecipeSearchSource(query, [], { source });
    return {
      matched_dish_name: visualAnalysis?.dish_candidates?.[0]?.name ?? photoContext?.dish_hint ?? null,
      confidence: 0.45,
      reference_urls: (recipeSearchSource?.recipe_sources ?? []).map((entry) => entry.url).filter(Boolean).slice(0, RECIPE_REFERENCE_MAX_SOURCES),
      ingredient_patterns: (recipeSearchSource?.ingredient_candidates ?? []).slice(0, 24),
      quantity_patterns: [],
      technique_notes: (recipeSearchSource?.instruction_candidates ?? []).slice(0, 10),
      restaurant_context: photoContext?.coarse_place_context ?? null,
      cautions: ["Perplexity Sonar was unavailable; used Ounje web-reference fallback."],
      fallback: true,
      search_methods: recipeSearchSource?.search_methods ?? [],
    };
  } catch (error) {
    return {
      matched_dish_name: visualAnalysis?.dish_candidates?.[0]?.name ?? photoContext?.dish_hint ?? null,
      confidence: 0.25,
      reference_urls: [],
      ingredient_patterns: [],
      quantity_patterns: [],
      technique_notes: [],
      restaurant_context: photoContext?.coarse_place_context ?? null,
      cautions: [`Web-reference fallback failed: ${errorSummary(error).message}`],
      fallback: true,
    };
  }
}

async function runPhotoSonarContext(visualAnalysis, photoContext, source) {
  if (!PERPLEXITY_API_KEY) {
    return runPhotoFallbackWebContext(visualAnalysis, photoContext, source);
  }
  const query = photoRecipeSearchQuery(visualAnalysis, photoContext);
  const payload = {
    model: PHOTO_RECIPE_SONAR_MODEL,
    temperature: 0.1,
    response_format: {
      type: "json_schema",
      json_schema: {
        schema: {
          type: "object",
          properties: {
            matched_dish_name: { type: ["string", "null"] },
            confidence: { type: "number" },
            exact_match_supported: { type: "boolean" },
            reference_urls: { type: "array", items: { type: "string" } },
            ingredient_patterns: {},
            quantity_patterns: {},
            technique_notes: {},
            restaurant_context: {},
            cautions: { type: "array", items: { type: "string" } },
          },
          required: [
            "matched_dish_name",
            "confidence",
            "exact_match_supported",
            "reference_urls",
            "ingredient_patterns",
            "quantity_patterns",
            "technique_notes",
            "restaurant_context",
            "cautions",
          ],
        },
      },
    },
    messages: [
      {
        role: "system",
        content: [
          "You are Ounje's grounded food web researcher.",
          "Search for restaurant, menu, and recipe evidence for the provided food query.",
          "Do not search for JSON, schema, programming, or validation libraries.",
          "Prefer exact restaurant/menu matches only if supported by a source.",
          "If no source directly confirms the restaurant/menu item, say the restaurant match is not found; do not write that the restaurant serves the dish.",
          "If exact match is unsupported, return similar recipe/menu patterns and mark exact_match_supported false.",
          "Return food citations and ingredient/quantity patterns, not a final recipe.",
        ].join("\n"),
      },
      {
        role: "user",
        content: [
          `Food search query: ${query}`,
          JSON.stringify({
            dish_hint: photoContext?.dish_hint ?? null,
            coarse_place_context: photoContext?.coarse_place_context ?? null,
            visual_analysis: visualAnalysis,
          }),
          "Return JSON with matched_dish_name, confidence, exact_match_supported, reference_urls, ingredient_patterns, quantity_patterns, technique_notes, restaurant_context, cautions.",
        ].join("\n\n"),
      },
    ],
  };
  const startedAt = Date.now();
  try {
    const response = await fetch(PERPLEXITY_API_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${PERPLEXITY_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    const responsePayload = await response.json().catch(() => null);
    await recordExternalAICall({
      provider: "perplexity",
      apiType: "chat.completions",
      service: "recipe-ingestion",
      operation: "recipe_import.photo_sonar_context",
      model: PHOTO_RECIPE_SONAR_MODEL,
      status: response.ok ? "succeeded" : "failed",
      durationMS: Date.now() - startedAt,
      inputPayload: payload,
      outputPayload: responsePayload,
      inputTokens: responsePayload?.usage?.prompt_tokens ?? responsePayload?.usage?.input_tokens ?? null,
      outputTokens: responsePayload?.usage?.completion_tokens ?? responsePayload?.usage?.output_tokens ?? null,
      totalTokens: responsePayload?.usage?.total_tokens ?? null,
      metadata: { search_query: query },
      error: response.ok ? null : new Error(responsePayload?.error?.message ?? `Perplexity returned HTTP ${response.status}`),
    }).catch(() => {});
    if (!response.ok) throw new Error(responsePayload?.error?.message ?? `Perplexity returned HTTP ${response.status}`);
    const rawContent = responsePayload?.choices?.[0]?.message?.content ?? "{}";
    const parsed = JSON.parse(rawContent.match(/\{[\s\S]*\}/)?.[0] ?? rawContent);
    return {
      matched_dish_name: normalizeText(parsed?.matched_dish_name ?? "") || null,
      confidence: Number.isFinite(Number(parsed?.confidence)) ? Number(parsed.confidence) : 0.5,
      reference_urls: Array.isArray(parsed?.reference_urls) ? parsed.reference_urls.map(cleanURL).filter(Boolean).slice(0, RECIPE_REFERENCE_MAX_SOURCES) : [],
      ingredient_patterns: uniqueStrings(Array.isArray(parsed?.ingredient_patterns) ? parsed.ingredient_patterns : []),
      quantity_patterns: uniqueStrings(Array.isArray(parsed?.quantity_patterns) ? parsed.quantity_patterns : []),
      technique_notes: uniqueStrings(Array.isArray(parsed?.technique_notes) ? parsed.technique_notes : []),
      restaurant_context: normalizeText(parsed?.restaurant_context ?? "", 700) || null,
      cautions: uniqueStrings(Array.isArray(parsed?.cautions) ? parsed.cautions : []),
      fallback: false,
    };
  } catch (error) {
    const fallback = await runPhotoFallbackWebContext(visualAnalysis, photoContext, source);
    return {
      ...fallback,
      cautions: uniqueStrings([...(fallback.cautions ?? []), `Sonar failed: ${errorSummary(error).message}`]),
    };
  }
}

async function extractPhotoRecipeSource(request) {
  const photoContext = request.photo_context ?? {};
  const imageInputs = await collectPhotoRecipeImageInputs(request.attachments);
  const primaryImage = imageInputs[0] ?? null;
  let sourceURL = cleanURL(primaryImage?.public_hero_url ?? primaryImage?.source_url ?? request.source_url ?? null);
  if (!primaryImage) {
    return {
      source_type: "media_image",
      platform: "photo",
      source_url: sourceURL,
      canonical_url: sourceURL,
      title: photoContext?.dish_hint ?? "Photo recipe",
      description: "No readable photo was attached.",
      raw_text: request.source_text ?? "",
      ingredient_candidates: [],
      instruction_candidates: [],
      hero_image_url: sourceURL,
      thumbnail_url: sourceURL,
      photo_context: photoContext,
      photo_meal_gate: { is_meal: false, confidence: 0, visible_food_components: [], likely_meal_type: null, reject_reason: "No readable photo was attached." },
      artifacts: [],
      source_provenance_json: { source_type: "media_image", photo_context: photoContext, error: "missing_photo_attachment" },
    };
  }
  const mealGate = await runPhotoMealGate(primaryImage, photoContext);

  let visualAnalysis = null;
  let heroImageURL = null;

  if (mealGate.is_meal) {
    // Run visual analysis and image upload in parallel — the upload doesn't
    // depend on analysis output; only sonar (next step) needs visualAnalysis.
    const earlyRecipeKey = photoContext?.dish_hint ?? "photo-recipe";
    [visualAnalysis, heroImageURL] = await Promise.all([
      runPhotoVisualAnalysis(primaryImage, mealGate, photoContext),
      persistPhotoRecipeHeroImage(primaryImage, {
        recipeKey: earlyRecipeKey,
        accessToken: request.access_token ?? null,
      }),
    ]);
    heroImageURL = heroImageURL ?? sourceURL ?? null;
  } else {
    heroImageURL = await persistPhotoRecipeHeroImage(primaryImage, {
      recipeKey: photoContext?.dish_hint ?? "photo-recipe",
      accessToken: request.access_token ?? null,
    }).catch(() => null) ?? sourceURL ?? null;
  }

  const sonarContext = mealGate.is_meal
    ? await runPhotoSonarContext(visualAnalysis, photoContext, {
        source_type: "media_image",
        title: photoContext?.dish_hint ?? visualAnalysis?.dish_candidates?.[0]?.name ?? "Photo dish",
        description: visualAnalysis?.plating_context ?? null,
        platform: "photo",
      })
    : null;
  const title = photoContext?.dish_hint
    ?? sonarContext?.matched_dish_name
    ?? visualAnalysis?.dish_candidates?.[0]?.name
    ?? "Photo recipe";
  sourceURL = sourceURL ?? heroImageURL;
  const rawText = [
    photoContext?.dish_hint ? `Dish hint: ${photoContext.dish_hint}` : null,
    photoContext?.coarse_place_context ? `Coarse place context: ${photoContext.coarse_place_context}` : null,
    `Meal gate: ${JSON.stringify(mealGate)}`,
    visualAnalysis ? `Visual analysis: ${JSON.stringify(visualAnalysis)}` : null,
    sonarContext ? `Grounded references: ${JSON.stringify(sonarContext)}` : null,
  ].filter(Boolean).join("\n\n");
  return {
    source_type: "media_image",
    platform: "photo",
    source_url: sourceURL,
    canonical_url: sourceURL,
    title,
    description: visualAnalysis?.plating_context ?? "Recipe inferred from a food photo.",
    meta_description: visualAnalysis?.uncertainty ?? null,
    raw_text: rawText,
    transcript_text: rawText,
    ingredient_candidates: uniqueStrings([
      ...(visualAnalysis?.visible_ingredients ?? []),
      ...(visualAnalysis?.likely_hidden_ingredients ?? []),
      ...(sonarContext?.ingredient_patterns ?? []),
    ]),
    instruction_candidates: uniqueStrings([
      ...(visualAnalysis?.cooking_methods ?? []),
      ...(sonarContext?.technique_notes ?? []),
    ]),
    hero_image_url: heroImageURL,
    thumbnail_url: heroImageURL,
    photo_context: photoContext,
    photo_image_inputs: imageInputs,
    photo_meal_gate: mealGate,
    photo_visual_analysis: visualAnalysis,
    photo_sonar_context: sonarContext,
    source_provenance_json: {
      source_type: "media_image",
      platform: "photo",
      source_url: sourceURL,
      title,
      description: visualAnalysis?.plating_context ?? null,
      photo_context: photoContext,
      photo_meal_gate: mealGate,
      photo_visual_analysis: visualAnalysis,
      photo_sonar_context: sonarContext,
      evidence_json: {
        photo_context: photoContext,
        meal_gate: mealGate,
        visual_analysis: visualAnalysis,
        sonar_context: sonarContext,
        hero_image_url: heroImageURL,
      },
    },
    artifacts: [
      { artifact_type: "photo_meal_gate", content_type: "application/json", source_url: sourceURL, raw_json: compactJSON(mealGate), metadata: { is_meal: mealGate.is_meal, confidence: mealGate.confidence } },
      ...(visualAnalysis ? [{ artifact_type: "photo_visual_analysis", content_type: "application/json", source_url: sourceURL, raw_json: compactJSON(visualAnalysis) }] : []),
      ...(sonarContext ? [{ artifact_type: "photo_sonar_context", content_type: "application/json", source_url: sourceURL, raw_json: compactJSON(sonarContext), metadata: { fallback: Boolean(sonarContext.fallback), reference_count: sonarContext.reference_urls?.length ?? 0 } }] : []),
    ],
  };
}

async function extractSourceMaterial(request) {
  const sourceType = request.source_type;
  const resolvedSourceURL = await expandCanonicalSourceURL(request.source_url, sourceType);
  if (sourceType === "youtube") return extractYouTubeSource(resolvedSourceURL);
  if (sourceType === "tiktok") return extractSocialSource(resolvedSourceURL, "tiktok");
  if (sourceType === "instagram") return extractSocialSource(resolvedSourceURL, "instagram");
  if (sourceType === "web") return extractWebSource(resolvedSourceURL);
  if (sourceType === "media_image") return extractPhotoRecipeSource(request);
  return extractTextSource(request.source_text, request.attachments);
}

async function extractRecipeWithModel(source) {
  if (!openai) {
    return {
      recipe: {
        title: source.title ?? null,
        description: source.description ?? source.meta_description ?? null,
        author_name: source.author_name ?? null,
        author_handle: source.author_handle ?? null,
        source: source.site_name ?? source.platform ?? null,
        source_platform: source.platform ?? null,
        hero_image_url: source.hero_image_url ?? source.thumbnail_url ?? null,
        discover_card_image_url: source.hero_image_url ?? source.thumbnail_url ?? null,
        recipe_url: source.source_url ?? null,
        original_recipe_url: source.canonical_url ?? source.source_url ?? null,
        attached_video_url: source.attached_video_url ?? null,
        ingredients: buildFallbackIngredientLines(source).map((line) => ({ display_name: line, quantity_text: null })),
        steps: buildFallbackInstructionLines(source).map((line) => ({ text: line })),
      },
      quality_flags: ["openai_unavailable"],
      review_reason: "Structured extraction model was unavailable, so this import needs review.",
    };
  }

  const content = [
    {
      type: "text",
      text: [
        "Extract a recipe from this source material.",
        "If the source does not provide nutrition but the dish, servings, and ingredient quantities are clear enough, return conservative best-guess per-serving calories_kcal, protein_g, carbs_g, and fat_g. These are rough display estimates for the app.",
        "",
        `source_type: ${source.source_type}`,
        `platform: ${source.platform ?? ""}`,
        `source_url: ${source.source_url ?? ""}`,
        `canonical_url: ${source.canonical_url ?? ""}`,
        `title_hint: ${source.title ?? ""}`,
        `author_hint: ${source.author_name ?? ""}`,
        `description_hint: ${source.description ?? source.meta_description ?? ""}`,
        "",
        "Structured recipe candidate from source (may be partial):",
        JSON.stringify(source.structured_recipe ?? null),
        "",
        "Ingredient candidates:",
        JSON.stringify(source.ingredient_candidates ?? []),
        "",
        "Instruction candidates:",
        JSON.stringify(source.instruction_candidates ?? []),
        "",
        "Raw text:",
        limitText(source.raw_text ?? source.body_text ?? "", 20_000),
        "",
        "Frame OCR excerpt (only high-confidence or recipe-like text):",
        limitText(summarizeFrameOCRTexts(source.frame_ocr_texts ?? [], { maxFrames: 4, textLimit: 700 }), 3_000),
        "",
        "Return a JSON object with this shape:",
        JSON.stringify({
          recipe: {
            title: "string|null",
            description: "string|null",
            author_name: "string|null",
            author_handle: "string|null",
            author_url: "string|null",
            source: "string|null",
            source_platform: "string|null",
            category: "string|null",
            subcategory: "string|null",
            recipe_type: "string|null",
            skill_level: "string|null",
            cook_time_text: "string|null",
            servings_text: "string|null",
            serving_size_text: "string|null",
            est_calories_text: "string|null",
            calories_kcal: "number|null",
            protein_g: "number|null",
            carbs_g: "number|null",
            fat_g: "number|null",
            prep_time_minutes: "integer|null",
            cook_time_minutes: "integer|null",
            hero_image_url: "string|null",
            discover_card_image_url: "string|null",
            recipe_url: "string|null",
            original_recipe_url: "string|null",
            attached_video_url: "string|null",
            detail_footnote: "string|null",
            image_caption: "string|null",
            dietary_tags: ["string"],
            flavor_tags: ["string"],
            cuisine_tags: ["string"],
            occasion_tags: ["string"],
            main_protein: "string|null",
            cook_method: "string|null",
            ingredients: [{ display_name: "string", quantity_text: "string|null", image_url: "string|null" }],
            steps: [{ number: "integer|null", text: "string", tip_text: "string|null", ingredients: [{ display_name: "string", quantity_text: "string|null" }] }]
          },
          quality_flags: ["string"],
          review_reason: "string|null"
        }),
      ].join("\n"),
    },
  ];

  content.push(...collectRecipeEvidenceImageInputs(source, { maxCount: 4 }));

  const response = await withRecipeAIStage("recipe_import.extract", () => openai.chat.completions.create({
    model: RECIPE_INGESTION_MODEL,
    ...chatCompletionTemperatureParams(RECIPE_INGESTION_MODEL, 0.1),
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: RECIPE_EXTRACTION_SYSTEM_PROMPT,
      },
      {
        role: "user",
        content,
      },
    ],
  }));

  const rawContent = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(rawContent);
  return {
    ...parsed,
    recipe: parsed.recipe ?? parsed,
  };
}

async function synthesizeRecipeFromPrompt(source) {
  if (!openai) {
    return {
      recipe: buildGroundedConceptFallbackRecipe(source),
      quality_flags: ["openai_unavailable", "concept_prompt_fallback"],
      review_reason: "Model unavailable; generated a draft recipe from your concept prompt.",
    };
  }

  for (const attempt of [1, 2, 3]) {
    const response = await withRecipeAIStage("recipe_import.concept_synthesis", () => openai.chat.completions.create({
      model: RECIPE_INGESTION_MODEL,
      ...chatCompletionTemperatureParams(RECIPE_INGESTION_MODEL, attempt === 1 ? 0.3 : attempt === 2 ? 0.18 : 0.1),
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content: RECIPE_CONCEPT_SYSTEM_PROMPT,
        },
        {
          role: "user",
          content: [
            "Create a realistic recipe from this user prompt.",
            "",
            `prompt: ${limitText(source.raw_text ?? "")}`,
            "",
            "Creation intent:",
            JSON.stringify(source.creation_intent ?? null),
            "",
            "Flavor hints:",
            JSON.stringify(source.flavor_seed_terms ?? []),
            "",
            "Web recipe references:",
            JSON.stringify((source.recipe_sources ?? []).slice(0, 6).map((entry) => ({
              title: entry.title ?? null,
              site_name: entry.site_name ?? null,
              source_url: entry.canonical_url ?? entry.source_url ?? null,
              ingredient_candidates: (entry.ingredient_candidates ?? []).slice(0, 24),
              instruction_candidates: (entry.instruction_candidates ?? []).slice(0, 18),
              structured_recipe: entry.structured_recipe
                ? {
                    name: entry.structured_recipe.name ?? null,
                    recipeCategory: entry.structured_recipe.recipeCategory ?? null,
                    recipeCuisine: entry.structured_recipe.recipeCuisine ?? null,
                    recipeYield: entry.structured_recipe.recipeYield ?? null,
                    recipeIngredient: (entry.structured_recipe.recipeIngredient ?? []).slice(0, 24),
                    recipeInstructions: (entry.structured_recipe.recipeInstructions ?? []).slice(0, 18),
                  }
                : null,
            }))),
            "",
            "Nearby embedding examples (use these as grounding references for structure, ingredient realism, and technique):",
            JSON.stringify(buildPromptExamplesContext(source.prompt_examples ?? [])),
            "",
            "Style examples:",
            JSON.stringify(source.style_examples ?? []),
            "",
            "Output requirements:",
            "- include at least 5 ingredients",
            "- include at least 4 numbered steps",
            "- each ingredient must be a real ingredient name (never repeat the raw prompt as an ingredient)",
            "- at least 3 ingredients must have concrete quantity_text (not null, not 'to taste')",
            "- steps must include concrete cooking actions (prep, combine, cook, finish) and ingredient references",
            "- keep quantities practical and concise",
            "- estimate per-serving calories_kcal, protein_g, carbs_g, and fat_g when ingredients and servings are specific enough",
            "- if creation_intent.intent is fusion_recipe, create one viable chef-tested style recipe that combines the requested dishes or techniques coherently; use web references for base ratios and methods, not as text to copy",
            "- if creation_intent.intent is custom_recipe, satisfy the user's constraints while keeping the dish cookable and ordinary enough for home cooking",
            "- do not output generic placeholder steps",
            "",
            "Return a JSON object with the same shape used for structured recipe extraction.",
          ].join("\n"),
        },
      ],
    }));

    const rawContent = response.choices?.[0]?.message?.content ?? "{}";
    const parsed = JSON.parse(rawContent);
    const recipeCandidate = parsed.recipe ?? parsed;
    if (hasUsableRecipeCore(recipeCandidate) && !looksGenericConceptRecipe(recipeCandidate, source.raw_text ?? "")) {
      return {
        ...parsed,
        recipe: recipeCandidate,
      };
    }
  }

  return {
    recipe: buildGroundedConceptFallbackRecipe(source),
    quality_flags: ["concept_prompt_fallback"],
    review_reason: "Concept prompt needed a grounded fallback draft from nearby recipe references.",
  };
}

async function synthesizeRecipeFromRecipeSearch(source) {
  if (!openai) {
    return {
      recipe: buildGroundedConceptFallbackRecipe({
        raw_text: source.raw_text ?? source.title ?? "Imported recipe",
        prompt_examples: [],
        flavor_seed_terms: extractIngredientSignals(source.raw_text ?? source.title ?? ""),
      }),
      quality_flags: ["openai_unavailable", "recipe_search_fallback"],
      review_reason: "Recipe search synthesis model was unavailable.",
    };
  }

  const recipeSources = Array.isArray(source.recipe_sources) ? source.recipe_sources.slice(0, 8) : [];
  const response = await withRecipeAIStage("recipe_import.recipe_search_synthesis", () => openai.chat.completions.create({
    model: RECIPE_SEARCH_SYNTHESIS_MODEL,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: RECIPE_SEARCH_SYSTEM_PROMPT },
      {
        role: "user",
        content: [
          `meal_query: ${normalizeText(source.raw_text ?? source.title ?? "")}`,
          "",
          "Scraped recipe sources:",
          JSON.stringify(recipeSources.map((entry) => ({
            title: entry.title ?? null,
            site_name: entry.site_name ?? null,
            source_url: entry.canonical_url ?? entry.source_url ?? null,
            ingredient_candidates: (entry.ingredient_candidates ?? []).slice(0, 30),
            instruction_candidates: (entry.instruction_candidates ?? []).slice(0, 24),
            structured_recipe: entry.structured_recipe
              ? {
                  name: entry.structured_recipe.name ?? null,
                  recipeCategory: entry.structured_recipe.recipeCategory ?? null,
                  recipeCuisine: entry.structured_recipe.recipeCuisine ?? null,
                  recipeYield: entry.structured_recipe.recipeYield ?? null,
                  recipeIngredient: (entry.structured_recipe.recipeIngredient ?? []).slice(0, 30),
                  recipeInstructions: (entry.structured_recipe.recipeInstructions ?? []).slice(0, 20),
                }
              : null,
          }))),
          "",
          "Nutrition requirement:",
          "Always provide conservative per-serving calories_kcal, protein_g, carbs_g, fat_g, and est_calories_text for app display. Use cited source nutrition when present; otherwise infer from the synthesized ingredients and servings.",
          "",
          "Return a JSON object with:",
          JSON.stringify({
            recipe: {
              title: "string|null",
              description: "string|null",
              recipe_type: "string|null",
              cuisine_tags: ["string"],
              dietary_tags: ["string"],
              cook_time_text: "string|null",
              prep_time_minutes: "number|null",
              cook_time_minutes: "number|null",
              est_calories_text: "string|null",
              calories_kcal: "number|null",
              protein_g: "number|null",
              carbs_g: "number|null",
              fat_g: "number|null",
              hero_image_url: "string|null",
              discover_card_image_url: "string|null",
              ingredients: [{ display_name: "string", quantity_text: "string|null", image_url: "string|null" }],
              steps: [{ number: "integer|null", text: "string", tip_text: "string|null", ingredients: [{ display_name: "string", quantity_text: "string|null" }] }],
            },
            quality_flags: ["string"],
            review_reason: "string|null",
          }),
        ].join("\n"),
      },
    ],
  }));

  const rawContent = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(rawContent);
  return {
    ...parsed,
    recipe: parsed.recipe ?? parsed,
  };
}

async function verifyRecipeSearchSynthesis(normalizedRecipe, source) {
  if (!openai || source.source_type !== "recipe_search") {
    return {
      recipe: normalizedRecipe,
      quality_flags: [],
      review_reason: null,
    };
  }

  const recipeSources = Array.isArray(source.recipe_sources) ? source.recipe_sources.slice(0, 8) : [];
  const response = await withRecipeAIStage("recipe_import.recipe_search_verify", () => openai.chat.completions.create({
    model: RECIPE_SEARCH_SYNTHESIS_MODEL,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: RECIPE_SEARCH_VERIFY_SYSTEM_PROMPT },
      {
        role: "user",
        content: [
          "Verify this synthesized recipe against the scraped recipe evidence.",
          "",
          "Current recipe:",
          JSON.stringify(normalizedRecipe),
          "",
          "Recipe sources:",
          JSON.stringify(recipeSources.map((entry) => ({
            title: entry.title ?? null,
            site_name: entry.site_name ?? null,
            source_url: entry.canonical_url ?? entry.source_url ?? null,
            ingredient_candidates: (entry.ingredient_candidates ?? []).slice(0, 24),
            instruction_candidates: (entry.instruction_candidates ?? []).slice(0, 18),
            structured_recipe: entry.structured_recipe
              ? {
                  recipeIngredient: (entry.structured_recipe.recipeIngredient ?? []).slice(0, 24),
                  recipeInstructions: (entry.structured_recipe.recipeInstructions ?? []).slice(0, 18),
                }
              : null,
          }))),
          "",
          "Return JSON like:",
          JSON.stringify({
            recipe: normalizedRecipe,
            quality_flags: ["string"],
            review_reason: "string|null",
          }),
        ].join("\n"),
      },
    ],
  }));

  const rawContent = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(rawContent);
  return {
    recipe: parsed.recipe ?? normalizedRecipe,
    quality_flags: Array.isArray(parsed.quality_flags) ? parsed.quality_flags : [],
    review_reason: normalizeText(parsed.review_reason ?? "") || null,
  };
}

function mergeLowRiskRecipeFill(baseRecipe, fillRecipe) {
  if (!fillRecipe || typeof fillRecipe !== "object") return baseRecipe;

  const normalizedServingsText = normalizeText(fillRecipe.servings_text) || null;
  const normalizedCookTimeText = normalizeText(fillRecipe.cook_time_text) || null;
  const normalizedSkillLevel = normalizeText(fillRecipe.skill_level) || null;
  const normalizedCaloriesText = normalizeText(fillRecipe.est_calories_text) || null;

  const mergedIngredients = (baseRecipe.ingredients ?? []).map((ingredient) => {
    const currentQuantity = normalizeText(ingredient.quantity_text);
    if (currentQuantity) return ingredient;

    const match = (fillRecipe.ingredients ?? []).find((candidate) => (
      ingredientNameMatches(candidate?.display_name, ingredient.display_name)
        && normalizeText(candidate?.quantity_text)
    ));

    return match
      ? { ...ingredient, quantity_text: normalizeText(match.quantity_text) || null }
      : ingredient;
  });

  return {
    ...baseRecipe,
    servings_text: baseRecipe.servings_text ?? normalizedServingsText,
    servings_count: baseRecipe.servings_count ?? (Number.isFinite(fillRecipe.servings_count) ? Number(fillRecipe.servings_count) : null),
    prep_time_minutes: baseRecipe.prep_time_minutes ?? (Number.isFinite(fillRecipe.prep_time_minutes) ? Number(fillRecipe.prep_time_minutes) : null),
    cook_time_minutes: baseRecipe.cook_time_minutes ?? (Number.isFinite(fillRecipe.cook_time_minutes) ? Number(fillRecipe.cook_time_minutes) : null),
    cook_time_text: baseRecipe.cook_time_text ?? normalizedCookTimeText,
    skill_level: baseRecipe.skill_level ?? normalizedSkillLevel,
    est_calories_text: baseRecipe.est_calories_text ?? normalizedCaloriesText,
    calories_kcal: baseRecipe.calories_kcal ?? finiteNumberOrNull(fillRecipe.calories_kcal),
    protein_g: baseRecipe.protein_g ?? finiteNumberOrNull(fillRecipe.protein_g),
    carbs_g: baseRecipe.carbs_g ?? finiteNumberOrNull(fillRecipe.carbs_g),
    fat_g: baseRecipe.fat_g ?? finiteNumberOrNull(fillRecipe.fat_g),
    ingredients: mergedIngredients,
  };
}

function hasUsableRecipeCore(recipe) {
  if (!recipe || typeof recipe !== "object") return false;
  const ingredientCount = Array.isArray(recipe.ingredients)
    ? recipe.ingredients.filter((item) => normalizeText(item?.display_name ?? item?.name ?? item)).length
    : 0;
  const stepCount = Array.isArray(recipe.steps)
    ? recipe.steps.filter((item) => normalizeText(item?.text ?? item)).length
    : 0;
  const quantifiedIngredientCount = Array.isArray(recipe.ingredients)
    ? recipe.ingredients.filter((item) => {
        const qty = normalizeText(item?.quantity_text ?? item?.quantity ?? "");
        return qty && qty.toLowerCase() !== "to taste";
      }).length
    : 0;
  return ingredientCount >= 4 && stepCount >= 3 && quantifiedIngredientCount >= 2;
}

function recipeCoreMetrics(recipe) {
  const ingredients = Array.isArray(recipe?.ingredients) ? recipe.ingredients : [];
  const steps = Array.isArray(recipe?.steps) ? recipe.steps : [];
  const ingredientCount = ingredients.filter((item) => normalizeText(item?.display_name ?? item?.name ?? item)).length;
  const stepCount = steps.filter((item) => normalizeText(item?.text ?? item)).length;
  const quantifiedIngredientCount = ingredients.filter((item) => {
    const qty = normalizeText(item?.quantity_text ?? item?.quantity ?? "");
    return qty && qty.toLowerCase() !== "to taste";
  }).length;
  const missingIngredientQuantities = ingredients.filter((item) => !normalizeText(item?.quantity_text ?? item?.quantity ?? "")).length;

  return {
    ingredientCount,
    stepCount,
    quantifiedIngredientCount,
    missingIngredientQuantities,
    needsRepair:
      ingredientCount < 4
      || stepCount < 3
      || quantifiedIngredientCount < 2
      || (ingredientCount > 0 && missingIngredientQuantities > Math.ceil(ingredientCount * 0.6)),
  };
}

function recipeNeedsCompletionPass(recipe) {
  const metrics = recipeCoreMetrics(recipe);
  const sparseQuantities = metrics.ingredientCount >= 3
    && metrics.missingIngredientQuantities >= Math.ceil(metrics.ingredientCount * 0.5);
  return metrics.needsRepair
    || sparseQuantities
    || !normalizeText(recipe?.servings_text)
    || !Number.isFinite(recipe?.servings_count)
    || !normalizeText(recipe?.cook_time_text)
    || !Number.isFinite(recipe?.cook_time_minutes)
    || !Number.isFinite(recipe?.prep_time_minutes)
    || !normalizeText(recipe?.est_calories_text)
    || !Number.isFinite(recipe?.calories_kcal)
    || !Number.isFinite(recipe?.protein_g)
    || !Number.isFinite(recipe?.carbs_g)
    || !Number.isFinite(recipe?.fat_g);
}

function buildRecipeCompletionQuery(recipe, source) {
  const title = normalizeText(recipe?.title ?? source?.title ?? "");
  if (title) return title;

  const raw = normalizeText(source?.raw_text ?? source?.description ?? source?.meta_description ?? "");
  if (!raw) return "";

  return raw
    .split(/[.!?\n]/)
    .map((part) => normalizeText(part))
    .find(Boolean)
    ?? raw.slice(0, 120);
}

function ingredientQuantityCompletionChanges(beforeRecipe, afterRecipe) {
  const beforeIngredients = Array.isArray(beforeRecipe?.ingredients) ? beforeRecipe.ingredients : [];
  const afterIngredients = Array.isArray(afterRecipe?.ingredients) ? afterRecipe.ingredients : [];
  const changes = [];

  for (const before of beforeIngredients) {
    const beforeName = normalizeText(before?.display_name ?? before?.name ?? "");
    if (!beforeName || normalizeText(before?.quantity_text ?? before?.quantity ?? "")) continue;
    const match = afterIngredients.find((candidate) => (
      ingredientNameMatches(candidate?.display_name ?? candidate?.name, beforeName)
        && normalizeText(candidate?.quantity_text ?? candidate?.quantity ?? "")
    ));
    if (!match) continue;
    changes.push({
      display_name: beforeName,
      quantity_text: normalizeText(match.quantity_text ?? match.quantity ?? "") || null,
    });
  }

  return changes;
}

function recipeReferenceSummaryForArtifact(recipeSources) {
  return (recipeSources ?? []).map((entry) => ({
    title: entry.title ?? null,
    site_name: entry.site_name ?? null,
    source_url: entry.canonical_url ?? entry.source_url ?? null,
  })).filter((entry) => entry.title || entry.source_url);
}

async function storeWebCompletionLookupArtifact(jobID, {
  completionQuery,
  source,
  lookupSource = null,
  recipeSources = [],
  error = null,
  status = "ok",
} = {}) {
  if (!jobID) return;
  await storeArtifact(jobID, {
    artifact_type: "web_completion_lookup",
    content_type: "application/json",
    source_url: source?.canonical_url ?? source?.source_url ?? null,
    raw_json: compactJSON({
      status,
      completion_query: completionQuery,
      search_query: lookupSource?.source_provenance_json?.evidence_bundle?.query ?? completionQuery,
      reference_count: recipeSources.length,
      references: recipeReferenceSummaryForArtifact(recipeSources),
      search: lookupSource?.source_provenance_json?.evidence_bundle
        ? {
            source_count: lookupSource.source_provenance_json.evidence_bundle.source_count ?? null,
            search_method: lookupSource.source_provenance_json.evidence_bundle.search_method ?? null,
            ai_link_count: lookupSource.source_provenance_json.evidence_bundle.ai_link_count ?? null,
            browser_link_count: lookupSource.source_provenance_json.evidence_bundle.browser_link_count ?? null,
            ai_search_error: lookupSource.source_provenance_json.evidence_bundle.ai_search_error ?? null,
            search_error: lookupSource.source_provenance_json.evidence_bundle.search_error ?? null,
            scrape_error_count: lookupSource.source_provenance_json.evidence_bundle.scrape_error_count ?? null,
            scrape_errors: lookupSource.source_provenance_json.evidence_bundle.scrape_errors ?? [],
          }
        : null,
      error: errorSummary(error),
    }),
    metadata: {
      status,
      reference_count: recipeSources.length,
      has_error: Boolean(error),
    },
  }).catch(() => {});
}

function mergeCompletedRecipe(baseRecipe, completedRecipe) {
  if (!completedRecipe || typeof completedRecipe !== "object") return baseRecipe;

  const baseMetrics = recipeCoreMetrics(baseRecipe);
  const completedMetrics = recipeCoreMetrics(completedRecipe);
  const shouldAdoptCompletedStructure =
    completedMetrics.ingredientCount >= baseMetrics.ingredientCount
    && completedMetrics.stepCount >= baseMetrics.stepCount
    && completedMetrics.quantifiedIngredientCount >= baseMetrics.quantifiedIngredientCount
    && (
      baseMetrics.needsRepair
      || completedMetrics.missingIngredientQuantities < baseMetrics.missingIngredientQuantities
      || !hasUsableRecipeCore(baseRecipe)
    );

  const lowRiskMerged = mergeLowRiskRecipeFill(baseRecipe, completedRecipe);
  const completedDescription = normalizeText(completedRecipe.description) || null;
  const completedCategory = normalizeText(completedRecipe.category) || null;
  const completedRecipeType = normalizeText(completedRecipe.recipe_type) || null;
  const completedSkillLevel = normalizeText(completedRecipe.skill_level) || null;
  const completedCaloriesText = normalizeText(completedRecipe.est_calories_text) || null;
  const completedMainProtein = normalizeText(completedRecipe.main_protein) || null;
  const completedCookMethod = normalizeText(completedRecipe.cook_method) || null;

  return {
    ...lowRiskMerged,
    description: baseRecipe.description ?? completedDescription,
    category: baseRecipe.category ?? completedCategory,
    recipe_type: baseRecipe.recipe_type ?? completedRecipeType,
    skill_level: lowRiskMerged.skill_level ?? completedSkillLevel,
    servings_text: lowRiskMerged.servings_text ?? (normalizeText(completedRecipe.servings_text) || null),
    servings_count: lowRiskMerged.servings_count ?? (Number.isFinite(completedRecipe.servings_count) ? Number(completedRecipe.servings_count) : null),
    prep_time_minutes: lowRiskMerged.prep_time_minutes ?? (Number.isFinite(completedRecipe.prep_time_minutes) ? Number(completedRecipe.prep_time_minutes) : null),
    cook_time_minutes: lowRiskMerged.cook_time_minutes ?? (Number.isFinite(completedRecipe.cook_time_minutes) ? Number(completedRecipe.cook_time_minutes) : null),
    cook_time_text: lowRiskMerged.cook_time_text ?? (normalizeText(completedRecipe.cook_time_text) || null),
    est_calories_text: lowRiskMerged.est_calories_text ?? completedCaloriesText,
    calories_kcal: lowRiskMerged.calories_kcal ?? finiteNumberOrNull(completedRecipe.calories_kcal),
    protein_g: lowRiskMerged.protein_g ?? finiteNumberOrNull(completedRecipe.protein_g),
    carbs_g: lowRiskMerged.carbs_g ?? finiteNumberOrNull(completedRecipe.carbs_g),
    fat_g: lowRiskMerged.fat_g ?? finiteNumberOrNull(completedRecipe.fat_g),
    main_protein: baseRecipe.main_protein ?? completedMainProtein,
    cook_method: baseRecipe.cook_method ?? completedCookMethod,
    cuisine_tags: uniqueStrings([...(baseRecipe.cuisine_tags ?? []), ...(completedRecipe.cuisine_tags ?? [])]).slice(0, 8),
    dietary_tags: uniqueStrings([...(baseRecipe.dietary_tags ?? []), ...(completedRecipe.dietary_tags ?? [])]).slice(0, 8),
    flavor_tags: uniqueStrings([...(baseRecipe.flavor_tags ?? []), ...(completedRecipe.flavor_tags ?? [])]).slice(0, 10),
    occasion_tags: uniqueStrings([...(baseRecipe.occasion_tags ?? []), ...(completedRecipe.occasion_tags ?? [])]).slice(0, 8),
    ingredients: shouldAdoptCompletedStructure && Array.isArray(completedRecipe.ingredients) && completedRecipe.ingredients.length
      ? completedRecipe.ingredients
      : lowRiskMerged.ingredients,
    steps: shouldAdoptCompletedStructure && Array.isArray(completedRecipe.steps) && completedRecipe.steps.length
      ? completedRecipe.steps
      : baseRecipe.steps,
    hero_image_url: baseRecipe.hero_image_url ?? cleanURL(completedRecipe.hero_image_url ?? null),
    discover_card_image_url: baseRecipe.discover_card_image_url ?? cleanURL(completedRecipe.discover_card_image_url ?? null),
  };
}

async function completeImportedRecipeWithWebEvidence(normalizedRecipe, source, { jobID = null } = {}) {
  if (!openai || source?.source_type === "recipe_search") {
    return {
      recipe: normalizedRecipe,
      quality_flags: [],
      review_reason: null,
      applied: false,
    };
  }

  const completionQuery = buildRecipeCompletionQuery(normalizedRecipe, source);
  if (!completionQuery) {
    return {
      recipe: normalizedRecipe,
      quality_flags: [],
      review_reason: null,
      applied: false,
    };
  }

  let lookupSource = null;
  try {
    lookupSource = await extractRecipeSearchSource(completionQuery, [], { source, jobID });
  } catch (error) {
    await storeWebCompletionLookupArtifact(jobID, {
      completionQuery,
      source,
      error,
      status: "failed",
    });
    return {
      recipe: normalizedRecipe,
      quality_flags: ["web_completion_lookup_failed"],
      review_reason: "Web reference lookup failed before quantity completion.",
      applied: false,
    };
  }

  const recipeSources = Array.isArray(lookupSource?.recipe_sources)
    ? lookupSource.recipe_sources.slice(0, RECIPE_REFERENCE_MAX_SOURCES)
    : [];
  await storeWebCompletionLookupArtifact(jobID, {
    completionQuery,
    source,
    lookupSource,
    recipeSources,
    status: recipeSources.length ? "ok" : "empty",
  });
  if (!recipeSources.length) {
    return {
      recipe: normalizedRecipe,
      quality_flags: ["web_completion_no_references"],
      review_reason: "No usable web recipe references were found for quantity completion.",
      applied: false,
    };
  }

  const response = await timeRecipeImportStage(
    "web_completion",
    { jobID, metadata: { reference_count: recipeSources.length } },
    () => withRecipeAIStage("recipe_import.web_completion", () => openai.chat.completions.create({
      model: RECIPE_IMPORT_COMPLETION_MODEL,
      ...chatCompletionTemperatureParams(RECIPE_IMPORT_COMPLETION_MODEL, 0.08),
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: RECIPE_IMPORT_COMPLETION_SYSTEM_PROMPT },
        {
          role: "user",
          content: [
            `completion_query: ${completionQuery}`,
            "",
            "Current imported recipe:",
            JSON.stringify(normalizedRecipe),
            "",
            "Original source evidence:",
            JSON.stringify({
              source_type: source.source_type ?? null,
              platform: source.platform ?? null,
              title: source.title ?? null,
              description: source.description ?? source.meta_description ?? null,
              transcript_text: source.transcript_text ?? null,
              raw_text: source.raw_text ?? null,
              ingredient_candidates: source.ingredient_candidates ?? [],
              instruction_candidates: source.instruction_candidates ?? [],
              structured_recipe: source.structured_recipe ?? null,
            }),
            "",
            "Web recipe references:",
            JSON.stringify(recipeSources.map((entry) => ({
              title: entry.title ?? null,
              site_name: entry.site_name ?? null,
              source_url: entry.canonical_url ?? entry.source_url ?? null,
              hero_image_url: entry.hero_image_url ?? null,
              ingredient_candidates: (entry.ingredient_candidates ?? []).slice(0, 30),
              instruction_candidates: (entry.instruction_candidates ?? []).slice(0, 20),
              structured_recipe: entry.structured_recipe
                ? {
                    name: entry.structured_recipe.name ?? null,
                    recipeCategory: entry.structured_recipe.recipeCategory ?? null,
                    recipeCuisine: entry.structured_recipe.recipeCuisine ?? null,
                    recipeYield: entry.structured_recipe.recipeYield ?? null,
                    recipeIngredient: (entry.structured_recipe.recipeIngredient ?? []).slice(0, 30),
                    recipeInstructions: (entry.structured_recipe.recipeInstructions ?? []).slice(0, 20),
                  }
                : null,
            }))),
            "",
            "Return JSON like:",
            JSON.stringify({
              recipe: {
                title: "string|null",
                description: "string|null",
                category: "string|null",
                recipe_type: "string|null",
                skill_level: "string|null",
                cook_time_text: "string|null",
                servings_text: "string|null",
                est_calories_text: "string|null",
                calories_kcal: "number|null",
                protein_g: "number|null",
                carbs_g: "number|null",
                fat_g: "number|null",
                prep_time_minutes: "number|null",
                cook_time_minutes: "number|null",
                main_protein: "string|null",
                cook_method: "string|null",
                cuisine_tags: ["string"],
                dietary_tags: ["string"],
                flavor_tags: ["string"],
                occasion_tags: ["string"],
                hero_image_url: "string|null",
                discover_card_image_url: "string|null",
                ingredients: [{ display_name: "string", quantity_text: "string|null", image_url: "string|null" }],
                steps: [{ number: "integer|null", text: "string", tip_text: "string|null", ingredients: [{ display_name: "string", quantity_text: "string|null" }] }],
              },
              quality_flags: ["string"],
              review_reason: "string|null",
            }),
          ].join("\n"),
        },
      ],
    }))
  );

  const rawContent = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(rawContent);
  const completedRecipe = coerceStructuredRecipeCandidate(parsed.recipe ?? parsed, source);
  const mergedRecipe = mergeCompletedRecipe(normalizedRecipe, completedRecipe);
  const filledQuantities = ingredientQuantityCompletionChanges(normalizedRecipe, mergedRecipe);
  const qualityFlags = uniqueStrings([
    ...(Array.isArray(parsed.quality_flags) ? parsed.quality_flags : []),
    ...(filledQuantities.length ? ["quantities_inferred"] : []),
    ...(JSON.stringify(mergedRecipe) !== JSON.stringify(normalizedRecipe) ? ["web_completion_applied"] : []),
  ]);
  if (jobID) {
    await storeArtifact(jobID, {
      artifact_type: "quantity_completion",
      content_type: "application/json",
      source_url: source.canonical_url ?? source.source_url ?? null,
      raw_json: compactJSON({
        completion_query: completionQuery,
        filled_quantities: filledQuantities,
        reference_sources: recipeReferenceSummaryForArtifact(recipeSources),
        quality_flags: qualityFlags,
        review_reason: normalizeText(parsed.review_reason ?? "") || null,
      }),
      metadata: {
        model: RECIPE_IMPORT_COMPLETION_MODEL,
        filled_quantity_count: filledQuantities.length,
        reference_count: recipeSources.length,
      },
    }).catch(() => {});
  }

  return {
    recipe: mergedRecipe,
    quality_flags: qualityFlags,
    review_reason: normalizeText(parsed.review_reason ?? "") || null,
    applied: JSON.stringify(mergedRecipe) !== JSON.stringify(normalizedRecipe),
  };
}

function buildConceptFallbackRecipe(source) {
  const promptText = normalizeText(source.raw_text ?? "") || "Custom recipe idea";
  const seedTerms = uniqueStrings([
    ...(Array.isArray(source.flavor_seed_terms) ? source.flavor_seed_terms : []),
    ...extractIngredientSignals(promptText),
  ]).slice(0, 8);

  const ingredientNames = uniqueStrings([
    ...seedTerms,
    "Sea salt",
    "Olive oil",
  ]).slice(0, 7);

  const ingredients = ingredientNames.map((name, index) => ({
    display_name: name,
    quantity_text: index < 3 ? "1 cup" : "to taste",
  }));

  const steps = [
    {
      number: 1,
      text: `Prep your core ingredients for ${promptText}.`,
    },
    {
      number: 2,
      text: "Combine and season in stages, tasting as you go.",
    },
    {
      number: 3,
      text: "Cook or assemble until the texture and flavor balance feels right, then plate and serve.",
    },
  ];

  return {
    title: promptText
      .split(/\s+/)
      .slice(0, 8)
      .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
      .join(" "),
    description: `Generated from your idea prompt: ${promptText}.`,
    source: "ounje",
    source_platform: "direct_input",
    category: "custom",
    recipe_type: "custom",
    cook_time_text: "30 mins",
    cook_time_minutes: 30,
    servings_text: "Serves 4",
    servings_count: 4,
    ingredients,
    steps,
    flavor_tags: seedTerms.slice(0, 6),
    cuisine_tags: [],
    dietary_tags: [],
    occasion_tags: ["idea-generated"],
  };
}

function buildPromptExamplesContext(examples = []) {
  return examples.slice(0, 5).map((example) => ({
    id: example.id ?? null,
    title: example.title ?? null,
    recipe_type: example.recipe_type ?? null,
    cuisine_tags: Array.isArray(example.cuisine_tags) ? example.cuisine_tags : [],
    cook_time_text: example.cook_time_text ?? null,
    ingredients: splitLines(example.ingredients_text).slice(0, 10),
    steps: splitLines(example.instructions_text).slice(0, 8),
  }));
}

function splitLines(value) {
  const normalized = normalizeText(value);
  if (!normalized) return [];
  return normalized
    .split(/\n+/)
    .map((line) => normalizeText(line))
    .filter(Boolean);
}

function parseIngredientLine(line) {
  const normalized = normalizeText(line);
  if (!normalized) return null;
  const parsed = parseIngredientObjects(normalized)[0];
  if (parsed?.name) {
    const quantityParts = [
      parsed.quantity != null ? String(parsed.quantity) : null,
      normalizeText(parsed.unit),
    ].filter(Boolean);
    return {
      display_name: parsed.name,
      quantity_text: quantityParts.length ? quantityParts.join(" ") : null,
    };
  }
  const cleaned = normalized.replace(/^[-*•\d\.\)\s]+/, "").trim();
  if (!cleaned) return null;
  return {
    display_name: cleaned,
    quantity_text: null,
  };
}

function looksGenericConceptRecipe(recipe, rawPrompt) {
  const promptKey = normalizeKey(rawPrompt ?? "");
  const ingredients = Array.isArray(recipe?.ingredients) ? recipe.ingredients : [];
  const steps = Array.isArray(recipe?.steps) ? recipe.steps : [];

  const genericStepPatterns = [
    "combine and season in stages",
    "texture and flavor balance",
    "tasting as you go",
    "until it feels right",
    "prep your core ingredients",
  ];

  const hasGenericStep = steps.some((step) => {
    const text = normalizeText(step?.text ?? step ?? "").toLowerCase();
    if (!text) return true;
    return genericStepPatterns.some((pattern) => text.includes(pattern));
  });

  const hasPromptAsIngredient = ingredients.some((ingredient) => {
    const name = normalizeKey(ingredient?.display_name ?? ingredient?.name ?? ingredient ?? "");
    return Boolean(name) && Boolean(promptKey) && (name === promptKey || name.includes(promptKey));
  });

  const concreteIngredientCount = ingredients.filter((ingredient) => {
    const name = normalizeText(ingredient?.display_name ?? ingredient?.name ?? ingredient ?? "");
    const qty = normalizeText(ingredient?.quantity_text ?? ingredient?.quantity ?? "");
    return Boolean(name) && Boolean(qty) && qty.toLowerCase() !== "to taste";
  }).length;

  return hasGenericStep || hasPromptAsIngredient || concreteIngredientCount < 2;
}

function buildGroundedConceptFallbackRecipe(source) {
  const promptText = normalizeText(source.raw_text ?? "") || "Custom recipe idea";
  const primaryExample = Array.isArray(source.prompt_examples) ? source.prompt_examples[0] : null;

  if (!primaryExample) {
    return buildConceptFallbackRecipe(source);
  }

  const exampleIngredients = splitLines(primaryExample.ingredients_text)
    .map(parseIngredientLine)
    .filter(Boolean);
  const filteredIngredients = uniqueBy(
    exampleIngredients.filter((ingredient) => !normalizeKey(ingredient.display_name).includes(normalizeKey(promptText))),
    (ingredient) => normalizeKey(ingredient.display_name)
  ).slice(0, 10);

  const fallbackIngredients = filteredIngredients.length
    ? filteredIngredients
    : buildConceptFallbackRecipe(source).ingredients;

  const baseSteps = splitLines(primaryExample.instructions_text)
    .map((line, index) => ({
      number: index + 1,
      text: line.replace(/^\d+[\).\s-]*/, "").trim(),
    }))
    .filter((step) => normalizeText(step.text))
    .slice(0, 7);

  const fallbackSteps = baseSteps.length
    ? baseSteps
    : buildConceptFallbackRecipe(source).steps;

  const refinedTitle = promptText
    .split(/\s+/)
    .slice(0, 8)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");

  return {
    ...buildConceptFallbackRecipe(source),
    title: refinedTitle,
    description: `Generated from your idea prompt: ${promptText}. Built using nearby Ounje recipe patterns.`,
    recipe_type: normalizeText(primaryExample.recipe_type) || "custom",
    cook_time_text: normalizeText(primaryExample.cook_time_text) || "30 mins",
    ingredients: fallbackIngredients,
    steps: fallbackSteps,
    cuisine_tags: uniqueStrings([
      ...(Array.isArray(primaryExample.cuisine_tags) ? primaryExample.cuisine_tags : []),
      ...(Array.isArray(source.flavor_seed_terms) ? source.flavor_seed_terms : []),
    ]).slice(0, 6),
  };
}

function recipeIngredientNames(recipe) {
  return (recipe?.ingredients ?? [])
    .map((ingredient) => normalizeText(ingredient.display_name ?? ingredient.name ?? ingredient.ingredient ?? ""))
    .filter(Boolean);
}

function recipeHasIngredientNamed(recipe, names = []) {
  const haystack = recipeIngredientNames(recipe).map(normalizeKey);
  return names.some((name) => {
    const key = normalizeKey(name);
    return key && haystack.some((ingredientKey) => ingredientKey === key || ingredientKey.includes(key) || key.includes(ingredientKey));
  });
}

function ingredientNameMatchesText(ingredientName, text) {
  const key = normalizeKey(ingredientName);
  const haystack = normalizeKey(text);
  if (!key || !haystack) return false;
  if (haystack.includes(key)) return true;
  const compactName = normalizeKey(String(ingredientName ?? "").split(/\s+/).slice(-2).join(" "));
  return Boolean(compactName && compactName.length >= 5 && haystack.includes(compactName));
}

function buildFinalRecipeValidationIssues(recipe) {
  const issues = [];
  const steps = Array.isArray(recipe?.steps) ? recipe.steps : [];
  const stepText = normalizeText(steps.map((step) => step.text ?? "").join("\n"));

  if (/\bwater\b/i.test(stepText) && !recipeHasIngredientNamed(recipe, ["water"])) {
    issues.push("Steps mention water, but water is not listed. Either remove the water reference by using a listed liquid, or add water only if the recipe needs it.");
  }

  if (/\bdehydrat\w*\b.{0,80}\b(pepper|tomato|sauce|mixture|stew)\b/i.test(stepText)) {
    issues.push("A step uses 'dehydrate' for a pepper/tomato/sauce mixture. Use a practical cooking verb like cook down, reduce, simmer, or fry down unless true dehydration is intended.");
  }

  if (/\b(a little|some|a bit of)\b.{0,35}\b(water|stock|broth|oil)\b/i.test(stepText)) {
    issues.push("A liquid amount is vague in the method. Make it practical for the serving size or refer to the listed quantity.");
  }

  const missingQuantityIngredients = (recipe?.ingredients ?? []).filter((ingredient) => {
    const quantityText = normalizeText(ingredient.quantity_text ?? ingredient.quantityText ?? "");
    const name = normalizeText(ingredient.display_name ?? ingredient.name ?? "");
    if (!name) return false;
    if (quantityText && !/^to taste$/i.test(quantityText)) return false;
    if (/^(salt|pepper|water)$/i.test(name)) return false;
    return !quantityText;
  });
  if (missingQuantityIngredients.length >= 3) {
    issues.push(`Several non-pantry ingredients are missing quantities: ${missingQuantityIngredients.slice(0, 5).map((ingredient) => ingredient.display_name ?? ingredient.name).join(", ")}.`);
  }

  const ingredientNames = recipeIngredientNames(recipe);
  if (ingredientNames.length >= 4 && steps.length >= 2) {
    for (const ingredientName of ingredientNames) {
      const key = normalizeKey(ingredientName);
      if (!key || /^(salt|pepper|water)$/i.test(ingredientName)) continue;
      if (!normalizeKey(stepText).includes(key)) {
        const compactName = ingredientName.split(/\s+/).slice(-2).join(" ");
        if (compactName && !normalizeKey(stepText).includes(normalizeKey(compactName))) {
          issues.push(`Ingredient "${ingredientName}" is listed but not clearly used in the steps.`);
          if (issues.length >= 6) break;
        }
      }
    }
  }

  const linkedIngredientIssues = [];
  for (const step of steps) {
    const currentStepText = normalizeText(step?.text ?? "");
    const linkedNames = Array.isArray(step?.ingredients)
      ? step.ingredients.map((ingredient) => normalizeText(ingredient.display_name ?? ingredient.name ?? ingredient.ingredient ?? "")).filter(Boolean)
      : [];
    if (!currentStepText || !Array.isArray(step?.ingredients)) continue;

    for (const ingredientName of ingredientNames) {
      if (!ingredientName || /^(salt|pepper|water)$/i.test(ingredientName)) continue;
      if (!ingredientNameMatchesText(ingredientName, currentStepText)) continue;
      const alreadyLinked = linkedNames.some((linkedName) => ingredientNameMatchesText(ingredientName, linkedName) || ingredientNameMatchesText(linkedName, ingredientName));
      if (alreadyLinked) continue;
      const stepNumber = step.number ?? step.step_number ?? "?";
      linkedIngredientIssues.push(`Step ${stepNumber} mentions "${ingredientName}" but does not include it in that step's linked ingredients.`);
      break;
    }
    if (linkedIngredientIssues.length >= 4) break;
  }
  issues.push(...linkedIngredientIssues);

  return uniqueStrings(issues).slice(0, 8);
}

async function validateAndRepairImportedRecipe(recipe, source, { jobID = null } = {}) {
  const validationIssues = buildFinalRecipeValidationIssues(recipe);
  if (!validationIssues.length) {
    return {
      recipe,
      quality_flags: [],
      review_reason: null,
      validation_notes: [],
      applied: false,
    };
  }

  if (!openai) {
    return {
      recipe,
      quality_flags: ["final_validator_issues"],
      review_reason: validationIssues.join(" "),
      validation_notes: validationIssues,
      applied: false,
    };
  }

  try {
    const response = await timeRecipeImportStage(
      "final_validation",
      { jobID, metadata: { issue_count: validationIssues.length } },
      () => withRecipeAIStage("recipe_import.final_validator", () => openai.chat.completions.create({
        model: RECIPE_FINAL_VALIDATOR_MODEL,
        ...chatCompletionTemperatureParams(RECIPE_FINAL_VALIDATOR_MODEL, 0.02),
        ...chatCompletionLatencyParams(RECIPE_FINAL_VALIDATOR_MODEL, 1800),
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: RECIPE_FINAL_VALIDATOR_SYSTEM_PROMPT },
          {
            role: "user",
            content: [
              "Repair only these detected consistency issues:",
              JSON.stringify(validationIssues),
              "",
              "Recipe:",
              JSON.stringify(recipe),
              "",
              "Source hints:",
              JSON.stringify({
                source_type: source.source_type ?? null,
                platform: source.platform ?? null,
                title: source.title ?? null,
                description: source.description ?? source.meta_description ?? null,
                transcript_text: source.transcript_text ? limitText(source.transcript_text, 1200) : null,
              }),
              "",
              "Return JSON like:",
              JSON.stringify({
                recipe: {
                  ingredients: "only include this full array if ingredients changed",
                  steps: "only include this full array if steps changed",
                },
                validation_notes: ["string"],
                quality_flags: ["string"],
                review_reason: "string|null",
              }),
            ].join("\n"),
          },
        ],
      }))
    );

    const rawContent = response.choices?.[0]?.message?.content ?? "{}";
    const parsed = JSON.parse(rawContent);
    const repairPatch = parsed.recipe && typeof parsed.recipe === "object" ? parsed.recipe : parsed;
    const repairedInput = {
      ...recipe,
      ...repairPatch,
      ingredients: Array.isArray(repairPatch.ingredients) ? repairPatch.ingredients : recipe.ingredients,
      steps: Array.isArray(repairPatch.steps) ? repairPatch.steps : recipe.steps,
    };
    const repaired = coerceStructuredRecipeCandidate(repairedInput, source);
    const repairedMetrics = recipeCoreMetrics(repaired);
    const originalMetrics = recipeCoreMetrics(recipe);
    const repairedIssues = buildFinalRecipeValidationIssues(repaired);
    const shouldUseRepair =
      repairedMetrics.ingredientCount >= Math.max(1, originalMetrics.ingredientCount - 1)
      && repairedMetrics.stepCount >= Math.max(1, originalMetrics.stepCount - 1)
      && repairedIssues.length <= validationIssues.length;

    const applied = shouldUseRepair && JSON.stringify(repaired) !== JSON.stringify(recipe);
    const validationNotes = uniqueStrings([
      ...validationIssues,
      ...(Array.isArray(parsed.validation_notes) ? parsed.validation_notes : []),
      ...(repairedIssues.length ? repairedIssues.map((issue) => `Remaining: ${issue}`) : []),
    ]);
    const qualityFlags = uniqueStrings([
      ...(Array.isArray(parsed.quality_flags) ? parsed.quality_flags : []),
      ...(applied ? ["final_validator_applied"] : ["final_validator_review_needed"]),
    ]);

    if (jobID) {
      await storeArtifact(jobID, {
        artifact_type: "final_recipe_validator",
        content_type: "application/json",
        source_url: source.canonical_url ?? source.source_url ?? null,
        raw_json: compactJSON({
          detected_issues: validationIssues,
          repaired_issues: repairedIssues,
          validation_notes: validationNotes,
          quality_flags: qualityFlags,
          applied,
        }),
        metadata: {
          model: RECIPE_FINAL_VALIDATOR_MODEL,
          issue_count: validationIssues.length,
          remaining_issue_count: repairedIssues.length,
          applied,
        },
      }).catch(() => {});
    }

    return {
      recipe: applied ? repaired : recipe,
      quality_flags: qualityFlags,
      review_reason: normalizeText(parsed.review_reason ?? "") || (repairedIssues.length ? repairedIssues.join(" ") : null),
      validation_notes: validationNotes,
      applied,
    };
  } catch (error) {
    if (jobID) {
      await storeArtifact(jobID, {
        artifact_type: "final_recipe_validator",
        content_type: "application/json",
        source_url: source.canonical_url ?? source.source_url ?? null,
        raw_json: compactJSON({
          detected_issues: validationIssues,
          error: errorSummary(error),
          applied: false,
        }),
        metadata: {
          model: RECIPE_FINAL_VALIDATOR_MODEL,
          issue_count: validationIssues.length,
          applied: false,
          failed: true,
        },
      }).catch(() => {});
    }
    return {
      recipe,
      quality_flags: ["final_validator_failed"],
      review_reason: validationIssues.join(" "),
      validation_notes: validationIssues,
      applied: false,
    };
  }
}

async function enrichRecipeLowRiskFields(normalizedRecipe, source) {
  if (!openai) return normalizedRecipe;

  const hasMissingIngredientQuantities = (normalizedRecipe.ingredients ?? []).some((ingredient) => !normalizeText(ingredient.quantity_text));
  const hasMissingLightFields = !normalizedRecipe.servings_text
    || !normalizedRecipe.cook_time_text
    || !Number.isFinite(normalizedRecipe.cook_time_minutes)
    || !Number.isFinite(normalizedRecipe.prep_time_minutes)
    || !normalizedRecipe.skill_level;

  if (!hasMissingIngredientQuantities && !hasMissingLightFields) {
    return normalizedRecipe;
  }

  const response = await withRecipeAIStage("recipe_import.light_fill", () => openai.chat.completions.create({
    model: RECIPE_IMPORT_COMPLETION_MODEL,
    ...chatCompletionTemperatureParams(RECIPE_IMPORT_COMPLETION_MODEL, 0.05),
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: RECIPE_LIGHT_FILL_SYSTEM_PROMPT },
      {
        role: "user",
        content: [
          "Fill only low-risk missing recipe fields from the supplied evidence.",
          "",
          "Current recipe:",
          JSON.stringify(normalizedRecipe),
          "",
          "Structured source:",
          JSON.stringify(source.structured_recipe ?? null),
          "",
          "Ingredient candidates:",
          JSON.stringify(source.ingredient_candidates ?? []),
          "",
          "Instruction candidates:",
          JSON.stringify(source.instruction_candidates ?? []),
          "",
          "Transcript text:",
          limitText(source.transcript_text ?? ""),
          "",
          "Caption/raw text:",
          limitText(source.raw_text ?? source.body_text ?? ""),
          "",
          "Return JSON like:",
          JSON.stringify({
            recipe: {
              servings_text: "string|null",
              servings_count: "number|null",
              prep_time_minutes: "number|null",
              cook_time_minutes: "number|null",
              cook_time_text: "string|null",
              skill_level: "string|null",
              est_calories_text: "string|null",
              calories_kcal: "number|null",
              protein_g: "number|null",
              carbs_g: "number|null",
              fat_g: "number|null",
              ingredients: [{ display_name: "string", quantity_text: "string|null" }],
            },
          }),
        ].join("\n"),
      },
    ],
  }));

  const rawContent = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(rawContent);
  return mergeLowRiskRecipeFill(normalizedRecipe, parsed.recipe ?? parsed);
}

function recipeNeedsSecondaryFill(recipe) {
  const ingredients = Array.isArray(recipe?.ingredients) ? recipe.ingredients : [];
  const missingIngredientQuantities = ingredients.filter((ingredient) => !normalizeText(ingredient.quantity_text)).length;
  const hasAnyIngredientQuantity = missingIngredientQuantities < ingredients.length;
  const missingServings = !normalizeText(recipe?.servings_text) && !Number.isFinite(recipe?.servings_count);
  const missingCookTime = !normalizeText(recipe?.cook_time_text) && !Number.isFinite(recipe?.cook_time_minutes);
  const criticallySparseQuantities = ingredients.length >= 3
    && missingIngredientQuantities >= Math.ceil(ingredients.length * 0.75)
    && !hasAnyIngredientQuantity;

  return missingServings || missingCookTime || criticallySparseQuantities;
}

async function enrichRecipeSecondaryFields(normalizedRecipe, source, { jobID = null } = {}) {
  if (!openai || !recipeNeedsSecondaryFill(normalizedRecipe)) {
    return {
      recipe: normalizedRecipe,
      applied: false,
    };
  }

  const content = [
    {
      type: "text",
      text: [
        "Fill only small missing recipe details that are safe to estimate from the evidence.",
        "",
        "Current recipe:",
        JSON.stringify(normalizedRecipe),
        "",
        "Structured source:",
        JSON.stringify(source.structured_recipe ?? null),
        "",
        "Ingredient candidates:",
        JSON.stringify(source.ingredient_candidates ?? []),
        "",
        "Instruction candidates:",
        JSON.stringify(source.instruction_candidates ?? []),
        "",
        "Transcript text:",
        limitText(source.transcript_text ?? ""),
        "",
        "Caption/raw text:",
        limitText(source.raw_text ?? source.body_text ?? ""),
        "",
        "Return JSON like:",
        JSON.stringify({
          recipe: {
            servings_text: "string|null",
            servings_count: "number|null",
            prep_time_minutes: "number|null",
            cook_time_minutes: "number|null",
            cook_time_text: "string|null",
            skill_level: "string|null",
            est_calories_text: "string|null",
            calories_kcal: "number|null",
            protein_g: "number|null",
            carbs_g: "number|null",
            fat_g: "number|null",
            ingredients: [{ display_name: "string", quantity_text: "string|null" }],
          },
        }),
      ].join("\n"),
    },
    ...collectRecipeEvidenceImageInputs(source, { maxCount: 3 }),
  ];

  const response = await timeRecipeImportStage(
    "secondary_fill",
    { jobID },
    () => withRecipeAIStage("recipe_import.secondary_fill", () => openai.chat.completions.create({
      model: RECIPE_IMPORT_COMPLETION_MODEL,
      ...chatCompletionTemperatureParams(RECIPE_IMPORT_COMPLETION_MODEL, 0.02),
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content: RECIPE_SECONDARY_FILL_SYSTEM_PROMPT,
        },
        {
          role: "user",
          content,
        },
      ],
    }))
  );

  const rawContent = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(rawContent);
  const merged = mergeLowRiskRecipeFill(normalizedRecipe, parsed.recipe ?? parsed);
  const applied = JSON.stringify(merged) !== JSON.stringify(normalizedRecipe);

  return {
    recipe: merged,
    applied,
  };
}

function photoRecipeFallbackDraft(source) {
  const title = normalizeText(source.title ?? source.photo_context?.dish_hint ?? source.photo_sonar_context?.matched_dish_name ?? "Photo recipe") || "Photo recipe";
  const visibleIngredients = uniqueStrings(source.ingredient_candidates ?? []).slice(0, 10);
  const ingredients = (visibleIngredients.length ? visibleIngredients : ["olive oil", "salt", "black pepper"]).map((name) => ({
    display_name: name,
    quantity_text: null,
  }));
  return {
    title,
    description: "A cookable draft inferred from a food photo. Review quantities before cooking.",
    source: "Ounje",
    source_platform: "Photo",
    hero_image_url: source.hero_image_url ?? null,
    discover_card_image_url: source.hero_image_url ?? null,
    recipe_url: source.source_url ?? null,
    original_recipe_url: source.source_url ?? null,
    category: source.photo_meal_gate?.likely_meal_type ?? null,
    recipe_type: source.photo_meal_gate?.likely_meal_type ?? null,
    servings: 4,
    servings_text: "4 servings",
    ingredients,
    steps: [
      { number: 1, text: "Prepare the visible ingredients from the photo and season to taste." },
      { number: 2, text: "Cook the main components using the method that best matches the dish, adjusting heat as needed." },
      { number: 3, text: "Plate and finish with seasoning or garnish to match the photo." },
    ],
    quality_flags: ["photo_inferred", "needs_review"],
  };
}

function validatePhotoRecipeStructurally(recipe, source) {
  const issues = [];
  const ingredients = Array.isArray(recipe?.ingredients) ? recipe.ingredients : [];
  const steps = Array.isArray(recipe?.steps) ? recipe.steps : [];
  if (!normalizeText(recipe?.title ?? "")) issues.push("missing_title");
  if (ingredients.length < 4) issues.push("too_few_ingredients");
  if (steps.length < 3) issues.push("too_few_steps");
  const ingredientNames = ingredients.map((entry) => normalizeText(entry?.display_name ?? entry?.name ?? "", 80).toLowerCase()).filter(Boolean);
  const stepText = steps.map((entry) => normalizeText(entry?.text ?? entry?.description ?? entry ?? "", 600).toLowerCase()).join("\n");
  const matchedIngredientCount = ingredientNames.filter((name) => name.length > 2 && stepText.includes(name.split(/\s+/).slice(-1)[0])).length;
  if (ingredientNames.length >= 4 && matchedIngredientCount < 2) issues.push("steps_do_not_reference_ingredients");
  if (ingredientNames.some((name) => /^(ingredient|extra protein|protein|vegetable|sauce|seasoning)$/i.test(name))) {
    issues.push("placeholder_ingredient");
  }
  if (/exact/i.test(recipe?.description ?? "") && !source?.photo_sonar_context?.reference_urls?.length) {
    issues.push("unsupported_exact_source_claim");
  }
  return uniqueStrings(issues);
}

async function synthesizeRecipeFromPhoto(source, { jobID = null } = {}) {
  if (!source?.photo_meal_gate?.is_meal) {
    return {
      recipe: photoRecipeFallbackDraft(source),
      quality_flags: ["photo_meal_gate_rejected", "needs_review"],
      review_reason: source?.photo_meal_gate?.reject_reason ?? "The photo does not appear to show a prepared meal.",
    };
  }
  if (!openai) {
    return {
      recipe: photoRecipeFallbackDraft(source),
      quality_flags: ["openai_unavailable", "photo_inferred", "needs_review"],
      review_reason: "OpenAI cleanup was unavailable, so this photo recipe needs review.",
    };
  }
  const compactEvidence = {
    dish_hint: source.photo_context?.dish_hint ?? null,
    coarse_place_context: source.photo_context?.coarse_place_context ?? null,
    meal_gate: source.photo_meal_gate,
    visual_analysis: source.photo_visual_analysis,
    sonar_context: source.photo_sonar_context,
    hero_image_url: source.hero_image_url ?? null,
  };
  const imagePart = photoImageContentPart(source.photo_image_inputs?.[0]);
  const makeRequest = async ({ repairIssues = [], previousRecipe = null } = {}) => {
    const userText = [
      "Create a cookable Ounje recipe from the photo analysis and grounded web evidence.",
      "Use web references for mainstream quantities when the photo cannot show amounts.",
      "Keep uncertainty in provenance, but make the recipe useful.",
      "Do not add ingredients unsupported by the photo, dish type, references, or basic pantry/cooking necessities.",
      "Do not claim this is an exact restaurant recipe unless a cited source supports that exact match.",
      "Return strict JSON with recipe, quality_flags, review_reason, and provenance_flags.",
      "",
      "Ounje recipe fields needed:",
      JSON.stringify({
        title: "string",
        description: "short summary",
        source: "Ounje",
        source_platform: "Photo",
        hero_image_url: source.hero_image_url ?? null,
        discover_card_image_url: source.hero_image_url ?? null,
        category: "meal type",
        recipe_type: "meal type",
        servings: 4,
        servings_text: "4 servings",
        prep_time_minutes: 10,
        cook_time_minutes: 20,
        total_time_minutes: 30,
        calories_kcal: 520,
        protein_g: 28,
        carbs_g: 52,
        fat_g: 22,
        cuisine_tags: ["tag"],
        dietary_tags: ["tag"],
        flavor_tags: ["tag"],
        ingredients: [{ display_name: "ingredient", quantity_text: "1 cup", grocery_name: "ingredient" }],
        steps: [{ number: 1, text: "step text" }],
      }),
      "",
      "Evidence:",
      JSON.stringify(compactEvidence),
      repairIssues.length ? `Repair these validation failures: ${JSON.stringify(repairIssues)}` : null,
      previousRecipe ? `Previous invalid recipe: ${JSON.stringify(previousRecipe).slice(0, 12000)}` : null,
    ].filter(Boolean).join("\n");
    const content = [{ type: "text", text: userText }];
    if (imagePart) content.push(imagePart);
    const response = await withRecipeAIStage(repairIssues.length ? "recipe_import.photo_recipe_repair" : "recipe_import.photo_recipe_cleanup", () => openai.chat.completions.create({
      model: PHOTO_RECIPE_CLEANUP_MODEL,
      ...chatCompletionTemperatureParams(PHOTO_RECIPE_CLEANUP_MODEL, repairIssues.length ? 0.08 : 0.18),
      ...chatCompletionLatencyParams(PHOTO_RECIPE_CLEANUP_MODEL, repairIssues.length ? 4200 : 5200),
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content: [
            "You convert food photos into practical Ounje recipes.",
            "The recipe must be cookable and internally consistent.",
            "Ingredients, quantities, steps, servings, timing, and macros should agree.",
            "Use citations only as evidence; do not quote or copy long recipe text.",
          ].join("\n"),
        },
        { role: "user", content },
      ],
    }));
    return JSON.parse(response.choices?.[0]?.message?.content ?? "{}");
  };
  let parsed = await makeRequest();
  let recipe = parsed.recipe ?? parsed;
  let issues = validatePhotoRecipeStructurally(recipe, source);
  let repaired = false;
  if (issues.length) {
    const repairedParsed = await makeRequest({ repairIssues: issues, previousRecipe: recipe });
    const repairedRecipe = repairedParsed.recipe ?? repairedParsed;
    const repairedIssues = validatePhotoRecipeStructurally(repairedRecipe, source);
    if (repairedIssues.length < issues.length) {
      parsed = repairedParsed;
      recipe = repairedRecipe;
      issues = repairedIssues;
      repaired = true;
    }
  }
  if (jobID) {
    await storeArtifact(jobID, {
      artifact_type: "photo_recipe_cleanup",
      content_type: "application/json",
      source_url: source.source_url ?? null,
      raw_json: compactJSON({ parsed, validation_issues: issues, repaired }),
      metadata: { repaired, issue_count: issues.length, model: PHOTO_RECIPE_CLEANUP_MODEL },
    }).catch(() => {});
    await storeArtifact(jobID, {
      artifact_type: "photo_final_validator",
      content_type: "application/json",
      source_url: source.source_url ?? null,
      raw_json: compactJSON({ issues, repaired, passed: !issues.length }),
      metadata: { passed: !issues.length, issue_count: issues.length },
    }).catch(() => {});
  }
  return {
    recipe,
    quality_flags: uniqueStrings([
      "photo_inferred",
      "quantities_inferred",
      ...(source.photo_sonar_context ? ["web_reference_applied"] : []),
      ...(source.photo_context?.coarse_place_context ? ["restaurant_clone_inferred"] : []),
      ...(Array.isArray(parsed.quality_flags) ? parsed.quality_flags : []),
      ...(Array.isArray(parsed.provenance_flags) ? parsed.provenance_flags : []),
      ...(repaired ? ["photo_cleanup_repaired"] : []),
      ...(issues.length ? ["needs_review", "photo_final_validator_failed"] : ["photo_final_validator_passed"]),
    ]),
    review_reason: issues.length
      ? `Photo recipe needs review: ${issues.join(", ")}.`
      : parsed.review_reason ?? null,
  };
}

async function repairSparseImportedRecipe(normalizedRecipe, source) {
  const metrics = recipeCoreMetrics(normalizedRecipe);
  if (!metrics.needsRepair) {
    return normalizedRecipe;
  }

  const repairQuery = normalizeText([
    source.title,
    source.description,
    source.transcript_text,
    source.raw_text,
    source.body_text,
  ].filter(Boolean).join(" "));

  const promptExamples = await fetchPromptRecipeExamples(
    repairQuery || normalizedRecipe.title || source.title || "",
    5
  );
  const styleExamples = findRecipeStyleExamples({
    recipe: {
      recipe_type: normalizedRecipe.recipe_type ?? source.structured_recipe?.recipeCategory ?? source.recipe_type ?? null,
      cuisine_tags: uniqueStrings([
        ...(normalizedRecipe.cuisine_tags ?? []),
        ...extractIngredientSignals(repairQuery),
      ]),
    },
    profile: null,
    limit: 3,
  });

  if (!openai) {
    return promptExamples.length
      ? buildGroundedConceptFallbackRecipe({
          raw_text: repairQuery || normalizedRecipe.title || source.title || "Imported recipe",
          prompt_examples: promptExamples,
          flavor_seed_terms: extractIngredientSignals(repairQuery),
        })
      : normalizedRecipe;
  }

  try {
    const response = await withRecipeAIStage("recipe_import.sparse_repair", () => openai.chat.completions.create({
      model: RECIPE_INGESTION_MODEL,
      ...chatCompletionTemperatureParams(RECIPE_INGESTION_MODEL, 0.12),
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content: RECIPE_REPAIR_SYSTEM_PROMPT,
        },
        {
          role: "user",
          content: [
            "Repair this imported recipe so the detail page is actually usable.",
            "",
            "Current sparse recipe:",
            JSON.stringify(normalizedRecipe),
            "",
            "Source evidence:",
            JSON.stringify({
              source_type: source.source_type ?? null,
              platform: source.platform ?? null,
              title: source.title ?? null,
              description: source.description ?? source.meta_description ?? null,
              transcript_text: source.transcript_text ?? null,
              raw_text: source.raw_text ?? null,
              ingredient_candidates: source.ingredient_candidates ?? [],
              instruction_candidates: source.instruction_candidates ?? [],
              structured_recipe: source.structured_recipe ?? null,
            }),
            "",
            "Nearby grounded recipe examples:",
            JSON.stringify(buildPromptExamplesContext(promptExamples)),
            "",
            "Style examples:",
            JSON.stringify(styleExamples),
            "",
            "If the source clearly points to a common dish, complete the missing structure so the recipe is cookable and not near-empty.",
            "",
            "Return the same JSON shape used for structured recipe extraction.",
          ].join("\n"),
        },
      ],
    }));

    const rawContent = response.choices?.[0]?.message?.content ?? "{}";
    const parsed = JSON.parse(rawContent);
    const repaired = coerceStructuredRecipeCandidate(parsed.recipe ?? parsed, source);
    const repairedMetrics = recipeCoreMetrics(repaired);

    if (
      repairedMetrics.ingredientCount >= metrics.ingredientCount
      && repairedMetrics.stepCount >= metrics.stepCount
      && (hasUsableRecipeCore(repaired) || repairedMetrics.ingredientCount >= 4 || repairedMetrics.stepCount >= 3)
    ) {
      return repaired;
    }
  } catch {
    // Fall through to grounded fallback below.
  }

  return promptExamples.length
    ? buildGroundedConceptFallbackRecipe({
        raw_text: repairQuery || normalizedRecipe.title || source.title || "Imported recipe",
        prompt_examples: promptExamples,
        flavor_seed_terms: extractIngredientSignals(repairQuery),
      })
    : normalizedRecipe;
}

const LOCAL_MACRO_PROFILES = [
  {
    pattern: /\b(banana|bananas)\b/,
    per100g: { calories_kcal: 89, protein_g: 1.1, carbs_g: 22.8, fat_g: 0.3 },
    eachGrams: 118,
  },
  {
    pattern: /\b(egg|eggs)\b/,
    each: { calories_kcal: 72, protein_g: 6.3, carbs_g: 0.4, fat_g: 4.8 },
    eachGrams: 50,
  },
  {
    pattern: /\b(greek yogurt|yoghurt|skyr)\b/,
    per100g: { calories_kcal: 59, protein_g: 10.3, carbs_g: 3.6, fat_g: 0.4 },
    cupGrams: 245,
    tablespoonGrams: 15,
  },
  {
    pattern: /\b(cocoa powder|cacao powder)\b/,
    per100g: { calories_kcal: 228, protein_g: 19.6, carbs_g: 57.9, fat_g: 13.7 },
    tablespoonGrams: 5,
  },
  {
    pattern: /\b(whey protein|protein powder)\b/,
    per100g: { calories_kcal: 400, protein_g: 80, carbs_g: 8, fat_g: 6 },
    scoopGrams: 30,
  },
  {
    pattern: /\b(oat|oats|oat flour)\b/,
    per100g: { calories_kcal: 389, protein_g: 16.9, carbs_g: 66.3, fat_g: 6.9 },
    cupGrams: 80,
  },
  {
    pattern: /\b(flour|all purpose flour|whole wheat flour)\b/,
    per100g: { calories_kcal: 364, protein_g: 10.3, carbs_g: 76.3, fat_g: 1 },
    cupGrams: 120,
  },
  {
    pattern: /\b(sugar|brown sugar|coconut sugar)\b/,
    per100g: { calories_kcal: 387, protein_g: 0, carbs_g: 100, fat_g: 0 },
    cupGrams: 200,
    tablespoonGrams: 12.5,
  },
  {
    pattern: /\b(honey|maple syrup)\b/,
    per100g: { calories_kcal: 304, protein_g: 0.3, carbs_g: 82.4, fat_g: 0 },
    tablespoonGrams: 21,
  },
  {
    pattern: /\b(peanut butter|almond butter)\b/,
    per100g: { calories_kcal: 588, protein_g: 25, carbs_g: 20, fat_g: 50 },
    tablespoonGrams: 16,
  },
  {
    pattern: /\b(oil|olive oil|avocado oil|coconut oil)\b/,
    per100g: { calories_kcal: 884, protein_g: 0, carbs_g: 0, fat_g: 100 },
    tablespoonGrams: 13.5,
    teaspoonGrams: 4.5,
  },
  {
    pattern: /\b(butter)\b/,
    per100g: { calories_kcal: 717, protein_g: 0.9, carbs_g: 0.1, fat_g: 81 },
    tablespoonGrams: 14,
  },
  {
    pattern: /\b(milk)\b/,
    per100g: { calories_kcal: 50, protein_g: 3.4, carbs_g: 5, fat_g: 1.9 },
    cupGrams: 244,
  },
  {
    pattern: /\b(cream cheese)\b/,
    per100g: { calories_kcal: 342, protein_g: 6.2, carbs_g: 4.1, fat_g: 34 },
    tablespoonGrams: 14.5,
  },
  {
    pattern: /\b(cottage cheese)\b/,
    per100g: { calories_kcal: 98, protein_g: 11.1, carbs_g: 3.4, fat_g: 4.3 },
    cupGrams: 226,
  },
];

function normalizeMacroUnit(unit) {
  const raw = normalizeText(unit).toLowerCase().replace(/\./g, "");
  if (!raw) return "ct";
  if (["g", "gram", "grams"].includes(raw)) return "g";
  if (["kg", "kilogram", "kilograms"].includes(raw)) return "kg";
  if (["oz", "ounce", "ounces"].includes(raw)) return "oz";
  if (["lb", "lbs", "pound", "pounds"].includes(raw)) return "lb";
  if (["ml", "milliliter", "milliliters", "millilitre", "millilitres"].includes(raw)) return "ml";
  if (["l", "liter", "liters", "litre", "litres"].includes(raw)) return "l";
  if (["cup", "cups", "c"].includes(raw)) return "cup";
  if (["tbsp", "tablespoon", "tablespoons", "tbs"].includes(raw)) return "tbsp";
  if (["tsp", "teaspoon", "teaspoons"].includes(raw)) return "tsp";
  if (["scoop", "scoops"].includes(raw)) return "scoop";
  if (["large", "medium", "small", "whole", "ct", "count", "counts"].includes(raw)) return "ct";
  return raw;
}

function quantityForMacroEstimate(quantityText) {
  const raw = normalizeText(quantityText);
  if (!raw) return null;
  const parsed = parseIngredientMeasurement(raw);
  if (parsed) {
    return {
      amount: parsed.amount,
      unit: normalizeMacroUnit(parsed.unit),
    };
  }

  const match = raw.match(/(\d+\s+\d\/\d|\d+\/\d|\d+(?:\.\d+)?|[¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞])/u);
  const amount = match ? parseQuantityAmount(match[1]) : null;
  return amount == null ? null : { amount, unit: "ct" };
}

function gramsForMacroProfile(quantity, profile) {
  if (!quantity || !profile?.per100g) return null;
  const amount = Number(quantity.amount);
  if (!Number.isFinite(amount) || amount <= 0) return null;

  switch (quantity.unit) {
    case "g": return amount;
    case "kg": return amount * 1000;
    case "oz": return amount * 28.3495;
    case "lb": return amount * 453.592;
    case "ml": return amount;
    case "l": return amount * 1000;
    case "cup": return amount * (profile.cupGrams ?? 240);
    case "tbsp": return amount * (profile.tablespoonGrams ?? 15);
    case "tsp": return amount * (profile.teaspoonGrams ?? 5);
    case "scoop": return amount * (profile.scoopGrams ?? 30);
    case "ct": return profile.eachGrams ? amount * profile.eachGrams : null;
    default: return null;
  }
}

function macroTotalsForIngredient(ingredient) {
  const name = normalizeText(ingredient?.display_name ?? ingredient?.name ?? "");
  const quantity = quantityForMacroEstimate(ingredient?.quantity_text ?? ingredient?.quantity ?? "");
  if (!name || !quantity) return null;

  const profile = LOCAL_MACRO_PROFILES.find((entry) => entry.pattern.test(name.toLowerCase()));
  if (!profile) return null;

  if (profile.each && quantity.unit === "ct") {
    const amount = Number(quantity.amount);
    if (!Number.isFinite(amount) || amount <= 0) return null;
    return {
      calories_kcal: profile.each.calories_kcal * amount,
      protein_g: profile.each.protein_g * amount,
      carbs_g: profile.each.carbs_g * amount,
      fat_g: profile.each.fat_g * amount,
    };
  }

  const grams = gramsForMacroProfile(quantity, profile);
  if (!Number.isFinite(grams) || grams <= 0 || !profile.per100g) return null;
  const multiplier = grams / 100;
  return {
    calories_kcal: profile.per100g.calories_kcal * multiplier,
    protein_g: profile.per100g.protein_g * multiplier,
    carbs_g: profile.per100g.carbs_g * multiplier,
    fat_g: profile.per100g.fat_g * multiplier,
  };
}

function estimateRecipeMacrosLocally(recipe) {
  const ingredients = Array.isArray(recipe?.ingredients) ? recipe.ingredients : [];
  if (ingredients.length < 2) return null;

  const servings = Number.isFinite(Number(recipe?.servings_count))
    ? Number(recipe.servings_count)
    : parseFirstInteger(recipe?.servings_text);
  if (!Number.isFinite(servings) || servings <= 0) return null;

  let matchedCount = 0;
  const totals = {
    calories_kcal: 0,
    protein_g: 0,
    carbs_g: 0,
    fat_g: 0,
  };

  for (const ingredient of ingredients) {
    const macros = macroTotalsForIngredient(ingredient);
    if (!macros) continue;
    matchedCount += 1;
    totals.calories_kcal += macros.calories_kcal;
    totals.protein_g += macros.protein_g;
    totals.carbs_g += macros.carbs_g;
    totals.fat_g += macros.fat_g;
  }

  const matchedRatio = matchedCount / Math.max(1, ingredients.length);
  if (matchedCount < 2 || matchedRatio < 0.4 || totals.calories_kcal <= 0) return null;

  const perServing = {
    calories_kcal: Math.max(1, Math.round(totals.calories_kcal / servings)),
    protein_g: Number((totals.protein_g / servings).toFixed(1)),
    carbs_g: Number((totals.carbs_g / servings).toFixed(1)),
    fat_g: Number((totals.fat_g / servings).toFixed(1)),
  };
  return {
    ...perServing,
    est_calories_text: `${perServing.calories_kcal} kcal per serving`,
    matched_ingredient_count: matchedCount,
    matched_ingredient_ratio: Number(matchedRatio.toFixed(3)),
  };
}

function fillRecipeMacrosWithLocalEstimate(normalizedRecipe) {
  const estimate = estimateRecipeMacrosLocally(normalizedRecipe);
  if (!estimate) return normalizedRecipe;

  return {
    ...normalizedRecipe,
    calories_kcal: Number.isFinite(normalizedRecipe.calories_kcal) ? normalizedRecipe.calories_kcal : estimate.calories_kcal,
    protein_g: Number.isFinite(normalizedRecipe.protein_g) ? normalizedRecipe.protein_g : estimate.protein_g,
    carbs_g: Number.isFinite(normalizedRecipe.carbs_g) ? normalizedRecipe.carbs_g : estimate.carbs_g,
    fat_g: Number.isFinite(normalizedRecipe.fat_g) ? normalizedRecipe.fat_g : estimate.fat_g,
    est_calories_text: normalizedRecipe.est_calories_text ?? estimate.est_calories_text,
  };
}

// Lightweight macro estimation — runs when any core macro is still missing
// after the main synthesis passes. Uses a small, cheap model focused solely on
// estimating per-serving calories/protein/carbs/fat from the finalized ingredient list.
async function maybeFillMissingMacros(normalizedRecipe) {
  const missingAny =
    !Number.isFinite(normalizedRecipe.calories_kcal)
    || !Number.isFinite(normalizedRecipe.protein_g)
    || !Number.isFinite(normalizedRecipe.carbs_g)
    || !Number.isFinite(normalizedRecipe.fat_g);
  if (!missingAny) return normalizedRecipe;
  if (!openai) return fillRecipeMacrosWithLocalEstimate(normalizedRecipe);

  const ingredients = Array.isArray(normalizedRecipe.ingredients) ? normalizedRecipe.ingredients : [];
  if (ingredients.length < 2) return fillRecipeMacrosWithLocalEstimate(normalizedRecipe);

  const ingredientSummary = ingredients
    .map((i) => [i.quantity_text, i.display_name].filter(Boolean).join(" "))
    .filter(Boolean)
    .join(", ");

  const context = [
    `Title: ${normalizedRecipe.title ?? "Recipe"}`,
    normalizedRecipe.servings_text ? `Servings: ${normalizedRecipe.servings_text}` : null,
    Number.isFinite(normalizedRecipe.servings_count) ? `Serving count: ${normalizedRecipe.servings_count}` : null,
    `Ingredients: ${ingredientSummary}`,
    normalizedRecipe.category ? `Category: ${normalizedRecipe.category}` : null,
    normalizedRecipe.recipe_type ? `Type: ${normalizedRecipe.recipe_type}` : null,
  ].filter(Boolean).join("\n");

  try {
    const response = await withRecipeAIStage("recipe_import.macro_fill", () => openai.chat.completions.create({
      model: RECIPE_IMPORT_COMPLETION_MODEL,
      ...chatCompletionTemperatureParams(RECIPE_IMPORT_COMPLETION_MODEL, 0),
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content: [
            "You are a nutrition estimator. Given a recipe title and ingredient list, estimate conservative per-serving macros.",
            "Return realistic estimates for app display — not lab-accurate.",
            "Return JSON with: calories_kcal (number), protein_g (number), carbs_g (number), fat_g (number), est_calories_text (e.g. '420 kcal per serving').",
            "If the recipe is too vague to estimate any single field, return null for that field only.",
            "Do NOT return null for all fields unless the recipe is completely unintelligible.",
          ].join("\n"),
        },
        { role: "user", content: context },
      ],
    }));
    const parsed = JSON.parse(response.choices?.[0]?.message?.content ?? "{}");
    const caloriesKcal = Number.isFinite(Number(parsed?.calories_kcal)) ? Number(parsed.calories_kcal) : null;
    const proteinG = Number.isFinite(Number(parsed?.protein_g)) ? Number(parsed.protein_g) : null;
    const carbsG = Number.isFinite(Number(parsed?.carbs_g)) ? Number(parsed.carbs_g) : null;
    const fatG = Number.isFinite(Number(parsed?.fat_g)) ? Number(parsed.fat_g) : null;
    const estCaloriesText = typeof parsed?.est_calories_text === "string" ? parsed.est_calories_text.trim() : null;
    const aiFilledRecipe = {
      ...normalizedRecipe,
      calories_kcal: normalizedRecipe.calories_kcal ?? caloriesKcal,
      protein_g: normalizedRecipe.protein_g ?? proteinG,
      carbs_g: normalizedRecipe.carbs_g ?? carbsG,
      fat_g: normalizedRecipe.fat_g ?? fatG,
      est_calories_text: normalizedRecipe.est_calories_text ?? estCaloriesText,
    };
    return fillRecipeMacrosWithLocalEstimate(aiFilledRecipe);
  } catch {
    return fillRecipeMacrosWithLocalEstimate(normalizedRecipe);
  }
}

function hasCompleteDisplayMacros(recipe) {
  return ["calories_kcal", "protein_g", "carbs_g", "fat_g"].every((field) => {
    const value = recipe?.[field];
    return value !== null
      && value !== undefined
      && String(value).trim() !== ""
      && Number.isFinite(Number(value));
  });
}

function isFiniteMacroValue(value) {
  return value !== null
    && value !== undefined
    && String(value).trim() !== ""
    && Number.isFinite(Number(value));
}

function fillRecipeMacrosWithDisplayFallback(normalizedRecipe) {
  if (hasCompleteDisplayMacros(normalizedRecipe)) return normalizedRecipe;

  const text = [
    normalizedRecipe?.title,
    normalizedRecipe?.description,
    normalizedRecipe?.category,
    normalizedRecipe?.recipe_type,
    normalizedRecipe?.main_protein,
    normalizedRecipe?.cook_method,
  ].map((value) => normalizeText(value).toLowerCase()).filter(Boolean).join(" ");

  let fallback = { calories_kcal: 420, protein_g: 22, carbs_g: 44, fat_g: 16 };
  if (/smoothie|shake|juice|drink/.test(text)) {
    fallback = { calories_kcal: 280, protein_g: /protein/.test(text) ? 28 : 12, carbs_g: 38, fat_g: 7 };
  } else if (/salad|greens|slaw/.test(text)) {
    fallback = { calories_kcal: 360, protein_g: /chicken|salmon|tuna|beef|tofu|egg/.test(text) ? 28 : 14, carbs_g: 26, fat_g: 18 };
  } else if (/brownie|cookie|cake|dessert|sweet|pancake|waffle/.test(text)) {
    fallback = { calories_kcal: 330, protein_g: /protein|yogurt|egg/.test(text) ? 14 : 7, carbs_g: 42, fat_g: 13 };
  } else if (/bowl|rice|pasta|noodle|wrap|sandwich|burger|taco|burrito/.test(text)) {
    fallback = { calories_kcal: 520, protein_g: 30, carbs_g: 58, fat_g: 18 };
  } else if (/soup|stew|chili/.test(text)) {
    fallback = { calories_kcal: 380, protein_g: 24, carbs_g: 34, fat_g: 14 };
  } else if (/high protein|protein/.test(text)) {
    fallback = { calories_kcal: 450, protein_g: 36, carbs_g: 42, fat_g: 14 };
  }

  const caloriesKcal = isFiniteMacroValue(normalizedRecipe?.calories_kcal)
    ? Number(normalizedRecipe.calories_kcal)
    : fallback.calories_kcal;
  return {
    ...normalizedRecipe,
    calories_kcal: caloriesKcal,
    protein_g: isFiniteMacroValue(normalizedRecipe?.protein_g) ? Number(normalizedRecipe.protein_g) : fallback.protein_g,
    carbs_g: isFiniteMacroValue(normalizedRecipe?.carbs_g) ? Number(normalizedRecipe.carbs_g) : fallback.carbs_g,
    fat_g: isFiniteMacroValue(normalizedRecipe?.fat_g) ? Number(normalizedRecipe.fat_g) : fallback.fat_g,
    est_calories_text: normalizeText(normalizedRecipe?.est_calories_text) || `${caloriesKcal} kcal per serving (estimate)`,
  };
}

async function guaranteeRecipeDisplayMacros(normalizedRecipe) {
  let nextRecipe = await maybeFillMissingMacros(normalizedRecipe ?? {});
  if (!hasCompleteDisplayMacros(nextRecipe)) {
    nextRecipe = fillRecipeMacrosWithDisplayFallback(nextRecipe);
  }
  return nextRecipe;
}

function missingDisplayMacroPatch(existingRecipe, candidateRecipe) {
  const patch = {};
  for (const field of ["calories_kcal", "protein_g", "carbs_g", "fat_g"]) {
    if (!isFiniteMacroValue(existingRecipe?.[field]) && isFiniteMacroValue(candidateRecipe?.[field])) {
      patch[field] = Number(candidateRecipe[field]);
    }
  }
  if (!normalizeText(existingRecipe?.est_calories_text) && normalizeText(candidateRecipe?.est_calories_text)) {
    patch.est_calories_text = normalizeText(candidateRecipe.est_calories_text);
  }
  return patch;
}

async function buildNormalizedRecipe(source, { accessToken = null, jobID = null } = {}) {
  const directStructured = source.structured_recipe
    ? coerceStructuredRecipeCandidate(
        {
          title: source.structured_recipe.name ?? source.title,
          description: source.structured_recipe.description ?? source.meta_description,
          author_name: source.author_name,
          author_handle: source.author_handle,
          author_url: source.author_url,
          source: source.site_name ?? source.platform,
          source_platform: source.platform,
          category: Array.isArray(source.structured_recipe.recipeCategory) ? source.structured_recipe.recipeCategory[0] : source.structured_recipe.recipeCategory,
          recipe_type: Array.isArray(source.structured_recipe.recipeCategory) ? source.structured_recipe.recipeCategory[0] : source.structured_recipe.recipeCategory,
          servings_text: Array.isArray(source.structured_recipe.recipeYield) ? source.structured_recipe.recipeYield[0] : source.structured_recipe.recipeYield,
          prep_time_iso: source.structured_recipe.prepTime,
          cook_time_iso: source.structured_recipe.cookTime,
          total_time_iso: source.structured_recipe.totalTime,
          hero_image_url: Array.isArray(source.structured_recipe.image)
            ? source.structured_recipe.image[0]
            : typeof source.structured_recipe.image === "string"
              ? source.structured_recipe.image
              : source.hero_image_url,
          recipe_url: source.source_url,
          original_recipe_url: source.canonical_url,
          attached_video_url: source.attached_video_url,
          cuisine_tags: uniqueStrings(Array.isArray(source.structured_recipe.recipeCuisine) ? source.structured_recipe.recipeCuisine : [source.structured_recipe.recipeCuisine]),
          ingredients: source.structured_recipe.recipeIngredient ?? [],
          steps: (source.structured_recipe.recipeInstructions ?? []).map((text, index) => ({
            number: index + 1,
            text,
          })),
          calories_kcal: Number.parseFloat(String(source.structured_recipe?.nutrition?.calories ?? "").replace(/[^\d.]+/g, "")) || null,
        },
        source
      )
    : null;

  const structuredIsStrong = directStructured
    && directStructured.title
    && directStructured.ingredients.length >= 3
    && directStructured.steps.length >= 2;

  const modelResult = structuredIsStrong
    ? { recipe: directStructured, quality_flags: [], review_reason: null }
    : source.source_type === "media_image"
      ? await synthesizeRecipeFromPhoto(source, { jobID })
      : source.source_type === "concept_prompt"
      ? await synthesizeRecipeFromPrompt(source)
      : source.source_type === "recipe_search"
        ? await synthesizeRecipeFromRecipeSearch(source)
        : await extractRecipeWithModel(source);

  let normalized = coerceStructuredRecipeCandidate(modelResult.recipe ?? {}, source);
  let secondaryFillApplied = false;
  const usedConceptFallback = source.source_type === "concept_prompt" && !hasUsableRecipeCore(modelResult.recipe ?? {});
  if (source.source_type === "concept_prompt" && (!normalized.ingredients.length || !normalized.steps.length)) {
    normalized = coerceStructuredRecipeCandidate(buildConceptFallbackRecipe(source), source);
  }
  normalized = await enrichRecipeLowRiskFields(normalized, source);
  if (source.source_type === "concept_prompt") {
    normalized = await repairSparseImportedRecipe(normalized, source);
    normalized = await enrichRecipeLowRiskFields(normalized, source);
    const completion = await completeImportedRecipeWithWebEvidence(normalized, source, { jobID });
    normalized = completion.recipe;
    modelResult.quality_flags = uniqueStrings([
      ...(modelResult.quality_flags ?? []),
      ...(completion.quality_flags ?? []),
      ...(completion.applied ? ["import_completion_applied"] : []),
    ]);
    modelResult.review_reason = completion.review_reason ?? modelResult.review_reason ?? null;
    const secondaryFill = await enrichRecipeSecondaryFields(normalized, source, { jobID });
    normalized = secondaryFill.recipe;
    secondaryFillApplied = secondaryFill.applied;
    const finalValidation = await validateAndRepairImportedRecipe(normalized, source, { jobID });
    normalized = finalValidation.recipe;
    modelResult.quality_flags = uniqueStrings([
      ...(modelResult.quality_flags ?? []),
      ...(finalValidation.quality_flags ?? []),
    ]);
    modelResult.review_reason = finalValidation.review_reason ?? modelResult.review_reason ?? null;
  }
  if (source.source_type !== "concept_prompt" && source.source_type !== "media_image") {
    normalized = await repairSparseImportedRecipe(normalized, source);
    normalized = await enrichRecipeLowRiskFields(normalized, source);
    const completion = await completeImportedRecipeWithWebEvidence(normalized, source, { jobID });
    normalized = completion.recipe;
    modelResult.quality_flags = uniqueStrings([
      ...(modelResult.quality_flags ?? []),
      ...(completion.quality_flags ?? []),
      ...(completion.applied ? ["import_completion_applied"] : []),
    ]);
    modelResult.review_reason = completion.review_reason ?? modelResult.review_reason ?? null;
    if (source.source_type === "recipe_search") {
      const verification = await verifyRecipeSearchSynthesis(normalized, source);
      normalized = coerceStructuredRecipeCandidate(verification.recipe ?? normalized, source);
      modelResult.quality_flags = uniqueStrings([
        ...(modelResult.quality_flags ?? []),
        ...(verification.quality_flags ?? []),
      ]);
      modelResult.review_reason = verification.review_reason ?? modelResult.review_reason ?? null;
    }
    const secondaryFill = await enrichRecipeSecondaryFields(normalized, source, { jobID });
    normalized = secondaryFill.recipe;
    secondaryFillApplied = secondaryFill.applied;
    const finalValidation = await validateAndRepairImportedRecipe(normalized, source, { jobID });
    normalized = finalValidation.recipe;
    modelResult.quality_flags = uniqueStrings([
      ...(modelResult.quality_flags ?? []),
      ...(finalValidation.quality_flags ?? []),
    ]);
    modelResult.review_reason = finalValidation.review_reason ?? modelResult.review_reason ?? null;
  }
  if (source.source_type === "media_image") {
    normalized = await repairSparseImportedRecipe(normalized, source);
    normalized = await enrichRecipeLowRiskFields(normalized, source);
    const completion = await completeImportedRecipeWithWebEvidence(normalized, source, { jobID });
    normalized = completion.recipe;
    modelResult.quality_flags = uniqueStrings([
      ...(modelResult.quality_flags ?? []),
      ...(completion.quality_flags ?? []),
      ...(completion.applied ? ["import_completion_applied"] : []),
    ]);
    modelResult.review_reason = completion.review_reason ?? modelResult.review_reason ?? null;
    const secondaryFill = await enrichRecipeSecondaryFields(normalized, source, { jobID });
    normalized = secondaryFill.recipe;
    secondaryFillApplied = secondaryFill.applied;
    const finalValidation = await validateAndRepairImportedRecipe(normalized, source, { jobID });
    normalized = finalValidation.recipe;
    modelResult.quality_flags = uniqueStrings([
      ...(modelResult.quality_flags ?? []),
      ...(finalValidation.quality_flags ?? []),
    ]);
    modelResult.review_reason = finalValidation.review_reason ?? modelResult.review_reason ?? null;
  }

  // Estimate macros if still missing after all enrichment passes.
  normalized = await guaranteeRecipeDisplayMacros(normalized);
  if (!hasCompleteDisplayMacros(modelResult.recipe ?? {}) && hasCompleteDisplayMacros(normalized)) {
    modelResult.quality_flags = uniqueStrings([...(modelResult.quality_flags ?? []), "macro_display_fallback"]);
  }

  const inferredDiscoverBrackets = sanitizeDiscoverBrackets(normalized, normalized.discover_brackets ?? []);
  const normalizedCategory = normalizeText(normalized.category ?? "");

  const _imgRecipeKey = normalized.title ?? source.title ?? source.canonical_url ?? source.source_url ?? source.source_type ?? "recipe";
  const _heroSrc = normalized.hero_image_url ?? normalized.discover_card_image_url ?? source.hero_image_url ?? source.meta_image_url ?? source.thumbnail_url ?? null;
  const _cardSrc = normalized.discover_card_image_url ?? normalized.hero_image_url ?? source.hero_image_url ?? source.meta_image_url ?? source.thumbnail_url ?? null;

  let persistedHeroImageURL, persistedCardImageURL;
  if (_heroSrc && _cardSrc && _heroSrc !== _cardSrc) {
    // Different source URLs — upload hero and card in parallel.
    [persistedHeroImageURL, persistedCardImageURL] = await Promise.all([
      persistRecipeImageToStorage(_heroSrc, { recipeKey: _imgRecipeKey, imageRole: "hero", accessToken }),
      persistRecipeImageToStorage(_cardSrc, { recipeKey: _imgRecipeKey, imageRole: "card", accessToken }),
    ]);
  } else {
    // Same source URL (or only one exists) — upload once and reuse.
    persistedHeroImageURL = await persistRecipeImageToStorage(_heroSrc, { recipeKey: _imgRecipeKey, imageRole: "hero", accessToken });
    persistedCardImageURL = persistedHeroImageURL;
  }

  normalized = {
    ...normalized,
    hero_image_url: persistedHeroImageURL ?? normalized.hero_image_url ?? null,
    discover_card_image_url: persistedCardImageURL ?? persistedHeroImageURL ?? normalized.discover_card_image_url ?? null,
  };

  // When the import still has no image (scraping couldn't extract one),
  // fall back to the most visually similar recipe already in the catalog.
  // This is a free DB lookup — no generation, no upload, no API cost.
  if (!normalized.hero_image_url && !normalized.discover_card_image_url) {
    try {
      const refRecipe = await fetchRecipeImageReference(normalized);
      const refImageURL = cleanURL(refRecipe?.hero_image_url ?? refRecipe?.discover_card_image_url ?? null);
      if (refImageURL) {
        normalized = {
          ...normalized,
          hero_image_url: refImageURL,
          discover_card_image_url: refImageURL,
        };
        modelResult.quality_flags = uniqueStrings([...(modelResult.quality_flags ?? []), "reference_image_fallback"]);
      }
    } catch {
      // Non-fatal — continue without image.
    }
  }

  if (isOunjeGeneratedSourceType(source.source_type)) {
    const shouldReplaceCategory = !normalizedCategory || ["concept_prompt", "direct_input", "text", "custom", "ounje"].includes(normalizedCategory.toLowerCase());
    normalized = {
      ...normalized,
      source: "Ounje",
      source_platform: "Ounje",
      category: shouldReplaceCategory ? (inferredDiscoverBrackets[0] ?? normalized.category ?? null) : normalized.category,
      discover_brackets: inferredDiscoverBrackets,
    };
  } else {
    normalized = {
      ...normalized,
      discover_brackets: inferredDiscoverBrackets,
    };
  }

  if (!normalized.title) {
    throw new Error("Could not extract a usable recipe title.");
  }

  if (!normalized.ingredients.length && !normalized.steps.length) {
    throw new Error("Could not extract ingredients or steps from this source.");
  }

  const assessment = assessRecipeQuality(
    normalized,
    {
      ...source,
      used_llm: !structuredIsStrong,
    }
  );
  const sourceProvenance = buildSourceProvenanceRecord(source, {
    reviewState: assessment.review_state,
    confidenceScore: assessment.confidence_score,
    qualityFlags: uniqueStrings([
      ...(modelResult.quality_flags ?? []),
      ...(usedConceptFallback ? ["concept_prompt_fallback"] : []),
      ...(secondaryFillApplied ? ["secondary_fill_applied"] : []),
      ...(assessment.quality_flags ?? []),
    ]),
    evidenceBundle: source.source_provenance_json ?? null,
  });

  return {
    normalized_recipe: {
      ...normalized,
      source_provenance_json: sourceProvenance,
    },
    quality_flags: uniqueStrings([
      ...(modelResult.quality_flags ?? []),
      ...(usedConceptFallback ? ["concept_prompt_fallback"] : []),
      ...(secondaryFillApplied ? ["secondary_fill_applied"] : []),
      ...(assessment.quality_flags ?? []),
    ]),
    confidence_score: assessment.confidence_score,
    review_state: assessment.review_state,
    review_reason: modelResult.review_reason ?? assessment.review_reason,
  };
}

function formatJobResponse(jobRow, extras = {}) {
  return {
    job: {
      id: jobRow.id,
      user_id: jobRow.user_id ?? null,
      target_state: jobRow.target_state,
      source_type: jobRow.source_type,
      source_url: jobRow.source_url ?? null,
      canonical_url: jobRow.canonical_url ?? null,
      evidence_bundle_id: jobRow.evidence_bundle_id ?? null,
      recipe_id: jobRow.recipe_id ?? null,
      status: jobRow.status,
      review_state: jobRow.review_state ?? "pending",
      confidence_score: jobRow.confidence_score ?? null,
      quality_flags: Array.isArray(jobRow.quality_flags) ? jobRow.quality_flags : [],
      review_reason: jobRow.review_reason ?? null,
      error_message: jobRow.error_message ?? null,
      attempts: jobRow.attempts ?? 0,
      queued_at: jobRow.queued_at ?? null,
      fetched_at: jobRow.fetched_at ?? null,
      parsed_at: jobRow.parsed_at ?? null,
      normalized_at: jobRow.normalized_at ?? null,
      saved_at: jobRow.saved_at ?? null,
      completed_at: jobRow.completed_at ?? null,
      event_log: Array.isArray(jobRow.event_log) ? jobRow.event_log : [],
    },
    ...extras,
  };
}

function isImportQueuedForWorker(jobRow) {
  return ["queued", "retryable"].includes(normalizeText(jobRow?.status).toLowerCase());
}

export async function queueRecipeIngestion(payload = {}, options = {}) {
  const requests = Array.isArray(payload.sources)
    ? payload.sources.map((entry) => normalizeImportPayload({ ...payload, ...entry }))
    : [normalizeImportPayload(payload)];

  const processInline = shouldProcessImportInline(payload, options);
  const results = [];

  for (const request of requests) {
    if (!request.source_url && !request.source_text && !(request.attachments ?? []).length) {
      throw new Error("Provide a source URL, pasted recipe text, or media attachment.");
    }
    if (!request.user_id && requiresUserScopedRecipeImport(request) && !allowsPublicCatalogRecipeImport(request)) {
      throw new Error("User ID is required for social recipe imports.");
    }

    // Keep enqueue fast and observable. Canonical expansion happens during worker processing.
    const queuedRequest = {
      ...request,
      source_url: request.source_url ?? null,
      canonical_url: request.source_url ?? null,
    };

    const job = await createJobRow(queuedRequest);
    if (isImportQueuedForWorker(job)) {
      void publishRedisJSON(RECIPE_IMPORT_WAKE_CHANNEL, {
        job_id: job.id,
        user_id: job.user_id ?? null,
        source_type: job.source_type ?? null,
        queued_at: nowIso(),
      });
    }
    if (processInline) {
      results.push(await processRecipeIngestionJob(job.id, { workerID: `api_${nanoid(8)}`, accessToken: queuedRequest.access_token ?? null }));
    } else {
      const processingMode = ["saved", "draft", "needs_review"].includes(normalizeText(job.status))
        ? "cached"
        : "queued";
      results.push(formatJobResponse(job, { processing_mode: processingMode }));
    }
  }

  return Array.isArray(payload.sources) ? results : results[0];
}

function shouldProcessImportInline(payload = {}, options = {}) {
  const allowInline = ["1", "true", "yes", "on"].includes(
    String(process.env.OUNJE_ALLOW_INLINE_RECIPE_IMPORT ?? "").trim().toLowerCase()
  ) && String(process.env.NODE_ENV ?? "development").trim().toLowerCase() !== "production";
  const requestedInline = payload.process_inline === true
    || payload.processInline === true
    || options.processInline === true;
  return allowInline && requestedInline;
}

export async function fetchRecipeIngestionJob(jobID) {
  const job = await fetchJobRow(jobID);
  if (!job) {
    throw new Error(`Ingestion job ${jobID} could not be found.`);
  }

  const [recipe, recipeDetail] = job.recipe_id
    ? await Promise.all([
        fetchRecipeCardProjection(job.recipe_id).catch(() => null),
        ["saved", "needs_review", "draft"].includes(normalizeText(job.status))
          ? fetchCanonicalRecipeDetailByID(job.recipe_id).catch(() => null)
          : Promise.resolve(null),
      ])
    : [null, null];
  return formatJobResponse(job, {
    recipe,
    recipe_detail: recipeDetail,
  });
}

export async function processRecipeIngestionJob(jobOrID, { workerID = `worker_${nanoid(8)}`, accessToken = null } = {}) {
  const existingJob = typeof jobOrID === "string" ? await fetchJobRow(jobOrID) : jobOrID;
  if (!existingJob) {
    throw new Error("Recipe ingestion job could not be found.");
  }

  const isAlreadyComplete = ["saved", "needs_review", "draft"].includes(normalizeText(existingJob.status));
  const processLockKey = isAlreadyComplete ? null : recipeImportLockKey("process", existingJob.id);
  const processLockToken = processLockKey
    ? await acquireRedisLock(processLockKey, IMPORT_PROCESS_LOCK_TTL_SECONDS)
    : null;
  if (processLockKey && !processLockToken) {
    const latestJob = await fetchJobRow(existingJob.id).catch(() => null);
    return formatJobResponse(latestJob ?? existingJob, { processing_mode: "locked" });
  }

  const stopHeartbeat = startRecipeIngestionHeartbeat(existingJob.id, workerID);
  try {
    return await withAIUsageContext({
    service: "recipe-ingestion",
    route: "worker:recipe-ingestion",
    operation: "recipe_ingestion_job",
    user_id: existingJob.user_id,
    job_id: existingJob.id,
    metadata: {
      worker_id: workerID,
      source_type: existingJob.source_type ?? null,
      target_state: existingJob.target_state ?? null,
    },
  }, async () => {
  if (["saved", "needs_review", "draft"].includes(existingJob.status)) {
    const recipe = existingJob.recipe_id ? await fetchRecipeCardProjection(existingJob.recipe_id) : null;
    return formatJobResponse(existingJob, { recipe });
  }

  let requestPayload = normalizeImportPayload({
    user_id: existingJob.user_id,
    ...(existingJob.request_payload ?? {}),
    source_type: existingJob.source_type,
    source_url: existingJob.canonical_url ?? existingJob.source_url,
    target_state: existingJob.target_state,
    source_text: existingJob.input_text ?? existingJob.request_payload?.source_text ?? "",
  });
  requestPayload = {
    ...requestPayload,
    source_url: await expandCanonicalSourceURL(requestPayload.source_url, requestPayload.source_type) ?? requestPayload.source_url ?? null,
  };
  const canonicalDedupeKey = buildDedupeKey({
    sourceUrl: existingJob.source_url ?? requestPayload.source_url,
    canonicalUrl: requestPayload.source_url,
    sourceText: requestPayload.source_text,
  });
  const lookupRequest = {
    ...requestPayload,
    source_url: existingJob.source_url ?? requestPayload.source_url,
    canonical_url: requestPayload.source_url,
  };
  requestPayload = {
    ...requestPayload,
    access_token: accessToken ?? requestPayload.access_token ?? null,
  };
  if (!requestPayload.user_id
    && requiresUserScopedRecipeImport(requestPayload)
    && !allowsPublicCatalogRecipeImport(existingJob.request_payload ?? requestPayload)) {
    const failed = await appendJobEvent(existingJob.id, "rejected_user_scoped_import_without_user", {
      worker_id: workerID,
      source_type: requestPayload.source_type,
    }, {
      status: "failed",
      worker_id: workerID,
      leased_at: null,
      completed_at: nowIso(),
      error_message: "User ID is required for social recipe imports.",
      review_state: "rejected",
      review_reason: "Social/video/photo imports are user-scoped and cannot write to the public recipe catalog.",
    });
    return formatJobResponse(failed);
  }
  const nextAttempt = existingJob.status === "processing"
    ? Number(existingJob.attempts ?? 1)
    : Number(existingJob.attempts ?? 0) + 1;

  let job = await appendJobEvent(existingJob.id, "fetching", { worker_id: workerID }, {
    status: "fetching",
    worker_id: workerID,
    leased_at: nowIso(),
    attempts: nextAttempt,
  });

  try {
    if (requestPayload.source_url && requestPayload.source_url !== existingJob.canonical_url) {
      await patchRecipeIngestionJobRow(existingJob.id, {
        canonical_url: requestPayload.source_url,
        dedupe_key: canonicalDedupeKey ?? existingJob.dedupe_key ?? null,
        request_payload: {
          ...(existingJob.request_payload ?? {}),
          canonical_url: requestPayload.source_url,
          source_url: existingJob.source_url ?? requestPayload.source_url,
        },
      }).catch(() => {});
    }

    const cachedCanonical = await findCompletedCanonicalImportForRequest(lookupRequest, {
      canonicalURL: requestPayload.source_url,
      dedupeKey: canonicalDedupeKey,
      excludeJobID: existingJob.id,
    });
    if (cachedCanonical) {
      return await completeJobFromCachedCanonicalImport(existingJob, cachedCanonical, {
        workerID,
        canonicalURL: requestPayload.source_url,
      });
    }

    const existingImportedRecipe = await findExistingUserImportedRecipeForRequest(lookupRequest, {
      canonicalURL: requestPayload.source_url,
      dedupeKey: canonicalDedupeKey,
    });
    if (existingImportedRecipe) {
      return await completeJobFromExistingImportedRecipe(existingJob, existingImportedRecipe, {
        workerID,
        canonicalURL: requestPayload.source_url,
        dedupeKey: canonicalDedupeKey,
      });
    }

    const globalCachedCanonical = await findCompletedCanonicalImportForRequest(lookupRequest, {
      canonicalURL: requestPayload.source_url,
      dedupeKey: canonicalDedupeKey,
      excludeJobID: existingJob.id,
      scope: "global",
    });
    if (globalCachedCanonical) {
      const sameUser = normalizeText(globalCachedCanonical.user_id) === normalizeText(existingJob.user_id);
      if (sameUser) {
        return await completeJobFromCachedCanonicalImport(existingJob, globalCachedCanonical, {
          workerID,
          canonicalURL: requestPayload.source_url,
        });
      }
      const cloned = await completeJobByCloningGlobalImportedRecipe(existingJob, globalCachedCanonical, {
        workerID,
        canonicalURL: requestPayload.source_url,
        dedupeKey: canonicalDedupeKey,
      });
      if (cloned) return cloned;
    }

    const resumedSourceArtifact = await fetchLatestJobArtifact(existingJob.id, "source_evidence_bundle").catch(() => null);
    let source = resumedSourceArtifact?.raw_json && existingJob.fetched_at
      ? {
          ...(resumedSourceArtifact.raw_json ?? {}),
          source_provenance_json: resumedSourceArtifact.raw_json,
        }
      : await extractSourceMaterial(requestPayload);

    if (resumedSourceArtifact?.raw_json && existingJob.fetched_at) {
      job = await appendJobEvent(existingJob.id, "resumed_from_source_evidence", {
        worker_id: workerID,
        artifact_id: resumedSourceArtifact.id,
      }, {
        status: "fetching",
        canonical_url: source.canonical_url ?? requestPayload.source_url,
        fetched_at: existingJob.fetched_at,
      });
    }

    const resumedNormalizedArtifact = await fetchLatestJobArtifact(existingJob.id, "normalized_recipe").catch(() => null);
    const hasResumableNormalizedRecipe = Boolean(resumedNormalizedArtifact?.raw_json && existingJob.normalized_at);

    if (!hasResumableNormalizedRecipe && source.source_type === "media_image" && source.photo_meal_gate && !source.photo_meal_gate.is_meal) {
      const evidenceBundle = await storeEvidenceBundle(existingJob.id, source.source_provenance_json ?? buildSourceProvenanceRecord(source));
      for (const artifact of source.artifacts ?? []) {
        await storeArtifact(existingJob.id, artifact).catch(() => {});
      }
      await storeArtifact(existingJob.id, {
        artifact_type: "source_evidence_bundle",
        content_type: "application/json",
        source_url: source.canonical_url ?? requestPayload.source_url ?? null,
        raw_json: compactJSON(source.source_type === "media_image"
          ? {
              ...source,
              photo_image_inputs: (source.photo_image_inputs ?? []).map((entry) => ({
                ...entry,
                data_url: entry.data_url ? "[omitted]" : null,
              })),
            }
          : (evidenceBundle.evidence_json ?? evidenceBundle)),
        metadata: {
          evidence_bundle_id: evidenceBundle.id,
          source_type: source.source_type ?? null,
        },
      }).catch(() => {});
      const completedAt = nowIso();
      job = await appendJobEvent(existingJob.id, "photo_needs_review", {
        worker_id: workerID,
        reason: source.photo_meal_gate.reject_reason,
        confidence: source.photo_meal_gate.confidence,
      }, {
        status: "needs_review",
        canonical_url: source.canonical_url ?? requestPayload.source_url,
        evidence_bundle_id: evidenceBundle.id,
        fetched_at: nowIso(),
        completed_at: completedAt,
        review_state: "needs_review",
        review_reason: source.photo_meal_gate.reject_reason ?? "The photo does not appear to be a prepared meal.",
        quality_flags: uniqueStrings([...(existingJob.quality_flags ?? []), "photo_meal_gate_rejected"]),
      });
      return formatJobResponse(job);
    }

    if (!hasResumableNormalizedRecipe && ["tiktok", "instagram", "youtube", "media_video"].includes(source.source_type)) {
      const recipeGate = await assessRecipeLikelihood(source);
      await storeArtifact(existingJob.id, {
        artifact_type: "recipe_gate_assessment",
        content_type: "application/json",
        source_url: source.canonical_url ?? requestPayload.source_url ?? null,
        raw_json: compactJSON(recipeGate),
        metadata: {
          is_recipe: recipeGate.is_recipe,
          confidence: recipeGate.confidence,
          reason: recipeGate.reason,
          method: recipeGate.method,
        },
      }).catch(() => {});
      if (!recipeGate.is_recipe) {
        if (socialSourceHasFoodIdentity(source)) {
          const referenceQuery = buildReferenceRecipeQueryFromSocialSource(source);
          let referenceSource = null;
          if (referenceQuery) {
            referenceSource = await extractRecipeSearchSource(referenceQuery, [], {
              source,
              jobID: existingJob.id,
            }).catch((error) => ({
              source_type: "recipe_search",
              platform: "web_search_from_social_reference",
              source_url: null,
              canonical_url: null,
              raw_text: referenceQuery,
              title: referenceQuery.replace(/\s+recipe$/i, ""),
              description: null,
              hero_image_url: source.hero_image_url ?? source.thumbnail_url ?? null,
              discover_card_image_url: source.hero_image_url ?? source.thumbnail_url ?? null,
              attachments: [],
              recipe_sources: [],
              source_provenance_json: buildSourceProvenanceRecord({
                source_type: "recipe_search",
                platform: "web_search_from_social_reference",
                title: referenceQuery,
              }, {
                evidenceBundle: {
                  query: referenceQuery,
                  original_social_gate: recipeGate,
                  search_error: errorSummary(error),
                },
              }),
              artifacts: [],
            }));
          }

          if (referenceSource) {
            source = {
              ...referenceSource,
              platform: "web_search_from_social_reference",
              original_social_source: {
                source_type: source.source_type ?? null,
                platform: source.platform ?? null,
                source_url: source.source_url ?? null,
                canonical_url: source.canonical_url ?? null,
                title: source.title ?? null,
                description: source.description ?? source.meta_description ?? null,
                author_name: source.author_name ?? null,
                author_handle: source.author_handle ?? null,
                recipe_gate: recipeGate,
              },
            };
            job = await appendJobEvent(existingJob.id, "not_recipe_converted_to_reference_recipe", {
              worker_id: workerID,
              reason: recipeGate.reason,
              confidence: recipeGate.confidence,
              method: recipeGate.method,
              reference_query: referenceQuery,
              reference_count: Array.isArray(referenceSource.recipe_sources) ? referenceSource.recipe_sources.length : 0,
            }, {
              quality_flags: uniqueStrings([...(existingJob.quality_flags ?? []), "social_reference_recipe"]),
            });
          } else if (shouldContinueRecipeImportDespiteGate(recipeGate, source)) {
            job = await appendJobEvent(existingJob.id, "not_recipe_gate_overridden", {
              worker_id: workerID,
              reason: recipeGate.reason,
              confidence: recipeGate.confidence,
              method: recipeGate.method,
            }, {
              quality_flags: uniqueStrings([...(existingJob.quality_flags ?? []), "recipe_lead_gate_override"]),
            });
          } else {
            const completedAt = nowIso();
            job = await appendJobEvent(existingJob.id, "failed_not_recipe", {
              worker_id: workerID,
              reason: recipeGate.reason,
              confidence: recipeGate.confidence,
              method: recipeGate.method,
            }, {
              status: "failed",
              canonical_url: source.canonical_url ?? requestPayload.source_url,
              fetched_at: nowIso(),
              completed_at: completedAt,
              error_message: "Source does not appear to be a recipe.",
              review_state: "needs_review",
              review_reason: recipeGate.reason,
              quality_flags: uniqueStrings([...(existingJob.quality_flags ?? []), "not_recipe"]),
            });
            return formatJobResponse(job);
          }
        } else if (shouldContinueRecipeImportDespiteGate(recipeGate, source)) {
          job = await appendJobEvent(existingJob.id, "not_recipe_gate_overridden", {
            worker_id: workerID,
            reason: recipeGate.reason,
            confidence: recipeGate.confidence,
            method: recipeGate.method,
          }, {
            quality_flags: uniqueStrings([...(existingJob.quality_flags ?? []), "recipe_lead_gate_override"]),
          });
        } else {
          const completedAt = nowIso();
          job = await appendJobEvent(existingJob.id, "failed_not_recipe", {
            worker_id: workerID,
            reason: recipeGate.reason,
            confidence: recipeGate.confidence,
            method: recipeGate.method,
          }, {
            status: "failed",
            canonical_url: source.canonical_url ?? requestPayload.source_url,
            fetched_at: nowIso(),
            completed_at: completedAt,
            error_message: "Source does not appear to be a recipe.",
            review_state: "needs_review",
            review_reason: recipeGate.reason,
            quality_flags: uniqueStrings([...(existingJob.quality_flags ?? []), "not_recipe"]),
          });
          return formatJobResponse(job);
        }
      }
    }

    if (!resumedSourceArtifact?.raw_json || !existingJob.fetched_at) {
      const evidenceBundle = await storeEvidenceBundle(existingJob.id, source.source_provenance_json ?? buildSourceProvenanceRecord(source));
      job = await appendJobEvent(existingJob.id, "evidence_bundle_stored", {
        worker_id: workerID,
        evidence_bundle_id: evidenceBundle.id,
      }, {
        evidence_bundle_id: evidenceBundle.id,
      });
      for (const artifact of source.artifacts ?? []) {
        await storeArtifact(existingJob.id, artifact);
      }
      await storeArtifact(existingJob.id, {
        artifact_type: "source_evidence_bundle",
        content_type: "application/json",
        source_url: source.canonical_url ?? requestPayload.source_url ?? null,
        raw_json: compactJSON(source.source_type === "media_image"
          ? {
              ...source,
              photo_image_inputs: (source.photo_image_inputs ?? []).map((entry) => ({
                ...entry,
                data_url: entry.data_url ? "[omitted]" : null,
              })),
            }
          : (evidenceBundle.evidence_json ?? evidenceBundle)),
        metadata: {
          evidence_bundle_id: evidenceBundle.id,
          source_type: source.source_type ?? null,
          frame_count: evidenceBundle.frame_count ?? null,
        },
      });
    }

    job = await appendJobEvent(existingJob.id, "parsing", { worker_id: workerID }, {
      status: "parsing",
      canonical_url: source.canonical_url ?? requestPayload.source_url,
      fetched_at: existingJob.fetched_at ?? nowIso(),
    });

    const extraction = hasResumableNormalizedRecipe
      ? {
          normalized_recipe: resumedNormalizedArtifact.raw_json,
          quality_flags: Array.isArray(resumedNormalizedArtifact.metadata?.quality_flags)
            ? resumedNormalizedArtifact.metadata.quality_flags
            : uniqueStrings([...(existingJob.quality_flags ?? []), "resumed_normalized_recipe"]),
          confidence_score: Number.isFinite(Number(resumedNormalizedArtifact.metadata?.confidence_score))
            ? Number(resumedNormalizedArtifact.metadata.confidence_score)
            : existingJob.confidence_score ?? 0.72,
          review_state: normalizeText(resumedNormalizedArtifact.metadata?.review_state ?? existingJob.review_state) || "approved",
          review_reason: resumedNormalizedArtifact.metadata?.review_reason ?? existingJob.review_reason ?? null,
        }
      : await buildNormalizedRecipe(source, {
        accessToken: requestPayload.access_token ?? null,
        jobID: existingJob.id,
      });

    if (hasResumableNormalizedRecipe) {
      job = await appendJobEvent(existingJob.id, "resumed_from_normalized_recipe", {
        worker_id: workerID,
        artifact_id: resumedNormalizedArtifact.id,
      }, {
        status: "normalized",
        canonical_url: source.canonical_url ?? requestPayload.source_url,
        normalized_at: existingJob.normalized_at,
      });
    } else {
      await storeArtifact(existingJob.id, {
        artifact_type: "normalized_recipe",
        content_type: "application/json",
        raw_json: compactJSON(extraction.normalized_recipe),
        metadata: {
          quality_flags: extraction.quality_flags,
          confidence_score: extraction.confidence_score,
          review_state: extraction.review_state,
          review_reason: extraction.review_reason,
        },
      });
    }

    job = await appendJobEvent(existingJob.id, "normalized", {
      confidence_score: extraction.confidence_score,
      review_state: extraction.review_state,
    }, {
      status: "normalized",
      canonical_url: source.canonical_url ?? requestPayload.source_url,
      normalized_at: nowIso(),
      confidence_score: extraction.confidence_score,
      quality_flags: extraction.quality_flags,
      review_state: extraction.review_state,
      review_reason: extraction.review_reason,
    });

    const persisted = await persistNormalizedRecipe(extraction.normalized_recipe, {
      userID: existingJob.user_id,
      targetState: existingJob.target_state,
      sourceJobID: existingJob.id,
      dedupeKey: canonicalDedupeKey ?? existingJob.dedupe_key ?? requestPayload.source_url ?? null,
      reviewState: extraction.review_state,
      confidenceScore: extraction.confidence_score,
      qualityFlags: extraction.quality_flags,
    });

    const finalStatus = "saved";
    job = await appendJobEvent(existingJob.id, finalStatus, {
      recipe_id: persisted.recipe_id,
      deduped: persisted.saved_state === "deduped",
      review_state: extraction.review_state,
    }, {
      status: finalStatus,
      recipe_id: persisted.recipe_id,
      dedupe_recipe_id: persisted.saved_state === "deduped" ? persisted.recipe_id : null,
      saved_at: nowIso(),
      completed_at: nowIso(),
      error_message: null,
    });

    // Populate in-memory canonical URL cache so repeat imports of the same URL
    // short-circuit instantly without a DB round-trip.
    _setCanonicalImportCache(
      existingJob.user_id,
      requestPayload.source_url ?? existingJob.canonical_url ?? null,
      canonicalDedupeKey ?? existingJob.dedupe_key ?? null,
      job
    );
    _setCanonicalImportCache(
      GLOBAL_IMPORT_CACHE_NAMESPACE,
      requestPayload.source_url ?? existingJob.canonical_url ?? null,
      canonicalDedupeKey ?? existingJob.dedupe_key ?? null,
      job
    );
    await warmRecipeDetailCache({
      userID: existingJob.user_id,
      recipeID: persisted.recipe_id,
      recipeDetail: persisted.recipe_detail,
    });
    if (existingJob.user_id && persisted.saved_state === "inserted") {
      scheduleUserImportEmbedding(persisted.recipe_id, persisted.recipe_detail, { jobID: existingJob.id });
    }
    invalidateUserBootstrapCache(existingJob.user_id);

    return formatJobResponse(job, {
      recipe: persisted.recipe_card,
      recipe_detail: persisted.recipe_detail,
    });
  } catch (error) {
    const quotaError = isOpenAIQuotaError(error);
    const modelError = isOpenAITerminalModelError(error);
    const terminal = quotaError || modelError || nextAttempt >= Number(existingJob.max_attempts ?? 3);
    job = await appendJobEvent(existingJob.id, terminal ? "failed" : "retryable", {
      worker_id: workerID,
      error_message: error.message,
      terminal_reason: quotaError
        ? "openai_quota_or_rate_limit"
        : modelError
          ? "openai_model_error"
          : null,
    }, {
      status: terminal ? "failed" : "retryable",
      completed_at: terminal ? nowIso() : null,
      error_message: error.message,
    });

    if (terminal) {
      return formatJobResponse(job);
    }

    throw error;
  }
  });
  } finally {
    stopHeartbeat();
    if (processLockToken) {
      void releaseRedisLock(processLockKey, processLockToken);
    }
  }
}

export async function runRecipeIngestionWorkerBatch({ workerID = `daemon_${nanoid(8)}`, batchSize = 3 } = {}) {
  const lockKey = "recipe-ingestion:worker-batch";
  const lockToken = await acquireRedisLock(lockKey, 55);
  if (!lockToken && process.env.REDIS_URL && !REDIS_DISABLED_FOR_INGESTION_LOCK) {
    return 0;
  }

  try {
    const claimed = await callRpc("claim_recipe_ingestion_jobs", {
      p_worker_id: workerID,
      p_batch_size: batchSize,
    });
    const jobs = Array.isArray(claimed) ? claimed : [];
    const concurrency = Math.max(
      1,
      Math.min(Number(batchSize) || 1, RECIPE_INGESTION_WORKER_CONCURRENCY)
    );
    let processed = 0;
    const queue = [...jobs];

    async function runWorkerLoop() {
      while (queue.length > 0) {
        const job = queue.shift();
        if (!job) break;
        try {
          await processRecipeIngestionJob(job, { workerID });
        } catch (error) {
          console.warn(`[recipe-ingestion] job ${job.id} failed on this pass:`, error.message);
        } finally {
          processed += 1;
        }
      }
    }

    await Promise.all(
      Array.from({ length: concurrency }, () => runWorkerLoop())
    );

    return processed;
  } finally {
    if (lockToken) {
      void releaseRedisLock(lockKey, lockToken);
    }
  }
}

export {
  RECIPE_IMPORT_WAKE_CHANNEL,
  RECIPE_GATE_MODEL,
  RECIPE_IMPORT_COMPLETION_MODEL,
  RECIPE_INGESTION_MODEL,
  RECIPE_SEARCH_SYNTHESIS_MODEL,
  PHOTO_MEAL_GATE_MODEL,
  maybeGenerateImportedRecipeImage,
  buildFinalRecipeValidationIssues,
  buildDedupeKey,
  canonicalImportIdentityForURL,
  estimateRecipeMacrosLocally,
  extractRecipeSearchSource,
  fillRecipeMacrosWithDisplayFallback,
  guaranteeRecipeDisplayMacros,
  hasCompleteDisplayMacros,
  persistNormalizedRecipe,
  recipeNeedsCompletionPass,
  recipeNeedsSecondaryFill,
  requiresUserScopedRecipeImport,
  shouldProcessImportInline,
  isCanonicalCacheableSource,
  isOpenAITerminalModelError,
  isResumableIngestionJob,
};
