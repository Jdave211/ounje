#!/usr/bin/env node
// Discovers public short-form recipe links and stages them for the shared catalog.
// Discovery is non-mutating by default. Add --enqueue --confirm-public-catalog to queue.

import crypto from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";

import { searchWeb } from "../lib/growth-outreach-agent.js";
import { queueRecipeIngestion } from "../lib/recipe-ingestion.js";
import { getServiceRoleSupabase } from "../lib/supabase-clients.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const DISCOVERY_QUERIES = [
  'site:tiktok.com/video "chicken skewers" recipe',
  'site:tiktok.com/video "banana bread" recipe',
  'site:tiktok.com/video "french toast" recipe',
  'site:tiktok.com/video "puff puff" recipe',
  'site:tiktok.com/video "suya" recipe',
  'site:tiktok.com/video "plantain sushi" recipe',
  'site:tiktok.com/video "jollof rice and chicken" recipe',
  'site:tiktok.com/video "Nigerian chicken" recipe',
  'site:tiktok.com/video "plantain" recipe easy',
  'site:tiktok.com/video "chocolate dessert" recipe',
  'site:tiktok.com/video "cheesecake" recipe',
  'site:tiktok.com/video "cinnamon rolls" recipe',
  'site:tiktok.com/video "brownies" recipe',
  'site:tiktok.com/video "cookies" recipe',
  'site:tiktok.com/video "easy pasta" recipe',
  'site:tiktok.com/video "creamy chicken" recipe',
  'site:tiktok.com/video "crispy chicken" recipe',
  'site:tiktok.com/video "garlic butter shrimp" recipe',
  'site:tiktok.com/video "salmon bites" recipe',
  'site:tiktok.com/video "rice bowl" recipe',
  'site:tiktok.com/video "loaded potatoes" recipe',
  'site:tiktok.com/video "breakfast sandwich" recipe',
  'site:tiktok.com/video "pancakes" recipe',
  'site:tiktok.com/video "waffles" recipe',
  'site:tiktok.com/video "air fryer chicken" recipe',
  'site:tiktok.com/video "one pot dinner" recipe',
  'site:tiktok.com/video "easy weeknight dinner" recipe',
  'site:tiktok.com/video "high protein dinner" recipe',
  'site:tiktok.com/video "meal prep chicken" recipe',
  'site:tiktok.com/video "tacos" recipe',
  'site:tiktok.com/video "burger" recipe',
  'site:tiktok.com/video "mac and cheese" recipe',
  'site:tiktok.com/video "pizza" recipe',
  'site:tiktok.com/video "grilled cheese" recipe',
  'site:tiktok.com/video "chicken curry" recipe',
  'site:tiktok.com/video "beef stir fry" recipe',
  'site:tiktok.com/video "fried rice" recipe',
  'site:tiktok.com/video "chicken wings" recipe',
  'site:tiktok.com/video "dessert cups" recipe',
  'site:tiktok.com/video "no bake dessert" recipe',
  'site:tiktok.com/video "tiramisu" recipe',
  'site:tiktok.com/video "lemon dessert" recipe',
  'site:tiktok.com/video "strawberry dessert" recipe',
  'site:tiktok.com/video "biscoff dessert" recipe',
  'site:tiktok.com/video "Nigerian food combination" recipe',
  'site:tiktok.com/video "plantain and chicken" recipe',
  'site:tiktok.com/video "plantain and eggs" recipe',
  'site:tiktok.com/video "suya chicken" recipe',
];

function normalizeText(value) {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

function parseArgs(argv) {
  const args = {
    enqueue: false,
    confirmed: false,
    queryLimit: 14,
    maxQueries: DISCOVERY_QUERIES.length,
    target: null,
    manifest: null,
    directTikTok: false,
    reuseExistingImports: false,
    headful: false,
    profileLimit: null,
    challengeWaitSeconds: 0,
  };
  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--enqueue") args.enqueue = true;
    else if (token === "--confirm-public-catalog") args.confirmed = true;
    else if (token === "--query-limit") args.queryLimit = Math.max(5, Math.min(30, Number.parseInt(argv[index + 1] ?? "", 10) || args.queryLimit)), index += 1;
    else if (token === "--max-queries") args.maxQueries = Math.max(1, Math.min(DISCOVERY_QUERIES.length, Number.parseInt(argv[index + 1] ?? "", 10) || 1)), index += 1;
    else if (token === "--target") args.target = Math.max(1, Number.parseInt(argv[index + 1] ?? "", 10) || 1), index += 1;
    else if (token === "--manifest") args.manifest = path.resolve(argv[index + 1] ?? ""), index += 1;
    else if (token === "--direct-tiktok") args.directTikTok = true;
    else if (token === "--reuse-existing-imports") args.reuseExistingImports = true;
    else if (token === "--headful") args.headful = true;
    else if (token === "--profile-limit") args.profileLimit = Math.max(1, Number.parseInt(argv[index + 1] ?? "", 10) || 1), index += 1;
    else if (token === "--challenge-wait-seconds") args.challengeWaitSeconds = Math.max(0, Number.parseInt(argv[index + 1] ?? "", 10) || 0), index += 1;
  }
  if (args.enqueue && !args.confirmed) {
    throw new Error("Refusing to queue public recipes without --confirm-public-catalog.");
  }
  return args;
}

function socialPlatformForURL(value) {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    if (host.includes("tiktok.com")) return "tiktok";
    if (host.includes("instagram.com")) return "instagram";
  } catch {}
  return null;
}

function canonicalSocialURL(value) {
  try {
    const url = new URL(value);
    url.hash = "";
    url.search = "";
    const host = url.hostname.toLowerCase();
    const parts = url.pathname.split("/").filter(Boolean);
    if (host.includes("tiktok.com")) {
      const videoIndex = parts.findIndex((part) => part.toLowerCase() === "video");
      if (videoIndex > 0 && parts[videoIndex + 1]) {
        return `https://www.tiktok.com/${parts.slice(0, videoIndex + 2).join("/")}`;
      }
      if (["vm.tiktok.com", "vt.tiktok.com"].includes(host) && parts[0]) return `https://${host}/${parts[0]}`;
      return null;
    }
    if (host.includes("instagram.com") && ["reel", "p", "tv"].includes(parts[0]?.toLowerCase()) && parts[1]) {
      return `https://www.instagram.com/${parts[0].toLowerCase()}/${parts[1]}`;
    }
  } catch {}
  return null;
}

function rowHasSocialSource(row) {
  const source = normalizeText(row?.source_platform).toLowerCase();
  return source === "tiktok" || source === "instagram";
}

function rowHasTikTokSource(row) {
  return normalizeText(row?.source_platform).toLowerCase() === "tiktok"
    || urlsForRow(row).some((url) => socialPlatformForURL(url) === "tiktok");
}

function tiktokCreatorHandle(value) {
  const canonicalURL = canonicalSocialURL(value);
  if (!canonicalURL) return null;
  try {
    const parts = new URL(canonicalURL).pathname.split("/").filter(Boolean);
    const handle = parts.find((part) => part.startsWith("@"));
    return handle?.slice(1).trim().toLowerCase() || null;
  } catch {
    return null;
  }
}

function urlsForRow(row) {
  return [row?.recipe_url, row?.original_recipe_url, row?.attached_video_url]
    .map(canonicalSocialURL)
    .filter(Boolean);
}

async function allRows(query) {
  const { data, error } = await query;
  if (error) throw new Error(error.message);
  return Array.isArray(data) ? data : [];
}

async function loadInventory(supabase) {
  const [privateRows, publicRows, jobRows] = await Promise.all([
    allRows(supabase.from("user_import_recipes").select("source_platform,source,recipe_url,original_recipe_url,attached_video_url").limit(5000)),
    allRows(supabase.from("recipes").select("source_platform,source,recipe_url,original_recipe_url,attached_video_url").limit(5000)),
    allRows(supabase.from("recipe_ingestion_jobs").select("source_type,source_url,canonical_url,status").is("user_id", null).limit(5000)),
  ]);

  const existingURLs = new Set();
  for (const row of [...publicRows, ...jobRows]) {
    for (const url of [...urlsForRow(row), canonicalSocialURL(row?.source_url), canonicalSocialURL(row?.canonical_url)]) {
      if (url) existingURLs.add(url);
    }
  }

  const reusableTikTokCandidates = [];
  const seenReusableURLs = new Set(existingURLs);
  for (const row of privateRows.filter(rowHasTikTokSource)) {
    for (const sourceURL of urlsForRow(row)) {
      if (socialPlatformForURL(sourceURL) !== "tiktok" || seenReusableURLs.has(sourceURL)) continue;
      seenReusableURLs.add(sourceURL);
      reusableTikTokCandidates.push({
        source_url: sourceURL,
        canonical_url: sourceURL,
        source_type: "tiktok",
        source_query: "existing-private-import",
        search_provider: null,
        search_title: null,
        search_snippet: null,
      });
    }
  }

  return {
    privateSocialImports: privateRows.filter(rowHasSocialSource).length,
    publicSocialRecipes: publicRows.filter(rowHasSocialSource).length,
    privateTikTokImports: privateRows.filter(rowHasTikTokSource).length,
    publicTikTokRecipes: publicRows.filter(rowHasTikTokSource).length,
    tiktokCreatorHandles: [...new Set(
      privateRows
        .filter(rowHasTikTokSource)
        .flatMap(urlsForRow)
        .map(tiktokCreatorHandle)
        .filter(Boolean),
    )],
    reusableTikTokCandidates,
    existingURLs,
  };
}

function isTikTokChallengeText(value) {
  const text = normalizeText(value).toLowerCase();
  return text.includes("drag the slider to fit the puzzle")
    || text.includes("verify to continue")
    || text.includes("complete the puzzle");
}

async function waitForTikTokChallenge(page, waitSeconds) {
  const deadline = Date.now() + (waitSeconds * 1000);
  while (true) {
    const bodyText = await page.locator("body").innerText().catch(() => "");
    if (!isTikTokChallengeText(bodyText)) return;
    if (Date.now() >= deadline) {
      throw new Error(
        "TikTok presented a slider challenge. Re-run with --headful --challenge-wait-seconds 180 and complete it in the opened browser.",
      );
    }
    await page.waitForTimeout(1000);
  }
}

async function discoverDirectTikTokCandidates({
  target,
  existingURLs,
  creatorHandles,
  previousCandidates = [],
  headful,
  profileLimit,
  challengeWaitSeconds,
}) {
  const { chromium } = await import("playwright");
  const profilePath = path.resolve(process.cwd(), "tmp", "tiktok-catalog-browser-profile");
  await mkdir(profilePath, { recursive: true });
  const context = await chromium.launchPersistentContext(profilePath, {
    channel: "chrome",
    headless: !headful,
    viewport: { width: 1280, height: 900 },
  });
  const page = context.pages()[0] ?? await context.newPage();
  const candidates = previousCandidates.filter((candidate) => candidate?.source_type === "tiktok");
  const seen = new Set([
    ...existingURLs,
    ...candidates.map((candidate) => canonicalSocialURL(candidate?.source_url)).filter(Boolean),
  ]);
  const selectedHandles = profileLimit ? creatorHandles.slice(0, profileLimit) : creatorHandles;
  let profilesWithVideoLinks = 0;

  try {
    for (const handle of selectedHandles) {
      if (candidates.length >= target) break;
      const profileURL = `https://www.tiktok.com/@${handle}`;
      await page.goto(profileURL, { waitUntil: "domcontentloaded", timeout: 30_000 });
      await page.waitForTimeout(1200);
      await waitForTikTokChallenge(page, challengeWaitSeconds);

      let profileLinkCount = 0;
      for (let pass = 0; pass < 4 && candidates.length < target; pass += 1) {
        const links = await page.locator('a[href*="/video/"]').evaluateAll((elements) => (
          elements.slice(0, 80).map((element) => element.href)
        ));
        profileLinkCount = Math.max(profileLinkCount, links.length);
        for (const value of links) {
          const canonicalURL = canonicalSocialURL(value);
          if (!canonicalURL || seen.has(canonicalURL)) continue;
          seen.add(canonicalURL);
          candidates.push({
            source_url: canonicalURL,
            canonical_url: canonicalURL,
            source_type: "tiktok",
            source_query: `creator:@${handle}`,
            search_provider: null,
            search_title: null,
            search_snippet: null,
          });
          if (candidates.length >= target) break;
        }
        if (candidates.length >= target) break;
        await page.mouse.wheel(0, 1800);
        await page.waitForTimeout(900);
      }
      if (profileLinkCount > 0) {
        profilesWithVideoLinks += 1;
      } else {
        const bodyText = await page.locator("body").innerText().catch(() => "");
        if (isTikTokChallengeText(bodyText) || normalizeText(bodyText).toLowerCase().includes("please wait")) {
          throw new Error(
            "TikTok blocked the creator feed behind a browser challenge. Re-run with --headful --challenge-wait-seconds 180 and complete it in the opened browser.",
          );
        }
      }
    }
  } finally {
    await context.close();
  }

  if (profilesWithVideoLinks === 0 && candidates.length === 0) {
    throw new Error(
      "TikTok returned no creator video links. Re-run with --headful --challenge-wait-seconds 180 so the browser session can be verified.",
    );
  }

  return candidates;
}

async function discoverCandidates({ target, queryLimit, maxQueries, existingURLs, previousCandidates = [] }) {
  const candidates = [...previousCandidates];
  const seen = new Set([
    ...existingURLs,
    ...previousCandidates.map((candidate) => canonicalSocialURL(candidate?.source_url)).filter(Boolean),
  ]);
  const desiredCandidates = Math.max(target * 2, target + 24);

  for (const query of DISCOVERY_QUERIES.slice(0, maxQueries)) {
    if (candidates.length >= desiredCandidates) break;
    const results = await searchWeb(query, { limit: queryLimit });
    for (const result of results) {
      const canonicalURL = canonicalSocialURL(result?.url);
      const platform = socialPlatformForURL(canonicalURL);
      if (!canonicalURL || !platform || seen.has(canonicalURL)) continue;
      seen.add(canonicalURL);
      candidates.push({
        source_url: canonicalURL,
        canonical_url: canonicalURL,
        source_type: platform,
        source_query: query,
        search_provider: normalizeText(result?.source) || null,
        search_title: normalizeText(result?.title) || null,
        search_snippet: normalizeText(result?.snippet) || null,
      });
    }
  }
  return candidates;
}

function defaultManifestPath() {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  return path.resolve(process.cwd(), "tmp", `social-catalog-seed-${stamp}.json`);
}

async function writeManifest(manifestPath, manifest) {
  await mkdir(path.dirname(manifestPath), { recursive: true });
  const pendingPath = `${manifestPath}.pending`;
  await writeFile(pendingPath, `${JSON.stringify(manifest, null, 2)}\n`);
  await rename(pendingPath, manifestPath);
}

async function loadPreviousCandidates(manifestPath) {
  try {
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    if (!Array.isArray(manifest?.candidates)) return [];
    const seen = new Set();
    return manifest.candidates.filter((candidate) => {
      const canonicalURL = canonicalSocialURL(candidate?.source_url);
      if (!canonicalURL || seen.has(canonicalURL)) return false;
      seen.add(canonicalURL);
      return true;
    });
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw new Error(`Could not read existing discovery manifest: ${error.message}`);
  }
}

async function enqueueCandidates(candidates, target) {
  const selected = candidates.slice(0, target);
  const results = await queueRecipeIngestion({
    process_inline: false,
    sources: selected.map((candidate) => ({
      source_url: candidate.source_url,
      target_state: "saved",
      public_catalog_import: true,
    })),
  });
  const jobs = (Array.isArray(results) ? results : [results]).map((result, index) => ({
    source_url: selected[index]?.source_url ?? null,
    job_id: result?.job?.id ?? null,
    status: result?.job?.status ?? "unknown",
  }));
  return { selected: selected.length, jobs };
}

async function main() {
  const args = parseArgs(process.argv);
  const supabase = getServiceRoleSupabase();
  const inventory = await loadInventory(supabase);
  const requestedTarget = args.target ?? (
    args.directTikTok || args.reuseExistingImports
      ? inventory.privateTikTokImports
      : inventory.privateSocialImports
  );
  if (!requestedTarget) throw new Error("No matching private social imports found; provide --target to set a catalog target.");

  const existingPublicCount = args.directTikTok || args.reuseExistingImports
    ? inventory.publicTikTokRecipes
    : inventory.publicSocialRecipes;
  const target = args.reuseExistingImports
    ? Math.min(requestedTarget, existingPublicCount + inventory.reusableTikTokCandidates.length)
    : requestedTarget;
  const remaining = args.directTikTok
    ? target
    : Math.max(0, target - existingPublicCount);
  const manifestPath = args.manifest ?? defaultManifestPath();
  const previousCandidates = await loadPreviousCandidates(manifestPath);
  const candidates = !remaining
    ? previousCandidates
    : args.reuseExistingImports
      ? inventory.reusableTikTokCandidates.slice(0, remaining)
      : args.directTikTok
      ? await discoverDirectTikTokCandidates({
        target: remaining,
        existingURLs: inventory.existingURLs,
        creatorHandles: inventory.tiktokCreatorHandles,
        previousCandidates,
        headful: args.headful,
        profileLimit: args.profileLimit,
        challengeWaitSeconds: args.challengeWaitSeconds,
      })
      : await discoverCandidates({
        target: remaining,
        queryLimit: args.queryLimit,
        maxQueries: args.maxQueries,
        existingURLs: inventory.existingURLs,
        previousCandidates,
      })
  ;
  const manifest = {
    run_id: `social_catalog_${crypto.randomUUID()}`,
    created_at: new Date().toISOString(),
    inventory: {
      private_social_imports: inventory.privateSocialImports,
      public_social_recipes: inventory.publicSocialRecipes,
      private_tiktok_imports: inventory.privateTikTokImports,
      reusable_private_tiktok_links: inventory.reusableTikTokCandidates.length,
      public_tiktok_recipes: inventory.publicTikTokRecipes,
      tiktok_creator_profiles: inventory.tiktokCreatorHandles.length,
      requested_public_social_recipes: requestedTarget,
      available_unique_public_social_recipes: target,
      remaining_public_social_recipes: remaining,
    },
    candidates,
    carried_forward_candidates: previousCandidates.length,
    queued: null,
  };

  if (args.enqueue && remaining) {
    if (candidates.length < remaining) {
      throw new Error(`Only discovered ${candidates.length} unique candidates for ${remaining} remaining recipes; refine the search before enqueueing.`);
    }
    manifest.queued = await enqueueCandidates(candidates, remaining);
  }

  await writeManifest(manifestPath, manifest);
  if (args.directTikTok && remaining && candidates.length < remaining) {
    throw new Error(
      `Direct TikTok crawl staged ${candidates.length} of ${remaining} requested links. The partial manifest is at ${manifestPath}.`,
    );
  }
  console.log(JSON.stringify({
    manifest: manifestPath,
    private_social_imports: inventory.privateSocialImports,
    public_social_recipes: inventory.publicSocialRecipes,
    private_tiktok_imports: inventory.privateTikTokImports,
    reusable_private_tiktok_links: inventory.reusableTikTokCandidates.length,
    public_tiktok_recipes: inventory.publicTikTokRecipes,
    tiktok_creator_profiles: inventory.tiktokCreatorHandles.length,
    target,
    requested_target: requestedTarget,
    remaining,
    discovered_candidates: candidates.length,
    queued: manifest.queued?.selected ?? 0,
  }, null, 2));
}

await main();
