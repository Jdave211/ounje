#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";

import { promoteUserImportedRecipeToCatalog } from "../lib/recipe-ingestion.js";
import { getServiceRoleSupabase } from "../lib/supabase-clients.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

function canonicalSocialURL(value) {
  try {
    const url = new URL(value);
    url.hash = "";
    url.search = "";
    const host = url.hostname.toLowerCase();
    const parts = url.pathname.split("/").filter(Boolean);
    if (!host.includes("tiktok.com")) return null;
    const videoIndex = parts.findIndex((part) => part.toLowerCase() === "video");
    if (videoIndex > 0 && parts[videoIndex + 1]) {
      return `https://www.tiktok.com/${parts.slice(0, videoIndex + 2).join("/")}`;
    }
    if (["vm.tiktok.com", "vt.tiktok.com"].includes(host) && parts[0]) {
      return `https://${host}/${parts[0]}`;
    }
  } catch {}
  return null;
}

function parseArgs(argv) {
  const args = { manifest: null, confirm: false };
  for (let index = 2; index < argv.length; index += 1) {
    if (argv[index] === "--manifest") args.manifest = path.resolve(argv[index + 1] ?? ""), index += 1;
    else if (argv[index] === "--confirm-public-catalog") args.confirm = true;
  }
  if (!args.manifest) throw new Error("Provide --manifest with the queued existing-import catalog manifest.");
  if (!args.confirm) throw new Error("Refusing to publish without --confirm-public-catalog.");
  return args;
}

async function main() {
  const args = parseArgs(process.argv);
  const manifest = JSON.parse(await readFile(args.manifest, "utf8"));
  const queuedJobs = Array.isArray(manifest?.queued?.jobs) ? manifest.queued.jobs : [];
  const candidateURLs = new Set(
    (manifest?.candidates ?? []).map((candidate) => canonicalSocialURL(candidate?.source_url)).filter(Boolean)
  );
  if (!candidateURLs.size || !queuedJobs.length) throw new Error("The manifest has no queued existing-import candidates.");

  const supabase = getServiceRoleSupabase();
  const { data: importedRows, error } = await supabase
    .from("user_import_recipes")
    .select("id,recipe_url,original_recipe_url,attached_video_url,review_state")
    .in("review_state", ["approved", "adapted_preview"])
    .limit(5000);
  if (error) throw new Error(error.message);

  const importedRecipeByURL = new Map();
  for (const row of importedRows ?? []) {
    for (const value of [row.recipe_url, row.original_recipe_url, row.attached_video_url]) {
      const canonicalURL = canonicalSocialURL(value);
      if (canonicalURL && candidateURLs.has(canonicalURL) && !importedRecipeByURL.has(canonicalURL)) {
        importedRecipeByURL.set(canonicalURL, row.id);
      }
    }
  }

  const jobsByURL = new Map();
  for (const job of queuedJobs) {
    const canonicalURL = canonicalSocialURL(job?.source_url);
    if (!canonicalURL || !job?.job_id) continue;
    const jobs = jobsByURL.get(canonicalURL) ?? [];
    jobs.push(job.job_id);
    jobsByURL.set(canonicalURL, jobs);
  }

  const promotedByImportID = new Map();
  const failures = [];
  let completedJobs = 0;
  for (const [sourceURL, importedRecipeID] of importedRecipeByURL) {
    try {
      let promoted = promotedByImportID.get(importedRecipeID);
      if (!promoted) {
        promoted = await promoteUserImportedRecipeToCatalog(importedRecipeID);
        promotedByImportID.set(importedRecipeID, promoted);
        await supabase
          .from("user_import_recipes")
          .update({ accepted_recipe_id: promoted.catalog_recipe_id })
          .eq("id", importedRecipeID);
      }

      for (const jobID of jobsByURL.get(sourceURL) ?? []) {
        const now = new Date().toISOString();
        const { error: updateError } = await supabase
          .from("recipe_ingestion_jobs")
          .update({
            recipe_id: promoted.catalog_recipe_id,
            dedupe_recipe_id: promoted.catalog_recipe_id,
            status: "saved",
            review_state: "approved",
            confidence_score: 0.98,
            quality_flags: ["promoted_existing_import"],
            review_reason: null,
            error_message: null,
            worker_id: null,
            leased_at: null,
            saved_at: now,
            completed_at: now,
          })
          .eq("id", jobID)
          .is("user_id", null);
        if (updateError) throw new Error(updateError.message);
        completedJobs += 1;
      }
    } catch (promotionError) {
      failures.push({ imported_recipe_id: importedRecipeID, reason: promotionError.message });
    }
  }

  console.log(JSON.stringify({
    candidate_links: candidateURLs.size,
    matched_imports: new Set(importedRecipeByURL.values()).size,
    promoted_recipes: promotedByImportID.size,
    completed_jobs: completedJobs,
    failures: failures.length,
    failure_details: failures.slice(0, 10),
  }, null, 2));

  if (failures.length) process.exitCode = 1;
}

await main();
