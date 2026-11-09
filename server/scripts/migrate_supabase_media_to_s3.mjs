#!/usr/bin/env node

// Run one phase at a time. A local checkpoint lets copy resume after a network
// interruption. Supabase objects are removed only by the Storage API.
import { readFile, writeFile, rename } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";
import pg from "pg";
import { getServiceRoleSupabase } from "../lib/supabase-clients.js";
import { headAwsMedia, publicAwsMediaURL, uploadAwsMedia } from "../lib/media-storage.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
dotenv.config({ path: path.join(root, "server/.env") });

const phase = process.argv[2] ?? "plan";
if (!["plan", "copy", "switch", "delete", "plan-recovered", "delete-recovered"].includes(phase)) {
  throw new Error("Usage: migrate_supabase_media_to_s3.mjs [plan|copy|switch|delete|plan-recovered|delete-recovered]");
}
if (process.env.OUNJE_MEDIA_STORAGE_PROVIDER !== "s3") {
  throw new Error("Set OUNJE_MEDIA_STORAGE_PROVIDER=s3 and the AWS media bucket/CDN settings first");
}

const supabaseURL = String(process.env.SUPABASE_URL ?? "").replace(/\/+$/, "");
if (!supabaseURL) throw new Error("SUPABASE_URL is required");
const sourceBuckets = ["recipe-videos", "recipe-images", "recipe_images"];
const statePath = path.join(root, ".media-migration-state.json");
const onboardingCatalogPath = path.join(root, "client/ios/ounje/Features/Onboarding/Models/OnboardingRecipeEditDemoCatalog.swift");
const oldPrefix = (bucket) => `${supabaseURL}/storage/v1/object/public/${bucket}/`;
const newPrefix = (bucket) => publicAwsMediaURL(bucket, "placeholder").replace(/placeholder$/, "");
const shippedClientReferences = new Set();
// Older App Store builds still contain these URLs even after source changes.
for (const key of [
  "recipe-images/peri-peri-chicken-with-peri-salted-chips/card/7e53e064f923d9822ed08823.jpg",
  "recipe-images/peri-peri-chicken-with-peri-salted-chips/hero/7e53e064f923d9822ed08823.jpg",
  "recipe-images/biscoff-banana-bread/hero/90780d141f292102b4e4b928.jpg",
  "recipe-videos/a11310fd870947a2ca94.mp4",
  "recipe-images/watermelon-drink/hero/7d8b8c8b4b7e6440d005ef5b.jpg",
  "recipe-videos/dc6e92ead77f84efc255.mp4",
  "recipe-images/airfryer-chicken-thighs-with-jollof-rice/card/bc601b7b5f48bb642c76a94e.jpg",
  "recipe-images/airfryer-chicken-thighs-with-jollof-rice/hero/bc601b7b5f48bb642c76a94e.jpg",
]) shippedClientReferences.add(key);
if (existsSync(onboardingCatalogPath)) {
  const catalog = await readFile(onboardingCatalogPath, "utf8");
  for (const bucket of sourceBuckets) {
    const prefix = oldPrefix(bucket);
    for (const match of catalog.matchAll(/https:\/\/[^"\s]+\/storage\/v1\/object\/public\/[^"\s]+/g)) {
      if (match[0].startsWith(prefix)) shippedClientReferences.add(`${bucket}/${match[0].slice(prefix.length)}`);
    }
  }
}

const poolerFile = path.join(root, "supabase/.temp/pooler-url");
const connectionString = process.env.SUPABASE_DB_URL || (existsSync(poolerFile) ? (await readFile(poolerFile, "utf8")).trim() : "");
if (!connectionString) throw new Error("Set SUPABASE_DB_URL or link the Supabase CLI project");
const connectionURL = new URL(connectionString);
if (!connectionURL.password && process.env.SUPABASE_DB_PASSWORD) connectionURL.password = process.env.SUPABASE_DB_PASSWORD;
const caPath = process.env.SUPABASE_DB_CA_CERT_PATH;
const ssl = caPath
  ? { ca: await readFile(caPath, "utf8"), rejectUnauthorized: true }
  : { rejectUnauthorized: false }; // Supabase shared pooler uses a private CA; TLS remains required.
if (!caPath) console.warn("Supabase pooler CA not configured; TLS is encrypted but its certificate is not verified. Set SUPABASE_DB_CA_CERT_PATH for full verification.");
const db = new pg.Client({
  connectionString: connectionURL.toString(),
  ssl,
  connectionTimeoutMillis: 10_000,
});
await db.connect();

async function loadState() {
  if (!existsSync(statePath)) return { copied: {}, switched: false };
  return JSON.parse(await readFile(statePath, "utf8"));
}

async function saveState(state) {
  const next = `${statePath}.tmp`;
  await writeFile(next, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(next, statePath);
}

async function objects() {
  const result = await db.query(
    "SELECT bucket_id, name, (metadata->>'size')::bigint AS size_bytes FROM storage.objects WHERE bucket_id = ANY($1) AND name IS NOT NULL ORDER BY bucket_id, name",
    [sourceBuckets]
  );
  return result.rows.map((row) => ({ ...row, size_bytes: Number(row.size_bytes) }));
}

async function copyObject(object, supabase) {
  const key = `${object.bucket_id}/${object.name}`;
  const { data, error } = await supabase.storage.from(object.bucket_id).download(object.name);
  if (error || !data) throw new Error(`Supabase download failed for ${key}: ${error?.message ?? "empty response"}`);
  const body = Buffer.from(await data.arrayBuffer());
  if (body.length !== object.size_bytes) throw new Error(`Size mismatch downloading ${key}`);
  const contentType = object.name.endsWith(".mp4") ? "video/mp4" : object.name.endsWith(".webp") ? "image/webp" : object.name.endsWith(".png") ? "image/png" : "image/jpeg";
  await uploadAwsMedia({ logicalBucket: object.bucket_id, objectPath: object.name, data: body, contentType });
  if ((await headAwsMedia(object.bucket_id, object.name))?.bytes !== object.size_bytes) throw new Error(`S3 size verification failed for ${key}`);
  return key;
}

const tables = ["recipes", "user_import_recipes", "saved_recipes", "recipe_ingestion_jobs", "recipe_ingestion_evidence_bundles"];
const referenceTables = [...tables, "recipe_ingestion_artifacts"];
async function storedReferences() {
  const host = new URL(supabaseURL).hostname.replaceAll(".", "\\.");
  const pattern = `(https://${host}/storage/v1/object/public/(?:recipe-videos|recipe-images|recipe_images)/[^"[:space:]]+)`;
  const references = new Set();
  for (const table of referenceTables) {
    const result = await db.query(
      `SELECT DISTINCT hit[1] AS url FROM public."${table}" AS row CROSS JOIN LATERAL regexp_matches(to_jsonb(row)::text, $1, 'g') AS hit`,
      [pattern]
    );
    for (const row of result.rows) references.add(row.url);
  }
  return references;
}

async function recoveredCopies() {
  const readState = async (name) => {
    const file = path.join(root, name);
    return existsSync(file) ? JSON.parse(await readFile(file, "utf8")) : {};
  };
  const videos = await readState(".media-rebuild-state.json");
  const images = await readState(".media-image-rebuild-state.json");
  const frames = await readState(".media-frame-rebuild-state.json");
  const pages = await readState(".media-page-rebuild-state.json");
  const imageCopies = { ...pages.copied, ...frames.copied, ...images.copied };
  const copies = new Map();
  for (const [name, record] of Object.entries(videos.recovered ?? {})) {
    if (videos.switched?.[name]) copies.set(`recipe-videos/${name}`, record.bytes);
  }
  for (const [key, record] of Object.entries(imageCopies)) {
    if (images.switched?.[key]) copies.set(key, record.bytes);
  }
  return copies;
}

async function replaceStoredUrls() {
  const columns = await db.query(
    "SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name = ANY($1) AND data_type IN ('text','jsonb') ORDER BY table_name,column_name",
    [tables]
  );
  const identifier = (value) => `"${value.replaceAll('"', '""')}"`;
  let changedRows = 0;
  await db.query("BEGIN");
  try {
    for (const bucket of sourceBuckets) {
      const from = oldPrefix(bucket);
      const to = newPrefix(bucket);
      for (const { table_name, column_name, data_type } of columns.rows) {
        const table = identifier(table_name);
        const column = identifier(column_name);
        const expression = data_type === "jsonb"
          ? `replace(${column}::text, $1, $2)::jsonb`
          : `replace(${column}, $1, $2)`;
        const result = await db.query(
          `UPDATE public.${table} SET ${column} = ${expression} WHERE ${column}::text LIKE '%' || $1 || '%'`,
          [from, to]
        );
        changedRows += result.rowCount;
      }
    }
    await db.query("COMMIT");
  } catch (error) {
    await db.query("ROLLBACK");
    throw error;
  }
  return changedRows;
}

try {
  const all = await objects();
  const bytes = all.reduce((sum, object) => sum + object.size_bytes, 0);
  console.log(JSON.stringify({ phase, objects: all.length, bytes, buckets: sourceBuckets }, null, 2));
  if (phase === "plan") process.exitCode = 0;
  if (phase === "copy") {
    const supabase = getServiceRoleSupabase();
    const state = await loadState();
    for (const [index, object] of all.entries()) {
      const key = `${object.bucket_id}/${object.name}`;
      if (state.copied[key] === object.size_bytes && (await headAwsMedia(object.bucket_id, object.name))?.bytes === object.size_bytes) continue;
      await copyObject(object, supabase);
      state.copied[key] = object.size_bytes;
      await saveState(state);
      console.log(`Copied ${index + 1}/${all.length}: ${key}`);
    }
  }
  if (phase === "plan-recovered" || phase === "delete-recovered") {
    const state = await loadState();
    const copies = await recoveredCopies();
    const eligible = all.filter((object) => copies.has(`${object.bucket_id}/${object.name}`) && !shippedClientReferences.has(`${object.bucket_id}/${object.name}`));
    const references = await storedReferences();
    const ready = eligible.filter((object) => !references.has(`${oldPrefix(object.bucket_id)}${object.name}`));
    console.log(JSON.stringify({ eligible: eligible.length, ready: ready.length, referencedURLs: references.size, originalBytes: ready.reduce((sum, object) => sum + object.size_bytes, 0) }));
    if (phase === "delete-recovered") {
      const supabase = getServiceRoleSupabase();
      let removed = 0;
      let retained = 0;
      for (const object of all) {
        const key = `${object.bucket_id}/${object.name}`;
        const copiedBytes = copies.get(key);
        if (!copiedBytes || shippedClientReferences.has(key)) {
          retained += 1;
          continue;
        }
        if (state.deleted?.[key]) continue;
        if ((await headAwsMedia(object.bucket_id, object.name))?.bytes !== copiedBytes) {
          throw new Error(`S3 verification failed before removing ${key}`);
        }
        const cdn = await fetch(publicAwsMediaURL(object.bucket_id, object.name), { method: "HEAD", signal: AbortSignal.timeout(20_000) });
        if (!cdn.ok || Number(cdn.headers.get("content-length")) !== copiedBytes) {
          throw new Error(`CloudFront verification failed before removing ${key} (HTTP ${cdn.status})`);
        }
        if (references.has(`${oldPrefix(object.bucket_id)}${object.name}`)) {
          retained += 1;
          console.warn(`Retained referenced Supabase file: ${key}`);
          continue;
        }
        const { error } = await supabase.storage.from(object.bucket_id).remove([object.name]);
        if (error) throw new Error(`Supabase removal failed for ${key}: ${error.message}`);
        state.deleted ??= {};
        state.deleted[key] = true;
        await saveState(state);
        removed += 1;
        console.log(`Removed recovered Supabase file: ${key}`);
      }
      console.log(JSON.stringify({ removed, retained }));
    }
  }
  if (phase === "switch" || phase === "delete") {
    const state = await loadState();
    if (all.some((object) => state.copied[`${object.bucket_id}/${object.name}`] !== object.size_bytes)) {
      throw new Error("Copy and verify every object before switching links or deleting originals");
    }
    for (const object of all) {
      const key = `${object.bucket_id}/${object.name}`;
      if ((await headAwsMedia(object.bucket_id, object.name))?.bytes !== object.size_bytes) {
        throw new Error(`S3 size verification failed before ${phase}: ${key}`);
      }
      const response = await fetch(publicAwsMediaURL(object.bucket_id, object.name), { method: "HEAD", signal: AbortSignal.timeout(20_000) });
      if (!response.ok || Number(response.headers.get("content-length")) !== object.size_bytes) {
        throw new Error(`CloudFront verification failed before ${phase}: ${key} (HTTP ${response.status})`);
      }
    }
    if (phase === "switch") {
      const changedRows = await replaceStoredUrls();
      state.switched = true;
      await saveState(state);
      console.log(`Updated ${changedRows} database rows`);
    } else {
      if (!state.switched) throw new Error("Switch database links before deleting originals");
      const supabase = getServiceRoleSupabase();
      for (const object of all) {
        // A shipped iOS demo has hardcoded Storage URLs. Keep those objects
        // until a client release uses the CDN URLs.
        if (shippedClientReferences.has(`${object.bucket_id}/${object.name}`)) continue;
        const key = `${object.bucket_id}/${object.name}`;
        if (state.deleted?.[key]) continue;
        const { error } = await supabase.storage.from(object.bucket_id).remove([object.name]);
        if (error) throw new Error(`Supabase removal failed for ${key}: ${error.message}`);
        state.deleted ??= {};
        state.deleted[key] = true;
        await saveState(state);
        console.log(`Removed Supabase copy: ${key}`);
      }
    }
  }
} finally {
  await db.end();
}
