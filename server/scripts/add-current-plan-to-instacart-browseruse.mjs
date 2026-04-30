#!/usr/bin/env node
/**
 * Load the latest Ounje meal plan from the iOS simulator container and push
 * its grocery items into Instacart using a Browser Use Cloud browser instead
 * of local Playwright Chromium.
 *
 * This script is intentionally opt-in so the free local Playwright runner stays
 * the default for testing. Run it only with:
 *   INSTACART_USE_BROWSER_USE=1 node server/scripts/add-current-plan-to-instacart-browseruse.mjs
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { execFileSync } from "child_process";
import { config as loadDotenv } from "dotenv";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
loadDotenv({ path: path.resolve(SCRIPT_DIR, "..", ".env") });
const { addItemsToInstacartCart } = await import("../lib/instacart-cart.js");
const { buildShoppingSpecEntries } = await import("../lib/instacart-intent.js");
const { loadPreferredProviderSession } = await import("../lib/provider-session-store.js");

const BROWSER_USE_API_KEY = process.env.BROWSER_USE_API_KEY ?? "";
const BROWSER_USE_BASE = "https://api.browser-use.com/api/v3";
const USE_BROWSER_USE = ["1", "true", "yes"].includes(String(process.env.INSTACART_USE_BROWSER_USE ?? "").toLowerCase())
  || process.argv.includes("--browser-use");

if (!USE_BROWSER_USE) {
  console.error([
    "Browser Use cloud is opt-in.",
    "Use `npm run instacart:add-current-plan` for the free local Playwright default,",
    "or set INSTACART_USE_BROWSER_USE=1 / pass --browser-use to this script.",
  ].join(" "));
  process.exit(1);
}

function run(command, args) {
  return execFileSync(command, args, { encoding: "utf8" }).trim();
}

function getSimulatorContainerPath() {
  return run("xcrun", ["simctl", "get_app_container", "booted", "net.ounje", "data"]);
}

function loadCurrentMealPlan() {
  const containerPath = getSimulatorContainerPath();
  const plistPath = path.join(containerPath, "Library/Preferences/net.ounje.plist");
  if (!fs.existsSync(plistPath)) {
    throw new Error(`Could not find simulator preferences at ${plistPath}`);
  }

  const payload = run("python3", ["-c", `
import json, plistlib, pathlib, sys
plist_path = pathlib.Path(sys.argv[1])
with plist_path.open("rb") as f:
    data = plistlib.load(f)

def decode_bytes(value):
    if isinstance(value, (bytes, bytearray)):
        return value.decode("utf-8")
    return value

auth = json.loads(decode_bytes(data.get("agentic-auth-session-v1") or b"{}"))
profile = json.loads(decode_bytes(data.get("agentic-meal-profile-v1") or b"{}"))
user_id = auth.get("userID")
preferred_keys = []
if user_id:
    preferred_keys.append(f"agentic-meal-history-v2-{user_id}")
preferred_keys.extend([key for key in data.keys() if str(key).startswith("agentic-meal-history-v2-")])
preferred_keys.append("agentic-meal-history-v1")

history_key = next((key for key in preferred_keys if key in data), None)
if not history_key:
    raise SystemExit("No meal history found in simulator preferences")

history = json.loads(decode_bytes(data[history_key]))
plan = history[0] if isinstance(history, list) and history else history
print(json.dumps({
    "auth": auth,
    "profile": profile,
    "historyKey": history_key,
    "plan": plan,
}, separators=(",", ":")))
`, plistPath]);

  return JSON.parse(payload);
}

function compactSourceSummary(item) {
  const sources = Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [];
  const names = [...new Set(sources.map((source) => String(source?.ingredientName ?? "").trim()).filter(Boolean))];
  return names.slice(0, 4).join(", ");
}

function compactSourceRecipeTitles(item, recipeTitleByID) {
  const sources = Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [];
  const titles = [...new Set(
    sources
      .map((source) => recipeTitleByID.get(String(source?.recipeID ?? "")))
      .filter(Boolean)
  )];
  return titles.slice(0, 4);
}

function summarizePlan(plan) {
  const recipes = Array.isArray(plan?.recipes) ? plan.recipes : [];
  const groceryItems = Array.isArray(plan?.groceryItems) ? plan.groceryItems : [];
  return {
    generatedAt: plan?.generatedAt ?? null,
    recipeCount: recipes.length,
    groceryCount: groceryItems.length,
    recipeTitles: recipes.slice(0, 10).map((entry) => entry?.recipe?.title).filter(Boolean),
    groceryItems,
  };
}

async function createBrowserUseBrowser() {
  if (!BROWSER_USE_API_KEY) {
    throw new Error("BROWSER_USE_API_KEY not configured");
  }

  const resp = await fetch(`${BROWSER_USE_BASE}/browsers`, {
    method: "POST",
    headers: {
      "X-Browser-Use-API-Key": BROWSER_USE_API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      keep_alive: true,
    }),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`browser-use create browser ${resp.status}: ${err}`);
  }

  return await resp.json();
}

const source = loadCurrentMealPlan();
const plan = summarizePlan(source.plan);
const recipeTitleByID = new Map((Array.isArray(source.plan?.recipes) ? source.plan.recipes : []).map((entry) => [entry?.recipe?.id, entry?.recipe?.title]));
const accessToken = source.auth?.accessToken ?? null;
const userID = source.auth?.userID ?? null;
const deliveryAddress = source.profile?.deliveryAddress ?? null;
const originalItems = plan.groceryItems;
const shoppingSpec = await buildShoppingSpecEntries({
  originalItems,
  plan: source.plan,
});
const refinedItems = Array.isArray(shoppingSpec?.items) ? shoppingSpec.items : [];
const providerSession = await loadPreferredProviderSession("instacart");

if (!providerSession?.cookies?.length) {
  throw new Error("No local Instacart provider session found to seed Browser Use Cloud");
}

const cloudBrowser = await createBrowserUseBrowser();

console.log("=== Ounje -> Instacart batch add (Browser Use Cloud) ===");
console.log(`historyKey: ${source.historyKey}`);
console.log(`generatedAt: ${plan.generatedAt}`);
console.log(`recipes: ${plan.recipeCount}`);
console.log(`groceryItems: ${plan.groceryCount}`);
if (shoppingSpec?.reconciliationSummary) {
  console.log(`reconciliationSummary: ${JSON.stringify(shoppingSpec.reconciliationSummary)}`);
}
console.log(`browserUseBrowserId: ${cloudBrowser.id}`);
console.log(`browserUseLiveUrl: ${cloudBrowser.liveUrl}`);
console.log(`browserUseCdpUrl: ${cloudBrowser.cdpUrl}`);
console.log(`sessionSeedSource: ${providerSession.source}`);
console.log("topRecipes:");
for (const title of plan.recipeTitles) {
  console.log(` - ${title}`);
}

console.log("\nshoppingSpecs:");
refinedItems.forEach((entry, index) => {
  const amount = Math.max(1, Math.ceil(Number(entry?.amount ?? 1)));
  const sourceNames = compactSourceSummary(entry);
  const role = entry.shoppingContext?.role ? `, role=${entry.shoppingContext.role}` : "";
  const exactness = entry.shoppingContext?.exactness ? `, exactness=${entry.shoppingContext.exactness}` : "";
  const preferred = entry.shoppingContext?.preferredForms?.length ? `, prefer=${entry.shoppingContext.preferredForms.slice(0, 3).join(" / ")}` : "";
  const required = entry.shoppingContext?.requiredDescriptors?.length ? `, must=${entry.shoppingContext.requiredDescriptors.slice(0, 3).join(" / ")}` : "";
  const pantry = entry.shoppingContext?.isPantryStaple ? ", pantry=yes" : "";
  const optional = entry.shoppingContext?.isOptional ? ", optional=yes" : "";
  const packageRule = entry.shoppingContext?.packageRule?.packageUnit ? `, package=${entry.shoppingContext.packageRule.packageUnit}` : "";
  console.log(` - ${index + 1}. ${entry.originalName ?? entry.name} -> ${entry.name} (qty=${amount}, confidence=${entry.confidence}, reason=${entry.reason}${role}${exactness}${preferred}${required}${pantry}${optional}${packageRule}${sourceNames ? `, sources=${sourceNames}` : ""})`);
});

const result = await addItemsToInstacartCart({
  userId: userID,
  accessToken,
  mealPlanID: source.plan?.id ?? null,
  items: refinedItems.map((entry) => ({
    name: entry.name,
    originalName: entry.originalName ?? entry.name,
    amount: Math.max(1, Math.ceil(Number(entry?.amount ?? 1))),
    unit: entry?.unit ?? "item",
    sourceIngredients: Array.isArray(entry?.sourceIngredients) ? entry.sourceIngredients : [],
    sourceRecipes: compactSourceRecipeTitles(entry, recipeTitleByID),
    shoppingContext: entry.shoppingContext ?? null,
  })),
  deliveryAddress,
  providerSession,
  cdpUrl: cloudBrowser.cdpUrl,
  logger: console,
});

console.log("\n=== Browser Use Cloud Instacart result ===");
console.log(JSON.stringify(result, null, 2));

if (!result.success) {
  process.exitCode = 1;
}
