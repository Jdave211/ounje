import fs from "fs";
import path from "path";

const CACHE_PATH = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../data/discover/discover_brackets.json"
);

const DISCOVER_PRESETS = [
  { key: "all", title: "All", description: "Keep the feed broad and varied." },
  { key: "breakfast", title: "Breakfast", description: "Breakfast and brunch recipes." },
  { key: "lunch", title: "Lunch", description: "Lunch-friendly recipes." },
  { key: "dinner", title: "Dinner", description: "Dinner recipes." },
  { key: "dessert", title: "Dessert", description: "Desserts and sweet treats." },
  { key: "drinks", title: "Drinks", description: "Drinks, smoothies, mocktails, coffees, and sips." },
  { key: "vegetarian", title: "Vegetarian", description: "Vegetarian recipes." },
  { key: "vegan", title: "Vegan", description: "Vegan recipes." },
  { key: "pasta", title: "Pasta", description: "Pasta dishes." },
  { key: "chicken", title: "Chicken", description: "Chicken-forward recipes." },
  { key: "steak", title: "Steak", description: "Beef and steak recipes." },
  { key: "fish", title: "Fish", description: "Fish-forward recipes." },
  { key: "salad", title: "Salad", description: "Salads and lighter bowls." },
  { key: "sandwich", title: "Sandwich", description: "Sandwiches, burgers, and wraps." },
  { key: "beans", title: "Beans", description: "Bean and legume-forward recipes." },
  { key: "potatoes", title: "Potatoes", description: "Potato-based recipes." },
  { key: "salmon", title: "Salmon", description: "Salmon recipes." },
  { key: "beginner", title: "Beginner", description: "Easy and beginner-friendly recipes." },
  { key: "under500", title: "Under 500 Cal", description: "Recipes under 500 calories." },
];

const PRESET_BY_KEY = new Map(DISCOVER_PRESETS.map((preset) => [preset.key, preset]));
const PRESET_BY_TITLE = new Map(DISCOVER_PRESETS.map((preset) => [preset.title.toLowerCase(), preset]));

let cacheState = {
  mtimeMs: 0,
  data: {
    by_recipe_id: {},
    by_bracket: {},
  },
};

const BREAKFAST_STRONG_REGEX = /\b(breakfast|brunch|overnight oats?|baked oats?|oatmeal|porridge|pancakes?|waffles?|omelet|omelette|scrambled eggs?|eggs benedict|frittata|granola|parfait|smoothie bowl|yogurt bowl|avocado toast|toast|bagel|breakfast sandwich|hash brown|breakfast burrito|breakfast casserole|biscuit|crepes?)\b/i;
const BREAKFAST_CORE_REGEX = /\b(overnight oats?|baked oats?|oatmeal|porridge|pancakes?|waffles?|omelet|omelette|scrambled eggs?|eggs benedict|frittata|granola|parfait|smoothie bowl|yogurt bowl|avocado toast|bagel|breakfast sandwich|hash brown|breakfast burrito|breakfast casserole)\b/i;
const DESSERT_HEAVY_REGEX = /\b(cookies?|cake|cheesecake|brownies?|brookies?|blondies?|ice cream|gelato|pie|pudding|tart|cobbler|madeleines?|cupcakes?|fudge|bars?|sweet rolls?|coffee cake|banana bread|loaf|brioche buns?)\b/i;
const DRINK_STRONG_REGEX = /\b(smoothies?|juices?|lattes?|coffees?|teas?|matcha|lemonades?|spritz(?:es)?|cocktails?|mocktails?|sodas?|shakes?|margaritas?|martinis?|mojitos?|spritzers?|punch|hot chocolate|cocoa|espresso|americanos?|cappuccinos?|frappes?|slush(?:ies)?|milkshakes?|carajillo)\b/i;
const DRINK_EXCLUSION_REGEX = /\b(soup|salad|bowl|sandwich|wrap|tacos?|pasta|noodles?|rice|chicken|beef|steak|salmon|shrimp|prawns?|cod|beans?|potatoes?)\b/i;
const FISH_STRONG_REGEX = /\b(salmon|cod|snapper|tilapia|trout|sea bass|halibut|mackerel|tuna|sardine|anchovy|shrimp|prawn|lobster|crab|scallop|mussels?|clams?|ceviche|seafood|fish)\b/i;

function buildDiscoverBracketEvidence(recipe = {}) {
  return {
    visibleText: [
      recipe?.title,
      recipe?.description,
      recipe?.recipe_type,
      recipe?.category,
      ...(recipe?.dietary_tags ?? []),
      ...(recipe?.cuisine_tags ?? []),
      ...(recipe?.occasion_tags ?? []),
    ]
      .filter(Boolean)
      .join(" "),
    titleAndDescription: [recipe?.title, recipe?.description].filter(Boolean).join(" "),
    titleContextText: [
      recipe?.title,
      recipe?.recipe_type,
      recipe?.category,
      ...(recipe?.occasion_tags ?? []),
    ]
      .filter(Boolean)
      .join(" "),
  };
}

export function sanitizeDiscoverBrackets(recipe = {}, candidateBrackets = []) {
  const unique = [...new Set((candidateBrackets ?? []).map(normalizeDiscoverBracketKey).filter(Boolean))];
  const brackets = new Set(unique);
  const { visibleText, titleAndDescription, titleContextText } = buildDiscoverBracketEvidence(recipe);

  const hasBreakfastSignal = BREAKFAST_STRONG_REGEX.test(visibleText);
  const hasBreakfastCoreSignal = BREAKFAST_CORE_REGEX.test(titleContextText);
  const hasDessertHeavySignal = DESSERT_HEAVY_REGEX.test(visibleText);
  const hasDrinkSignal = DRINK_STRONG_REGEX.test(titleContextText) || String(recipe?.recipe_type ?? "").toLowerCase() === "drinks";
  const hasDrinkExclusionSignal = DRINK_EXCLUSION_REGEX.test(titleContextText);
  const hasFishSignal = FISH_STRONG_REGEX.test(visibleText);

  if (brackets.has("breakfast") && ((hasDessertHeavySignal && !hasBreakfastCoreSignal) || (hasDrinkSignal && !hasBreakfastCoreSignal))) {
    brackets.delete("breakfast");
  }

  if (brackets.has("drinks") && (!hasDrinkSignal || hasDrinkExclusionSignal || hasDessertHeavySignal || hasBreakfastCoreSignal)) {
    brackets.delete("drinks");
  }

  if (brackets.has("fish") && !hasFishSignal) {
    brackets.delete("fish");
  }

  if (brackets.has("salmon")) {
    brackets.add("fish");
  }

  if (!brackets.size) {
    if (hasDrinkSignal && !hasDrinkExclusionSignal) brackets.add("drinks");
    else if (hasBreakfastCoreSignal) brackets.add("breakfast");
    else if (hasFishSignal) brackets.add("fish");
    else if (hasDessertHeavySignal) brackets.add("dessert");
    else if (String(recipe?.recipe_type ?? "").toLowerCase() === "lunch") brackets.add("lunch");
    else if (String(recipe?.recipe_type ?? "").toLowerCase() === "breakfast") brackets.add("breakfast");
    else brackets.add("dinner");
  }

  return [...brackets];
}

function readCacheFile() {
  try {
    const stat = fs.statSync(CACHE_PATH);
    if (cacheState.data && cacheState.mtimeMs === stat.mtimeMs) {
      return cacheState.data;
    }

    const parsed = JSON.parse(fs.readFileSync(CACHE_PATH, "utf8"));
    cacheState = {
      mtimeMs: stat.mtimeMs,
      data: {
        by_recipe_id: parsed?.by_recipe_id ?? {},
        by_bracket: parsed?.by_bracket ?? {},
      },
    };
    return cacheState.data;
  } catch {
    return cacheState.data;
  }
}

export function getDiscoverPreset(filter = "All") {
  const raw = String(filter ?? "All").trim();
  if (!raw) return PRESET_BY_KEY.get("all");

  const normalizedKey = normalizeDiscoverBracketKey(raw);
  return PRESET_BY_KEY.get(normalizedKey)
    ?? PRESET_BY_TITLE.get(raw.toLowerCase())
    ?? PRESET_BY_KEY.get("all");
}

export function getDiscoverPresetTitles() {
  return DISCOVER_PRESETS.map((preset) => preset.title);
}

export function getClassifiableDiscoverBracketKeys() {
  return DISCOVER_PRESETS
    .map((preset) => preset.key)
    .filter((key) => key !== "all");
}

export function normalizeDiscoverBracketKey(value) {
  const lowered = String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/calories?/g, "cal")
    .replace(/\s+/g, "")
    .replace(/[^a-z0-9]/g, "");

  switch (lowered) {
    case "all":
      return "all";
    case "breakfast":
      return "breakfast";
    case "lunch":
      return "lunch";
    case "dinner":
      return "dinner";
    case "dessert":
    case "desserts":
      return "dessert";
    case "drinks":
    case "drink":
      return "drinks";
    case "vegetarian":
      return "vegetarian";
    case "vegan":
      return "vegan";
    case "pasta":
      return "pasta";
    case "chicken":
      return "chicken";
    case "steak":
    case "beef":
      return "steak";
    case "fish":
      return "fish";
    case "salad":
      return "salad";
    case "sandwich":
    case "sandwiches":
      return "sandwich";
    case "beans":
    case "bean":
    case "legumes":
    case "legume":
      return "beans";
    case "potatoes":
    case "potato":
      return "potatoes";
    case "salmon":
      return "salmon";
    case "beginner":
      return "beginner";
    case "under500":
    case "under500cal":
    case "under500cals":
    case "under500calories":
      return "under500";
    default:
      return lowered;
  }
}

export function getRecipeDiscoverBrackets(recipe) {
  const fromRecipe = Array.isArray(recipe?.discover_brackets)
    ? recipe.discover_brackets
    : [];

  const cache = readCacheFile();
  const fromCache = cache.by_recipe_id?.[String(recipe?.id ?? "")]?.brackets ?? [];

  const normalized = sanitizeDiscoverBrackets(
    recipe,
    [...new Set([...fromRecipe, ...fromCache].map(normalizeDiscoverBracketKey))]
      .filter((key) => PRESET_BY_KEY.has(key) && key !== "all")
  );

  return normalized;
}

export function attachDiscoverBrackets(recipes = []) {
  return (recipes ?? []).map((recipe) => {
    const discoverBrackets = getRecipeDiscoverBrackets(recipe);
    return discoverBrackets.length
      ? { ...recipe, discover_brackets: discoverBrackets }
      : recipe;
  });
}

export function recipeHasDiscoverBracket(recipe, filter = "All") {
  const preset = getDiscoverPreset(filter);
  if (!preset || preset.key === "all" || preset.key === "under500") {
    return true;
  }

  return getRecipeDiscoverBrackets(recipe).includes(preset.key);
}

export function getCachedRecipeIdsForBracket(filter = "All") {
  const preset = getDiscoverPreset(filter);
  if (!preset || preset.key === "all") return [];

  const cache = readCacheFile();
  const ids = cache.by_bracket?.[preset.key] ?? [];
  return Array.isArray(ids) ? ids.map((id) => String(id).trim()).filter(Boolean) : [];
}
