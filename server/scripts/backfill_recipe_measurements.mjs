#!/usr/bin/env node
import dotenv from "dotenv";
import OpenAI from "openai";
import { chromium } from "playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseIngredientObjects, parseInstructionSteps, sanitizeRecipeText } from "../lib/recipe-detail-utils.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, "../.env") });

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";
const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const RECIPE_MEASUREMENT_FILL_MODEL = process.env.RECIPE_MEASUREMENT_FILL_MODEL ?? "gpt-4o-mini";

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_ANON_KEY in server/.env");
  process.exit(1);
}

const openai = OPENAI_API_KEY ? new OpenAI({ apiKey: OPENAI_API_KEY }) : null;

const HEADERS = {
  apikey: SUPABASE_ANON_KEY,
  Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
  Accept: "application/json",
  "Content-Type": "application/json",
};

const DEFAULT_BATCH_SIZE = 100;
const DEFAULT_IDLE_SLEEP_MS = 5 * 60 * 1000;
const DEFAULT_MATCHED_UPDATED_COOLDOWN_MS = 2 * 60 * 60 * 1000;
const DEFAULT_MATCHED_NO_UPDATE_COOLDOWN_MS = 12 * 60 * 60 * 1000;
const DEFAULT_PARTIAL_OR_AMBIGUOUS_COOLDOWN_MS = 12 * 60 * 60 * 1000;
const DEFAULT_NOT_FOUND_COOLDOWN_MS = 6 * 60 * 60 * 1000;

const VAGUE_QUANTITY_PATTERNS = [
  /^$/,
  /^to taste$/i,
  /^optional$/i,
  /^a pinch$/i,
  /^pinch$/i,
  /^as needed$/i,
  /^as required$/i,
  /^some$/i,
  /^a little$/i,
];

const ABBREVIATION_DISPLAY_NAMES = new Set(["ls", "cr", "tbsp", "tsp", "oz", "ml", "g", "kg", "lb", "pkg"]);

function normalizeText(value) {
  return String(value ?? "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeKey(value) {
  return normalizeText(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function parseArgs(argv) {
  const args = {
    recipeId: null,
    once: false,
    dryRun: false,
    batchSize: DEFAULT_BATCH_SIZE,
    headless: true,
    idleSleepMs: DEFAULT_IDLE_SLEEP_MS,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--once") args.once = true;
    else if (token === "--dry-run") args.dryRun = true;
    else if (token === "--headless=false") args.headless = false;
    else if (token === "--headless=true") args.headless = true;
    else if (token === "--recipe-id") args.recipeId = argv[++i] ?? null;
    else if (token === "--batch-size") args.batchSize = Math.max(1, parseInt(argv[++i] ?? "", 10) || DEFAULT_BATCH_SIZE);
    else if (token === "--idle-sleep-ms") args.idleSleepMs = Math.max(10_000, parseInt(argv[++i] ?? "", 10) || DEFAULT_IDLE_SLEEP_MS);
  }

  return args;
}

function chunk(values, size) {
  const result = [];
  for (let i = 0; i < values.length; i += size) {
    result.push(values.slice(i, i + size));
  }
  return result;
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function isVagueQuantity(value) {
  const text = normalizeText(value);
  return VAGUE_QUANTITY_PATTERNS.some((pattern) => pattern.test(text));
}

function isAbbreviationDisplayName(value) {
  const key = normalizeKey(value);
  if (!key) return false;
  if (ABBREVIATION_DISPLAY_NAMES.has(key)) return true;
  return key.length <= 3;
}

function needsBackfill(row) {
  const quantity = normalizeText(row.quantity_text);
  const displayName = normalizeText(row.display_name);

  if (!quantity) return true;
  if (isVagueQuantity(quantity)) return true;
  if (displayName && normalizeKey(quantity) === normalizeKey(displayName)) return true;
  return false;
}

function parseLeadingQuantity(text) {
  const value = normalizeText(text);
  if (!value) return null;

  const match = value.match(/^(\d+\s+\d\/\d|\d+\/\d+|\d+(?:\.\d+)?)(?:\s+(.*))?$/);
  if (!match) return null;

  const amountText = match[1];
  const unitText = normalizeText(match[2] || "");
  const amount = parseQuantityAmount(amountText);
  if (amount == null) return null;

  return {
    amount,
    unit: normalizeUnit(unitText),
    unitText,
  };
}

function parseQuantityAmount(text) {
  const value = normalizeText(text);
  if (!value) return null;

  if (/^\d+\s+\d\/\d$/.test(value)) {
    const [whole, fraction] = value.split(/\s+/, 2);
    const [num, den] = fraction.split("/").map((part) => parseInt(part, 10));
    if (!num || !den) return null;
    return parseInt(whole, 10) + num / den;
  }

  if (/^\d+\/\d+$/.test(value)) {
    const [num, den] = value.split("/").map((part) => parseInt(part, 10));
    if (!num || !den) return null;
    return num / den;
  }

  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function formatQuantityAmount(amount) {
  if (!Number.isFinite(amount)) return null;
  const rounded = Math.round(amount * 1000) / 1000;
  const whole = Math.floor(rounded);
  const remainder = Math.abs(rounded - whole);
  const fractionMap = [
    [0.75, "3/4"],
    [0.666, "2/3"],
    [0.5, "1/2"],
    [0.333, "1/3"],
    [0.25, "1/4"],
    [0.2, "1/5"],
    [0.125, "1/8"],
  ];

  if (Number.isInteger(rounded)) return String(rounded);

  for (const [target, fraction] of fractionMap) {
    if (Math.abs(remainder - target) < 0.015) {
      if (whole === 0) return fraction;
      return `${whole} ${fraction}`;
    }
  }

  return rounded.toFixed(2).replace(/\.0+$/, "").replace(/(\.\d*[1-9])0+$/, "$1");
}

function normalizeUnit(unitText) {
  const text = normalizeText(unitText).toLowerCase();
  if (!text) return "";
  return text
    .replace(/\bteaspoons?\b/g, "teaspoon")
    .replace(/\btablespoons?\b/g, "tablespoon")
    .replace(/\bcups?\b/g, "cup")
    .replace(/\bgrams?\b/g, "gram")
    .replace(/\bounces?\b/g, "ounce")
    .replace(/\bpounds?\b/g, "pound")
    .replace(/\bcloves?\b/g, "clove")
    .replace(/\beggs?\b/g, "egg")
    .replace(/\bapricots?\b/g, "apricot")
    .replace(/\braspberries\b/g, "raspberry")
    .replace(/\bsour creams?\b/g, "sour cream")
    .replace(/\bsalted butters?\b/g, "salted butter")
    .replace(/\bgranulated sugars?\b/g, "granulated sugar")
    .replace(/\bfine sea salts?\b/g, "fine sea salt")
    .replace(/\ball purpose flours?\b/g, "all purpose flour")
    .replace(/\bbaking sodas?\b/g, "baking soda")
    .replace(/\bbaking powders?\b/g, "baking powder")
    .replace(/\bvanilla extracts?\b/g, "vanilla extract")
    .replace(/\s+/g, " ")
    .trim();
}

function sumCompatibleQuantities(quantityTexts) {
  const parsed = quantityTexts.map((text) => parseLeadingQuantity(text)).filter(Boolean);
  if (!parsed.length || parsed.length !== quantityTexts.length) return null;

  const unitKey = parsed[0].unit;
  if (!unitKey) {
    if (parsed.every((item) => !item.unit)) {
      const total = parsed.reduce((sum, item) => sum + item.amount, 0);
      return formatQuantityAmount(total);
    }
    return null;
  }

  if (!parsed.every((item) => item.unit === unitKey)) return null;
  const total = parsed.reduce((sum, item) => sum + item.amount, 0);
  const amountText = formatQuantityAmount(total);
  return amountText ? `${amountText} ${parsed[0].unitText || unitKey}`.trim() : null;
}

async function fetchRows(table, select, { filters = [], order = [], limit = 1000, offset = 0 } = {}) {
  let url = `${SUPABASE_URL}/rest/v1/${table}?select=${encodeURIComponent(select)}&limit=${limit}&offset=${offset}`;
  for (const filter of filters) {
    if (filter) url += `&${filter}`;
  }
  for (const clause of order) {
    if (clause) url += `&order=${clause}`;
  }

  const response = await fetch(url, { headers: HEADERS });
  const data = await response.json().catch(() => []);
  if (!response.ok) {
    throw new Error(`${table} fetch failed: ${data?.message ?? data?.error ?? JSON.stringify(data).slice(0, 200)}`);
  }
  return Array.isArray(data) ? data : [];
}

async function fetchAllRows(table, select, options = {}) {
  const pageSize = options.limit ?? 1000;
  let offset = 0;
  const rows = [];

  while (true) {
    const page = await fetchRows(table, select, { ...options, limit: pageSize, offset });
    rows.push(...page);
    if (page.length < pageSize) break;
    offset += page.length;
  }

  return rows;
}

async function fetchRowsByIds(table, select, keyName, ids, order = []) {
  const chunks = chunk(unique(ids), 50);
  const rows = [];

  for (const idChunk of chunks) {
    if (!idChunk.length) continue;
    const filter = `${keyName}=in.(${idChunk.map((value) => encodeURIComponent(value)).join(",")})`;
    const page = await fetchAllRows(table, select, { filters: [filter], order, limit: 1000 });
    rows.push(...page);
  }

  return rows;
}

async function patchRow(table, rowId, payload) {
  const cleaned = Object.fromEntries(
    Object.entries(payload).filter(([, value]) => value !== undefined)
  );
  if (!Object.keys(cleaned).length) return true;

  const response = await fetch(`${SUPABASE_URL}/rest/v1/${table}?id=eq.${encodeURIComponent(rowId)}`, {
    method: "PATCH",
    headers: {
      ...HEADERS,
      Prefer: "return=minimal",
    },
    body: JSON.stringify(cleaned),
  });

  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(`${table} update failed for ${rowId}: ${data?.message ?? data?.error ?? response.statusText}`);
  }

  return true;
}

function buildIngredientIndex(rows) {
  const byId = new Map();
  const byName = new Map();

  for (const row of rows) {
    byId.set(row.id, row);
    const nameKey = normalizeKey(row.normalized_name || row.display_name);
    if (nameKey && !byName.has(nameKey)) byName.set(nameKey, row);
  }

  return { byId, byName };
}

function parseSchemaRecipeInstructions(recipeInstructions) {
  if (Array.isArray(recipeInstructions)) {
    return recipeInstructions
      .map((entry) => {
        if (typeof entry === "string") return normalizeText(entry);
        if (!entry || typeof entry !== "object") return "";
        if (Array.isArray(entry.itemListElement)) {
          return entry.itemListElement.map((value) => {
            if (typeof value === "string") return normalizeText(value);
            return normalizeText(value?.text ?? value?.name ?? "");
          }).filter(Boolean);
        }
        return normalizeText(entry.text ?? entry.name ?? "");
      })
      .flat()
      .filter(Boolean);
  }

  if (typeof recipeInstructions === "string") {
    return [...new Set(
      sanitizeRecipeText(recipeInstructions)
        .split(/\n+/)
        .map(normalizeText)
        .filter(Boolean)
    )];
  }

  return [];
}

function pickBestSchemaRecipe(jsonLdRecipes) {
  const flattened = [];

  const visit = (value) => {
    if (!value) return;
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (typeof value !== "object") return;

    const graph = Array.isArray(value["@graph"]) ? value["@graph"] : [];
    if (graph.length) graph.forEach(visit);

    const type = value["@type"];
    const types = Array.isArray(type) ? type : [type];
    if (types.some((entry) => String(entry ?? "").toLowerCase() === "recipe")) {
      flattened.push(value);
    }
  };

  visit(jsonLdRecipes);

  return flattened
    .map((recipe) => ({
      recipe,
      score:
        (Array.isArray(recipe.recipeIngredient) ? recipe.recipeIngredient.length : 0) * 5
        + parseSchemaRecipeInstructions(recipe.recipeInstructions).length * 7
        + (normalizeText(recipe.name) ? 10 : 0)
        + (normalizeText(recipe.description) ? 4 : 0),
    }))
    .sort((left, right) => right.score - left.score)[0]?.recipe ?? null;
}

async function createBrowserContext({ headless = true } = {}) {
  const browser = await chromium.launch({ headless });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1600 },
    locale: "en-US",
    userAgent:
      process.env.USER_AGENT ||
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
  });
  await context.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
  });
  return { browser, context };
}

async function crawlSourceRecipe(sourceURL, { headless = true } = {}) {
  const { browser, context } = await createBrowserContext({ headless });
  const page = await context.newPage();
  try {
    await page.goto(sourceURL, { waitUntil: "domcontentloaded", timeout: 45000 });
    await page.waitForTimeout(3000);

    const pageData = await page.evaluate(() => {
      const normalize = (value) =>
        String(value ?? "")
          .replace(/\s+/g, " ")
          .trim();

      const meta = (name) =>
        document.querySelector(`meta[name="${name}"], meta[property="${name}"]`)?.getAttribute("content")
        || "";

      const parseJsonLd = () => Array.from(document.querySelectorAll('script[type="application/ld+json"]'))
        .map((node) => node.textContent || "")
        .map((raw) => {
          try {
            return JSON.parse(raw);
          } catch {
            return null;
          }
        })
        .filter(Boolean);

      const findSectionItems = (labels, selectors = ["li", "p"]) => {
        const heading = Array.from(document.querySelectorAll("h1,h2,h3,h4,strong"))
          .find((node) => labels.includes(normalize(node.textContent).toLowerCase()));
        if (!heading) return [];

        const containers = [];
        let node = heading.parentElement;
        let depth = 0;
        while (node && depth < 4) {
          containers.push(node);
          node = node.parentElement;
          depth += 1;
        }

        const lines = [];
        for (const container of containers) {
          for (const selector of selectors) {
            for (const item of Array.from(container.querySelectorAll(selector))) {
              const text = normalize(item.textContent);
              if (text) lines.push(text);
            }
          }
          if (lines.length >= 4) break;
        }
        return [...new Set(lines)].slice(0, 80);
      };

      const ingredientCandidates = [...new Set([
        ...Array.from(document.querySelectorAll('[itemprop="recipeIngredient"]')).map((node) => node.textContent || ""),
        ...Array.from(document.querySelectorAll('li[class*="ingredient"], [class*="ingredient"] li, [data-ingredient]')).map((node) => node.textContent || ""),
        ...findSectionItems(["ingredients"], ["li", "p", "span"]),
      ])].slice(0, 120);

      const instructionCandidates = [...new Set([
        ...Array.from(document.querySelectorAll('[itemprop="recipeInstructions"] li, [itemprop="recipeInstructions"] p')).map((node) => node.textContent || ""),
        ...Array.from(document.querySelectorAll('li[class*="instruction"], li[class*="direction"], [class*="instructions"] li')).map((node) => node.textContent || ""),
        ...findSectionItems(["instructions", "method", "directions"], ["li", "p"]),
      ])].slice(0, 120);

      const pageImageURLs = [...new Set([
        meta("og:image"),
        meta("twitter:image"),
        ...Array.from(document.images)
          .map((node) => node.getAttribute("src") || node.getAttribute("data-src") || node.currentSrc || "")
          .filter(Boolean),
      ])]
        .filter((url) => /^https?:\/\//i.test(url))
        .slice(0, 24);

      return {
        source_url: window.location.href,
        canonical_url: document.querySelector('link[rel="canonical"]')?.getAttribute("href") || window.location.href,
        title: normalize(document.querySelector("h1")?.textContent) || normalize(document.title),
        meta_title: normalize(meta("og:title") || meta("twitter:title") || document.title),
        meta_description: normalize(meta("description") || meta("og:description") || meta("twitter:description")),
        meta_image_url: meta("og:image") || meta("twitter:image") || null,
        meta_video_url: meta("og:video") || meta("og:video:url") || null,
        site_name: normalize(meta("og:site_name")),
        author_name: normalize(meta("author")),
        body_text: normalize(document.body?.innerText || "").slice(0, 120000),
        ingredient_candidates: ingredientCandidates,
        instruction_candidates: instructionCandidates,
        page_image_urls: pageImageURLs,
        json_ld: parseJsonLd(),
      };
    });

    const structuredRecipe = pickBestSchemaRecipe(pageData.json_ld);
    const instructions = parseSchemaRecipeInstructions(structuredRecipe?.recipeInstructions);

    return {
      source_type: "web",
      platform: "web",
      source_url: normalizeText(pageData.source_url) || null,
      canonical_url: normalizeText(pageData.canonical_url) || normalizeText(sourceURL) || null,
      title: normalizeText(pageData.title) || normalizeText(pageData.meta_title) || null,
      meta_title: normalizeText(pageData.meta_title) || null,
      meta_description: normalizeText(pageData.meta_description) || null,
      hero_image_url: normalizeText(pageData.meta_image_url) || null,
      attached_video_url: normalizeText(pageData.meta_video_url) || null,
      site_name: normalizeText(pageData.site_name) || null,
      author_name: normalizeText(pageData.author_name) || null,
      ingredient_candidates: pageData.ingredient_candidates ?? [],
      instruction_candidates: pageData.instruction_candidates ?? [],
      page_image_urls: pageData.page_image_urls ?? [],
      body_text: pageData.body_text ?? "",
      structured_recipe: structuredRecipe
        ? {
            ...structuredRecipe,
            recipeIngredient: Array.isArray(structuredRecipe.recipeIngredient) ? structuredRecipe.recipeIngredient : [],
            recipeInstructions: instructions,
          }
        : null,
    };
  } finally {
    await page.close().catch(() => {});
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
  }
}

function buildSourceIndexes(source) {
  const ingredientsByName = new Map();
  const stepRefsByName = new Map();
  const stepRefsByStep = new Map();
  const structuredIngredients = parseIngredientObjects(source?.structured_recipe?.recipeIngredient ?? []);
  const ingredientCards = structuredIngredients.length
    ? structuredIngredients.map((ingredient) => ({
        displayName: ingredient.display_name ?? ingredient.displayName ?? ingredient.name ?? null,
        quantityText: ingredient.quantity_text ?? ingredient.quantity ?? null,
      }))
    : parseIngredientObjects(source?.ingredient_candidates ?? []).map((ingredient) => ({
        displayName: ingredient.display_name ?? ingredient.displayName ?? ingredient.name ?? null,
        quantityText: ingredient.quantity_text ?? ingredient.quantity ?? null,
      }));
  const steps = parseInstructionSteps(
    source?.structured_recipe?.recipeInstructions ?? source?.instruction_candidates ?? [],
    structuredIngredients
  ).map((step) => ({
    stepNumber: step.number ?? null,
    text: step.text ?? null,
    ingredientRefs: (Array.isArray(step.ingredients) ? step.ingredients : []).map((ingredient) => ({
      displayName: ingredient.display_name ?? ingredient.displayName ?? ingredient.name ?? null,
      quantityText: ingredient.quantity_text ?? ingredient.quantity ?? null,
      sortOrder: ingredient.sort_order ?? null,
    })),
  }));

  for (const card of ingredientCards) {
    const key = normalizeKey(card.displayName);
    if (key && !ingredientsByName.has(key)) {
      ingredientsByName.set(key, card);
    }
  }

  for (const step of steps) {
    const refs = Array.isArray(step.ingredientRefs) ? step.ingredientRefs : [];
    stepRefsByStep.set(step.stepNumber, refs);
    for (const ref of refs) {
      const key = normalizeKey(ref.displayName);
      if (!key) continue;
      if (!stepRefsByName.has(key)) stepRefsByName.set(key, []);
      stepRefsByName.get(key).push({
        stepNumber: step.stepNumber,
        sortOrder: ref.sortOrder,
        displayName: ref.displayName,
        quantityText: ref.quantityText || null,
      });
    }
  }

  return {
    ingredientCards,
    steps,
    ingredientsByName,
    stepRefsByName,
    stepRefsByStep,
  };
}

function candidateNamesForRow(row, ingredientIndex) {
  const names = [];
  const current = normalizeKey(row.display_name);
  if (current) names.push(current);

  const ingredient = row.ingredient_id ? ingredientIndex.byId.get(row.ingredient_id) : null;
  if (ingredient) {
    const canonical = normalizeKey(ingredient.normalized_name || ingredient.display_name);
    if (canonical) names.push(canonical);
    const display = normalizeKey(ingredient.display_name);
    if (display) names.push(display);
  }

  return unique(names);
}

function chooseDisplayName(row, ingredientIndex, scrapedIndexes) {
  const current = normalizeText(row.display_name);
  if (current && !isAbbreviationDisplayName(current)) return current;

  const candidateNames = candidateNamesForRow(row, ingredientIndex);
  for (const name of candidateNames) {
    const scrapedCard = scrapedIndexes.ingredientsByName.get(name);
    if (scrapedCard?.displayName) return scrapedCard.displayName;
    const scrapedRef = scrapedIndexes.stepRefsByName.get(name)?.[0];
    if (scrapedRef?.displayName) return scrapedRef.displayName;
  }

  return current || null;
}

function resolveTopLevelQuantity(row, ingredientIndex, scrapedIndexes) {
  const candidateNames = candidateNamesForRow(row, ingredientIndex);

  for (const name of candidateNames) {
    const card = scrapedIndexes.ingredientsByName.get(name);
    if (card?.quantityText) return card.quantityText;
  }

  const quantities = [];
  for (const name of candidateNames) {
    for (const ref of scrapedIndexes.stepRefsByName.get(name) ?? []) {
      if (ref.quantityText) quantities.push(ref.quantityText);
    }
  }

  const uniqueQuantities = unique(quantities.map((value) => normalizeText(value)));
  if (!uniqueQuantities.length) return null;
  if (uniqueQuantities.length === 1) return uniqueQuantities[0];

  return sumCompatibleQuantities(uniqueQuantities);
}

function resolveStepQuantity(row, step, ingredientIndex, scrapedIndexes) {
  const refs = scrapedIndexes.stepRefsByStep.get(step.stepNumber) ?? [];
  if (!refs.length) return null;

  const candidateNames = candidateNamesForRow(row, ingredientIndex);

  for (const name of candidateNames) {
    const exact = refs.find((ref) => normalizeKey(ref.displayName) === name && ref.quantityText);
    if (exact?.quantityText) return exact.quantityText;
  }

  if (refs.length === 1 && refs[0].quantityText) return refs[0].quantityText;

  if (row.sort_order != null) {
    const bySort = refs.find((ref) => Number(ref.sortOrder) === Number(row.sort_order) && ref.quantityText);
    if (bySort?.quantityText) return bySort.quantityText;
  }

  return null;
}

function buildRecipeResultShape(recipe, ingredientRows, stepRows, stepIngredientRows) {
  return {
    recipe_id: recipe.id,
    title: recipe.title,
    source: recipe.source ?? null,
    source_recipe_url: recipe.recipe_url ?? recipe.original_recipe_url ?? recipe.attached_video_url ?? null,
    status: "matched",
    inspected_tables: {
      recipes: 1,
      recipe_ingredients: ingredientRows.length,
      recipe_steps: stepRows.length,
      recipe_step_ingredients: stepIngredientRows.length,
      ingredients: 0,
    },
    missing_ingredients: [],
    backfill_updates: [],
    notes: [],
  };
}

function serializeRecipeForQuantityInference(recipe, relatedRows, ingredientIndex, scrapedIndexes) {
  const { recipeIngredients, recipeSteps, stepIngredients } = relatedRows;
  const stepById = new Map(recipeSteps.map((row) => [row.id, row]));

  return {
    recipe: {
      id: recipe.id,
      title: recipe.title ?? null,
      description: recipe.description ?? null,
      source: recipe.source ?? null,
      recipe_url: recipe.recipe_url ?? null,
      servings_text: recipe.servings_text ?? null,
      recipe_type: recipe.recipe_type ?? null,
      main_protein: recipe.main_protein ?? null,
      cook_method: recipe.cook_method ?? null,
      cuisine_tags: recipe.cuisine_tags ?? null,
      ingredients_json: recipe.ingredients_json ?? null,
      steps_json: recipe.steps_json ?? null,
    },
    ingredients: recipeIngredients.map((row) => ({
      row_id: row.id,
      ingredient_id: row.ingredient_id ?? null,
      display_name: row.display_name ?? null,
      quantity_text: row.quantity_text ?? null,
      image_url: row.image_url ?? null,
      sort_order: row.sort_order ?? null,
      ingredient_name: row.ingredient_id ? (ingredientIndex.byId.get(row.ingredient_id)?.display_name ?? null) : null,
    })),
    step_ingredients: stepIngredients.map((row) => ({
      row_id: row.id,
      recipe_step_id: row.recipe_step_id ?? null,
      step_number: stepById.get(row.recipe_step_id)?.step_number ?? null,
      ingredient_id: row.ingredient_id ?? null,
      display_name: row.display_name ?? null,
      quantity_text: row.quantity_text ?? null,
      sort_order: row.sort_order ?? null,
    })),
    steps: recipeSteps.map((row) => ({
      step_id: row.id,
      step_number: row.step_number ?? null,
      instruction_text: row.instruction_text ?? null,
      tip_text: row.tip_text ?? null,
    })),
  };
}

function buildSourceInferenceContext(sourceIndexes) {
  const ingredientCards = Array.isArray(sourceIndexes?.ingredientCards) ? sourceIndexes.ingredientCards : [];
  const stepRefsByName = Array.from(sourceIndexes?.stepRefsByName?.entries?.() ?? []);
  const steps = Array.isArray(sourceIndexes?.steps) ? sourceIndexes.steps : [];

  return {
    ingredients: ingredientCards.slice(0, 24).map((card) => ({
      display_name: card.displayName ?? null,
      quantity_text: card.quantityText ?? null,
    })),
    step_refs: stepRefsByName.slice(0, 30).map(([displayName, refs]) => ({
      display_name: displayName,
      refs: (Array.isArray(refs) ? refs : []).slice(0, 3).map((ref) => ({
        step_number: ref.stepNumber ?? null,
        display_name: ref.displayName ?? null,
        quantity_text: ref.quantityText ?? null,
      })),
    })),
    steps: steps.slice(0, 24).map((step) => ({
      step_number: step.stepNumber ?? null,
      text: step.text ?? null,
      ingredient_refs: (Array.isArray(step.ingredientRefs) ? step.ingredientRefs : []).slice(0, 8).map((ref) => ({
        display_name: ref.displayName ?? null,
        quantity_text: ref.quantityText ?? null,
      })),
    })),
  };
}

function isSafeQuantityGuess(value) {
  const text = normalizeText(value);
  if (!text) return false;
  return !isVagueQuantity(text);
}

async function inferMissingQuantitiesWithLLM(recipe, relatedRows, ingredientIndex, sourceIndexes, sourceEvidence = null) {
  if (!openai) return [];

  const payload = {
    ...serializeRecipeForQuantityInference(recipe, relatedRows, ingredientIndex, sourceIndexes),
    source_evidence: sourceEvidence
      ? {
          source_url: sourceEvidence.source_url ?? null,
          canonical_url: sourceEvidence.canonical_url ?? null,
          title: sourceEvidence.title ?? null,
          meta_description: sourceEvidence.meta_description ?? null,
          hero_image_url: sourceEvidence.hero_image_url ?? null,
          page_image_urls: Array.isArray(sourceEvidence.page_image_urls) ? sourceEvidence.page_image_urls.slice(0, 12) : [],
          structured_recipe: sourceEvidence.structured_recipe
            ? {
                name: sourceEvidence.structured_recipe.name ?? null,
                recipeCategory: sourceEvidence.structured_recipe.recipeCategory ?? null,
                recipeCuisine: sourceEvidence.structured_recipe.recipeCuisine ?? null,
                recipeYield: sourceEvidence.structured_recipe.recipeYield ?? null,
                recipeIngredient: (sourceEvidence.structured_recipe.recipeIngredient ?? []).slice(0, 24),
                recipeInstructions: (sourceEvidence.structured_recipe.recipeInstructions ?? []).slice(0, 18),
              }
            : null,
          ingredient_candidates: Array.isArray(sourceEvidence.ingredient_candidates) ? sourceEvidence.ingredient_candidates.slice(0, 24) : [],
          instruction_candidates: Array.isArray(sourceEvidence.instruction_candidates) ? sourceEvidence.instruction_candidates.slice(0, 24) : [],
          body_text: normalizeText(sourceEvidence.body_text ?? "").slice(0, 12000),
        }
      : null,
    source_context: buildSourceInferenceContext(sourceIndexes),
  };

  const hasTargets = [
    ...(Array.isArray(payload.ingredients) ? payload.ingredients : []).filter((row) => needsBackfill(row)),
    ...(Array.isArray(payload.step_ingredients) ? payload.step_ingredients : []).filter((row) => needsBackfill(row)),
  ];
  if (!hasTargets.length) {
    return [];
  }

  const response = await openai.chat.completions.create({
    model: RECIPE_MEASUREMENT_FILL_MODEL,
    temperature: 0.08,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: [
          "You infer missing ingredient measurements for a recipe backfill job.",
          "Return JSON only.",
          "Only update quantity_text fields.",
          "Be conservative. If a value is not strongly implied by the recipe context, return null for that row.",
          "Use the recipe title, description, steps, other ingredient measurements, and any crawled source-page evidence as context.",
          "Do not invent new ingredients or rewrite display names.",
          "Prefer concise grocery-ready quantities like '1 cup', '2', '1 tablespoon', '6 thighs', or '1 bunch'.",
          "If the row already has a clear quantity, leave it unchanged.",
        ].join(" "),
      },
      {
        role: "user",
        content: [
          "Fill the missing ingredient measurements only for these rows.",
          "",
          JSON.stringify(payload),
          "",
          "Return JSON like:",
          JSON.stringify({
            updates: [
              {
                table: "recipe_ingredients",
                row_id: "string",
                quantity_text: "string|null",
                confidence: 0.0,
                reason: "string",
              },
            ],
            unresolved: [
              {
                table: "recipe_ingredients",
                row_id: "string",
                reason: "string",
              },
            ],
          }),
        ].join("\n"),
      },
    ],
  });

  const rawContent = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(rawContent);
  const updates = Array.isArray(parsed.updates) ? parsed.updates : [];

  return updates
    .map((entry) => ({
      table: normalizeText(entry.table).toLowerCase(),
      row_id: normalizeText(entry.row_id),
      quantity_text: normalizeText(entry.quantity_text),
      confidence: Number(entry.confidence ?? 0) || 0,
      reason: normalizeText(entry.reason),
    }))
    .filter((entry) => entry.row_id && entry.quantity_text && isSafeQuantityGuess(entry.quantity_text));
}

async function inspectRecipe(recipe, relatedRows, ingredientIndex, args) {
  const { recipeIngredients, recipeSteps, stepIngredients } = relatedRows;
  const result = buildRecipeResultShape(recipe, recipeIngredients, recipeSteps, stepIngredients);

  const needsInspection = [
    ...recipeIngredients.filter(needsBackfill).map((row) => ({ table: "recipe_ingredients", row })),
    ...stepIngredients
      .filter(needsBackfill)
      .map((row) => ({ table: "recipe_step_ingredients", row })),
  ];

  if (!needsInspection.length) {
    result.status = "matched";
    result.notes.push("No measurement gaps detected after the local filter.");
    return result;
  }

  const sourceURLs = unique([
    recipe.recipe_url,
    recipe.original_recipe_url,
    recipe.attached_video_url,
  ].map((value) => normalizeText(value)).filter((value) => /^https?:\/\//i.test(value)));

  let sourceEvidence = null;
  for (const sourceURL of sourceURLs) {
    try {
      sourceEvidence = await crawlSourceRecipe(sourceURL, { headless: args.headless });
      if (sourceEvidence) break;
    } catch (error) {
      result.notes.push(`Source crawl failed for ${sourceURL}: ${error.message}`);
    }
  }

  const sourceIndexes = buildSourceIndexes(sourceEvidence);
  const matchedTopLevel = new Set();
  const updatedRowIDs = new Set();
  let updatedTop = 0;
  let updatedStep = 0;
  let ambiguousCount = 0;

  for (const row of recipeIngredients) {
    if (!needsBackfill(row)) continue;

    const displayName = chooseDisplayName(row, ingredientIndex, sourceIndexes);
    const quantityText = resolveTopLevelQuantity(row, ingredientIndex, sourceIndexes);
    if (!quantityText && !displayName) {
      ambiguousCount += 1;
      result.missing_ingredients.push({
        table: "recipe_ingredients",
        row_id: row.id,
        recipe_step_id: null,
        ingredient_id: row.ingredient_id ?? null,
        current_display_name: row.display_name ?? null,
        current_quantity_text: row.quantity_text ?? null,
        problem_type: "ambiguous",
        matched_source_name: null,
        matched_source_quantity: null,
        confidence: 0.2,
        reason: "Could not confidently map the Ounje row to a source recipe quantity.",
      });
      continue;
    }

    const payload = {};
    if (displayName && normalizeText(displayName) !== normalizeText(row.display_name)) {
      payload.display_name = displayName;
    }
    if (quantityText && normalizeText(quantityText) !== normalizeText(row.quantity_text)) {
      payload.quantity_text = quantityText;
    }

    if (!Object.keys(payload).length) continue;

    result.missing_ingredients.push({
      table: "recipe_ingredients",
      row_id: row.id,
      recipe_step_id: null,
      ingredient_id: row.ingredient_id ?? null,
      current_display_name: row.display_name ?? null,
      current_quantity_text: row.quantity_text ?? null,
      problem_type: normalizeText(row.display_name) !== normalizeText(displayName) ? "bad_display_name" : "missing_quantity",
      matched_source_name: displayName ?? row.display_name ?? null,
      matched_source_quantity: quantityText ?? null,
      confidence: quantityText ? 0.88 : 0.6,
      reason: "Matched against source-page ingredient cards and step ingredients.",
    });

    result.backfill_updates.push({
      table: "recipe_ingredients",
      row_id: row.id,
      display_name: payload.display_name ?? row.display_name ?? null,
      quantity_text: payload.quantity_text ?? row.quantity_text ?? null,
      reason: "Backfilled from source recipe evidence.",
    });
    updatedTop += 1;
    matchedTopLevel.add(row.id);
    updatedRowIDs.add(row.id);

    if (!args.dryRun) {
      await patchRow("recipe_ingredients", row.id, payload);
    }
  }

  for (const row of stepIngredients) {
    if (!needsBackfill(row)) continue;
    const step = recipeSteps.find((candidate) => candidate.id === row.recipe_step_id);
    if (!step) continue;

    const displayName = chooseDisplayName(row, ingredientIndex, sourceIndexes);
    const quantityText = resolveStepQuantity(row, step, ingredientIndex, sourceIndexes);
    if (!quantityText && !displayName) {
      ambiguousCount += 1;
      result.missing_ingredients.push({
        table: "recipe_step_ingredients",
        row_id: row.id,
        recipe_step_id: row.recipe_step_id,
        ingredient_id: row.ingredient_id ?? null,
        current_display_name: row.display_name ?? null,
        current_quantity_text: row.quantity_text ?? null,
        problem_type: "ambiguous",
        matched_source_name: null,
        matched_source_quantity: null,
        confidence: 0.2,
        reason: "Could not confidently map the step ingredient to a source step ref.",
      });
      continue;
    }

    const payload = {};
    if (displayName && normalizeText(displayName) !== normalizeText(row.display_name)) {
      payload.display_name = displayName;
    }
    if (quantityText && normalizeText(quantityText) !== normalizeText(row.quantity_text)) {
      payload.quantity_text = quantityText;
    }

    if (!Object.keys(payload).length) continue;

    result.missing_ingredients.push({
      table: "recipe_step_ingredients",
      row_id: row.id,
      recipe_step_id: row.recipe_step_id,
      ingredient_id: row.ingredient_id ?? null,
      current_display_name: row.display_name ?? null,
      current_quantity_text: row.quantity_text ?? null,
      problem_type: normalizeText(row.display_name) !== normalizeText(displayName) ? "bad_display_name" : "missing_quantity",
      matched_source_name: displayName ?? row.display_name ?? null,
      matched_source_quantity: quantityText ?? null,
      confidence: quantityText ? 0.99 : 0.6,
      reason: `Matched against source step ${step.step_number}.`,
    });

    result.backfill_updates.push({
      table: "recipe_step_ingredients",
      row_id: row.id,
      display_name: payload.display_name ?? row.display_name ?? null,
      quantity_text: payload.quantity_text ?? row.quantity_text ?? null,
      reason: `Backfilled from source step ${step.step_number}.`,
    });
    updatedStep += 1;
    updatedRowIDs.add(row.id);

    if (!args.dryRun) {
      await patchRow("recipe_step_ingredients", row.id, payload);
    }
  }

  const remainingTargets = [
    ...recipeIngredients.filter((row) => needsBackfill(row) && !updatedRowIDs.has(row.id)),
    ...stepIngredients.filter((row) => needsBackfill(row) && !updatedRowIDs.has(row.id)),
  ];

  if (remainingTargets.length && openai) {
    try {
      const llmUpdates = await inferMissingQuantitiesWithLLM(recipe, relatedRows, ingredientIndex, sourceIndexes, sourceEvidence);
      for (const update of llmUpdates) {
        const targetRow = recipeIngredients.find((row) => row.id === update.row_id && update.table === "recipe_ingredients")
          ?? stepIngredients.find((row) => row.id === update.row_id && update.table === "recipe_step_ingredients");
        if (!targetRow || updatedRowIDs.has(targetRow.id)) continue;

        const inferredQuantity = normalizeText(update.quantity_text);
        if (!inferredQuantity || normalizeText(targetRow.quantity_text) === inferredQuantity) continue;

        const tableName = update.table === "recipe_step_ingredients" ? "recipe_step_ingredients" : "recipe_ingredients";
        const payload = { quantity_text: inferredQuantity };

        result.backfill_updates.push({
          table: tableName,
          row_id: targetRow.id,
          display_name: targetRow.display_name ?? null,
          quantity_text: inferredQuantity,
          reason: update.reason || "Backfilled from LLM recipe context.",
        });

        if (tableName === "recipe_ingredients") {
          updatedTop += 1;
        } else {
          updatedStep += 1;
        }
        updatedRowIDs.add(targetRow.id);

        if (!args.dryRun) {
          await patchRow(tableName, targetRow.id, payload);
        }
      }
    } catch (error) {
      result.notes.push(`LLM quantity backfill skipped: ${error.message}`);
    }
  }

  if (updatedTop === 0 && updatedStep === 0) {
    result.status = ambiguousCount > 0 ? "ambiguous" : "partial";
    result.notes.push("Source recipe match was found, but no safe updates could be applied.");
    return result;
  }

  result.status = ambiguousCount > 0 ? "partial" : "matched";
  if (updatedTop > 0) {
    result.notes.push("Recipe-level quantities were backfilled from source ingredient cards and step refs.");
  }
  if (updatedStep > 0) {
    result.notes.push("Step-level quantities were backfilled directly from source step ingredient refs.");
  }
  return result;
}

async function fetchCandidateRows() {
  const [recipeIngredients, recipeSteps, stepIngredients] = await Promise.all([
    fetchAllRows(
      "recipe_ingredients",
      "id,recipe_id,ingredient_id,display_name,quantity_text,image_url,sort_order,created_at"
    ),
    fetchAllRows(
      "recipe_steps",
      "id,recipe_id,step_number,instruction_text,tip_text,created_at"
    ),
    fetchAllRows(
      "recipe_step_ingredients",
      "id,recipe_step_id,ingredient_id,display_name,quantity_text,sort_order,created_at"
    ),
  ]);

  const stepById = new Map(recipeSteps.map((row) => [row.id, row]));
  const candidateRecipeIds = new Set();
  for (const row of recipeIngredients) {
    if (needsBackfill(row)) candidateRecipeIds.add(row.recipe_id);
  }
  for (const row of stepIngredients) {
    if (!needsBackfill(row)) continue;
    const step = stepById.get(row.recipe_step_id);
    if (step?.recipe_id) candidateRecipeIds.add(step.recipe_id);
  }

  return {
    recipeIngredients,
    recipeSteps,
    stepIngredients,
    candidateRecipeIds: [...candidateRecipeIds],
    stepById,
  };
}

function partitionRowsByRecipe(recipeIds, recipeIngredients, recipeSteps, stepIngredients) {
  const recipeIdSet = new Set(recipeIds);
  const stepsByRecipe = new Map();

  for (const step of recipeSteps) {
    if (!recipeIdSet.has(step.recipe_id)) continue;
    if (!stepsByRecipe.has(step.recipe_id)) stepsByRecipe.set(step.recipe_id, []);
    stepsByRecipe.get(step.recipe_id).push(step);
  }

  const stepIdToRecipeId = new Map();
  for (const [recipeId, steps] of stepsByRecipe.entries()) {
    for (const step of steps) stepIdToRecipeId.set(step.id, recipeId);
  }

  const ingredientsByRecipe = new Map();
  for (const row of recipeIngredients) {
    if (!recipeIdSet.has(row.recipe_id)) continue;
    if (!ingredientsByRecipe.has(row.recipe_id)) ingredientsByRecipe.set(row.recipe_id, []);
    ingredientsByRecipe.get(row.recipe_id).push(row);
  }

  const stepIngredientsByRecipe = new Map();
  for (const row of stepIngredients) {
    const recipeId = stepIdToRecipeId.get(row.recipe_step_id);
    if (!recipeId || !recipeIdSet.has(recipeId)) continue;
    if (!stepIngredientsByRecipe.has(recipeId)) stepIngredientsByRecipe.set(recipeId, []);
    stepIngredientsByRecipe.get(recipeId).push(row);
  }

  return { ingredientsByRecipe, stepsByRecipe, stepIngredientsByRecipe };
}

async function fetchIngredientRowsForRecipe(recipeIngredients, stepIngredients) {
  const ingredientIds = unique([
    ...recipeIngredients.map((row) => row.ingredient_id),
    ...stepIngredients.map((row) => row.ingredient_id),
  ]);

  if (!ingredientIds.length) return [];

  return fetchRowsByIds(
    "ingredients",
    "id,display_name,normalized_name,default_image_url,created_at,updated_at",
    "id",
    ingredientIds,
    ["display_name.asc"]
  );
}

async function fetchRecipesByIds(ids) {
  if (!ids.length) return [];
  return fetchRowsByIds(
    "recipes",
    "id,title,description,source,recipe_url,original_recipe_url,attached_video_url,servings_text,recipe_type,main_protein,cook_method,cuisine_tags,ingredients_json,steps_json,created_at,updated_at",
    "id",
    ids,
    ["created_at.asc"]
  );
}

function sortRecipeCandidates(recipes) {
  return [...recipes].sort((a, b) => {
    const aTime = new Date(a.updated_at || a.created_at || 0).getTime();
    const bTime = new Date(b.updated_at || b.created_at || 0).getTime();
    return aTime - bTime;
  });
}

function buildMissingCountsByRecipe(allRows) {
  const counts = new Map();
  const { recipeIngredients, stepIngredients, stepById } = allRows;

  for (const row of recipeIngredients) {
    if (!needsBackfill(row)) continue;
    counts.set(row.recipe_id, (counts.get(row.recipe_id) ?? 0) + 1);
  }

  for (const row of stepIngredients) {
    if (!needsBackfill(row)) continue;
    const recipeId = stepById.get(row.recipe_step_id)?.recipe_id;
    if (!recipeId) continue;
    counts.set(recipeId, (counts.get(recipeId) ?? 0) + 1);
  }

  return counts;
}

function sortRecipesByPriority(recipes, missingCountsByRecipe) {
  return [...recipes].sort((a, b) => {
    const aMissing = missingCountsByRecipe.get(a.id) ?? 0;
    const bMissing = missingCountsByRecipe.get(b.id) ?? 0;
    if (aMissing !== bMissing) return bMissing - aMissing;

    const aSource = unique([a.recipe_url, a.original_recipe_url, a.attached_video_url].map((value) => normalizeText(value)).filter(Boolean)).length > 0 ? 1 : 0;
    const bSource = unique([b.recipe_url, b.original_recipe_url, b.attached_video_url].map((value) => normalizeText(value)).filter(Boolean)).length > 0 ? 1 : 0;
    if (aSource !== bSource) return bSource - aSource;

    const aUpdated = new Date(a.updated_at || a.created_at || 0).getTime();
    const bUpdated = new Date(b.updated_at || b.created_at || 0).getTime();
    return aUpdated - bUpdated;
  });
}

function cooldownForOutcome(outcome) {
  if (!outcome) return DEFAULT_PARTIAL_OR_AMBIGUOUS_COOLDOWN_MS;
  if (outcome.status === "not_found") return DEFAULT_NOT_FOUND_COOLDOWN_MS;
  if (outcome.status === "partial" || outcome.status === "ambiguous") {
    return DEFAULT_PARTIAL_OR_AMBIGUOUS_COOLDOWN_MS;
  }
  if (outcome.updated > 0) return DEFAULT_MATCHED_UPDATED_COOLDOWN_MS;
  return DEFAULT_MATCHED_NO_UPDATE_COOLDOWN_MS;
}

async function processBatch(recipeIds, allRows, args) {
  const { recipeIngredients, recipeSteps, stepIngredients } = allRows;
  const recipes = await fetchRecipesByIds(recipeIds);
  const recipeMap = new Map(recipes.map((recipe) => [recipe.id, recipe]));
  const { ingredientsByRecipe, stepsByRecipe, stepIngredientsByRecipe } = partitionRowsByRecipe(
    recipeIds,
    recipeIngredients,
    recipeSteps,
    stepIngredients
  );

  let processed = 0;
  let updated = 0;
  let matched = 0;
  let partial = 0;
  let ambiguous = 0;
  let notFound = 0;
  const outcomes = [];

  for (const recipeId of recipeIds) {
    const recipe = recipeMap.get(recipeId);
    if (!recipe) continue;

    const recipeIngredientRows = ingredientsByRecipe.get(recipeId) ?? [];
    const recipeStepRows = stepsByRecipe.get(recipeId) ?? [];
    const recipeStepIngredientRows = stepIngredientsByRecipe.get(recipeId) ?? [];
    const relevantIngredientIndex = await fetchIngredientRowsForRecipe(recipeIngredientRows, recipeStepIngredientRows);
    const ingredientIndex = buildIngredientIndex(relevantIngredientIndex);

    try {
      const result = await inspectRecipe(
        recipe,
        {
          recipeIngredients: recipeIngredientRows,
          recipeSteps: recipeStepRows,
          stepIngredients: recipeStepIngredientRows,
        },
        ingredientIndex,
        args
      );

      processed += 1;
      if (result.status === "matched") matched += 1;
      else if (result.status === "partial") partial += 1;
      else if (result.status === "ambiguous") ambiguous += 1;
      else if (result.status === "not_found") notFound += 1;
      const rowUpdates = result.backfill_updates.length;
      updated += rowUpdates;
      outcomes.push({
        recipeId: recipe.id,
        status: result.status,
        updated: rowUpdates,
      });

      console.log(
        JSON.stringify(
          {
            recipe_id: recipe.id,
            title: recipe.title,
            status: result.status,
            top_level_updates: result.backfill_updates.filter((entry) => entry.table === "recipe_ingredients").length,
            step_updates: result.backfill_updates.filter((entry) => entry.table === "recipe_step_ingredients").length,
            notes: result.notes,
          },
          null,
          2
        )
      );
    } catch (error) {
      processed += 1;
      notFound += 1;
      outcomes.push({
        recipeId: recipe.id,
        status: "not_found",
        updated: 0,
      });
      console.error(`[backfill] ${recipe.id} ${recipe.title}: ${error.message}`);
    }
  }

  return { processed, updated, matched, partial, ambiguous, notFound, outcomes };
}

async function selectBatchRecipeIds(allRows, args, cooldownMap) {
  const { candidateRecipeIds } = allRows;
  const filtered = [];

  for (const recipeId of candidateRecipeIds) {
    const until = cooldownMap.get(recipeId);
    if (until && Date.now() < until) continue;
    filtered.push(recipeId);
  }

  if (args.recipeId) {
    return [args.recipeId];
  }

  const recipes = await fetchRecipesByIds(filtered);
  const missingCountsByRecipe = buildMissingCountsByRecipe(allRows);
  const sortedRecipes = sortRecipesByPriority(recipes, missingCountsByRecipe);
  const sortedRecipeIds = sortedRecipes.map((recipe) => recipe.id);
  return sortedRecipeIds.slice(0, args.batchSize);
}

async function main() {
  const args = parseArgs(process.argv);
  const cooldownMap = new Map();
  let cycle = 0;

  console.log(
    JSON.stringify(
        {
          mode: args.recipeId ? "single" : args.once ? "once" : "daemon",
          batch_size: args.batchSize,
          headless: args.headless,
          dry_run: args.dryRun,
          source_crawl: true,
        },
      null,
      2
    )
  );

  while (true) {
    cycle += 1;
    const allRows = await fetchCandidateRows();
    const batchRecipeIds = await selectBatchRecipeIds(allRows, args, cooldownMap);

    if (!batchRecipeIds.length) {
      console.log(`[backfill] cycle ${cycle}: no candidate recipes. sleeping ${Math.round(args.idleSleepMs / 1000)}s`);
      if (args.once || args.recipeId) break;
      await new Promise((resolve) => setTimeout(resolve, args.idleSleepMs));
      continue;
    }

    console.log(`[backfill] cycle ${cycle}: processing ${batchRecipeIds.length} recipes`);
    const summary = await processBatch(batchRecipeIds, allRows, args);
    console.log(
      JSON.stringify(
        {
          cycle,
          processed: summary.processed,
          updated: summary.updated,
          matched: summary.matched,
          partial: summary.partial,
          ambiguous: summary.ambiguous,
          notFound: summary.notFound,
        },
        null,
        2
      )
    );

    if (args.recipeId || args.once) break;

    for (const outcome of summary.outcomes ?? []) {
      cooldownMap.set(outcome.recipeId, Date.now() + cooldownForOutcome(outcome));
    }

    if (summary.processed === 0) {
      await new Promise((resolve) => setTimeout(resolve, args.idleSleepMs));
    }
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
