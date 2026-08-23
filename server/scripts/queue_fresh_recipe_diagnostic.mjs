#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, "../.env") });

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? String(process.argv[index + 1] ?? "").trim() : "";
}

const sourceURL = argument("--url") || String(process.env.RECIPE_IMPORT_DIAGNOSTIC_URL ?? "").trim();
const userID = argument("--user-id") || String(process.env.RECIPE_IMPORT_DIAGNOSTIC_USER_ID ?? "").trim();

if (!sourceURL || !userID) {
  throw new Error("Provide --url and --user-id for a fresh diagnostic import.");
}

const { queueRecipeIngestion } = await import("../lib/recipe-ingestion.js");
const result = await queueRecipeIngestion({
  user_id: userID,
  source_url: sourceURL,
  target_state: "saved",
}, {
  forceReprocess: true,
  suppressNotifications: true,
});

console.log(JSON.stringify({
  job_id: result?.job?.id ?? null,
  status: result?.job?.status ?? null,
  processing_mode: result?.processing_mode ?? null,
}, null, 2));
