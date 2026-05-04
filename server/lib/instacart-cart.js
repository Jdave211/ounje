import { chromium } from "playwright";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createClient } from "@supabase/supabase-js";
import { loadProviderSession, loadPreferredProviderSession } from "./provider-session-store.js";
import { getInstacartRunLogTrace, persistInstacartRunLog } from "./instacart-run-logs.js";
import { createNotificationEvent } from "./notification-events.js";
import { buildPlaywrightLaunchOptions } from "./playwright-runtime.js";
import { installCaptchaHooksScript, maybeSolveCaptcha } from "./twocaptcha.js";
import { createLoggedOpenAI } from "./openai-usage-logger.js";

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const INSTACART_STORE_MODEL = process.env.INSTACART_STORE_MODEL ?? "gpt-5-mini";
const INSTACART_PRODUCT_MODEL = process.env.INSTACART_PRODUCT_MODEL ?? "gpt-5-mini";
const INSTACART_FAILURE_MODEL = process.env.INSTACART_FAILURE_MODEL ?? INSTACART_PRODUCT_MODEL;
const INSTACART_FINALIZER_MODEL = process.env.INSTACART_FINALIZER_MODEL ?? INSTACART_PRODUCT_MODEL;
const INITIAL_SELECTION_CONFIDENCE_CUTOFF = Number(process.env.INSTACART_INITIAL_CONFIDENCE_CUTOFF ?? 0.74);
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const openai = OPENAI_API_KEY ? createLoggedOpenAI({ apiKey: OPENAI_API_KEY, service: "instacart-cart" }) : null;

function chatCompletionTemperatureParams(model) {
  return String(model ?? "").trim() === "gpt-5-mini" ? {} : { temperature: 0 };
}

function getSupabase() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return null;
  }
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
}

async function appendRunBackedOrderEvent({
  groceryOrderID = null,
  userId = null,
  runId = null,
  event,
  cartUrl = null,
}) {
  const orderID = String(groceryOrderID ?? "").trim();
  const normalizedUserID = String(userId ?? "").trim();
  if (!orderID || !normalizedUserID || !event || typeof event !== "object") {
    return;
  }

  const supabase = getSupabase();
  if (!supabase) {
    return;
  }

  const { data: currentOrder, error: currentOrderError } = await supabase
    .from("grocery_orders")
    .select("id,status,step_log,provider_tracking_url")
    .eq("id", orderID)
    .eq("user_id", normalizedUserID)
    .maybeSingle();

  if (currentOrderError || !currentOrder?.id) {
    return;
  }

  const entry = {
    at: String(event.at ?? new Date().toISOString()).trim(),
    status: String(currentOrder.status ?? "building_cart").trim() || "building_cart",
    kind: String(event.kind ?? "update").trim() || "update",
    title: String(event.title ?? "Instacart update").trim() || "Instacart update",
    body: String(event.body ?? "").trim() || "There is a new Instacart update.",
    metadata: {
      ...(event.metadata && typeof event.metadata === "object" ? event.metadata : {}),
      runId: String(runId ?? "").trim() || null,
      cartUrl: String(cartUrl ?? "").trim() || null,
    },
  };

  await supabase
    .from("grocery_orders")
    .update({
      tracking_title: entry.title,
      tracking_detail: entry.body,
      last_tracked_at: entry.at,
      provider_tracking_url: String(cartUrl ?? "").trim() || currentOrder.provider_tracking_url || null,
      step_log: [
        ...(Array.isArray(currentOrder.step_log) ? currentOrder.step_log : []),
        entry,
      ],
    })
    .eq("id", currentOrder.id);
}

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

const BEVERAGE_LIKE_TERMS = [
  "beverage",
  "cocktail",
  "cordial",
  "drink",
  "juice",
  "kombucha",
  "lemonade",
  "mixer",
  "mocktail",
  "soda",
  "sparkling",
  "tea",
  "tonic",
];

const DRESSING_LIKE_TERMS = [
  "aioli",
  "caesar",
  "dip",
  "dressing",
  "mayo",
  "mayonnaise",
  "ranch",
  "remoulade",
  "slaw",
  "tartar",
  "vinaigrette",
];

const DRIED_OR_SPICE_TERMS = [
  "bouillon",
  "cube",
  "dried",
  "extract",
  "flakes",
  "granules",
  "ground",
  "mix",
  "paste",
  "powder",
  "rub",
  "seasoning",
  "spice",
];

const STOCK_AVAILABILITY_NEGATIVE_TERMS = [
  "currently unavailable",
  "not available",
  "out of stock",
  "sold out",
  "unavailable",
];

const SENSITIVE_EXTRA_DESCRIPTOR_TOKENS = new Set([
  "aioli",
  "barbecue",
  "bbq",
  "buffalo",
  "caesar",
  "chipotle",
  "cordial",
  "creamy",
  "dill",
  "garlic",
  "grinder",
  "habanero",
  "honey",
  "himalayan",
  "iodized",
  "jalapeno",
  "jalapeño",
  "kosher",
  "lemon",
  "lime",
  "mango",
  "marinade",
  "onion",
  "orange",
  "peach",
  "pineapple",
  "pink",
  "ranch",
  "roasted",
  "sea",
  "sesame",
  "smoked",
  "spicy",
  "sweet",
  "teriyaki",
  "vinaigrette",
]);

const MATERIAL_SOURCE_DESCRIPTOR_TOKENS = new Set([
  "anchovy",
  "beef",
  "chicken",
  "crab",
  "fish",
  "goat",
  "lamb",
  "lobster",
  "pork",
  "salmon",
  "seafood",
  "shrimp",
  "tuna",
  "turkey",
  "vegan",
  "veggie",
  "vegetable",
]);

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

const NON_SHOPPABLE_PREP_DESCRIPTOR_TOKENS = new Set([
  "baked",
  "bbq",
  "blackened",
  "braised",
  "breaded",
  "caramelized",
  "charred",
  "crisp",
  "crispy",
  "crunchy",
  "fried",
  "griddled",
  "grilled",
  "roasted",
  "rubbed",
  "sauteed",
  "sautéed",
  "seared",
  "smoked",
  "smoky",
  "toasted",
]);

const MAX_ITEM_ATTEMPTS = 3;

const NOT_STORE_LINE_PATTERNS = [
  /^\d+(?:\.\d+)?\s*km$/i,
  /^\d+(?:\.\d+)?\s*(?:min|mins|hr|hrs)$/i,
  /^by\s+\d/i,
  /^delivery$/i,
  /^pickup$/i,
  /^\$\d/,
  /^[\d\s.,/-]+$/,
];

const STORE_SECTION_MARKERS = [
  /^Delivery available$/i,
  /^Pickup available$/i,
  /^Groceries$/i,
  /^Butcher Shop$/i,
  /^Prepared Meals$/i,
  /^No markups$/i,
];

function isLikelyStoreName(storeName) {
  const trimmed = String(storeName ?? "").trim();
  if (!trimmed) return false;

  const lower = trimmed.toLowerCase();
  if (STORE_HINTS.some((hint) => hint.toLowerCase() === lower)) {
    return true;
  }

  const storeishTerms = [
    "store",
    "market",
    "mart",
    "grocery",
    "grocer",
    "grocers",
    "foods",
    "superstore",
    "supermarket",
    "drug",
    "pharmacy",
    "wholesale",
    "express",
    "centre",
    "center",
  ];
  if (storeishTerms.some((term) => lower.includes(term))) {
    return true;
  }

  const productishTerms = [
    "all purpose flour",
    "flour",
    "garlic",
    "onion",
    "chicken",
    "beef",
    "pork",
    "shrimp",
    "salmon",
    "tuna",
    "bread",
    "oil",
    "sauce",
    "salt",
    "pepper",
    "sugar",
    "honey",
    "rice",
    "pasta",
    "miso",
    "juice",
    "stock",
    "broth",
    "butter",
    "milk",
    "cheese",
    "cream",
    "yogurt",
    "lettuce",
    "cilantro",
    "parsley",
    "basil",
    "ginger",
    "cucumber",
    "potato",
    "tomato",
    "jalapeno",
    "chili",
    "paprika",
    "seasoning",
    "spice",
    "vanilla",
    "cinnamon",
  ];
  if (productishTerms.some((term) => lower.includes(term))) {
    return false;
  }

  if (["true", "false", "null", "none", "undefined"].includes(lower)) {
    return false;
  }

  if (lower.startsWith("delivery by") || lower.startsWith("pickup by") || lower.startsWith("current price") || lower.startsWith("add ")) {
    return false;
  }

  return /\p{L}/u.test(trimmed);
}

const ADDRESS_TOKEN_NORMALIZERS = new Map([
  ["st", "street"],
  ["street", "street"],
  ["rd", "road"],
  ["road", "road"],
  ["ave", "avenue"],
  ["avenue", "avenue"],
  ["blvd", "boulevard"],
  ["boulevard", "boulevard"],
  ["dr", "drive"],
  ["drive", "drive"],
  ["ln", "lane"],
  ["lane", "lane"],
  ["pkwy", "parkway"],
  ["parkway", "parkway"],
  ["ctr", "center"],
  ["centre", "center"],
  ["center", "center"],
  ["ct", "court"],
  ["court", "court"],
  ["cir", "circle"],
  ["circle", "circle"],
  ["trl", "trail"],
  ["trail", "trail"],
  ["ter", "terrace"],
  ["terrace", "terrace"],
]);

function extractStreetNumber(value) {
  const match = String(value ?? "").trim().match(/^(\d+[a-z]?)/i);
  return match?.[1]?.toLowerCase() ?? null;
}

function normalizeAddressTokens(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .split(/\s+/)
    .map((token) => ADDRESS_TOKEN_NORMALIZERS.get(token) ?? token)
    .filter(Boolean);
}

function addressesLikelyMatch(visibleAddress, deliveryAddress = null) {
  const expectedLine1 = String(deliveryAddress?.line1 ?? "").trim();
  const visible = String(visibleAddress ?? "").trim();
  if (!expectedLine1 || !visible) return true;

  const visibleStreetNumber = extractStreetNumber(visible);
  const expectedStreetNumber = extractStreetNumber(expectedLine1);
  if (visibleStreetNumber && expectedStreetNumber && visibleStreetNumber !== expectedStreetNumber) {
    return false;
  }

  const visibleTokens = normalizeAddressTokens(visible);
  const expectedTokens = normalizeAddressTokens(expectedLine1)
    .filter((token) => token.length > 2 && /^\d/.test(token) === false);
  if (!expectedTokens.length) {
    return visibleStreetNumber && expectedStreetNumber
      ? visibleStreetNumber === expectedStreetNumber
      : true;
  }

  const overlap = expectedTokens.filter((token) => visibleTokens.includes(token));
  if (overlap.length > 0) return true;

  return visibleStreetNumber && expectedStreetNumber
    ? visibleStreetNumber === expectedStreetNumber
    : false;
}

function normalizeAddressLine(value) {
  return normalizeText(String(value ?? "").toLowerCase().replace(/[^a-z0-9\s]/g, " "));
}

function addressSearchQuery(deliveryAddress = null) {
  const line1 = normalizeText(deliveryAddress?.line1);
  const city = normalizeText(deliveryAddress?.city);
  const region = normalizeText(deliveryAddress?.region);
  const postalCode = normalizeText(deliveryAddress?.postalCode);
  return [line1, city, region, postalCode].filter(Boolean).join(", ");
}

function scoreAddressCandidate(text, deliveryAddress = null) {
  const normalized = normalizeAddressLine(text);
  if (!normalized) return -1;

  const targetLine = normalizeAddressLine(deliveryAddress?.line1);
  const targetCity = normalizeAddressLine(deliveryAddress?.city);
  const targetRegion = normalizeAddressLine(deliveryAddress?.region);
  const targetPostalCode = normalizeAddressLine(deliveryAddress?.postalCode);
  const streetNumber = extractStreetNumber(deliveryAddress?.line1);
  const lineTokens = normalizeAddressTokens(targetLine).filter((token) => token.length > 2 && /^\d/.test(token) === false);

  let score = 0;
  if (targetLine && normalized.includes(targetLine)) score += 300;
  if (streetNumber && normalized.includes(streetNumber)) score += 150;
  if (targetCity && normalized.includes(targetCity)) score += 60;
  if (targetRegion && normalized.includes(targetRegion)) score += 20;
  if (targetPostalCode && normalized.includes(targetPostalCode)) score += 40;

  for (const token of lineTokens) {
    if (normalized.includes(token)) score += 35;
  }

  return score;
}

async function extractActiveDeliveryAddress(page) {
  const recommendationState = await extractCrossRetailerRecommendations(page, 1).catch(() => ({ activeAddress: null }));
  if (recommendationState?.activeAddress) {
    return recommendationState.activeAddress;
  }

  const addressButton = page.getByRole("button", { name: /current address:/i }).first();
  if (await addressButton.count().catch(() => 0)) {
    const label = await addressButton.getAttribute("aria-label").catch(() => null);
    const match = /current address:\s*(.+?)(?:\.|$)/i.exec(label ?? "");
    if (match?.[1]) {
      return normalizeText(match[1]);
    }
    return normalizeText(await addressButton.innerText().catch(() => ""));
  }

  return null;
}

async function openDeliveryAddressSelector(page, activeAddress = null) {
  const buttonCandidates = [
    page.getByRole("button", { name: /current address:/i }).first(),
    page.getByRole("button", { name: /select a new address/i }).first(),
  ];

  if (activeAddress) {
    buttonCandidates.push(page.getByRole("button", { name: new RegExp(activeAddress.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i") }).first());
  }

  for (const locator of buttonCandidates) {
    if (!(await locator.count().catch(() => 0))) continue;
    try {
      await locator.click({ timeout: 5000 });
      await page.waitForTimeout(1200);
      return true;
    } catch {}
  }

  return false;
}

async function findVisibleAddressInput(page) {
  const dialogRoot = page.locator('[data-dialog-ref], [role="dialog"], .__reakit-portal').filter({ visible: true }).last();
  const root = await dialogRoot.count().catch(() => 0) ? dialogRoot : page;
  const selectors = [
    'input[placeholder*="address" i]',
    'input[aria-label*="address" i]',
    'input[placeholder*="postal" i]',
    'input[aria-label*="postal" i]',
    'input[type="text"]',
  ];

  for (const selector of selectors) {
    const locator = root.locator(selector).filter({ visible: true }).first();
    if (await locator.count().catch(() => 0)) {
      const placeholder = normalizeText(await locator.getAttribute("placeholder").catch(() => ""));
      const ariaLabel = normalizeText(await locator.getAttribute("aria-label").catch(() => ""));
      if (placeholder === "Search products, stores, and recipes" || ariaLabel === "Search") {
        continue;
      }
      return locator;
    }
  }

  return null;
}

async function selectSavedDeliveryAddress(page, deliveryAddress) {
  const dialogRoot = page.locator('[data-dialog-ref], [role="dialog"], .__reakit-portal').filter({ visible: true }).last();
  const root = await dialogRoot.count().catch(() => 0) ? dialogRoot : page;
  const buttons = root.locator('[data-testid="address-button"]').filter({ visible: true });
  const count = await buttons.count().catch(() => 0);
  if (!count) return null;

  let bestIndex = -1;
  let bestScore = 0;
  let bestText = null;

  for (let index = 0; index < count; index += 1) {
    const button = buttons.nth(index);
    const text = normalizeText(await button.innerText().catch(() => ""));
    if (!text) continue;
    const isCurrent = await button.getAttribute("aria-current").catch(() => null);
    if (String(isCurrent).toLowerCase() === "true" && addressesLikelyMatch(text, deliveryAddress)) {
      return text;
    }

    const score = scoreAddressCandidate(text, deliveryAddress);
    if (score > bestScore) {
      bestScore = score;
      bestIndex = index;
      bestText = text;
    }
  }

  if (bestIndex < 0 || bestScore <= 0) return null;

  const target = buttons.nth(bestIndex);
  await target.scrollIntoViewIfNeeded().catch(() => {});
  await target.click({ timeout: 5000, force: true });
  await page.waitForTimeout(1800);
  return bestText;
}

async function selectDeliveryAddressSuggestion(page, deliveryAddress) {
  const query = addressSearchQuery(deliveryAddress);
  if (!query) return null;

  const targetLine = normalizeAddressLine(deliveryAddress?.line1);
  const streetNumber = extractStreetNumber(deliveryAddress?.line1);
  const city = normalizeAddressLine(deliveryAddress?.city);
  const postalCode = normalizeAddressLine(deliveryAddress?.postalCode);

  await page.waitForTimeout(1500);

  const suggestion = await page.evaluate(({ targetLine, streetNumber, city, postalCode }) => {
    const normalize = (value) => String(value ?? "").toLowerCase().replace(/[^a-z0-9\s]/g, " ").replace(/\s+/g, " ").trim();
    const isVisible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return rect.width > 40 && rect.height > 18 && rect.bottom > 0 && rect.top < window.innerHeight && style.visibility !== "hidden" && style.display !== "none";
    };
    const score = (text) => {
      const normalized = normalize(text);
      if (!normalized) return -1;
      let total = 0;
      if (targetLine && normalized.includes(targetLine)) total += 200;
      if (streetNumber && normalized.includes(streetNumber)) total += 80;
      if (city && normalized.includes(city)) total += 40;
      if (postalCode && normalized.includes(postalCode)) total += 30;
      return total;
    };

    const root = document.querySelector('[data-dialog-ref], [role="dialog"], .__reakit-portal') ?? document;
    const candidates = Array.from(root.querySelectorAll('[role="option"], li, button, a, div'))
      .filter(isVisible)
      .map((element) => {
        const text = String(element.textContent ?? "").replace(/\s+/g, " ").trim();
        return {
          text,
          score: score(text),
          top: element.getBoundingClientRect().top,
          element,
        };
      })
      .filter((candidate) => candidate.score > 0)
      .sort((left, right) => right.score - left.score || left.top - right.top);

    const best = candidates[0];
    if (!best?.element) return null;
    const clickable = best.element.closest('button, a, [role="option"], [role="button"], li') ?? best.element;
    clickable.click();
    return best.text;
  }, { targetLine, streetNumber, city, postalCode }).catch(() => null);

  return suggestion;
}

async function confirmDeliveryAddressChange(page) {
  const confirmButtons = [
    /save/i,
    /confirm/i,
    /deliver here/i,
    /use this address/i,
    /done/i,
    /continue/i,
  ];

  for (const pattern of confirmButtons) {
    const locator = page.getByRole("button", { name: pattern }).first();
    if (!(await locator.count().catch(() => 0))) continue;
    try {
      await locator.click({ timeout: 3000 });
      await page.waitForTimeout(1200);
      return true;
    } catch {}
  }

  return false;
}

async function ensureDeliveryAddress(page, deliveryAddress = null, logger = console) {
  if (!normalizeText(deliveryAddress?.line1)) {
    return {
      activeAddress: await extractActiveDeliveryAddress(page),
      addressMatches: true,
      changed: false,
      attempted: false,
    };
  }

  const initialAddress = await extractActiveDeliveryAddress(page);
  if (addressesLikelyMatch(initialAddress, deliveryAddress)) {
    return {
      activeAddress: initialAddress,
      addressMatches: true,
      changed: false,
      attempted: false,
    };
  }

  const opened = await openDeliveryAddressSelector(page, initialAddress);
  if (!opened) {
    return {
      activeAddress: initialAddress,
      addressMatches: false,
      changed: false,
      attempted: true,
    };
  }

  const selectedSavedAddress = await selectSavedDeliveryAddress(page, deliveryAddress);
  if (selectedSavedAddress) {
    await confirmDeliveryAddressChange(page);
    await page.waitForTimeout(1800);

    const updatedAddress = await extractActiveDeliveryAddress(page);
    if (addressesLikelyMatch(updatedAddress, deliveryAddress)) {
      return {
        activeAddress: updatedAddress,
        addressMatches: true,
        changed: normalizeText(updatedAddress) !== normalizeText(initialAddress),
        attempted: true,
        selectedSuggestion: selectedSavedAddress,
      };
    }

    logger.warn?.(`[instacart] saved address selection did not update active address: selected="${selectedSavedAddress}" active="${updatedAddress ?? "unknown"}"`);
  }

  const input = await findVisibleAddressInput(page);
  if (!input) {
    return {
      activeAddress: initialAddress,
      addressMatches: false,
      changed: false,
      attempted: true,
    };
  }

  const query = addressSearchQuery(deliveryAddress);
  try {
    await input.click({ timeout: 3000, force: true });
    await input.fill("");
    await input.fill(query);
  } catch (error) {
    logger.warn?.(`[instacart] failed to fill delivery address input: ${error.message}`);
    return {
      activeAddress: initialAddress,
      addressMatches: false,
      changed: false,
      attempted: true,
    };
  }

  const selectedSuggestion = await selectDeliveryAddressSuggestion(page, deliveryAddress);
  if (!selectedSuggestion) {
    try {
      await input.press("Enter");
    } catch {}
  }

  await confirmDeliveryAddressChange(page);
  await page.waitForTimeout(2500);

  const updatedAddress = await extractActiveDeliveryAddress(page);
  return {
    activeAddress: updatedAddress,
    addressMatches: addressesLikelyMatch(updatedAddress, deliveryAddress),
    changed: normalizeText(updatedAddress) !== normalizeText(initialAddress),
    attempted: true,
    selectedSuggestion,
  };
}

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
const INSTACART_TRACE_DIR = process.env.INSTACART_TRACE_DIR
  ?? path.join(os.homedir(), ".ounje", "instacart-runs");

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

function normalizeText(value) {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

function truncateText(value, maxLength = 180) {
  const normalized = normalizeText(value);
  if (!normalized) return "";
  if (normalized.length <= maxLength) return normalized;
  return `${normalized.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
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
    title: extractCandidateTitle(candidate.title, candidate.rawLabel, candidate.cardText) || candidate.title || candidate.rawLabel || null,
    rawLabel: candidate.rawLabel ?? null,
    score: Number.isFinite(candidate.score) ? Number(candidate.score.toFixed(2)) : null,
    actionType: candidate.actionType ?? null,
    actionLabel: candidate.actionLabel ?? null,
    productHref: candidate.productHref ?? null,
    cardText: candidate.cardText ?? null,
    imageURL: candidate.imageURL ?? null,
    priceText: candidate.priceText ?? null,
  };
}

function normalizeFailureReasonList(values) {
  if (!Array.isArray(values)) return [];
  const seen = new Set();
  const output = [];
  for (const value of values) {
    const normalized = truncateText(String(value ?? "").trim(), 220);
    if (!normalized) continue;
    const key = normalized.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    output.push(normalized);
  }
  return output;
}

function buildFailedItemReviewFallback({ item, query, added, attemptLimitHit = false }) {
  const fallbackSummary = truncateText(
    String(
      added?.llmReason
      ?? added?.substituteReason
      ?? (attemptLimitHit ? `Skipped after ${MAX_ITEM_ATTEMPTS} attempts.` : "Instacart could not verify a safe match.")
    ).trim(),
    220,
  ) || "Instacart could not verify a safe match.";
  const refinedQuery = String(added?.refinedQuery ?? "").trim() || null;
  return {
    verdict: refinedQuery && !attemptLimitHit ? "retry_recommended" : "mark_failed",
    shouldAccept: false,
    correctedStatus: null,
    summary: fallbackSummary,
    reasons: normalizeFailureReasonList([
      fallbackSummary,
      added?.substituteReason,
    ]),
    approachChange: refinedQuery
      ? `Try a tighter search query like "${refinedQuery}" before marking this item failed.`
      : "Tighten the product-form checks and only reject after an exact same-form candidate has been ruled out.",
    retryQuery: refinedQuery,
    confidence: null,
    acceptedCandidate: null,
    model: null,
  };
}

async function adjudicateFailedItemBeforeTracking({
  page,
  item,
  query,
  added,
  targetQuantity,
  attemptLimitHit = false,
  logger = console,
}) {
  const fallback = buildFailedItemReviewFallback({
    item,
    query,
    added,
    attemptLimitHit,
  });
  const selectionTrace = added?.selectionTrace ?? null;
  const selectedCandidate = selectionTrace?.selectedCandidate ?? null;
  if (!openai || !selectedCandidate) {
    return fallback;
  }

  const screenshotDataURL = page ? await capturePageScreenshotDataURL(page, { fullPage: false }) : null;
  const promptPayload = {
    requestedItem: {
      originalName: item?.originalName ?? item?.name ?? query,
      canonicalName: item?.shoppingContext?.canonicalName ?? item?.canonicalName ?? item?.name ?? null,
      normalizedQuery: query,
      quantityRequested: targetQuantity,
      originalAmount: item?.originalAmount ?? item?.amount ?? null,
      originalUnit: item?.originalUnit ?? item?.unit ?? null,
      sourceIngredients: Array.isArray(item?.sourceIngredients)
        ? item.sourceIngredients.map((entry) => String(entry?.ingredientName ?? "").trim()).filter(Boolean).slice(0, 10)
        : [],
      sourceRecipes: Array.isArray(item?.sourceRecipes)
        ? item.sourceRecipes.map((entry) => String(entry ?? "").trim()).filter(Boolean).slice(0, 6)
        : [],
      shoppingContext: item?.shoppingContext ?? null,
    },
    failedAttempt: {
      decision: added?.decision ?? null,
      matchType: added?.matchType ?? null,
      reason: added?.llmReason ?? null,
      substituteReason: added?.substituteReason ?? null,
      refinedQuery: added?.refinedQuery ?? null,
      attemptLimitHit,
    },
    selectedCandidate,
    fallbackCandidate: selectionTrace?.fallbackCandidate ?? null,
    topCandidates: Array.isArray(selectionTrace?.topCandidates) ? selectionTrace.topCandidates.slice(0, 3) : [],
    recentWindows: Array.isArray(selectionTrace?.windows) ? selectionTrace.windows.slice(-2) : [],
    verification: {
      click: selectionTrace?.click ?? null,
      cartVerification: selectionTrace?.cartVerification ?? null,
      actionVerification: selectionTrace?.actionVerification ?? null,
      cartPresenceVerification: selectionTrace?.cartPresenceVerification ?? null,
    },
  };

  try {
    const response = await openai.chat.completions.create({
      model: INSTACART_FAILURE_MODEL,
      ...chatCompletionTemperatureParams(INSTACART_FAILURE_MODEL),
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "instacart_failed_item_review",
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              verdict: { type: "string" },
              shouldAccept: { type: "boolean" },
              correctedStatus: { type: ["string", "null"] },
              summary: { type: "string" },
              reasons: {
                type: "array",
                items: { type: "string" },
              },
              approachChange: { type: "string" },
              retryQuery: { type: ["string", "null"] },
              confidence: { type: "number" },
            },
            required: [
              "verdict",
              "shouldAccept",
              "correctedStatus",
              "summary",
              "reasons",
              "approachChange",
              "retryQuery",
              "confidence",
            ],
          },
        },
      },
      messages: [
        {
          role: "system",
          content: [
            "You are the final Instacart item failure judge.",
            "You decide whether a supposedly failed item is actually acceptable, deserves one more targeted retry, or should be marked failed.",
            "Be concrete and strict about form. Fresh plantain is not plantain chips. Fresh cilantro is not a cilantro spice bottle.",
            "Be practical about obvious matches. Onion powder is onion powder. Parchment paper is parchment paper.",
            "If the selected visible product materially satisfies the requested Ounje ingredient and recipe context, set shouldAccept=true and verdict=accept_match.",
            "If the selected product is wrong enough that it should not pass, explain why in plain product terms and suggest one specific approach change.",
            "Use retry_recommended only when one short, better search query should still be tried before this becomes a failure.",
            "Use mark_failed when the product is genuinely wrong or the current evidence is too weak to trust it.",
            "Return concise, user-readable reasons. No internal jargon.",
            "Return JSON only.",
          ].join(" "),
        },
        {
          role: "user",
          content: [
            {
              type: "text",
              text: JSON.stringify(promptPayload, null, 2),
            },
            ...(screenshotDataURL ? [{ type: "image_url", image_url: { url: screenshotDataURL } }] : []),
          ],
        },
      ],
    });

    const content = response.choices?.[0]?.message?.content ?? "{}";
    const parsed = JSON.parse(content);
    const verdict = String(parsed?.verdict ?? "").trim().toLowerCase();
    const shouldAccept = Boolean(parsed?.shouldAccept);
    const correctedStatus = String(parsed?.correctedStatus ?? "").trim().toLowerCase() || null;
    const summary = truncateText(String(parsed?.summary ?? "").trim(), 220) || fallback.summary;
    const reasons = normalizeFailureReasonList(parsed?.reasons);
    const retryQuery = truncateText(String(parsed?.retryQuery ?? "").trim(), 80) || null;
    return {
      ...fallback,
      verdict: verdict || fallback.verdict,
      shouldAccept,
      correctedStatus,
      summary,
      reasons: reasons.length ? reasons : fallback.reasons,
      approachChange: truncateText(String(parsed?.approachChange ?? "").trim(), 220) || fallback.approachChange,
      retryQuery,
      confidence: Number.isFinite(Number(parsed?.confidence)) ? Number(parsed.confidence) : null,
      acceptedCandidate: shouldAccept ? summarizeCandidate(selectedCandidate) : null,
      model: INSTACART_FAILURE_MODEL,
    };
  } catch (error) {
    logger.warn?.(`[instacart] failed-item adjudication failed for "${item?.originalName ?? item?.name ?? query}": ${error.message}`);
    return {
      ...fallback,
      model: INSTACART_FAILURE_MODEL,
      error: error.message,
    };
  }
}

function summarizeStoreOptionForLLM(store, index) {
  const badgeValueScore = (Array.isArray(store.badges) ? store.badges : []).reduce((score, badge) => {
    const normalizedBadge = String(badge ?? "").toLowerCase();
    if (normalizedBadge.includes("no markups")) return score + 20;
    if (normalizedBadge.includes("low prices")) return score + 12;
    if (normalizedBadge.includes("lots of deals")) return score + 8;
    if (normalizedBadge.includes("loyalty savings")) return score + 6;
    return score;
  }, 0);
  return {
    index,
    storeName: store.storeName,
    score: Number.isFinite(Number(store.score ?? 0)) ? Number(store.score ?? 0) : 0,
    matchedCount: Number.isFinite(Number(store.matchedCount ?? 0)) ? Number(store.matchedCount ?? 0) : 0,
    totalProbes: Number.isFinite(Number(store.totalProbes ?? 0)) ? Number(store.totalProbes ?? 0) : 0,
    exactMatches: Number.isFinite(Number(store.exactMatches ?? 0)) ? Number(store.exactMatches ?? 0) : 0,
    coverageRatio: Number.isFinite(Number(store.coverageRatio ?? 0)) ? Number(store.coverageRatio ?? 0) : 0,
    distanceKm: Number.isFinite(Number(store.distanceKm ?? NaN)) ? Number(store.distanceKm) : null,
    recommendationRank: Number.isFinite(Number(store.recommendationRank ?? NaN)) ? Number(store.recommendationRank) : null,
    liquidityBias: storeLiquidityBias(store.storeName),
    badgeValueScore,
    badges: Array.isArray(store.badges) ? store.badges.slice(0, 6) : [],
    deliveryText: store.deliveryText ?? null,
  };
}

function summarizeStoreSelectionReason(selectedStore, storeOptions, cartSummary, selectedBy = "heuristic", preferredStore = null) {
  if (!selectedStore) return null;

  if (selectedBy === "preferred") {
    return truncateText(`Preferred store matched: ${selectedStore.storeName}.`, 150);
  }

  if (selectedBy === "llm") {
    const llmReason = String(selectedStore.reason ?? selectedStore.selectionReason ?? "").trim();
    if (llmReason) {
      return truncateText(llmReason, 180);
    }
  }

  const storeRank = storeOptions.findIndex((store) => store.storeName === selectedStore.storeName);
  const coverage = Number(selectedStore.coverageRatio ?? 0);
  const coverageText = Number.isFinite(coverage) && coverage > 0
    ? `${Math.round(coverage * 100)}% probe coverage`
    : `${Number(selectedStore.matchedCount ?? 0)}/${Number(selectedStore.totalProbes ?? 0) || 0} probe matches`;
  const families = Number(cartSummary?.uniqueFamilies ?? 0);
  const items = Number(cartSummary?.totalItems ?? 0);
  const pantry = Number(cartSummary?.pantryStaples ?? 0);
  const fresh = Number(cartSummary?.freshItems ?? 0);
  const breadth = storeLiquidityBias(selectedStore.storeName) >= 180
    ? "broad inventory"
    : storeLiquidityBias(selectedStore.storeName) >= 150
      ? "good breadth"
      : "targeted coverage";
  const valueSignal = (selectedStore.badges ?? []).some((badge) => /no markups|low prices|lots of deals|loyalty savings/i.test(String(badge ?? "")))
    ? "good value signals"
    : null;
  const preferredNote = preferredStore && normalizeStoreKey(preferredStore) !== normalizeStoreKey(selectedStore.storeName)
    ? `overrode preferred ${preferredStore}`
    : null;

  return truncateText([
    `${selectedStore.storeName} offers ${breadth} for a ${items}-item cart`,
    `${families} families, ${fresh} fresh items, ${pantry} pantry staples`,
    coverageText,
    valueSignal,
    storeRank >= 0 ? `ranked #${storeRank + 1}` : null,
    preferredNote,
  ].filter(Boolean).join(" • "), 180);
}

function buildCandidatePriceContext(candidates = []) {
  const priced = candidates
    .filter((candidate) => Number.isFinite(candidate?.priceValue) && Number(candidate.priceValue) > 0)
    .sort((lhs, rhs) => Number(lhs.priceValue) - Number(rhs.priceValue));

  const cheapest = priced[0]?.priceValue ?? null;
  const median = priced.length > 0
    ? priced[Math.floor(priced.length / 2)]?.priceValue ?? cheapest
    : null;
  const rankMap = new Map(priced.map((candidate, index) => [candidateKey(candidate), index + 1]));

  return candidates.map((candidate) => {
    const priceValue = Number.isFinite(candidate?.priceValue) ? Number(candidate.priceValue) : null;
    const priceRank = rankMap.get(candidateKey(candidate)) ?? null;
    const priceDeltaFromCheapest = cheapest != null && priceValue != null
      ? Number((priceValue - cheapest).toFixed(2))
      : null;
    const pricePosition = priceRank == null || priced.length <= 1
      ? null
      : priceRank === 1
        ? "lowest_visible_price"
        : priceRank <= Math.max(2, Math.ceil(priced.length / 3))
          ? "lower_priced_option"
          : median != null && priceValue != null && priceValue > median
            ? "higher_priced_option"
            : "mid_priced_option";

    return {
      priceRank,
      cheapestVisiblePrice: cheapest,
      priceDeltaFromCheapest,
      pricePosition,
    };
  });
}

function buildCartSummary(items = []) {
  const normalizedItems = (items ?? [])
    .map((item) => ({
      name: normalizeText(item?.name ?? item?.originalName ?? "").trim(),
      canonicalName: normalizeText(item?.shoppingContext?.canonicalName ?? item?.canonicalName ?? item?.name ?? "").trim(),
      amount: Number(item?.amount ?? 0),
      unit: normalizeText(item?.unit ?? "item"),
      shoppingContext: item?.shoppingContext ?? null,
    }))
    .filter((item) => item.name.length > 0);

  const families = new Map();
  for (const item of normalizedItems) {
    const familyKey = normalizeItemName(item.shoppingContext?.familyKey ?? item.canonicalName ?? item.name);
    const entry = families.get(familyKey) ?? {
      familyKey,
      names: new Set(),
      count: 0,
      amount: 0,
      pantryStaples: 0,
      optionalItems: 0,
      freshItems: 0,
      storeFitWeight: 0,
    };
    entry.names.add(item.canonicalName || item.name);
    entry.count += 1;
    entry.amount += Number(item.amount ?? 0) || 0;
    entry.storeFitWeight += Number(item.shoppingContext?.storeFitWeight ?? 1);
    if (item.shoppingContext?.isPantryStaple) entry.pantryStaples += 1;
    if (item.shoppingContext?.isOptional) entry.optionalItems += 1;
    if (item.shoppingContext?.role && !item.shoppingContext?.isPantryStaple) entry.freshItems += 1;
    families.set(familyKey, entry);
  }

  const probeItems = [...normalizedItems]
    .sort((left, right) => probeItemPriority(right) - probeItemPriority(left))
    .slice(0, 8)
    .map((item) => ({
      name: item.name,
      canonicalName: item.canonicalName || item.name,
      amount: item.amount,
      unit: item.unit,
      shoppingContext: item.shoppingContext ? {
        canonicalName: item.shoppingContext.canonicalName ?? null,
        role: item.shoppingContext.role ?? null,
        exactness: item.shoppingContext.exactness ?? null,
        preferredForms: item.shoppingContext.preferredForms ?? [],
        avoidForms: item.shoppingContext.avoidForms ?? [],
        requiredDescriptors: item.shoppingContext.requiredDescriptors ?? [],
        alternateQueries: item.shoppingContext.alternateQueries ?? [],
        searchQueries: item.shoppingContext.searchQueries ?? [],
        verificationTerms: item.shoppingContext.verificationTerms ?? [],
        shoppingForm: item.shoppingContext.shoppingForm ?? null,
        expectedPurchaseUnit: item.shoppingContext.expectedPurchaseUnit ?? null,
        substitutionPolicy: item.shoppingContext.substitutionPolicy ?? null,
        isPantryStaple: Boolean(item.shoppingContext.isPantryStaple),
        isOptional: Boolean(item.shoppingContext.isOptional),
        packageRule: item.shoppingContext.packageRule ?? null,
        storeFitWeight: Number(item.shoppingContext.storeFitWeight ?? 1),
      } : null,
    }));

  const topFamilies = [...families.values()]
    .map((entry) => ({
      familyKey: entry.familyKey,
      names: [...entry.names],
      count: entry.count,
      amount: entry.amount,
      pantryStaples: entry.pantryStaples,
      optionalItems: entry.optionalItems,
      freshItems: entry.freshItems,
      storeFitWeight: Number(entry.storeFitWeight.toFixed(2)),
    }))
    .sort((left, right) =>
      right.storeFitWeight - left.storeFitWeight ||
      right.count - left.count ||
      right.amount - left.amount ||
      left.familyKey.localeCompare(right.familyKey)
    )
    .slice(0, 10);

  return {
    totalItems: normalizedItems.length,
    uniqueFamilies: families.size,
    pantryStaples: normalizedItems.filter((item) => item.shoppingContext?.isPantryStaple).length,
    optionalItems: normalizedItems.filter((item) => item.shoppingContext?.isOptional).length,
    freshItems: normalizedItems.filter((item) => !item.shoppingContext?.isPantryStaple).length,
    probeItems,
    topFamilies,
    recommendedStoreCount: Math.min(3, Math.max(2, Math.ceil(Math.max(normalizedItems.length, 1) / 6))),
  };
}

async function persistRunTrace(trace, { accessToken = null } = {}) {
  let tracePath = null;

  try {
    await mkdir(INSTACART_TRACE_DIR, { recursive: true });
    tracePath = path.join(INSTACART_TRACE_DIR, `${trace.runId}.json`);
    await writeFile(tracePath, JSON.stringify(trace, null, 2), "utf8");
  } catch (error) {
    trace.persistenceError = trace.persistenceError ?? error.message;
    console.error?.(`[instacart] run trace artifact write failed for ${trace.runId}: ${error.message}`);
  }

  try {
    await persistInstacartRunLog(trace, { accessToken });
  } catch (error) {
    trace.persistenceError = trace.persistenceError ?? error.message;
    console.error?.(`[instacart] run log persistence failed for ${trace.runId}: ${error.message}`);
  }

  return tracePath;
}

function buildRunArtifactPath(runId, artifactName, extension = "png") {
  const normalizedRunID = String(runId ?? "").trim();
  const normalizedName = slugifyTracePart(artifactName, "artifact");
  const normalizedExtension = String(extension ?? "bin").replace(/[^a-z0-9]/gi, "").toLowerCase() || "bin";
  return path.join(INSTACART_TRACE_DIR, `${normalizedRunID}__${normalizedName}.${normalizedExtension}`);
}

async function persistRunImageArtifact({ runId, artifactName, dataURL, logger = console }) {
  const normalizedRunID = String(runId ?? "").trim();
  const normalizedDataURL = String(dataURL ?? "").trim();
  if (!normalizedRunID || !normalizedDataURL.startsWith("data:image/")) {
    return null;
  }

  const match = normalizedDataURL.match(/^data:(image\/[a-z0-9.+-]+);base64,(.+)$/i);
  if (!match) {
    return null;
  }

  const mimeType = String(match[1] ?? "").toLowerCase();
  const extension = mimeType.includes("jpeg") ? "jpg" : mimeType.split("/")[1] || "png";
  const artifactPath = buildRunArtifactPath(normalizedRunID, artifactName, extension);

  try {
    await mkdir(INSTACART_TRACE_DIR, { recursive: true });
    await writeFile(artifactPath, Buffer.from(match[2], "base64"));
    return {
      path: artifactPath,
      mimeType,
      artifactName: String(artifactName ?? "").trim() || "artifact",
      capturedAt: nowISO(),
    };
  } catch (error) {
    logger.warn?.(`[instacart] image artifact write failed for ${normalizedRunID}/${artifactName}: ${error.message}`);
    return null;
  }
}

async function readImageArtifactAsDataURL(artifactPath) {
  const normalizedPath = String(artifactPath ?? "").trim();
  if (!normalizedPath) {
    return null;
  }
  const extension = path.extname(normalizedPath).replace(".", "").toLowerCase();
  const mimeType = extension === "jpg" || extension === "jpeg"
    ? "image/jpeg"
    : extension === "webp"
      ? "image/webp"
      : "image/png";
  try {
    const buffer = await readFile(normalizedPath);
    if (!buffer?.length) {
      return null;
    }
    return `data:${mimeType};base64,${buffer.toString("base64")}`;
  } catch {
    return null;
  }
}

async function collectCartPageSnapshot(page) {
  const bodyText = await page.locator("body").innerText({ timeout: 10000 }).catch(() => "");
  const cartCount = await readCartItemCount(page).catch(() => null);
  const lineItems = await extractVisibleCartLineItems(page).catch(() => []);
  return {
    url: page.url(),
    cartCount,
    bodyText: String(bodyText ?? ""),
    bodyExcerpt: String(bodyText ?? "").slice(0, 12000),
    lineItems,
    lineItemsText: lineItems.join(" "),
  };
}

async function captureCartScreenshotDataURL(page) {
  try {
    const buffer = await page.screenshot({
      type: "png",
      fullPage: true,
    });
    return `data:image/png;base64,${buffer.toString("base64")}`;
  } catch {
    return null;
  }
}

async function capturePageScreenshotDataURL(page, { fullPage = false } = {}) {
  try {
    const buffer = await page.screenshot({
      type: "png",
      fullPage,
    });
    return `data:image/png;base64,${buffer.toString("base64")}`;
  } catch {
    return null;
  }
}

async function captureRunPageArtifact(page, runId, artifactName, logger = console, { fullPage = false } = {}) {
  const dataURL = await capturePageScreenshotDataURL(page, { fullPage });
  if (!dataURL) return null;
  return persistRunImageArtifact({
    runId,
    artifactName,
    dataURL,
    logger,
  });
}

function buildItemAttemptArtifactName({
  itemName,
  retryRound = 1,
  stage,
  attemptIndex = 1,
}) {
  const normalizedItemName = slugifyTracePart(itemName, "item");
  const normalizedStage = slugifyTracePart(stage, "stage");
  const normalizedRetryRound = Math.max(1, Number(retryRound) || 1);
  const normalizedAttemptIndex = Math.max(1, Number(attemptIndex) || 1);
  return `item-${normalizedItemName}-r${normalizedRetryRound}-a${normalizedAttemptIndex}-${normalizedStage}`;
}

async function verifyCartClearedWithScreenshot(page, cartSnapshot, cartScreenshotDataURL, logger = console) {
  const bodyText = String(cartSnapshot?.bodyText ?? cartSnapshot?.bodyExcerpt ?? "");
  const lineItemsText = Array.isArray(cartSnapshot?.lineItems) ? cartSnapshot.lineItems.join(" ") : String(cartSnapshot?.lineItemsText ?? "");
  const normalizedSnapshotText = normalizeItemName([bodyText, lineItemsText].filter(Boolean).join(" "));
  const looksLike404Shell = (
    normalizedSnapshotText.includes("404")
    || normalizedSnapshotText.includes("page not found")
    || normalizedSnapshotText.includes("sorry we couldn t find")
    || normalizedSnapshotText.includes("something went wrong")
  ) && !(Array.isArray(cartSnapshot?.lineItems) && cartSnapshot.lineItems.length > 0);
  const promptPayload = {
    cartUrl: cartSnapshot?.url ?? page.url(),
    cartCount: cartSnapshot?.cartCount ?? null,
    bodyExcerpt: String(bodyText).slice(0, 1200),
    lineItems: Array.isArray(cartSnapshot?.lineItems) ? cartSnapshot.lineItems.slice(0, 20) : [],
    lineItemsText: String(lineItemsText).slice(0, 1200),
  };

  const heuristic = {
    cleared:
      cartSnapshot?.cartCount === 0
      || (!String(bodyText).trim() && !(Array.isArray(cartSnapshot?.lineItems) && cartSnapshot.lineItems.length)),
    confidence: cartSnapshot?.cartCount === 0 ? 0.98 : 0.55,
    summary: cartSnapshot?.cartCount === 0
      ? "Cart count shows zero items."
      : looksLike404Shell
        ? "Instacart showed a 404/cart shell. This is not proof that the cart is empty."
        : "Cart snapshot does not clearly show lingering items.",
    topIssue: null,
    remainingItems: [],
    model: null,
  };

  if (!openai || !cartScreenshotDataURL) {
    return heuristic;
  }

  try {
    const response = await openai.chat.completions.create({
      model: INSTACART_FINALIZER_MODEL,
      ...chatCompletionTemperatureParams(INSTACART_FINALIZER_MODEL),
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "instacart_cart_clear_verifier",
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              cleared: { type: "boolean" },
              summary: { type: "string" },
              confidence: { type: "number" },
              topIssue: { type: ["string", "null"] },
              remainingItems: {
                type: "array",
                items: { type: "string" },
              },
            },
            required: ["cleared", "summary", "confidence", "topIssue", "remainingItems"],
          },
        },
      },
      messages: [
        {
          role: "system",
          content: [
            "You are verifying whether an Instacart selected-store cart is fully empty before shopping continues.",
            "The screenshot is the primary source of truth.",
            "If any product rows, item names, prices, quantity controls, or checkout totals are visible, the cart is not cleared.",
            "Only mark cleared=true when the screenshot clearly shows an empty cart state.",
            "A 404 page, generic error shell, or broken cart page is not proof that the cart is empty.",
            "Only mark cleared=true when the screenshot clearly shows an empty cart state or a zero-item cart.",
            "Return strict JSON only.",
          ].join(" "),
        },
        {
          role: "user",
          content: [
            "Verify whether this cart is fully cleared. Use the screenshot first and the text snapshot only as support.",
            JSON.stringify(promptPayload, null, 2),
            ...(cartScreenshotDataURL ? [{ type: "image_url", image_url: { url: cartScreenshotDataURL } }] : []),
          ],
        },
      ],
    });

    const parsed = JSON.parse(response.choices?.[0]?.message?.content ?? "{}");
    return {
      cleared: Boolean(parsed.cleared),
      confidence: Number.isFinite(Number(parsed.confidence)) ? Number(parsed.confidence) : heuristic.confidence,
      summary: String(parsed.summary ?? heuristic.summary).trim() || heuristic.summary,
      topIssue: parsed.topIssue ?? null,
      remainingItems: Array.isArray(parsed.remainingItems) ? parsed.remainingItems : [],
      model: INSTACART_FINALIZER_MODEL,
    };
  } catch (error) {
    logger.warn?.(`[instacart] cart-clear screenshot verification failed: ${error.message}`);
    return {
      ...heuristic,
      model: INSTACART_FINALIZER_MODEL,
      error: error.message,
    };
  }
}

async function adjudicateSelectedCandidateWithLLM({
  page,
  item,
  query,
  selectedCandidate,
  selectedIndex,
  promptCandidates = [],
  windowCandidates = [],
  windowIndex = 0,
  totalWindows = 1,
  previousAction = "select_candidate",
  logger = console,
}) {
  if (!selectedCandidate) {
    return {
      action: "continue_scrolling",
      approved: false,
      selectedIndex: null,
      candidate: null,
      confidence: null,
      reason: "no_selected_candidate",
      refinedQuery: null,
    };
  }

  if (!openai) {
    return {
      action: "approve_candidate",
      approved: true,
      selectedIndex,
      candidate: selectedCandidate,
      confidence: null,
      reason: "no_openai_candidate_warden",
      refinedQuery: null,
    };
  }

  const screenshotDataURL = await capturePageScreenshotDataURL(page, { fullPage: false });
  const bodyExcerpt = await page.locator("body").innerText({ timeout: 2500 }).catch(() => "");

  try {
    const response = await openai.chat.completions.create({
      model: INSTACART_PRODUCT_MODEL,
      ...chatCompletionTemperatureParams(INSTACART_PRODUCT_MODEL),
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "instacart_candidate_warden",
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              action: { type: "string" },
              approved: { type: "boolean" },
              selectedIndex: { type: ["integer", "null"] },
              confidence: { type: "number" },
              reason: { type: "string" },
              refinedQuery: { type: ["string", "null"] },
            },
            required: ["action", "approved", "selectedIndex", "confidence", "reason", "refinedQuery"],
          },
        },
      },
      messages: [
        {
          role: "system",
          content: [
            {
              type: "text",
              text: [
                "You are the final grocery-quality gate before add-to-cart.",
                "The screenshot is the primary source of truth. The structured candidate list is supporting context.",
                "Approve a candidate only when it is materially correct for the requested ingredient and recipe context.",
                "If the proposed candidate is wrong but a better visible candidate exists, swap to that visible candidate instead of approving the wrong one.",
                "Reject packaged, prepared, boxed, flavored, dried, premium, or novelty variants when the request is for a simple everyday ingredient unless the recipe context explicitly calls for that form.",
                "For whole produce, chips, crisps, flour, canned, frozen, boxed, pickled, juice, cordial, extract, seasoning, and sauce forms are wrong.",
                "For ripe plantain, plantain chips, crisps, flour, or green plantain are wrong. Prefer fresh whole plantain.",
                "For herbs like cilantro, dried spice bottles are wrong when the request is for fresh herb.",
                "Prefer the plain everyday option over premium or specialty variants when both are acceptable.",
                "Actions must be one of: approve_candidate, swap_candidate, continue_scrolling, refine_query, mark_unfound.",
                "If action is approve_candidate or swap_candidate, selectedIndex must point to the chosen visible candidate.",
                "If action is continue_scrolling, refine_query, or mark_unfound, selectedIndex must be null.",
                "Use refine_query only when a short concrete query would materially improve the results.",
                "Return strict JSON only.",
              ].join(" "),
            },
          ],
        },
        {
          role: "user",
          content: [
            {
              type: "text",
              text: JSON.stringify({
                requestedItem: {
                  originalName: item?.originalName ?? item?.name ?? query,
                  normalizedQuery: query,
                  quantity: item?.originalAmount ?? item?.amount ?? 1,
                  unit: item?.originalUnit ?? item?.unit ?? "item",
                  sourceIngredients: Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [],
                  sourceRecipes: Array.isArray(item?.sourceRecipes) ? item.sourceRecipes : [],
                  shoppingContext: item?.shoppingContext ?? null,
                },
                reviewState: {
                  previousAction,
                  currentWindow: windowIndex + 1,
                  totalWindows,
                  selectedIndex,
                },
                selectedCandidate: summarizeCandidate(selectedCandidate),
                visibleCandidates: promptCandidates,
                bodyExcerpt: String(bodyExcerpt ?? "").slice(0, 2000),
              }, null, 2),
            },
            ...(screenshotDataURL ? [{ type: "image_url", image_url: { url: screenshotDataURL } }] : []),
          ],
        },
      ],
    });

    const parsed = JSON.parse(response.choices?.[0]?.message?.content ?? "{}");
    const action = typeof parsed.action === "string" ? parsed.action.trim() : "continue_scrolling";
    const nextIndex = typeof parsed.selectedIndex === "number" ? parsed.selectedIndex : null;
    const candidate = nextIndex != null ? windowCandidates[nextIndex] ?? null : null;
    const approved = Boolean(parsed.approved) && (action === "approve_candidate" || action === "swap_candidate") && Boolean(candidate);
    return {
      action,
      approved,
      selectedIndex: nextIndex,
      candidate: approved ? candidate : null,
      confidence: Number.isFinite(Number(parsed.confidence)) ? Number(parsed.confidence) : null,
      reason: normalizeText(parsed.reason) || "candidate_warden_no_reason",
      refinedQuery: typeof parsed.refinedQuery === "string" && parsed.refinedQuery.trim()
        ? parsed.refinedQuery.trim()
        : null,
    };
  } catch (error) {
    logger.warn?.(`[instacart] candidate warden failed for "${item?.originalName ?? item?.name ?? query}": ${error.message}`);
    return {
      action: "approve_candidate",
      approved: true,
      selectedIndex,
      candidate: selectedCandidate,
      confidence: null,
      reason: "candidate_warden_failed_open",
      refinedQuery: null,
    };
  }
}

async function extractVisibleCartLineItems(page) {
  const selectors = [
    'button[aria-label*="Remove"]',
    'button[aria-label*="remove"]',
    'button[aria-label*="Delete"]',
    'button[aria-label*="delete"]',
    'button[aria-label*="Decrease quantity"]',
    'button[aria-label*="decrease quantity"]',
    'button[aria-label*="Decrement quantity"]',
    'button[aria-label*="decrement quantity"]',
    'button[aria-label*="Increase quantity"]',
    'button[aria-label*="increase quantity"]',
    'button:has-text("Remove")',
    'button:has-text("Delete")',
    'button:has-text("+")',
  ];
  const lineItems = new Set();

  for (const selector of selectors) {
    const locator = page.locator(selector);
    const count = await locator.count().catch(() => 0);
    for (let index = 0; index < count; index += 1) {
      const button = locator.nth(index);
      if (!(await button.isVisible().catch(() => false))) continue;
      const text = await button.evaluate((el) => {
        const clean = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
        let node = el;
        let cardNode = el;
        for (let depth = 0; depth < 10 && node; depth += 1) {
          node = node.parentElement;
          if (!node) break;
          const nodeText = clean(node.innerText || "");
          if (nodeText.length >= 12) {
            cardNode = node;
            break;
          }
        }
        const cardText = clean(cardNode?.innerText || "");
        return cardText ? cardText.slice(0, 600) : "";
      }).catch(() => "");
      if (text) {
        lineItems.add(normalizeText(text));
      }
    }
  }

  return [...lineItems].filter(Boolean);
}

async function pageLooksLikeInstacartCart(page) {
  const currentUrl = page.url();
  if (/\/store\/cart(?:[/?#]|$)/i.test(currentUrl)) return true;
  const cartSelectors = [
    'button[aria-label*="Remove"]',
    'button[aria-label*="remove"]',
    'button[aria-label*="Delete"]',
    'button[aria-label*="delete"]',
    'button[aria-label*="Decrease quantity"]',
    'button[aria-label*="decrease quantity"]',
    'button[aria-label*="Decrement quantity"]',
    'button[aria-label*="decrement quantity"]',
  ];
  for (const selector of cartSelectors) {
    const locator = page.locator(selector);
    const count = await locator.count().catch(() => 0);
    for (let index = 0; index < count; index += 1) {
      if (await locator.nth(index).isVisible().catch(() => false)) return true;
    }
  }
  const bodyText = normalizeSearchText(await page.locator("body").innerText({ timeout: 1500 }).catch(() => ""));
  if (!bodyText) return false;
  return (
    bodyText.includes("go to checkout")
    || bodyText.includes("add instructions")
    || bodyText.includes("checkout")
    || bodyText.includes("replace with best match")
    || bodyText.includes("shopping in")
  );
}

async function openInstacartCartFromCurrentContext(page) {
  if (await pageLooksLikeInstacartCart(page)) return true;

  const candidateLocators = [
    page.locator('button[aria-label*="View Cart" i][aria-controls], a[aria-label*="View Cart" i][aria-controls]'),
    page.locator('button[aria-label*="View Cart" i], a[aria-label*="View Cart" i]'),
    page.locator('a[href*="/store/cart"]'),
    page.locator('button[aria-label*="Cart"], button[aria-label*="cart"], a[aria-label*="Cart"], a[aria-label*="cart"]'),
    page.getByRole("button", { name: /cart/i }),
    page.getByRole("link", { name: /cart/i }),
  ];

  for (const locator of candidateLocators) {
    const clicked = await clickFirstVisible(locator).catch(() => false);
    if (!clicked) continue;
    await page.waitForTimeout(2200);
    if (await pageLooksLikeInstacartCart(page)) {
      return true;
    }
  }

  return false;
}

async function clearInstacartCart(page, logger = console, { preferCurrentPage = false } = {}) {
  const result = {
    attempted: true,
    beforeCount: null,
    afterCount: null,
    cleared: false,
    rounds: 0,
    clicks: [],
    error: null,
    critical: false,
    screenshotVerification: null,
  };

  async function hasVisibleRemovalControls() {
    const removalSelectors = [
      'button[aria-label*="Remove"]',
      'button[aria-label*="remove"]',
      'button[aria-label*="Delete"]',
      'button[aria-label*="delete"]',
      'button[aria-label*="Decrease quantity"]',
      'button[aria-label*="decrease quantity"]',
      'button[aria-label*="Decrement quantity"]',
      'button[aria-label*="decrement quantity"]',
      'button:has-text("Remove")',
      'button:has-text("Delete")',
    ];

    for (const selector of removalSelectors) {
      const locator = page.locator(selector);
      const count = await locator.count().catch(() => 0);
      for (let index = 0; index < count; index += 1) {
        if (await locator.nth(index).isVisible().catch(() => false)) {
          return true;
        }
      }
    }

    return false;
  }

  async function clickUntilRowClears(button, {
    selector,
    pass,
    round,
    maxClicks = 18,
  } = {}) {
    const rowHandle = await button.evaluateHandle((el) => {
      let node = el;
      for (let depth = 0; depth < 10 && node; depth += 1) {
        const text = String(node?.innerText ?? "").replace(/\s+/g, " ").trim();
        if (text.length >= 12) {
          return node;
        }
        node = node.parentElement;
      }
      return el.parentElement ?? el;
    }).catch(() => null);
    const rowElement = rowHandle?.asElement?.() ?? null;

    let drainClicks = 0;
    let lastKnownLabel = "";

    for (let attempt = 0; attempt < maxClicks; attempt += 1) {
      if (!(await button.isVisible().catch(() => false))) break;
      const ariaLabel = await button.getAttribute("aria-label").catch(() => "") ?? "";
      const innerText = await button.innerText().catch(() => "") ?? "";
      const label = normalizeText(ariaLabel || innerText || selector || "cart-control");
      lastKnownLabel = label || lastKnownLabel;

      await button.click({ timeout: 5000 });
      drainClicks += 1;
      result.clicks.push({
        pass,
        round,
        selector,
        label,
        drainClick: drainClicks,
      });
      await page.waitForTimeout(450);

      const rowStillVisible = rowElement
        ? await rowElement.evaluate((node) => {
            if (!(node instanceof HTMLElement)) return false;
            const style = window.getComputedStyle(node);
            const rect = node.getBoundingClientRect();
            return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
          }).catch(() => false)
        : false;

      if (!rowStillVisible) break;

      const rowText = rowElement
        ? await rowElement.evaluate((node) => String(node?.innerText ?? "").replace(/\s+/g, " ").trim()).catch(() => "")
        : "";
      if (!rowText) break;

      const nextCandidates = rowElement
        ? await rowElement.$$(
            'button[aria-label*="Decrease quantity"], button[aria-label*="decrease quantity"], button[aria-label*="Remove"], button[aria-label*="remove"], button[aria-label*="Delete"], button[aria-label*="delete"], button'
          ).catch(() => [])
        : [];

      let replacement = null;
      for (const candidate of nextCandidates) {
        if (!(await candidate.isVisible().catch(() => false))) continue;
        const candidateText = normalizeText(await candidate.innerText().catch(() => ""));
        const candidateAria = normalizeText(await candidate.getAttribute("aria-label").catch(() => ""));
        if (
          candidateAria.toLowerCase().includes("decrease quantity")
          || candidateAria.toLowerCase().includes("decrement quantity")
          || candidateAria.toLowerCase().includes("remove")
          || candidateAria.toLowerCase().includes("delete")
          || candidateText === "−"
          || candidateText === "-"
          || candidateText.toLowerCase() === "remove"
          || candidateText.toLowerCase() === "delete"
        ) {
          replacement = candidate;
          break;
        }
      }
      if (!replacement) break;
      button = replacement;
    }

    await rowHandle?.dispose?.().catch(() => {});
    return {
      clicked: drainClicks > 0,
      drainClicks,
      label: lastKnownLabel || null,
    };
  }

  try {
    const removalSelectors = [
      'button[aria-label*="Remove"]',
      'button[aria-label*="remove"]',
      'button[aria-label*="Delete"]',
      'button[aria-label*="delete"]',
      'button[aria-label*="Decrease quantity"]',
      'button[aria-label*="decrease quantity"]',
      'button[aria-label*="Decrement quantity"]',
      'button[aria-label*="decrement quantity"]',
      'button:has-text("Remove")',
      'button:has-text("Delete")',
    ];

    for (let pass = 0; pass < 3; pass += 1) {
      if (preferCurrentPage) {
        const openedFromCurrentContext = await openInstacartCartFromCurrentContext(page).catch(() => false);
        if (!openedFromCurrentContext) {
          if (pass === 0) {
            await page.goto("https://www.instacart.ca/store/cart", { waitUntil: "domcontentloaded", timeout: 30000 });
          } else {
            await page.reload({ waitUntil: "domcontentloaded", timeout: 30000 }).catch(async () => {
              await page.goto("https://www.instacart.ca/store/cart", { waitUntil: "domcontentloaded", timeout: 30000 });
            });
          }
        }
      } else if (pass === 0) {
        await page.goto("https://www.instacart.ca/store/cart", { waitUntil: "domcontentloaded", timeout: 30000 });
      } else {
        await page.reload({ waitUntil: "domcontentloaded", timeout: 30000 }).catch(async () => {
          await page.goto("https://www.instacart.ca/store/cart", { waitUntil: "domcontentloaded", timeout: 30000 });
        });
      }
      await page.waitForTimeout(2200);
      await maybeSolveCaptcha(page, { logger }).catch((error) => {
        logger.warn?.(`[instacart] captcha solver skipped or failed during cart clear: ${error.message}`);
      });

      if (pass === 0) {
        result.beforeCount = await readCartItemCount(page);
        if (typeof result.beforeCount === "number" && result.beforeCount === 0) {
          result.afterCount = 0;
          result.cleared = true;
          return result;
        }
      }

      for (let round = 0; round < 20; round += 1) {
        result.rounds = pass * 20 + round + 1;
        let clicked = false;

        for (const selector of removalSelectors) {
          const locator = page.locator(selector);
          const count = await locator.count().catch(() => 0);
          for (let index = 0; index < count; index += 1) {
            const button = locator.nth(index);
            if (!(await button.isVisible().catch(() => false))) continue;
            const drainResult = await clickUntilRowClears(button, {
              selector,
              pass: pass + 1,
              round: round + 1,
            }).catch(() => ({ clicked: false, drainClicks: 0, label: null }));
            clicked = drainResult.clicked;
            await page.waitForTimeout(drainResult.drainClicks > 1 ? 900 : 600);
            break;
          }
          if (clicked) break;
        }

        result.afterCount = await readCartItemCount(page);
        if (typeof result.afterCount === "number" && result.afterCount === 0) {
          result.cleared = true;
          return result;
        }
        if (!clicked) break;
        await page.waitForTimeout(700);
      }

      result.afterCount = await readCartItemCount(page);
      if (typeof result.afterCount === "number" && result.afterCount === 0) {
        result.cleared = true;
        return result;
      }
    }

    result.afterCount = await readCartItemCount(page);
    const cartSnapshot = await collectCartPageSnapshot(page).catch(() => null);
    const cartScreenshotDataURL = await captureCartScreenshotDataURL(page).catch(() => null);
    result.screenshotVerification = await verifyCartClearedWithScreenshot(page, cartSnapshot, cartScreenshotDataURL, logger).catch((error) => ({
      cleared: false,
      summary: "Cart screenshot verification failed.",
      confidence: 0,
      topIssue: error.message,
      remainingItems: [],
      model: INSTACART_FINALIZER_MODEL,
      error: error.message,
    }));
    const hasVisibleRemovals = await hasVisibleRemovalControls();
    const noVisibleLineItems = !(Array.isArray(cartSnapshot?.lineItems) && cartSnapshot.lineItems.length > 0);
    result.cleared = (
      result.afterCount === 0
      || (
        result.afterCount == null
        && Boolean(result.screenshotVerification?.cleared)
        && !hasVisibleRemovals
        && noVisibleLineItems
      )
    );
    if (!result.cleared) {
      result.critical = true;
      logger.warn?.(`[instacart] cart clear ended with ${result.afterCount ?? "unknown"} remaining item(s); screenshot=${result.screenshotVerification?.summary ?? "unverified"}`);
    }
    return result;
  } catch (error) {
    result.error = error.message;
    result.afterCount = await readCartItemCount(page).catch(() => null);
    result.critical = true;
    logger.warn?.(`[instacart] cart clear failed: ${error.message}`);
    return result;
  }
}

function summarizeFinalizerIssues(finalizer) {
  const sections = [
    Array.isArray(finalizer?.missingItems) ? finalizer.missingItems : [],
    Array.isArray(finalizer?.mismatchedItems) ? finalizer.mismatchedItems : [],
    Array.isArray(finalizer?.extraItems) ? finalizer.extraItems : [],
    Array.isArray(finalizer?.duplicateItems) ? finalizer.duplicateItems : [],
    Array.isArray(finalizer?.unresolvedItems) ? finalizer.unresolvedItems : [],
    Array.isArray(finalizer?.outOfStockItems) ? finalizer.outOfStockItems : [],
  ];

  return sections.flat().filter(Boolean).length;
}

function normalizeRunItemKey(value) {
  return normalizeItemName(value ?? "");
}

function findRunTraceItem(runTrace, name) {
  const normalized = normalizeRunItemKey(name);
  if (!normalized) return null;
  return (Array.isArray(runTrace?.items) ? runTrace.items : []).find((item) => (
    [
      item?.requested,
      item?.canonicalName,
      item?.normalizedQuery,
    ]
      .map((value) => normalizeRunItemKey(value))
      .some((value) => value && value === normalized)
  )) ?? null;
}

function latestSelectedCandidateForTraceItem(itemTrace) {
  const attempts = Array.isArray(itemTrace?.attempts) ? itemTrace.attempts.slice().reverse() : [];
  for (const attempt of attempts) {
    const selected = attempt?.selectionTrace?.selectedCandidate ?? attempt?.selectionTrace?.fallbackCandidate ?? null;
    if (selected) return selected;
  }
  return null;
}

function buildWardenFallbackSummary({ unresolvedItems, finalizer }) {
  const unresolvedCount = Array.isArray(unresolvedItems) ? unresolvedItems.length : 0;
  const finalizerIssues = summarizeFinalizerIssues(finalizer);
  return {
    status: unresolvedCount > 0 || finalizerIssues > 0 ? "needs_attention" : "ready",
    overallSummary: unresolvedCount > 0
      ? "Most mappings look usable, but some items still need another pass."
      : "Mappings look aligned with the requested cart.",
    mappingScore: unresolvedCount > 0 ? 84 : 96,
    retryRecommendation: unresolvedCount > 0 ? "retry_items_only" : "none",
    correctedItems: [],
    failedItems: Array.isArray(unresolvedItems)
      ? unresolvedItems.map((item) => ({
          name: String(item?.requested ?? item?.canonicalName ?? item?.name ?? "").trim(),
          actuallyFailed: true,
          reason: String(item?.reason ?? "Still unresolved after the shopping pass.").trim() || "Still unresolved after the shopping pass.",
          approachChange: "Retry only this item with a broader fallback query and candidate review.",
          retry: true,
        }))
      : [],
    notes: [],
  };
}

function normalizedWardenStatus(value) {
  return String(value ?? "").trim().toLowerCase();
}

function reviewerStatusCountsAsReady(value) {
  return ["ready", "success"].includes(normalizedWardenStatus(value));
}

function isFullyCorrectedRun({ runTrace, unresolvedItems, correctedItems }) {
  const totalItemCount = Array.isArray(runTrace?.items) ? runTrace.items.length : 0;
  if (!totalItemCount) return false;
  return (Array.isArray(unresolvedItems) ? unresolvedItems.length : 0) === 0
    && (Array.isArray(correctedItems) ? correctedItems.length : 0) >= totalItemCount;
}

function inferCartFinalizerHeuristic({ runTrace, cartSnapshot }) {
  const items = Array.isArray(runTrace?.items) ? runTrace.items : [];
  const bodyText = normalizeText(cartSnapshot?.bodyText ?? "").toLowerCase();
  const lineItemsText = normalizeText(Array.isArray(cartSnapshot?.lineItems) ? cartSnapshot.lineItems.join(" ") : cartSnapshot?.lineItemsText ?? "").toLowerCase();
  const cartText = [bodyText, lineItemsText].filter(Boolean).join(" ");
  const missingItems = [];
  const mismatchedItems = [];
  const extraItems = [];
  const duplicateItems = [];
  const unresolvedItems = [];
  const outOfStockItems = [];

  for (const item of items) {
    const requested = String(item?.requested ?? item?.canonicalName ?? item?.normalizedQuery ?? "").trim();
    const canonical = String(item?.canonicalName ?? item?.normalizedQuery ?? requested ?? "").trim();
    const normalizedRequested = normalizeItemName(requested);
    const normalizedCanonical = normalizeItemName(canonical);
    if (!normalizedRequested && !normalizedCanonical) continue;

    const shortfall = Number(item?.finalStatus?.shortfall ?? 0);
    const status = String(item?.finalStatus?.status ?? "").trim();
    const hasMention = [normalizedRequested, normalizedCanonical]
      .filter(Boolean)
      .some((term) => cartText.includes(term));

    if (status === "unresolved" || shortfall > 0) {
      unresolvedItems.push({
        name: requested || canonical,
        expectedQuantity: Number(item?.quantityRequested ?? 0) || null,
        reason: status === "unresolved" ? "unresolved during cart fill" : `shortfall of ${shortfall}`,
      });
      if (!hasMention) {
        missingItems.push({
          name: requested || canonical,
          expectedQuantity: Number(item?.quantityRequested ?? 0) || null,
          reason: status === "unresolved" ? "not found in populated cart" : `only partially added (${shortfall} short)`,
        });
      }
      continue;
    }

    if (!hasMention) {
      mismatchedItems.push({
        name: requested || canonical,
        expectedQuantity: Number(item?.quantityRequested ?? 0) || null,
        observedQuantity: Number(item?.quantityAdded ?? 0) || null,
        reason: "cart snapshot did not clearly show the expected item",
      });
    }
  }

  const hasIssues = missingItems.length > 0 || mismatchedItems.length > 0 || duplicateItems.length > 0 || unresolvedItems.length > 0 || outOfStockItems.length > 0;
  const criticalIssueCount = missingItems.length + unresolvedItems.length + outOfStockItems.length;
  const totalItemCount = Math.max(1, items.length);
  const visibleCartLineItemCount = Array.isArray(cartSnapshot?.lineItems) ? cartSnapshot.lineItems.length : 0;
  const visibleCartCount = Number(cartSnapshot?.cartCount ?? 0);
  const effectiveVisibleCartCount = Math.max(visibleCartLineItemCount, visibleCartCount, 0);
  const broadCorruptionLikely = (
    (criticalIssueCount / totalItemCount) >= 0.7
    || (missingItems.length / totalItemCount) >= 0.6
    || duplicateItems.length >= 4
    || extraItems.length >= 4
    || (effectiveVisibleCartCount > 0 && effectiveVisibleCartCount >= (totalItemCount * 1.75))
  );
  const retryRecommendation = !hasIssues
    ? "none"
    : (broadCorruptionLikely ? "rerun_full_cart" : "retry_items_only");
  return {
    status: hasIssues ? "needs_attention" : "ready",
    summary: hasIssues
      ? "Cart snapshot suggests one or more items still need review."
      : "Cart snapshot looks aligned with the requested grocery set.",
    canCheckout: !hasIssues,
    confidence: hasIssues ? 0.61 : 0.9,
    cartCompletenessScore: hasIssues ? 68 : 96,
    topIssue: missingItems[0]?.reason ?? mismatchedItems[0]?.reason ?? duplicateItems[0]?.reason ?? unresolvedItems[0]?.reason ?? null,
    nextAction: hasIssues
      ? (retryRecommendation === "rerun_full_cart"
          ? "Run the cart again from the start after review."
          : "Retry only the flagged items before checkout.")
      : "Proceed to Instacart checkout when ready.",
    retryRecommendation,
    missingItems,
    mismatchedItems,
    extraItems,
    duplicateItems,
    unresolvedItems,
    outOfStockItems,
    notes: [
      `cartCount=${cartSnapshot?.cartCount ?? "unknown"}`,
      `bodyExcerpt=${String(cartSnapshot?.bodyExcerpt ?? "").slice(0, 240)}`,
      `lineItems=${Array.isArray(cartSnapshot?.lineItems) ? cartSnapshot.lineItems.length : 0}`,
    ],
  };
}

async function finalizeInstacartCartRun({ page, runTrace, addedItems, unresolvedItems, cartSummary = null, logger = console }) {
  const cartSnapshot = await collectCartPageSnapshot(page);
  const cartScreenshotDataURL = await captureCartScreenshotDataURL(page);
  const cartScreenshotArtifact = await persistRunImageArtifact({
    runId: runTrace?.runId,
    artifactName: "finalizer-cart",
    dataURL: cartScreenshotDataURL,
    logger,
  });
  const intendedItems = Array.isArray(runTrace?.items) ? runTrace.items : [];
  const promptPayload = {
    runId: runTrace?.runId ?? null,
    userId: runTrace?.userId ?? null,
    deliveryAddress: runTrace?.deliveryAddress ?? null,
    selectedStore: runTrace?.selectedStore ?? null,
    preferredStore: runTrace?.preferredStore ?? null,
    strictStore: Boolean(runTrace?.strictStore),
    cartSummary: cartSummary ?? runTrace?.cartSummary ?? null,
    storeShortlist: Array.isArray(runTrace?.storeShortlist) ? runTrace.storeShortlist.slice(0, 3) : [],
    cartUrl: runTrace?.cartUrl ?? cartSnapshot.url,
    cartCount: cartSnapshot.cartCount,
    intendedItems: intendedItems.map((item) => ({
      requested: item?.requested ?? null,
      canonicalName: item?.canonicalName ?? null,
      normalizedQuery: item?.normalizedQuery ?? null,
      quantityRequested: item?.quantityRequested ?? null,
      finalStatus: item?.finalStatus ?? null,
      attempts: Array.isArray(item?.attempts) ? item.attempts.slice(-3) : [],
      quantityEvents: Array.isArray(item?.quantityEvents) ? item.quantityEvents.slice(-3) : [],
    })),
    addedItems: Array.isArray(addedItems) ? addedItems.slice(-50) : [],
    unresolvedItems: Array.isArray(unresolvedItems) ? unresolvedItems.slice(-50) : [],
    cartSnapshot: {
      url: cartSnapshot.url,
      cartCount: cartSnapshot.cartCount,
      bodyExcerpt: cartSnapshot.bodyExcerpt,
      lineItems: Array.isArray(cartSnapshot.lineItems) ? cartSnapshot.lineItems.slice(0, 20) : [],
    },
    cartScreenshotCaptured: Boolean(cartScreenshotDataURL),
    cartScreenshotArtifact: cartScreenshotArtifact?.path ?? null,
  };

  if (!openai) {
    return {
      ...inferCartFinalizerHeuristic({ runTrace, cartSnapshot }),
      model: null,
      cartSnapshot: {
        url: cartSnapshot.url,
        cartCount: cartSnapshot.cartCount,
        bodyExcerpt: cartSnapshot.bodyExcerpt,
        lineItems: Array.isArray(cartSnapshot.lineItems) ? cartSnapshot.lineItems.slice(0, 20) : [],
      },
      cartScreenshotCaptured: Boolean(cartScreenshotDataURL),
      cartScreenshotArtifact: cartScreenshotArtifact,
    };
  }

  try {
    const response = await openai.chat.completions.create({
      model: INSTACART_FINALIZER_MODEL,
      ...chatCompletionTemperatureParams(INSTACART_FINALIZER_MODEL),
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "instacart_cart_finalizer",
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              status: { type: "string" },
              summary: { type: "string" },
              canCheckout: { type: "boolean" },
              confidence: { type: "number" },
              cartCompletenessScore: { type: "number" },
              topIssue: { type: ["string", "null"] },
              nextAction: { type: "string" },
              retryRecommendation: { type: "string" },
              missingItems: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    expectedQuantity: { type: ["number", "null"] },
                    expectedUnit: { type: ["string", "null"] },
                    observedQuantity: { type: ["number", "null"] },
                    issue: { type: "string" },
                    severity: { type: "string" },
                  },
                  required: ["name", "expectedQuantity", "expectedUnit", "observedQuantity", "issue", "severity"],
                },
              },
              mismatchedItems: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    expectedQuantity: { type: ["number", "null"] },
                    observedQuantity: { type: ["number", "null"] },
                    expected: { type: ["string", "null"] },
                    observed: { type: ["string", "null"] },
                    issue: { type: "string" },
                    severity: { type: "string" },
                  },
                  required: ["name", "expectedQuantity", "observedQuantity", "expected", "observed", "issue", "severity"],
                },
              },
              extraItems: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    reason: { type: "string" },
                    severity: { type: "string" },
                  },
                  required: ["name", "reason", "severity"],
                },
              },
              duplicateItems: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    reason: { type: "string" },
                    severity: { type: "string" },
                  },
                  required: ["name", "reason", "severity"],
                },
              },
              unresolvedItems: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    reason: { type: "string" },
                    severity: { type: "string" },
                  },
                  required: ["name", "reason", "severity"],
                },
              },
              outOfStockItems: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    reason: { type: "string" },
                    severity: { type: "string" },
                  },
                  required: ["name", "reason", "severity"],
                },
              },
              notes: {
                type: "array",
                items: { type: "string" },
              },
            },
            required: [
              "status",
              "summary",
              "canCheckout",
              "confidence",
              "cartCompletenessScore",
              "topIssue",
              "nextAction",
              "retryRecommendation",
              "missingItems",
              "mismatchedItems",
              "extraItems",
              "duplicateItems",
              "unresolvedItems",
              "outOfStockItems",
              "notes",
            ],
          },
        },
      },
      messages: [
        {
          role: "system",
          content: [
            "You are the final cart quality checker for an Instacart automation run.",
            "The cart screenshot is the primary source of truth. Inspect it first and use the text snapshot only as support.",
            "Compare the intended grocery set against the current cart snapshot and flag anything missing, mismatched, duplicated, extra, out of stock, or unsafe.",
            "Be conservative and only mark a cart ready when the screenshot and run trace clearly line up.",
            "Use status values: ready, needs_attention, uncertain.",
            "Set retryRecommendation to exactly one of: none, retry_items_only, rerun_full_cart.",
            "Default to retry_items_only. A full-cart rerun should be rare.",
            "Use rerun_full_cart only when the cart is broadly corrupted: wrong or uncleared cart, obviously wrong store context, cart mostly empty relative to the request, or many duplicate/extra rows that show the cart state itself is bad.",
            "If the cart is mostly right and only a few items need another pass, use retry_items_only.",
            "If a matched product looks correct in the screenshot but the extracted label is generic or weak, do not force a full rerun because of the weak label alone.",
            "Return strict JSON only.",
          ].join(" "),
        },
        {
          role: "user",
          content: [
            {
              type: "text",
              text: [
                "Use the cart screenshot plus the structured trace below to verify the cart.",
                "Classify each intended item as present, missing, out_of_stock, mismatched, duplicate, or unresolved.",
                "If the screenshot shows a clear product row but the text proof is weak, trust the screenshot.",
                "Put visibly unavailable products into outOfStockItems when the screenshot makes that clear.",
                "",
                JSON.stringify(promptPayload, null, 2),
              ].join("\n"),
            },
            ...(cartScreenshotDataURL ? [{ type: "image_url", image_url: { url: cartScreenshotDataURL } }] : []),
          ],
        },
      ],
    });

    const content = response.choices?.[0]?.message?.content ?? "{}";
    const parsed = JSON.parse(content);
    return {
      ...parsed,
      model: INSTACART_FINALIZER_MODEL,
      cartSnapshot: {
        url: cartSnapshot.url,
        cartCount: cartSnapshot.cartCount,
        bodyExcerpt: cartSnapshot.bodyExcerpt,
      },
      cartScreenshotCaptured: Boolean(cartScreenshotDataURL),
      cartScreenshotArtifact: cartScreenshotArtifact,
    };
  } catch (error) {
    logger.warn?.(`[instacart] finalizer inference failed: ${error.message}`);
    return {
      ...inferCartFinalizerHeuristic({ runTrace, cartSnapshot }),
      model: INSTACART_FINALIZER_MODEL,
      error: error.message,
      cartSnapshot: {
        url: cartSnapshot.url,
        cartCount: cartSnapshot.cartCount,
        bodyExcerpt: cartSnapshot.bodyExcerpt,
      },
      cartScreenshotCaptured: Boolean(cartScreenshotDataURL),
      cartScreenshotArtifact: cartScreenshotArtifact,
    };
  }
}

async function adjudicateInstacartRunWithWarden({
  page,
  runTrace,
  addedItems,
  unresolvedItems,
  finalizer,
  logger = console,
  cartSnapshotOverride = null,
  cartScreenshotDataURLOverride = null,
}) {
  const fallback = buildWardenFallbackSummary({ unresolvedItems, finalizer });
  if (!openai) {
    return {
      ...fallback,
      model: null,
    };
  }

  const cartSnapshot = cartSnapshotOverride ?? (page ? await collectCartPageSnapshot(page) : null);
  const cartScreenshotDataURL = cartScreenshotDataURLOverride ?? (page ? await captureCartScreenshotDataURL(page) : null);
  const itemPayload = (Array.isArray(runTrace?.items) ? runTrace.items : []).map((item) => {
    const selectedCandidate = latestSelectedCandidateForTraceItem(item);
    return {
      requested: item?.requested ?? null,
      canonicalName: item?.canonicalName ?? null,
      normalizedQuery: item?.normalizedQuery ?? null,
      finalStatus: item?.finalStatus ?? null,
      selectedCandidate: selectedCandidate ? {
        title: selectedCandidate.title ?? null,
        rawLabel: selectedCandidate.rawLabel ?? null,
        priceText: selectedCandidate.priceText ?? null,
        cardText: selectedCandidate.cardText ?? null,
      } : null,
    };
  });

  const promptPayload = {
    runId: runTrace?.runId ?? null,
    selectedStore: runTrace?.selectedStore ?? null,
    itemCount: itemPayload.length,
    items: itemPayload,
    unresolvedItems: (Array.isArray(unresolvedItems) ? unresolvedItems : []).map((item) => ({
      name: item?.requested ?? item?.canonicalName ?? item?.name ?? null,
      reason: item?.reason ?? item?.substituteReason ?? null,
      refinedQuery: item?.refinedQuery ?? null,
    })),
    finalizer: finalizer ?? null,
    cartSnapshot: {
      cartCount: cartSnapshot?.cartCount ?? null,
      lineItems: Array.isArray(cartSnapshot?.lineItems) ? cartSnapshot.lineItems.slice(0, 30) : [],
      bodyExcerpt: cartSnapshot?.bodyExcerpt ?? null,
    },
  };

  try {
    const response = await openai.chat.completions.create({
      model: INSTACART_FINALIZER_MODEL,
      ...chatCompletionTemperatureParams(INSTACART_FINALIZER_MODEL),
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "instacart_mapping_warden",
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              status: { type: "string" },
              overallSummary: { type: "string" },
              mappingScore: { type: "number" },
              retryRecommendation: { type: "string" },
              correctedItems: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    matched: { type: ["string", "null"] },
                    correctedStatus: { type: "string" },
                    reason: { type: "string" },
                  },
                  required: ["name", "matched", "correctedStatus", "reason"],
                },
              },
              failedItems: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    actuallyFailed: { type: "boolean" },
                    reason: { type: "string" },
                    approachChange: { type: "string" },
                    retry: { type: "boolean" },
                  },
                  required: ["name", "actuallyFailed", "reason", "approachChange", "retry"],
                },
              },
              notes: {
                type: "array",
                items: { type: "string" },
              },
            },
            required: [
              "status",
              "overallSummary",
              "mappingScore",
              "retryRecommendation",
              "correctedItems",
              "failedItems",
              "notes",
            ],
          },
        },
      },
      messages: [
        {
          role: "system",
          content: [
            "You are the Instacart mapping warden.",
            "Your job is to review the completed shopping pass and decide whether supposedly failed items are actually wrong, or just labeled weakly.",
            "Use the cart screenshot as primary truth. Use the structured candidate, finalizer, and cart snapshot data as support.",
            "Treat exact or near-exact pantry and spice matches as correct unless the screenshot or cart rows clearly show a different product or a clearly wrong form.",
            "Do not over-reject salt, pepper, onion powder, paprika, curry powder, habanero pepper, or similar pantry items because of harmless descriptors or packaging language.",
            "If the mapping is effectively complete and the only remaining problem is a broken cart screenshot or noisy finalizer evidence, do not recommend a rerun; mark the run ready and keep retryRecommendation as none.",
            "If an item appears correctly mapped in the screenshot or the visible cart rows, mark it corrected instead of failed.",
            "Explain why true failures happened and what to change in the approach.",
            "Default retryRecommendation to retry_items_only. Use rerun_full_cart only for broad cart corruption.",
            "Return strict JSON only.",
          ].join(" "),
        },
        {
          role: "user",
          content: [
            {
              type: "text",
              text: [
                "Review the finished run. Correct false failures, summarize mapping quality, and identify only the items that truly need another retry.",
                JSON.stringify(promptPayload, null, 2),
              ].join("\n"),
            },
            ...(cartScreenshotDataURL ? [{ type: "image_url", image_url: { url: cartScreenshotDataURL } }] : []),
          ],
        },
      ],
    });

    const content = response.choices?.[0]?.message?.content ?? "{}";
    const parsed = JSON.parse(content);
    return {
      ...fallback,
      ...parsed,
      model: INSTACART_FINALIZER_MODEL,
    };
  } catch (error) {
    logger.warn?.(`[instacart] warden inference failed: ${error.message}`);
    return {
      ...fallback,
      model: INSTACART_FINALIZER_MODEL,
      error: error.message,
    };
  }
}

function containsAnyTerm(text, terms) {
  const haystack = ` ${String(text ?? "").toLowerCase()} `;
  return terms.some((term) => haystack.includes(` ${String(term).toLowerCase()} `) || haystack.includes(String(term).toLowerCase()));
}

function uniqueTerms(values, limit = 8) {
  return [...new Set((values ?? []).map((value) => normalizeItemName(value)).filter(Boolean))].slice(0, limit);
}

function extractContainedQuantityHint(productLabel) {
  const normalized = normalizeItemName(productLabel);
  if (!normalized) return null;

  const patterns = [
    /\b(\d+)\s*(?:ct|count|counts|pc|pcs|pack|packs|piece|pieces)\b/i,
    /\b(?:pack of|contains|with)\s*(\d+)\b/i,
    /\b(\d+)\s*(?:thighs?|breasts?|drumsticks?|wings?|fillets?|cutlets?|steaks?|shrimp|prawns|fish|salmon)\b/i,
  ];

  for (const pattern of patterns) {
    const match = normalized.match(pattern);
    if (match) return Number(match[1]);
  }

  return null;
}

function classifyQueryProfile(query) {
  const normalizedQuery = normalizeItemName(query);
  const tokens = tokenizeItemName(normalizedQuery);
  const tokenSet = new Set(tokens);
  const freshHerb = tokens.some((token) => FRESH_HERB_TERMS.has(token)) || FRESH_HERB_TERMS.has(normalizedQuery);
  const queryMentionsDrySpice = containsAnyTerm(normalizedQuery, DRIED_OR_SPICE_TERMS);
  const pantryOrSpiceLike = queryMentionsDrySpice || containsAnyTerm(normalizedQuery, PANTRY_OR_PREPARED_TERMS);
  const freshProduce = freshHerb ||
    (!pantryOrSpiceLike && (
      tokens.some((token) => FRESH_PRODUCE_TERMS.has(token)) ||
      FRESH_PRODUCE_TERMS.has(normalizedQuery)
    ));
  const genericChicken = normalizedQuery === "chicken";
  const genericShrimp = normalizedQuery === "shrimp";
  const genericFish = ["salmon", "fish", "cod", "tilapia", "trout", "tuna"].includes(normalizedQuery);

  return {
    normalizedQuery,
    tokens,
    tokenSet,
    freshHerb,
    freshProduce,
    genericChicken,
    genericShrimp,
    genericFish,
    queryMentionsBeverage: containsAnyTerm(normalizedQuery, BEVERAGE_LIKE_TERMS),
    queryMentionsDressing: containsAnyTerm(normalizedQuery, DRESSING_LIKE_TERMS),
    queryMentionsDrySpice,
  };
}

function normalizeSearchTerms(values, limit = 10) {
  return [...new Set((values ?? []).flatMap((value) => {
    const normalized = normalizeItemName(value);
    return normalized ? [normalized] : [];
  }))].slice(0, limit);
}

function buildVerificationTerms(item, query, candidate = null) {
  const shoppingContext = item?.shoppingContext ?? null;
  return normalizeSearchTerms([
    ...(shoppingContext?.verificationTerms ?? []),
    ...(shoppingContext?.searchQueries ?? []).slice(0, 4),
    ...(shoppingContext?.preferredForms ?? []).slice(0, 3),
    ...(shoppingContext?.alternateQueries ?? []).slice(0, 3),
    shoppingContext?.canonicalName,
    item?.name,
    item?.originalName,
    query,
    candidate?.title,
  ], 10);
}

function extractCandidateTitle(...labels) {
  const genericTitles = new Set([
    "instacart item",
    "current price",
    "best seller",
    "top pick",
    "store choice",
  ]);

  for (const label of labels.flat()) {
    let value = String(label ?? "").replace(/\u00a0/g, " ").trim();
    if (!value) continue;

    const lines = value
      .split(/\n/)
      .map((line) => line.replace(/\s+/g, " ").trim())
      .filter(Boolean);
    const searchValues = lines.length > 1 ? lines : [value];

    for (let candidate of searchValues) {
      candidate = candidate
        .replace(/^Add\s+\d+(?:\.\d+)?\s*(?:ct|item|items|kg|g|oz|lb|l|ml|pack|packs|bunch|bunches)?\s*/i, "")
        .replace(/^Add\s+/i, "")
        .replace(/^(best seller|top pick|store choice)\s*/i, "")
        .replace(/\b(current price|original price|sale price):\s*.*$/i, "")
        .replace(/\b(add|choose)\b.*$/i, "")
        .replace(/\s*\$[0-9][0-9,]*(?:\.[0-9]{2})?.*$/i, "")
        .replace(/\s+/g, " ")
        .trim();
      if (!candidate) continue;

      const normalized = normalizeText(candidate).toLowerCase();
      if (!normalized || genericTitles.has(normalized)) continue;
      if (!/[a-z]/i.test(candidate)) continue;

      return candidate.length > 62 ? candidate.slice(0, 62).trim() : candidate;
    }
  }

  return "";
}

function candidateFamilySignals(productLabel) {
  const normalizedLabel = normalizeItemName(productLabel);
  return {
    normalizedLabel,
    beverageLike: containsAnyTerm(normalizedLabel, BEVERAGE_LIKE_TERMS),
    dressingLike: containsAnyTerm(normalizedLabel, DRESSING_LIKE_TERMS),
    driedOrSpiceLike: containsAnyTerm(normalizedLabel, DRIED_OR_SPICE_TERMS),
    pantryOrPrepared: containsAnyTerm(normalizedLabel, PANTRY_OR_PREPARED_TERMS),
    unavailable: STOCK_AVAILABILITY_NEGATIVE_TERMS.some((term) => normalizedLabel.includes(term)),
  };
}

function candidatePlainnessBias(productLabel, query, shoppingContext = null) {
  const normalizedLabel = normalizeItemName(productLabel);
  const profile = classifyQueryProfile(query);
  const normalizedQuery = profile.normalizedQuery;
  if (!normalizedLabel || !normalizedQuery) return 0;

  const plainQuery = profile.freshProduce || profile.genericChicken || profile.genericShrimp || profile.genericFish;
  if (!plainQuery && !/\b(sweet potato|tomato|salmon|honey|avocado oil|olive oil)\b/i.test(normalizedQuery)) {
    return 0;
  }

  let score = 0;
  const premiumTerms = [
    "boxed",
    "box",
    "heirloom",
    "king",
    "premium",
    "gourmet",
    "specialty",
    "wild",
    "sockeye",
    "atlantic",
    "fancy",
    "artisan",
    "deluxe",
  ];
  if (containsAnyTerm(normalizedLabel, premiumTerms)) {
    score -= 30;
  }
  if (/\b(plain|regular|natural|whole|fresh)\b/i.test(normalizedLabel)) {
    score += 10;
  }
  if (profile.freshProduce && /\bheirloom\b/i.test(normalizedLabel) && !/\bheirloom\b/i.test(normalizedQuery)) {
    score -= 45;
  }
  if (/\b(box(?:ed)?|pack(?:ed)?|bundle|sampler|variety|mix)\b/i.test(normalizedLabel)) {
    score -= 18;
  }
  if (profile.genericFish && /\b(wild|sockeye|atlantic|king)\b/i.test(normalizedLabel)) {
    score -= 28;
  }
  if (profile.genericChicken && /\b(boneless|skinless|breaded|seasoned|marinated)\b/i.test(normalizedLabel)) {
    score -= 18;
  }
  if (profile.freshProduce && /\b(box|boxed)\b/i.test(normalizedLabel)) {
    score -= 40;
  }
  if (profile.freshProduce && /\b(organic)\b/i.test(normalizedLabel)) {
    score -= 8;
  }
  return score;
}

function collectQueryDescriptorTokens(query, shoppingContext = null) {
  const values = [
    query,
    ...(shoppingContext?.preferredForms ?? []),
    ...(shoppingContext?.alternateQueries ?? []),
    ...(shoppingContext?.requiredDescriptors ?? []),
  ];
  return new Set(
    values.flatMap((value) => tokenizeMeaningfulDescriptors(value)).filter(Boolean)
  );
}

function extractUnexpectedDescriptorTokens(candidate, query, shoppingContext = null) {
  const queryDescriptors = collectQueryDescriptorTokens(query, shoppingContext);
  if (!queryDescriptors.size) return [];
  const candidateDescriptors = tokenizeMeaningfulDescriptors([
    candidate?.title,
    candidate?.rawLabel,
    candidate?.cardText,
  ].filter(Boolean).join(" "));
  return candidateDescriptors.filter((token) => !queryDescriptors.has(token));
}

function summarizeFamilyMismatch(productLabel, query, shoppingContext = null) {
  const profile = classifyQueryProfile(query);
  const signals = candidateFamilySignals(productLabel);
  if (signals.unavailable) return "candidate_unavailable";
  if (!profile.queryMentionsBeverage && signals.beverageLike) return "candidate_is_beverage_family";
  if (!profile.queryMentionsDressing && signals.dressingLike) return "candidate_is_dressing_family";
  const freshQuery = (profile.freshHerb || profile.freshProduce) && !profile.queryMentionsDrySpice;
  if (freshQuery && signals.driedOrSpiceLike) return "fresh_item_mismatched_to_dry_or_spice";
  if (freshQuery && signals.pantryOrPrepared) return "fresh_item_mismatched_to_pantry_or_prepared";

  const minimumContainedQuantity = Number(shoppingContext?.minimumContainedQuantity ?? 0);
  if (minimumContainedQuantity > 1) {
    const quantityHint = extractContainedQuantityHint(productLabel);
    if (Number.isFinite(quantityHint) && quantityHint > 0 && quantityHint < minimumContainedQuantity) {
      return `package_too_small:${quantityHint}_under_${minimumContainedQuantity}`;
    }
  }

  const unexpectedDescriptors = extractUnexpectedDescriptorTokens(
    {
      title: productLabel,
      rawLabel: productLabel,
    },
    query,
    shoppingContext,
  ).filter((token) => SENSITIVE_EXTRA_DESCRIPTOR_TOKENS.has(token) || MATERIAL_SOURCE_DESCRIPTOR_TOKENS.has(token));
  if (unexpectedDescriptors.length) {
    return `unexpected_descriptors:${unexpectedDescriptors.join(",")}`;
  }

  return null;
}

function scoreProductLabel(productLabel, query, shoppingContext = null, candidatePosition = null) {
  const normalizedLabel = normalizeItemName(productLabel);
  const profile = classifyQueryProfile(query);
  const normalizedQuery = profile.normalizedQuery;
  if (!normalizedLabel || !normalizedQuery) return Number.NEGATIVE_INFINITY;
  const signals = candidateFamilySignals(normalizedLabel);

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
  if (signals.unavailable) score -= 260;
  if (!profile.queryMentionsBeverage && signals.beverageLike) score -= 280;
  if (!profile.queryMentionsDressing && signals.dressingLike) score -= 220;
  if ((profile.freshHerb || profile.freshProduce) && signals.driedOrSpiceLike) score -= 220;
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
  score += candidatePlainnessBias(normalizedLabel, query, shoppingContext);
  const numericPosition = Number(candidatePosition);
  if (Number.isFinite(numericPosition) && numericPosition >= 0) {
    const plainEverydayQuery = profile.freshProduce
      || profile.genericChicken
      || profile.genericShrimp
      || profile.genericFish
      || /\b(sweet potato|tomato|salmon|honey|avocado oil|olive oil|cucumber|lime|lemon|pepper|salt)\b/i.test(normalizedQuery);
    if (plainEverydayQuery) {
      if (numericPosition === 0) score += 34;
      else if (numericPosition === 1) score += 22;
      else if (numericPosition === 2) score += 12;
      else if (numericPosition === 3) score += 6;
      else if (numericPosition < 8) score += 2;
    } else if (numericPosition === 0) {
      score += 8;
    }
  }
  const preferredForms = uniqueTerms(shoppingContext?.preferredForms ?? [], 8);
  const avoidForms = uniqueTerms(shoppingContext?.avoidForms ?? [], 10);
  if (preferredForms.some((form) => form && normalizedLabel.includes(form))) score += 36;
  if (avoidForms.some((form) => form && normalizedLabel.includes(form))) score -= 180;
  const minimumContainedQuantity = Number(shoppingContext?.minimumContainedQuantity ?? 0);
  if (minimumContainedQuantity > 1) {
    const quantityHint = extractContainedQuantityHint(normalizedLabel) ?? extractContainedQuantityHint(productLabel);
    if (Number.isFinite(quantityHint) && quantityHint > 0) {
      if (quantityHint >= minimumContainedQuantity) {
        score += 80 + Math.min(24, quantityHint - minimumContainedQuantity);
      } else {
        score -= 180 + Math.min(50, (minimumContainedQuantity - quantityHint) * 10);
      }
    } else if (/\b(family pack|value pack|club pack|bulk|tray|multi pack)\b/i.test(normalizedLabel)) {
      score += 20;
    }
  }
  const unexpectedDescriptors = extractUnexpectedDescriptorTokens(
    {
      title: productLabel,
      rawLabel: productLabel,
      cardText: productLabel,
    },
    query,
    shoppingContext,
  ).filter((token) => SENSITIVE_EXTRA_DESCRIPTOR_TOKENS.has(token) || MATERIAL_SOURCE_DESCRIPTOR_TOKENS.has(token));
  if (unexpectedDescriptors.length) {
    score -= 90 + (unexpectedDescriptors.length * 20);
  }

  return score;
}

function isStrongCandidateMismatch(productLabel, query, shoppingContext = null) {
  const normalizedLabel = normalizeItemName(productLabel);
  const profile = classifyQueryProfile(query);
  const normalizedQuery = profile.normalizedQuery;
  if (!normalizedLabel || !normalizedQuery) return false;
  const familyMismatch = summarizeFamilyMismatch(normalizedLabel, query, shoppingContext);
  if (familyMismatch) return true;

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

function extractPriceText(cardText) {
  const text = normalizeText(cardText);
  if (!text) return null;

  const explicitMatch = text.match(/(?:current price|original price|sale price)\s*:\s*([^•|]+)/i);
  if (explicitMatch) {
    const cleaned = normalizeText(explicitMatch[1]);
    if (cleaned) return cleaned;
  }

  const amountMatch = text.match(/\$\s*\d+(?:[.,]\d{1,2})?/);
  if (amountMatch) {
    return normalizeText(amountMatch[0]);
  }

  return null;
}

function parsePriceValue(value) {
  const text = normalizeText(value);
  if (!text) return null;
  const match = text.match(/\$?\s*([0-9][0-9,]*(?:\.[0-9]{2})?)/);
  if (!match) return null;
  const parsed = Number(String(match[1]).replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : null;
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
        imageURL: node.querySelector("img")?.currentSrc || node.querySelector("img")?.src || null,
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
      imageURL: null,
    };
  }).catch(() => ({
    title: "",
    cardText: "",
    productHref: null,
    actionLabel: "",
    imageURL: null,
  }));
}

async function collectProductCandidates(page, query, shoppingContext = null, {
  maxCandidates = 12,
  sortByScore = true,
} = {}) {
  const productCards = page.locator('a[href*="/products/"]');
  const count = await productCards.count();
  const candidates = [];
  const seen = new Set();

  for (let i = 0; i < count; i += 1) {
    const card = productCards.nth(i);
    if (!(await card.isVisible().catch(() => false))) continue;
    const text = await card.innerText().catch(() => "");
    const rawLabel = (text ?? "").trim();
    const cardContext = await extractProductCardContext(card);
    const title = extractCandidateTitle(cardContext.title, rawLabel, cardContext.cardText) || cardContext.title || rawLabel;
    const cardText = cardContext.cardText || await extractNearbyCardText(card);
    const priceText = extractPriceText(cardText);
    const priceValue = parsePriceValue(priceText ?? cardText);
    const actionLabel = cardContext.actionLabel || "";
    const actionType = /choose/i.test(actionLabel) ? "choose" : "add";
    const score = Math.max(
      scoreProductLabel(title || rawLabel, query, shoppingContext, i),
      scoreProductLabel(cardText || title || rawLabel, query, shoppingContext, i),
    );

    const candidate = {
      buttonIndex: i,
      visibleOrder: candidates.length,
      title,
      rawLabel,
      score,
      cardText: String(cardText ?? "").replace(/\s+/g, " ").trim().slice(0, 360),
      priceText,
      priceValue,
      actionType,
      actionLabel,
      productHref: cardContext.productHref || null,
      imageURL: cardContext.imageURL || null,
    };
    const key = candidateKey(candidate);
    if (seen.has(key)) continue;
    seen.add(key);
    candidates.push(candidate);
  }

  const ordered = sortByScore
    ? candidates
      .sort((a, b) =>
        b.score - a.score ||
        a.title.localeCompare(b.title) ||
        a.buttonIndex - b.buttonIndex
      )
    : candidates
      .sort((a, b) => a.buttonIndex - b.buttonIndex || a.title.localeCompare(b.title));
  return ordered.slice(0, maxCandidates);
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
    const current = await collectProductCandidates(page, query, shoppingContext, {
      maxCandidates,
      sortByScore: true,
    });
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

async function collectScrollableProductCandidateWindows(page, query, shoppingContext = null, {
  windowSize = 10,
  maxWindows = 6,
} = {}) {
  const windows = [];
  const seen = new Set();

  for (let round = 0; round < maxWindows; round += 1) {
    const current = await collectProductCandidates(page, query, shoppingContext, {
      maxCandidates: 40,
      sortByScore: false,
    });
    const fresh = [];
    for (const candidate of current) {
      const key = candidateKey(candidate);
      if (seen.has(key)) continue;
      seen.add(key);
      fresh.push({
        ...candidate,
        visibleOrder: seen.size - 1,
      });
    }

    if (fresh.length) {
      for (let index = 0; index < fresh.length; index += windowSize) {
        const window = fresh.slice(index, index + windowSize);
        if (window.length) windows.push(window);
        if (windows.length >= maxWindows) break;
      }
    }

    if (windows.length >= maxWindows) break;

    const beforeHeight = await page.evaluate(() => document.body?.scrollHeight ?? 0).catch(() => 0);
    await page.evaluate(() => {
      window.scrollBy(0, Math.max(window.innerHeight * 0.9, 1000));
    }).catch(() => {});
    await page.waitForTimeout(1200);
    const afterHeight = await page.evaluate(() => document.body?.scrollHeight ?? 0).catch(() => 0);
    const nearBottom = await page.evaluate(() => (window.innerHeight + window.scrollY) >= ((document.body?.scrollHeight ?? 0) - 120)).catch(() => false);
    if (nearBottom && afterHeight <= beforeHeight) {
      break;
    }
  }

  return windows;
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
      .filter((token) =>
        token.length >= 4 &&
        !NON_DISTINGUISHING_DESCRIPTOR_TOKENS.has(token) &&
        !NON_SHOPPABLE_PREP_DESCRIPTOR_TOKENS.has(token)
      )
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

function applyCandidateDecisionGuards(candidate, query, shoppingContext = null, decisionPayload = {}) {
  if (!candidate) return decisionPayload;

  const familyMismatch = summarizeFamilyMismatch(
    [candidate.title, candidate.rawLabel, candidate.cardText].filter(Boolean).join(" "),
    query,
    shoppingContext,
  );
  if (familyMismatch) {
    return {
      ...decisionPayload,
      decision: "reject",
      matchType: "unsafe",
      needsReview: true,
      substituteReason: null,
      reason: `${decisionPayload.reason ?? "family_guard"}; ${familyMismatch}`,
    };
  }

  const requiredDescriptors = getRequiredDescriptorTokens(query, shoppingContext);
  const unexpectedDescriptors = extractUnexpectedDescriptorTokens(candidate, query, shoppingContext)
    .filter((token) => SENSITIVE_EXTRA_DESCRIPTOR_TOKENS.has(token) || MATERIAL_SOURCE_DESCRIPTOR_TOKENS.has(token));

  const candidateText = normalizeItemName([
    candidate.title,
    candidate.rawLabel,
  ].filter(Boolean).join(" "));
  const candidateTokens = new Set(tokenizeItemName(candidateText));
  const substitutionPolicy = String(shoppingContext?.substitutionPolicy ?? "strict").toLowerCase();
  const minimumContainedQuantity = Number(shoppingContext?.minimumContainedQuantity ?? 0);
  if (minimumContainedQuantity > 1) {
    const quantityHint = extractContainedQuantityHint([
      candidate.title,
      candidate.rawLabel,
      candidate.cardText,
    ].filter(Boolean).join(" "));
    if (Number.isFinite(quantityHint) && quantityHint > 0 && quantityHint < minimumContainedQuantity) {
      return {
        ...decisionPayload,
        decision: "reject",
        matchType: "unsafe",
        needsReview: true,
        substituteReason: null,
        reason: `${decisionPayload.reason ?? "quantity_guard"}; package_too_small:${quantityHint}_under_${minimumContainedQuantity}`,
      };
    }
  }

  if (unexpectedDescriptors.length) {
    const nextDecision = substitutionPolicy === "strict" ? "reject" : "substitute";
    const nextMatchType = substitutionPolicy === "optional" ? "usable_substitute" : "close_substitute";
    return {
      ...decisionPayload,
      decision: nextDecision,
      matchType: nextDecision === "reject" ? "unsafe" : nextMatchType,
      needsReview: true,
      substituteReason: nextDecision === "substitute"
        ? `unexpected_descriptors:${unexpectedDescriptors.join(",")}`
        : null,
      reason: `${decisionPayload.reason ?? "descriptor_guard"}; unexpected descriptors: ${unexpectedDescriptors.join(", ")}`,
    };
  }

  if (!requiredDescriptors.length) return decisionPayload;

  const remainingDescriptors = requiredDescriptors.filter((token) => !NON_SHOPPABLE_PREP_DESCRIPTOR_TOKENS.has(token));
  if (!remainingDescriptors.length) return decisionPayload;

  const missingDescriptors = remainingDescriptors.filter((token) => !candidateTokens.has(token) && !candidateText.includes(token));
  if (!missingDescriptors.length) return decisionPayload;

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
    return applyCandidateDecisionGuards(candidate, query, shoppingContext, {
      success: true,
      decision: "exact_match",
      matchType: "exact",
      needsReview: false,
      substituteReason: null,
      reason: "heuristic_exactish_match",
    });
  }

  if (substitutionPolicy === "flexible" && candidate.score >= 85) {
    return applyCandidateDecisionGuards(candidate, query, shoppingContext, {
      success: true,
      decision: "substitute",
      matchType: "close_substitute",
      needsReview: false,
      substituteReason: "heuristic_close_substitute",
      reason: "heuristic_close_substitute",
    });
  }

  if (substitutionPolicy === "optional" && candidate.score >= 55) {
    return applyCandidateDecisionGuards(candidate, query, shoppingContext, {
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

async function chooseProductCandidateWithLLM({ page, item, query, logger = console, searchMode = "initial" }) {
  const shoppingContext = item?.shoppingContext ?? null;
  const role = normalizeItemName(shoppingContext?.role ?? "");
  const shoppingForm = normalizeItemName(shoppingContext?.shoppingForm ?? "");
  const isBroadSearch = String(searchMode ?? "initial").trim().toLowerCase() === "broad";
  const explorationScale = role === "produce" || /whole_produce|fresh_bunch|fresh_produce/i.test(shoppingForm)
    ? { windowSize: 12, maxWindows: 8 }
    : role === "pantry" || Boolean(shoppingContext?.isPantryStaple)
      ? { windowSize: 10, maxWindows: 7 }
      : { windowSize: 10, maxWindows: 6 };
  const candidateWindows = isBroadSearch
    ? await collectScrollableProductCandidateWindows(page, query, shoppingContext, explorationScale)
    : [(
      await collectProductCandidates(page, query, shoppingContext, {
        maxCandidates: 12,
        sortByScore: false,
      })
    ).slice(0, 3)];
  const flattenedCandidates = candidateWindows.flat();
  if (!flattenedCandidates.length) return null;
  const backupCandidates = flattenedCandidates.slice(0, 3).map(summarizeCandidate);
  if (!openai) {
    const heuristicDecision = inferHeuristicDecision(flattenedCandidates[0], query, shoppingContext);
    return {
      candidate: heuristicDecision.success ? flattenedCandidates[0] : null,
      fallbackCandidate: flattenedCandidates[0],
      refinedQuery: null,
      llmChoice: false,
      llmConfidence: null,
      llmReason: heuristicDecision.reason,
      decision: heuristicDecision.decision,
      matchType: heuristicDecision.matchType,
      needsReview: heuristicDecision.needsReview,
      substituteReason: heuristicDecision.substituteReason,
      selectionTrace: {
        totalCandidates: flattenedCandidates.length,
        selectedCandidate: heuristicDecision.success ? summarizeCandidate(flattenedCandidates[0]) : null,
        fallbackCandidate: summarizeCandidate(flattenedCandidates[0] ?? null),
        topCandidates: backupCandidates,
      },
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

  for (let windowIndex = 0; windowIndex < candidateWindows.length; windowIndex += 1) {
    const windowCandidates = candidateWindows[windowIndex];
    const priceContext = buildCandidatePriceContext(windowCandidates);
    const promptCandidates = windowCandidates.map((candidate, index) => ({
      index,
      visibleOrder: Number.isFinite(Number(candidate.visibleOrder)) ? Number(candidate.visibleOrder) : index,
      title: candidate.title,
      rawLabel: candidate.rawLabel,
      score: candidate.score,
      cardText: candidate.cardText,
      priceText: candidate.priceText,
      priceValue: candidate.priceValue,
      quantityHint: extractContainedQuantityHint([candidate.title, candidate.rawLabel, candidate.cardText].filter(Boolean).join(" ")),
      familyMismatch: summarizeFamilyMismatch(
        [candidate.title, candidate.rawLabel, candidate.cardText].filter(Boolean).join(" "),
        query,
        shoppingContext,
      ),
      priceRank: priceContext[index]?.priceRank ?? null,
      cheapestVisiblePrice: priceContext[index]?.cheapestVisiblePrice ?? null,
      priceDeltaFromCheapest: priceContext[index]?.priceDeltaFromCheapest ?? null,
      pricePosition: priceContext[index]?.pricePosition ?? null,
      unexpectedDescriptors: extractUnexpectedDescriptorTokens(candidate, query, shoppingContext)
        .filter((token) => SENSITIVE_EXTRA_DESCRIPTOR_TOKENS.has(token)),
    }));

  try {
    const response = await openai.chat.completions.create({
      model: INSTACART_PRODUCT_MODEL,
      ...chatCompletionTemperatureParams(INSTACART_PRODUCT_MODEL),
      response_format: {
          type: "json_schema",
          json_schema: {
            name: "instacart_product_choice",
            schema: {
              type: "object",
              additionalProperties: false,
              properties: {
                action: { type: "string" },
                selectedIndex: { type: ["integer", "null"] },
                decision: { type: "string" },
                matchType: { type: "string" },
                needsReview: { type: "boolean" },
                substituteReason: { type: ["string", "null"] },
                confidence: { type: "number" },
                reason: { type: "string" },
                refinedQuery: { type: ["string", "null"] },
              },
              required: ["action", "selectedIndex", "decision", "matchType", "needsReview", "substituteReason", "confidence", "reason", "refinedQuery"],
            },
          },
        },
        messages: [
          {
            role: "system",
            content: [
              "You choose the best Instacart search result for a grocery item.",
              "You are reviewing visible Instacart results in the same order a shopper would see them while browsing.",
              isBroadSearch
                ? "This is a broader retry pass. You may keep browsing or refine the query more aggressively if the first visible options are weak."
                : "This is the initial pass. Only evaluate the first three visible options on the screen. Do not browse beyond those three in this pass; the finalizer and retry flow handle broader search later.",
              "Your job is to decide whether to select a visible product now, keep browsing, refine the search query, or mark this search path as unfound.",
              "Prefer the correct ingredient/form for the recipe context, not merely a same-aisle item.",
              "For plain grocery queries like tomato, sweet potato, salmon, honey, avocado oil, or chicken, prefer the simplest everyday form over specialty, boxed, heirloom, premium, or overly expensive variants unless the recipe context explicitly asks for them.",
              "For simple everyday items with little context, prefer the earliest visible result that is a reasonable fit. The first item is usually the best default; second, third, and fourth are acceptable backups only if they are still simple and obviously correct.",
              "Optimize for value after fit. If two or more visible candidates are materially acceptable, prefer the lower-priced everyday option rather than premium, organic, wild, specialty, heirloom, or oversized options.",
              !isBroadSearch
                ? "Because this is an initial pass, give extra weight to the first visible everyday option and avoid overthinking ordinary pantry or produce items."
                : "Because this is a retry pass, broaden the search or browse further when the first visible options are not clearly correct.",
              "Do not pick a cheaper product if it is the wrong form, wrong ingredient family, or a worse fit for the recipe.",
              "Respect shoppingContext.shoppingForm and shoppingContext.expectedPurchaseUnit when present. For whole produce, prefer fresh whole produce cards. For fresh_bunch, prefer fresh bunches over dried, paste, or pantry variants.",
              "If shoppingContext.quantityStrategy is single_package_minimum_count, the item should be bought as one package that contains at least shoppingContext.minimumContainedQuantity. Do not multiply packs to satisfy the requested count.",
              "When quantityStrategy is single_package_minimum_count, prefer visible candidates whose text suggests a family pack, value pack, tray, or an explicit count at or above the minimumContainedQuantity.",
              "If two candidates are both acceptable, prefer the plainer, more common, less packaged, and cheaper everyday option.",
              "Use the full requestedItem context, including sourceIngredients, sourceRecipes, and shoppingContext, to decide if the product actually works in the recipes.",
              "If shoppingContext.searchQueries or shoppingContext.preferredForms indicate broader search variants, keep scrolling or refine the query instead of forcing a weak match.",
              "Return action as one of: select_candidate, continue_scrolling, refine_query, mark_unfound.",
              "Use select_candidate only when one visible candidate is materially correct or an explicitly acceptable substitute.",
              "Use continue_scrolling when this window is inconclusive but more browsing is likely useful.",
              "Use refine_query when the current query is wrong or too broad; provide a short concrete refinedQuery.",
              "Use mark_unfound when the current store/query path should stop and the caller should try another store or a general Instacart search.",
              "Reject bundled, flavored, prepared, or obviously wrong products when a cleaner match exists.",
              "Prefer in-stock items. If the visible candidate is unavailable, that alone is not enough to select it.",
              "matchType must be one of: exact, close_substitute, usable_substitute, unsafe.",
              "If action is select_candidate, selectedIndex must point to one visible candidate.",
              "If action is refine_query, selectedIndex must be null.",
              "If action is continue_scrolling or mark_unfound, selectedIndex must be null.",
              "The refinedQuery should be short and concrete, usually 1 to 4 words, and only when it would materially improve the search.",
              "Return JSON only.",
            ].join(" "),
          },
          {
            role: "user",
            content: JSON.stringify({
              requestedItem: {
                originalName: item?.originalName ?? item?.name ?? query,
                normalizedQuery: query,
                quantity: item?.originalAmount ?? item?.amount ?? 1,
                unit: item?.originalUnit ?? item?.unit ?? "item",
                sourceIngredients,
                sourceRecipes,
                shoppingContext: item?.shoppingContext ?? null,
              },
              searchState: {
                currentQuery: query,
                windowNumber: windowIndex + 1,
                totalWindowsSeen: candidateWindows.length,
                hasMoreWindowsAfterThis: windowIndex < candidateWindows.length - 1,
                searchQueries: shoppingContext?.searchQueries ?? [],
                preferredForms: shoppingContext?.preferredForms ?? [],
                requiredDescriptors: shoppingContext?.requiredDescriptors ?? [],
                quantityStrategy: shoppingContext?.quantityStrategy ?? null,
                minimumContainedQuantity: shoppingContext?.minimumContainedQuantity ?? null,
                desiredPackageCount: shoppingContext?.desiredPackageCount ?? null,
              },
              candidates: promptCandidates,
              searchMode,
            }, null, 2),
          },
        ],
      });

      const content = response.choices?.[0]?.message?.content ?? "{}";
      const parsed = JSON.parse(content);
    const action = typeof parsed.action === "string" ? parsed.action : "mark_unfound";
    const selectedIndex = typeof parsed.selectedIndex === "number" ? parsed.selectedIndex : null;
    const chosen = selectedIndex != null ? windowCandidates[selectedIndex] ?? null : null;
    const refinedQuery = typeof parsed.refinedQuery === "string" && parsed.refinedQuery.trim() ? parsed.refinedQuery.trim() : null;
    latestRefinedQuery = refinedQuery ?? latestRefinedQuery;
    latestReason = parsed.reason ?? latestReason;
    const parsedConfidence = Number(parsed.confidence ?? 0);
    const initialConfidenceBelowCutoff =
      !isBroadSearch &&
      action === "select_candidate" &&
      chosen &&
      Number.isFinite(parsedConfidence) &&
      parsedConfidence < INITIAL_SELECTION_CONFIDENCE_CUTOFF;

    if (action === "select_candidate" && chosen) {
      const initialGuardedDecision = applyCandidateDecisionGuards(chosen, query, shoppingContext, {
        decision: parsed.decision ?? "exact_match",
        matchType: parsed.matchType ?? "exact",
          needsReview: Boolean(parsed.needsReview),
          substituteReason: parsed.substituteReason ?? null,
          reason: parsed.reason ?? "",
        });
        const candidateWarden = initialGuardedDecision.decision !== "reject"
          ? await adjudicateSelectedCandidateWithLLM({
            page,
            item,
            query,
            selectedCandidate: chosen,
          selectedIndex,
          promptCandidates,
          windowCandidates,
          windowIndex,
          totalWindows: candidateWindows.length,
          previousAction: action,
          logger,
        })
          : {
            action: "continue_scrolling",
            approved: false,
            selectedIndex: null,
            candidate: null,
          confidence: null,
          reason: initialGuardedDecision.reason ?? "guard_reject",
          refinedQuery: null,
        };
        const reviewedCandidate = candidateWarden.candidate ?? chosen;
        const guardedDecision = candidateWarden.approved
          ? applyCandidateDecisionGuards(reviewedCandidate, query, shoppingContext, {
            decision: parsed.decision ?? "exact_match",
            matchType: parsed.matchType ?? "exact",
            needsReview: Boolean(parsed.needsReview),
            substituteReason: parsed.substituteReason ?? null,
            reason: candidateWarden.reason ?? parsed.reason ?? "",
          })
          : initialGuardedDecision;
        windowTrace.push({
          window: windowIndex + 1,
          candidates: promptCandidates,
          action,
          selectedIndex: candidateWarden.approved ? candidateWarden.selectedIndex ?? selectedIndex : selectedIndex,
          selectedCandidate: candidateWarden.approved ? summarizeCandidate(reviewedCandidate) : summarizeCandidate(chosen),
          decision: guardedDecision.decision ?? parsed.decision ?? "exact_match",
          matchType: guardedDecision.matchType ?? parsed.matchType ?? "exact",
          confidence: candidateWarden.confidence ?? parsedConfidence,
          reason: guardedDecision.reason ?? candidateWarden.reason ?? parsed.reason ?? "",
          refinedQuery: candidateWarden.refinedQuery ?? refinedQuery,
          confidenceCutoff: INITIAL_SELECTION_CONFIDENCE_CUTOFF,
          belowCutoff: initialConfidenceBelowCutoff,
          candidateWarden: {
            action: candidateWarden.action,
            approved: candidateWarden.approved,
            selectedIndex: candidateWarden.selectedIndex,
            confidence: candidateWarden.confidence,
            reason: candidateWarden.reason,
            refinedQuery: candidateWarden.refinedQuery,
          },
        });
        logger.log?.(`[instacart] LLM picked "${chosen.title}" for "${item?.originalName ?? item?.name ?? query}" (confidence=${parsed.confidence ?? 0}, reason=${parsed.reason ?? ""}, window=${windowIndex + 1})`);
        if (initialConfidenceBelowCutoff) {
          return {
            candidate: reviewedCandidate,
            fallbackCandidate: flattenedCandidates[0] ?? null,
            refinedQuery: candidateWarden.refinedQuery ?? refinedQuery,
            llmChoice: true,
            llmConfidence: candidateWarden.confidence ?? parsedConfidence,
            llmReason: guardedDecision.reason ?? candidateWarden.reason ?? parsed.reason ?? "initial_confidence_below_cutoff",
            decision: "retry_queued",
            matchType: "low_confidence",
            needsReview: true,
            substituteReason: null,
            selectionTrace: {
              totalCandidates: flattenedCandidates.length,
              selectedCandidate: summarizeCandidate(reviewedCandidate),
              fallbackCandidate: summarizeCandidate(flattenedCandidates[0] ?? null),
              topCandidates: backupCandidates,
              windows: windowTrace,
              confidenceCutoff: INITIAL_SELECTION_CONFIDENCE_CUTOFF,
              belowCutoff: true,
              searchMode,
            },
          };
        }
        if (candidateWarden.action === "refine_query" && candidateWarden.refinedQuery) {
          logger.warn?.(`[instacart] candidate warden requested refined query "${candidateWarden.refinedQuery}" for "${item?.originalName ?? item?.name ?? query}" at window ${windowIndex + 1}`);
          return {
            candidate: null,
            fallbackCandidate: flattenedCandidates[0] ?? null,
            refinedQuery: candidateWarden.refinedQuery,
            llmChoice: true,
            llmConfidence: candidateWarden.confidence ?? Number(parsed.confidence ?? 0),
            llmReason: candidateWarden.reason ?? parsed.reason ?? "candidate_warden_refine_query",
            decision: "reject",
            matchType: "unsafe",
            needsReview: true,
            substituteReason: null,
            selectionTrace: {
              totalCandidates: flattenedCandidates.length,
              fallbackCandidate: summarizeCandidate(flattenedCandidates[0] ?? null),
              topCandidates: backupCandidates,
              windows: windowTrace,
              searchMode,
            },
          };
        }
        if (candidateWarden.action === "mark_unfound") {
          logger.warn?.(`[instacart] candidate warden marked "${item?.originalName ?? item?.name ?? query}" unfound at window ${windowIndex + 1}`);
          break;
        }
        if (candidateWarden.action === "continue_scrolling" || !candidateWarden.approved || guardedDecision.decision === "reject") {
          logger.warn?.(`[instacart] candidate warden rejected "${chosen.title}" for "${item?.originalName ?? item?.name ?? query}" at window ${windowIndex + 1}: ${candidateWarden.reason ?? guardedDecision.reason ?? "rejected"}`);
          continue;
        }
        if (guardedDecision.decision !== "reject") {
          return {
            candidate: reviewedCandidate,
            fallbackCandidate: flattenedCandidates[0] ?? null,
            refinedQuery: candidateWarden.refinedQuery ?? refinedQuery,
            llmChoice: true,
            llmConfidence: candidateWarden.confidence ?? Number(parsed.confidence ?? 0),
            llmReason: guardedDecision.reason ?? candidateWarden.reason ?? parsed.reason ?? "",
            decision: guardedDecision.decision ?? "exact_match",
            matchType: guardedDecision.matchType ?? "exact",
            needsReview: Boolean(guardedDecision.needsReview),
            substituteReason: guardedDecision.substituteReason ?? null,
            selectionTrace: {
              totalCandidates: flattenedCandidates.length,
              selectedCandidate: summarizeCandidate(reviewedCandidate),
              fallbackCandidate: summarizeCandidate(flattenedCandidates[0] ?? null),
              topCandidates: backupCandidates,
              windows: windowTrace,
              searchMode,
            },
          };
        }
      } else {
        const heuristicDecision = inferHeuristicDecision(windowCandidates[0], query, shoppingContext);
        windowTrace.push({
          window: windowIndex + 1,
          candidates: promptCandidates,
          action,
          selectedIndex: null,
          selectedCandidate: null,
          decision: parsed.decision ?? "reject",
          matchType: parsed.matchType ?? "unsafe",
          confidence: Number(parsed.confidence ?? 0),
          reason: parsed.reason ?? "",
          refinedQuery,
        });
        if ((action === "mark_unfound" || action === "continue_scrolling") && heuristicDecision.success) {
          const rescueWarden = await adjudicateSelectedCandidateWithLLM({
            page,
            item,
            query,
            selectedCandidate: windowCandidates[0],
            selectedIndex: 0,
            promptCandidates,
            windowCandidates,
            windowIndex,
            totalWindows: candidateWindows.length,
            previousAction: action,
            logger,
          });
          if (rescueWarden.action === "refine_query" && rescueWarden.refinedQuery) {
            logger.warn?.(`[instacart] heuristic rescue requested refined query "${rescueWarden.refinedQuery}" for "${item?.originalName ?? item?.name ?? query}" at window ${windowIndex + 1}`);
            return {
              candidate: null,
              fallbackCandidate: flattenedCandidates[0] ?? null,
              refinedQuery: rescueWarden.refinedQuery,
              llmChoice: true,
              llmConfidence: rescueWarden.confidence,
              llmReason: rescueWarden.reason ?? `heuristic_rescue_after_${action}`,
              decision: "reject",
              matchType: "unsafe",
              needsReview: true,
              substituteReason: null,
              selectionTrace: {
                totalCandidates: flattenedCandidates.length,
                fallbackCandidate: summarizeCandidate(flattenedCandidates[0] ?? null),
                topCandidates: backupCandidates,
                windows: windowTrace,
              },
            };
          }
          if (rescueWarden.action === "mark_unfound") {
            logger.warn?.(`[instacart] heuristic rescue marked "${item?.originalName ?? item?.name ?? query}" unfound at window ${windowIndex + 1}`);
            break;
          }
          if (!rescueWarden.approved) {
            logger.warn?.(`[instacart] heuristic rescue rejected top candidate for "${item?.originalName ?? item?.name ?? query}" at window ${windowIndex + 1}: ${rescueWarden.reason ?? "rejected"}`);
            continue;
          }
          const rescuedCandidate = rescueWarden.candidate ?? windowCandidates[0];
          const rescuedDecision = applyCandidateDecisionGuards(rescuedCandidate, query, shoppingContext, {
            decision: heuristicDecision.decision,
            matchType: heuristicDecision.matchType,
            needsReview: heuristicDecision.needsReview,
            substituteReason: heuristicDecision.substituteReason,
            reason: rescueWarden.reason ?? heuristicDecision.reason,
          });
          if (rescuedDecision.decision === "reject") {
            logger.warn?.(`[instacart] heuristic rescue still rejected "${item?.originalName ?? item?.name ?? query}" at window ${windowIndex + 1}: ${rescuedDecision.reason ?? "guarded_reject"}`);
            continue;
          }
          logger.log?.(`[instacart] heuristic rescue picked "${rescuedCandidate.title}" for "${item?.originalName ?? item?.name ?? query}" after LLM action=${action} (window=${windowIndex + 1})`);
          return {
            candidate: rescuedCandidate,
            fallbackCandidate: flattenedCandidates[0] ?? null,
            refinedQuery: null,
            llmChoice: false,
            llmConfidence: rescueWarden.confidence ?? null,
            llmReason: rescueWarden.reason ?? `heuristic_rescue_after_${action}`,
            decision: rescuedDecision.decision,
            matchType: rescuedDecision.matchType,
            needsReview: rescuedDecision.needsReview,
            substituteReason: rescuedDecision.substituteReason,
            selectionTrace: {
              totalCandidates: flattenedCandidates.length,
              selectedCandidate: summarizeCandidate(rescuedCandidate),
              fallbackCandidate: summarizeCandidate(flattenedCandidates[0] ?? null),
              topCandidates: backupCandidates,
              windows: windowTrace,
              rescuedByHeuristic: true,
              rescueReason: rescueWarden.reason ?? heuristicDecision.reason,
            },
          };
        }
        if (action === "refine_query" && refinedQuery) {
          logger.warn?.(`[instacart] LLM requested refined query "${refinedQuery}" for "${item?.originalName ?? item?.name ?? query}" at window ${windowIndex + 1}`);
          return {
            candidate: null,
            fallbackCandidate: flattenedCandidates[0] ?? null,
            refinedQuery,
            llmChoice: true,
            llmConfidence: Number(parsed.confidence ?? 0),
            llmReason: parsed.reason ?? "llm_refine_query",
            decision: "reject",
            matchType: "unsafe",
            needsReview: true,
            substituteReason: null,
            selectionTrace: {
              totalCandidates: flattenedCandidates.length,
              fallbackCandidate: summarizeCandidate(flattenedCandidates[0] ?? null),
              topCandidates: backupCandidates,
              windows: windowTrace,
            },
          };
        }
        if (action === "mark_unfound") {
          logger.warn?.(`[instacart] LLM marked "${item?.originalName ?? item?.name ?? query}" unfound for current search path at window ${windowIndex + 1}`);
          break;
        }
      }

      logger.warn?.(`[instacart] LLM action=${action} on window ${windowIndex + 1} for "${item?.originalName ?? item?.name ?? query}" (confidence=${parsed.confidence ?? 0}${refinedQuery ? `, refinedQuery="${refinedQuery}"` : ""})`);
    } catch (error) {
      logger.warn?.(`[instacart] LLM selection failed for "${item?.originalName ?? item?.name ?? query}" on window ${windowIndex + 1}: ${error.message}`);
      const heuristicDecision = inferHeuristicDecision(windowCandidates[0], query, shoppingContext);
      windowTrace.push({
        window: windowIndex + 1,
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
          fallbackCandidate: flattenedCandidates[0] ?? null,
          refinedQuery: null,
          llmChoice: false,
          llmConfidence: null,
          llmReason: heuristicDecision.reason,
          decision: heuristicDecision.decision,
          matchType: heuristicDecision.matchType,
          needsReview: heuristicDecision.needsReview,
          substituteReason: heuristicDecision.substituteReason,
          selectionTrace: {
              totalCandidates: flattenedCandidates.length,
              selectedCandidate: heuristicDecision.success ? summarizeCandidate(windowCandidates[0]) : null,
              fallbackCandidate: summarizeCandidate(flattenedCandidates[0] ?? null),
              topCandidates: backupCandidates,
              windows: windowTrace,
            },
          };
      }
    }
  }

  return {
    candidate: null,
    fallbackCandidate: flattenedCandidates[0] ?? null,
    refinedQuery: latestRefinedQuery,
    llmChoice: false,
    llmConfidence: null,
    llmReason: latestReason ?? "llm_exhausted_candidate_windows",
    decision: "reject",
    matchType: "unsafe",
    needsReview: true,
    substituteReason: null,
    selectionTrace: {
      totalCandidates: flattenedCandidates.length,
      fallbackCandidate: summarizeCandidate(flattenedCandidates[0] ?? null),
      windows: windowTrace,
      topCandidates: backupCandidates,
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
    return { changed: false, afterCount: null, verificationMode: "missing_before_count" };
  }

  const start = Date.now();
  while ((Date.now() - start) < timeoutMs) {
    await page.waitForTimeout(450);
    const afterCount = await readCartItemCount(page);
    if (typeof afterCount === "number") {
      if (afterCount >= beforeCount + minimumDelta) {
        return { changed: true, afterCount, verificationMode: "count_increase" };
      }
      if (beforeCount >= 50 && afterCount > 0 && afterCount !== beforeCount) {
        return { changed: true, afterCount, verificationMode: "count_reset_anomaly" };
      }
    }
  }

  return { changed: false, afterCount: await readCartItemCount(page), verificationMode: "timeout" };
}

async function captureActionVerificationSnapshot(locator) {
  try {
    return await locator.evaluate((el) => {
      const clean = (value) => String(value ?? "").replace(/\s+/g, " ").trim().toLowerCase();
      let node = el;
      let cardNode = el;
      for (let depth = 0; depth < 9 && node; depth += 1) {
        node = node.parentElement;
        if (!node) break;
        const text = clean(node.innerText || "");
        if (text.length >= 8) {
          cardNode = node;
          break;
        }
      }

      const quantityButtons = cardNode
        ? Array.from(cardNode.querySelectorAll("button")).filter((button) =>
            /increase quantity|decrease quantity|\+|\-/i.test(
              `${button.getAttribute?.("aria-label") || ""} ${button.innerText || ""} ${button.textContent || ""}`
            )
          )
        : [];
      const quantityText = cardNode
        ? Array.from(cardNode.querySelectorAll("button, span, div"))
            .map((node) => clean(node.textContent || ""))
            .find((text) => /^\d+$/.test(text) || /^\d+\s*(each|item|items|bunch|bunches|pack|packs)$/.test(text))
        : null;

      return {
        ariaLabel: clean(el?.getAttribute?.("aria-label") || ""),
        text: clean(el?.innerText || ""),
        title: clean(cardNode?.querySelector?.("h1, h2, h3, h4, [data-testid*='item-name'], [data-testid*='product-name']")?.textContent || ""),
        actionLabel: clean(
          cardNode?.querySelector?.('button[aria-label*="Add"], button[aria-label*="Choose"]')?.getAttribute?.("aria-label")
            || el?.getAttribute?.("aria-label")
            || el?.innerText
            || ""
        ),
        cardText: clean(cardNode?.innerText || ""),
        quantityButtonCount: quantityButtons.length,
        quantityText: clean(quantityText || ""),
      };
    });
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
  if ((beforeSnapshot.quantityButtonCount ?? 0) !== (afterSnapshot.quantityButtonCount ?? 0)) {
    return true;
  }
  if (beforeSnapshot.quantityText && afterSnapshot.quantityText && beforeSnapshot.quantityText !== afterSnapshot.quantityText) {
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
      title: extractCandidateTitle(cardContext.title, ariaLabel ?? text, cardContext.cardText) || cardContext.title || extractCandidateTitle(ariaLabel ?? text),
      rawLabel: (ariaLabel ?? text ?? "").trim(),
      cardText: cardContext.cardText || await extractNearbyCardText(button),
      productHref: cardContext.productHref || null,
      actionType: /choose/i.test(ariaLabel || text || cardContext.actionLabel || "") ? "choose" : "add",
      actionLabel: (ariaLabel ?? text ?? cardContext.actionLabel ?? "").trim(),
      score: Math.max(
        scoreProductLabel(cardContext.title || ariaLabel || text, query, shoppingContext, i),
        scoreProductLabel(cardContext.cardText || ariaLabel || text, query, shoppingContext, i),
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
    const beforeSnapshot = await captureActionVerificationSnapshot(liveCandidate.button);
    await liveCandidate.button.click({ timeout: 5000 });
    return {
      clicked: true,
      method: "visible_action",
      liveCandidate: summarizeCandidate(liveCandidate),
      verificationTarget: liveCandidate.button,
      beforeSnapshot,
    };
  }

  if (candidate?.productHref) {
    await page.goto(candidate.productHref, { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(1800);
    const productAction = page.locator(ACTIONABLE_PRODUCT_BUTTON_SELECTOR).first();
    if (await productAction.count().catch(() => 0)) {
      const beforeSnapshot = await captureActionVerificationSnapshot(productAction);
      await productAction.click({ timeout: 5000 });
      return {
        clicked: true,
        method: "product_page",
        liveCandidate: summarizeCandidate(candidate),
        verificationTarget: productAction,
        beforeSnapshot,
      };
    }
  }

  return { clicked: false, method: "not_found", liveCandidate: summarizeCandidate(candidate) };
}

async function verifyItemInCartByTerms(page, terms = [], timeoutMs = 5000) {
  const normalizedTerms = normalizeSearchTerms(terms, 8);
  if (!normalizedTerms.length) {
    return { matched: false, matchedTerm: null, source: "no_terms" };
  }

  const startedAt = Date.now();
  const evaluateTerms = async (activePage) => {
    const bodyText = normalizeItemName(await activePage.locator("body").innerText({ timeout: 2500 }).catch(() => ""));
    const lineItemsText = normalizeItemName((await extractVisibleCartLineItems(activePage).catch(() => [])).join(" "));
    const combinedText = normalizeItemName([bodyText, lineItemsText].filter(Boolean).join(" "));
    for (const term of normalizedTerms) {
      if (term && combinedText.includes(term)) {
        return {
          matched: true,
          matchedTerm: term,
          source: lineItemsText.includes(term) ? "cart_rows" : "page_body",
        };
      }
    }
    return null;
  };

  while ((Date.now() - startedAt) < timeoutMs) {
    const liveMatch = await evaluateTerms(page);
    if (liveMatch) return liveMatch;
    await page.waitForTimeout(350);
  }

  const priorURL = page.url();
  if (!/\/store\/cart(?:[/?#]|$)/i.test(priorURL)) {
    try {
      await page.goto("https://www.instacart.ca/store/cart", { waitUntil: "domcontentloaded", timeout: 30000 });
      await page.waitForTimeout(1200);
      const cartMatch = await evaluateTerms(page);
      if (cartMatch) {
        return { ...cartMatch, source: "cart_page" };
      }
    } catch {}
    try {
      await page.goto(priorURL, { waitUntil: "domcontentloaded", timeout: 30000 });
      await page.waitForTimeout(1200);
    } catch {}
  }

  return { matched: false, matchedTerm: null, source: "not_found" };
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

function pluralizeSearchPhrase(value) {
  const normalized = normalizeItemName(value);
  if (!normalized) return "";
  const tokens = normalized.split(" ").filter(Boolean);
  if (!tokens.length) return "";
  const last = tokens[tokens.length - 1];
  let pluralLast = last;
  if (/[^aeiou]y$/i.test(last)) {
    pluralLast = `${last.slice(0, -1)}ies`;
  } else if (!/(s|x|z|ch|sh)$/i.test(last)) {
    pluralLast = `${last}s`;
  }
  tokens[tokens.length - 1] = pluralLast;
  return tokens.join(" ");
}

function buildContextualQueryVariants(item, query) {
  const shoppingContext = item?.shoppingContext ?? null;
  const canonicalName = normalizeItemName(shoppingContext?.canonicalName ?? query);
  const preferredForms = uniqueTerms(shoppingContext?.preferredForms ?? [], 8);
  const alternateQueries = uniqueTerms(shoppingContext?.alternateQueries ?? [], 8);
  const searchQueries = uniqueTerms(shoppingContext?.searchQueries ?? [], 8);
  const requiredDescriptors = uniqueTerms(shoppingContext?.requiredDescriptors ?? [], 8);
  const shoppingForm = normalizeItemName(shoppingContext?.shoppingForm ?? "");
  const role = normalizeItemName(shoppingContext?.role ?? "");
  const variants = [];
  const push = (...values) => {
    for (const value of values) {
      const normalizedValue = normalizeItemName(value);
      if (normalizedValue && !variants.includes(normalizedValue)) {
        variants.push(normalizedValue);
      }
    }
  };

  push(query);
  push(canonicalName);
  for (const preferred of preferredForms) push(preferred);
  for (const alternate of alternateQueries) push(alternate);
  for (const guided of searchQueries) push(guided);

  if (role === "produce" || /whole_produce|fresh_bunch|fresh_produce/i.test(shoppingForm)) {
    push(
      `fresh ${canonicalName}`,
      `whole ${canonicalName}`,
      pluralizeSearchPhrase(canonicalName),
      `${canonicalName} bunch`,
    );
  }

  if (requiredDescriptors.length) {
    for (const descriptor of requiredDescriptors.slice(0, 4)) {
      push(
        `${descriptor} ${canonicalName}`,
        `${canonicalName} ${descriptor}`,
      );
    }
  }

  if (role === "produce") {
    push(
      `fresh ${query}`,
      pluralizeSearchPhrase(query),
      `${query} bunch`,
    );
  }

  return variants;
}

function buildQueryVariants(query, item) {
  const shoppingContext = item?.shoppingContext ?? null;
  const fallbackSearchQuery = normalizeItemName(shoppingContext?.fallbackSearchQuery ?? "");
  const variants = [];
  const push = (value) => {
    const normalized = normalizeItemName(value);
    if (normalized && !variants.includes(normalized)) {
      variants.push(normalized);
    }
  };

  for (const variant of buildContextualQueryVariants(item, query)) push(variant);
  for (const variant of buildManualQueryVariants(query)) push(variant);
  if (fallbackSearchQuery) push(fallbackSearchQuery);
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

async function tryAddButton(page, item, query, logger = console, {
  searchMode = "initial",
  runId = null,
  selectionArtifactName = null,
} = {}) {
  const bestCandidate = await chooseProductCandidateWithLLM({
    page,
    item,
    query,
    logger,
    searchMode,
  });
  if (bestCandidate?.candidate && bestCandidate?.decision !== "reject") {
    const selectionScreenshotArtifact = selectionArtifactName && runId
      ? await captureRunPageArtifact(page, runId, selectionArtifactName, logger, { fullPage: false })
      : null;
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
          selectedCandidate: summarizeCandidate(bestCandidate.candidate),
          fallbackCandidate: summarizeCandidate(bestCandidate.fallbackCandidate ?? null),
          selectionScreenshotArtifact,
          click: clickResult,
        },
      };
    }

    let cartVerification = await waitForCartCountChange(page, beforeCartCount, 1, 3500);
    let actionVerification = (!cartVerification.changed && clickResult.verificationTarget)
      ? await waitForActionContextChange(page, clickResult.verificationTarget, clickResult.beforeSnapshot, 3500)
      : { changed: false, afterSnapshot: clickResult.beforeSnapshot ?? null };
    let choiceFlow = null;
    if (!cartVerification.changed && (bestCandidate.candidate.actionType === "choose" || clickResult.method === "product_page")) {
      choiceFlow = await completeChoiceFlowIfNeeded(page);
      if (choiceFlow.completed) {
        cartVerification = await waitForCartCountChange(page, beforeCartCount, 1, 3500);
        if (!cartVerification.changed && clickResult.verificationTarget) {
          actionVerification = await waitForActionContextChange(page, clickResult.verificationTarget, clickResult.beforeSnapshot, 3500);
        }
      }
    }
    const cartPresenceVerification = (!cartVerification.changed && !actionVerification.changed)
      ? await verifyItemInCartByTerms(page, buildVerificationTerms(item, query, bestCandidate.candidate), 3000)
      : { matched: false, matchedTerm: null, source: "skipped" };
    const verifiedSuccess = typeof beforeCartCount === "number"
      ? (cartVerification.changed || actionVerification.changed || cartPresenceVerification.matched)
      : (actionVerification.changed || cartPresenceVerification.matched);
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
          selectedCandidate: summarizeCandidate(bestCandidate.candidate),
          fallbackCandidate: summarizeCandidate(bestCandidate.fallbackCandidate ?? null),
          selectionScreenshotArtifact,
          click: clickResult,
          choiceFlow,
          cartVerification: {
            beforeCount: beforeCartCount,
            afterCount: cartVerification.afterCount,
            changed: cartVerification.changed,
          },
          actionVerification,
          cartPresenceVerification,
        },
      };
    }

    return {
      success: true,
      matchedLabel: extractCandidateTitle(bestCandidate.candidate.title, bestCandidate.candidate.rawLabel, bestCandidate.candidate.cardText) || bestCandidate.candidate.title || bestCandidate.candidate.rawLabel,
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
        selectedCandidate: summarizeCandidate(bestCandidate.candidate),
        fallbackCandidate: summarizeCandidate(bestCandidate.fallbackCandidate ?? null),
        selectionScreenshotArtifact,
        click: clickResult,
        choiceFlow,
        cartVerification: {
          beforeCount: beforeCartCount,
          afterCount: cartVerification.afterCount,
          changed: cartVerification.changed,
        },
        actionVerification,
        cartPresenceVerification,
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
          selectedCandidate: summarizeCandidate({
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
          selectedCandidate: summarizeCandidate({
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
  const normalizedQuery = normalizeItemName(query);
  const normalizedPreferredLabel = normalizeItemName(preferredLabel);

  async function scanQuantityTargets(activePage) {
    for (const selector of quantitySelectors) {
      try {
        const locator = activePage.locator(selector);
        const count = await locator.count();
        for (let i = 0; i < count; i += 1) {
          const candidate = locator.nth(i);
          if (!(await candidate.isVisible().catch(() => false))) continue;
          const ariaLabel = await candidate.getAttribute("aria-label").catch(() => "") ?? "";
          const buttonText = await candidate.innerText().catch(() => "") ?? "";
          const cardText = await extractNearbyCardText(candidate);
          const contextLabel = [ariaLabel, buttonText, cardText].filter(Boolean).join(" ");
          const normalizedContext = normalizeItemName(contextLabel);
          if (!normalizedContext) continue;

          if (normalizedPreferredLabel) {
            const matchesPreferred =
              normalizedContext.includes(normalizedPreferredLabel) ||
              normalizedPreferredLabel.includes(normalizedContext);
            if (!matchesPreferred) continue;
          }

          if (normalizedQuery) {
            const matchesQuery =
              normalizedContext.includes(normalizedQuery) ||
              normalizedQuery.includes(normalizedContext);
            if (!matchesQuery) {
              const profile = classifyQueryProfile(normalizedQuery);
              if (profile.freshProduce || profile.freshHerb || profile.genericChicken || profile.genericShrimp) {
                continue;
              }
            }
          }

          const score = Math.max(
            scoreProductLabel(contextLabel, query, shoppingContext),
            normalizedPreferredLabel ? scoreProductLabel(contextLabel, normalizedPreferredLabel, shoppingContext) : Number.NEGATIVE_INFINITY,
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
  }

  while (!best && Date.now() < deadline) {
    await scanQuantityTargets(page);
    if (!best) {
      await page.waitForTimeout(400);
    }
  }

  if (!best && !/\/store\/cart(?:[/?#]|$)/i.test(page.url())) {
    try {
      await page.goto("https://www.instacart.ca/store/cart", { waitUntil: "domcontentloaded", timeout: 30000 });
      await page.waitForTimeout(1200);
      const cartDeadline = Date.now() + 3500;
      while (!best && Date.now() < cartDeadline) {
        await scanQuantityTargets(page);
        if (!best) {
          await page.waitForTimeout(350);
        }
      }
    } catch {}
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

function looksLikeStoreHeading(line, nextLine, nextNextLine) {
  const current = String(line ?? "").trim();
  const next = String(nextLine ?? "").trim();
  const nextNext = String(nextNextLine ?? "").trim();
  if (!current || !next) return false;
  if (current.length > 42) return false;
  if (NOT_STORE_LINE_PATTERNS.some((pattern) => pattern.test(current))) return false;
  if (STORE_SECTION_MARKERS.some((pattern) => pattern.test(current))) return false;
  if (/^(Common Questions|Results for|Skip Navigation|Shop|Recipes|Lists|Browse aisles|Sort|Brands|Current price|Best seller|Great price|Out of stock|Add|Show similar|Carts)$/i.test(current)) {
    return false;
  }
  if (STORE_HINTS.some((hint) => hint.toLowerCase() === current.toLowerCase())) return true;
  if (STORE_SECTION_MARKERS.some((pattern) => pattern.test(next) || pattern.test(nextNext))) return true;
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
    const nextNext = lines[i + 2];
    if (!looksLikeStoreHeading(current, next, nextNext)) continue;

    const start = i;
    let j = i + 1;
    const sectionLines = [current];
    while (j < lines.length) {
      const line = lines[j];
      const lineNext = lines[j + 1];
      const lineNextNext = lines[j + 2];
      if (looksLikeStoreHeading(line, lineNext, lineNextNext) || /^Common Questions$/i.test(line) || /^Carts$/i.test(line)) {
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

async function extractCrossRetailerRecommendations(page, maxStores = 3) {
  return await page.evaluate(({ maxStores }) => {
    const normalize = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
    const parseDistance = (lines) => {
      for (const line of lines) {
        const match = line.match(/(\d+(?:\.\d+)?)\s*km/i);
        if (match) return Number.parseFloat(match[1]);
      }
      return null;
    };

    const looksLikeAddress = (text) => {
      if (!text) return false;
      if (/delivery by|pickup available|show all|search/i.test(text)) return false;
      return /^\d+\s+[a-z0-9]/i.test(text)
        && /(street|st|road|rd|avenue|ave|boulevard|blvd|drive|dr|lane|ln|parkway|pkwy|court|ct|circle|cir|trail|trl|terrace|ter|way)\b/i.test(text);
    };

    const addressCandidates = Array.from(document.querySelectorAll("button, a, div, span"))
      .map((element) => {
        const text = normalize(element.textContent);
        const rect = element.getBoundingClientRect();
        return { text, rect };
      })
      .filter((candidate) =>
        looksLikeAddress(candidate.text)
        && candidate.rect.y >= 0
        && candidate.rect.y < 140
        && candidate.rect.width > 80
      )
      .sort((left, right) =>
        left.rect.y - right.rect.y
        || right.rect.x - left.rect.x
        || left.text.length - right.text.length
      );

    const rows = Array.from(document.querySelectorAll('li[data-testid="CrossRetailerResultRowWrapper"]'));
    const stores = [];
    for (const row of rows) {
      const retailer = row.querySelector('[role="group"][aria-label="retailer"]');
      if (!retailer) continue;
      const logoImage = row.querySelector("img");

      const lines = String(retailer.innerText ?? "")
        .split(/\r?\n+/)
        .map((line) => normalize(line))
        .filter(Boolean);
      if (!lines.length) continue;

      const storeName = lines[0] ?? "";
      const deliveryText = lines.find((line) => /^Delivery by|^Pickup available/i.test(line)) ?? null;
      if (!storeName || !deliveryText) continue;

      const badges = lines.filter((line) =>
        /No markups|Low prices|Lots of deals|Loyalty savings|Groceries|Butcher Shop|Prepared Meals|Organic/i.test(line)
      );

      stores.push({
        storeName,
        deliveryText,
        distanceKm: parseDistance(lines),
        badges: badges.slice(0, 6),
        logoURL: logoImage?.currentSrc || logoImage?.src || null,
        sourceUrl: location.href,
        recommendationRank: stores.length,
      });

      if (stores.length >= maxStores) break;
    }

    return {
      activeAddress: addressCandidates[0]?.text ?? null,
      stores,
    };
  }, { maxStores });
}

async function discoverInstacartStoreOptions({ page, items, cartSummary = null, maxStores = 3, deliveryAddress = null }) {
  const summaryProbeItems = Array.isArray(cartSummary?.probeItems) ? cartSummary.probeItems : [];
  const probeItems = summaryProbeItems.length > 0
    ? summaryProbeItems
    : [...new Map((items ?? []).map((item) => [normalizeItemName(item.name), item]))]
      .map(([, item]) => item)
      .filter((item) => isProbeItemRelevant(item.name))
      .sort((a, b) => probeItemPriority(b) - probeItemPriority(a))
      .slice(0, 8);

  const fallbackProbeItems = [...new Map((items ?? []).map((item) => [normalizeItemName(item.name), item]))]
    .map(([, item]) => item)
    .slice(0, 8);

  const storeStats = new Map();
  const itemsProbed = probeItems.length > 0 ? probeItems : fallbackProbeItems;
  const bootstrapQuery = normalizeItemName(itemsProbed[0]?.name ?? "watermelon");
  const bootstrapSearchUrl = buildSearchUrl(bootstrapQuery);
  await page.goto(bootstrapSearchUrl, { waitUntil: "domcontentloaded", timeout: 30000 });
  await page.waitForTimeout(2200);

  const domRecommendations = await extractCrossRetailerRecommendations(page, maxStores);
  const activeAddress = domRecommendations.activeAddress ?? null;
  const addressMatches = addressesLikelyMatch(activeAddress, deliveryAddress);

  if (domRecommendations.stores.length > 0) {
    const rankedStores = domRecommendations.stores.map((store, index) => {
      const distancePenalty = typeof store.distanceKm === "number" ? store.distanceKm * 3 : 0;
      const liquidityBias = storeLiquidityBias(store.storeName);
      const badgeScore = (store.badges ?? []).reduce((score, badge) => {
        const normalizedBadge = String(badge ?? "").toLowerCase();
        if (normalizedBadge.includes("no markups")) return score + 20;
        if (normalizedBadge.includes("low prices")) return score + 12;
        if (normalizedBadge.includes("lots of deals")) return score + 8;
        if (normalizedBadge.includes("loyalty savings")) return score + 6;
        return score;
      }, 0);

      return {
        ...store,
        matchedCount: 0,
        totalProbes: itemsProbed.length,
        exactMatches: 0,
        coverageRatio: null,
        score: (maxStores - index) * 20 + badgeScore + liquidityBias - distancePenalty,
      };
    });

    return {
      stores: rankedStores.slice(0, maxStores),
      activeAddress,
      addressMatches,
      source: "cross_retailer_dom",
    };
  }

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
    .filter((store) => isLikelyStoreName(store.storeName))
    .map((store) => {
      const coverageRatio = itemsProbed.length > 0 ? store.matchedCount / itemsProbed.length : 0;
      const distancePenalty = typeof store.distanceKm === "number" ? store.distanceKm * 3 : 0;
      const coverageScore = coverageRatio * 1000;
      const matchScore = store.matchedCount * 120 + store.exactMatches * 45;
      const liquidityBias = storeLiquidityBias(store.storeName);
      return {
        ...store,
        score: coverageScore + matchScore + liquidityBias - distancePenalty,
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

  return {
    stores: ranked.slice(0, maxStores),
    activeAddress,
    addressMatches,
    source: "body_text_fallback",
  };
}

function storeLiquidityBias(storeName) {
  const normalized = normalizeStoreKey(storeName);
  if (!normalized) return 0;

  const profiles = [
    ["walmart", 220],
    ["realcanadiansuperstore", 190],
    ["nofrills", 180],
    ["metro", 168],
    ["foodbasics", 164],
    ["freshco", 160],
    ["loblaws", 150],
    ["sobeys", 146],
    ["costco", 142],
    ["shoppersdrugmart", 120],
    ["gianttiger", 110],
    ["wholefoodsmarket", 90],
    ["saveonfoods", 88],
    ["adonis", 76],
    ["coop", 70],
  ];

  for (const [needle, score] of profiles) {
    if (normalized.includes(needle) || needle.includes(normalized)) {
      return score;
    }
  }

  return 0;
}

async function openSelectedStore(page, storeOption, fallbackQuery) {
  if (!storeOption) return null;

  try {
    await page.goto(storeOption.sourceUrl, { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(1800);

    const retailerGroup = page.locator('[role="group"][aria-label="retailer"]').filter({ hasText: storeOption.storeName }).first();
    if (await retailerGroup.count().catch(() => 0)) {
      const storeLink = retailerGroup.locator("a").first();
      if (await storeLink.count().catch(() => 0)) {
        await storeLink.click({ timeout: 5000 });
      } else {
        await retailerGroup.click({ timeout: 5000 });
      }
      await page.waitForTimeout(2200);
      return page.url();
    }

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

async function chooseStoreWithLLM({ storeOptions = [], cartSummary = null, preferredStore = null, strictStore = false, logger = console }) {
  if (!openai || !Array.isArray(storeOptions) || !storeOptions.length) {
    return null;
  }

  const candidateStores = storeOptions.slice(0, 5).map((store, index) => summarizeStoreOptionForLLM(store, index));
  if (!candidateStores.length) return null;

  try {
    const response = await openai.chat.completions.create({
      model: INSTACART_STORE_MODEL,
      ...chatCompletionTemperatureParams(INSTACART_STORE_MODEL),
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "instacart_store_choice",
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              selectedIndex: { type: ["integer", "null"] },
              reason: { type: "string" },
              confidence: { type: "number" },
            },
            required: ["selectedIndex", "reason", "confidence"],
          },
        },
      },
      messages: [
        {
          role: "system",
          content: [
            "You choose which Instacart store should be used for the cart.",
            "Prefer stores with broader and more reliable grocery inventory when the cart is varied or large.",
            "Use probe coverage, exact matches, store breadth, badges, distance, value signals, and cart composition to decide.",
            "For carts with many ingredients and multiple families, broad stores like Walmart or Superstore-style options should get extra weight if they are competitive on coverage.",
            "If two stores are comparably strong on coverage and breadth, prefer the one with better value signals such as no markups, low prices, lots of deals, or loyalty savings.",
            "Do not pay a meaningful price premium for a niche store unless the cart clearly needs the specialty coverage.",
            "If a preferred store is provided, prefer it only when it is still a good fit for the cart.",
            "Return strict JSON only.",
          ].join(" "),
        },
        {
          role: "user",
          content: JSON.stringify({
            cartSummary,
            preferredStore,
            strictStore,
            storeCandidates: candidateStores,
            instructions: "Pick one candidate store by selectedIndex. Explain the choice briefly and concretely, including coverage, breadth, and value.",
          }, null, 2),
        },
      ],
    });

    const parsed = JSON.parse(response.choices?.[0]?.message?.content ?? "{}");
    const selectedIndex = Number.isInteger(parsed.selectedIndex) ? parsed.selectedIndex : null;
    if (selectedIndex == null || selectedIndex < 0 || selectedIndex >= storeOptions.length) {
      return null;
    }

    const selectedStore = storeOptions[selectedIndex] ?? null;
    if (!selectedStore) return null;

    return {
      selectedStore: {
        ...selectedStore,
        reason: String(parsed.reason ?? "").trim() || null,
      },
      reason: truncateText(String(parsed.reason ?? "").trim() || "", 180) || null,
      confidence: Number.isFinite(Number(parsed.confidence ?? NaN)) ? Number(parsed.confidence) : null,
      trace: {
        model: INSTACART_STORE_MODEL,
        selectedIndex,
        candidates: candidateStores,
        reason: String(parsed.reason ?? "").trim() || null,
        confidence: Number.isFinite(Number(parsed.confidence ?? NaN)) ? Number(parsed.confidence) : null,
      },
    };
  } catch (error) {
    logger.warn?.(`[instacart] store-selection LLM failed: ${error.message}`);
    return null;
  }
}

export async function addItemsToInstacartCart({
  items,
  userId = null,
  accessToken = null,
  mealPlanID = null,
  groceryOrderID = null,
  runId: requestedRunID = null,
  deliveryAddress = null,
  preferredStore = null,
  strictStore = false,
  retryContext = null,
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

  const effectiveUserID = String(userId ?? "").trim() || null;
  const session = providerSession ?? await loadProviderSession({
    userId: effectiveUserID,
    provider: "instacart",
    accessToken,
  }) ?? (effectiveUserID ? null : await loadPreferredProviderSession("instacart"));

  if (!session?.cookies?.length) {
    throw new Error("No connected Instacart session found");
  }

  const browser = cdpUrl
    ? await chromium.connectOverCDP(cdpUrl)
    : await chromium.launch(buildPlaywrightLaunchOptions({
        headless,
        args: [
          "--disable-blink-features=AutomationControlled",
        ],
      }));

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
  await context.addInitScript(installCaptchaHooksScript());

  await context.addCookies(cookiesToPlaywright(session.cookies));

  const existingPage = context.pages()[0];
  const page = existingPage ?? await context.newPage();
  const addedItems = [];
  const unresolvedItems = [];
  const confidenceRetryItems = [];
  let storeOptions = [];
  let selectedStore = null;
  const storeUrlCache = new Map();
  const runId = String(requestedRunID ?? "").trim() || [
    new Date().toISOString().replace(/[:.]/g, "-"),
    slugifyTracePart(userId, "anon"),
    slugifyTracePart(preferredStore, "instacart"),
  ].join("__");
  const runTrace = {
    runId,
    startedAt: nowISO(),
    userId: effectiveUserID ?? null,
    mealPlanID: String(mealPlanID ?? "").trim() || null,
    groceryOrderID: String(groceryOrderID ?? "").trim() || null,
    deliveryAddress: deliveryAddress ?? null,
    preferredStore: preferredStore ?? null,
    strictStore: Boolean(strictStore),
    runKind: String(retryContext?.kind ?? "").trim() || "primary",
    rootRunID: String(retryContext?.rootRunID ?? "").trim() || null,
    retryAttempt: Number.isFinite(Number(retryContext?.attempt)) ? Number(retryContext.attempt) : null,
    retryState: null,
    retryQueuedAt: null,
    retryStartedAt: null,
    retryCompletedAt: null,
    retryRunID: null,
    retryItemCount: null,
    selectedStore: null,
    selectedStoreReason: null,
    storeSelectionTrace: null,
    storeOptions: [],
    storeShortlist: [],
    storeDiscoverySource: null,
    activeAddress: null,
    addressMatches: null,
    addressChangeAttempted: false,
    addressChanged: false,
    addressSuggestion: null,
    cartSummary: null,
    items: [],
    events: [],
    sessionSource: session.source,
    cartReset: null,
    finalizer: null,
  };
  let lastProgressPersistAt = 0;

  async function emitRunStartedNotification() {
    if (!userId) return;
    try {
      await createNotificationEvent({
        userId,
        kind: "grocery_cart_ready",
        dedupeKey: `${runId}:started-shopping`,
        title: "Our agents started shopping",
        body: "We’re building your cart now.",
        actionUrl: runTrace.cartUrl ?? null,
        actionLabel: "Open cart",
        metadata: {
          provider: "instacart",
          runId,
          sessionSource: session.source,
          status: "session_started",
        },
      });
    } catch (error) {
      logger.warn?.(`[instacart] shopping-start notification skipped: ${error.message}`);
    }
  }

  async function emitRunEvent(kind, title, body, metadata = {}) {
    const event = {
      at: nowISO(),
      kind,
      title,
      body,
      metadata: metadata && typeof metadata === "object" ? metadata : {},
    };

    runTrace.events = Array.isArray(runTrace.events)
      ? [...runTrace.events, event].slice(-80)
      : [event];
    runTrace.latestEvent = event;
    runTrace.latestEventAt = event.at;
    await persistRunProgress(true);
    await appendRunBackedOrderEvent({
      groceryOrderID: runTrace.groceryOrderID,
      userId,
      runId,
      event,
      cartUrl: runTrace.cartUrl,
    }).catch(() => {});
    return event;
  }

  async function persistRunProgress(force = false) {
    const now = Date.now();
    if (!force && now - lastProgressPersistAt < 4000) {
      return;
    }
    lastProgressPersistAt = now;
    await persistRunTrace(runTrace, { accessToken });
  }

  try {
    logger.log?.(`[instacart] opening store discovery with ${normalizedItems.length} item(s)`);
    await ensureLoggedIn(page).catch(() => {});

    logger.log?.(`[instacart] clearing existing cart before population`);
    runTrace.cartReset = await clearInstacartCart(page, logger);
    logger.log?.(`[instacart] cart reset result: before=${runTrace.cartReset?.beforeCount ?? "?"}, after=${runTrace.cartReset?.afterCount ?? "?"}, cleared=${runTrace.cartReset?.cleared ? "yes" : "no"}`);
    if (!runTrace.cartReset?.cleared) {
      await emitRunEvent(
        "cart_reset_needs_store_check",
        "Cart check needs store verification",
        "The generic Instacart cart could not be verified as empty, so we will verify again after the store is selected.",
        {
          importance: "medium",
          beforeCount: runTrace.cartReset?.beforeCount ?? null,
          afterCount: runTrace.cartReset?.afterCount ?? null,
        }
      );
      logger.warn?.("[instacart] generic cart check was inconclusive; continuing to selected-store cart verification");
    }

    if (runTrace.cartReset?.cleared) {
      await emitRunEvent(
        "cart_cleared",
        "Cart cleared",
        "Instacart cart was reset before the run started.",
        {
          beforeCount: runTrace.cartReset?.beforeCount ?? null,
          afterCount: runTrace.cartReset?.afterCount ?? null,
        }
      );
    }
    await emitRunStartedNotification();

    await page.goto("https://www.instacart.ca/store/s?k=watermelon", { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(2500);
    await maybeSolveCaptcha(page, { logger }).catch((error) => {
      logger.warn?.(`[instacart] captcha solver skipped or failed during store discovery: ${error.message}`);
    });

    const deliveryAddressState = await ensureDeliveryAddress(page, deliveryAddress, logger);
    runTrace.activeAddress = deliveryAddressState.activeAddress ?? null;
    runTrace.addressMatches = deliveryAddressState.addressMatches;
    runTrace.addressChangeAttempted = deliveryAddressState.attempted;
    runTrace.addressChanged = deliveryAddressState.changed;
    runTrace.addressSuggestion = deliveryAddressState.selectedSuggestion ?? null;
    if (deliveryAddressState.attempted) {
      logger.log?.(`[instacart] delivery address sync attempted: changed=${deliveryAddressState.changed ? "yes" : "no"}, active="${deliveryAddressState.activeAddress ?? "unknown"}"`);
    }
    if (deliveryAddressState.addressMatches === false) {
      await emitRunEvent(
        "address_mismatch",
        "Delivery address mismatch",
        "The visible Instacart address did not match the requested delivery address.",
        {
          activeAddress: deliveryAddressState.activeAddress ?? null,
          requestedAddress: deliveryAddress?.line1 ?? null,
        }
      );
      logger.warn?.(`[instacart] visible delivery address "${deliveryAddressState.activeAddress ?? "unknown"}" does not match requested address "${deliveryAddress?.line1 ?? ""}"`);
      throw new Error(`delivery_address_mismatch:${deliveryAddressState.activeAddress ?? "unknown"}`);
    }

    await emitRunEvent(
      "address_synced",
      "Delivery address synced",
      deliveryAddressState.changed
        ? "Instacart switched to the requested delivery address."
        : "Instacart was already on the requested delivery address.",
      {
        activeAddress: deliveryAddressState.activeAddress ?? null,
        changed: Boolean(deliveryAddressState.changed),
      }
    );

    const cartSummary = buildCartSummary(normalizedItems);
    runTrace.cartSummary = cartSummary;

    const storeDiscovery = await discoverInstacartStoreOptions({
      page,
      items: normalizedItems,
      cartSummary,
      maxStores: 5,
      deliveryAddress,
    });
    storeOptions = storeDiscovery.stores;
    runTrace.storeDiscoverySource = storeDiscovery.source ?? null;
    runTrace.activeAddress = storeDiscovery.activeAddress ?? runTrace.activeAddress ?? null;
    runTrace.addressMatches = storeDiscovery.addressMatches;
    if (storeDiscovery.addressMatches === false) {
      logger.warn?.(`[instacart] visible delivery address "${storeDiscovery.activeAddress ?? "unknown"}" does not match requested address "${deliveryAddress?.line1 ?? ""}"`);
      throw new Error(`delivery_address_mismatch:${storeDiscovery.activeAddress ?? "unknown"}`);
    }

    const preferredMatch = choosePreferredStore(storeOptions, preferredStore);
    const llmStoreChoice = strictStore && preferredMatch
      ? {
        selectedStore: preferredMatch,
        reason: summarizeStoreSelectionReason(preferredMatch, storeOptions, cartSummary, "preferred", preferredStore),
        confidence: 1,
        trace: {
          selectedIndex: storeOptions.findIndex((store) => store.storeName === preferredMatch.storeName),
          reason: "strict_store_preference",
          confidence: 1,
          candidates: storeOptions.slice(0, 5).map((store, index) => summarizeStoreOptionForLLM(store, index)),
        },
      }
      : await chooseStoreWithLLM({
        storeOptions,
        cartSummary,
        preferredStore,
        strictStore,
        logger,
      });
    const forcedStore = llmStoreChoice?.selectedStore ?? preferredMatch;
    selectedStore = forcedStore ?? storeOptions[0] ?? null;
    runTrace.storeShortlist = storeOptions.map((store) => ({
      storeName: store.storeName,
      score: Number(store.score ?? 0),
      matchedCount: store.matchedCount,
      totalProbes: store.totalProbes,
      exactMatches: store.exactMatches,
      coverageRatio: store.coverageRatio ?? null,
      distanceKm: store.distanceKm ?? null,
      recommendationRank: store.recommendationRank ?? null,
      badges: Array.isArray(store.badges) ? store.badges.slice(0, 6) : [],
    }));
    logger.log?.(`[instacart] store options: ${storeOptions.map((store) => `${store.storeName} (${store.matchedCount}/${store.totalProbes}, exact=${store.exactMatches})`).join(" | ") || "none"}`);
    logger.log?.(`[instacart] cart summary: items=${cartSummary.totalItems}, families=${cartSummary.uniqueFamilies}, pantry=${cartSummary.pantryStaples}, optional=${cartSummary.optionalItems}, recommendedStores=${cartSummary.recommendedStoreCount}`);
    if (preferredStore && !preferredMatch && !llmStoreChoice) {
      logger.warn?.(`[instacart] preferred store "${preferredStore}" not found in ranked options; using top-ranked fallback`);
    }
    if (selectedStore) {
      logger.log?.(`[instacart] selected store: ${selectedStore.storeName}`);
    }
    const selectedStoreReason = llmStoreChoice?.reason ?? summarizeStoreSelectionReason(selectedStore, storeOptions, cartSummary, preferredMatch ? "preferred" : "heuristic", preferredStore);
    runTrace.selectedStoreReason = selectedStoreReason;
    runTrace.storeSelectionTrace = llmStoreChoice?.trace ?? null;
    await emitRunEvent(
      "store_selected",
      selectedStore ? `Selected ${selectedStore.storeName}` : "Using general Instacart search",
      selectedStore
        ? `Instacart will shop from ${selectedStore.storeName}.`
        : "Instacart will search the general catalog.",
      {
        selectedStore: selectedStore?.storeName ?? null,
        selectedStoreReason,
        recommendedStores: storeOptions.slice(0, 3).map((store) => store.storeName),
      }
    );
    runTrace.selectedStore = isLikelyStoreName(selectedStore?.storeName) ? selectedStore.storeName : null;
    runTrace.selectedStoreLogoURL = selectedStore?.logoURL ?? null;
    runTrace.storeOptions = storeOptions.map((store) => ({
      storeName: store.storeName,
      score: Number(store.score ?? 0),
      matchedCount: store.matchedCount,
      totalProbes: store.totalProbes,
      exactMatches: store.exactMatches,
      coverageRatio: store.coverageRatio ?? null,
      distanceKm: store.distanceKm ?? null,
      recommendationRank: store.recommendationRank ?? null,
      logoURL: store.logoURL ?? null,
      badges: Array.isArray(store.badges) ? store.badges.slice(0, 6) : [],
    }));
    const selectedStoreUrl = selectedStore
      ? await openSelectedStore(page, selectedStore, normalizeItemName(normalizedItems[0]?.name ?? "watermelon"))
      : null;
    if (selectedStore && selectedStoreUrl) {
      storeUrlCache.set(selectedStore.storeName, selectedStoreUrl);
    }
    logger.log?.(`[instacart] clearing selected-store cart before population`);
    runTrace.storeCartReset = await clearInstacartCart(page, logger, { preferCurrentPage: true });
    logger.log?.(`[instacart] selected-store cart reset result: before=${runTrace.storeCartReset?.beforeCount ?? "?"}, after=${runTrace.storeCartReset?.afterCount ?? "?"}, cleared=${runTrace.storeCartReset?.cleared ? "yes" : "no"}`);
    if (!runTrace.storeCartReset?.cleared) {
      const queuedAt = nowISO();
      runTrace.retryState = "queued";
      runTrace.retryQueuedAt = queuedAt;
      runTrace.retryItemCount = normalizedItems.length;
      await emitRunEvent(
        "cart_reset_blocked",
        "Selected store cart must be cleared",
        "We could not fully empty the selected store cart before adding items.",
        {
          importance: "high",
          beforeCount: runTrace.storeCartReset?.beforeCount ?? null,
          afterCount: runTrace.storeCartReset?.afterCount ?? null,
        }
      );
      await emitRunEvent(
        "retry_queued",
        "Queued after cart clear",
        "We queued this run to restart after the selected store cart is fully cleared.",
        {
          reason: "awaiting_cart_clear",
          retryItemCount: normalizedItems.length,
          beforeCount: runTrace.storeCartReset?.beforeCount ?? null,
          afterCount: runTrace.storeCartReset?.afterCount ?? null,
        }
      );
      if (userId) {
        await createNotificationEvent({
          userId,
          kind: "grocery_issue",
          dedupeKey: `${runId}:selected-store-cart-reset-blocked`,
          title: "Queued after cart clear",
          body: "The chosen store cart still has items, so this run is queued until the cart is cleared.",
          actionUrl: runTrace.cartUrl ?? null,
          actionLabel: "Open cart",
          metadata: {
            provider: "instacart",
            runId,
            importance: "high",
            reason: "awaiting_cart_clear",
            beforeCount: runTrace.storeCartReset?.beforeCount ?? null,
            afterCount: runTrace.storeCartReset?.afterCount ?? null,
          },
        }).catch((error) => {
          logger.warn?.(`[instacart] selected-store cart reset notification skipped: ${error.message}`);
        });
      }
      throw new Error(`selected_store_cart_not_cleared_queued${runTrace.storeCartReset?.afterCount != null ? `:${runTrace.storeCartReset.afterCount}` : ""}`);
    }
    await emitRunEvent(
      "cart_cleared",
      "Selected store cart cleared",
      "Instacart cart was reset after the store was selected.",
      {
        beforeCount: runTrace.storeCartReset?.beforeCount ?? null,
        afterCount: runTrace.storeCartReset?.afterCount ?? null,
      }
    );
    await persistRunProgress(true);

    const itemTracesByKey = new Map();
    const processItem = async (item, { retryRound = 1 } = {}) => {
      const query = normalizeItemName(item.name);
      const targetQuantity = Math.max(1, Math.ceil(Number(item.amount ?? 1)));
      const traceKey = normalizeItemName(item.originalName ?? item.name);
      const itemTrace = itemTracesByKey.get(traceKey) ?? {
        requested: item.originalName ?? item.name,
        canonicalName: item.shoppingContext?.canonicalName ?? item.name,
        normalizedQuery: query,
        quantityRequested: targetQuantity,
        shoppingContext: item.shoppingContext ? {
          familyKey: item.shoppingContext.familyKey ?? item.shoppingContext.canonicalName ?? null,
          role: item.shoppingContext.role ?? null,
          exactness: item.shoppingContext.exactness ?? null,
          substitutionPolicy: item.shoppingContext.substitutionPolicy ?? null,
          preferredForms: item.shoppingContext.preferredForms ?? [],
          avoidForms: item.shoppingContext.avoidForms ?? [],
          requiredDescriptors: item.shoppingContext.requiredDescriptors ?? [],
          fallbackSearchQuery: item.shoppingContext.fallbackSearchQuery ?? null,
          alternateQueries: item.shoppingContext.alternateQueries ?? [],
          quantityStrategy: item.shoppingContext.quantityStrategy ?? null,
          minimumContainedQuantity: item.shoppingContext.minimumContainedQuantity ?? null,
          desiredPackageCount: item.shoppingContext.desiredPackageCount ?? null,
        } : null,
        attempts: [],
        quantityEvents: [],
        finalStatus: null,
        retryRound,
      };
      itemTrace.retryRound = Math.max(Number(itemTrace.retryRound ?? 1), retryRound);
      itemTracesByKey.set(traceKey, itemTrace);

      let attemptLimitHit = false;
      let attemptsThisPass = 0;
      logger.log?.(`[instacart] searching "${item.originalName ?? item.name}" -> "${query}" (qty=${targetQuantity})${retryRound > 1 ? ` [retry ${retryRound}]` : ""}`);
      const queryVariants = buildQueryVariants(query, item);
      const shortlistStores = storeOptions.slice(0, Math.max(2, Math.min(3, storeOptions.length)));
      const storeAttempts = selectedStore
        ? (strictStore
          ? [selectedStore]
          : [selectedStore, ...shortlistStores.filter((store) => store.storeName !== selectedStore.storeName)])
        : [];
      const searchAttempts = [
        ...storeAttempts.map((store) => ({ store, generalSearch: false })),
        { store: null, generalSearch: true },
      ];
      let activeQuery = queryVariants[0];
      let added = null;
      let matchedStore = selectedStore?.storeName ?? null;

      for (const attemptPlan of searchAttempts) {
        const storeAttempt = attemptPlan.store;
        let activeStoreUrl = null;
        if (storeAttempt && !attemptPlan.generalSearch) {
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
          await maybeSolveCaptcha(page, { logger }).catch((error) => {
            logger.warn?.(`[instacart] captcha solver skipped or failed during item search: ${error.message}`);
          });

          const attemptNumber = itemTrace.attempts.length + 1;
          const searchScreenshotArtifact = await captureRunPageArtifact(
            page,
            runTrace.runId,
            buildItemAttemptArtifactName({
              itemName: item.originalName ?? item.name,
              retryRound,
              stage: "search",
              attemptIndex: attemptNumber,
            }),
            logger,
            { fullPage: false }
          );

          added = await tryAddButton(page, item, activeQuery, logger, {
            searchMode: retryRound > 1 ? "broad" : "initial",
            runId: runTrace.runId,
            selectionArtifactName: buildItemAttemptArtifactName({
              itemName: item.originalName ?? item.name,
              retryRound,
              stage: "selection",
              attemptIndex: attemptNumber,
            }),
          });
          itemTrace.attempts.push({
            at: nowISO(),
            store: attemptPlan.generalSearch ? "__general_search__" : (storeAttempt?.storeName ?? selectedStore?.storeName ?? null),
            query: activeQuery,
            searchUrl,
            success: Boolean(added.success),
            matchedLabel: added.matchedLabel ?? null,
            decision: added.decision ?? null,
            matchType: added.matchType ?? null,
            refinedQuery: added.refinedQuery ?? null,
            reason: added.llmReason ?? null,
            searchScreenshotArtifact,
            selectionScreenshotArtifact: added.selectionTrace?.selectionScreenshotArtifact ?? null,
            selectionTrace: added.selectionTrace ?? null,
          });
          attemptsThisPass += 1;
          if (attemptsThisPass >= MAX_ITEM_ATTEMPTS) {
            attemptLimitHit = true;
            added = {
              success: false,
              decision: "attempt_limit_reached",
              matchType: "retry_limit",
              llmReason: `Skipped after ${MAX_ITEM_ATTEMPTS} item attempts.`,
              refinedQuery: null,
            };
            logger.warn?.(`[instacart] skipping "${item.originalName ?? item.name}" after ${MAX_ITEM_ATTEMPTS} attempts`);
            break;
          }
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

        if (attemptLimitHit) break;
        if (added?.success) break;
        if (attemptPlan.generalSearch) {
          logger.warn?.(`[instacart] no safe match for "${item.originalName ?? item.name}" in general Instacart search`);
        } else if (storeAttempt && storeAttempts.length > 1) {
          logger.warn?.(`[instacart] no safe match for "${item.originalName ?? item.name}" at ${storeAttempt.storeName}; trying another store`);
        }
      }

      if (!added.success) {
        if (added.decision === "retry_queued") {
          logger.warn?.(`[instacart] low-confidence pick for "${item.originalName ?? item.name}" will be retried broadly`);
          const retryQueued = {
            requested: item.originalName ?? item.name,
            normalizedQuery: query,
            quantityRequested: targetQuantity,
            quantityAdded: 0,
            quantity: item.amount,
            status: "retry_queued",
            decision: added.decision ?? "retry_queued",
            matchType: added.matchType ?? "low_confidence",
            needsReview: true,
            reason: added.llmReason ?? "initial_confidence_below_cutoff",
            confidence: Number(added.llmConfidence ?? 0) || null,
            refinedQuery: added.refinedQuery ?? null,
            matchedStore,
            trace: itemTrace,
          };
          itemTrace.finalStatus = {
            status: "retry_queued",
            matchedStore,
            decision: added.decision ?? "retry_queued",
            matchType: added.matchType ?? "low_confidence",
            retryQueued: true,
            retryMode: "broad",
            confidence: Number(added.llmConfidence ?? 0) || null,
            reason: added.llmReason ?? "initial_confidence_below_cutoff",
          };
          itemTrace.attempts.push({
            at: nowISO(),
            store: matchedStore,
            query,
            searchUrl: null,
            success: false,
            matchedLabel: added.matchedLabel ?? null,
            decision: added.decision ?? "retry_queued",
            matchType: added.matchType ?? "low_confidence",
            refinedQuery: added.refinedQuery ?? null,
            reason: added.llmReason ?? "initial_confidence_below_cutoff",
            selectionTrace: added.selectionTrace ?? null,
          });
          if (retryRound <= 1) {
            runTrace.items.push(itemTrace);
            confidenceRetryItems.push({
              ...item,
              broadRetryReason: added.llmReason ?? "initial_confidence_below_cutoff",
            });
          } else {
            const traceIndex = runTrace.items.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.normalizedQuery ?? "") === traceKey);
            if (traceIndex >= 0) {
              runTrace.items[traceIndex] = itemTrace;
            } else {
              runTrace.items.push(itemTrace);
            }
          }
          await emitRunEvent(
            "item_retry_queued",
            `Queued broader retry for ${item.originalName ?? item.name}`,
            `We picked a candidate from the first three results, but the confidence was too low. This item will be retried in a broader pass.`,
            {
              item: item.originalName ?? item.name,
              confidence: added.llmConfidence ?? null,
              confidenceCutoff: INITIAL_SELECTION_CONFIDENCE_CUTOFF,
              matchedStore,
              retryRound,
            }
          );
          await persistRunProgress();
          return { status: retryQueued.status, itemTrace, resolved: retryQueued };
        }

        let failedItemReview = await adjudicateFailedItemBeforeTracking({
          page,
          item,
          query,
          added,
          targetQuantity,
          attemptLimitHit,
          logger,
        });

        const adjudicatedRetryQuery = normalizeItemName(failedItemReview.retryQuery ?? "");
        const alreadyTriedAdjudicatedQuery = adjudicatedRetryQuery
          ? itemTrace.attempts.some((attempt) => normalizeItemName(attempt?.query ?? "") === adjudicatedRetryQuery)
          : false;

        if (
          failedItemReview.verdict === "retry_recommended"
          && adjudicatedRetryQuery
          && !attemptLimitHit
          && !alreadyTriedAdjudicatedQuery
        ) {
          logger.log?.(`[instacart] adjudicated retry for "${item.originalName ?? item.name}" -> "${adjudicatedRetryQuery}"`);
          const searchUrl = buildStoreSearchUrl(null, adjudicatedRetryQuery);
          await page.goto(searchUrl, { waitUntil: "domcontentloaded", timeout: 30000 });
          await page.waitForTimeout(2500);
          await maybeSolveCaptcha(page, { logger }).catch((error) => {
            logger.warn?.(`[instacart] captcha solver skipped or failed during adjudicated retry: ${error.message}`);
          });
          const adjudicatedRetry = await tryAddButton(page, item, adjudicatedRetryQuery, logger, {
            searchMode: "broad",
          });
          itemTrace.attempts.push({
            at: nowISO(),
            store: "__adjudicated_retry__",
            query: adjudicatedRetryQuery,
            searchUrl,
            success: Boolean(adjudicatedRetry.success),
            matchedLabel: adjudicatedRetry.matchedLabel ?? null,
            decision: adjudicatedRetry.decision ?? null,
            matchType: adjudicatedRetry.matchType ?? null,
            refinedQuery: adjudicatedRetry.refinedQuery ?? null,
            reason: adjudicatedRetry.llmReason ?? failedItemReview.summary,
            selectionTrace: adjudicatedRetry.selectionTrace ?? null,
          });
          if (adjudicatedRetry.success) {
            added = adjudicatedRetry;
            matchedStore = selectedStore?.storeName ?? matchedStore;
          } else {
            added = adjudicatedRetry;
            failedItemReview = {
              ...failedItemReview,
              summary: truncateText(
                String(adjudicatedRetry.llmReason ?? failedItemReview.summary ?? "").trim(),
                220,
              ) || failedItemReview.summary,
              reasons: normalizeFailureReasonList([
                ...(failedItemReview.reasons ?? []),
                adjudicatedRetry.llmReason,
              ]),
            };
          }
        }

        if (failedItemReview.shouldAccept && failedItemReview.acceptedCandidate && (
          targetQuantity <= 1 || String(item?.shoppingContext?.quantityStrategy ?? "").trim().toLowerCase() === "single_package_minimum_count"
        )) {
          const acceptedStatus = failedItemReview.correctedStatus === "substituted" ? "substituted" : "exact";
          const resolved = {
            requested: item.originalName ?? item.name,
            normalizedQuery: query,
            matched: extractCandidateTitle(
              failedItemReview.acceptedCandidate.title,
              failedItemReview.acceptedCandidate.rawLabel,
              failedItemReview.acceptedCandidate.cardText,
            ) || failedItemReview.acceptedCandidate.title || failedItemReview.acceptedCandidate.rawLabel || item.name,
            quantityRequested: targetQuantity,
            quantityAdded: targetQuantity,
            quantity: item.amount,
            status: acceptedStatus,
            score: Number.isFinite(Number(failedItemReview.acceptedCandidate.score ?? NaN))
              ? Number(failedItemReview.acceptedCandidate.score)
              : null,
            shortfall: 0,
            llmChoice: Boolean(added.llmChoice),
            llmConfidence: added.llmConfidence ?? failedItemReview.confidence ?? null,
            llmReason: failedItemReview.summary,
            refinedQuery: failedItemReview.retryQuery ?? added.refinedQuery ?? null,
            matchedStore,
            decision: "failed_item_review_accept",
            matchType: acceptedStatus === "substituted" ? "close_substitute" : "exact",
            needsReview: false,
            substituteReason: acceptedStatus === "substituted" ? failedItemReview.summary : null,
            trace: itemTrace,
            failureReview: failedItemReview,
          };
          itemTrace.finalStatus = {
            status: acceptedStatus,
            matchedStore,
            decision: "failed_item_review_accept",
            matchType: acceptedStatus === "substituted" ? "close_substitute" : "exact",
            quantityAdded: targetQuantity,
            shortfall: 0,
            failureVerdict: failedItemReview.verdict,
            failureSummary: failedItemReview.summary,
            failureReasons: failedItemReview.reasons,
            approachChange: failedItemReview.approachChange,
            failureReviewModel: failedItemReview.model ?? null,
          };

          if (retryRound > 1) {
            const unresolvedIndex = unresolvedItems.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.name ?? "") === traceKey);
            if (unresolvedIndex >= 0) {
              unresolvedItems.splice(unresolvedIndex, 1);
            }
            const addedIndex = addedItems.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.name ?? "") === traceKey);
            if (addedIndex >= 0) {
              addedItems[addedIndex] = resolved;
            } else {
              addedItems.push(resolved);
            }
            const traceIndex = runTrace.items.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.normalizedQuery ?? "") === traceKey);
            if (traceIndex >= 0) {
              runTrace.items[traceIndex] = itemTrace;
            } else {
              runTrace.items.push(itemTrace);
            }
          } else {
            runTrace.items.push(itemTrace);
            addedItems.push(resolved);
          }

          await emitRunEvent(
            "item_review_corrected",
            `Kept ${item.originalName ?? item.name}`,
            failedItemReview.summary,
            {
              item: item.originalName ?? item.name,
              matchedStore,
              retryRound,
            }
          );
          await persistRunProgress();
          await page.waitForTimeout(800);
          return { status: resolved.status, itemTrace, resolved };
        }

        if (!added.success) {
          logger.warn?.(`[instacart] unresolved "${item.originalName ?? item.name}" (decision=${added.decision ?? "reject"}, refinedQuery=${added.refinedQuery ?? "none"})`);
          const unresolvedEventBody = attemptLimitHit
            ? "We skipped a stubborn match and kept shopping the rest."
            : (failedItemReview.summary ?? added.llmReason ?? added.substituteReason ?? "Instacart could not find a safe match.");
          await emitRunEvent(
            "item_unresolved",
            `Couldn’t place ${item.originalName ?? item.name}`,
            unresolvedEventBody,
            {
              item: item.originalName ?? item.name,
              refinedQuery: failedItemReview.retryQuery ?? added.refinedQuery ?? null,
              matchedStore,
              attemptLimitHit,
              retryRound,
              failureVerdict: failedItemReview.verdict ?? null,
            }
          );
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
            reason: failedItemReview.summary ?? added.llmReason ?? null,
            failureReasons: failedItemReview.reasons ?? [],
            approachChange: failedItemReview.approachChange ?? null,
            failureVerdict: failedItemReview.verdict ?? null,
            failureReviewModel: failedItemReview.model ?? null,
            substituteReason: added.substituteReason ?? null,
            refinedQuery: failedItemReview.retryQuery ?? added.refinedQuery ?? null,
            attemptLimitHit,
            matchedStore,
            trace: itemTrace,
          };
          itemTrace.finalStatus = {
            status: "unresolved",
            matchedStore,
            decision: added.decision ?? "reject",
            matchType: added.matchType ?? "unsafe",
            attemptLimitHit,
            failureVerdict: failedItemReview.verdict ?? null,
            failureSummary: failedItemReview.summary ?? added.llmReason ?? null,
            failureReasons: failedItemReview.reasons ?? [],
            approachChange: failedItemReview.approachChange ?? null,
            failureReviewModel: failedItemReview.model ?? null,
          };
          if (retryRound <= 1) {
            runTrace.items.push(itemTrace);
            addedItems.push(unresolved);
            unresolvedItems.push(unresolved);
          } else {
            const unresolvedIndex = unresolvedItems.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.name ?? "") === traceKey);
            if (unresolvedIndex >= 0) {
              unresolvedItems[unresolvedIndex] = unresolved;
            } else {
              unresolvedItems.push(unresolved);
            }

            const addedIndex = addedItems.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.name ?? "") === traceKey);
            if (addedIndex >= 0) {
              addedItems[addedIndex] = unresolved;
            } else {
              addedItems.push(unresolved);
            }

            const traceIndex = runTrace.items.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.normalizedQuery ?? "") === traceKey);
            if (traceIndex >= 0) {
              runTrace.items[traceIndex] = itemTrace;
            } else {
              runTrace.items.push(itemTrace);
            }
          }
          await persistRunProgress();
          await page.waitForTimeout(800);
          return { status: "unresolved", itemTrace, unresolved };
        }
      }

      let quantityAdded = 1;
      await page.waitForTimeout(1400);
      while (quantityAdded < targetQuantity) {
        let increased = { success: false };
        for (let attempt = 0; attempt < 3; attempt += 1) {
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

      const resolved = {
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
      };
      itemTrace.finalStatus = {
        status: (added.decision ?? "exact_match") === "substitute" ? "substituted" : "exact",
        matchedStore,
        decision: added.decision ?? "exact_match",
        matchType: added.matchType ?? "exact",
        quantityAdded,
        shortfall: Math.max(0, targetQuantity - quantityAdded),
      };

      if (retryRound > 1) {
        const unresolvedIndex = unresolvedItems.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.name ?? "") === traceKey);
        if (unresolvedIndex >= 0) {
          unresolvedItems.splice(unresolvedIndex, 1);
        }
        const addedIndex = addedItems.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.name ?? "") === traceKey);
        if (addedIndex >= 0) {
          addedItems.splice(addedIndex, 1);
        }
        const traceIndex = runTrace.items.findIndex((entry) => normalizeItemName(entry.requested ?? entry.canonicalName ?? entry.normalizedQuery ?? "") === traceKey);
        if (traceIndex >= 0) {
          runTrace.items[traceIndex] = itemTrace;
        } else {
          runTrace.items.push(itemTrace);
        }
      } else {
        runTrace.items.push(itemTrace);
      }

      addedItems.push(resolved);
      logger.log?.(`[instacart] added "${item.originalName ?? item.name}" -> matched "${added.matchedLabel ?? item.name}" @ ${matchedStore ?? "default store"} (decision=${added.decision ?? "exact_match"}, matchType=${added.matchType ?? "exact"}, score=${added.score}, qty=${quantityAdded}/${targetQuantity}, llm=${added.llmChoice ? "yes" : "no"})`);
      await persistRunProgress();

      await page.waitForTimeout(1500);
      return { status: resolved.status, itemTrace, resolved };
    };

    for (const item of normalizedItems) {
      await processItem(item, { retryRound: 1 });
    }

      const retryQueue = [...confidenceRetryItems, ...unresolvedItems]
      .slice()
      .map((entry) => {
        const requested = String(entry?.requested ?? entry?.canonicalName ?? "").trim();
        if (!requested) return null;
        return normalizedItems.find((item) => normalizeItemName(item.originalName ?? item.name) === normalizeItemName(requested)) ?? null;
      })
      .filter(Boolean);

    if (retryQueue.length > 0) {
      runTrace.retryQueue = retryQueue.map((item) => ({
        requested: item.originalName ?? item.name,
        normalizedQuery: normalizeItemName(item.originalName ?? item.name),
        quantityRequested: Math.max(1, Math.ceil(Number(item.amount ?? 1))),
      }));
      await persistRunProgress();
      await emitRunEvent(
        "retry_queue_started",
        "Retrying unresolved items",
        `We queued ${retryQueue.length} unresolved item(s) for one more pass.`,
        {
          retryCount: retryQueue.length,
        }
      );

      for (const item of retryQueue) {
        await processItem(item, { retryRound: 2 });
      }
    }

    await page.goto("https://www.instacart.ca/store/cart", { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(2500);
    await maybeSolveCaptcha(page, { logger }).catch((error) => {
      logger.warn?.(`[instacart] captcha solver skipped or failed during cart page: ${error.message}`);
    });
    logger.log?.(`[instacart] cart page ready: ${page.url()}`);
    runTrace.finalizer = await finalizeInstacartCartRun({
      page,
      runTrace,
      addedItems,
      unresolvedItems,
      logger,
      cartSummary,
    });
    logger.log?.(`[instacart] finalizer result: status=${runTrace.finalizer?.status ?? "unknown"}, issues=${summarizeFinalizerIssues(runTrace.finalizer)}, canCheckout=${runTrace.finalizer?.canCheckout ? "yes" : "no"}`);
    if (runTrace.finalizer?.topIssue) {
      logger.warn?.(`[instacart] finalizer top issue: ${runTrace.finalizer.topIssue}`);
    }
    await emitRunEvent(
      runTrace.finalizer?.canCheckout ? "checkout_ready" : "finalizer_review",
      runTrace.finalizer?.canCheckout ? "Cart is ready" : "Cart needs another look",
      runTrace.finalizer?.summary ?? runTrace.finalizer?.topIssue ?? "The cart has been finalized.",
      {
        canCheckout: Boolean(runTrace.finalizer?.canCheckout),
        status: runTrace.finalizer?.status ?? null,
        retryRecommendation: runTrace.finalizer?.retryRecommendation ?? null,
      }
    );
    runTrace.warden = await adjudicateInstacartRunWithWarden({
      page,
      runTrace,
      addedItems,
      unresolvedItems,
      finalizer: runTrace.finalizer,
      logger,
    });
    const correctedItems = Array.isArray(runTrace.warden?.correctedItems) ? runTrace.warden.correctedItems : [];
    for (const correction of correctedItems) {
      const normalized = normalizeRunItemKey(correction?.name);
      if (!normalized) continue;
      const unresolvedIndex = unresolvedItems.findIndex((entry) => (
        normalizeRunItemKey(entry?.requested ?? entry?.canonicalName ?? entry?.name) === normalized
      ));
      if (unresolvedIndex >= 0) {
        const unresolved = unresolvedItems[unresolvedIndex];
        const quantityRequested = Math.max(1, Math.ceil(Number(unresolved?.quantityRequested ?? unresolved?.quantity ?? 1)));
        const resolved = {
          ...unresolved,
          matched: String(correction?.matched ?? "").trim() || unresolved?.matched || unresolved?.requested || unresolved?.canonicalName || null,
          quantityAdded: quantityRequested,
          status: "exact",
          shortfall: 0,
          needsReview: false,
          reason: String(correction?.reason ?? "").trim() || unresolved?.reason || null,
          wardenVerified: true,
        };
        unresolvedItems.splice(unresolvedIndex, 1);
        const addedIndex = addedItems.findIndex((entry) => (
          normalizeRunItemKey(entry?.requested ?? entry?.canonicalName ?? entry?.name) === normalized
        ));
        if (addedIndex >= 0) {
          addedItems[addedIndex] = resolved;
        } else {
          addedItems.push(resolved);
        }
        const traceItem = findRunTraceItem(runTrace, correction?.name);
        if (traceItem) {
          traceItem.finalStatus = {
            ...(traceItem.finalStatus ?? {}),
            status: "exact",
            decision: "warden_verified",
            matchType: "warden_verified",
            quantityAdded: quantityRequested,
            shortfall: 0,
          };
        }
      }
    }
    const fullyCorrectedRun = isFullyCorrectedRun({
      runTrace,
      unresolvedItems,
      correctedItems,
    });
    if (fullyCorrectedRun) {
      runTrace.warden = {
        ...(runTrace.warden ?? {}),
        status: "ready",
        retryRecommendation: "none",
        notes: Array.isArray(runTrace.warden?.notes) ? runTrace.warden.notes : [],
      };
      if (runTrace.finalizer) {
        runTrace.finalizer = {
          ...(runTrace.finalizer ?? {}),
          status: "ready",
          retryRecommendation: "none",
        };
      }
    }
    await emitRunEvent(
      "warden_review",
      "Mapping review finished",
      runTrace.warden?.overallSummary ?? "We reviewed the product matches.",
      {
        status: runTrace.warden?.status ?? null,
        mappingScore: runTrace.warden?.mappingScore ?? null,
        retryRecommendation: runTrace.warden?.retryRecommendation ?? null,
        correctedItemCount: correctedItems.length,
      }
    );
    runTrace.completedAt = nowISO();
    runTrace.cartUrl = page.url();
    const finalizerHasIssues = summarizeFinalizerIssues(runTrace.finalizer) > 0 || String(runTrace.finalizer?.status ?? "").trim() !== "ready";
    const finalizerRetryRecommendation = String(runTrace.finalizer?.retryRecommendation ?? "").trim().toLowerCase();
    const finalizerRequiresFullRerun = finalizerRetryRecommendation === "rerun_full_cart";
    const wardenStatus = normalizedWardenStatus(runTrace.warden?.status ?? "");
    const wardenRetryRecommendation = String(runTrace.warden?.retryRecommendation ?? "").trim().toLowerCase();
    const reviewerHasIssues = runTrace.warden
      ? !reviewerStatusCountsAsReady(runTrace.warden?.status)
      : finalizerHasIssues;
    const reviewerRequiresFullRerun = runTrace.warden
      ? (wardenRetryRecommendation === "rerun_full_cart" && !fullyCorrectedRun)
      : finalizerRequiresFullRerun;
    const hasMeaningfulAddedItems = addedItems.some((item) => {
      const status = String(item?.status ?? "").trim().toLowerCase();
      const quantityAdded = Number(item?.quantityAdded ?? 0);
      return ["exact", "substituted", "saved", "done", "completed"].includes(status) || quantityAdded > 0;
    });
    runTrace.success = unresolvedItems.length === 0 && !reviewerHasIssues;
    runTrace.partialSuccess = !runTrace.success && (
      hasMeaningfulAddedItems
      || wardenRetryRecommendation === "retry_items_only"
      || finalizerRetryRecommendation === "retry_items_only"
      || unresolvedItems.length > 0
      || (reviewerHasIssues && !reviewerRequiresFullRerun)
    );
    const traceArtifact = await persistRunTrace(runTrace, { accessToken });

    return {
      success: runTrace.success,
      partialSuccess: runTrace.partialSuccess,
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
    const queuedAfterCartClear = runTrace.retryState === "queued" && /selected_store_cart_not_cleared_queued/i.test(error.message);
    if (!queuedAfterCartClear) {
      try {
        await emitRunEvent(
          "run_failed",
          "Instacart run failed",
          error.message,
          {
            error: error.message,
          }
        );
      } catch {}
    }
    runTrace.completedAt = nowISO();
    runTrace.success = false;
    runTrace.partialSuccess = Boolean(queuedAfterCartClear);
    runTrace.error = error.message;
    runTrace.storeOptions = runTrace.storeOptions.length ? runTrace.storeOptions : storeOptions.map((store) => ({
      storeName: store.storeName,
      score: Number(store.score ?? 0),
      matchedCount: store.matchedCount,
      totalProbes: store.totalProbes,
      exactMatches: store.exactMatches,
      coverageRatio: store.coverageRatio ?? null,
      distanceKm: store.distanceKm ?? null,
      logoURL: store.logoURL ?? null,
    }));
    const traceArtifact = await persistRunTrace(runTrace, { accessToken });
    return {
      success: false,
      partialSuccess: Boolean(queuedAfterCartClear),
      error: error.message,
      addedItems,
      unresolvedItems,
      cartUrl: page.url(),
      sessionSource: session.source,
      storeOptions,
      selectedStore,
      retryState: runTrace.retryState,
      retryQueuedAt: runTrace.retryQueuedAt,
      retryItemCount: runTrace.retryItemCount,
      queueReason: queuedAfterCartClear ? "awaiting_cart_clear" : null,
      runId,
      traceArtifact,
    };
  } finally {
    await browser.close().catch(() => {});
  }
}

export async function runInstacartWardenForExistingRun({
  runId,
  userId = null,
  accessToken = null,
  headless = true,
  cdpUrl = null,
  providerSession = null,
  logger = console,
}) {
  const normalizedRunID = String(runId ?? "").trim();
  if (!normalizedRunID) {
    throw new Error("runId is required");
  }

  const tracePayload = await getInstacartRunLogTrace(normalizedRunID, {
    userID: String(userId ?? "").trim() || null,
    accessToken,
  });
  if (!tracePayload?.trace) {
    throw new Error(`Run trace not found for ${normalizedRunID}`);
  }

  const runTrace = tracePayload.trace;
  const savedCartScreenshotArtifactPath = String(
    runTrace?.finalizer?.cartScreenshotArtifact?.path
      ?? runTrace?.finalizer?.cartScreenshotArtifact
      ?? runTrace?.finalizer?.cartScreenshotPath
      ?? ""
  ).trim() || null;
  const savedCartScreenshotDataURL = savedCartScreenshotArtifactPath
    ? await readImageArtifactAsDataURL(savedCartScreenshotArtifactPath)
    : null;
  const savedCartSnapshot = runTrace?.finalizer?.cartSnapshot ?? null;
  const effectiveUserID = String(userId ?? runTrace?.userId ?? "").trim() || null;
  const session = providerSession ?? await loadProviderSession({
    userId: effectiveUserID,
    provider: "instacart",
    accessToken,
  }) ?? (effectiveUserID ? null : await loadPreferredProviderSession("instacart"));

  if (!savedCartScreenshotDataURL && !session?.cookies?.length) {
    throw new Error("No connected Instacart session found");
  }
  let browser = null;
  let page = null;

  if (!savedCartScreenshotDataURL) {
    browser = cdpUrl
      ? await chromium.connectOverCDP(cdpUrl)
      : await chromium.launch(buildPlaywrightLaunchOptions({
          headless,
          args: [
            "--disable-blink-features=AutomationControlled",
          ],
        }));

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
    await context.addInitScript(installCaptchaHooksScript());
    await context.addCookies(cookiesToPlaywright(session.cookies));

    const existingPage = context.pages()[0];
    page = existingPage ?? await context.newPage();
  }

  try {
    if (page) {
      await page.goto(String(runTrace?.cartUrl ?? "https://www.instacart.ca/store/cart"), {
        waitUntil: "domcontentloaded",
        timeout: 30000,
      });
      await page.waitForTimeout(2500);
      await maybeSolveCaptcha(page, { logger }).catch(() => {});
    }

    const addedItems = [];
    const unresolvedItems = [];
    for (const item of Array.isArray(runTrace?.items) ? runTrace.items : []) {
      const finalStatus = item?.finalStatus ?? null;
      const requested = item?.requested ?? item?.canonicalName ?? item?.normalizedQuery ?? null;
      const quantityRequested = Math.max(1, Math.ceil(Number(item?.quantityRequested ?? 1)));
      const status = String(finalStatus?.status ?? "").trim().toLowerCase();
      const shortfall = Math.max(0, Number(finalStatus?.shortfall ?? 0));
      const selectedCandidate = latestSelectedCandidateForTraceItem(item);
      if (status === "unresolved" || shortfall > 0) {
        unresolvedItems.push({
          requested,
          canonicalName: item?.canonicalName ?? null,
          normalizedQuery: item?.normalizedQuery ?? null,
          quantityRequested,
          quantityAdded: Math.max(0, Number(finalStatus?.quantityAdded ?? 0)),
          status: "unresolved",
          reason: item?.attempts?.slice(-1)?.[0]?.reason ?? null,
          trace: item,
        });
        continue;
      }
      if (["exact", "substituted"].includes(status) || Number(finalStatus?.quantityAdded ?? 0) > 0) {
        addedItems.push({
          requested,
          canonicalName: item?.canonicalName ?? null,
          normalizedQuery: item?.normalizedQuery ?? null,
          matched: selectedCandidate?.title ?? selectedCandidate?.rawLabel ?? requested,
          quantityRequested,
          quantityAdded: Math.max(1, Number(finalStatus?.quantityAdded ?? quantityRequested)),
          status: status || "exact",
          shortfall,
          trace: item,
        });
      }
    }

    runTrace.warden = await adjudicateInstacartRunWithWarden({
      page,
      runTrace,
      addedItems,
      unresolvedItems,
      finalizer: runTrace.finalizer ?? null,
      logger,
      cartSnapshotOverride: savedCartSnapshot,
      cartScreenshotDataURLOverride: savedCartScreenshotDataURL,
    });

    const correctedItems = Array.isArray(runTrace.warden?.correctedItems) ? runTrace.warden.correctedItems : [];
    for (const correction of correctedItems) {
      const normalized = normalizeRunItemKey(correction?.name);
      if (!normalized) continue;
      const unresolvedIndex = unresolvedItems.findIndex((entry) => (
        normalizeRunItemKey(entry?.requested ?? entry?.canonicalName ?? entry?.name) === normalized
      ));
      if (unresolvedIndex < 0) continue;
      const unresolved = unresolvedItems[unresolvedIndex];
      const quantityRequested = Math.max(1, Math.ceil(Number(unresolved?.quantityRequested ?? 1)));
      unresolvedItems.splice(unresolvedIndex, 1);
      addedItems.push({
        ...unresolved,
        matched: String(correction?.matched ?? "").trim() || unresolved?.requested || unresolved?.canonicalName || null,
        quantityAdded: quantityRequested,
        status: "exact",
        shortfall: 0,
        reason: String(correction?.reason ?? "").trim() || unresolved?.reason || null,
        wardenVerified: true,
      });
      const traceItem = findRunTraceItem(runTrace, correction?.name);
      if (traceItem) {
        traceItem.finalStatus = {
          ...(traceItem.finalStatus ?? {}),
          status: "exact",
          decision: "warden_verified",
          matchType: "warden_verified",
          quantityAdded: quantityRequested,
          shortfall: 0,
        };
      }
    }
    const fullyCorrectedRun = isFullyCorrectedRun({
      runTrace,
      unresolvedItems,
      correctedItems,
    });
    if (fullyCorrectedRun) {
      runTrace.warden = {
        ...(runTrace.warden ?? {}),
        status: "ready",
        retryRecommendation: "none",
        notes: Array.isArray(runTrace.warden?.notes) ? runTrace.warden.notes : [],
      };
      if (runTrace.finalizer) {
        runTrace.finalizer = {
          ...(runTrace.finalizer ?? {}),
          status: "ready",
          retryRecommendation: "none",
        };
      }
    }

    const reviewerHasIssues = !reviewerStatusCountsAsReady(runTrace.warden?.status);
    const reviewerRequiresFullRerun = String(runTrace.warden?.retryRecommendation ?? "").trim().toLowerCase() === "rerun_full_cart";
    const hasMeaningfulAddedItems = addedItems.some((item) => {
      const status = String(item?.status ?? "").trim().toLowerCase();
      const quantityAdded = Number(item?.quantityAdded ?? 0);
      return ["exact", "substituted", "saved", "done", "completed"].includes(status) || quantityAdded > 0;
    });
    runTrace.success = unresolvedItems.length === 0 && !reviewerHasIssues;
    runTrace.partialSuccess = !runTrace.success && (
      hasMeaningfulAddedItems
      || String(runTrace.warden?.retryRecommendation ?? "").trim().toLowerCase() === "retry_items_only"
      || unresolvedItems.length > 0
      || (reviewerHasIssues && !reviewerRequiresFullRerun && !fullyCorrectedRun)
    );
    runTrace.latestEvent = {
      kind: "warden_review",
      title: "Mapping review finished",
      body: runTrace.warden?.overallSummary ?? "We reviewed the product matches.",
      at: nowISO(),
    };
    runTrace.latestEventAt = runTrace.latestEvent.at;

    await persistInstacartRunLog(runTrace, { accessToken });
    return {
      runId: normalizedRunID,
      success: runTrace.success,
      partialSuccess: runTrace.partialSuccess,
      correctedItemCount: correctedItems.length,
      unresolvedCount: unresolvedItems.length,
      warden: runTrace.warden,
    };
  } finally {
    await browser?.close().catch(() => {});
  }
}
