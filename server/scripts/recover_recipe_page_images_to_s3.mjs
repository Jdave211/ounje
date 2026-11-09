#!/usr/bin/env node

// Recreates referenced recipe images from their original recipe pages.
import { existsSync, statSync } from "node:fs";
import { mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";
import pg from "pg";
import { headAwsMedia, publicAwsMediaURL, uploadAwsMedia } from "../lib/media-storage.js";

const run = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
dotenv.config({ path: path.join(root, "server/.env") });
const phase = process.argv[2] ?? "plan";
if (!["plan", "copy"].includes(phase)) throw new Error("Usage: recover_recipe_page_images_to_s3.mjs [plan|copy]");
if (process.env.OUNJE_MEDIA_STORAGE_PROVIDER !== "s3") throw new Error("Configure S3 media before recovering images");
const statePath = path.join(root, ".media-page-rebuild-state.json");
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
  return existsSync(statePath) ? JSON.parse(await readFile(statePath, "utf8")) : { copied: {}, failed: {} };
}

async function saveState(state) {
  const temporary = `${statePath}.tmp`;
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, statePath);
}

function validPublicURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:"
      && !url.username && !url.password
      && !/^(localhost|.*\.local|\d+\.\d+\.\d+\.\d+|\[.*\])$/i.test(url.hostname)
      && !["supabase.co", "tiktok.com", "instagram.com", "facebook.com"].some((domain) => url.hostname === domain || url.hostname.endsWith(`.${domain}`));
  } catch {
    return false;
  }
}

function decodeEntities(value) {
  return value.replace(/&amp;/g, "&").replace(/&#(\d+);/g, (_, number) => String.fromCodePoint(Number(number)))
    .replace(/&#x([0-9a-f]+);/gi, (_, number) => String.fromCodePoint(parseInt(number, 16)));
}

function socialImage(html, pageURL) {
  for (const tag of html.match(/<meta\b[^>]*>/gi) ?? []) {
    if (!/(?:property|name)=["'](?:og:image|twitter:image)(?::url)?["']/i.test(tag)) continue;
    const content = tag.match(/\bcontent=["']([^"']+)["']/i)?.[1];
    if (!content) continue;
    const url = new URL(decodeEntities(content), pageURL).toString();
    if (validPublicURL(url)) return url;
  }
  return null;
}

async function inventory() {
  const result = await db.query(`
    WITH images AS (SELECT bucket_id,name FROM storage.objects WHERE bucket_id IN ('recipe-images','recipe_images')),
    links AS (
      SELECT i.bucket_id,i.name,r.original_recipe_url,r.recipe_url FROM images i JOIN public.recipes r
        ON r.hero_image_url LIKE '%' || i.name OR r.discover_card_image_url LIKE '%' || i.name
      UNION ALL
      SELECT i.bucket_id,i.name,r.original_recipe_url,r.recipe_url FROM images i JOIN public.user_import_recipes r
        ON r.hero_image_url LIKE '%' || i.name OR r.discover_card_image_url LIKE '%' || i.name
    ) SELECT * FROM links
  `);
  const byKey = new Map();
  for (const row of result.rows) {
    const source = [row.original_recipe_url, row.recipe_url].find(validPublicURL);
    if (source) byKey.set(`${row.bucket_id}/${row.name}`, { bucket: row.bucket_id, name: row.name, page: source });
  }
  return [...byKey.values()];
}

async function getImageBuffer(pageURL) {
  const page = await fetch(pageURL, { headers: { "user-agent": "Mozilla/5.0" }, signal: AbortSignal.timeout(20_000) });
  if (!page.ok) throw new Error(`Recipe page returned HTTP ${page.status}`);
  const imageURL = socialImage(await page.text(), pageURL);
  if (!imageURL) throw new Error("Recipe page has no usable social image");
  const image = await fetch(imageURL, { headers: { "user-agent": "Mozilla/5.0", referer: pageURL, accept: "image/*" }, signal: AbortSignal.timeout(30_000) });
  if (!image.ok) throw new Error(`Recipe page image returned HTTP ${image.status}`);
  if (Number(image.headers.get("content-length")) > 20 * 1024 * 1024) throw new Error("Recipe page image exceeds 20 MB");
  const buffer = Buffer.from(await image.arrayBuffer());
  if (buffer.length < 1024 || buffer.length > 20 * 1024 * 1024) throw new Error("Recipe page image has an invalid size");
  return buffer;
}

function contentType(name) {
  const extension = path.extname(name).toLowerCase();
  if ([".jpg", ".jpeg"].includes(extension)) return "image/jpeg";
  if (extension === ".png") return "image/png";
  if (extension === ".webp") return "image/webp";
  return null;
}

async function playbackWorks(object) {
  const response = await fetch(publicAwsMediaURL(object.bucket, object.name), { headers: { Range: "bytes=0-0" }, signal: AbortSignal.timeout(20_000) });
  await response.body?.cancel();
  return [200, 206].includes(response.status);
}

try {
  const objects = await inventory();
  console.log(JSON.stringify({ phase, pageLinked: objects.length }));
  if (phase === "copy") {
    const state = await loadState();
    for (const object of objects) {
      const key = `${object.bucket}/${object.name}`;
      if (await headAwsMedia(object.bucket, object.name)) continue;
      const directory = await mkdtemp(path.join(os.tmpdir(), "ounje-page-image-"));
      try {
        const buffer = await getImageBuffer(object.page);
        const sourceFile = path.join(directory, "source.img");
        await writeFile(sourceFile, buffer);
        const extension = path.extname(object.name).toLowerCase();
        const output = path.join(directory, `asset${extension}`);
        if (extension === ".webp") {
          const png = path.join(directory, "asset.png");
          await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-i", sourceFile, "-frames:v", "1", "-y", png], { timeout: 30_000 });
          await run("cwebp", ["-quiet", "-q", "82", png, "-o", output], { timeout: 20_000 });
        } else {
          await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-i", sourceFile, "-frames:v", "1", "-y", output], { timeout: 30_000 });
        }
        const bytes = statSync(output).size;
        if (bytes < 1024) throw new Error("Converted page image is empty");
        await uploadAwsMedia({ logicalBucket: object.bucket, objectPath: object.name, filePath: output, contentType: contentType(object.name) });
        if ((await headAwsMedia(object.bucket, object.name))?.bytes !== bytes || !(await playbackWorks(object))) throw new Error("AWS page image verification failed");
        state.copied[key] = { bytes, page: object.page, method: "recipe-page" };
        delete state.failed[key];
        await saveState(state);
        console.log(`Recovered page image ${key}`);
      } catch (error) {
        state.failed[key] = error.message;
        await saveState(state);
        console.warn(`Failed page image ${key}: ${error.message}`);
      } finally {
        await rm(directory, { recursive: true, force: true });
      }
    }
    console.log(JSON.stringify({ copied: Object.keys(state.copied).length, failed: Object.keys(state.failed).length }));
  }
} finally {
  await db.end();
}
