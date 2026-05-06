import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import OpenAI from "openai";
import dotenv from "dotenv";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REGISTRY_PATH = path.resolve(__dirname, "../config/recipe-models.json");
dotenv.config({ path: path.resolve(__dirname, "../.env") });

const DEFAULT_REGISTRY = {
  version: 1,
  models: {
    discoverIntentModel: "gpt-4.1-mini",
    recipeRewriteBaseModel: "gpt-4.1-mini-2025-04-14",
    recipeRewriteActiveModel: null,
    recipeAdaptationModel: "gpt-4o-mini",
  },
  fineTune: {
    jobId: "",
    status: "idle",
    fineTunedModel: null,
    lastCheckedAt: null,
    completedAt: null,
    error: null,
    trainingFile: null,
    validationFile: null,
  },
};

let cachedRegistry = null;
let activePoller = null;
let refreshInFlight = null;

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function ensureRegistryFile() {
  if (!fs.existsSync(REGISTRY_PATH)) {
    fs.mkdirSync(path.dirname(REGISTRY_PATH), { recursive: true });
    fs.writeFileSync(REGISTRY_PATH, JSON.stringify(DEFAULT_REGISTRY, null, 2));
  }
}

export function readRecipeModelRegistry() {
  if (cachedRegistry) return clone(cachedRegistry);
  ensureRegistryFile();
  const parsed = JSON.parse(fs.readFileSync(REGISTRY_PATH, "utf8"));
  cachedRegistry = {
    ...clone(DEFAULT_REGISTRY),
    ...parsed,
    models: {
      ...DEFAULT_REGISTRY.models,
      ...(parsed.models ?? {}),
    },
    fineTune: {
      ...DEFAULT_REGISTRY.fineTune,
      ...(parsed.fineTune ?? {}),
    },
  };
  return clone(cachedRegistry);
}

export function writeRecipeModelRegistry(nextRegistry) {
  cachedRegistry = clone(nextRegistry);
  fs.mkdirSync(path.dirname(REGISTRY_PATH), { recursive: true });
  fs.writeFileSync(REGISTRY_PATH, JSON.stringify(cachedRegistry, null, 2));
  return clone(cachedRegistry);
}

export function updateRecipeModelRegistry(mutator) {
  const current = readRecipeModelRegistry();
  const draft = clone(current);
  const maybeNext = mutator(draft);
  const next = maybeNext ?? draft;
  return writeRecipeModelRegistry(next);
}

export function getActiveRecipeRewriteModel() {
  const registry = readRecipeModelRegistry();
  return registry.models.recipeRewriteActiveModel || registry.models.recipeRewriteBaseModel;
}

export function getRecipeAdaptationModel() {
  const envModel = String(process.env.RECIPE_ADAPTATION_MODEL ?? "").trim();
  if (envModel) return envModel;
  const registry = readRecipeModelRegistry();
  return registry.models.recipeAdaptationModel || "gpt-4o-mini";
}

export function getDiscoverIntentModel() {
  const registry = readRecipeModelRegistry();
  return registry.models.discoverIntentModel || "gpt-4.1-mini";
}

export async function refreshRecipeFineTuneStatus({ client = null } = {}) {
  if (refreshInFlight) return refreshInFlight;

  refreshInFlight = (async () => {
    const registry = readRecipeModelRegistry();
    const jobId = registry.fineTune.jobId;
    const apiKey = process.env.OPENAI_API_KEY ?? "";
    if (!jobId || !apiKey) return registry;

    const openai = client ?? new OpenAI({ apiKey });
    try {
      const job = await openai.fineTuning.jobs.retrieve(jobId);
      const normalizedError = job.error && Object.keys(job.error).length > 0
        ? (job.error.message ?? job.error)
        : null;
      const nextRegistry = updateRecipeModelRegistry((draft) => {
        draft.fineTune.status = job.status ?? draft.fineTune.status;
        draft.fineTune.lastCheckedAt = new Date().toISOString();
        draft.fineTune.error = normalizedError;
        draft.fineTune.trainingFile = job.training_file ?? draft.fineTune.trainingFile;
        draft.fineTune.validationFile = job.validation_file ?? draft.fineTune.validationFile;

        if (job.fine_tuned_model) {
          draft.fineTune.fineTunedModel = job.fine_tuned_model;
        }

        if (job.status === "succeeded" && job.fine_tuned_model) {
          draft.models.recipeRewriteActiveModel = job.fine_tuned_model;
          draft.fineTune.completedAt = draft.fineTune.completedAt ?? new Date().toISOString();
        }

        if (job.status === "failed") {
          draft.models.recipeRewriteActiveModel = draft.models.recipeRewriteActiveModel && draft.models.recipeRewriteActiveModel !== draft.fineTune.fineTunedModel
            ? draft.models.recipeRewriteActiveModel
            : null;
        }
      });
      return nextRegistry;
    } catch (error) {
      return updateRecipeModelRegistry((draft) => {
        draft.fineTune.lastCheckedAt = new Date().toISOString();
        draft.fineTune.error = error.message;
      });
    }
  })();

  try {
    return await refreshInFlight;
  } finally {
    refreshInFlight = null;
  }
}

export function startRecipeFineTunePolling({ intervalMs = 60_000 } = {}) {
  if (activePoller) return activePoller;

  refreshRecipeFineTuneStatus().catch((error) => {
    console.warn("[recipe-model-registry] initial refresh failed:", error.message);
  });

  activePoller = setInterval(() => {
    refreshRecipeFineTuneStatus().catch((error) => {
      console.warn("[recipe-model-registry] polling refresh failed:", error.message);
    });
  }, intervalMs);

  return activePoller;
}

export function stopRecipeFineTunePolling() {
  if (activePoller) clearInterval(activePoller);
  activePoller = null;
}
