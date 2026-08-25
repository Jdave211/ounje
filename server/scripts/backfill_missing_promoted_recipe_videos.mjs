#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";

import { getServiceRoleSupabase } from "../lib/supabase-clients.js";
import { runYoutubeDl } from "../lib/youtube-dl-wrapper.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const confirm = process.argv.includes("--confirm");
const idArgumentIndex = process.argv.indexOf("--id");
const targetRecipeID = idArgumentIndex >= 0 ? String(process.argv[idArgumentIndex + 1] ?? "").trim() : null;
const bucket = process.env.RECIPE_VIDEO_BUCKET ?? "recipe-videos";
const directVideoPattern = /\.(mp4|m4v|mov|m3u8)(?:\?|$)/i;

function isDirectVideoURL(value) {
  return directVideoPattern.test(String(value ?? ""));
}

async function downloadVideo(sourceURL, outputDirectory) {
  await runYoutubeDl(sourceURL, {
    noWarnings: true,
    noCallHome: true,
    noCheckCertificates: true,
    noPlaylist: true,
    socketTimeout: 20,
    retries: 2,
    fragmentRetries: 2,
    extractorRetries: 2,
    format: "mp4/best",
    mergeOutputFormat: "mp4",
    output: path.join(outputDirectory, "asset.%(ext)s"),
  }, {
    timeout: 120_000,
    killSignal: "SIGKILL",
  });

  const files = await readdir(outputDirectory);
  const videoName = files.find((name) => /\.(mp4|m4v|mov)$/i.test(name));
  return videoName ? path.join(outputDirectory, videoName) : null;
}

async function main() {
  const supabase = getServiceRoleSupabase();
  const { data: recipes, error } = await supabase
    .from("recipes")
    .select("id,title,attached_video_url,original_recipe_url,recipe_url")
    .eq("source_provenance_json->>catalog_origin", "existing_import")
    .limit(1000);
  if (error) throw new Error(error.message);

  const candidates = (recipes ?? []).filter((recipe) => (
    (!targetRecipeID || recipe.id === targetRecipeID)
    && !isDirectVideoURL(recipe.attached_video_url)
    && Boolean(recipe.original_recipe_url || recipe.recipe_url || recipe.attached_video_url)
  ));

  if (!confirm) {
    console.log(JSON.stringify({
      mode: "dry_run",
      candidates: candidates.map((recipe) => ({ id: recipe.id, title: recipe.title })),
    }, null, 2));
    return;
  }

  const completed = [];
  const failures = [];
  for (const recipe of candidates) {
    const sourceURL = recipe.original_recipe_url || recipe.recipe_url || recipe.attached_video_url;
    const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "ounje-catalog-video-"));
    try {
      const videoPath = await downloadVideo(sourceURL, tempDirectory);
      if (!videoPath) throw new Error("Downloader returned no playable video file.");

      const data = await readFile(videoPath);
      if (!data.length) throw new Error("Downloaded video was empty.");
      const digest = createHash("sha256").update(data).digest("hex").slice(0, 20);
      const objectPath = `catalog/${recipe.id}-${digest}.mp4`;
      const { error: uploadError } = await supabase.storage
        .from(bucket)
        .upload(objectPath, data, { contentType: "video/mp4", upsert: false });
      if (uploadError && !/already exists/i.test(uploadError.message)) {
        throw new Error(uploadError.message);
      }

      const { data: publicURLData } = supabase.storage.from(bucket).getPublicUrl(objectPath);
      const hostedURL = publicURLData?.publicUrl;
      if (!hostedURL) throw new Error("Storage did not return a public video URL.");

      const playbackResponse = await fetch(hostedURL, {
        headers: { range: "bytes=0-0" },
        signal: AbortSignal.timeout(12_000),
      });
      await playbackResponse.body?.cancel();
      if (![200, 206].includes(playbackResponse.status)) {
        throw new Error(`Hosted video playback check failed (${playbackResponse.status}).`);
      }

      let updateQuery = supabase
        .from("recipes")
        .update({ attached_video_url: hostedURL })
        .eq("id", recipe.id);
      updateQuery = recipe.attached_video_url == null
        ? updateQuery.is("attached_video_url", null)
        : updateQuery.eq("attached_video_url", recipe.attached_video_url);
      const { data: updated, error: updateError } = await updateQuery.select("id").maybeSingle();
      if (updateError) throw new Error(updateError.message);
      if (!updated?.id) throw new Error("Recipe changed while the video was being prepared.");
      completed.push({ id: recipe.id, title: recipe.title, bytes: data.length });
    } catch (downloadError) {
      failures.push({ id: recipe.id, title: recipe.title, reason: downloadError.message });
    } finally {
      await rm(tempDirectory, { recursive: true, force: true }).catch(() => {});
    }
  }

  console.log(JSON.stringify({
    mode: "confirmed",
    completed,
    failures,
  }, null, 2));
  if (failures.length) process.exitCode = 1;
}

await main();
