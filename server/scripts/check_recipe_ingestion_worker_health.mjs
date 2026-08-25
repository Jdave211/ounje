#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const { repairStaleRecipeIngestionJobs, runRecipeIngestionWorkerBatch } = await import("../lib/recipe-ingestion.js");
const { getRedisClient, redisConfigStatus } = await import("../lib/redis-cache.js");
const { getServiceRoleSupabase } = await import("../lib/supabase-clients.js");

function argValue(name, fallback = null) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  return process.argv[index + 1] ?? fallback;
}

async function checkRedis() {
  try {
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
  } catch (error) {
    return { configured: true, ok: false, reason: error.message };
  }
}

function secondsSince(value) {
  const parsed = new Date(value).getTime();
  if (!Number.isFinite(parsed)) return null;
  return Math.max(0, Math.round((Date.now() - parsed) / 1000));
}

async function checkQueueAge(maxQueuedAgeSeconds) {
  const supabase = getServiceRoleSupabase();
  const { data, error } = await supabase
    .from("recipe_ingestion_jobs")
    .select("id,status,source_type,worker_id,queued_at,updated_at")
    .in("status", ["queued", "retryable"])
    .order("queued_at", { ascending: true })
    .limit(1);

  if (error) {
    return {
      ok: false,
      error: error.message,
    };
  }

  const oldest = Array.isArray(data) ? data[0] ?? null : null;
  if (!oldest) {
    return {
      ok: true,
      oldest: null,
      max_queued_age_seconds: maxQueuedAgeSeconds,
    };
  }

  const ageSeconds = secondsSince(oldest.queued_at ?? oldest.updated_at);
  return {
    ok: ageSeconds == null || ageSeconds <= maxQueuedAgeSeconds,
    oldest: {
      ...oldest,
      queued_age_seconds: ageSeconds,
    },
    max_queued_age_seconds: maxQueuedAgeSeconds,
  };
}

const staleAfterMinutes = Number.parseInt(argValue("--stale-after-minutes", "15"), 10) || 15;
const staleLimit = Number.parseInt(argValue("--stale-limit", "25"), 10) || 25;
const maxQueuedAgeSeconds = Number.parseInt(argValue("--max-queued-age-seconds", "180"), 10) || 180;
const badWorkerProcessed = await runRecipeIngestionWorkerBatch({
  workerID: "api_health_check",
  batchSize: 1,
});
const stale = await repairStaleRecipeIngestionJobs({
  staleAfterMinutes,
  limit: staleLimit,
  dryRun: false,
  workerID: "recipe_ingestion_health_check",
});
const redis = await checkRedis();
const queueBeforeRecovery = await checkQueueAge(maxQueuedAgeSeconds);
let fallbackProcessed = 0;
let fallbackError = null;
if (!queueBeforeRecovery.ok) {
  try {
    fallbackProcessed = await runRecipeIngestionWorkerBatch({
      workerID: "render_recipe_ingest_health",
      batchSize: 2,
    });
  } catch (error) {
    fallbackError = error.message;
  }
}
const queue = await checkQueueAge(maxQueuedAgeSeconds);
const ok = badWorkerProcessed === 0 && queue.ok && fallbackError == null;

console.log(JSON.stringify({
  ok,
  degraded: !redis.ok,
  redis,
  queue,
  queue_before_recovery: queueBeforeRecovery,
  fallback_processed: fallbackProcessed,
  fallback_error: fallbackError,
  bad_worker_claim_blocked: badWorkerProcessed === 0,
  bad_worker_processed: badWorkerProcessed,
  stale,
}, null, 2));

process.exit(ok ? 0 : 1);
