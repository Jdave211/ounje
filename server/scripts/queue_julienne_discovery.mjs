#!/usr/bin/env node
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";

import { queueRecipeIngestion } from "../lib/recipe-ingestion.js";
import { DEFAULT_ROUTES } from "./julienne_scraper.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const SUPABASE_URL = String(process.env.SUPABASE_URL ?? "").trim().replace(/\/+$/, "");
const SUPABASE_ANON_KEY = String(process.env.SUPABASE_ANON_KEY ?? "").trim();
const USER_AGENT =
  process.env.USER_AGENT ||
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const PLAYWRIGHT_FALLBACK_PATH = "/Users/davejaga/.openclaw/skills/playwright-scraper-skill/node_modules/playwright/index.js";

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_ANON_KEY in server/.env");
  process.exit(1);
}

function normalizeText(value) {
  return String(value ?? "")
    .replace(/\s+/g, " ")
    .trim();
}

function cleanURL(raw) {
  try {
    const url = new URL(String(raw ?? "").trim());
    url.hash = "";
    if (url.hostname.includes("youtube.com") && url.searchParams.has("v")) {
      return `https://www.youtube.com/watch?v=${url.searchParams.get("v")}`;
    }
    if (url.hostname === "youtu.be") {
      const id = url.pathname.split("/").filter(Boolean)[0] ?? "";
      return id ? `https://www.youtube.com/watch?v=${id}` : url.toString();
    }
    const removable = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "si", "feature"];
    removable.forEach((key) => url.searchParams.delete(key));
    return url.toString();
  } catch {
    return normalizeText(raw) || null;
  }
}

function extractJulienneRecipeID(rawURL) {
  const url = cleanURL(rawURL);
  if (!url) return null;
  const match = url.match(/\/recipes\/([0-9a-f-]{8,})/i);
  return match?.[1]?.toUpperCase?.() ?? null;
}

function buildInClause(values) {
  const quoted = (values ?? [])
    .map((value) => String(value ?? "").replace(/"/g, '\\"'))
    .filter(Boolean)
    .map((value) => `"${value}"`)
    .join(",");
  const clause = `(${quoted})`;
  return encodeURIComponent(clause);
}

function chunk(values, size = 50) {
  const list = [];
  for (let i = 0; i < values.length; i += size) {
    list.push(values.slice(i, i + size));
  }
  return list;
}

function parseArgs(argv) {
  const args = {
    headless: true,
    maxStepsPerRoute: 220,
    stagnantLimit: 35,
    routeLimit: null,
    enqueueChunkSize: 50,
    routes: [...DEFAULT_ROUTES],
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--headless") args.headless = true;
    else if (token === "--headed") args.headless = false;
    else if (token === "--max-steps") args.maxStepsPerRoute = Math.max(20, Number.parseInt(argv[index + 1] ?? "", 10) || args.maxStepsPerRoute), index += 1;
    else if (token === "--stagnant-limit") args.stagnantLimit = Math.max(8, Number.parseInt(argv[index + 1] ?? "", 10) || args.stagnantLimit), index += 1;
    else if (token === "--route-limit") args.routeLimit = Math.max(1, Number.parseInt(argv[index + 1] ?? "", 10) || 1), index += 1;
    else if (token === "--enqueue-chunk-size") args.enqueueChunkSize = Math.max(10, Number.parseInt(argv[index + 1] ?? "", 10) || args.enqueueChunkSize), index += 1;
    else if (token === "--routes") {
      const raw = String(argv[index + 1] ?? "").trim();
      const routes = raw.split(",").map((entry) => normalizeText(entry)).filter(Boolean);
      if (routes.length) args.routes = routes;
      index += 1;
    }
  }

  if (Number.isFinite(args.routeLimit) && args.routeLimit > 0) {
    args.routes = args.routes.slice(0, args.routeLimit);
  }

  return args;
}

async function loadPlaywright() {
  try {
    const localModule = await import(PLAYWRIGHT_FALLBACK_PATH);
    return localModule.default ?? localModule;
  } catch {
    const module = await import("playwright");
    return module.default ?? module;
  }
}

async function createBrowserContext({ headless = true } = {}) {
  const playwright = await loadPlaywright();
  const browser = await playwright.chromium.launch({ headless });
  const context = await browser.newContext({
    viewport: { width: 1450, height: 1700 },
    locale: "en-US",
    userAgent: USER_AGENT,
  });
  await context.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
  });
  return { browser, context };
}

async function collectVisibleRecipeURLs(page) {
  const urls = await page.evaluate(() => {
    const toAbsolute = (value) => {
      try {
        const url = new URL(String(value ?? ""), window.location.origin);
        url.hash = "";
        return url.toString();
      } catch {
        return null;
      }
    };

    const values = new Set();
    for (const anchor of Array.from(document.querySelectorAll('a[href*="/recipes/"]'))) {
      const href = anchor.getAttribute("href") || anchor.href || "";
      const absolute = toAbsolute(href);
      if (!absolute) continue;
      values.add(absolute);
    }
    return [...values];
  });

  return urls
    .map(cleanURL)
    .filter((url) => url && /withjulienne\.com\/.*\/recipes\//i.test(url));
}

async function clickLoadMore(page) {
  return page.evaluate(() => {
    const buttons = Array.from(document.querySelectorAll("button"));
    const target = buttons.find((button) => /load more/i.test(button.textContent || ""));
    if (!target || target.disabled) return false;
    target.scrollIntoView({ block: "center" });
    target.click();
    return true;
  });
}

async function discoverRoute(page, route, { maxStepsPerRoute, stagnantLimit }) {
  const seen = new Set();
  let stagnant = 0;

  await page.goto(route, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(4000);

  for (let step = 1; step <= maxStepsPerRoute; step += 1) {
    const urls = await collectVisibleRecipeURLs(page);
    let added = 0;
    for (const url of urls) {
      if (seen.has(url)) continue;
      seen.add(url);
      added += 1;
    }

    const loadMoreClicked = await clickLoadMore(page);
    if (loadMoreClicked) {
      await page.waitForTimeout(2200);
    } else {
      await page.evaluate(() => {
        window.scrollBy({ top: Math.floor(window.innerHeight * 0.88), behavior: "instant" });
      });
      await page.waitForTimeout(900);
    }

    stagnant = added > 0 ? 0 : stagnant + 1;
    console.log(
      `[discover] route=${route} step=${step} +${added} total=${seen.size} action=${loadMoreClicked ? "load_more" : "scroll"} stagnant=${stagnant}/${stagnantLimit}`
    );

    if (stagnant >= stagnantLimit) {
      break;
    }
  }

  return [...seen];
}

async function fetchRows(pathname) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/${pathname}`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    const message = data?.message ?? data?.error ?? response.statusText;
    throw new Error(`Supabase fetch failed (${response.status}): ${message}`);
  }
  return Array.isArray(data) ? data : [];
}

async function getExistingRecipeSignals() {
  const existingURLs = new Set();
  const existingRecipeIDs = new Set();
  const rows = await fetchRows("recipes?select=recipe_url,original_recipe_url,attached_video_url&limit=5000");

  for (const row of rows) {
    const values = [row.recipe_url, row.original_recipe_url, row.attached_video_url];
    for (const value of values) {
      const normalized = cleanURL(value);
      if (!normalized) continue;
      existingURLs.add(normalized);
      const recipeID = extractJulienneRecipeID(normalized);
      if (recipeID) existingRecipeIDs.add(recipeID);
    }
  }

  return { existingURLs, existingRecipeIDs };
}

function dedupeKeyForCanonicalURL(url) {
  const candidate = cleanURL(url);
  return candidate
    ? crypto.createHash("sha256").update(candidate).digest("hex")
    : null;
}

async function getExistingNonFailedJobKeys(dedupeKeys) {
  const existing = new Set();
  for (const batch of chunk(dedupeKeys.filter(Boolean), 120)) {
    if (!batch.length) continue;
    const clause = buildInClause(batch);
    const rows = await fetchRows(
      `recipe_ingestion_jobs?select=dedupe_key,status,user_id&user_id=is.null&status=neq.failed&dedupe_key=in.${clause}&limit=2000`
    );
    for (const row of rows) {
      if (row?.dedupe_key) existing.add(row.dedupe_key);
    }
  }
  return existing;
}

async function getExistingNonFailedJulienneRecipeIDs() {
  const recipeIDs = new Set();
  const rows = await fetchRows(
    "recipe_ingestion_jobs?select=source_url,canonical_url,status,user_id&user_id=is.null&status=neq.failed&limit=5000"
  );
  for (const row of rows) {
    const recipeID = extractJulienneRecipeID(row?.canonical_url ?? row?.source_url ?? null);
    if (recipeID) recipeIDs.add(recipeID);
  }
  return recipeIDs;
}

async function enqueueURLs(candidates, enqueueChunkSize) {
  const byStatus = new Map();
  let queuedNew = 0;

  for (const [index, batch] of chunk(candidates, enqueueChunkSize).entries()) {
    const results = await queueRecipeIngestion(
      {
        process_inline: false,
        sources: batch.map((candidate) => ({
          source_type: "web",
          source_url: candidate.source_url,
          canonical_url: candidate.canonical_url,
          target_state: "saved",
        })),
      },
      { processInline: false }
    );

    const rows = Array.isArray(results) ? results : [results];
    let queuedInBatch = 0;

    for (const row of rows) {
      const status = row?.job?.status ?? "unknown";
      byStatus.set(status, (byStatus.get(status) ?? 0) + 1);
      if (status === "queued") {
        queuedNew += 1;
        queuedInBatch += 1;
      }
    }

    console.log(
      `[enqueue] chunk=${index + 1}/${Math.ceil(urls.length / enqueueChunkSize)} size=${batch.length} queued=${queuedInBatch}`
    );
  }

  return {
    queuedNew,
    byStatus: Object.fromEntries([...byStatus.entries()].sort((a, b) => a[0].localeCompare(b[0]))),
  };
}

async function main() {
  const args = parseArgs(process.argv);
  const started = new Date();

  const { browser, context } = await createBrowserContext({ headless: args.headless });
  const page = await context.newPage();
  page.setDefaultTimeout(45_000);
  page.setDefaultNavigationTimeout(60_000);

  const discovered = new Set();

  try {
    for (const route of args.routes) {
      const routeURLs = await discoverRoute(page, route, args);
      for (const url of routeURLs) discovered.add(url);
      console.log(`[discover] route_done=${route} route_unique=${routeURLs.length} global_unique=${discovered.size}`);
    }
  } finally {
    await page.close().catch(() => {});
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
  }

  const discoveredList = [...discovered].map(cleanURL).filter(Boolean);
  const discoveredByRecipeID = new Map();
  const discoveredWithoutRecipeID = [];

  for (const url of discoveredList) {
    const recipeID = extractJulienneRecipeID(url);
    if (recipeID) {
      if (!discoveredByRecipeID.has(recipeID)) {
        discoveredByRecipeID.set(recipeID, {
          source_url: url,
          recipe_id: recipeID,
          canonical_url: `https://withjulienne.com/recipes/${recipeID}`,
        });
      }
      continue;
    }

    discoveredWithoutRecipeID.push({
      source_url: url,
      recipe_id: null,
      canonical_url: url,
    });
  }

  const dedupedCandidates = [...discoveredByRecipeID.values(), ...discoveredWithoutRecipeID];
  const { existingURLs: existingRecipeURLs, existingRecipeIDs } = await getExistingRecipeSignals();
  const existingJobRecipeIDs = await getExistingNonFailedJulienneRecipeIDs();
  const dedupeKeys = dedupedCandidates.map((candidate) => dedupeKeyForCanonicalURL(candidate.canonical_url));
  const existingJobKeys = await getExistingNonFailedJobKeys(dedupeKeys);

  const filtered = dedupedCandidates.filter((candidate) => {
    if (candidate.recipe_id && existingRecipeIDs.has(candidate.recipe_id)) return false;
    if (candidate.recipe_id && existingJobRecipeIDs.has(candidate.recipe_id)) return false;
    if (!candidate.recipe_id && existingRecipeURLs.has(candidate.source_url)) return false;
    const key = dedupeKeyForCanonicalURL(candidate.canonical_url);
    if (!key) return false;
    return !existingJobKeys.has(key);
  });

  const enqueueSummary = await enqueueURLs(filtered, args.enqueueChunkSize);
  const ended = new Date();

  const summary = {
    started_at: started.toISOString(),
    ended_at: ended.toISOString(),
    duration_seconds: Math.round((ended.getTime() - started.getTime()) / 1000),
    headless: args.headless,
    routes_scanned: args.routes.length,
    discovered_recipe_urls: discoveredList.length,
    discovered_unique_by_recipe_id: dedupedCandidates.length,
    skipped_existing_recipe_urls: existingRecipeURLs.size,
    skipped_existing_recipe_ids: existingRecipeIDs.size,
    skipped_existing_nonfailed_job_recipe_ids: existingJobRecipeIDs.size,
    skipped_existing_nonfailed_jobs: existingJobKeys.size,
    queue_candidates: filtered.length,
    queued_new_jobs: enqueueSummary.queuedNew,
    result_status_counts: enqueueSummary.byStatus,
  };

  console.log(JSON.stringify(summary, null, 2));
}

main().catch((error) => {
  console.error(`[queue-julienne-discovery] fatal: ${error.message}`);
  process.exit(1);
});
