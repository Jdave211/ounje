#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";

import { getServiceRoleSupabase } from "../lib/supabase-clients.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const confirm = process.argv.includes("--confirm");
const directVideoPattern = /\.(mp4|m4v|mov|m3u8)(?:\?|$)/i;

function isDirectVideoURL(value) {
  try {
    const url = new URL(String(value ?? ""));
    return ["http:", "https:"].includes(url.protocol) && directVideoPattern.test(url.href);
  } catch {
    return false;
  }
}

async function mapWithConcurrency(values, concurrency, callback) {
  const results = new Array(values.length);
  let cursor = 0;
  async function worker() {
    while (cursor < values.length) {
      const index = cursor;
      cursor += 1;
      results[index] = await callback(values[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, worker));
  return results;
}

async function videoIsReachable(url) {
  try {
    const response = await fetch(url, {
      headers: { range: "bytes=0-0" },
      signal: AbortSignal.timeout(12_000),
    });
    const contentType = String(response.headers.get("content-type") ?? "").toLowerCase();
    await response.body?.cancel();
    return [200, 206].includes(response.status)
      && (contentType.startsWith("video/") || contentType.includes("octet-stream"));
  } catch {
    return false;
  }
}

async function main() {
  const supabase = getServiceRoleSupabase();
  const { data: imports, error: importError } = await supabase
    .from("user_import_recipes")
    .select("id,accepted_recipe_id,attached_video_url,updated_at")
    .not("accepted_recipe_id", "is", null)
    .not("attached_video_url", "is", null)
    .order("updated_at", { ascending: false })
    .limit(5000);
  if (importError) throw new Error(importError.message);

  const hostedVideoByRecipeID = new Map();
  for (const importedRecipe of imports ?? []) {
    if (!isDirectVideoURL(importedRecipe.attached_video_url)) continue;
    if (!hostedVideoByRecipeID.has(importedRecipe.accepted_recipe_id)) {
      hostedVideoByRecipeID.set(importedRecipe.accepted_recipe_id, importedRecipe.attached_video_url);
    }
  }

  const recipeIDs = [...hostedVideoByRecipeID.keys()];
  const { data: recipes, error: recipeError } = await supabase
    .from("recipes")
    .select("id,attached_video_url")
    .in("id", recipeIDs.length ? recipeIDs : ["00000000-0000-0000-0000-000000000000"]);
  if (recipeError) throw new Error(recipeError.message);

  const candidates = (recipes ?? [])
    .filter((recipe) => !isDirectVideoURL(recipe.attached_video_url))
    .map((recipe) => ({
      recipeID: recipe.id,
      previousURL: recipe.attached_video_url,
      hostedURL: hostedVideoByRecipeID.get(recipe.id),
    }));

  const reachability = await mapWithConcurrency(candidates, 8, async (candidate) => ({
    ...candidate,
    reachable: await videoIsReachable(candidate.hostedURL),
  }));
  const verified = reachability.filter((candidate) => candidate.reachable);

  if (!confirm) {
    console.log(JSON.stringify({
      mode: "dry_run",
      catalog_recipes_checked: recipes?.length ?? 0,
      update_candidates: candidates.length,
      verified_hosted_videos: verified.length,
      unreachable_hosted_videos: candidates.length - verified.length,
    }, null, 2));
    return;
  }

  let updated = 0;
  const failures = [];
  for (const candidate of verified) {
    let query = supabase
      .from("recipes")
      .update({ attached_video_url: candidate.hostedURL })
      .eq("id", candidate.recipeID);
    query = candidate.previousURL == null
      ? query.is("attached_video_url", null)
      : query.eq("attached_video_url", candidate.previousURL);

    const { data, error } = await query.select("id").maybeSingle();
    if (error) {
      failures.push({ recipe_id: candidate.recipeID, reason: error.message });
    } else if (data?.id) {
      updated += 1;
    }
  }

  console.log(JSON.stringify({
    mode: "confirmed",
    verified_hosted_videos: verified.length,
    updated,
    skipped_after_concurrent_change: verified.length - updated - failures.length,
    failures: failures.length,
    failure_details: failures.slice(0, 10),
  }, null, 2));
  if (failures.length) process.exitCode = 1;
}

await main();
