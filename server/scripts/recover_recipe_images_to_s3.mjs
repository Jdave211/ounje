#!/usr/bin/env node

// Re-fetches image assets from the original URLs recorded in recipe evidence.
// A SHA-256 prefix in each Storage filename identifies the exact source URL.
import crypto from "node:crypto";
import { readFile, rename, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";
import pg from "pg";
import { headAwsMedia, publicAwsMediaURL, uploadAwsMedia } from "../lib/media-storage.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
dotenv.config({ path: path.join(root, "server/.env") });
const phase = process.argv[2] ?? "plan";
if (!["plan", "copy", "switch"].includes(phase)) throw new Error("Usage: recover_recipe_images_to_s3.mjs [plan|copy|switch]");
if (process.env.OUNJE_MEDIA_STORAGE_PROVIDER !== "s3") throw new Error("Configure S3 media before recovering images");
const supabaseURL = String(process.env.SUPABASE_URL ?? "").replace(/\/+$/, "");
if (!supabaseURL) throw new Error("SUPABASE_URL is required");
const statePath = path.join(root, ".media-image-rebuild-state.json");
const poolerFile = path.join(root, "supabase/.temp/pooler-url");
const connection = process.env.SUPABASE_DB_URL || (existsSync(poolerFile) ? (await readFile(poolerFile, "utf8")).trim() : "");
if (!connection) throw new Error("Set SUPABASE_DB_URL or link the Supabase CLI project");
const connectionURL = new URL(connection);
if (!connectionURL.password && process.env.SUPABASE_DB_PASSWORD) connectionURL.password = process.env.SUPABASE_DB_PASSWORD;
const caPath = process.env.SUPABASE_DB_CA_CERT_PATH;
const db = new pg.Client({
  connectionString: connectionURL.toString(),
  ssl: caPath ? { ca: await readFile(caPath, "utf8"), rejectUnauthorized: true } : { rejectUnauthorized: false },
  connectionTimeoutMillis: 10_000,
});
if (!caPath) console.warn("Supabase pooler CA not configured; TLS certificate is not verified. Set SUPABASE_DB_CA_CERT_PATH for full verification.");
await db.connect();

async function loadState() {
  return existsSync(statePath) ? JSON.parse(await readFile(statePath, "utf8")) : { copied: {}, switched: {}, failed: {} };
}

async function saveState(state) {
  const temporary = `${statePath}.tmp`;
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, statePath);
}

function publicSource(value) {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:"
      && !parsed.username && !parsed.password
      && !/^(localhost|.*\.local|\d+\.\d+\.\d+\.\d+|\[.*\])$/i.test(parsed.hostname)
      && parsed.hostname !== new URL(supabaseURL).hostname;
  } catch {
    return false;
  }
}

function extractUrls(value, found) {
  if (typeof value === "string") {
    for (const match of value.matchAll(/https?:\/\/[^\s"'<>]+/g)) {
      const candidate = match[0].replace(/[),.;]+$/, "");
      if (publicSource(candidate)) found.add(candidate);
    }
  } else if (Array.isArray(value)) {
    value.forEach((item) => extractUrls(item, found));
  } else if (value && typeof value === "object") {
    Object.values(value).forEach((item) => extractUrls(item, found));
  }
}

async function inventory() {
  const objects = (await db.query(
    "SELECT bucket_id, name, (metadata->>'size')::bigint AS old_bytes FROM storage.objects WHERE bucket_id IN ('recipe-images','recipe_images') ORDER BY bucket_id,name"
  )).rows;
  const byHash = new Map();
  for (const object of objects) {
    const hash = path.extname(object.name) ? path.basename(object.name, path.extname(object.name)) : "";
    if (!/^[a-f0-9]{24}$/.test(hash)) continue;
    const matches = byHash.get(hash) ?? [];
    matches.push(object);
    byHash.set(hash, matches);
  }
  const sources = new Set();
  for (const query of [
    "SELECT source_provenance_json,original_recipe_url,recipe_url FROM recipes",
    "SELECT source_provenance_json,original_recipe_url,recipe_url FROM user_import_recipes",
    "SELECT request_payload,source_provenance_json,event_log FROM recipe_ingestion_jobs",
    "SELECT evidence_json,metadata_json FROM recipe_ingestion_evidence_bundles",
    "SELECT raw_json,metadata,source_url FROM recipe_ingestion_artifacts",
  ]) {
    for (const row of (await db.query(query)).rows) extractUrls(row, sources);
  }
  const matched = new Map();
  for (const source of sources) {
    const hash = crypto.createHash("sha256").update(source).digest("hex").slice(0, 24);
    for (const object of byHash.get(hash) ?? []) matched.set(`${object.bucket_id}/${object.name}`, { ...object, source });
  }
  return { objects, matched: [...matched.values()] };
}

function imageType(buffer) {
  if (buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return "image/jpeg";
  if (buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return "image/png";
  if (buffer.toString("ascii", 0, 4) === "RIFF" && buffer.toString("ascii", 8, 12) === "WEBP") return "image/webp";
  if (["GIF87a", "GIF89a"].includes(buffer.toString("ascii", 0, 6))) return "image/gif";
  return null;
}

function typeMatchesName(type, name) {
  const extension = path.extname(name).toLowerCase();
  return (type === "image/jpeg" && [".jpg", ".jpeg"].includes(extension))
    || (type === "image/png" && extension === ".png")
    || (type === "image/webp" && extension === ".webp")
    || (type === "image/gif" && extension === ".gif");
}

async function fetchImage(source) {
  let current = source;
  for (let redirects = 0; redirects < 4; redirects += 1) {
    if (!publicSource(current)) throw new Error("Image source redirected to a disallowed host");
    const response = await fetch(current, {
      redirect: "manual",
      headers: { "user-agent": "Mozilla/5.0 OunjeMediaMigration/1.0", accept: "image/*" },
      signal: AbortSignal.timeout(30_000),
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      await response.body?.cancel();
      if (!location) throw new Error("Image source redirected without a location");
      current = new URL(location, current).toString();
      continue;
    }
    if (!response.ok) throw new Error(`Image source returned HTTP ${response.status}`);
    if (Number(response.headers.get("content-length")) > 20 * 1024 * 1024) throw new Error("Image source exceeds 20 MB");
    const chunks = [];
    let bytes = 0;
    for await (const chunk of response.body) {
      bytes += chunk.length;
      if (bytes > 20 * 1024 * 1024) throw new Error("Image source exceeds 20 MB");
      chunks.push(chunk);
    }
    return Buffer.concat(chunks);
  }
  throw new Error("Too many image redirects");
}

async function playbackWorks(object) {
  const response = await fetch(publicAwsMediaURL(object.bucket_id, object.name), {
    headers: { Range: "bytes=0-0" },
    signal: AbortSignal.timeout(20_000),
  });
  await response.body?.cancel();
  return [200, 206].includes(response.status);
}

const tables = ["recipes", "user_import_recipes", "saved_recipes", "recipe_ingestion_jobs", "recipe_ingestion_evidence_bundles", "recipe_ingestion_artifacts"];
const quote = (identifier) => `"${identifier.replaceAll('"', '""')}"`;
async function switchOne(object) {
  const columns = await db.query(
    "SELECT table_name,column_name,data_type FROM information_schema.columns WHERE table_schema='public' AND table_name=ANY($1) AND data_type IN ('text','jsonb')",
    [tables]
  );
  const oldURL = `${supabaseURL}/storage/v1/object/public/${object.bucket_id}/${object.name}`;
  const newURL = publicAwsMediaURL(object.bucket_id, object.name);
  let changed = 0;
  await db.query("BEGIN");
  try {
    for (const { table_name, column_name, data_type } of columns.rows) {
      const column = quote(column_name);
      const expression = data_type === "jsonb" ? `replace(${column}::text,$1,$2)::jsonb` : `replace(${column},$1,$2)`;
      const result = await db.query(
        `UPDATE public.${quote(table_name)} SET ${column}=${expression} WHERE ${column}::text LIKE '%' || $1 || '%'`,
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
  const { objects, matched } = await inventory();
  console.log(JSON.stringify({ phase, total: objects.length, sourceMatched: matched.length, unmatched: objects.length - matched.length }));
  if (phase === "copy") {
    const state = await loadState();
    for (const [index, object] of matched.entries()) {
      const key = `${object.bucket_id}/${object.name}`;
      if (state.copied[key] && (await headAwsMedia(object.bucket_id, object.name))?.bytes === state.copied[key].bytes && await playbackWorks(object)) continue;
      try {
        const data = await fetchImage(object.source);
        const contentType = imageType(data);
        if (!typeMatchesName(contentType, object.name)) throw new Error("Image format does not match the stored filename");
        await uploadAwsMedia({ logicalBucket: object.bucket_id, objectPath: object.name, data, contentType });
        if ((await headAwsMedia(object.bucket_id, object.name))?.bytes !== data.length || !(await playbackWorks(object))) {
          throw new Error("AWS upload/playback verification failed");
        }
        state.copied[key] = { bytes: data.length, oldBytes: Number(object.old_bytes) };
        delete state.failed[key];
        await saveState(state);
        console.log(`Recovered ${index + 1}/${matched.length}: ${key} (${data.length} bytes)`);
      } catch (error) {
        state.failed[key] = error.message;
        await saveState(state);
        console.warn(`Failed ${key}: ${error.message}`);
      }
    }
    console.log(JSON.stringify({ copied: Object.keys(state.copied).length, failed: Object.keys(state.failed).length }));
  }
  if (phase === "switch") {
    const state = await loadState();
    const frameStatePath = path.join(root, ".media-frame-rebuild-state.json");
    const frameState = existsSync(frameStatePath) ? JSON.parse(await readFile(frameStatePath, "utf8")) : { copied: {} };
    const pageStatePath = path.join(root, ".media-page-rebuild-state.json");
    const pageState = existsSync(pageStatePath) ? JSON.parse(await readFile(pageStatePath, "utf8")) : { copied: {} };
    const verifiedCopies = { ...pageState.copied, ...frameState.copied, ...state.copied };
    const byKey = new Map(objects.map((object) => [`${object.bucket_id}/${object.name}`, object]));
    for (const [key, record] of Object.entries(verifiedCopies)) {
      if (state.switched[key]) continue;
      const object = byKey.get(key);
      if (!object || (await headAwsMedia(object.bucket_id, object.name))?.bytes !== record.bytes || !(await playbackWorks(object))) {
        throw new Error(`AWS copy failed verification before switching ${key}`);
      }
      const changed = await switchOne(object);
      state.switched[key] = true;
      await saveState(state);
      console.log(`Switched ${key}: ${changed} database rows`);
    }
    console.log(JSON.stringify({ switched: Object.keys(state.switched).length }));
  }
} finally {
  await db.end();
}
