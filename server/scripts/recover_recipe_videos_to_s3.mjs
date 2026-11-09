#!/usr/bin/env node

// Rebuilds recipe videos from their original public source when Supabase
// Storage is quota-restricted. This cannot remove the Supabase copies.
import { mkdtemp, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { existsSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";
import pg from "pg";
import { headAwsMedia, publicAwsMediaURL, uploadAwsMedia } from "../lib/media-storage.js";
import { runYoutubeDl } from "../lib/youtube-dl-wrapper.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
dotenv.config({ path: path.join(root, "server/.env") });
const phase = process.argv[2] ?? "plan";
if (!["plan", "copy", "switch"].includes(phase)) throw new Error("Usage: recover_recipe_videos_to_s3.mjs [plan|copy|switch]");
const limitIndex = process.argv.indexOf("--limit");
const limit = limitIndex < 0 ? Infinity : Number(process.argv[limitIndex + 1]);
if (limitIndex >= 0 && (!Number.isInteger(limit) || limit < 1)) throw new Error("--limit requires a positive integer");
const failedOnly = process.argv.includes("--failed-only");
if (process.env.OUNJE_MEDIA_STORAGE_PROVIDER !== "s3") throw new Error("Configure S3 media before recovering videos");
const supabaseURL = String(process.env.SUPABASE_URL ?? "").replace(/\/+$/, "");
if (!supabaseURL) throw new Error("SUPABASE_URL is required");
const bucket = "recipe-videos";
const statePath = path.join(root, ".media-rebuild-state.json");
const sourcePrefix = `${supabaseURL}/storage/v1/object/public/${bucket}/`;
const poolerFile = path.join(root, "supabase/.temp/pooler-url");
const rawConnection = process.env.SUPABASE_DB_URL || (existsSync(poolerFile) ? (await readFile(poolerFile, "utf8")).trim() : "");
if (!rawConnection) throw new Error("Set SUPABASE_DB_URL or link the Supabase CLI project");
const connectionURL = new URL(rawConnection);
if (!connectionURL.password && process.env.SUPABASE_DB_PASSWORD) connectionURL.password = process.env.SUPABASE_DB_PASSWORD;
const caPath = process.env.SUPABASE_DB_CA_CERT_PATH;
const db = new pg.Client({
  connectionString: connectionURL.toString(),
  ssl: caPath ? { ca: await readFile(caPath, "utf8"), rejectUnauthorized: true } : { rejectUnauthorized: false },
  connectionTimeoutMillis: 10_000,
});
if (!caPath) console.warn("Supabase pooler CA not configured; TLS certificate is not verified. Set SUPABASE_DB_CA_CERT_PATH for full verification.");
await db.connect();

async function saveState(state) {
  const temporary = `${statePath}.tmp`;
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, statePath);
}

async function loadState() {
  return existsSync(statePath) ? JSON.parse(await readFile(statePath, "utf8")) : { recovered: {}, switched: {} };
}

function originalSource(value) {
  try {
    const parsed = new URL(value);
    return ["http:", "https:"].includes(parsed.protocol) && parsed.hostname !== new URL(supabaseURL).hostname;
  } catch {
    return false;
  }
}

async function inventory() {
  const result = await db.query(`
    WITH videos AS (
      SELECT name, (metadata->>'size')::bigint AS bytes
      FROM storage.objects WHERE bucket_id = $1
    ), links AS (
      SELECT v.name, v.bytes, r.original_recipe_url, r.recipe_url
      FROM videos v JOIN public.recipes r ON r.attached_video_url LIKE '%' || v.name
      UNION ALL
      SELECT v.name, v.bytes, r.original_recipe_url, r.recipe_url
      FROM videos v JOIN public.user_import_recipes r ON r.attached_video_url LIKE '%' || v.name
    )
    SELECT name, bytes, original_recipe_url, recipe_url FROM links ORDER BY name
  `, [bucket]);
  const byName = new Map();
  for (const row of result.rows) {
    const entry = byName.get(row.name) ?? { name: row.name, originalBytes: Number(row.bytes), sources: [] };
    for (const source of [row.original_recipe_url, row.recipe_url]) {
      if (originalSource(source) && !entry.sources.includes(source)) entry.sources.push(source);
    }
    byName.set(row.name, entry);
  }
  const all = await db.query("SELECT name, (metadata->>'size')::bigint AS bytes FROM storage.objects WHERE bucket_id=$1 ORDER BY name", [bucket]);
  return all.rows.map((row) => byName.get(row.name) ?? { name: row.name, originalBytes: Number(row.bytes), sources: [] });
}

async function download(source, directory) {
  await runYoutubeDl(source, {
    noPlaylist: true,
    socketTimeout: 20,
    retries: 2,
    fragmentRetries: 2,
    extractorRetries: 2,
    format: "mp4/best",
    mergeOutputFormat: "mp4",
    output: path.join(directory, "asset.%(ext)s"),
  }, { timeout: 150_000, killSignal: "SIGKILL" });
  const filename = (await readdir(directory)).find((name) => /\.(mp4|m4v|mov)$/i.test(name));
  if (!filename) throw new Error("Source did not provide a video file");
  const filePath = path.join(directory, filename);
  if (statSync(filePath).size < 1024) throw new Error("Downloaded video is empty");
  return filePath;
}

async function embeddedSources(pageURL) {
  const host = new URL(pageURL).hostname.toLowerCase();
  if (["tiktok.com", "instagram.com", "youtube.com"].some((domain) => host === domain || host.endsWith(`.${domain}`))) return [];
  const response = await fetch(pageURL, { headers: { "user-agent": "Mozilla/5.0" }, signal: AbortSignal.timeout(20_000) });
  if (!response.ok) return [];
  const html = await response.text();
  const sources = [
    ...[...html.matchAll(/https:\/\/content\.jwplatform\.com\/videos\/[A-Za-z0-9_-]+\.mp4/g)].map((match) => match[0]),
    ...[...html.matchAll(/youtube(?:-nocookie)?\.com\/embed\/([A-Za-z0-9_-]{11})/g)].map((match) => `https://www.youtube.com/watch?v=${match[1]}`),
    ...[...html.matchAll(/data-instgrm-permalink="(https:\/\/www\.instagram\.com\/reel\/[^"?]+)/g)].map((match) => match[1]),
  ];
  return [...new Set(sources)];
}

async function playbackWorks(name) {
  const response = await fetch(publicAwsMediaURL(bucket, name), {
    headers: { Range: "bytes=0-0" },
    signal: AbortSignal.timeout(20_000),
  });
  await response.body?.cancel();
  return response.status === 200 || response.status === 206;
}

async function copyOne(entry) {
  const failures = [];
  for (const source of entry.sources) {
    let candidates = [source];
    try { candidates.push(...await embeddedSources(source)); } catch { /* Try the original URL. */ }
    for (const candidate of [...new Set(candidates)]) {
      const directory = await mkdtemp(path.join(os.tmpdir(), "ounje-video-rebuild-"));
      try {
        const filePath = await download(candidate, directory);
        const bytes = statSync(filePath).size;
        await uploadAwsMedia({ logicalBucket: bucket, objectPath: entry.name, filePath, contentType: "video/mp4" });
        const head = await headAwsMedia(bucket, entry.name);
        if (head?.bytes !== bytes || !(await playbackWorks(entry.name))) throw new Error("AWS upload/playback verification failed");
        return { bytes, source: candidate, originalBytes: entry.originalBytes };
      } catch (error) {
        failures.push(`${new URL(candidate).hostname}: ${String(error.stderr ?? error.message).slice(-350)}`);
      } finally {
        await rm(directory, { recursive: true, force: true });
      }
    }
  }
  throw new Error(failures.join("; ") || "No original video source in the database");
}

const tables = ["recipes", "user_import_recipes", "saved_recipes", "recipe_ingestion_jobs", "recipe_ingestion_evidence_bundles", "recipe_ingestion_artifacts"];
const quote = (identifier) => `"${identifier.replaceAll('"', '""')}"`;
async function switchOne(name) {
  const columns = await db.query(
    "SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name = ANY($1) AND data_type IN ('text','jsonb')",
    [tables]
  );
  const oldURL = `${sourcePrefix}${name}`;
  const newURL = publicAwsMediaURL(bucket, name);
  let changed = 0;
  await db.query("BEGIN");
  try {
    for (const { table_name, column_name, data_type } of columns.rows) {
      const column = quote(column_name);
      const expression = data_type === "jsonb" ? `replace(${column}::text, $1, $2)::jsonb` : `replace(${column}, $1, $2)`;
      const result = await db.query(
        `UPDATE public.${quote(table_name)} SET ${column} = ${expression} WHERE ${column}::text LIKE '%' || $1 || '%'`,
        [oldURL, newURL]
      );
      changed += result.rowCount;
    }
    await db.query("COMMIT");
  } catch (error) {
    await db.query("ROLLBACK");
    throw error;
  }
  return changed;
}

try {
  const entries = await inventory();
  const recoverable = entries.filter((entry) => entry.sources.length);
  console.log(JSON.stringify({ phase, total: entries.length, recoverable: recoverable.length, unavailable: entries.length - recoverable.length }));
  if (phase === "copy") {
    const state = await loadState();
    const candidates = failedOnly ? recoverable.filter((entry) => state.failed?.[entry.name]) : recoverable;
    for (const [index, entry] of candidates.slice(0, limit).entries()) {
      const existing = state.recovered[entry.name];
      if (existing && (await headAwsMedia(bucket, entry.name))?.bytes === existing.bytes && await playbackWorks(entry.name)) continue;
      try {
        state.recovered[entry.name] = await copyOne(entry);
        delete state.failed?.[entry.name];
        await saveState(state);
        console.log(`Recovered ${index + 1}/${recoverable.length}: ${entry.name} (${state.recovered[entry.name].bytes} bytes)`);
      } catch (error) {
        state.failed ??= {};
        state.failed[entry.name] = error.message;
        await saveState(state);
        console.warn(`Failed ${entry.name}: ${error.message}`);
      }
    }
    console.log(JSON.stringify({ recovered: Object.keys(state.recovered).length, failed: Object.keys(state.failed ?? {}).length }));
    if (Object.keys(state.failed ?? {}).length) process.exitCode = 1;
  }
  if (phase === "switch") {
    const state = await loadState();
    for (const [name, record] of Object.entries(state.recovered)) {
      if (state.switched[name]) continue;
      if ((await headAwsMedia(bucket, name))?.bytes !== record.bytes || !(await playbackWorks(name))) {
        throw new Error(`AWS copy failed verification before switching ${name}`);
      }
      const changed = await switchOne(name);
      state.switched[name] = true;
      await saveState(state);
      console.log(`Switched ${name}: ${changed} database rows`);
    }
    console.log(JSON.stringify({ switched: Object.keys(state.switched).length }));
  }
} finally {
  await db.end();
}
