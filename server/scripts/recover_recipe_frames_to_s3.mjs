#!/usr/bin/env node

// Recreates unavailable recipe thumbnails from videos already recovered to S3.
import { createWriteStream, existsSync, statSync } from "node:fs";
import { mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";
import { execFile } from "node:child_process";
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
if (!["plan", "copy"].includes(phase)) throw new Error("Usage: recover_recipe_frames_to_s3.mjs [plan|copy]");
const refresh = process.argv.includes("--refresh");
if (process.env.OUNJE_MEDIA_STORAGE_PROVIDER !== "s3") throw new Error("Configure S3 media before recovering frames");
const statePath = path.join(root, ".media-frame-rebuild-state.json");
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

function videoName(url) {
  try {
    const parsed = new URL(url);
    const match = parsed.pathname.match(/\/recipe-videos\/([^/]+\.mp4)$/i);
    return match?.[1] ?? null;
  } catch {
    return null;
  }
}

async function inventory() {
  const result = await db.query(`
    WITH images AS (
      SELECT bucket_id, name FROM storage.objects WHERE bucket_id IN ('recipe-images','recipe_images')
    ), links AS (
      SELECT i.bucket_id, i.name, r.attached_video_url
      FROM images i JOIN public.recipes r
        ON r.hero_image_url LIKE '%' || i.name OR r.discover_card_image_url LIKE '%' || i.name
      UNION ALL
      SELECT i.bucket_id, i.name, r.attached_video_url
      FROM images i JOIN public.user_import_recipes r
        ON r.hero_image_url LIKE '%' || i.name OR r.discover_card_image_url LIKE '%' || i.name
    )
    SELECT bucket_id, name, attached_video_url FROM links
  `);
  const byVideo = new Map();
  for (const row of result.rows) {
    const video = videoName(row.attached_video_url);
    if (!video) continue;
    const images = byVideo.get(video) ?? new Map();
    images.set(`${row.bucket_id}/${row.name}`, { bucket: row.bucket_id, name: row.name });
    byVideo.set(video, images);
  }
  return byVideo;
}

async function downloadVideo(name, target) {
  const response = await fetch(publicAwsMediaURL("recipe-videos", name), { signal: AbortSignal.timeout(120_000) });
  if (!response.ok || !response.body) throw new Error(`AWS video download returned HTTP ${response.status}`);
  await pipeline(Readable.fromWeb(response.body), createWriteStream(target));
  if (statSync(target).size < 1024) throw new Error("AWS video is empty");
}

async function createFrame(videoPath, target) {
  const { stdout } = await run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", videoPath], { timeout: 20_000 });
  const duration = Number(stdout.trim());
  if (!Number.isFinite(duration) || duration <= 0) throw new Error("Video duration is unavailable");
  const timestamp = Math.max(0, Math.min(Math.max(0.5, duration * 0.05), duration - 0.5));
  const webp = path.extname(target).toLowerCase() === ".webp";
  const intermediate = webp ? `${target}.png` : target;
  await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-ss", String(timestamp), "-i", videoPath, "-frames:v", "1", "-q:v", "2", "-y", intermediate], { timeout: 45_000 });
  if (webp) await run("cwebp", ["-quiet", "-q", "82", intermediate, "-o", target], { timeout: 20_000 });
  if (statSync(target).size < 1024) throw new Error("Extracted image is empty");
}

function contentType(name) {
  const extension = path.extname(name).toLowerCase();
  if ([".jpg", ".jpeg"].includes(extension)) return "image/jpeg";
  if (extension === ".png") return "image/png";
  if (extension === ".webp") return "image/webp";
  if (extension === ".gif") return "image/gif";
  return null;
}

async function playbackWorks(image) {
  const response = await fetch(publicAwsMediaURL(image.bucket, image.name), { headers: { Range: "bytes=0-0" }, signal: AbortSignal.timeout(20_000) });
  await response.body?.cancel();
  return [200, 206].includes(response.status);
}

try {
  const byVideo = await inventory();
  const possible = [...byVideo.values()].reduce((sum, images) => sum + images.size, 0);
  console.log(JSON.stringify({ phase, sourceVideos: byVideo.size, imageReferences: possible }));
  if (phase === "copy") {
    const state = await loadState();
    for (const [video, images] of byVideo) {
      const pending = [];
      for (const image of images.values()) {
        const key = `${image.bucket}/${image.name}`;
        if (await headAwsMedia(image.bucket, image.name) && !(refresh && state.copied[key])) continue;
        pending.push(image);
      }
      if (!pending.length) continue;
      if (!(await headAwsMedia("recipe-videos", video))) continue;
      const directory = await mkdtemp(path.join(os.tmpdir(), "ounje-recipe-frame-"));
      try {
        const videoPath = path.join(directory, "source.mp4");
        await downloadVideo(video, videoPath);
        const byExtension = new Map();
        for (const image of pending) {
          const key = `${image.bucket}/${image.name}`;
          try {
            const type = contentType(image.name);
            if (!type || type === "image/gif") throw new Error("Unsupported frame image format");
            const extension = path.extname(image.name).toLowerCase();
            if (!byExtension.has(extension)) {
              const framePath = path.join(directory, `frame${extension}`);
              await createFrame(videoPath, framePath);
              byExtension.set(extension, framePath);
            }
            const framePath = byExtension.get(extension);
            await uploadAwsMedia({ logicalBucket: image.bucket, objectPath: image.name, filePath: framePath, contentType: type });
            const bytes = statSync(framePath).size;
            if ((await headAwsMedia(image.bucket, image.name))?.bytes !== bytes || !(await playbackWorks(image))) throw new Error("AWS frame verification failed");
            state.copied[key] = { bytes, video, method: "video-frame" };
            delete state.failed[key];
            await saveState(state);
            console.log(`Recovered frame ${key} from ${video}`);
          } catch (error) {
            state.failed[key] = error.message;
            await saveState(state);
            console.warn(`Failed frame ${key}: ${error.message}`);
          }
        }
      } catch (error) {
        console.warn(`Failed video ${video}: ${error.message}`);
      } finally {
        await rm(directory, { recursive: true, force: true });
      }
    }
    console.log(JSON.stringify({ copied: Object.keys(state.copied).length, failed: Object.keys(state.failed).length }));
  }
} finally {
  await db.end();
}
