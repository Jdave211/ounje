// Model + provider configuration for the recipe ingestion pipeline.
//
// This is the foundation module of the ingestion split: it has no dependencies on
// the rest of the pipeline (only process.env), so every other ingestion module can
// import from it without creating import cycles. It loads the local .env itself
// because ESM evaluates imported modules before the importer's body runs — if it
// relied on a caller to call dotenv.config() first, env overrides would be missed.

import path from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// server/lib/ingestion -> server/.env
dotenv.config({ path: path.resolve(__dirname, "../../.env") });

export const RECIPE_INGESTION_MODEL = process.env.RECIPE_INGESTION_MODEL ?? "gpt-4o-mini";
export const RECIPE_SEARCH_SYNTHESIS_MODEL = process.env.RECIPE_SEARCH_SYNTHESIS_MODEL ?? "gpt-5-nano";
export const RECIPE_IMPORT_COMPLETION_MODEL = process.env.RECIPE_IMPORT_COMPLETION_MODEL ?? "gpt-5-nano";
export const RECIPE_WEB_REFERENCE_MODEL = process.env.RECIPE_WEB_REFERENCE_MODEL ?? "gpt-5-nano";
export const RECIPE_FINAL_VALIDATOR_MODEL = process.env.RECIPE_FINAL_VALIDATOR_MODEL ?? RECIPE_IMPORT_COMPLETION_MODEL;
export const RECIPE_GATE_MODEL = process.env.RECIPE_GATE_MODEL ?? "gpt-5-nano";
export const PHOTO_RECIPE_VISION_MODEL = process.env.PHOTO_RECIPE_VISION_MODEL ?? RECIPE_INGESTION_MODEL;
export const PHOTO_MEAL_GATE_MODEL = process.env.PHOTO_MEAL_GATE_MODEL ?? PHOTO_RECIPE_VISION_MODEL;
export const PHOTO_RECIPE_CLEANUP_MODEL = process.env.PHOTO_RECIPE_CLEANUP_MODEL ?? RECIPE_IMPORT_COMPLETION_MODEL;
export const PHOTO_RECIPE_SONAR_MODEL = process.env.PHOTO_RECIPE_SONAR_MODEL ?? "sonar";
export const SHORT_VIDEO_TRANSCRIBE_MODEL = process.env.SHORT_VIDEO_TRANSCRIBE_MODEL ?? "gpt-4o-mini-transcribe";
