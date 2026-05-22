#!/usr/bin/env node
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { getServiceRoleSupabase } from "../lib/supabase-clients.js";
import {
  repairStaleRecipeIngestionJobs,
  runRecipeIngestionWorkerBatch,
} from "../lib/recipe-ingestion.js";
import { getRedisClient, redisConfigStatus } from "../lib/redis-cache.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const supabase = getServiceRoleSupabase();

function argValue(name, fallback = null) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  return process.argv[index + 1] ?? fallback;
}

function redact(value) {
  const raw = String(value ?? "").trim();
  if (raw.length <= 20) return raw;
  return `${raw.slice(0, 10)}...${raw.slice(-6)}`;
}

function isoMinutesAgo(minutes) {
  return new Date(Date.now() - minutes * 60_000).toISOString();
}

async function timed(label, fn) {
  const started = performance.now();
  try {
    const value = await fn();
    return {
      label,
      ok: true,
      ms: Math.round(performance.now() - started),
      value,
    };
  } catch (error) {
    return {
      label,
      ok: false,
      ms: Math.round(performance.now() - started),
      error: error?.message ?? String(error),
    };
  }
}

async function exactCount(table, filters = []) {
  let query = supabase.from(table).select("*", { count: "exact", head: true });
  for (const apply of filters) query = apply(query);
  const { count, error } = await query;
  if (error) throw error;
  return count ?? 0;
}

async function statusCounts(table, statuses, extraFilters = []) {
  const entries = await Promise.all(statuses.map(async (status) => {
    const count = await exactCount(table, [
      ...extraFilters,
      (query) => query.eq("status", status),
    ]);
    return [status, count];
  }));
  return Object.fromEntries(entries);
}

async function fetchRows(table, select, configure) {
  let query = supabase.from(table).select(select);
  query = configure(query);
  const { data, error } = await query;
  if (error) throw error;
  return data ?? [];
}

function summarizeJob(row) {
  return {
    id: row.id,
    user_id: redact(row.user_id),
    status: row.status,
    source_type: row.source_type,
    source_url: redact(row.source_url),
    canonical_url: redact(row.canonical_url),
    recipe_id: row.recipe_id,
    attempts: row.attempts,
    max_attempts: row.max_attempts,
    worker_id: row.worker_id,
    queued_at: row.queued_at,
    leased_at: row.leased_at,
    completed_at: row.completed_at,
    updated_at: row.updated_at,
    error_message: row.error_message,
    last_event: Array.isArray(row.event_log) ? row.event_log.at(-1) ?? null : null,
  };
}

function summarizeImport(row) {
  return {
    id: row.id,
    user_id: redact(row.user_id),
    source_job_id: row.source_job_id,
    title: row.title,
    source: row.source,
    recipe_url: redact(row.recipe_url),
    original_recipe_url: redact(row.original_recipe_url),
    attached_video_url: redact(row.attached_video_url),
    has_hero_image: Boolean(row.hero_image_url),
    has_card_image: Boolean(row.discover_card_image_url),
    calories_kcal: row.calories_kcal,
    protein_g: row.protein_g,
    carbs_g: row.carbs_g,
    fat_g: row.fat_g,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

async function redisHealth() {
  const status = redisConfigStatus();
  if (!status.configured) return { configured: false, ok: false };
  const client = await getRedisClient();
  if (!client) return { configured: true, ok: false, reason: "client unavailable" };
  const pong = await client.ping();
  return { configured: true, ok: pong === "PONG", pong };
}

const sourceNeedle = argValue("--source", "ZSxDxs84j");
const staleAfterMinutes = Number.parseInt(argValue("--stale-after-minutes", "15"), 10) || 15;
const staleCutoff = isoMinutesAgo(staleAfterMinutes);

const jobStatuses = [
  "queued",
  "retryable",
  "processing",
  "fetching",
  "parsing",
  "normalized",
  "saved",
  "draft",
  "needs_review",
  "failed",
];

const audit = {};

audit.redis = await timed("redis.ping", redisHealth);
audit.bad_worker_claim = await timed("claim_recipe_ingestion_jobs blocked for api worker", async () => {
  const processed = await runRecipeIngestionWorkerBatch({
    workerID: "api_db_audit",
    batchSize: 1,
  });
  return { processed, blocked: processed === 0 };
});
audit.stale_repair_dry_run = await timed("repair stale ingestion jobs dry-run", () => repairStaleRecipeIngestionJobs({
  staleAfterMinutes,
  limit: 100,
  dryRun: true,
  workerID: "recipe_ingestion_db_audit",
}));
audit.recipe_ping = await timed("recipes limit 1", () => fetchRows("recipes", "id", (query) => query.limit(1)));
audit.import_ping = await timed("user_import_recipes limit 1", () => fetchRows("user_import_recipes", "id", (query) => query.limit(1)));
audit.saved_ping = await timed("saved_recipes limit 1", () => fetchRows("saved_recipes", "recipe_id", (query) => query.limit(1)));
audit.cart_ping = await timed("main_shop_items limit 1", () => fetchRows("main_shop_items", "id", (query) => query.limit(1)));

audit.job_status_counts = await timed("recipe_ingestion_jobs status counts", () => statusCounts("recipe_ingestion_jobs", jobStatuses));
audit.recent_job_status_counts = await timed("recipe_ingestion_jobs recent status counts", () => statusCounts(
  "recipe_ingestion_jobs",
  jobStatuses,
  [(query) => query.gte("created_at", isoMinutesAgo(24 * 60))]
));
audit.queued_or_retryable_stale = await timed("queued/retryable older than stale cutoff", () => fetchRows(
  "recipe_ingestion_jobs",
  "id,user_id,target_state,source_type,source_url,canonical_url,recipe_id,status,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,completed_at,updated_at,event_log",
  (query) => query
    .in("status", ["queued", "retryable"])
    .lt("queued_at", staleCutoff)
    .order("queued_at", { ascending: true })
    .limit(25)
).then((rows) => rows.map(summarizeJob)));
audit.live_stale = await timed("live jobs stale lease", () => fetchRows(
  "recipe_ingestion_jobs",
  "id,user_id,target_state,source_type,source_url,canonical_url,recipe_id,status,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,completed_at,updated_at,event_log",
  (query) => query
    .in("status", ["processing", "fetching", "parsing", "normalized"])
    .not("leased_at", "is", null)
    .lt("leased_at", staleCutoff)
    .order("leased_at", { ascending: true })
    .limit(25)
).then((rows) => rows.map(summarizeJob)));
audit.source_match = await timed(`jobs matching ${sourceNeedle}`, async () => {
  const rows = await fetchRows(
    "recipe_ingestion_jobs",
    "id,user_id,target_state,source_type,source_url,canonical_url,recipe_id,status,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,completed_at,updated_at,event_log",
    (query) => query
      .or(`source_url.ilike.*${sourceNeedle}*,canonical_url.ilike.*${sourceNeedle}*,input_text.ilike.*${sourceNeedle}*`)
      .order("updated_at", { ascending: false })
      .limit(20)
  );
  return rows.map(summarizeJob);
});
audit.latest_jobs = await timed("latest ingestion jobs", () => fetchRows(
  "recipe_ingestion_jobs",
  "id,user_id,target_state,source_type,source_url,canonical_url,recipe_id,status,error_message,attempts,max_attempts,worker_id,leased_at,queued_at,completed_at,updated_at,event_log",
  (query) => query.order("updated_at", { ascending: false }).limit(20)
).then((rows) => rows.map(summarizeJob)));
audit.latest_imports = await timed("latest imported recipes", () => fetchRows(
  "user_import_recipes",
  "id,user_id,source_job_id,title,source,recipe_url,original_recipe_url,attached_video_url,hero_image_url,discover_card_image_url,calories_kcal,protein_g,carbs_g,fat_g,created_at,updated_at",
  (query) => query.order("updated_at", { ascending: false }).limit(20)
).then((rows) => rows.map(summarizeImport)));
audit.imports_missing_images = await timed("recent imports missing both image fields", () => fetchRows(
  "user_import_recipes",
  "id,user_id,source_job_id,title,source,recipe_url,original_recipe_url,attached_video_url,hero_image_url,discover_card_image_url,created_at,updated_at",
  (query) => query
    .is("hero_image_url", null)
    .is("discover_card_image_url", null)
    .order("updated_at", { ascending: false })
    .limit(20)
).then((rows) => rows.map(summarizeImport)));
audit.imports_missing_numeric_macros = await timed("recent imports missing numeric macros", () => fetchRows(
  "user_import_recipes",
  "id,user_id,source_job_id,title,source,recipe_url,original_recipe_url,attached_video_url,hero_image_url,discover_card_image_url,calories_kcal,protein_g,carbs_g,fat_g,created_at,updated_at",
  (query) => query
    .or("calories_kcal.is.null,protein_g.is.null,carbs_g.is.null,fat_g.is.null")
    .order("updated_at", { ascending: false })
    .limit(20)
).then((rows) => rows.map(summarizeImport)));
audit.saved_missing_images = await timed("saved rows missing both saved image snapshots", () => fetchRows(
  "saved_recipes",
  "user_id,recipe_id,title,hero_image_url,discover_card_image_url,saved_at,updated_at",
  (query) => query
    .is("hero_image_url", null)
    .is("discover_card_image_url", null)
    .order("saved_at", { ascending: false })
    .limit(25)
).then((rows) => rows.map((row) => ({
  user_id: redact(row.user_id),
  recipe_id: row.recipe_id,
  title: row.title,
  saved_at: row.saved_at,
  updated_at: row.updated_at,
}))));
audit.cart_missing_images = await timed("main shop rows missing image", () => fetchRows(
  "main_shop_items",
  "id,user_id,plan_id,name,image_url,created_at,updated_at",
  (query) => query
    .is("image_url", null)
    .order("updated_at", { ascending: false })
    .limit(25)
).then((rows) => rows.map((row) => ({
  id: row.id,
  user_id: redact(row.user_id),
  plan_id: row.plan_id,
  name: row.name,
  created_at: row.created_at,
  updated_at: row.updated_at,
}))));

console.log(JSON.stringify({
  audited_at: new Date().toISOString(),
  project_ref: process.env.SUPABASE_URL?.match(/https:\/\/([^.]+)/)?.[1] ?? null,
  stale_after_minutes: staleAfterMinutes,
  source_needle: sourceNeedle,
  audit,
}, null, 2));

try {
  const client = await getRedisClient().catch(() => null);
  if (client?.isOpen) {
    await client.quit();
  }
} catch {
  // Do not keep the audit process alive just because cache cleanup failed.
}
