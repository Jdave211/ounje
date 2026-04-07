import { chromium } from "playwright";
import OpenAI from "openai";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { loadProviderSession, loadPreferredProviderSession } from "./provider-session-store.js";

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const INSTACART_PRODUCT_MODEL = process.env.INSTACART_PRODUCT_MODEL ?? "gpt-4.1-mini";
const openai = OPENAI_API_KEY ? new OpenAI({ apiKey: OPENAI_API_KEY }) : null;

const STORE_HINTS = [
  "Metro",
  "No Frills",
  "FreshCo",
  "Food Basics",
  "Sobeys",
  "Loblaws",
  "Walmart",
  "Costco",
  "Real Canadian Superstore",
  "Shoppers Drug Mart",
];

const PROBE_NOISE_TERMS = new Set([
  "salt",
  "pepper",
  "black pepper",
  "water",
  "ice",
  "oil",
  "olive oil",
  "vegetable oil",
  "canola oil",
  "flour",
  "sugar",
  "milk",
  "butter",
  "eggs",
  "egg",
]);

const FRESH_HERB_TERMS = new Set([
  "basil",
  "cilantro",
  "coriander",
  "dill",
  "mint",
  "oregano",
  "parsley",
  "rosemary",
  "sage",
  "thyme",
]);

const FRESH_PRODUCE_TERMS = new Set([
  "avocado",
  "broccoli",
  "cabbage",
  "carrot",
  "cauliflower",
  "celery",
  "cilantro",
  "cucumber",
  "eggplant",
  "garlic",
  "ginger",
  "green onion",
  "green onions",
  "jalapeno",
  "jalapenos",
  "kale",
  "lettuce",
  "lime",
  "limes",
  "mango",
  "mushroom",
  "mushrooms",
  "onion",
  "onions",
  "parsley",
  "potato",
  "potatoes",
  "romaine",
  "romaine lettuce",
  "spinach",
  "tomato",
  "tomatoes",
  "watermelon",
  "zucchini",
]);

const PANTRY_OR_PREPARED_TERMS = [
  "bottle",
  "bouillon",
  "broth",
  "canned",
  "capsule",
  "concentrate",
  "cube",
  "dressing",
  "dried",
  "extract",
  "flavored",
  "frozen",
  "glass",
  "ground",
  "jar",
  "juice",
  "marinade",
  "mix",
  "paste",
  "pickled",
  "powder",
  "prepared",
  "puree",
  "rub",
  "salsa",
  "sauce",
  "seasoning",
  "smoothie",
  "soup",
  "spice",
  "spray",
  "stuffed",
  "tea",
];

const NON_FOOD_OR_TOOL_TERMS = [
  "knife",
  "knives",
  "fork",
  "spoon",
  "skillet",
  "pan",
  "pot",
  "plate",
  "bowl",
  "napkin",
  "toothbrush",
  "mouthwash",
  "detergent",
  "bleach",
  "soap",
  "shampoo",
  "conditioner",
  "cleaner",
  "battery",
  "batteries",
  "filter",
  "lotion",
  "toothpaste",
  "patches",
  "cream",
];

const NOT_STORE_LINE_PATTERNS = [
  /^\d+(?:\.\d+)?\s*km$/i,
  /^\d+(?:\.\d+)?\s*(?:min|mins|hr|hrs)$/i,
  /^by\s+\d/i,
  /^delivery$/i,
  /^pickup$/i,
  /^\$\d/,
  /^[\d\s.,/-]+$/,
];

const GENERIC_CHICKEN_TERMS = ["breast", "breasts", "thigh", "thighs", "cutlet", "cutlets", "boneless", "skinless", "tenderloin", "tenderloins"];
const REJECT_GENERIC_CHICKEN_TERMS = ["whole", "rotisserie", "wings", "nuggets", "tenders", "strips", "fried", "breaded", "popcorn"];
const PREFER_GENERIC_SHRIMP_TERMS = ["raw", "plain", "frozen", "peeled", "deveined", "tail-off", "tail off"];
const REJECT_GENERIC_SHRIMP_TERMS = ["ring", "platter", "cocktail", "tray", "tempura", "breaded", "battered", "scampi", "sauced"];
const ACTIONABLE_PRODUCT_BUTTON_SELECTOR = [
  'button[aria-label*="Add"]',
  'button[aria-label*="Choose"]',
  'button:has-text("Add")',
  'button:has-text("Choose")',
].join(", ");
const INSTACART_TRACE_DIR = process.env.INSTACART_TRACE_DIR ?? path.resolve(process.cwd(), "server/logs/instacart-runs");

function buildSearchUrl(term, storePath = null) {
  const path = storePath ?? "/store";
  return `https://www.instacart.ca${path.replace(/\/$/, "")}/s?k=${encodeURIComponent(term)}`;
}

function normalizeItemName(name) {
  return String(name ?? "")
    .toLowerCase()
    .replace(/\b(fresh|organic|large|small|medium|ripe|frozen|diced|chopped|sliced|minced|grated|shredded)\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
}

function tokenizeItemName(name) {
  return normalizeItemName(name)
    .split(" ")
    .map((token) => token.trim())
    .filter((token) => token.length > 1);
}

function nowISO() {
  return new Date().toISOString();
}

function slugifyTracePart(value, fallback = "run") {
  const normalized = String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 32);
  return normalized || fallback;
}

function summarizeCandidate(candidate) {
  if (!candidate) return null;
  return {
    title: candidate.title ?? null,
    rawLabel: candidate.rawLabel ?? null,
    score: Number.isFinite(candidate.score) ? Number(candidate.score.toFixed(2)) : null,
    actionType: candidate.actionType ?? null,
    actionLabel: candidate.actionLabel ?? null,
    productHref: candidate.productHref ?? null,
    cardText: candidate.cardText ?? null,
  };
}

async function persistRunTrace(trace) {
  try {
    await mkdir(INSTACART_TRACE_DIR, { recursive: true });
    const tracePath = path.join(INSTACART_TRACE_DIR, `${trace.runId}.json`);
    await writeFile(tracePath, JSON.stringify(trace, null, 2), "utf8");
    return tracePath;
  } catch (error) {
    trace.persistenceError = error.message;
    return null;
  }
}

function containsAnyTerm(text, terms) {
  const haystack = ` ${String(text ?? "").toLowerCase()} `;
  return terms.some((term) => haystack.includes(` ${String(term).toLowerCase()} `) || haystack.includes(String(term).toLowerCase()));
}

function uniqueTerms(values, limit = 8) {
  return [...new Set((values ?? []).map((value) => normalizeItemName(value)).filter(Boolean))].slice(0, limit);
}

function classifyQueryProfile(query) {
  const normalizedQuery = normalizeItemName(query);
  const tokens = tokenizeItemName(normalizedQuery);
  const tokenSet = new Set(tokens);
  const freshHerb = tokens.some((token) => FRESH_HERB_TERMS.has(token)) || FRESH_HERB_TERMS.has(normalizedQuery);
  const freshProduce = freshHerb ||
    tokens.some((token) => FRESH_PRODUCE_TERMS.has(token)) ||
    FRESH_PRODUCE_TERMS.has(normalizedQuery);
  const genericChicken = normalizedQuery === "chicken";
  const genericShrimp = normalizedQuery === "shrimp";

  return {
    normalizedQuery,
    tokens,
    tokenSet,
    freshHerb,
    freshProduce,
    genericChicken,
    genericShrimp,
  };
}

function extractCandidateTitle(label) {
  return String(label ?? "")
    .replace(/^Add\s+\d+(?:\.\d+)?\s*(?:ct|item|items|kg|g|oz|lb|l|ml|pack|packs|bunch|bunches)?\s*/i, "")
    .replace(/^Add\s+/i, "")
    .replace(/\s+/g, " ")
    .trim();
}

function scoreProductLabel(productLabel, query, shoppingContext = null) {
  const normalizedLabel = normalizeItemName(productLabel);
  const profile = classifyQueryProfile(query);
  const normalizedQuery = profile.normalizedQuery;
  if (!normalizedLabel || !normalizedQuery) return Number.NEGATIVE_INFINITY;

  const queryTokens = profile.tokens;
  const labelTokens = tokenizeItemName(normalizedLabel);
  const labelSet = new Set(labelTokens);
  const exactPhrase = normalizedLabel.includes(normalizedQuery);
  const matchedTokens = queryTokens.filter((token) => labelSet.has(token));
  const tokenCoverage = queryTokens.length > 0 ? matchedTokens.length / queryTokens.length : 0;
  const extraTokenPenalty = Math.max(0, labelTokens.length - matchedTokens.length) * 2.1;
  const queryLengthBonus = Math.min(18, normalizedQuery.length * 0.4);
  const exactTokenBonus = matchedTokens.reduce((sum, token) => sum + (normalizedLabel.includes(` ${token} `) ? 2.5 : 0), 0);

  let score = tokenCoverage * 120 + queryLengthBonus + exactTokenBonus - extraTokenPenalty;
  if (exactPhrase) score += 80;
  if (normalizedLabel.startsWith(normalizedQuery)) score += 24;
  if (normalizedLabel === normalizedQuery) score += 180;
  if (labelTokens.length <= 3) score += 10;
  if (/\b(trio|sampler|pack|bundle|variety|mix|combo)\b/i.test(normalizedLabel)) score -= 22;
  if (/\b(cake|candy|soap|toothpaste|drink|beverage|juice)\b/i.test(normalizedLabel) && !/\bloaf\b/i.test(normalizedQuery)) {
    score -= 12;
  }
  if (profile.freshHerb || profile.freshProduce) {
    if (containsAnyTerm(normalizedLabel, PANTRY_OR_PREPARED_TERMS)) score -= 180;
    if (/\b(organic|fresh|bunch|whole|raw)\b/i.test(normalizedLabel)) score += 18;
  }
  if (profile.freshHerb && !/\b(fresh|bunch|leaf|leaves|live)\b/i.test(normalizedLabel)) {
    score -= 40;
  }
  if (profile.genericChicken) {
    if (containsAnyTerm(normalizedLabel, REJECT_GENERIC_CHICKEN_TERMS)) score -= 160;
    if (containsAnyTerm(normalizedLabel, GENERIC_CHICKEN_TERMS)) score += 36;
  }
  if (profile.genericShrimp) {
    if (containsAnyTerm(normalizedLabel, REJECT_GENERIC_SHRIMP_TERMS)) score -= 160;
    if (containsAnyTerm(normalizedLabel, PREFER_GENERIC_SHRIMP_TERMS)) score += 28;
  }
  const preferredForms = uniqueTerms(shoppingContext?.preferredForms ?? [], 8);
  const avoidForms = uniqueTerms(shoppingContext?.avoidForms ?? [], 10);
  if (preferredForms.some((form) => form && normalizedLabel.includes(form))) score += 36;
  if (avoidForms.some((form) => form && normalizedLabel.includes(form))) score -= 180;

  return score;
}

function isStrongCandidateMismatch(productLabel, query, shoppingContext = null) {
  const normalizedLabel = normalizeItemName(productLabel);
  const profile = classifyQueryProfile(query);
  const normalizedQuery = profile.normalizedQuery;
  if (!normalizedLabel || !normalizedQuery) return false;

  const mismatchTerms = [
    "oyster",
    "oysters",
    "seafood",
    "fish",
    "salmon",
    "tuna",
    "scallop",
    "scallops",
    "lobster",
    "crab",
    "shrimp",
    "soap",
    "toothpaste",
    "candy",
    "drink",
    "beverage",
    "juice",
    "cake",
    "dessert",
  ];

  if ((profile.freshHerb || profile.freshProduce) && containsAnyTerm(normalizedLabel, PANTRY_OR_PREPARED_TERMS)) {
    return true;
  }
  if (profile.genericChicken && containsAnyTerm(normalizedLabel, REJECT_GENERIC_CHICKEN_TERMS)) {
    return true;
  }
  if (profile.genericShrimp && containsAnyTerm(normalizedLabel, REJECT_GENERIC_SHRIMP_TERMS)) {
    return true;
  }
  if (containsAnyTerm(normalizedLabel, NON_FOOD_OR_TOOL_TERMS)) {
    return true;
  }
  const avoidForms = uniqueTerms(shoppingContext?.avoidForms ?? [], 10);
  if (avoidForms.some((form) => form && normalizedLabel.includes(form))) return true;

  return mismatchTerms.some((term) => normalizedLabel.includes(term) && !profile.tokenSet.has(term));
}

async function chooseBestAddButton(page, query, shoppingContext = null) {
  const addButtons = page.locator('button[aria-label*="Add"]');
  const count = await addButtons.count();
  let best = null;

  for (let i = 0; i < count; i += 1) {
    const button = addButtons.nth(i);
    if (!(await button.isVisible().catch(() => false))) continue;
    const ariaLabel = await button.getAttribute("aria-label").catch(() => null);
    const text = await button.innerText().catch(() => "");
    const cardText = await extractNearbyCardText(button);
    const candidateLabel = [ariaLabel, text, cardText].filter(Boolean).join(" ").trim();
    const score = scoreProductLabel(candidateLabel, query, shoppingContext);
    if (!Number.isFinite(score)) continue;
    if (isStrongCandidateMismatch(candidateLabel, query, shoppingContext)) continue;
    if (!best || score > best.score) {
      best = { button, score, candidateLabel };
    }
  }

  return best;
}

async function extractNearbyCardText(locator) {
  return locator.evaluate((el) => {
    let node = el;
    for (let depth = 0; depth < 7 && node; depth += 1) {
      node = node.parentElement;
      if (!node) break;
      const text = (node.innerText || "").replace(/\s+/g, " ").trim();
      if (text && text.length > 3) {
        return text.slice(0, 520);
      }
    }
    return "";
  }).catch(() => "");
}

async function extractProductCardContext(locator) {
  return locator.evaluate((el) => {
    const clean = (value, max = 520) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, max);
    const buttonLabel = (node) =>
      clean(node?.getAttribute?.("aria-label") || node?.innerText || node?.textContent || "", 160);

    let node = el;
    let fallback = null;

    for (let depth = 0; depth < 9 && node; depth += 1) {
      node = node.parentElement;
      if (!node) break;

      const text = clean(node.innerText || "");
      if (!text || text.length < 8) continue;

      const productLink = node.querySelector('a[href*="/products/"]');
      const heading =
        node.querySelector("h1, h2, h3, h4, [data-testid*='item-name'], [data-testid*='product-name']") ||
        productLink;
      const directAction =
        node.querySelector('button[aria-label*="Add"]') ||
        node.querySelector('button[aria-label*="Choose"]') ||
        [...node.querySelectorAll("button")].find((button) => /add|choose/i.test(buttonLabel(button)));

      const context = {
        title: clean(heading?.textContent || ""),
        cardText: text,
        productHref: productLink?.href || null,
        actionLabel: buttonLabel(directAction),
      };

      if (!fallback) fallback = context;
      if (context.productHref || context.title || context.actionLabel) {
        return context;
      }
    }

    return fallback ?? {
      title: "",
      cardText: clean(el?.innerText || ""),
      productHref: null,
      actionLabel: buttonLabel(el),
    };
  }).catch(() => ({
    title: "",
    cardText: "",
    productHref: null,
    actionLabel: "",
  }));
}

async function collectProductCandidates(page, query, shoppingContext = null, maxCandidates = 12) {
  const actionButtons = page.locator(ACTIONABLE_PRODUCT_BUTTON_SELECTOR);
  const count = await actionButtons.count();
  const candidates = [];
  const seen = new Set();

  for (let i = 0; i < count; i += 1) {
    const button = actionButtons.nth(i);
    if (!(await button.isVisible().catch(() => false))) continue;
    const ariaLabel = await button.getAttribute("aria-label").catch(() => null);
    const text = await button.innerText().catch(() => "");
    const rawLabel = (ariaLabel ?? text ?? "").trim();
    const cardContext = await extractProductCardContext(button);
    const title = cardContext.title || extractCandidateTitle(rawLabel);
    const cardText = cardContext.cardText || await extractNearbyCardText(button);
    const actionType = /choose/i.test(rawLabel || cardContext.actionLabel || "") ? "choose" : "add";
    const score = Math.max(
      scoreProductLabel(title || rawLabel, query, shoppingContext),
      scoreProductLabel(cardText || title || rawLabel, query, shoppingContext),
    );

    const candidate = {
      buttonIndex: i,
      title,
      rawLabel,
      score,
      cardText: String(cardText ?? "").replace(/\s+/g, " ").trim().slice(0, 360),
      actionType,
      actionLabel: rawLabel || cardContext.actionLabel || "",
      productHref: cardContext.productHref || null,
    };
    const key = candidateKey(candidate);
    if (seen.has(key)) continue;
    seen.add(key);
    candidates.push(candidate);
  }

  return candidates
    .sort((a, b) =>
      b.score - a.score ||
      a.title.localeCompare(b.title) ||
      a.buttonIndex - b.buttonIndex
    )
    .slice(0, maxCandidates);
}

function candidateKey(candidate) {
  return [
    normalizeItemName(candidate?.productHref),
    normalizeItemName(candidate?.title),
    normalizeItemName(candidate?.rawLabel),
    normalizeItemName(candidate?.cardText),
  ].join("||");
}

async function collectScrollableProductCandidates(page, query, shoppingContext = null, {
  maxCandidates = 40,
  maxScrollRounds = 6,
} = {}) {
  const deduped = new Map();

  for (let round = 0; round < maxScrollRounds; round += 1) {
    const current = await collectProductCandidates(page, query, shoppingContext, maxCandidates);
    for (const candidate of current) {
      const key = candidateKey(candidate);
      if (!deduped.has(key) || (deduped.get(key)?.score ?? Number.NEGATIVE_INFINITY) < candidate.score) {
        deduped.set(key, candidate);
      }
    }

    if (deduped.size >= maxCandidates) break;

    const beforeHeight = await page.evaluate(() => document.body?.scrollHeight ?? 0).catch(() => 0);
    await page.evaluate(() => {
      window.scrollBy(0, Math.max(window.innerHeight * 0.85, 900));
    }).catch(() => {});
    await page.waitForTimeout(1200);
    const afterHeight = await page.evaluate(() => document.body?.scrollHeight ?? 0).catch(() => 0);
    const nearBottom = await page.evaluate(() => (window.innerHeight + window.scrollY) >= ((document.body?.scrollHeight ?? 0) - 120)).catch(() => false);
    if (nearBottom && afterHeight <= beforeHeight) {
      break;
    }
  }

  return [...deduped.values()]
    .sort((a, b) =>
      b.score - a.score ||
      a.title.localeCompare(b.title) ||
      a.buttonIndex - b.buttonIndex
    )
    .slice(0, maxCandidates);
}

const NON_DISTINGUISHING_DESCRIPTOR_TOKENS = new Set([
  "a",
  "an",
  "and",
  "or",
  "the",
  "for",
  "with",
  "of",
  "to",
  "fresh",
  "plain",
  "whole",
  "large",
  "medium",
  "small",
  "raw",
  "peeled",
  "deveined",
  "boneless",
  "skinless",
  "cooked",
  "bunch",
  "strips",
  "breast",
  "breasts",
  "thigh",
  "thighs",
  "fillet",
  "filet",
  "dozen",
  "mixed",
  "all",
  "purpose",
  "organic",
  "natural",
  "original",
  "raised",
  "canadian",
  "farms",
  "bulbs",
  "salad",
  "sauce",
  "dressing",
  "cheese",
  "chicken",
  "shrimp",
  "salmon",
  "steak",
  "eggs",
  "egg",
  "greens",
  "lettuce",
  "onions",
  "onion",
  "garlic",
  "rice",
  "paper",
  "wrappers",
  "carrots",
  "carrot",
  "butter",
  "powder",
  "chips",
  "cucumber",
  "apples",
  "apple",
  "avocado",
  "blueberries",
  "blueberry",
  "yogurt",
  "sugar",
  "flour",
  "pepper",
  "seasoning",
  "skewers",
  "jalapenos",
  "jalapeños",
]);

function tokenizeMeaningfulDescriptors(value) {
  return [...new Set(
    normalizeItemName(value)
      .split(" ")
      .map((token) => token.replace(/[^a-z0-9]+/gi, "").trim())
      .filter((token) => token.length >= 4 && !NON_DISTINGUISHING_DESCRIPTOR_TOKENS.has(token))
  )];
}

function getRequiredDescriptorTokens(query, shoppingContext = null) {
  const explicitDescriptors = shoppingContext?.requiredDescriptors ?? [];
  return [...new Set(
    explicitDescriptors
      .flatMap((value) => tokenizeMeaningfulDescriptors(value))
      .filter(Boolean)
  )];
}

function applyDescriptorDecisionGuard(candidate, query, shoppingContext = null, decisionPayload = {}) {
  if (!candidate) return decisionPayload;

  const requiredDescriptors = getRequiredDescriptorTokens(query, shoppingContext);
  if (!requiredDescriptors.length) return decisionPayload;

  const candidateText = normalizeItemName([
    candidate.title,
    candidate.rawLabel,
  ].filter(Boolean).join(" "));

  const missingDescriptors = requiredDescriptors.filter((token) => !candidateText.includes(token));
  if (!missingDescriptors.length) return decisionPayload;

  const substitutionPolicy = String(shoppingContext?.substitutionPolicy ?? "strict").toLowerCase();
  const nextDecision = substitutionPolicy === "strict" ? "reject" : "substitute";
  const nextMatchType = substitutionPolicy === "optional" ? "usable_substitute" : "close_substitute";

  return {
    ...decisionPayload,
    decision: nextDecision,
    matchType: nextDecision === "reject" ? "unsafe" : nextMatchType,
    needsReview: true,
    substituteReason: nextDecision === "substitute"
      ? `missing_descriptors:${missingDescriptors.join(",")}`
      : null,
    reason: `${decisionPayload.reason ?? "descriptor_guard"}; missing descriptors: ${missingDescriptors.join(", ")}`,
    missingDescriptors,
  };
}

function inferHeuristicDecision(candidate, query, shoppingContext = null) {
  if (!candidate) {
    return {
      success: false,
      decision: "reject",
      matchType: "unsafe",
      needsReview: true,
      substituteReason: null,
      reason: "no_candidate",
    };
  }

  const normalizedTitle = normalizeItemName(candidate.title || candidate.rawLabel);
  const normalizedQuery = normalizeItemName(query);
  const substitutionPolicy = String(shoppingContext?.substitutionPolicy ?? "strict").toLowerCase();
  const preferredForms = uniqueTerms(shoppingContext?.preferredForms ?? [], 8);
  const exactish = normalizedTitle === normalizedQuery || normalizedTitle.includes(normalizedQuery) || preferredForms.some((form) => normalizedTitle.includes(form));

  if (exactish) {
    return applyDescriptorDecisionGuard(candidate, query, shoppingContext, {
      success: true,
      decision: "exact_match",
      matchType: "exact",
      needsReview: false,
      substituteReason: null,
      reason: "heuristic_exactish_match",
    });
  }

  if (substitutionPolicy === "flexible" && candidate.score >= 85) {
    return applyDescriptorDecisionGuard(candidate, query, shoppingContext, {
      success: true,
      decision: "substitute",
      matchType: "close_substitute",
      needsReview: false,
      substituteReason: "heuristic_close_substitute",
      reason: "heuristic_close_substitute",
    });
  }

  if (substitutionPolicy === "optional" && candidate.score >= 55) {
    return applyDescriptorDecisionGuard(candidate, query, shoppingContext, {
      success: true,
      decision: "substitute",
      matchType: "usable_substitute",
      needsReview: true,
      substituteReason: "heuristic_optional_substitute",
      reason: "heuristic_optional_substitute",
    });
  }

  return {
    success: false,
    decision: "reject",
    matchType: "unsafe",
    needsReview: true,
    substituteReason: null,
    reason: "heuristic_reject_low_confidence",
  };
}

async function chooseProductCandidateWithLLM({ page, item, query, logger = console }) {
  const heuristics = await collectScrollableProductCandidates(page, query, item?.shoppingContext ?? null, {
    maxCandidates: 40,
    maxScrollRounds: 6,
  });
  if (!heuristics.length) return null;
  if (!openai) {
    const heuristicDecision = inferHeuristicDecision(heuristics[0], query, item?.shoppingContext ?? null);
    return {
      candidate: heuristicDecision.success ? heuristics[0] : null,
      fallbackCandidate: heuristics[0],
      refinedQuery: null,
      llmChoice: false,
      llmConfidence: null,
      llmReason: heuristicDecision.reason,
      decision: heuristicDecision.decision,
      matchType: heuristicDecision.matchType,
      needsReview: heuristicDecision.needsReview,
      substituteReason: heuristicDecision.substituteReason,
    };
  }

  const sourceIngredients = Array.isArray(item?.sourceIngredients)
    ? [...new Set(item.sourceIngredients.map((source) => String(source?.ingredientName ?? "").trim()).filter(Boolean))]
    : [];
  const sourceRecipes = Array.isArray(item?.sourceRecipes)
    ? [...new Set(item.sourceRecipes.map((title) => String(title ?? "").trim()).filter(Boolean))]
    : [];

  let latestRefinedQuery = null;
  let latestReason = null;
  const windowTrace = [];

  for (let offset = 0; offset < heuristics.length; offset += 10) {
    const windowCandidates = heuristics.slice(offset, offset + 10);
    const promptCandidates = windowCandidates.map((candidate, index) => ({
      index,
      title: candidate.title,
      rawLabel: candidate.rawLabel,
      score: candidate.score,
      cardText: candidate.cardText,
    }));

    try {
      const response = await openai.chat.completions.create({
        model: INSTACART_PRODUCT_MODEL,
        temperature: 0,
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "instacart_product_choice",
            schema: {
              type: "object",
              additionalProperties: false,
              properties: {
                selectedIndex: { type: ["integer", "null"] },
                decision: { type: "string" },
                matchType: { type: "string" },
                needsReview: { type: "boolean" },
                substituteReason: { type: ["string", "null"] },
                confidence: { type: "number" },
                reason: { type: "string" },
                refinedQuery: { type: ["string", "null"] },
              },
              required: ["selectedIndex", "decision", "matchType", "needsReview", "substituteReason", "confidence", "reason", "refinedQuery"],
            },
          },
        },
        messages: [
          {
            role: "system",
            content: [
              "You choose the best Instacart search result for a grocery item.",
              "You are reviewing one window of 10 visible products at a time.",
              "Select the candidate that most closely matches the requested ingredient.",
              "Prefer the correct ingredient, not just something similar in the same category.",
              "Reject bundled, flavored, prepared, or obviously wrong products when a cleaner match exists.",
              "For fresh herbs or produce, never choose dried spices, seasoning bottles, jars, sauces, dressings, or canned alternatives unless the user explicitly asked for that form.",
              "For plain chicken, prefer breasts, thighs, cutlets, boneless or skinless packs over whole birds, rotisserie chickens, wings, nuggets, or breaded products.",
              "For plain shrimp, prefer raw or plain shrimp over rings, platters, cocktail trays, breaded shrimp, or party-style prepared products.",
              "If every candidate in this 10-product window is bad, return reject with selectedIndex null and, if helpful, a refinedQuery.",
              "The caller may show you another 10-product window next. Do not force a bad match just because this window is limited.",
              "Use the provided shoppingContext as a strong steering signal for role, preferred forms, avoid forms, and neighboring recipe ingredients.",
              "Return one of: exact_match, substitute, reject.",
              "Use exact_match when the product is materially the same ingredient/form the recipe needs.",
              "Use substitute when the ingredient family and recipe role still work, and explain the substitute clearly.",
              "Use reject when no visible candidate is safe enough to add.",
              "matchType must be one of: exact, close_substitute, usable_substitute, unsafe.",
              "If no candidate is a good fit, return selectedIndex null and a refinedQuery that you would search next.",
              "The refinedQuery should be a short, concrete shopping search phrase, usually 1 to 4 words.",
              "Do not return null refinedQuery if you can think of a better search term.",
              "Return JSON only.",
            ].join(" "),
          },
          {
            role: "user",
            content: JSON.stringify({
              requestedItem: {
                originalName: item?.originalName ?? item?.name ?? query,
                normalizedQuery: query,
                quantity: item?.amount ?? 1,
                unit: item?.unit ?? "item",
                sourceIngredients,
                sourceRecipes,
                shoppingContext: item?.shoppingContext ?? null,
              },
              windowOffset: offset,
              candidates: promptCandidates,
            }, null, 2),
          },
        ],
      });

      const content = response.choices?.[0]?.message?.content ?? "{}";
      const parsed = JSON.parse(content);
      const selectedIndex = typeof parsed.selectedIndex === "number" ? parsed.selectedIndex : null;
      const chosen = selectedIndex != null ? windowCandidates[selectedIndex] ?? null : null;
      const refinedQuery = typeof parsed.refinedQuery === "string" && parsed.refinedQuery.trim() ? parsed.refinedQuery.trim() : null;
      latestRefinedQuery = latestRefinedQuery ?? refinedQuery;
      latestReason = parsed.reason ?? latestReason;

      if (chosen) {
        const guardedDecision = applyDescriptorDecisionGuard(chosen, query, item?.shoppingContext ?? null, {
          decision: parsed.decision ?? "exact_match",
          matchType: parsed.matchType ?? "exact",
          needsReview: Boolean(parsed.needsReview),
          substituteReason: parsed.substituteReason ?? null,
          reason: parsed.reason ?? "",
        });
        windowTrace.push({
          window: offset / 10 + 1,
          candidates: promptCandidates,
          selectedIndex,
          selectedCandidate: summarizeCandidate(chosen),
          decision: guardedDecision.decision ?? parsed.decision ?? "exact_match",
          matchType: guardedDecision.matchType ?? parsed.matchType ?? "exact",
          confidence: Number(parsed.confidence ?? 0),
          reason: guardedDecision.reason ?? parsed.reason ?? "",
          refinedQuery,
        });
        logger.log?.(`[instacart] LLM picked "${chosen.title}" for "${item?.originalName ?? item?.name ?? query}" (confidence=${parsed.confidence ?? 0}, reason=${parsed.reason ?? ""}, window=${offset / 10 + 1})`);
        if (guardedDecision.decision !== "reject") {
          return {
            candidate: chosen,
            fallbackCandidate: heuristics[0] ?? null,
            refinedQuery,
            llmChoice: true,
            llmConfidence: Number(parsed.confidence ?? 0),
            llmReason: guardedDecision.reason ?? parsed.reason ?? "",
            decision: guardedDecision.decision ?? "exact_match",
            matchType: guardedDecision.matchType ?? "exact",
            needsReview: Boolean(guardedDecision.needsReview),
            substituteReason: guardedDecision.substituteReason ?? null,
            selectionTrace: {
              totalCandidates: heuristics.length,
              windows: windowTrace,
            },
          };
        }
      } else {
        windowTrace.push({
          window: offset / 10 + 1,
          candidates: promptCandidates,
          selectedIndex: null,
          selectedCandidate: null,
          decision: parsed.decision ?? "reject",
          matchType: parsed.matchType ?? "unsafe",
          confidence: Number(parsed.confidence ?? 0),
          reason: parsed.reason ?? "",
          refinedQuery,
        });
      }

      logger.warn?.(`[instacart] LLM rejected candidate window ${offset / 10 + 1} for "${item?.originalName ?? item?.name ?? query}" (confidence=${parsed.confidence ?? 0}${refinedQuery ? `, refinedQuery="${refinedQuery}"` : ""})`);
    } catch (error) {
      logger.warn?.(`[instacart] LLM selection failed for "${item?.originalName ?? item?.name ?? query}" on window ${offset / 10 + 1}: ${error.message}`);
      const heuristicDecision = inferHeuristicDecision(windowCandidates[0], query, item?.shoppingContext ?? null);
      windowTrace.push({
        window: offset / 10 + 1,
        candidates: promptCandidates,
        selectedIndex: heuristicDecision.success ? 0 : null,
        selectedCandidate: heuristicDecision.success ? summarizeCandidate(windowCandidates[0]) : null,
        decision: heuristicDecision.decision,
        matchType: heuristicDecision.matchType,
        confidence: null,
        reason: heuristicDecision.reason,
        refinedQuery: null,
      });
      if (heuristicDecision.success) {
        return {
          candidate: windowCandidates[0],
          fallbackCandidate: heuristics[0] ?? null,
          refinedQuery: null,
          llmChoice: false,
          llmConfidence: null,
          llmReason: heuristicDecision.reason,
          decision: heuristicDecision.decision,
          matchType: heuristicDecision.matchType,
          needsReview: heuristicDecision.needsReview,
          substituteReason: heuristicDecision.substituteReason,
          selectionTrace: {
            totalCandidates: heuristics.length,
            windows: windowTrace,
          },
        };
      }
    }
  }

  return {
    candidate: null,
    fallbackCandidate: heuristics[0] ?? null,
    refinedQuery: latestRefinedQuery,
    llmChoice: false,
    llmConfidence: null,
    llmReason: latestReason ?? "llm_exhausted_candidate_windows",
    decision: "reject",
    matchType: "unsafe",
    needsReview: true,
    substituteReason: null,
    selectionTrace: {
      totalCandidates: heuristics.length,
      windows: windowTrace,
      topCandidates: heuristics.slice(0, 10).map(summarizeCandidate),
      reason: latestReason ?? "llm_exhausted_candidate_windows",
      refinedQuery: latestRefinedQuery,
    },
  };
}

async function readCartItemCount(page) {
  const cartLabels = await page.locator('[aria-label*="cart"], [aria-label*="Cart"]').evaluateAll((nodes) =>
    nodes
      .map((node) => node.getAttribute("aria-label") || node.textContent || "")
      .filter(Boolean)
  ).catch(() => []);

  const bodyText = await page.locator("body").innerText({ timeout: 3000 }).catch(() => "");
  const candidates = [...cartLabels, bodyText];

  for (const candidate of candidates) {
    const match = String(candidate).match(/items in cart:\s*(\d+)/i);
    if (match) return parseInt(match[1], 10);
  }

  return null;
}

async function waitForCartCountChange(page, beforeCount, minimumDelta = 1, timeoutMs = 5000) {
  if (typeof beforeCount !== "number") {
    return { changed: false, afterCount: null };
  }

  const start = Date.now();
  while ((Date.now() - start) < timeoutMs) {
    await page.waitForTimeout(450);
    const afterCount = await readCartItemCount(page);
    if (typeof afterCount === "number" && afterCount >= beforeCount + minimumDelta) {
      return { changed: true, afterCount };
    }
  }

  return { changed: false, afterCount: await readCartItemCount(page) };
}

async function captureActionVerificationSnapshot(locator) {
  try {
    const ariaLabel = await locator.getAttribute("aria-label").catch(() => "") ?? "";
    const text = await locator.innerText().catch(() => "") ?? "";
    const cardContext = await extractProductCardContext(locator);
    const nearbyText = cardContext.cardText || await extractNearbyCardText(locator);

    return {
      ariaLabel: normalizeSearchText(ariaLabel),
      text: normalizeSearchText(text),
      title: normalizeSearchText(cardContext.title),
      actionLabel: normalizeSearchText(cardContext.actionLabel || ariaLabel || text),
      cardText: normalizeSearchText(nearbyText),
    };
  } catch {
    return null;
  }
}

function didActionVerificationSnapshotChange(beforeSnapshot, afterSnapshot) {
  if (!beforeSnapshot || !afterSnapshot) return false;

  if (beforeSnapshot.actionLabel && afterSnapshot.actionLabel && beforeSnapshot.actionLabel !== afterSnapshot.actionLabel) {
    return true;
  }
  if (beforeSnapshot.text && afterSnapshot.text && beforeSnapshot.text !== afterSnapshot.text) {
    return true;
  }
  if (beforeSnapshot.ariaLabel && afterSnapshot.ariaLabel && beforeSnapshot.ariaLabel !== afterSnapshot.ariaLabel) {
    return true;
  }
  if (beforeSnapshot.cardText && afterSnapshot.cardText && beforeSnapshot.cardText !== afterSnapshot.cardText) {
    return true;
  }

  return false;
}

async function waitForActionContextChange(page, locator, beforeSnapshot, timeoutMs = 4500) {
  if (!beforeSnapshot) {
    return { changed: false, afterSnapshot: null };
  }

  const start = Date.now();
  while ((Date.now() - start) < timeoutMs) {
    await page.waitForTimeout(350);
    const afterSnapshot = await captureActionVerificationSnapshot(locator);
    if (didActionVerificationSnapshotChange(beforeSnapshot, afterSnapshot)) {
      return { changed: true, afterSnapshot };
    }
  }

  return {
    changed: false,
    afterSnapshot: await captureActionVerificationSnapshot(locator),
  };
}

function candidateIdentityScore(lhs, rhs) {
  if (!lhs || !rhs) return Number.NEGATIVE_INFINITY;
  let score = 0;
  if (lhs.productHref && rhs.productHref && lhs.productHref === rhs.productHref) score += 500;
  if (normalizeItemName(lhs.title) && normalizeItemName(lhs.title) === normalizeItemName(rhs.title)) score += 260;
  if (normalizeItemName(lhs.rawLabel) && normalizeItemName(lhs.rawLabel) === normalizeItemName(rhs.rawLabel)) score += 180;
  if (normalizeItemName(lhs.cardText) && normalizeItemName(lhs.cardText) === normalizeItemName(rhs.cardText)) score += 140;
  if (lhs.actionType && rhs.actionType && lhs.actionType === rhs.actionType) score += 20;
  return score;
}

async function resolveLiveCandidateAction(page, candidate, query, shoppingContext = null) {
  const actionButtons = page.locator(ACTIONABLE_PRODUCT_BUTTON_SELECTOR);
  const count = await actionButtons.count();
  let best = null;

  for (let i = 0; i < count; i += 1) {
    const button = actionButtons.nth(i);
    if (!(await button.isVisible().catch(() => false))) continue;
    const ariaLabel = await button.getAttribute("aria-label").catch(() => null);
    const text = await button.innerText().catch(() => "");
    const cardContext = await extractProductCardContext(button);
    const liveCandidate = {
      buttonIndex: i,
      title: cardContext.title || extractCandidateTitle(ariaLabel ?? text),
      rawLabel: (ariaLabel ?? text ?? "").trim(),
      cardText: cardContext.cardText || await extractNearbyCardText(button),
      productHref: cardContext.productHref || null,
      actionType: /choose/i.test(ariaLabel || text || cardContext.actionLabel || "") ? "choose" : "add",
      actionLabel: (ariaLabel ?? text ?? cardContext.actionLabel ?? "").trim(),
      score: Math.max(
        scoreProductLabel(cardContext.title || ariaLabel || text, query, shoppingContext),
        scoreProductLabel(cardContext.cardText || ariaLabel || text, query, shoppingContext),
      ),
      button,
    };

    const identityScore = candidateIdentityScore(candidate, liveCandidate);
    const combinedScore = identityScore + liveCandidate.score;
    if (!best || combinedScore > best.combinedScore) {
      best = { ...liveCandidate, combinedScore };
    }
  }

  return best;
}

async function clickCandidateAction(page, candidate, query, shoppingContext = null) {
  const liveCandidate = await resolveLiveCandidateAction(page, candidate, query, shoppingContext);
  if (liveCandidate?.button) {
    await liveCandidate.button.click({ timeout: 5000 });
    return { clicked: true, method: "visible_action", liveCandidate: summarizeCandidate(liveCandidate) };
  }

  if (candidate?.productHref) {
    await page.goto(candidate.productHref, { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(1800);
    const productAction = page.locator(ACTIONABLE_PRODUCT_BUTTON_SELECTOR).first();
    if (await productAction.count().catch(() => 0)) {
      await productAction.click({ timeout: 5000 });
      return { clicked: true, method: "product_page", liveCandidate: summarizeCandidate(candidate) };
    }
  }

  return { clicked: false, method: "not_found", liveCandidate: summarizeCandidate(candidate) };
}

async function completeChoiceFlowIfNeeded(page) {
  const followUpSelectors = [
    'button:has-text("Add")',
    'button[aria-label*="Add"]',
    'button:has-text("Continue")',
    'button:has-text("Done")',
    'button:has-text("Save")',
  ];

  for (const selector of followUpSelectors) {
    const clicked = await clickFirstVisible(page.locator(selector)).catch(() => false);
    if (clicked) {
      await page.waitForTimeout(700);
      return { completed: true, selector };
    }
  }

  return { completed: false, selector: null };
}

function isProbeItemRelevant(name) {
  const normalized = normalizeItemName(name);
  if (!normalized || normalized.length < 3) return false;
  return !PROBE_NOISE_TERMS.has(normalized);
}

function buildManualQueryVariants(query) {
  const normalized = normalizeItemName(query);
  const variants = [];
  const push = (...values) => {
    for (const value of values) {
      const normalizedValue = normalizeItemName(value);
      if (normalizedValue && normalizedValue !== normalized && !variants.includes(normalizedValue)) {
        variants.push(normalizedValue);
      }
    }
  };

  switch (normalized) {
    case "lime":
      push("fresh lime", "limes");
      break;
    case "cilantro":
      push("fresh cilantro", "cilantro bunch");
      break;
    case "parsley":
      push("fresh parsley", "parsley bunch");
      break;
    case "basil":
      push("fresh basil", "basil bunch");
      break;
    case "avocado":
      push("hass avocado", "organic avocado", "whole avocado", "avocados", "avocado bag", "bagged avocado");
      break;
    case "vegetables":
      push("mixed vegetables", "fresh vegetables");
      break;
    case "spices":
      push("seasoning", "all purpose seasoning");
      break;
    case "herbs":
      push("fresh herbs", "parsley", "cilantro");
      break;
    case "chicken":
      push("chicken breast", "chicken thighs");
      break;
    case "pepper":
      push("black pepper", "ground black pepper");
      break;
    case "bean":
      push("white beans", "canned beans");
      break;
    case "butterbeans":
      push("butter beans", "lima beans");
      break;
    case "cotija cheese":
      push("queso cotija", "cotija", "mexican cotija cheese");
      break;
    default:
      break;
  }

  return variants;
}

function buildQueryVariants(query, item) {
  const variants = [];
  const push = (value) => {
    const normalized = normalizeItemName(value);
    if (normalized && !variants.includes(normalized)) {
      variants.push(normalized);
    }
  };

  push(query);
  for (const preferred of item?.shoppingContext?.preferredForms ?? []) push(preferred);
  for (const alternate of item?.shoppingContext?.alternateQueries ?? []) push(alternate);
  for (const variant of buildManualQueryVariants(query)) push(variant);
  return variants;
}

function probeItemPriority(itemOrName) {
  const name = typeof itemOrName === "string" ? itemOrName : itemOrName?.name;
  const normalized = normalizeItemName(name);
  const wordCount = normalized.split(" ").filter(Boolean).length;
  const storeFitWeight = Number(itemOrName?.shoppingContext?.storeFitWeight ?? 1);
  const pantryPenalty = itemOrName?.shoppingContext?.isPantryStaple ? 30 : 0;
  const optionalPenalty = itemOrName?.shoppingContext?.isOptional ? 20 : 0;
  return ((wordCount * 24) + normalized.length) * storeFitWeight - pantryPenalty - optionalPenalty;
}

function cookiesToPlaywright(cookies) {
  return (cookies ?? [])
    .filter((cookie) => cookie?.name && cookie?.value && cookie?.domain)
    .map((cookie) => ({
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path ?? "/",
      expires: typeof cookie.expires === "number" ? cookie.expires : undefined,
      secure: Boolean(cookie.secure),
      httpOnly: Boolean(cookie.httpOnly),
      sameSite: cookie.sameSite,
    }));
}

async function clickFirstVisible(locator) {
  const count = await locator.count();
  for (let i = 0; i < count; i += 1) {
    const candidate = locator.nth(i);
    if (await candidate.isVisible().catch(() => false)) {
      await candidate.click({ timeout: 5000 });
      return true;
    }
  }
  return false;
}

async function tryAddButton(page, item, query, logger = console) {
  const bestCandidate = await chooseProductCandidateWithLLM({
    page,
    item,
    query,
    logger,
  });
  if (bestCandidate?.candidate && bestCandidate?.decision !== "reject") {
    const beforeCartCount = await readCartItemCount(page);
    const clickResult = await clickCandidateAction(page, bestCandidate.candidate, query, item?.shoppingContext ?? null);
    if (!clickResult.clicked) {
      return {
        success: false,
        matchedLabel: null,
        score: Number.NEGATIVE_INFINITY,
        llmChoice: Boolean(bestCandidate.llmChoice),
        llmConfidence: bestCandidate.llmConfidence ?? null,
        llmReason: bestCandidate.llmReason ?? "candidate_click_not_found",
        refinedQuery: bestCandidate.refinedQuery ?? null,
        decision: "reject",
        matchType: "unsafe",
        needsReview: true,
        substituteReason: null,
        selectionTrace: {
          ...(bestCandidate.selectionTrace ?? {}),
          click: clickResult,
        },
      };
    }

    let cartVerification = await waitForCartCountChange(page, beforeCartCount, 1, 3500);
    let choiceFlow = null;
    if (!cartVerification.changed && (bestCandidate.candidate.actionType === "choose" || clickResult.method === "product_page")) {
      choiceFlow = await completeChoiceFlowIfNeeded(page);
      if (choiceFlow.completed) {
        cartVerification = await waitForCartCountChange(page, beforeCartCount, 1, 3500);
      }
    }
    const verifiedSuccess = typeof beforeCartCount === "number" ? cartVerification.changed : true;
    if (!verifiedSuccess) {
      return {
        success: false,
        matchedLabel: null,
        score: Number.NEGATIVE_INFINITY,
        llmChoice: Boolean(bestCandidate.llmChoice),
        llmConfidence: bestCandidate.llmConfidence ?? null,
        llmReason: bestCandidate.llmReason ?? "cart_count_not_verified",
        refinedQuery: bestCandidate.refinedQuery ?? null,
        decision: "reject",
        matchType: "unsafe",
        needsReview: true,
        substituteReason: null,
        selectionTrace: {
          ...(bestCandidate.selectionTrace ?? {}),
          click: clickResult,
          choiceFlow,
          cartVerification: {
            beforeCount: beforeCartCount,
            afterCount: cartVerification.afterCount,
            changed: cartVerification.changed,
          },
        },
      };
    }

    return {
      success: true,
      matchedLabel: bestCandidate.candidate.title || bestCandidate.candidate.rawLabel,
      matchedProductHref: bestCandidate.candidate.productHref ?? clickResult.liveCandidate?.productHref ?? null,
      score: bestCandidate.candidate.score,
      llmChoice: Boolean(bestCandidate.llmChoice),
      llmConfidence: bestCandidate.llmConfidence ?? null,
      llmReason: bestCandidate.llmReason ?? null,
      refinedQuery: bestCandidate.refinedQuery ?? null,
      decision: bestCandidate.decision ?? "exact_match",
      matchType: bestCandidate.matchType ?? "exact",
      needsReview: Boolean(bestCandidate.needsReview),
      substituteReason: bestCandidate.substituteReason ?? null,
      selectionTrace: {
        ...(bestCandidate.selectionTrace ?? {}),
        click: clickResult,
        choiceFlow,
        cartVerification: {
          beforeCount: beforeCartCount,
          afterCount: cartVerification.afterCount,
          changed: cartVerification.changed,
        },
      },
    };
  }

  if (openai && bestCandidate?.refinedQuery) {
    return {
      success: false,
      matchedLabel: null,
      score: Number.NEGATIVE_INFINITY,
      llmChoice: false,
      llmConfidence: bestCandidate.llmConfidence ?? null,
      llmReason: bestCandidate.llmReason ?? null,
      refinedQuery: bestCandidate.refinedQuery,
      decision: bestCandidate.decision ?? "reject",
      matchType: bestCandidate.matchType ?? "unsafe",
      needsReview: Boolean(bestCandidate.needsReview),
      substituteReason: bestCandidate.substituteReason ?? null,
      selectionTrace: bestCandidate.selectionTrace ?? null,
    };
  }

  if (openai) {
    return {
      success: false,
      matchedLabel: null,
      score: Number.NEGATIVE_INFINITY,
      refinedQuery: bestCandidate?.refinedQuery ?? null,
      decision: bestCandidate?.decision ?? "reject",
      matchType: bestCandidate?.matchType ?? "unsafe",
      needsReview: Boolean(bestCandidate?.needsReview),
      substituteReason: bestCandidate?.substituteReason ?? null,
      llmReason: bestCandidate?.llmReason ?? null,
      selectionTrace: bestCandidate?.selectionTrace ?? null,
    };
  }

  const fallback = await chooseBestAddButton(page, query, item?.shoppingContext ?? null);
  if (fallback) {
    const fallbackDecision = inferHeuristicDecision(fallback, query, item?.shoppingContext ?? null);
    if (!fallbackDecision.success) {
      return {
        success: false,
        matchedLabel: null,
        score: Number.NEGATIVE_INFINITY,
        refinedQuery: null,
        decision: fallbackDecision.decision,
        matchType: fallbackDecision.matchType,
        needsReview: fallbackDecision.needsReview,
        substituteReason: fallbackDecision.substituteReason,
        selectionTrace: {
          fallbackCandidate: summarizeCandidate({
            ...fallback,
            actionType: "add",
            actionLabel: fallback.candidateLabel,
          }),
        },
      };
    }
    try {
      const beforeCartCount = await readCartItemCount(page);
      await fallback.button.click({ timeout: 5000 });
      const cartVerification = await waitForCartCountChange(page, beforeCartCount, 1, 5000);
      if (typeof beforeCartCount === "number" && !cartVerification.changed) {
        throw new Error("cart_count_not_verified");
      }
      return {
        success: true,
        matchedLabel: fallback.candidateLabel,
        matchedProductHref: fallback.productHref ?? null,
        score: fallback.score,
        refinedQuery: null,
        decision: fallbackDecision.decision,
        matchType: fallbackDecision.matchType,
        needsReview: fallbackDecision.needsReview,
        substituteReason: fallbackDecision.substituteReason,
        selectionTrace: {
          fallbackCandidate: summarizeCandidate({
            ...fallback,
            actionType: "add",
            actionLabel: fallback.candidateLabel,
          }),
          cartVerification: {
            beforeCount: beforeCartCount,
            afterCount: cartVerification.afterCount,
            changed: cartVerification.changed,
          },
        },
      };
    } catch {}
  }

  return {
    success: false,
    matchedLabel: null,
    score: Number.NEGATIVE_INFINITY,
    refinedQuery: null,
    decision: "reject",
    matchType: "unsafe",
    needsReview: true,
    substituteReason: null,
    selectionTrace: null,
  };
}

async function tryIncreaseQuantity(page, query, shoppingContext = null, preferredLabel = null) {
  const quantitySelectors = [
    'button[aria-label*="Increase quantity"]',
    'button[aria-label*="increase quantity"]',
    'button[aria-label*="Increase"]',
    'button[aria-label*="+"]',
    'button:has-text("+")',
  ];

  let best = null;
  const deadline = Date.now() + 5500;
  while (!best && Date.now() < deadline) {
    for (const selector of quantitySelectors) {
      try {
        const locator = page.locator(selector);
        const count = await locator.count();
        for (let i = 0; i < count; i += 1) {
          const candidate = locator.nth(i);
          if (!(await candidate.isVisible().catch(() => false))) continue;
          const ariaLabel = await candidate.getAttribute("aria-label").catch(() => "") ?? "";
          const buttonText = await candidate.innerText().catch(() => "") ?? "";
          const cardText = await extractNearbyCardText(candidate);
          const contextLabel = [ariaLabel, buttonText, cardText].filter(Boolean).join(" ");
          const score = Math.max(
            scoreProductLabel(contextLabel, query, shoppingContext),
            preferredLabel ? scoreProductLabel(contextLabel, preferredLabel, shoppingContext) : Number.NEGATIVE_INFINITY,
          );
          if (!Number.isFinite(score)) continue;
          if (isStrongCandidateMismatch(contextLabel, query, shoppingContext)) continue;
          if (!best || score > best.score) {
            best = {
              candidate,
              score,
              matchedLabel: contextLabel || selector,
            };
          }
        }
      } catch {}
    }
    if (!best) {
      await page.waitForTimeout(400);
    }
  }

  if (best) {
    try {
      const beforeCartCount = await readCartItemCount(page);
      const beforeSnapshot = await captureActionVerificationSnapshot(best.candidate);
      await best.candidate.click({ timeout: 5000 });
      const cartVerification = await waitForCartCountChange(page, beforeCartCount, 1, 4500);
      const actionVerification = cartVerification.changed
        ? { changed: false, afterSnapshot: beforeSnapshot }
        : await waitForActionContextChange(page, best.candidate, beforeSnapshot, 4500);
      const verifiedSuccess = (typeof beforeCartCount === "number" ? cartVerification.changed : false) || actionVerification.changed;
      if (!verifiedSuccess) {
        throw new Error("cart_count_not_verified");
      }
      return {
        success: true,
        matchedLabel: best.matchedLabel,
        score: best.score,
        verified: verifiedSuccess,
        verificationMode: cartVerification.changed ? "cart_count" : actionVerification.changed ? "action_context" : "none",
        beforeCount: beforeCartCount,
        afterCount: cartVerification.afterCount,
      };
    } catch {}
  }

  const fallback = await chooseBestAddButton(page, query, shoppingContext);
  if (fallback) {
    try {
      const beforeCartCount = await readCartItemCount(page);
      const beforeSnapshot = await captureActionVerificationSnapshot(fallback.button);
      await fallback.button.click({ timeout: 5000 });
      const cartVerification = await waitForCartCountChange(page, beforeCartCount, 1, 4500);
      const actionVerification = cartVerification.changed
        ? { changed: false, afterSnapshot: beforeSnapshot }
        : await waitForActionContextChange(page, fallback.button, beforeSnapshot, 4500);
      const verifiedSuccess = (typeof beforeCartCount === "number" ? cartVerification.changed : false) || actionVerification.changed;
      if (!verifiedSuccess) {
        throw new Error("cart_count_not_verified");
      }
      return {
        success: true,
        matchedLabel: fallback.candidateLabel,
        score: fallback.score,
        verified: verifiedSuccess,
        verificationMode: cartVerification.changed ? "cart_count" : actionVerification.changed ? "action_context" : "none",
        beforeCount: beforeCartCount,
        afterCount: cartVerification.afterCount,
      };
    } catch {}
  }

  return { success: false, matchedLabel: null, score: Number.NEGATIVE_INFINITY, verified: false, beforeCount: null, afterCount: null };
}

async function ensureLoggedIn(page) {
  const currentUrl = page.url();
  if (/login|signin|sign-in/i.test(currentUrl)) {
    throw new Error("Instacart session redirected to login");
  }
}

function splitLines(text) {
  return String(text ?? "")
    .split(/\r?\n+/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function normalizeSearchText(text) {
  return String(text ?? "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

function looksLikeStoreHeading(line, nextLine) {
  const current = String(line ?? "").trim();
  const next = String(nextLine ?? "").trim();
  if (!current || !next) return false;
  if (!/^(Delivery by|Pickup)/i.test(next)) return false;
  if (current.length > 42) return false;
  if (NOT_STORE_LINE_PATTERNS.some((pattern) => pattern.test(current))) return false;
  if (/^(Common Questions|Results for|Skip Navigation|Shop|Recipes|Lists|Browse aisles|Sort|Brands|Current price|Best seller|Great price|Out of stock|Add|Show similar|Carts)$/i.test(current)) {
    return false;
  }
  if (STORE_HINTS.some((hint) => hint.toLowerCase() === current.toLowerCase())) return true;
  return /^[A-Z0-9][A-Za-z0-9&'’.\-/ ]+$/.test(current);
}

function parseDistanceKm(lines) {
  for (const line of lines) {
    const match = String(line).match(/(\d+(?:\.\d+)?)\s*km/i);
    if (match) return parseFloat(match[1]);
  }
  return null;
}

function parseDeliveryText(lines) {
  return lines.find((line) => /^Delivery by|^Pickup/i.test(line)) ?? null;
}

function parseStoreSections(bodyText) {
  const lines = splitLines(bodyText);
  const sections = [];

  for (let i = 0; i < lines.length; i += 1) {
    const current = lines[i];
    const next = lines[i + 1];
    if (!looksLikeStoreHeading(current, next)) continue;

    const start = i;
    let j = i + 1;
    const sectionLines = [current];
    while (j < lines.length) {
      const line = lines[j];
      const lineNext = lines[j + 1];
      if (looksLikeStoreHeading(line, lineNext) || /^Common Questions$/i.test(line) || /^Carts$/i.test(line)) {
        break;
      }
      sectionLines.push(line);
      j += 1;
    }

    sections.push({
      storeName: current,
      lines: sectionLines.slice(1),
      text: sectionLines.join(" "),
      distanceKm: parseDistanceKm(sectionLines),
      deliveryText: parseDeliveryText(sectionLines),
      startIndex: start,
      endIndex: j,
    });

    i = j - 1;
  }

  return sections;
}

function scoreSectionForItem(section, itemName) {
  const query = normalizeItemName(itemName);
  const text = normalizeSearchText(section.text);
  if (!query) return { matched: false, exact: false };

  const exact = text.includes(query);
  const partial = query
    .split(" ")
    .filter((token) => token.length > 2)
    .some((token) => text.includes(token));

  return {
    matched: exact || partial,
    exact,
  };
}

async function discoverInstacartStoreOptions({ page, items, maxStores = 5 }) {
  const probeItems = [...new Map((items ?? []).map((item) => [normalizeItemName(item.name), item]))]
    .map(([, item]) => item)
    .filter((item) => isProbeItemRelevant(item.name))
    .sort((a, b) => probeItemPriority(b) - probeItemPriority(a))
    .slice(0, 8);

  const fallbackProbeItems = [...new Map((items ?? []).map((item) => [normalizeItemName(item.name), item]))]
    .map(([, item]) => item)
    .slice(0, 8);

  const storeStats = new Map();
  const itemsProbed = probeItems.length > 0 ? probeItems : fallbackProbeItems;

  for (const item of itemsProbed) {
    const query = normalizeItemName(item.name);
    const searchUrl = buildSearchUrl(query);
    await page.goto(searchUrl, { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(2200);

    const bodyText = await page.locator("body").innerText({ timeout: 10000 }).catch(() => "");
    const sections = parseStoreSections(bodyText);

    for (const section of sections) {
      const hit = scoreSectionForItem(section, query);
      if (!hit.matched) continue;

      const existing = storeStats.get(section.storeName) ?? {
        storeName: section.storeName,
        matchedCount: 0,
        totalProbes: 0,
        exactMatches: 0,
        distanceKm: section.distanceKm,
        deliveryText: section.deliveryText,
        sourceUrl: page.url(),
      };

      existing.totalProbes += 1;
      existing.matchedCount += 1;
      if (hit.exact) existing.exactMatches += 1;
      if (typeof section.distanceKm === "number") {
        existing.distanceKm = existing.distanceKm == null
          ? section.distanceKm
          : Math.min(existing.distanceKm, section.distanceKm);
      }
      if (!existing.deliveryText && section.deliveryText) {
        existing.deliveryText = section.deliveryText;
      }
      existing.sourceUrl = page.url();

      storeStats.set(section.storeName, existing);
    }
  }

  const ranked = [...storeStats.values()]
    .map((store) => {
      const coverageRatio = itemsProbed.length > 0 ? store.matchedCount / itemsProbed.length : 0;
      const distancePenalty = typeof store.distanceKm === "number" ? store.distanceKm * 3 : 0;
      const coverageScore = coverageRatio * 1000;
      const matchScore = store.matchedCount * 120 + store.exactMatches * 45;
      return {
        ...store,
        score: coverageScore + matchScore - distancePenalty,
        coverageRatio,
      };
    })
    .sort((a, b) =>
      (b.coverageRatio ?? 0) - (a.coverageRatio ?? 0) ||
      b.matchedCount - a.matchedCount ||
      b.exactMatches - a.exactMatches ||
      (a.distanceKm ?? Number.POSITIVE_INFINITY) - (b.distanceKm ?? Number.POSITIVE_INFINITY) ||
      b.score - a.score ||
      a.storeName.localeCompare(b.storeName)
    );

  return ranked.slice(0, maxStores);
}

async function openSelectedStore(page, storeOption, fallbackQuery) {
  if (!storeOption) return null;

  try {
    await page.goto(storeOption.sourceUrl, { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(1800);

    const storeLocator = page.getByText(storeOption.storeName, { exact: true }).first();
    if (await storeLocator.count().catch(() => 0)) {
      await storeLocator.click({ timeout: 5000 });
      await page.waitForTimeout(2200);
      return page.url();
    }
  } catch {}

  const baseUrl = storeOption.sourceUrl ? new URL(storeOption.sourceUrl) : new URL(buildSearchUrl(fallbackQuery));
  baseUrl.searchParams.set("k", fallbackQuery);
  await page.goto(baseUrl.toString(), { waitUntil: "domcontentloaded", timeout: 30000 });
  await page.waitForTimeout(2200);
  return page.url();
}

function buildStoreSearchUrl(storeUrl, query) {
  if (!storeUrl) return buildSearchUrl(query);
  const url = new URL(storeUrl);
  url.searchParams.set("k", query);
  return url.toString();
}

function normalizeStoreKey(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "");
}

function choosePreferredStore(storeOptions, preferredStore) {
  if (!preferredStore) return null;
  const preferredKey = normalizeStoreKey(preferredStore);
  if (!preferredKey) return null;
  return storeOptions.find((store) => normalizeStoreKey(store.storeName).includes(preferredKey) || preferredKey.includes(normalizeStoreKey(store.storeName))) ?? null;
}

export async function addItemsToInstacartCart({
  items,
  userId = null,
  accessToken = null,
  preferredStore = null,
  strictStore = false,
  headless = true,
  cdpUrl = null,
  providerSession = null,
  logger = console,
}) {
  const normalizedItems = (items ?? [])
    .map((item) => {
      if (typeof item === "string") {
        return {
          name: item,
          originalName: item,
          amount: 1,
          unit: "item",
          sourceIngredients: [],
          sourceRecipes: [],
          shoppingContext: null,
        };
      }
      return {
        name: item?.name ?? "",
        originalName: item?.originalName ?? item?.name ?? "",
        amount: Math.max(1, Math.round(item?.amount ?? 1)),
        unit: item?.unit ?? "item",
        sourceIngredients: Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [],
        sourceRecipes: Array.isArray(item?.sourceRecipes) ? item.sourceRecipes : [],
        shoppingContext: item?.shoppingContext ?? null,
      };
    })
    .filter((item) => item.name.trim().length > 0);

  if (!normalizedItems.length) {
    throw new Error("No items provided for Instacart cart add");
  }

  const session = providerSession ?? await loadProviderSession({
    userId,
    provider: "instacart",
    accessToken,
  }) ?? await loadPreferredProviderSession("instacart");

  if (!session?.cookies?.length) {
    throw new Error("No connected Instacart session found");
  }

  const browser = cdpUrl
    ? await chromium.connectOverCDP(cdpUrl)
    : await chromium.launch({
        headless,
        args: [
          "--disable-blink-features=AutomationControlled",
          "--no-sandbox",
        ],
      });

  const context = cdpUrl
    ? (browser.contexts()[0] ?? await browser.newContext({
        viewport: { width: 1280, height: 900 },
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
      }))
    : await browser.newContext({
        viewport: { width: 1280, height: 900 },
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
      });

  await context.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
  });

  await context.addCookies(cookiesToPlaywright(session.cookies));

  const existingPage = context.pages()[0];
  const page = existingPage ?? await context.newPage();
  const addedItems = [];
  const unresolvedItems = [];
  let storeOptions = [];
  let selectedStore = null;
  const storeUrlCache = new Map();
  const runId = [
    new Date().toISOString().replace(/[:.]/g, "-"),
    slugifyTracePart(userId, "anon"),
    slugifyTracePart(preferredStore, "instacart"),
  ].join("__");
  const runTrace = {
    runId,
    startedAt: nowISO(),
    userId: userId ?? null,
    preferredStore: preferredStore ?? null,
    strictStore: Boolean(strictStore),
    selectedStore: null,
    storeOptions: [],
    items: [],
    sessionSource: session.source,
  };

  try {
    logger.log?.(`[instacart] opening store discovery with ${normalizedItems.length} item(s)`);
    await page.goto("https://www.instacart.ca/store/s?k=watermelon", { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(2500);

    await ensureLoggedIn(page).catch(() => {});

    storeOptions = await discoverInstacartStoreOptions({
      page,
      items: normalizedItems,
      maxStores: 5,
    });

    const forcedStore = choosePreferredStore(storeOptions, preferredStore);
    selectedStore = forcedStore ?? storeOptions[0] ?? null;
    logger.log?.(`[instacart] store options: ${storeOptions.map((store) => `${store.storeName} (${store.matchedCount}/${store.totalProbes}, exact=${store.exactMatches})`).join(" | ") || "none"}`);
    if (preferredStore && !forcedStore) {
      logger.warn?.(`[instacart] preferred store "${preferredStore}" not found in ranked options; using top-ranked fallback`);
    }
    if (selectedStore) {
      logger.log?.(`[instacart] selected store: ${selectedStore.storeName}`);
    }
    runTrace.selectedStore = selectedStore?.storeName ?? null;
    runTrace.storeOptions = storeOptions.map((store) => ({
      storeName: store.storeName,
      score: Number(store.score ?? 0),
      matchedCount: store.matchedCount,
      totalProbes: store.totalProbes,
      exactMatches: store.exactMatches,
      coverageRatio: store.coverageRatio ?? null,
      distanceKm: store.distanceKm ?? null,
    }));
    const selectedStoreUrl = selectedStore
      ? await openSelectedStore(page, selectedStore, normalizeItemName(normalizedItems[0]?.name ?? "watermelon"))
      : null;
    if (selectedStore && selectedStoreUrl) {
      storeUrlCache.set(selectedStore.storeName, selectedStoreUrl);
    }

    for (const item of normalizedItems) {
      const query = normalizeItemName(item.name);
      const targetQuantity = Math.max(1, Math.ceil(Number(item.amount ?? 1)));
      const itemTrace = {
        requested: item.originalName ?? item.name,
        canonicalName: item.shoppingContext?.canonicalName ?? item.name,
        normalizedQuery: query,
        quantityRequested: targetQuantity,
        shoppingContext: item.shoppingContext ? {
          role: item.shoppingContext.role ?? null,
          exactness: item.shoppingContext.exactness ?? null,
          substitutionPolicy: item.shoppingContext.substitutionPolicy ?? null,
          preferredForms: item.shoppingContext.preferredForms ?? [],
          avoidForms: item.shoppingContext.avoidForms ?? [],
          requiredDescriptors: item.shoppingContext.requiredDescriptors ?? [],
          alternateQueries: item.shoppingContext.alternateQueries ?? [],
        } : null,
        attempts: [],
        quantityEvents: [],
        finalStatus: null,
      };
      logger.log?.(`[instacart] searching "${item.originalName ?? item.name}" -> "${query}" (qty=${targetQuantity})`);
      const queryVariants = buildQueryVariants(query, item);
      const storeAttempts = selectedStore
        ? (strictStore
          ? [selectedStore]
          : [selectedStore, ...storeOptions.filter((store) => store.storeName !== selectedStore.storeName)])
        : [null];
      let activeQuery = queryVariants[0];
      let added = null;
      let matchedStore = selectedStore?.storeName ?? null;

      for (const storeAttempt of storeAttempts) {
        let activeStoreUrl = null;
        if (storeAttempt) {
          activeStoreUrl = storeUrlCache.get(storeAttempt.storeName) ?? null;
          if (!activeStoreUrl) {
            activeStoreUrl = await openSelectedStore(page, storeAttempt, query);
            if (activeStoreUrl) {
              storeUrlCache.set(storeAttempt.storeName, activeStoreUrl);
            }
          }
        }

        let variantIndex = 0;
        while (variantIndex < queryVariants.length && !added?.success) {
          activeQuery = queryVariants[variantIndex];
          const searchUrl = buildStoreSearchUrl(activeStoreUrl, activeQuery);
          await page.goto(searchUrl, { waitUntil: "domcontentloaded", timeout: 30000 });
          await page.waitForTimeout(2500);

          added = await tryAddButton(page, item, activeQuery, logger);
          itemTrace.attempts.push({
            at: nowISO(),
            store: storeAttempt?.storeName ?? selectedStore?.storeName ?? null,
            query: activeQuery,
            searchUrl,
            success: Boolean(added.success),
            matchedLabel: added.matchedLabel ?? null,
            decision: added.decision ?? null,
            matchType: added.matchType ?? null,
            refinedQuery: added.refinedQuery ?? null,
            reason: added.llmReason ?? null,
            selectionTrace: added.selectionTrace ?? null,
          });
          if (!added.success && added.refinedQuery && normalizeItemName(added.refinedQuery) !== activeQuery) {
            const nextQuery = normalizeItemName(added.refinedQuery);
            logger.log?.(`[instacart] retrying "${item.originalName ?? item.name}" with refined query "${nextQuery}"`);
            if (!queryVariants.includes(nextQuery)) {
              queryVariants.splice(variantIndex + 1, 0, nextQuery);
            }
            variantIndex += 1;
            continue;
          }
          if (!added.success) {
            variantIndex += 1;
            continue;
          }
          matchedStore = storeAttempt?.storeName ?? matchedStore;
          break;
        }

        if (added?.success) break;
        if (storeAttempt && storeAttempts.length > 1) {
          logger.warn?.(`[instacart] no safe match for "${item.originalName ?? item.name}" at ${storeAttempt.storeName}; trying another store`);
        }
      }

      if (!added.success) {
        logger.warn?.(`[instacart] unresolved "${item.originalName ?? item.name}" (decision=${added.decision ?? "reject"}, refinedQuery=${added.refinedQuery ?? "none"})`);
        const unresolved = {
          requested: item.originalName ?? item.name,
          normalizedQuery: query,
          quantityRequested: targetQuantity,
          quantityAdded: 0,
          quantity: item.amount,
          status: "unresolved",
          decision: added.decision ?? "reject",
          matchType: added.matchType ?? "unsafe",
          needsReview: Boolean(added.needsReview ?? true),
          reason: added.llmReason ?? null,
          substituteReason: added.substituteReason ?? null,
          refinedQuery: added.refinedQuery ?? null,
          matchedStore,
          trace: itemTrace,
        };
        itemTrace.finalStatus = {
          status: "unresolved",
          matchedStore,
          decision: added.decision ?? "reject",
          matchType: added.matchType ?? "unsafe",
        };
        runTrace.items.push(itemTrace);
        addedItems.push(unresolved);
        unresolvedItems.push(unresolved);
        await page.waitForTimeout(800);
        continue;
      }

      let quantityAdded = 1;
      await page.waitForTimeout(1400);
      while (quantityAdded < targetQuantity) {
        let increased = { success: false };
        for (let attempt = 0; attempt < 3; attempt += 1) {
          if (added.matchedProductHref) {
            await page.goto(added.matchedProductHref, { waitUntil: "domcontentloaded", timeout: 30000 });
            await page.waitForTimeout(1800);
          }
          increased = await tryIncreaseQuantity(page, query, item?.shoppingContext ?? null, added.matchedLabel ?? null);
          itemTrace.quantityEvents.push({
            at: nowISO(),
            attempt: attempt + 1,
            success: Boolean(increased.success),
            matchedLabel: increased.matchedLabel ?? null,
            beforeCount: increased.beforeCount ?? null,
            afterCount: increased.afterCount ?? null,
            verified: Boolean(increased.verified),
            verificationMode: increased.verificationMode ?? null,
          });
          if (increased.success) break;
          await page.waitForTimeout(700);
        }
        if (!increased.success) break;
        quantityAdded += 1;
        await page.waitForTimeout(700);
      }
      if (quantityAdded < targetQuantity) {
        logger.warn?.(`[instacart] quantity shortfall for "${item.name}": requested ${targetQuantity}, added ${quantityAdded}`);
      }

      addedItems.push({
        requested: item.originalName ?? item.name,
        normalizedQuery: query,
        matched: added.matchedLabel ?? item.name,
        quantityRequested: targetQuantity,
        quantityAdded,
        quantity: item.amount,
        status: (added.decision ?? "exact_match") === "substitute" ? "substituted" : "exact",
        score: added.score,
        shortfall: Math.max(0, targetQuantity - quantityAdded),
        llmChoice: added.llmChoice ?? false,
        llmConfidence: added.llmConfidence ?? null,
        llmReason: added.llmReason ?? null,
        refinedQuery: added.refinedQuery ?? null,
        matchedStore,
        decision: added.decision ?? "exact_match",
        matchType: added.matchType ?? "exact",
        needsReview: Boolean(added.needsReview),
        substituteReason: added.substituteReason ?? null,
        trace: itemTrace,
      });
      itemTrace.finalStatus = {
        status: (added.decision ?? "exact_match") === "substitute" ? "substituted" : "exact",
        matchedStore,
        decision: added.decision ?? "exact_match",
        matchType: added.matchType ?? "exact",
        quantityAdded,
        shortfall: Math.max(0, targetQuantity - quantityAdded),
      };
      runTrace.items.push(itemTrace);
      logger.log?.(`[instacart] added "${item.originalName ?? item.name}" -> matched "${added.matchedLabel ?? item.name}" @ ${matchedStore ?? "default store"} (decision=${added.decision ?? "exact_match"}, matchType=${added.matchType ?? "exact"}, score=${added.score}, qty=${quantityAdded}/${targetQuantity}, llm=${added.llmChoice ? "yes" : "no"})`);

      await page.waitForTimeout(1500);
    }

    await page.goto("https://www.instacart.ca/store/cart", { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(2500);
    logger.log?.(`[instacart] cart page ready: ${page.url()}`);
    runTrace.completedAt = nowISO();
    runTrace.cartUrl = page.url();
    runTrace.success = unresolvedItems.length === 0;
    runTrace.partialSuccess = addedItems.some((item) => item.status === "exact" || item.status === "substituted") && unresolvedItems.length > 0;
    const traceArtifact = await persistRunTrace(runTrace);

    return {
      success: unresolvedItems.length === 0,
      partialSuccess: addedItems.some((item) => item.status === "exact" || item.status === "substituted") && unresolvedItems.length > 0,
      cartUrl: page.url(),
      addedItems,
      unresolvedItems,
      screenshotUrl: null,
      sessionSource: session.source,
      storeOptions,
      selectedStore,
      runId,
      traceArtifact,
    };
  } catch (error) {
    logger.error?.(`[instacart] batch add failed: ${error.message}`);
    runTrace.completedAt = nowISO();
    runTrace.success = false;
    runTrace.error = error.message;
    runTrace.storeOptions = runTrace.storeOptions.length ? runTrace.storeOptions : storeOptions.map((store) => ({
      storeName: store.storeName,
      score: Number(store.score ?? 0),
      matchedCount: store.matchedCount,
      totalProbes: store.totalProbes,
      exactMatches: store.exactMatches,
      coverageRatio: store.coverageRatio ?? null,
      distanceKm: store.distanceKm ?? null,
    }));
    const traceArtifact = await persistRunTrace(runTrace);
    return {
      success: false,
      error: error.message,
      addedItems,
      unresolvedItems,
      cartUrl: page.url(),
      sessionSource: session.source,
      storeOptions,
      selectedStore,
      runId,
      traceArtifact,
    };
  } finally {
    await browser.close().catch(() => {});
  }
}
