#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { repairStaleRecipeIngestionJobs } from "../lib/recipe-ingestion.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

function argValue(name, fallback = null) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  return process.argv[index + 1] ?? fallback;
}

const dryRun = process.argv.includes("--dry-run");
const staleAfterMinutes = Number.parseInt(argValue("--stale-after-minutes", "15"), 10) || 15;
const limit = Number.parseInt(argValue("--limit", "50"), 10) || 50;
const workerID = argValue("--worker-id", "recipe_ingestion_maintenance");

const result = await repairStaleRecipeIngestionJobs({
  staleAfterMinutes,
  limit,
  dryRun,
  workerID,
});

console.log(JSON.stringify(result, null, 2));
