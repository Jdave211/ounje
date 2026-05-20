import fsSync from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { chromium } from "playwright";
import { createLoggedOpenAI, withAIUsageContext } from "./openai-usage-logger.js";
import { buildPlaywrightLaunchOptions } from "./playwright-runtime.js";
import { getServiceRoleSupabase } from "./supabase-clients.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../..");
const DEFAULT_CONFIG_PATH = path.resolve(__dirname, "../config/growth-outreach.json");
const DEFAULT_LOCAL_OUTPUT_DIR = path.resolve(repoRoot, "tmp/growth-outreach");
const DEFAULT_PLAYWRIGHT_PROFILE_DIR = path.resolve(repoRoot, "tmp/growth-outreach/playwright-profile");

const RUNS_TABLE = "growth_outreach_runs";
const QUORA_CANDIDATES_TABLE = "quora_question_candidates";
const QUORA_DRAFTS_TABLE = "quora_answer_drafts";
const ROUNDUP_OPPORTUNITIES_TABLE = "roundup_list_opportunities";
const ROUNDUP_DRAFTS_TABLE = "roundup_pitch_drafts";
const BROWSER_USE_BASE = "https://api.browser-use.com/api/v3";

const GROWTH_JOB_KIND = "growth_outreach_run";
const DEFAULT_SEARCH_LIMIT = 10;
const DEFAULT_OPENAI_MODEL = "gpt-4o-mini";
const HUMANIZER_SYSTEM_PROMPT = [
  "Rewrite AI-sounding growth drafts so they read like a specific person wrote them.",
  "Preserve meaning, facts, links, and required affiliation disclosures.",
  "Remove chatbot filler, sycophancy, generic conclusions, press-release phrasing, and words like delve, vibrant, crucial, comprehensive, robust, seamless, groundbreaking, leverage, synergy, transformative, paramount, multifaceted, myriad, cornerstone, reimagine, empower, catalyst, invaluable, bustling, nestled, and realm.",
  "Use plain verbs like is and has. Vary sentence length. Let the writing sound useful, slightly opinionated, and concrete.",
  "Do not make the answer more promotional. Ounje should appear only where it naturally helps the reader.",
].join(" ");
let warnedMissingSearchProvider = false;

function normalizeText(value, maxLength = 0) {
  const normalized = String(value ?? "").replace(/\s+/g, " ").trim();
  if (!maxLength || normalized.length <= maxLength) return normalized;
  return normalized.slice(0, maxLength).trim();
}

function normalizeBodyText(value, maxLength = 0) {
  const normalized = String(value ?? "")
    .replace(/\r\n/g, "\n")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
  if (!maxLength || normalized.length <= maxLength) return normalized;
  return normalized.slice(0, maxLength).trim();
}

function normalizeURL(value) {
  const raw = normalizeText(value, 2048);
  if (!raw) return "";
  try {
    const url = new URL(raw);
    url.hash = "";
    return url.toString();
  } catch {
    return raw;
  }
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function clamp(value, min, max) {
  const number = Number(value);
  if (!Number.isFinite(number)) return min;
  return Math.min(max, Math.max(min, number));
}

function uniqueByURL(items) {
  const seen = new Set();
  const unique = [];
  for (const item of items) {
    const url = normalizeURL(item?.url);
    if (!url || seen.has(url)) continue;
    seen.add(url);
    unique.push({ ...item, url });
  }
  return unique;
}

function getEnv(name) {
  return normalizeText(process.env[name]);
}

function fileExists(filePath) {
  try {
    return Boolean(filePath) && fsSync.existsSync(filePath);
  } catch {
    return false;
  }
}

function resolveSystemChromeExecutable() {
  if (process.platform === "darwin") {
    const candidates = [
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    ];
    return candidates.find(fileExists) ?? null;
  }

  return null;
}

function normalizeStorage(value) {
  const storage = normalizeText(value).toLowerCase();
  if (storage === "local" || storage === "supabase") return storage;
  return "supabase";
}

function makeLocalID(prefix) {
  return `${prefix}_${new Date().toISOString().replace(/[:.]/g, "-")}_${Math.random().toString(36).slice(2, 8)}`;
}

async function writeJSONFile(filePath, value) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(`${filePath}.tmp`, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await fs.rename(`${filePath}.tmp`, filePath);
}

function mergeAppConfig(app = {}) {
  const publicURL = getEnv("OUNJE_APP_DOWNLOAD_URL")
    || getEnv("OUNJE_PUBLIC_BASE_URL")
    || normalizeText(app.public_url)
    || "https://ounje-idbl.onrender.com";

  return {
    name: normalizeText(app.name) || "Ounje",
    description: normalizeText(app.description) || "Ounje helps people turn recipes and cravings into meal prep plans and grocery lists.",
    publicURL,
    contactName: getEnv("GROWTH_OUTREACH_CONTACT_NAME") || normalizeText(app.contact_name) || "Dave",
    contactEmail: getEnv("GROWTH_OUTREACH_CONTACT_EMAIL") || normalizeText(app.contact_email) || "thisisounje@gmail.com",
    features: asArray(app.features).map((feature) => normalizeText(feature)).filter(Boolean),
    positioning: asArray(app.positioning).map((item) => normalizeText(item)).filter(Boolean),
  };
}

export async function loadGrowthOutreachConfig({ configPath = DEFAULT_CONFIG_PATH, overrides = {} } = {}) {
  let base = {};
  try {
    const raw = await fs.readFile(configPath, "utf8");
    base = JSON.parse(raw);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  return {
    ...base,
    ...overrides,
    app: mergeAppConfig({ ...(base.app ?? {}), ...(overrides.app ?? {}) }),
    quora: { ...(base.quora ?? {}), ...(overrides.quora ?? {}) },
    roundups: { ...(base.roundups ?? {}), ...(overrides.roundups ?? {}) },
  };
}

export function buildQuoraSearchQueries(config = {}) {
  const queries = asArray(config.quora?.queries)
    .map((query) => normalizeText(query))
    .filter(Boolean);
  if (queries.length) return queries;

  return [
    "site:quora.com meal planning app grocery list recipes",
    "site:quora.com recipe organizer app grocery list",
    "site:quora.com how to meal prep from saved recipes",
  ];
}

export function buildRoundupSearchQueries(config = {}) {
  const queries = asArray(config.roundups?.queries)
    .map((query) => normalizeText(query))
    .filter(Boolean);
  if (queries.length) return queries;

  return [
    "best meal planning apps",
    "best recipe organizer apps",
    "best grocery list apps for meal prep",
  ];
}

function keywordCount(haystack, keywords) {
  return keywords.reduce((count, keyword) => count + (haystack.includes(keyword) ? 1 : 0), 0);
}

export function evaluateQuoraCandidateHeuristic(candidate, config = {}) {
  const title = normalizeText(candidate?.title);
  const snippet = normalizeText(candidate?.snippet);
  const url = normalizeURL(candidate?.url);
  const haystack = `${title} ${snippet} ${url}`.toLowerCase();

  const helpfulMatches = keywordCount(haystack, [
    "meal plan",
    "meal prep",
    "recipe",
    "recipes",
    "grocery",
    "groceries",
    "fridge",
    "pantry",
    "cook",
    "cooking",
    "restaurant",
    "takeout",
    "tiktok",
    "saved",
    "ingredients",
  ]);
  const appMatches = keywordCount(haystack, ["app", "tool", "organize", "list", "plan", "planner"]);
  const workflowMatches = keywordCount(haystack, [
    "meal planning",
    "meal plan",
    "meal prep",
    "grocery list",
    "shopping list",
    "recipe organizer",
    "organise your recipes",
    "organize your recipes",
    "store and organise",
    "store and organize",
    "ingredients in my fridge",
    "ingredients currently in your refrigerator",
    "what can i cook",
    "saved recipes",
    "recipe videos",
    "food videos",
  ]);
  const avoidMatches = keywordCount(haystack, [
    "weight loss",
    "diet cure",
    "medical",
    "diabetes",
    "eating disorder",
    "allergy",
    "bad cooks",
    "voice assistant",
    "voice assistants",
    "marry a chef",
    "junk food",
    "one habit",
    ...asArray(config.quora?.avoid_topics).map((item) => normalizeText(item).toLowerCase()),
  ]);

  let score = 0.18 + helpfulMatches * 0.07 + appMatches * 0.04;
  if (url.includes("quora.com/")) score += 0.18;
  if (title.endsWith("?")) score += 0.06;
  if (workflowMatches === 0) score -= 0.28;
  if (avoidMatches > 0) score -= Math.min(0.45, avoidMatches * 0.15);
  score = clamp(score, 0, 0.98);

  const primaryAngle = haystack.includes("fridge") || haystack.includes("pantry")
    ? "Explain a practical fridge-to-dinner workflow before mentioning Ounje as one optional tool."
    : haystack.includes("restaurant") || haystack.includes("takeout")
      ? "Explain how to recreate the structure of a restaurant meal without claiming to copy proprietary recipes."
      : haystack.includes("tiktok") || haystack.includes("saved")
        ? "Explain how to turn saved food videos or recipe screenshots into a clean recipe and shopping list."
        : "Explain a simple meal planning and grocery-list workflow, then mention Ounje only if directly useful.";

  return {
    relevanceScore: Number(score.toFixed(2)),
    fitReason: helpfulMatches > 0
      ? `Matched ${helpfulMatches} cooking or grocery planning signals and ${appMatches} app/workflow signals.`
      : "Weak fit; needs human review before drafting.",
    answerAngle: primaryAngle,
    blockedReason: avoidMatches > 0 ? "Potential health, allergy, or medical-adjacent topic; skip unless reviewed by a human." : null,
  };
}

function evaluateRoundupCandidateHeuristic(candidate) {
  const title = normalizeText(candidate?.title);
  const snippet = normalizeText(candidate?.snippet);
  const url = normalizeURL(candidate?.url);
  const haystack = `${title} ${snippet} ${url}`.toLowerCase();
  const roundupMatches = keywordCount(haystack, ["best", "top", "apps", "tools", "roundup", "list"]);
  const fitMatches = keywordCount(haystack, ["meal", "recipe", "grocery", "cooking", "prep", "planner", "fridge"]);
  const score = clamp(0.2 + roundupMatches * 0.08 + fitMatches * 0.08, 0, 0.98);
  return {
    relevanceScore: Number(score.toFixed(2)),
    fitReason: `Matched ${roundupMatches} roundup/list signals and ${fitMatches} Ounje category signals.`,
  };
}

async function searchWithSerper(query, limit) {
  const key = getEnv("SERPER_API_KEY");
  if (!key) return null;
  const response = await fetch("https://google.serper.dev/search", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-KEY": key,
    },
    body: JSON.stringify({ q: query, num: limit }),
  });
  if (!response.ok) throw new Error(`Serper search failed (${response.status}) for query: ${query}`);
  const data = await response.json();
  return asArray(data.organic).map((item) => ({
    title: item.title,
    url: item.link,
    snippet: item.snippet,
    source: "serper",
  }));
}

async function searchWithSerpAPI(query, limit) {
  const key = getEnv("SERPAPI_API_KEY");
  if (!key) return null;
  const url = new URL("https://serpapi.com/search.json");
  url.searchParams.set("engine", "google");
  url.searchParams.set("q", query);
  url.searchParams.set("api_key", key);
  url.searchParams.set("num", String(limit));
  const response = await fetch(url);
  if (!response.ok) throw new Error(`SerpAPI search failed (${response.status}) for query: ${query}`);
  const data = await response.json();
  return asArray(data.organic_results).map((item) => ({
    title: item.title,
    url: item.link,
    snippet: item.snippet,
    source: "serpapi",
  }));
}

async function searchWithBrave(query, limit) {
  const key = getEnv("BRAVE_SEARCH_API_KEY");
  if (!key) return null;
  const url = new URL("https://api.search.brave.com/res/v1/web/search");
  url.searchParams.set("q", query);
  url.searchParams.set("count", String(Math.min(20, Math.max(1, limit))));
  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      "X-Subscription-Token": key,
    },
  });
  if (!response.ok) throw new Error(`Brave search failed (${response.status}) for query: ${query}`);
  const data = await response.json();
  return asArray(data.web?.results).map((item) => ({
    title: item.title,
    url: item.url,
    snippet: item.description,
    source: "brave",
  }));
}

function browserUseHeaders() {
  const key = getEnv("BROWSER_USE_API_KEY");
  if (!key) return null;
  return {
    "X-Browser-Use-API-Key": key,
    "Content-Type": "application/json",
  };
}

async function pollBrowserUseSession(sessionID, { timeoutMS = 240_000 } = {}) {
  const headers = browserUseHeaders();
  if (!headers) throw new Error("BROWSER_USE_API_KEY not configured");
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMS) {
    const response = await fetch(`${BROWSER_USE_BASE}/sessions/${sessionID}`, { headers });
    if (!response.ok) {
      throw new Error(`browser-use getSession ${response.status}: ${await response.text().catch(() => response.statusText)}`);
    }
    const session = await response.json();
    if (session.status === "completed") return session;
    if (session.status === "failed" || session.status === "cancelled") {
      throw new Error(`browser-use session ${session.status}: ${session.error ?? "Unknown error"}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error("browser-use session timed out");
}

function parseBrowserUseSearchOutput(output) {
  if (!output) return [];
  if (typeof output === "object" && Array.isArray(output.results)) return output.results;
  const raw = typeof output === "string" ? output : JSON.stringify(output);
  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed?.results)) return parsed.results;
  } catch {}
  const match = raw.match(/\{[\s\S]*\}/);
  if (!match) return [];
  try {
    const parsed = JSON.parse(match[0]);
    return Array.isArray(parsed?.results) ? parsed.results : [];
  } catch {
    return [];
  }
}

async function searchWithBrowserUse(query, limit, { logger = console } = {}) {
  const headers = browserUseHeaders();
  if (!headers) return null;

  let sessionID = null;

  try {
    const createResponse = await fetch(`${BROWSER_USE_BASE}/sessions`, {
      method: "POST",
      headers,
      body: JSON.stringify({}),
    });
    if (!createResponse.ok) {
      throw new Error(`browser-use createSession ${createResponse.status}: ${await createResponse.text().catch(() => createResponse.statusText)}`);
    }
    const created = await createResponse.json();
    sessionID = created.id;

    const task = [
      `Find up to ${limit} public web search results for this query: ${query}`,
      "Prefer Quora question URLs when the query includes Quora or site:quora.com.",
      "Do not log in, create an account, answer questions, post content, or bypass a site login wall.",
      "Return only JSON with this exact shape:",
      "{\"results\":[{\"title\":\"...\",\"url\":\"https://...\",\"snippet\":\"...\"}]}",
    ].join("\n");

    const runResponse = await fetch(`${BROWSER_USE_BASE}/sessions`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        task,
        session_id: sessionID,
        model: getEnv("GROWTH_BROWSER_USE_MODEL") || "claude-sonnet-4.6",
        output_schema: {
          type: "object",
          properties: {
            results: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  title: { type: "string" },
                  url: { type: "string" },
                  snippet: { type: "string" },
                },
                required: ["title", "url"],
              },
            },
          },
          required: ["results"],
        },
      }),
    });

    if (!runResponse.ok) {
      throw new Error(`browser-use runTask ${runResponse.status}: ${await runResponse.text().catch(() => runResponse.statusText)}`);
    }

    const run = await runResponse.json();
    const completed = await pollBrowserUseSession(run.id || sessionID);
    const results = parseBrowserUseSearchOutput(completed.output);
    return results
      .map((item) => ({
        title: item.title,
        url: item.url,
        snippet: item.snippet,
        source: "browser-use",
      }))
      .filter((item) => normalizeURL(item.url))
      .slice(0, limit);
  } catch (error) {
    logger.warn(`[growth-outreach] browser-use search failed for "${query}": ${error.message}`);
    return [];
  } finally {
    if (sessionID) await fetch(`${BROWSER_USE_BASE}/sessions/${sessionID}/stop`, {
      method: "POST",
      headers,
    }).catch(() => {});
  }
}

async function searchDuckDuckGoWithPlaywright(page, query, limit) {
  const url = new URL("https://html.duckduckgo.com/html/");
  url.searchParams.set("q", query);
  await page.goto(url.toString(), { waitUntil: "domcontentloaded", timeout: 30_000 });
  await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});
  return page.evaluate((maxResults) => {
    const links = Array.from(document.querySelectorAll("a.result__a, .result__title a, a[href]"));
    return links
      .map((anchor) => {
        const title = anchor.textContent?.replace(/\s+/g, " ").trim() ?? "";
        let href = anchor.href || anchor.getAttribute("href") || "";
        try {
          const parsed = new URL(href, window.location.href);
          const uddg = parsed.searchParams.get("uddg");
          if (uddg) href = decodeURIComponent(uddg);
          else href = parsed.toString();
        } catch {}
        const result = anchor.closest(".result");
        const snippet = result?.querySelector(".result__snippet")?.textContent?.replace(/\s+/g, " ").trim() ?? "";
        return { title, url: href, snippet };
      })
      .filter((item) => item.title && /^https?:\/\//i.test(item.url))
      .slice(0, maxResults);
  }, limit);
}

async function searchBingWithPlaywright(page, query, limit) {
  const url = new URL("https://www.bing.com/search");
  url.searchParams.set("q", query);
  await page.goto(url.toString(), { waitUntil: "domcontentloaded", timeout: 30_000 });
  await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});
  return page.evaluate((maxResults) => {
    function decodeBingURL(value) {
      try {
        const parsed = new URL(value, window.location.href);
        const encoded = parsed.searchParams.get("u");
        if (!encoded) return parsed.toString();
        const payload = encoded.startsWith("a1") ? encoded.slice(2) : encoded;
        const decoded = atob(payload.replace(/-/g, "+").replace(/_/g, "/"));
        return /^https?:\/\//i.test(decoded) ? decoded : parsed.toString();
      } catch {
        return value;
      }
    }

    return Array.from(document.querySelectorAll("li.b_algo"))
      .map((result) => {
        const anchor = result.querySelector("h2 a");
        const title = anchor?.textContent?.replace(/\s+/g, " ").trim() ?? "";
        const url = decodeBingURL(anchor?.href ?? "");
        const snippet = result.querySelector(".b_caption p, p")?.textContent?.replace(/\s+/g, " ").trim() ?? "";
        return { title, url, snippet };
      })
      .filter((item) => item.title && /^https?:\/\//i.test(item.url))
      .slice(0, maxResults);
  }, limit);
}

function shouldSearchQuoraDirectly(query) {
  const normalized = normalizeText(query).toLowerCase();
  return normalized.includes("site:quora.com") || normalized.includes("quora.com");
}

function normalizeQuoraDirectQuery(query) {
  return normalizeText(query)
    .replace(/\bsite:quora\.com\b/gi, "")
    .replace(/\bquora\.com\b/gi, "")
    .replace(/\bquora\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
}

async function searchQuoraWithPlaywright(page, query, limit) {
  const searchQuery = normalizeQuoraDirectQuery(query) || query;
  const url = new URL("https://www.quora.com/search");
  url.searchParams.set("q", searchQuery);
  await page.goto(url.toString(), { waitUntil: "domcontentloaded", timeout: 30_000 });
  await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});
  await page.waitForTimeout(750);
  await page.mouse.wheel(0, 1200).catch(() => {});
  await page.waitForTimeout(750);

  return page.evaluate((maxResults) => {
    const blockedSegments = new Set([
      "",
      "about",
      "answer",
      "following",
      "login",
      "notifications",
      "profile",
      "search",
      "signup",
      "spaces",
      "topic",
    ]);

    function clean(text) {
      return String(text ?? "").replace(/\s+/g, " ").trim();
    }

    function canonicalQuestionURL(value) {
      try {
        const parsed = new URL(value, window.location.href);
        if (!["quora.com", "www.quora.com"].includes(parsed.hostname.toLowerCase())) return "";

        const parts = parsed.pathname.split("/").filter(Boolean);
        if (parts.length === 0) return "";
        if (blockedSegments.has(parts[0].toLowerCase())) return "";

        if (parts[0].toLowerCase() === "unanswered" && parts[1]) {
          return `${parsed.origin}/unanswered/${parts[1]}`;
        }

        if (parts.length >= 2 && parts[1].toLowerCase() === "answer") {
          return `${parsed.origin}/${parts[0]}`;
        }

        if (parts.length === 1) return `${parsed.origin}/${parts[0]}`;
        return "";
      } catch {
        return "";
      }
    }

    function nearbySnippet(anchor, title) {
      let node = anchor;
      for (let depth = 0; depth < 8 && node; depth += 1) {
        const text = clean(node.innerText || node.textContent);
        if (text.length > title.length + 20 && text.length < 1400) return text;
        node = node.parentElement;
      }
      return "";
    }

    const seen = new Set();
    return Array.from(document.querySelectorAll("a[href]"))
      .map((anchor) => {
        const title = clean(anchor.textContent);
        if (!title || !title.endsWith("?")) return null;
        const url = canonicalQuestionURL(anchor.href || anchor.getAttribute("href"));
        if (!url || seen.has(url)) return null;
        seen.add(url);
        return {
          title,
          url,
          snippet: nearbySnippet(anchor, title),
        };
      })
      .filter(Boolean)
      .slice(0, maxResults);
  }, limit);
}

async function launchPlaywrightSearchContext() {
  const systemChrome = resolveSystemChromeExecutable();
  const headless = !["1", "true", "yes"].includes(getEnv("GROWTH_SEARCH_HEADED").toLowerCase());
  const profileDir = getEnv("GROWTH_PLAYWRIGHT_USER_DATA_DIR") || DEFAULT_PLAYWRIGHT_PROFILE_DIR;
  return chromium.launchPersistentContext(
    profileDir,
    buildPlaywrightLaunchOptions({
      headless,
      ...(systemChrome ? { executablePath: systemChrome } : {}),
      viewport: { width: 1280, height: 900 },
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
    })
  );
}

async function searchWithPlaywright(query, limit, { logger = console } = {}) {
  const context = await launchPlaywrightSearchContext();
  try {
    const page = context.pages()[0] ?? await context.newPage();
    if (shouldSearchQuoraDirectly(query)) {
      try {
        const results = await searchQuoraWithPlaywright(page, query, limit);
        if (results.length) return results.map((item) => ({ ...item, source: "playwright:quora" }));
      } catch (error) {
        logger.warn(`[growth-outreach] Playwright Quora search failed for "${query}": ${error.message}`);
      }
    }

    const engines = getEnv("GROWTH_PLAYWRIGHT_SEARCH_ENGINE") === "bing"
      ? ["bing", "duckduckgo"]
      : ["duckduckgo", "bing"];

    for (const engine of engines) {
      try {
        const results = engine === "bing"
          ? await searchBingWithPlaywright(page, query, limit)
          : await searchDuckDuckGoWithPlaywright(page, query, limit);
        if (results.length) {
          return results.map((item) => ({ ...item, source: `playwright:${engine}` }));
        }
      } catch (error) {
        logger.warn(`[growth-outreach] Playwright ${engine} search failed for "${query}": ${error.message}`);
      }
    }
    return [];
  } finally {
    await context.close().catch(() => {});
  }
}

function appendQuoraCandidateResults(candidates, results, sourceQuery, config) {
  for (const result of results) {
    const url = normalizeURL(result.url);
    if (!url.includes("quora.com/")) continue;
    const candidate = {
      title: normalizeText(result.title, 500),
      url,
      snippet: normalizeText(result.snippet, 1500),
      sourceQuery,
      searchProvider: result.source,
    };
    const evaluation = evaluateQuoraCandidateHeuristic(candidate, config);
    if (evaluation.relevanceScore < clamp(config.quora?.min_relevance_score ?? 0.55, 0, 1)) continue;
    if (evaluation.blockedReason) continue;
    candidates.push({ ...candidate, ...evaluation });
  }
}

async function discoverQuoraCandidatesWithPlaywright(config, { logger = console } = {}) {
  const target = clamp(config.quora?.candidate_target ?? 15, 1, 50);
  const queries = buildQuoraSearchQueries(config);
  const candidates = [];
  const context = await launchPlaywrightSearchContext();

  try {
    const page = context.pages()[0] ?? await context.newPage();
    for (const query of queries) {
      if (uniqueByURL(candidates).length >= target) break;
      logger.log?.(`[growth-outreach] Quora search: ${normalizeQuoraDirectQuery(query) || query}`);
      try {
        const directResults = shouldSearchQuoraDirectly(query)
          ? await searchQuoraWithPlaywright(page, query, DEFAULT_SEARCH_LIMIT)
          : [];
        const results = directResults.length
          ? directResults.map((item) => ({ ...item, source: "playwright:quora" }))
          : (await searchDuckDuckGoWithPlaywright(page, query, DEFAULT_SEARCH_LIMIT)).map((item) => ({ ...item, source: "playwright:duckduckgo" }));
        appendQuoraCandidateResults(candidates, results, query, config);
      } catch (error) {
        logger.warn(`[growth-outreach] Playwright Quora discovery failed for "${query}": ${error.message}`);
      }
    }
  } finally {
    await context.close().catch(() => {});
  }

  return uniqueByURL(candidates).slice(0, target);
}

async function searchWeb(query, { limit = DEFAULT_SEARCH_LIMIT, logger = console } = {}) {
  const provider = getEnv("GROWTH_SEARCH_PROVIDER").toLowerCase();
  const forcedProvider = Boolean(provider);
  const providers = provider ? [provider] : ["serper", "brave", "serpapi", "browser-use", "playwright"];

  for (const candidateProvider of providers) {
    let results = null;
    if (candidateProvider === "serper") results = await searchWithSerper(query, limit);
    else if (candidateProvider === "brave") results = await searchWithBrave(query, limit);
    else if (candidateProvider === "serpapi") results = await searchWithSerpAPI(query, limit);
    else if (candidateProvider === "browser-use") results = await searchWithBrowserUse(query, limit, { logger });
    else if (candidateProvider === "playwright") results = await searchWithPlaywright(query, limit, { logger });
    else throw new Error(`Unsupported GROWTH_SEARCH_PROVIDER: ${candidateProvider}`);

    if (Array.isArray(results) && (results.length > 0 || forcedProvider)) return results;
  }

  if (!warnedMissingSearchProvider) {
    logger.warn("[growth-outreach] no search provider configured; set SERPER_API_KEY, BRAVE_SEARCH_API_KEY, or SERPAPI_API_KEY");
    warnedMissingSearchProvider = true;
  }
  return [];
}

async function discoverQuoraCandidates(config, { logger = console } = {}) {
  if (getEnv("GROWTH_SEARCH_PROVIDER").toLowerCase() === "playwright") {
    return discoverQuoraCandidatesWithPlaywright(config, { logger });
  }

  const target = clamp(config.quora?.candidate_target ?? 15, 1, 50);
  const queries = buildQuoraSearchQueries(config);
  const candidates = [];

  for (const query of queries) {
    if (uniqueByURL(candidates).length >= target) break;
    const results = await searchWeb(query, { limit: DEFAULT_SEARCH_LIMIT, logger });
    appendQuoraCandidateResults(candidates, results, query, config);
  }

  return uniqueByURL(candidates).slice(0, target);
}

async function discoverRoundupOpportunities(config, { logger = console } = {}) {
  const target = clamp(config.roundups?.candidate_target ?? 15, 1, 50);
  const queries = buildRoundupSearchQueries(config);
  const opportunities = [];

  for (const query of queries) {
    if (opportunities.length >= target) break;
    const results = await searchWeb(query, { limit: DEFAULT_SEARCH_LIMIT, logger });
    for (const result of results) {
      const url = normalizeURL(result.url);
      if (!url || url.includes("quora.com/")) continue;
      const opportunity = {
        postTitle: normalizeText(result.title, 500),
        postURL: url,
        snippet: normalizeText(result.snippet, 1500),
        sourceQuery: query,
        searchProvider: result.source,
        siteName: inferSiteName(url),
        contactURL: inferContactURL(url),
      };
      const evaluation = evaluateRoundupCandidateHeuristic(opportunity);
      if (evaluation.relevanceScore < clamp(config.roundups?.min_relevance_score ?? 0.35, 0, 1)) continue;
      opportunities.push({ ...opportunity, ...evaluation });
    }
  }

  return uniqueByURL(opportunities.map((item) => ({ ...item, url: item.postURL })))
    .map(({ url, ...item }) => ({ ...item, postURL: url }))
    .slice(0, target);
}

function inferSiteName(urlValue) {
  try {
    return new URL(urlValue).hostname.replace(/^www\./, "");
  } catch {
    return null;
  }
}

function inferContactURL(urlValue) {
  try {
    const url = new URL(urlValue);
    return `${url.origin}/contact`;
  } catch {
    return null;
  }
}

function getOpenAIClient() {
  const apiKey = getEnv("OPENAI_API_KEY");
  if (!apiKey) return null;
  return createLoggedOpenAI({ apiKey, service: "growth-outreach" });
}

function hasSearchProviderConfigured() {
  return Boolean(
    getEnv("GROWTH_SEARCH_PROVIDER")
    || getEnv("SERPER_API_KEY")
    || getEnv("BRAVE_SEARCH_API_KEY")
    || getEnv("SERPAPI_API_KEY")
  );
}

function extractJSON(content) {
  const raw = normalizeBodyText(content);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) return null;
    return JSON.parse(match[0]);
  }
}

function ensureAffiliationDisclosure(body, app) {
  const text = normalizeBodyText(body);
  if (/i (work on|work for|am associated with|help build|build|run) ounje/i.test(text)) return text;
  return `${text}\n\nDisclosure: I work on ${app.name}.`;
}

function localHumanizeText(text) {
  return normalizeBodyText(text)
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\bGreat question[!.]?\s*/gi, "")
    .replace(/\bI hope (this message finds you well|you're doing well)[!.]?\s*/gi, "")
    .replace(/\byour upcoming (roundup|post|article)\b/gi, "your $1")
    .replace(/\bstreamline(?:s|d)? the process\b/gi, "make the process easier")
    .replace(/\bmake easier the process\b/gi, "make the process easier")
    .replace(/\bmore simpler\b/gi, "simpler")
    .replace(/\btailored experience\b/gi, "specific workflow")
    .replace(/\bIn order to\b/g, "To")
    .replace(/\bin order to\b/g, "to")
    .replace(/\bDue to the fact that\b/g, "Because")
    .replace(/\bdue to the fact that\b/g, "because")
    .replace(/\bIt is important to note that\b,?\s*/gi, "")
    .replace(/\bIt is worth noting that\b,?\s*/gi, "")
    .replace(/\bserves as\b/gi, "is")
    .replace(/\butilize\b/gi, "use")
    .replace(/\bleverage\b/gi, "use")
    .replace(/\bseamless\b/gi, "simple")
    .replace(/\bstreamline\b/gi, "simplify")
    .replace(/\bstreamlines\b/gi, "makes easier")
    .replace(/\bstreamlined\b/gi, "simpler")
    .replace(/\brobust\b/gi, "solid")
    .replace(/\bcrucial\b/gi, "important")
    .replace(/\bcomprehensive\b/gi, "thorough")
    .replace(/\benhance\b/gi, "improve")
    .replace(/\benhances\b/gi, "improves")
    .replace(/\bI hope this helps[!.]?/gi, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

async function humanizeDraftText(text, { openai = null, kind = "draft", app, logger = console } = {}) {
  const cleaned = localHumanizeText(text);
  if (!openai) return cleaned;

  const model = getEnv("GROWTH_OUTREACH_OPENAI_MODEL") || DEFAULT_OPENAI_MODEL;
  try {
    const response = await withAIUsageContext({
      operation: `growth_outreach.humanize_${kind}`,
    }, () => openai.chat.completions.create({
      model,
      temperature: 0.45,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content: HUMANIZER_SYSTEM_PROMPT,
        },
        {
          role: "user",
          content: JSON.stringify({
            task: "Humanize this draft and return JSON with key text only.",
            app_name: app?.name ?? "Ounje",
            must_keep: [
              "Keep any link that is already present.",
              "Keep explicit Ounje affiliation disclosure if present.",
              "Do not add unsupported metrics, awards, guarantees, medical advice, or fake personal experience.",
            ],
            draft: cleaned,
          }),
        },
      ],
    }));

    const parsed = extractJSON(response.choices?.[0]?.message?.content);
    const humanized = typeof parsed?.text === "string"
      ? parsed.text
      : typeof parsed?.body === "string"
        ? parsed.body
        : typeof parsed?.draft === "string"
          ? parsed.draft
          : typeof parsed?.text?.content === "string"
            ? parsed.text.content
            : "";
    return localHumanizeText(humanized || cleaned);
  } catch (error) {
    logger.warn(`[growth-outreach] humanizer pass failed: ${error.message}`);
    return cleaned;
  }
}

export function composeFallbackQuoraAnswer(candidate, app) {
  const title = normalizeText(candidate?.questionTitle ?? candidate?.title) || "this question";
  const angle = normalizeText(candidate?.answerAngle) || "Start with the food input, make the recipe actionable, then turn it into a grocery list.";
  const appName = app?.name ?? "Ounje";
  const appURL = app?.publicURL ?? "https://ounje-idbl.onrender.com";

  return ensureAffiliationDisclosure(`For "${title}", I would think about the workflow before picking a tool.

1. Start with the actual input you already have: a saved recipe video, a screenshot, a restaurant meal you want to recreate, or the ingredients in your fridge.
2. Turn that into a plain recipe structure: ingredients, rough quantities, steps, timing, and what needs human judgment.
3. Convert the ingredients into a grouped grocery list, subtracting what you already have.
4. Review anything that affects safety or cost: allergens, substitutions, servings, prices, and whether the recipe actually fits your week.

${angle}

${appName} is one option for this kind of flow because it is built around importing food inputs and turning them into recipes, meal prep plans, and grocery lists: ${appURL}. It still should not replace your own review of ingredients, allergens, or quantities.`, app);
}

export function composeFallbackRoundupPitch(opportunity, app) {
  const authorName = normalizeText(opportunity?.authorName) || "there";
  const postTitle = normalizeText(opportunity?.postTitle) || "your roundup";
  const appName = app?.name ?? "Ounje";
  const appURL = app?.publicURL ?? "https://ounje-idbl.onrender.com";
  const features = asArray(app?.features).length
    ? asArray(app.features)
    : [
      "Imports recipe links, videos, screenshots, captions, or meal photos.",
      "Turns cravings and saved food content into meal prep plans.",
      "Builds organized grocery lists and supported cart handoff paths.",
    ];

  const body = `Hi ${authorName},

I came across your post "${postTitle}" and thought it covered the meal planning app space well. I wanted to tell you about ${appName}, an app I work on.

${appName} helps people turn saved recipes, food videos, meal photos, cravings, and fridge ingredients into recipes, meal prep plans, grocery lists, and supported checkout paths. It is a strong fit for readers who save food ideas but struggle to turn them into actual dinners.

It is unique because:

* ${features[0]}
* ${features[1]}
* ${features[2]}

${appURL}

I would appreciate it if you could check it out and consider adding it to your list if it feels useful for your readers.

Thanks,
${app?.contactName ?? "Dave"}`;

  return {
    subject: `${appName} for ${postTitle}`,
    body,
    followUp1Body: `Hi ${authorName},\n\nWanted to follow up on my note below about ${appName}. I still think it could be a useful addition for readers comparing meal planning or recipe workflow apps.\n\nThanks,\n${app?.contactName ?? "Dave"}`,
    followUp2Body: `Hi ${authorName},\n\nLast quick follow-up from me. If you update "${postTitle}" and want another app that focuses on turning saved recipes, food videos, and meal photos into grocery-ready plans, ${appName} could be worth a look: ${appURL}\n\nThanks,\n${app?.contactName ?? "Dave"}`,
  };
}

async function draftQuoraAnswer(candidate, app, { openai = null, logger = console } = {}) {
  if (!openai) {
    const body = ensureAffiliationDisclosure(await humanizeDraftText(composeFallbackQuoraAnswer(candidate, app), {
      kind: "quora_answer",
      app,
      logger,
    }), app);
    return {
      body,
      affiliationDisclosure: `I work on ${app.name}.`,
      appMention: `${app.name} is mentioned as one optional tool where it directly fits the workflow.`,
      confidenceNotes: "Fallback draft generated without OpenAI; human review required before posting.",
      complianceNotes: ["Draft is not auto-posted.", "Affiliation disclosure included.", "Local humanizer cleanup applied.", "Verify the question context before publishing."],
    };
  }

  const model = getEnv("GROWTH_OUTREACH_OPENAI_MODEL") || DEFAULT_OPENAI_MODEL;
  const response = await withAIUsageContext({
    operation: "growth_outreach.quora_answer_draft",
  }, () => openai.chat.completions.create({
    model,
    temperature: 0.4,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: "You draft human-review Quora answers for Ounje. Directly answer the question first. Give concrete, standalone advice. Mention Ounje only where it naturally helps, and disclose the affiliation clearly. Avoid press-release language, excessive promotion, unsupported health or allergy claims, and any claim that the draft has been posted.",
      },
      {
        role: "user",
        content: JSON.stringify({
          task: "Draft a Quora answer in JSON with keys body, affiliation_disclosure, app_mention, confidence_notes, compliance_notes.",
          question: {
            title: candidate.questionTitle ?? candidate.title,
            url: candidate.questionURL ?? candidate.url,
            snippet: candidate.snippet,
            answer_angle: candidate.answerAngle,
          },
          app,
          rules: [
            "The answer must be understandable without clicking an external link.",
            "Mention Ounje once or twice and only as an optional tool tied to the question.",
            "Use first-person disclosure such as 'I work on Ounje'.",
            "No affiliate links, no guaranteed outcomes, no medical/nutrition advice.",
            "Write like a person answering from experience: concrete, a bit uneven, and not overly polished.",
          ],
        }),
      },
    ],
  }));

  const parsed = extractJSON(response.choices?.[0]?.message?.content);
  if (!parsed?.body) {
    logger.warn("[growth-outreach] OpenAI returned an invalid Quora draft; using fallback");
    return draftQuoraAnswer(candidate, app, { openai: null, logger });
  }

  const humanizedBody = await humanizeDraftText(parsed.body, {
    openai,
    kind: "quora_answer",
    app,
    logger,
  });

  return {
    body: ensureAffiliationDisclosure(humanizedBody, app),
    affiliationDisclosure: normalizeText(parsed.affiliation_disclosure) || `I work on ${app.name}.`,
    appMention: normalizeText(parsed.app_mention),
    confidenceNotes: normalizeText(parsed.confidence_notes) || "Human review required before posting.",
    complianceNotes: [
      ...asArray(parsed.compliance_notes).map((item) => normalizeText(item)).filter(Boolean),
      "LLM humanizer pass applied.",
    ],
  };
}

async function draftRoundupPitch(opportunity, app, { openai = null, logger = console } = {}) {
  if (!openai) return composeFallbackRoundupPitch(opportunity, app);

  const model = getEnv("GROWTH_OUTREACH_OPENAI_MODEL") || DEFAULT_OPENAI_MODEL;
  const response = await withAIUsageContext({
    operation: "growth_outreach.roundup_pitch_draft",
  }, () => openai.chat.completions.create({
    model,
    temperature: 0.35,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: "You draft concise founder outreach emails. Do not invent facts, awards, usage numbers, or fake personalization. If the author's name is unknown, use 'Hi there,'.",
      },
      {
        role: "user",
        content: JSON.stringify({
          task: "Draft a roundup inclusion pitch in JSON with keys subject, body, follow_up_1_body, follow_up_2_body.",
          post: opportunity,
          app,
          rules: [
            "Be concise.",
            "Address the author by name only if known.",
            "Use 3 bullets for Ounje's differentiators.",
            "Ask them to consider adding Ounje if it improves the list for readers.",
            "Do not imply a prior relationship.",
            "Do not call the post upcoming unless the source title clearly says it is future-facing.",
          ],
        }),
      },
    ],
  }));

  const parsed = extractJSON(response.choices?.[0]?.message?.content);
  if (!parsed?.body || !parsed?.subject) {
    logger.warn("[growth-outreach] OpenAI returned an invalid roundup pitch; using fallback");
    return composeFallbackRoundupPitch(opportunity, app);
  }

  return {
    subject: normalizeText(parsed.subject, 240),
    body: await humanizeDraftText(parsed.body, { openai, kind: "roundup_pitch", app, logger }),
    followUp1Body: await humanizeDraftText(parsed.follow_up_1_body, { openai, kind: "roundup_followup", app, logger }),
    followUp2Body: await humanizeDraftText(parsed.follow_up_2_body, { openai, kind: "roundup_followup", app, logger }),
  };
}

async function createRun(supabase, { job, config, mode }) {
  const { data, error } = await supabase
    .from(RUNS_TABLE)
    .insert({
      user_id: job.userID,
      automation_job_id: job.id,
      channel: mode,
      status: "running",
      config: {
        mode,
        quora: config.quora,
        roundups: config.roundups,
        app: {
          name: config.app.name,
          publicURL: config.app.publicURL,
          contactName: config.app.contactName,
          contactEmail: config.app.contactEmail,
        },
      },
    })
    .select("*")
    .single();

  if (error) throw error;
  return data;
}

async function updateRun(supabase, runID, patch) {
  const { data, error } = await supabase
    .from(RUNS_TABLE)
    .update(patch)
    .eq("id", runID)
    .select("*")
    .single();
  if (error) throw error;
  return data;
}

async function upsertQuoraCandidate(supabase, { userID, runID, candidate }) {
  const { data, error } = await supabase
    .from(QUORA_CANDIDATES_TABLE)
    .upsert({
      user_id: userID,
      run_id: runID,
      question_url: candidate.url,
      question_title: candidate.title,
      snippet: candidate.snippet,
      source_query: candidate.sourceQuery,
      relevance_score: candidate.relevanceScore,
      fit_reason: candidate.fitReason,
      answer_angle: candidate.answerAngle,
      status: "candidate",
      metadata: {
        searchProvider: candidate.searchProvider,
      },
    }, { onConflict: "user_id,question_url" })
    .select("*")
    .single();
  if (error) throw error;
  return data;
}

async function insertQuoraDraft(supabase, { candidate, draft }) {
  const { data, error } = await supabase
    .from(QUORA_DRAFTS_TABLE)
    .insert({
      user_id: candidate.user_id,
      run_id: candidate.run_id,
      question_candidate_id: candidate.id,
      draft_body: draft.body,
      affiliation_disclosure: draft.affiliationDisclosure,
      app_mention: draft.appMention,
      confidence_notes: draft.confidenceNotes,
      compliance_notes: draft.complianceNotes,
      status: "pending_review",
    })
    .select("*")
    .single();
  if (error) throw error;
  const { error: updateError } = await supabase
    .from(QUORA_CANDIDATES_TABLE)
    .update({ status: "drafted" })
    .eq("id", candidate.id);
  if (updateError) throw updateError;
  return data;
}

async function upsertRoundupOpportunity(supabase, { userID, runID, opportunity }) {
  const { data, error } = await supabase
    .from(ROUNDUP_OPPORTUNITIES_TABLE)
    .upsert({
      user_id: userID,
      run_id: runID,
      post_url: opportunity.postURL,
      post_title: opportunity.postTitle,
      site_name: opportunity.siteName,
      author_name: null,
      contact_url: opportunity.contactURL,
      contact_email: null,
      snippet: opportunity.snippet,
      source_query: opportunity.sourceQuery,
      relevance_score: opportunity.relevanceScore,
      fit_reason: opportunity.fitReason,
      status: "candidate",
      metadata: {
        searchProvider: opportunity.searchProvider,
      },
    }, { onConflict: "user_id,post_url" })
    .select("*")
    .single();
  if (error) throw error;
  return data;
}

async function insertRoundupPitch(supabase, { opportunity, pitch }) {
  const { data, error } = await supabase
    .from(ROUNDUP_DRAFTS_TABLE)
    .insert({
      user_id: opportunity.user_id,
      run_id: opportunity.run_id,
      roundup_opportunity_id: opportunity.id,
      subject: pitch.subject,
      body: pitch.body,
      follow_up_1_body: pitch.followUp1Body,
      follow_up_2_body: pitch.followUp2Body,
      status: "pending_review",
    })
    .select("*")
    .single();
  if (error) throw error;
  const { error: updateError } = await supabase
    .from(ROUNDUP_OPPORTUNITIES_TABLE)
    .update({ status: opportunity.contact_url || opportunity.contact_email ? "contact_found" : "candidate" })
    .eq("id", opportunity.id);
  if (updateError) throw updateError;
  return data;
}

function normalizeMode(value) {
  const mode = normalizeText(value).toLowerCase();
  if (mode === "quora" || mode === "roundups" || mode === "both") return mode;
  return "both";
}

export async function executeGrowthOutreachJob(job, { logger = console, configOverrides = {} } = {}) {
  if (!job?.id) throw new Error("growth outreach job id is required");
  if (job.kind !== GROWTH_JOB_KIND) throw new Error(`Unsupported growth outreach job kind: ${job.kind}`);

  const payload = job.payload && typeof job.payload === "object" ? job.payload : {};
  const storage = normalizeStorage(payload.storage || getEnv("GROWTH_OUTREACH_STORAGE"));
  if (storage === "local") {
    return executeLocalGrowthOutreachRun({
      mode: payload.mode,
      job,
      logger,
      configOverrides: { ...configOverrides, ...(payload.config ?? {}) },
    });
  }

  if (!job?.userID) throw new Error("growth outreach job userID is required");
  const mode = normalizeMode(payload.mode);
  const config = await loadGrowthOutreachConfig({ overrides: { ...configOverrides, ...(payload.config ?? {}) } });
  const supabase = getServiceRoleSupabase();
  const openai = getOpenAIClient();
  const run = await createRun(supabase, { job, config, mode });

  const summary = {
    runID: run.id,
    mode,
    searchConfigured: hasSearchProviderConfigured(),
    quoraCandidates: 0,
    quoraDrafts: 0,
    roundupOpportunities: 0,
    roundupPitchDrafts: 0,
    warnings: [],
  };

  try {
    if (mode === "quora" || mode === "both") {
      const discovered = await discoverQuoraCandidates(config, { logger });
      const rows = [];
      for (const candidate of discovered) {
        rows.push(await upsertQuoraCandidate(supabase, { userID: job.userID, runID: run.id, candidate }));
      }
      summary.quoraCandidates = rows.length;

      const minBeforeDrafting = clamp(config.quora?.min_candidates_before_drafting ?? 10, 1, 50);
      if (rows.length >= minBeforeDrafting) {
        const draftTarget = clamp(config.quora?.draft_target ?? 5, 0, 25);
        const selected = rows
          .slice()
          .sort((a, b) => Number(b.relevance_score ?? 0) - Number(a.relevance_score ?? 0))
          .slice(0, draftTarget);
        for (const row of selected) {
          const draft = await draftQuoraAnswer({
            questionTitle: row.question_title,
            questionURL: row.question_url,
            snippet: row.snippet,
            answerAngle: row.answer_angle,
          }, config.app, { openai, logger });
          await insertQuoraDraft(supabase, { candidate: row, draft });
          summary.quoraDrafts += 1;
        }
      } else {
        summary.warnings.push(`Quora discovery found ${rows.length} candidates; drafting requires at least ${minBeforeDrafting}.`);
      }
    }

    if (mode === "roundups" || mode === "both") {
      const discovered = await discoverRoundupOpportunities(config, { logger });
      const rows = [];
      for (const opportunity of discovered) {
        rows.push(await upsertRoundupOpportunity(supabase, { userID: job.userID, runID: run.id, opportunity }));
      }
      summary.roundupOpportunities = rows.length;

      const minBeforeDrafting = clamp(config.roundups?.min_candidates_before_drafting ?? 10, 1, 50);
      if (rows.length >= minBeforeDrafting) {
        const draftTarget = clamp(config.roundups?.draft_target ?? 10, 0, 25);
        const selected = rows
          .slice()
          .sort((a, b) => Number(b.relevance_score ?? 0) - Number(a.relevance_score ?? 0))
          .slice(0, draftTarget);
        for (const row of selected) {
          const pitch = await draftRoundupPitch({
            postTitle: row.post_title,
            postURL: row.post_url,
            authorName: row.author_name,
            siteName: row.site_name,
          }, config.app, { openai, logger });
          await insertRoundupPitch(supabase, { opportunity: row, pitch });
          summary.roundupPitchDrafts += 1;
        }
      } else {
        summary.warnings.push(`Roundup discovery found ${rows.length} opportunities; drafting requires at least ${minBeforeDrafting}.`);
      }
    }

    await updateRun(supabase, run.id, {
      status: "succeeded",
      completed_at: new Date().toISOString(),
      summary,
    });
    logger.log(`[growth-outreach] completed run=${run.id} quora=${summary.quoraCandidates}/${summary.quoraDrafts} roundups=${summary.roundupOpportunities}/${summary.roundupPitchDrafts}`);
    return summary;
  } catch (error) {
    await updateRun(supabase, run.id, {
      status: "failed",
      completed_at: new Date().toISOString(),
      summary: {
        ...summary,
        error: error.message,
      },
    }).catch((updateError) => {
      logger.warn(`[growth-outreach] failed to mark run failed=${run.id}: ${updateError.message}`);
    });
    throw error;
  }
}

export async function executeLocalGrowthOutreachRun({
  mode: requestedMode = "both",
  job = null,
  logger = console,
  configOverrides = {},
  outputDir = getEnv("GROWTH_OUTREACH_LOCAL_DIR") || DEFAULT_LOCAL_OUTPUT_DIR,
} = {}) {
  const mode = normalizeMode(requestedMode);
  const config = await loadGrowthOutreachConfig({ overrides: configOverrides });
  const openai = getOpenAIClient();
  const runID = job?.id || makeLocalID("growth_run");
  const runDir = path.resolve(outputDir, runID);
  const startedAt = new Date().toISOString();
  const run = {
    id: runID,
    kind: GROWTH_JOB_KIND,
    channel: mode,
    status: "running",
    started_at: startedAt,
    completed_at: null,
    storage: "local",
    output_dir: runDir,
    config: {
      mode,
      quora: config.quora,
      roundups: config.roundups,
      app: {
        name: config.app.name,
        publicURL: config.app.publicURL,
        contactName: config.app.contactName,
        contactEmail: config.app.contactEmail,
      },
    },
    summary: {},
  };

  await fs.mkdir(runDir, { recursive: true });
  await writeJSONFile(path.join(runDir, "run.json"), run);

  const summary = {
    runID,
    mode,
    storage: "local",
    outputDir: runDir,
    searchConfigured: hasSearchProviderConfigured(),
    quoraCandidates: 0,
    quoraDrafts: 0,
    roundupOpportunities: 0,
    roundupPitchDrafts: 0,
    warnings: [],
  };

  const quoraRows = [];
  const quoraDraftRows = [];
  const roundupRows = [];
  const roundupDraftRows = [];

  try {
    if (mode === "quora" || mode === "both") {
      const discovered = await discoverQuoraCandidates(config, { logger });
      for (const candidate of discovered) {
        quoraRows.push({
          id: makeLocalID("quora_candidate"),
          run_id: runID,
          question_url: candidate.url,
          question_title: candidate.title,
          snippet: candidate.snippet,
          source_query: candidate.sourceQuery,
          relevance_score: candidate.relevanceScore,
          fit_reason: candidate.fitReason,
          answer_angle: candidate.answerAngle,
          status: "candidate",
          metadata: {
            searchProvider: candidate.searchProvider,
          },
          created_at: new Date().toISOString(),
        });
      }
      summary.quoraCandidates = quoraRows.length;

      const minBeforeDrafting = clamp(config.quora?.min_candidates_before_drafting ?? 10, 1, 50);
      if (quoraRows.length >= minBeforeDrafting) {
        const draftTarget = clamp(config.quora?.draft_target ?? 5, 0, 25);
        const selected = quoraRows
          .slice()
          .sort((a, b) => Number(b.relevance_score ?? 0) - Number(a.relevance_score ?? 0))
          .slice(0, draftTarget);

        for (const row of selected) {
          const draft = await draftQuoraAnswer({
            questionTitle: row.question_title,
            questionURL: row.question_url,
            snippet: row.snippet,
            answerAngle: row.answer_angle,
          }, config.app, { openai, logger });
          row.status = "drafted";
          quoraDraftRows.push({
            id: makeLocalID("quora_draft"),
            run_id: runID,
            question_candidate_id: row.id,
            question_url: row.question_url,
            question_title: row.question_title,
            draft_body: draft.body,
            affiliation_disclosure: draft.affiliationDisclosure,
            app_mention: draft.appMention,
            confidence_notes: draft.confidenceNotes,
            compliance_notes: draft.complianceNotes,
            status: "ready_to_copy",
            created_at: new Date().toISOString(),
          });
          summary.quoraDrafts += 1;
        }
      } else {
        summary.warnings.push(`Quora discovery found ${quoraRows.length} candidates; drafting requires at least ${minBeforeDrafting}.`);
      }

      await writeJSONFile(path.join(runDir, "quora-candidates.json"), quoraRows);
      await writeJSONFile(path.join(runDir, "quora-answer-drafts.json"), quoraDraftRows);
    }

    if (mode === "roundups" || mode === "both") {
      const discovered = await discoverRoundupOpportunities(config, { logger });
      for (const opportunity of discovered) {
        roundupRows.push({
          id: makeLocalID("roundup_opportunity"),
          run_id: runID,
          post_url: opportunity.postURL,
          post_title: opportunity.postTitle,
          site_name: opportunity.siteName,
          author_name: null,
          contact_url: opportunity.contactURL,
          contact_email: null,
          snippet: opportunity.snippet,
          source_query: opportunity.sourceQuery,
          relevance_score: opportunity.relevanceScore,
          fit_reason: opportunity.fitReason,
          status: "candidate",
          metadata: {
            searchProvider: opportunity.searchProvider,
          },
          created_at: new Date().toISOString(),
        });
      }
      summary.roundupOpportunities = roundupRows.length;

      const minBeforeDrafting = clamp(config.roundups?.min_candidates_before_drafting ?? 10, 1, 50);
      if (roundupRows.length >= minBeforeDrafting) {
        const draftTarget = clamp(config.roundups?.draft_target ?? 10, 0, 25);
        const selected = roundupRows
          .slice()
          .sort((a, b) => Number(b.relevance_score ?? 0) - Number(a.relevance_score ?? 0))
          .slice(0, draftTarget);

        for (const row of selected) {
          const pitch = await draftRoundupPitch({
            postTitle: row.post_title,
            postURL: row.post_url,
            authorName: row.author_name,
            siteName: row.site_name,
          }, config.app, { openai, logger });
          row.status = row.contact_url || row.contact_email ? "contact_found" : "candidate";
          roundupDraftRows.push({
            id: makeLocalID("roundup_pitch"),
            run_id: runID,
            roundup_opportunity_id: row.id,
            post_url: row.post_url,
            post_title: row.post_title,
            subject: pitch.subject,
            body: pitch.body,
            follow_up_1_body: pitch.followUp1Body,
            follow_up_2_body: pitch.followUp2Body,
            status: "ready_to_copy",
            created_at: new Date().toISOString(),
          });
          summary.roundupPitchDrafts += 1;
        }
      } else {
        summary.warnings.push(`Roundup discovery found ${roundupRows.length} opportunities; drafting requires at least ${minBeforeDrafting}.`);
      }

      await writeJSONFile(path.join(runDir, "roundup-opportunities.json"), roundupRows);
      await writeJSONFile(path.join(runDir, "roundup-pitch-drafts.json"), roundupDraftRows);
    }

    run.status = "succeeded";
    run.completed_at = new Date().toISOString();
    run.summary = summary;
    await writeJSONFile(path.join(runDir, "run.json"), run);
    logger.log(`[growth-outreach] completed local run=${runID} dir=${runDir}`);
    return summary;
  } catch (error) {
    run.status = "failed";
    run.completed_at = new Date().toISOString();
    run.summary = {
      ...summary,
      error: error.message,
    };
    await writeJSONFile(path.join(runDir, "run.json"), run).catch(() => {});
    throw error;
  }
}

export { GROWTH_JOB_KIND };
