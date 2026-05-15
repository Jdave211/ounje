#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { repairStaleRecipeIngestionJobs, runRecipeIngestionWorkerBatch } from "../lib/recipe-ingestion.js";
import { getRedisClient, redisConfigStatus } from "../lib/redis-cache.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

function argValue(name, fallback = null) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  return process.argv[index + 1] ?? fallback;
}

async function checkRedis() {
  const status = redisConfigStatus();
  if (!status.configured) {
    return { configured: false, ok: false, reason: "REDIS_URL is not configured" };
  }

  const client = await getRedisClient();
  if (!client) {
    return { configured: true, ok: false, reason: "Redis client unavailable" };
  }

  const pong = await client.ping();
  return { configured: true, ok: pong === "PONG", pong };
}

const staleAfterMinutes = Number.parseInt(argValue("--stale-after-minutes", "15"), 10) || 15;
const staleLimit = Number.parseInt(argValue("--stale-limit", "25"), 10) || 25;
const badWorkerProcessed = await runRecipeIngestionWorkerBatch({
  workerID: "api_health_check",
  batchSize: 1,
});
const stale = await repairStaleRecipeIngestionJobs({
  staleAfterMinutes,
  limit: staleLimit,
  dryRun: true,
  workerID: "recipe_ingestion_health_check",
});
const redis = await checkRedis();
const ok = badWorkerProcessed === 0 && stale.actions.length === 0 && redis.ok;

console.log(JSON.stringify({
  ok,
  redis,
  bad_worker_claim_blocked: badWorkerProcessed === 0,
  bad_worker_processed: badWorkerProcessed,
  stale,
}, null, 2));

process.exit(ok ? 0 : 1);
