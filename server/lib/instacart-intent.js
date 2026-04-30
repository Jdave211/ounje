import OpenAI from "openai";
import "dotenv/config";
import { normalizeRecipeDetail } from "./recipe-detail-utils.js";
import {
  applySourceCollationToItem,
  buildSourceEdgeCoverageSummary,
  canonicalizeIngredientName,
  mergeCanonicalShoppingEntries,
  sourceEdgeIDsForItem,
} from "./main-shop-collation.js";

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const INTENT_MODEL = process.env.INSTACART_QUERY_MODEL ?? "gpt-5-mini";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";

const openai = OPENAI_API_KEY ? new OpenAI({ apiKey: OPENAI_API_KEY }) : null;
const RECIPE_DETAIL_CACHE_TTL_MS = 5 * 60 * 1000;
const recipeDetailRecordCache = new Map();

function chatCompletionTemperatureParams(model) {
  return String(model ?? "").trim() === "gpt-5-mini" ? {} : { temperature: 0 };
}

const AMBIGUOUS_QUERY_SET = new Set([
  "chicken",
  "egg",
  "eggs",
  "shrimp",
  "greens",
  "green onion",
  "green onions",
  "onion",
  "cilantro",
  "rice paper",
  "seasoning",
  "cotija cheese",
  "shredded cheese",
  "cooked buffalo chicken",
  "sugar",
  "romaine",
  "romaine lettuce",
  "avocado",
  "plantain",
  "ripe plantain",
  "optional toppings",
  "bang bang sauce",
]);

const PANTRY_STAPLE_SET = new Set([
  "salt",
  "black pepper",
  "pepper",
  "olive oil",
  "oil",
  "garlic powder",
  "onion powder",
  "paprika",
  "cinnamon",
  "baking powder",
  "baking soda",
  "bouillon powder",
  "curry powder",
]);

const PUBLIC_RECIPE_SELECT = [
  "id",
  "title",
  "description",
  "source",
  "category",
  "subcategory",
  "recipe_type",
  "skill_level",
  "cook_method",
  "cook_time_text",
  "servings_text",
  "prep_time_minutes",
  "cook_time_minutes",
  "ingredients_json",
  "steps_json",
  "dietary_tags",
  "flavor_tags",
  "cuisine_tags",
  "occasion_tags",
  "main_protein",
].join(",");

function normalizeText(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function tokenizeItemName(value) {
  return normalizeText(value)
    .split(" ")
    .map((token) => token.trim())
    .filter(Boolean);
}

function uniqueStrings(values, limit = 8) {
  return [...new Set((values ?? []).map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, limit);
}

function truncateText(value, maxLength = 180) {
  const normalized = String(value ?? "").replace(/\s+/g, " ").trim();
  if (normalized.length <= maxLength) return normalized;
  return `${normalized.slice(0, maxLength - 1).trimEnd()}…`;
}

function normalizedKey(value) {
  return normalizeText(value)
    .replace(/\b(or|and|with|plus|the|a|an|additional|optional|fresh|creamy|crispy|tangy|plain|raw|cooked)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizedMergeKey(value) {
  return normalizeText(value)
    .replace(/\b(or|and|with|plus|the|a|an)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function shouldPreferMergeMax(existingEntry, nextEntry) {
  const existingUnit = String(existingEntry?.unit ?? "").trim().toLowerCase();
  const nextUnit = String(nextEntry?.unit ?? "").trim().toLowerCase();
  if (existingUnit && nextUnit && existingUnit === nextUnit) return false;

  const packageUnit = String(
    existingEntry?.shoppingContext?.packageRule?.packageUnit
      ?? nextEntry?.shoppingContext?.packageRule?.packageUnit
      ?? ""
  ).trim().toLowerCase();

  return ["bottle", "jar", "can", "tub", "pack", "carton"].includes(packageUnit);
}

const MAIN_SHOP_DESCRIPTOR_WORDS = new Set([
  "additional",
  "atlantic",
  "boneless",
  "boxed",
  "chopped",
  "cooked",
  "crushed",
  "diced",
  "drained",
  "gourmet",
  "fresh",
  "frozen",
  "heirloom",
  "grated",
  "ground",
  "large",
  "lowfat",
  "low-fat",
  "king",
  "medium",
  "minced",
  "optional",
  "organic",
  "peeled",
  "premium",
  "raw",
  "ripe",
  "sockeye",
  "specialty",
  "sliced",
  "small",
  "skinless",
  "shredded",
  "wild",
  "thawed",
  "whole",
]);

const FALLBACK_SEARCH_MODIFIER_WORDS = new Set([
  ...MAIN_SHOP_DESCRIPTOR_WORDS,
  "baby",
  "colorful",
  "clean",
  "crisp",
  "deli",
  "extra",
  "fresh",
  "frozen",
  "green",
  "heavy",
  "hot",
  "italian",
  "kosher",
  "large",
  "light",
  "low",
  "medium",
  "mini",
  "organic",
  "pale",
  "persian",
  "pink",
  "plain",
  "purple",
  "raw",
  "red",
  "ripe",
  "rough",
  "sea",
  "skinless",
  "small",
  "smoked",
  "soft",
  "spicy",
  "table",
  "thin",
  "unsalted",
  "virgin",
  "white",
  "yellow",
]);

const MAIN_SHOP_LEXICAL_STOP_WORDS = new Set([
  "a",
  "an",
  "and",
  "for",
  "fresh",
  "of",
  "optional",
  "or",
  "plain",
  "plus",
  "the",
  "with",
]);

const MAIN_SHOP_FINALIZER_EXCLUSIONS = new Set([
  "water",
]);

const MAIN_SHOP_PHRASE_REPLACEMENTS = [
  [/\bbird['’]?\s*eye\s+chil(?:i|ies|is|y|ly|le|es)\b/gu, "bird eye chili"],
  [/\bboneless\s+skinless\s+chicken\s+breasts?\b/gu, "chicken breast"],
  [/\bboneless\s+skinless\s+chicken\s+thighs?\b/gu, "chicken thigh"],
  [/\bbone[-\s]?in\s+skin[-\s]?on\s+chicken\s+breasts?\b/gu, "chicken breast"],
  [/\bbone[-\s]?in\s+skin[-\s]?on\s+chicken\s+thighs?\b/gu, "chicken thigh"],
  [/\bbone[-\s]?in\s+chicken\s+breasts?\b/gu, "chicken breast"],
  [/\bbone[-\s]?in\s+chicken\s+thighs?\b/gu, "chicken thigh"],
  [/\bskin[-\s]?on\s+chicken\s+breasts?\b/gu, "chicken breast"],
  [/\bskin[-\s]?on\s+chicken\s+thighs?\b/gu, "chicken thigh"],
  [/\bcooked\s+chicken\s+breasts?\b/gu, "chicken breast"],
  [/\bcooked\s+chicken\s+thighs?\b/gu, "chicken thigh"],
  [/\bshredded\s+chicken\s+breasts?\b/gu, "chicken breast"],
  [/\bshredded\s+chicken\s+thighs?\b/gu, "chicken thigh"],
  [/\bheirloom\s+tomatoes?\b/gu, "tomato"],
  [/\bboxed\s+sweet\s+potatoes?\b/gu, "sweet potato"],
  [/\borganic\s+avocados?\b/gu, "avocado"],
  [/\b(?:wild|sockeye|atlantic|king)\s+salmon\b/gu, "salmon"],
  [/\bgreen\s+onions?\b/gu, "green onion"],
  [/\bspring\s+onions?\b/gu, "green onion"],
  [/\bscallions?\b/gu, "green onion"],
];

const GENERIC_INGREDIENT_BUCKETS = new Set([
  "spice",
  "spices",
  "seasoning",
  "seasonings",
  "herb",
  "herbs",
  "sauce",
  "sauces",
  "dressing",
  "dressings",
  "marinade",
  "marinades",
  "glaze",
  "glazes",
  "topping",
  "toppings",
  "garnish",
  "garnishes",
]);

const CONCRETE_BUCKET_HINTS = {
  spice: [
    /paprika/i,
    /chili/i,
    /cumin/i,
    /coriander/i,
    /turmeric/i,
    /garlic\s+powder/i,
    /onion\s+powder/i,
    /black\s+pepper/i,
    /white\s+pepper/i,
    /red\s+pepper/i,
    /cayenne/i,
    /oregano/i,
    /basil/i,
    /thyme/i,
    /rosemary/i,
    /sage/i,
    /mint/i,
    /parsley/i,
    /cilantro/i,
    /dill/i,
    /chives?/i,
    /ginger/i,
    /cinnamon/i,
    /nutmeg/i,
    /cloves?/i,
    /allspice/i,
    /cardamom/i,
    /fennel/i,
    /sumac/i,
    /za'?atar/i,
  ],
  herb: [/cilantro/i, /parsley/i, /basil/i, /mint/i, /thyme/i, /oregano/i, /rosemary/i, /sage/i, /dill/i, /chives?/i],
  sauce: [
    /honey/i,
    /sriracha/i,
    /soy\s+sauce/i,
    /hot\s+sauce/i,
    /vinegar/i,
    /mustard/i,
    /mayo/i,
    /yogurt/i,
    /bbq/i,
    /worcestershire/i,
    /sesame\s+oil/i,
    /fish\s+sauce/i,
    /oyster\s+sauce/i,
    /hoisin/i,
    /teriyaki/i,
    /chipotle/i,
    /tomato\s+sauce/i,
  ],
  topping: [/cheese/i, /onion/i, /scallion/i, /cilantro/i, /parsley/i, /lime/i, /avocado/i, /seed/i, /nut/i],
};

function normalizeMainShopToken(token) {
  let normalized = String(token ?? "").trim().toLowerCase();
  if (!normalized) return "";
  normalized = normalized.replace(/[^\p{L}\p{N}]+/gu, "");
  if (!normalized) return "";

  if (/^chil(?:i|ies|is|y|ly|le|es|li|les)?$/.test(normalized)) return "chili";
  if (/^tomatoes?$/.test(normalized)) return "tomato";
  if (/^potatoes?$/.test(normalized)) return "potato";
  if (/^avocados?$/.test(normalized)) return "avocado";
  if (/^berries$/.test(normalized)) return "berry";
  if (/^onions?$/.test(normalized)) return "onion";
  if (/^scallions?$/.test(normalized)) return "scallion";
  if (/^leaves$/.test(normalized)) return "leaf";
  if (normalized === "greens") return "greens";

  if (normalized.endsWith("ies") && normalized.length > 4) {
    return `${normalized.slice(0, -3)}y`;
  }
  if (normalized.endsWith("oes") && normalized.length > 4) {
    return normalized.slice(0, -2);
  }
  if (normalized.endsWith("es") && normalized.length > 4 && !normalized.endsWith("ses")) {
    return normalized.slice(0, -2);
  }
  if (normalized.endsWith("s") && normalized.length > 3 && !normalized.endsWith("ss")) {
    return normalized.slice(0, -1);
  }
  return normalized;
}

function normalizeMainShopFamilyName(value) {
  let normalized = normalizeText(value);
  if (!normalized) return "";

  for (const [pattern, replacement] of MAIN_SHOP_PHRASE_REPLACEMENTS) {
    normalized = normalized.replace(pattern, replacement);
  }

  const tokens = normalized
    .split(" ")
    .map(normalizeMainShopToken)
    .filter(Boolean)
    .filter((token) => !MAIN_SHOP_DESCRIPTOR_WORDS.has(token));

  return tokens.join(" ").trim();
}

function deriveFallbackSearchQuery(value, itemContext = {}) {
  let normalized = normalizeText(value).toLowerCase();
  if (!normalized) return "";

  for (const [pattern, replacement] of MAIN_SHOP_PHRASE_REPLACEMENTS) {
    normalized = normalized.replace(pattern, replacement);
  }

  const tokens = normalized
    .split(" ")
    .map((token) => token.replace(/[^\p{L}\p{N}]+/gu, ""))
    .filter(Boolean);

  const modifierWords = new Set([
    ...FALLBACK_SEARCH_MODIFIER_WORDS,
    ...(Array.isArray(itemContext?.requiredDescriptors) ? itemContext.requiredDescriptors : []),
  ].map((token) => normalizeText(token).toLowerCase()).filter(Boolean));

  const filtered = tokens.filter((token) => !modifierWords.has(token));
  let fallbackTokens = filtered.length > 0 ? filtered : tokens;
  if (!fallbackTokens.length) return "";

  let fallback = fallbackTokens.join(" ").trim();
  if (!fallback) return "";

  if (normalizeText(fallback) === normalizeText(value) && tokens.length > 1) {
    const tail = tokens.slice(-2).join(" ").trim();
    if (tail && tail !== fallback) {
      fallback = tail;
    }
  }

  return fallback;
}

function normalizeSubstitutionPolicy(value, fallback = "strict") {
  const normalized = String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z_]+/g, "_")
    .replace(/^_+|_+$/g, "");

  if (["strict", "flexible", "optional"].includes(normalized)) {
    return normalized;
  }
  return fallback;
}

function mainShopFamilyKeyForEntry(entry) {
  const candidate = entry?.shoppingContext?.canonicalName
    ?? entry?.canonicalName
    ?? entry?.name
    ?? "";
  return normalizeMainShopFamilyName(candidate);
}

function lexicalMainShopTokens(value) {
  const normalized = normalizeText(value);
  if (!normalized) return [];
  return normalized
    .split(" ")
    .map(normalizeMainShopToken)
    .filter(Boolean)
    .filter((token) => !MAIN_SHOP_DESCRIPTOR_WORDS.has(token))
    .filter((token) => !MAIN_SHOP_LEXICAL_STOP_WORDS.has(token));
}

function lexicalMainShopSignature(value) {
  return lexicalMainShopTokens(value).join(" ").trim();
}

function buildLexicalAdjudicationName(entry) {
  return String(
    entry?.shoppingContext?.canonicalName
      || entry?.canonicalName
      || entry?.name
      || entry?.originalName
      || ""
  ).trim();
}

function shouldLexicallyAdjudicateEntries(lhsEntry, rhsEntry) {
  const lhsName = buildLexicalAdjudicationName(lhsEntry);
  const rhsName = buildLexicalAdjudicationName(rhsEntry);
  const lhsSignature = lexicalMainShopSignature(lhsName);
  const rhsSignature = lexicalMainShopSignature(rhsName);

  if (!lhsSignature || !rhsSignature || lhsSignature === rhsSignature) {
    return false;
  }

  const lhsTokens = lexicalMainShopTokens(lhsName);
  const rhsTokens = lexicalMainShopTokens(rhsName);
  if (!lhsTokens.length || !rhsTokens.length) return false;

  const lhsSet = new Set(lhsTokens);
  const rhsSet = new Set(rhsTokens);
  const overlap = lhsTokens.filter((token) => rhsSet.has(token));
  if (overlap.length === 0) return false;

  // Shared meaningful token(s) are only used to queue the pair for LLM review.
  // The LLM still decides whether to merge or keep distinct.
  return overlap.length > 0 || lhsSet.size === rhsSet.size && lhsSignature === rhsSignature;
}

function buildAdjudicationGroups(clusters) {
  const parents = new Map(clusters.map((cluster) => [cluster.index, cluster.index]));

  function find(index) {
    const parent = parents.get(index);
    if (parent === index) return index;
    const root = find(parent);
    parents.set(index, root);
    return root;
  }

  function union(lhsIndex, rhsIndex) {
    const lhsRoot = find(lhsIndex);
    const rhsRoot = find(rhsIndex);
    if (lhsRoot !== rhsRoot) {
      parents.set(rhsRoot, lhsRoot);
    }
  }

  for (let lhsIndex = 0; lhsIndex < clusters.length; lhsIndex += 1) {
    const lhs = clusters[lhsIndex];
    const lhsRepresentative = lhs.items[0];
    for (let rhsIndex = lhsIndex + 1; rhsIndex < clusters.length; rhsIndex += 1) {
      const rhs = clusters[rhsIndex];
      const rhsRepresentative = rhs.items[0];
      if (!lhsRepresentative || !rhsRepresentative) continue;
      if (!shouldLexicallyAdjudicateEntries(lhsRepresentative, rhsRepresentative)) continue;
      union(lhs.index, rhs.index);
    }
  }

  const grouped = new Map();
  for (const cluster of clusters) {
    const root = find(cluster.index);
    if (!grouped.has(root)) {
      grouped.set(root, []);
    }
    grouped.get(root).push(cluster);
  }

  return [...grouped.values()];
}

function mainShopEntryDisplayScore(entry) {
  const familyKey = mainShopFamilyKeyForEntry(entry);
  const name = familyKey || normalizeText(entry?.name ?? "");
  const tokenCount = name.split(" ").filter(Boolean).length;
  const familyBonus = familyKey ? 20 : 0;
  const confidenceBonus = Number(entry?.confidence ?? 0) * 25;
  const priceBonus = Number(entry?.estimatedPrice ?? 0) > 0 ? 2 : 0;
  const sourceBonus = Array.isArray(entry?.sourceIngredients) && entry.sourceIngredients.length > 1 ? 6 : 0;
  return tokenCount * 18 + name.length + familyBonus + confidenceBonus + priceBonus + sourceBonus;
}

function genericBucketKindForName(value) {
  const normalized = normalizeText(value).toLowerCase();
  if (!normalized) return null;
  if (["spice", "spices", "seasoning", "seasonings"].includes(normalized)) return "spice";
  if (["herb", "herbs"].includes(normalized)) return "herb";
  if (["sauce", "sauces", "dressing", "dressings", "marinade", "marinades", "glaze", "glazes"].includes(normalized)) return "sauce";
  if (["topping", "toppings", "garnish", "garnishes"].includes(normalized)) return "topping";
  return null;
}

function isGenericIngredientBucketName(value) {
  return genericBucketKindForName(value) != null;
}

function isConcreteIngredientForBucket(value, bucketKind) {
  const normalized = normalizeText(value);
  if (!normalized) return false;
  if (GENERIC_INGREDIENT_BUCKETS.has(normalized.toLowerCase())) return false;
  const patterns = CONCRETE_BUCKET_HINTS[bucketKind] ?? [];
  return patterns.some((pattern) => pattern.test(normalized));
}

function recipeHasConcreteCompanions(recipe, bucketKind) {
  const ingredients = Array.isArray(recipe?.ingredients) ? recipe.ingredients : [];
  return ingredients.filter((ingredient) => isConcreteIngredientForBucket(ingredient?.display_name ?? ingredient?.name ?? "", bucketKind)).length >= 2;
}

function normalizeGenericBucketDisplayName(value) {
  const normalized = normalizeText(value).toLowerCase();
  switch (normalized) {
    case "spice":
    case "spices":
    case "seasoning":
    case "seasonings":
      return "seasoning blend";
    case "herb":
    case "herbs":
      return "herb blend";
    case "sauce":
    case "sauces":
    case "dressing":
    case "dressings":
    case "marinade":
    case "marinades":
    case "glaze":
    case "glazes":
      return "sauce mix";
    case "topping":
    case "toppings":
    case "garnish":
    case "garnishes":
      return "topping mix";
    default:
      return normalizeText(value);
  }
}

function uniqueSourceIngredientEntries(sourceIngredients = []) {
  const seen = new Set();
  return (Array.isArray(sourceIngredients) ? sourceIngredients : []).filter((source) => {
    const key = [
      String(source?.recipeID ?? "").trim().toLowerCase(),
      String(source?.ingredientName ?? "").trim().toLowerCase(),
      String(source?.unit ?? "").trim().toLowerCase(),
    ].join("::");
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function buildShoppingSpecCleanupPrompt(clusters) {
  return [
    "You are cleaning a grocery shopping graph after recipe parsing.",
    "For each cluster, decide whether the items are the same grocery family and should be merged into one main-shop row.",
    "Every item is backed by sourceEdgeIDs. Merge decisions must preserve those sourceEdgeIDs; do not create or imply new source ingredients.",
    "Merge spelling variants, pluralization variants, and descriptor-only variants such as shredded vs plain, cooked vs raw, or boneless skinless vs the base grocery family.",
    "Merge packaging/prep-only variants such as instant rice cup, cooked rice, rice cup, or chopped cilantro when the head grocery is the same.",
    "If a name is an explicit alternative such as A or B, choose one canonical shopping family and keep the unchosen name as an alternate, not a separate main-shop row.",
    "Collapse obvious grocery variants like heirloom tomato, boxed sweet potato, organic avocado, or wild salmon into the plain grocery family when the recipe does not ask for the specialty form.",
    "Lexically related names were intentionally grouped for review. Only merge them when they truly represent the same shoppable grocery.",
    "Do not merge different grocery families just because they share a broad word.",
    "Keep these separate: chicken breast vs chicken thigh, chili powder vs chili pepper, green onion vs yellow onion, lettuce vs cabbage, rice vs cauliflower rice.",
    "Review pairs like garlic + garlic clove, salmon + salmon fillet, oil + olive oil, and bird eye chilies + bird eye chily with the recipe context before deciding.",
    "Good merge examples: bird eye chilies + bird eye chily; shredded chicken breast + chicken breast.",
    "Descriptor-only examples that should usually merge: cilantro + chopped cilantro, parsley + chopped parsley.",
    "If one item is an explicit alternative or compound, keep it separate: rice vs rice or cauliflower rice.",
    "When merged, return the best canonicalName and preferredDisplayName for the shopper.",
    "Use mergeAmountStrategy = sum when the amounts are additive, and max when different measurements are only alternate ways of representing one packaged grocery.",
    "Return JSON only.",
    "",
    JSON.stringify(clusters, null, 2),
  ].join("\n");
}

async function resolveMainShopClusterDecisions(clusters) {
  if (!openai || clusters.length === 0) return new Map();

  const response = await openai.chat.completions.create({
    model: INTENT_MODEL,
    ...chatCompletionTemperatureParams(INTENT_MODEL),
    response_format: {
      type: "json_schema",
      json_schema: {
        name: "instacart_main_shop_cleanup",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            clusters: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  index: { type: "integer" },
                  merge: { type: "boolean" },
                  preferredDisplayName: { type: "string" },
                  canonicalName: { type: "string" },
                  mergeAmountStrategy: { type: "string" },
                  preferredUnit: { type: ["string", "null"] },
                  confidence: { type: "number" },
                  reason: { type: "string" },
                },
                required: [
                  "index",
                  "merge",
                  "preferredDisplayName",
                  "canonicalName",
                  "mergeAmountStrategy",
                  "preferredUnit",
                  "confidence",
                  "reason",
                ],
              },
            },
          },
          required: ["clusters"],
        },
      },
    },
    messages: [
      {
        role: "system",
        content: "You clean grocery shopping clusters. Keep only true grocery-family duplicates together and preserve distinct groceries.",
      },
      { role: "user", content: buildShoppingSpecCleanupPrompt(clusters) },
    ],
  });

  const content = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(content);
  return new Map((parsed.clusters ?? []).map((entry) => [entry.index, entry]));
}

function shouldExcludeFinalizedMainShopEntry(entry) {
  const candidate = normalizeMainShopFamilyName(
    entry?.shoppingContext?.canonicalName
      ?? entry?.canonicalName
      ?? entry?.name
      ?? ""
  );
  return MAIN_SHOP_FINALIZER_EXCLUSIONS.has(candidate);
}

function mergeShoppingSpecCluster(items, decision = {}) {
  const sortedItems = [...items].sort((lhs, rhs) => mainShopEntryDisplayScore(rhs) - mainShopEntryDisplayScore(lhs));
  const representative = sortedItems[0] ?? items[0];
  if (!representative) return null;

  const preferredDisplayName = String(
    decision.preferredDisplayName
      || representative.name
      || representative.canonicalName
      || ""
  ).trim();
  const canonicalName = normalizeMainShopFamilyName(
    decision.canonicalName
      || representative.shoppingContext?.canonicalName
      || representative.canonicalName
      || preferredDisplayName
      || representative.name
      || ""
  ) || preferredDisplayName || representative.name || representative.canonicalName || "";

  const preferredUnit = String(
    decision.preferredUnit
      || representative.shoppingContext?.packageRule?.packageUnit
      || representative.unit
      || ""
  ).trim() || null;
  const mergeStrategy = String(decision.mergeAmountStrategy ?? "").trim().toLowerCase();

  let mergedAmount = Math.max(0, Number(representative.amount ?? 0));
  let probeEntry = representative;
  for (const nextItem of sortedItems.slice(1)) {
    const nextAmount = Math.max(0, Number(nextItem.amount ?? 0));
    const useMax = mergeStrategy === "max" || shouldPreferMergeMax(probeEntry, nextItem);
    mergedAmount = useMax ? Math.max(mergedAmount, nextAmount) : mergedAmount + nextAmount;
    probeEntry = {
      ...probeEntry,
      amount: mergedAmount,
      unit: preferredUnit ?? probeEntry.unit ?? nextItem.unit ?? "item",
    };
  }

  const sourceIngredients = uniqueSourceIngredientEntries(
    sortedItems.flatMap((item) => Array.isArray(item.sourceIngredients) ? item.sourceIngredients : [])
  );
  const sourceRecipes = [...new Set(sortedItems.flatMap((item) => Array.isArray(item.sourceRecipes) ? item.sourceRecipes : []))];
  const preferredForms = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.preferredForms ?? []), 16);
  const avoidForms = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.avoidForms ?? []), 20);
  const alternateQueries = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.alternateQueries ?? []), 16);
  const requiredDescriptors = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.requiredDescriptors ?? []), 12);
  const sourceIngredientNames = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.sourceIngredientNames ?? []), 20);
  const recipeTitles = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.recipeTitles ?? []), 16);
  const cuisines = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.cuisines ?? []), 12);
  const tags = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.tags ?? []), 20);
  const recipeSignals = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.recipeSignals ?? []), 20);
  const neighborIngredients = uniqueStrings(sortedItems.flatMap((item) => item.shoppingContext?.neighborIngredients ?? []), 20);
  const matchedRecipeIngredients = uniqueStrings(
    sortedItems.flatMap((item) => item.shoppingContext?.matchedRecipeIngredients ?? []).map((entry) => JSON.stringify(entry)),
    20
  ).map((value) => {
    try {
      return JSON.parse(value);
    } catch {
      return null;
    }
  }).filter(Boolean);
  const matchedStepSnippets = uniqueStrings(
    sortedItems.flatMap((item) => item.shoppingContext?.matchedStepSnippets ?? []).map((entry) => JSON.stringify(entry)),
    20
  ).map((value) => {
    try {
      return JSON.parse(value);
    } catch {
      return null;
    }
  }).filter(Boolean);
  const isPantryStaple = sortedItems.some((item) => Boolean(item.shoppingContext?.isPantryStaple));
  const isOptional = sortedItems.some((item) => Boolean(item.shoppingContext?.isOptional));
  const packageRule = sortedItems
    .map((item) => item.shoppingContext?.packageRule ?? null)
    .find(Boolean) ?? representative.shoppingContext?.packageRule ?? null;
  const storeFitWeight = Math.max(
    ...sortedItems.map((item) => Number(item.shoppingContext?.storeFitWeight ?? 0)),
    Number(representative.shoppingContext?.storeFitWeight ?? 0),
  );
  const mergedContext = {
    ...(representative.shoppingContext ?? {}),
    canonicalName,
    familyKey: canonicalName,
    clusterSize: sortedItems.length,
    mergeDecision: decision.merge ? "merged" : "kept",
    preferredForms,
    avoidForms,
    alternateQueries,
    requiredDescriptors,
    sourceIngredientNames,
    recipeTitles,
    cuisines,
    tags,
    recipeSignals,
    neighborIngredients,
    matchedRecipeIngredients,
    matchedStepSnippets,
    isPantryStaple,
    isOptional,
    packageRule,
    storeFitWeight,
  };

  return {
    name: preferredDisplayName || canonicalName,
    originalName: representative.originalName ?? representative.name ?? canonicalName,
    canonicalName,
    amount: mergedAmount,
    unit: preferredUnit ?? representative.unit ?? "item",
    estimatedPrice: sortedItems.reduce((sum, item) => sum + Number(item.estimatedPrice ?? 0), 0),
    sourceIngredients,
    sourceRecipes,
    shoppingContext: mergedContext,
    confidence: Math.max(...sortedItems.map((item) => Number(item.confidence ?? 0)), Number(decision.confidence ?? 0)),
    reason: [
      decision.reason,
      ...uniqueStrings(sortedItems.map((item) => item.reason), 6),
    ]
      .filter(Boolean)
      .join(" • "),
  };
}

async function reconcileShoppingSpecEntries(entries = []) {
  if (!Array.isArray(entries) || entries.length === 0) {
    return { items: [], summary: { clusterCount: 0, mergedClusterCount: 0, keptClusterCount: 0, lexicalAdjudicationGroupCount: 0 } };
  }

  const keyedClusters = new Map();
  const sortOrder = [...entries].sort((lhs, rhs) => mainShopEntryDisplayScore(rhs) - mainShopEntryDisplayScore(lhs));

  for (const entry of sortOrder) {
    const familyKey = mainShopFamilyKeyForEntry(entry);
    const clusterKey = familyKey || normalizedMergeKey(entry.canonicalName || entry.name || "");
    if (!clusterKey) continue;
    if (!keyedClusters.has(clusterKey)) {
      keyedClusters.set(clusterKey, []);
    }
    keyedClusters.get(clusterKey).push(entry);
  }

  const clusters = [...keyedClusters.entries()].map(([familyKey, items], index) => ({
    index,
    familyKey,
    items,
    needsAdjudication: items.length > 1,
  }));

  const adjudicationGroups = buildAdjudicationGroups(clusters);
  const adjudicationClusters = adjudicationGroups
    .filter((group) => group.length > 1 || group.some((cluster) => cluster.needsAdjudication))
    .map((group, adjudicationIndex) => {
      const flattenedItems = group.flatMap((cluster) => cluster.items);
      const sourceIngredientNames = uniqueStrings(
        flattenedItems.flatMap((entry) => entry.shoppingContext?.sourceIngredientNames ?? []),
        20
      );
      const recipeTitles = uniqueStrings(
        flattenedItems.flatMap((entry) => entry.shoppingContext?.recipeTitles ?? []),
        16
      );
      const cuisines = uniqueStrings(
        flattenedItems.flatMap((entry) => entry.shoppingContext?.cuisines ?? []),
        12
      );
      const lexicalSignals = uniqueStrings(
        flattenedItems.map((entry) => buildLexicalAdjudicationName(entry)),
        12
      );
      return {
        index: adjudicationIndex,
        familyKey: uniqueStrings(group.map((cluster) => cluster.familyKey), 6).join(" | "),
        items: flattenedItems,
        sourceIngredientNames,
        recipeTitles,
        cuisines,
        lexicalSignals,
        defaultMerge: group.length === 1,
      };
    });
  let decisions = new Map();
  try {
    decisions = await resolveMainShopClusterDecisions(adjudicationClusters);
  } catch {}

  const items = [];
  let mergedClusterCount = 0;
  let keptClusterCount = 0;
  const consumedClusterKeys = new Set();

  for (const group of adjudicationGroups) {
    const participatingClusters = group.filter((cluster) => cluster.items.length > 0);
    if (!participatingClusters.length) continue;

    for (const cluster of participatingClusters) {
      consumedClusterKeys.add(cluster.index);
    }

    const flattenedItems = participatingClusters.flatMap((cluster) => cluster.items);
    if (participatingClusters.length === 1 && flattenedItems.length === 1) {
      items.push(flattenedItems[0]);
      continue;
    }

    const groupIndex = adjudicationClusters.findIndex((candidate) =>
      candidate.items.length === flattenedItems.length
      && candidate.items.every((item, itemIndex) => item === flattenedItems[itemIndex])
    );
    const decision = groupIndex >= 0 ? decisions.get(groupIndex) ?? null : null;
    const shouldMerge = decision?.merge ?? adjudicationClusters[groupIndex]?.defaultMerge ?? (participatingClusters.length === 1);

    if (!shouldMerge) {
      keptClusterCount += participatingClusters.length;
      items.push(...flattenedItems);
      continue;
    }

    const merged = mergeShoppingSpecCluster(flattenedItems, decision ?? {});
    if (merged) {
      mergedClusterCount += flattenedItems.length > 1 ? 1 : 0;
      items.push(merged);
    }
  }

  for (const cluster of clusters) {
    if (consumedClusterKeys.has(cluster.index)) continue;
    items.push(...cluster.items);
  }

  const finalizedItems = items.filter((entry) => !shouldExcludeFinalizedMainShopEntry(entry));

  return {
    items: finalizedItems.sort((lhs, rhs) => {
      const lhsKey = mainShopFamilyKeyForEntry(lhs) || normalizedMergeKey(lhs.canonicalName || lhs.name || "");
      const rhsKey = mainShopFamilyKeyForEntry(rhs) || normalizedMergeKey(rhs.canonicalName || rhs.name || "");
      if (lhsKey === rhsKey) {
        return mainShopEntryDisplayScore(rhs) - mainShopEntryDisplayScore(lhs);
      }
      return lhsKey.localeCompare(rhsKey);
    }),
    summary: {
      clusterCount: clusters.length,
      mergedClusterCount,
      keptClusterCount,
      lexicalAdjudicationGroupCount: adjudicationClusters.length,
    },
  };
}

function ingredientTokenSet(value) {
  return new Set(normalizedKey(value).split(" ").filter(Boolean));
}

function scoreNameMatch(a, b) {
  const keyA = normalizedKey(a);
  const keyB = normalizedKey(b);
  if (!keyA || !keyB) return 0;
  if (keyA === keyB) return 100;
  if (keyA.includes(keyB) || keyB.includes(keyA)) return 70;
  const tokensA = ingredientTokenSet(a);
  const tokensB = ingredientTokenSet(b);
  const overlap = [...tokensA].filter((token) => tokensB.has(token)).length;
  if (!overlap) return 0;
  return overlap * 18;
}

function recipeTableConfigForID(recipeID) {
  const normalizedID = String(recipeID ?? "").trim();
  return normalizedID.startsWith("uir_")
    ? {
        recipeTable: "user_import_recipes",
        ingredientTable: "user_import_recipe_ingredients",
        stepTable: "user_import_recipe_steps",
        stepIngredientTable: "user_import_recipe_step_ingredients",
      }
    : {
        recipeTable: "recipes",
        ingredientTable: "recipe_ingredients",
        stepTable: "recipe_steps",
        stepIngredientTable: "recipe_step_ingredients",
      };
}

async function fetchSupabaseTableRows(tableName, select, filters = [], orderClauses = []) {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return [];

  let url = `${SUPABASE_URL}/rest/v1/${tableName}?select=${encodeURIComponent(select)}`;
  for (const filter of filters) {
    if (filter) url += `&${filter}`;
  }
  for (const orderClause of orderClauses) {
    if (orderClause) url += `&order=${orderClause}`;
  }

  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });

  const data = await response.json().catch(() => []);
  if (!response.ok) {
    const message = data?.message ?? data?.error ?? `${tableName} fetch failed`;
    throw new Error(message);
  }

  return Array.isArray(data) ? data : [];
}

async function fetchRecipeDetailRecord(recipeID, fallbackRecipe = {}) {
  const normalizedID = String(recipeID ?? "").trim();
  if (!normalizedID) return null;

  const cached = recipeDetailRecordCache.get(normalizedID);
  if (cached && (Date.now() - cached.cachedAt) < RECIPE_DETAIL_CACHE_TTL_MS) {
    return cached.value;
  }

  const config = recipeTableConfigForID(normalizedID);
  const [recipes, recipeIngredients, recipeSteps] = await Promise.all([
    fetchSupabaseTableRows(
      config.recipeTable,
      PUBLIC_RECIPE_SELECT,
      [`id=eq.${encodeURIComponent(normalizedID)}`],
      []
    ).catch(() => []),
    fetchSupabaseTableRows(
      config.ingredientTable,
      "id,recipe_id,ingredient_id,display_name,quantity_text,image_url,sort_order",
      [`recipe_id=eq.${encodeURIComponent(normalizedID)}`],
      ["sort_order.asc", "created_at.asc"]
    ).catch(() => []),
    fetchSupabaseTableRows(
      config.stepTable,
      "id,recipe_id,step_number,instruction_text,tip_text",
      [`recipe_id=eq.${encodeURIComponent(normalizedID)}`],
      ["step_number.asc", "created_at.asc"]
    ).catch(() => []),
  ]);

  const stepIDs = recipeSteps.map((step) => step.id).filter(Boolean);
  const stepIngredientRows = stepIDs.length
    ? await fetchSupabaseTableRows(
        config.stepIngredientTable,
        "id,recipe_step_id,ingredient_id,display_name,quantity_text,sort_order",
        [`recipe_step_id=in.(${encodeURIComponent(stepIDs.join(","))})`],
        ["recipe_step_id.asc", "sort_order.asc"]
      ).catch(() => [])
    : [];

  const recipeRow = recipes[0] ?? fallbackRecipe;
  const normalized = normalizeRecipeDetail(recipeRow, {
    recipeIngredients,
    recipeSteps,
    stepIngredients: stepIngredientRows,
  });

  const record = {
    id: normalizedID,
    title: normalized.title || fallbackRecipe.title || "",
    cuisine: normalized.cuisine_tags?.[0] || fallbackRecipe.cuisine || "",
    cuisines: uniqueStrings([...(normalized.cuisine_tags ?? []), fallbackRecipe.cuisine], 6),
    tags: uniqueStrings([
      ...(normalized.dietary_tags ?? []),
      ...(normalized.flavor_tags ?? []),
      ...(normalized.occasion_tags ?? []),
      ...(fallbackRecipe.tags ?? []),
    ], 16),
    cookMethod: normalized.cook_method || fallbackRecipe.cookMethod || "",
    recipeType: normalized.recipe_type || fallbackRecipe.recipeType || "",
    category: normalized.category || fallbackRecipe.category || "",
    mainProtein: normalized.main_protein || fallbackRecipe.mainProtein || "",
    ingredients: Array.isArray(normalized.ingredients) ? normalized.ingredients : [],
    steps: Array.isArray(normalized.steps) ? normalized.steps : [],
  };
  recipeDetailRecordCache.set(normalizedID, {
    cachedAt: Date.now(),
    value: record,
  });
  return record;
}

async function buildRecipeLookup(plan, originalItems = []) {
  const entries = Array.isArray(plan?.recipes) ? plan.recipes : [];
  const fallbackRecipesByID = new Map(
    entries
      .map((entry) => {
        const recipe = entry?.recipe ?? {};
        const recipeID = String(recipe.id ?? "").trim();
        if (!recipeID) return null;

        return [
          recipeID,
          {
            id: recipeID,
            title: recipe.title ?? "",
            cuisine: recipe.cuisine ?? "",
            tags: Array.isArray(recipe.tags) ? recipe.tags : [],
            ingredients: Array.isArray(recipe.ingredients) ? recipe.ingredients : [],
            cookMethod: recipe.cookMethod ?? "",
            recipeType: recipe.recipeType ?? "",
            category: recipe.category ?? "",
            mainProtein: recipe.mainProtein ?? "",
          },
        ];
      })
      .filter(Boolean)
  );

  const recipeIDs = new Set(fallbackRecipesByID.keys());
  for (const item of originalItems ?? []) {
    for (const source of item?.sourceIngredients ?? []) {
      const recipeID = String(source?.recipeID ?? "").trim();
      if (recipeID) recipeIDs.add(recipeID);
    }
  }

  const recipePairs = await Promise.all([...recipeIDs].map(async (recipeID) => {
    const fallbackRecipe = fallbackRecipesByID.get(recipeID) ?? {
      id: recipeID,
      title: "",
      cuisine: "",
      tags: [],
      ingredients: [],
      cookMethod: "",
      recipeType: "",
      category: "",
      mainProtein: "",
    };

    const detailed = await fetchRecipeDetailRecord(recipeID, fallbackRecipe).catch(() => null);
    const fallbackIngredients = (fallbackRecipe.ingredients ?? []).map((ingredient) => ({
      display_name: ingredient?.name ?? "",
      quantity_text: [ingredient?.amount, ingredient?.unit].filter(Boolean).join(" ").trim() || null,
      name: ingredient?.name ?? "",
    }));

    const merged = detailed
      ? {
          ...detailed,
          title: detailed.title || fallbackRecipe.title,
          cuisine: detailed.cuisine || fallbackRecipe.cuisine,
          cuisines: uniqueStrings([...(detailed.cuisines ?? []), fallbackRecipe.cuisine], 6),
          tags: uniqueStrings([...(detailed.tags ?? []), ...(fallbackRecipe.tags ?? [])], 16),
          cookMethod: detailed.cookMethod || fallbackRecipe.cookMethod,
          recipeType: detailed.recipeType || fallbackRecipe.recipeType,
          category: detailed.category || fallbackRecipe.category,
          mainProtein: detailed.mainProtein || fallbackRecipe.mainProtein,
          ingredients: Array.isArray(detailed.ingredients) && detailed.ingredients.length
            ? detailed.ingredients
            : fallbackIngredients,
        }
      : {
          id: recipeID,
          title: fallbackRecipe.title,
          cuisine: fallbackRecipe.cuisine,
          cuisines: uniqueStrings([fallbackRecipe.cuisine], 4),
          tags: fallbackRecipe.tags,
          cookMethod: fallbackRecipe.cookMethod,
          recipeType: fallbackRecipe.recipeType,
          category: fallbackRecipe.category,
          mainProtein: fallbackRecipe.mainProtein,
          ingredients: fallbackIngredients,
          steps: [],
        };

    return [recipeID, merged];
  }));

  return new Map(recipePairs.filter(Boolean));
}

function packageRuleForQuery(normalizedQuery, role) {
  if (normalizedQuery === "egg" || normalizedQuery === "eggs") {
    return { packageUnit: "carton", packageSize: 12 };
  }
  if (/\brice\b/.test(normalizedQuery)) {
    return { packageUnit: "bag", packageSize: 4 };
  }
  if (/\b(flour|sugar)\b/.test(normalizedQuery)) {
    return { packageUnit: "bag", packageSize: 3 };
  }
  if (role === "sauce" || /\b(sauce|dressing|juice)\b/.test(normalizedQuery)) {
    return { packageUnit: "bottle", packageSize: 1 };
  }
  if (role === "pantry" || /\b(seasoning|pepper|cinnamon|baking powder|bouillon|curry powder)\b/.test(normalizedQuery)) {
    return { packageUnit: "jar", packageSize: 1 };
  }
  if (/\b(milk|cream|broth|stock)\b/.test(normalizedQuery)) {
    return { packageUnit: "carton", packageSize: 1 };
  }
  if (/\byogurt\b/.test(normalizedQuery)) {
    return { packageUnit: "tub", packageSize: 1 };
  }
  if (/\bcheese\b/.test(normalizedQuery)) {
    return { packageUnit: "pack", packageSize: 1 };
  }
  if (/\b(beans|tomatoes)\b/.test(normalizedQuery)) {
    return { packageUnit: "can", packageSize: 1 };
  }
  if (/\b(chips)\b/.test(normalizedQuery)) {
    return { packageUnit: "bag", packageSize: 1 };
  }
  if (/\b(cilantro|parsley|green onions|green onion|scallions)\b/.test(normalizedQuery)) {
    return { packageUnit: "bunch", packageSize: 1 };
  }
  if (/\b(romaine|lettuce|greens)\b/.test(normalizedQuery)) {
    return { packageUnit: "head", packageSize: 1 };
  }
  return null;
}

function inferQuantityPurchasePlan(normalizedQuery, originalItem, itemContext) {
  const amount = Math.max(1, Math.ceil(Number(originalItem?.amount ?? 1)));
  const rawUnit = normalizeText(originalItem?.unit ?? "");
  const queryTokens = tokenizeItemName(normalizedQuery);
  const proteinishQuery = queryTokens.some((token) => [
    "chicken",
    "shrimp",
    "salmon",
    "steak",
    "beef",
    "pork",
    "lamb",
    "turkey",
    "fish",
    "tilapia",
    "cod",
    "trout",
    "tuna",
    "thigh",
    "thighs",
    "breast",
    "breasts",
    "wing",
    "wings",
    "drumstick",
    "drumsticks",
    "fillet",
    "fillets",
    "cutlet",
    "cutlets",
    "patty",
    "patties",
  ].includes(token));
  const weightBasedUnit = /\b(lb|lbs|pound|pounds|kg|g|gram|grams|oz|ounce|ounces|ml|l|liter|litre|cup|cups|tbsp|tsp)\b/.test(rawUnit);
  const countedPieceUnit = /\b(item|items|each|piece|pieces|count|counts|thigh|thighs|breast|breasts|wing|wings|drumstick|drumsticks|fillet|fillets|cutlet|cutlets|steak|steaks|chop|chops|shrimp|prawns|fish|salmon)\b/.test(rawUnit || normalizedQuery);
  const role = String(itemContext?.role ?? "").trim().toLowerCase();
  const shouldPackByCount = amount > 1
    && !weightBasedUnit
    && (role === "protein" || proteinishQuery || countedPieceUnit);

  if (shouldPackByCount) {
    return {
      quantityStrategy: "single_package_minimum_count",
      minimumContainedQuantity: amount,
      desiredPackageCount: 1,
      expectedPurchaseUnit: "pack",
      quantityReason: "counted_protein_pack",
    };
  }

  return {
    quantityStrategy: "exact_quantity",
    minimumContainedQuantity: null,
    desiredPackageCount: null,
    expectedPurchaseUnit: null,
    quantityReason: "exact_quantity",
  };
}

function inferStoreFitWeight(role, normalizedQuery, itemContext) {
  let weight = 1;
  if (role === "protein") weight += 0.45;
  if (role === "fresh garnish" || role === "salad base") weight += 0.2;
  if (role === "wrapper") weight += 0.15;
  if (role === "dairy") weight += 0.12;
  if (role === "pantry") weight -= 0.35;
  if (PANTRY_STAPLE_SET.has(normalizedQuery)) weight -= 0.2;
  if ((itemContext.cuisines ?? []).some((value) => /nigerian|west african|mexican|thai|vietnamese/i.test(String(value)))) {
    weight += 0.08;
  }
  return Number(Math.max(0.25, Math.min(1.85, weight)).toFixed(2));
}

function sanitizeShoppingUnit(unit, shoppingContext = null) {
  const rawUnit = String(unit ?? "").trim();
  if (!rawUnit) return "item";

  const normalizedUnit = normalizeText(rawUnit);
  if (!normalizedUnit) return "item";

  if (/^[,.;:()[\]\-]/.test(rawUnit)) {
    return "item";
  }

  if (/\b(peeled|diced|chopped|minced|sliced|grated|shredded|crushed|to taste|for garnish|optional)\b/.test(normalizedUnit)) {
    return "item";
  }

  if (shoppingContext?.role === "produce" && !/\b(item|each|banana|bunch|head|lb|kg|g|oz)\b/.test(normalizedUnit)) {
    return "item";
  }

  return rawUnit;
}

function deconstructCompositeItem(originalItem) {
  const sourceIngredients = Array.isArray(originalItem?.sourceIngredients) ? originalItem.sourceIngredients : [];
  const combined = normalizeText([
    originalItem?.name ?? "",
    ...sourceIngredients.map((source) => source?.ingredientName ?? ""),
  ].join(" "));
  const base = {
    ...originalItem,
    originalName: originalItem?.originalName ?? originalItem?.name ?? "",
  };

  const component = (name, overrides = {}) => ({
    ...base,
    ...overrides,
    name,
    originalName: base.originalName || base.name,
    componentOf: base.name ?? base.originalName ?? "",
  });

  if (combined.includes("buffalo chicken")) {
    const chickenName = combined.includes("thigh") ? "chicken thighs" : "chicken breast";
    return [
      component(chickenName),
      component("buffalo sauce", {
        amount: 1,
        unit: "bottle",
      }),
    ];
  }

  return [applySourceCollationToItem(base)];
}

function inferDeterministicIntent(normalizedQuery, itemContext) {
  const produceLikeQueries = new Set([
    "lime",
    "limes",
    "avocado",
    "plantain",
    "ripe plantain",
    "jalapeños",
    "jalape os",
    "jalapenos",
    "persian cucumber",
    "cucumber",
    "bell pepper",
    "cauliflower",
    "banana",
  ]);
  const freshBunchQueries = new Set([
    "cilantro",
    "parsley",
    "basil",
    "green onions",
    "green onion",
    "scallions",
  ]);
  const mentionsPlantain = /\bplantain\b/.test(normalizedQuery)
    || itemContext.sourceIngredientNames.some((name) => /\bplantain\b/i.test(String(name)));
  const requiresRipePlantain = /\bripe\b/.test(normalizedQuery)
    || itemContext.sourceIngredientNames.some((name) => /\bripe\b/i.test(String(name)))
    || (itemContext.matchingRecipeIngredients ?? []).some((entry) => /\bripe\b/i.test(String(entry?.ingredientName ?? "")))
    || (itemContext.matchingStepSnippets ?? []).some((entry) => /\bripe\b/i.test(String(entry?.text ?? "")));
  const inferredShoppingForm = (() => {
    if (mentionsPlantain || produceLikeQueries.has(normalizedQuery)) return "whole_produce";
    if (freshBunchQueries.has(normalizedQuery)) return "fresh_bunch";
    return null;
  })();
  const role = (() => {
    if (["chicken", "shrimp", "salmon", "steak", "eggs"].includes(normalizedQuery)) return "protein";
    if (["cilantro", "green onions", "green onion", "onion", "parsley", "basil", "scallions"].includes(normalizedQuery)) return "fresh garnish";
    if (["cotija cheese", "shredded cheese", "yogurt"].includes(normalizedQuery)) return "dairy";
    if (["rice paper", "rice paper wrappers"].includes(normalizedQuery)) return "wrapper";
    if (["greens", "romaine lettuce", "crispy romaine"].includes(normalizedQuery)) return "salad base";
    if (["seasoning", "black pepper", "cinnamon", "baking powder"].includes(normalizedQuery)) return "pantry";
    if (["skewers", "bamboo skewers"].includes(normalizedQuery)) return "cooking tool";
    if (["bang bang sauce", "cilantro lime caesar dressing", "ranch dressing"].includes(normalizedQuery)) return "sauce";
    if (mentionsPlantain || produceLikeQueries.has(normalizedQuery)) return "produce";
    return "ingredient";
  })();

  const preferredForms = [];
  const avoidForms = [];
  const requiredDescriptors = [];
  const alternateQueries = [];
  const searchQueries = [];
  const verificationTerms = [];
  let resolvedQuery = normalizedQuery;

  switch (normalizedQuery) {
    case "chicken":
      preferredForms.push("boneless skinless chicken breasts", "boneless skinless chicken thighs", "chicken breast");
      avoidForms.push("whole chicken", "rotisserie chicken", "wings", "nuggets", "breaded chicken", "fried chicken");
      break;
    case "shrimp":
      preferredForms.push("raw shrimp", "peeled deveined shrimp", "frozen raw shrimp");
      avoidForms.push("shrimp ring", "shrimp platter", "cocktail shrimp", "breaded shrimp", "tempura shrimp");
      requiredDescriptors.push("raw");
      alternateQueries.push("raw peeled deveined shrimp");
      resolvedQuery = "raw shrimp";
      break;
    case "cilantro":
      preferredForms.push("fresh cilantro", "cilantro bunch", "coriander bunch");
      avoidForms.push("dried cilantro", "cilantro spice", "cilantro paste", "cilantro sauce");
      requiredDescriptors.push("fresh");
      searchQueries.push("fresh cilantro", "cilantro bunch");
      verificationTerms.push("cilantro", "coriander");
      resolvedQuery = "fresh cilantro";
      break;
    case "parsley":
      preferredForms.push("fresh parsley", "parsley bunch", "italian parsley");
      avoidForms.push("dried parsley", "parsley flakes", "parsley paste");
      requiredDescriptors.push("fresh");
      searchQueries.push("fresh parsley", "parsley bunch");
      verificationTerms.push("parsley");
      resolvedQuery = "fresh parsley";
      break;
    case "basil":
      preferredForms.push("fresh basil", "basil bunch", "basil leaves");
      avoidForms.push("dried basil", "basil paste", "basil pesto");
      requiredDescriptors.push("fresh");
      searchQueries.push("fresh basil", "basil bunch");
      verificationTerms.push("basil");
      resolvedQuery = "fresh basil";
      break;
    case "green onions":
    case "green onion":
    case "onion":
      preferredForms.push("green onions bunch", "scallions", "green onions");
      avoidForms.push("yellow onions", "white onions", "fried onions");
      requiredDescriptors.push("green");
      searchQueries.push("green onions bunch", "scallions");
      verificationTerms.push("green onions", "scallions");
      resolvedQuery = "green onions";
      break;
    case "cotija cheese":
      preferredForms.push("cotija cheese", "queso cotija", "mexican crumbling cheese");
      avoidForms.push("cheddar", "mozzarella", "processed cheese", "cheese dip", "nacho cheese");
      requiredDescriptors.push("cotija");
      alternateQueries.push("mexican crumbling cheese");
      break;
    case "rice paper":
      preferredForms.push("rice paper wrappers", "spring roll wrappers", "rice paper");
      avoidForms.push("rice noodles", "rice vinegar", "rice flour");
      requiredDescriptors.push("wrappers");
      resolvedQuery = "rice paper wrappers";
      break;
    case "greens":
      preferredForms.push("mixed greens", "spring mix", "baby spinach");
      avoidForms.push("green beans", "mustard greens", "collard greens");
      resolvedQuery = "mixed greens";
      break;
    case "romaine lettuce":
    case "crispy romaine":
      preferredForms.push("romaine hearts", "romaine lettuce");
      avoidForms.push("iceberg lettuce", "cabbage", "spring mix");
      requiredDescriptors.push("romaine");
      resolvedQuery = "romaine hearts";
      break;
    case "eggs":
    case "egg":
      preferredForms.push("dozen eggs", "large eggs", "large white eggs");
      avoidForms.push("hard boiled eggs", "liquid eggs", "egg bites");
      requiredDescriptors.push("large");
      resolvedQuery = "dozen eggs";
      break;
    case "cooked buffalo chicken":
      preferredForms.push("cooked buffalo chicken", "buffalo chicken breast", "buffalo chicken strips");
      avoidForms.push("rotisserie chicken", "buffalo dip", "buffalo wings", "buffalo frozen dinner");
      requiredDescriptors.push("buffalo");
      alternateQueries.push("buffalo chicken strips");
      break;
    case "shredded cheese":
      preferredForms.push("mexican shredded cheese", "shredded cheese", "mozzarella shredded cheese");
      avoidForms.push("cheese slices", "cheese dip");
      requiredDescriptors.push("shredded");
      resolvedQuery = "mexican shredded cheese";
      break;
    case "seasoning":
      preferredForms.push("all purpose seasoning", "seasoning blend");
      break;
    case "skewers":
      preferredForms.push("bamboo skewers", "wood skewers");
      avoidForms.push("prepared skewers", "meat skewers");
      requiredDescriptors.push("bamboo");
      resolvedQuery = "bamboo skewers";
      break;
    case "bang bang sauce":
      preferredForms.push("bang bang sauce");
      avoidForms.push("plain hot sauce", "plain mayonnaise", "sriracha");
      requiredDescriptors.push("bang");
      requiredDescriptors.push("sauce");
      break;
    case "sugar":
      preferredForms.push("granulated sugar", "white sugar");
      avoidForms.push("icing sugar", "powdered sugar", "brown sugar");
      requiredDescriptors.push("granulated");
      resolvedQuery = "granulated sugar";
      break;
    case "avocado":
      preferredForms.push("avocado", "hass avocado", "avocado bag");
      avoidForms.push("guacamole", "avocado oil", "avocado dressing");
      requiredDescriptors.push("avocado");
      searchQueries.push("fresh avocado", "hass avocado", "avocados");
      verificationTerms.push("avocado", "avocados");
      break;
    case "lime":
    case "limes":
      preferredForms.push("fresh lime", "limes", "lime 1 each", "whole lime");
      avoidForms.push("lime juice", "lime cordial", "lime concentrate", "lime extract", "lime soda");
      requiredDescriptors.push("fresh");
      searchQueries.push("fresh limes", "limes", "whole lime");
      verificationTerms.push("lime", "limes");
      resolvedQuery = "lime";
      break;
    case "ripe plantain":
    case "plantain":
      preferredForms.push("plantain", "ripe plantain", "fresh plantain", "plantain banana");
      avoidForms.push(
        "plantain chips",
        "plantain crisps",
        "green plantain",
        "plantain flour",
        "plantain tostones",
        "sweet plantain chips"
      );
      if (requiresRipePlantain) {
        requiredDescriptors.push("ripe");
      }
      alternateQueries.push("fresh plantain", "plantain banana");
      searchQueries.push("fresh plantain", requiresRipePlantain ? "ripe plantain" : "plantain", "plantain banana");
      verificationTerms.push("plantain");
      resolvedQuery = "plantain";
      break;
    case "jalapeños":
    case "jalape os":
    case "jalapenos":
      preferredForms.push("fresh jalapeños", "jalapeño peppers");
      avoidForms.push("pickled jalapeños", "jalapeño chips", "chili sauce");
      requiredDescriptors.push("fresh");
      searchQueries.push("fresh jalapeños", "jalapeño peppers", "jalapenos");
      verificationTerms.push("jalapeño", "jalapeno");
      resolvedQuery = "fresh jalapeños";
      break;
    default:
      break;
  }

  if (itemContext.recipeSignals.some((signal) => /caesar|salad|romaine/i.test(signal)) && normalizedQuery === "greens") {
    preferredForms.unshift("romaine hearts");
    requiredDescriptors.push("romaine");
    resolvedQuery = "romaine hearts";
  }

  if (mentionsPlantain && !preferredForms.some((value) => /\bplantain\b/i.test(value))) {
    preferredForms.unshift("plantain", "ripe plantain");
    avoidForms.push("plantain chips", "green plantain", "plantain flour", "plantain tostones");
    alternateQueries.push("fresh plantain", "plantain banana");
    resolvedQuery = "plantain";
  }

  if (mentionsPlantain && requiresRipePlantain) {
    requiredDescriptors.push("ripe");
  }

  if (inferredShoppingForm === "whole_produce") {
    verificationTerms.push(normalizedQuery, resolvedQuery);
    if (!searchQueries.length) {
      searchQueries.push(resolvedQuery, `fresh ${resolvedQuery}`);
    }
  }

  if (inferredShoppingForm === "fresh_bunch") {
    verificationTerms.push(normalizedQuery, resolvedQuery);
    if (!requiredDescriptors.includes("fresh")) {
      requiredDescriptors.push("fresh");
    }
    if (!searchQueries.length) {
      searchQueries.push(`fresh ${normalizedQuery}`, `${normalizedQuery} bunch`);
    }
  }

  const isOptional = /optional/.test(normalizedQuery)
    || itemContext.sourceIngredientNames.some((name) => /optional/i.test(name));

  const exactness = (() => {
    if (["rice paper", "rice paper wrappers", "bang bang sauce", "cilantro lime caesar dressing"].includes(normalizedQuery)) return "strict_exact";
    if (isOptional) return "optional";
    if (["cotija cheese", "shredded cheese", "greens", "romaine lettuce", "jalapeños", "jalape os"].includes(normalizedQuery)) return "flexible_substitute";
    if (mentionsPlantain) return "preferred_exact";
    return "preferred_exact";
  })();

  const substitutionPolicy = exactness === "flexible_substitute"
    ? "flexible"
    : exactness === "optional"
      ? "optional"
      : "strict";

  const isPantryStaple = role === "pantry" || PANTRY_STAPLE_SET.has(normalizedQuery);
  const packageRule = packageRuleForQuery(normalizedQuery, role);
  const storeFitWeight = inferStoreFitWeight(role, normalizedQuery, itemContext);

  return {
    role,
    resolvedQuery,
    fallbackSearchQuery: deriveFallbackSearchQuery(resolvedQuery, itemContext) || deriveFallbackSearchQuery(normalizedQuery, itemContext),
    exactness,
    isPantryStaple,
    isOptional,
    packageRule,
    storeFitWeight,
    preferredForms: uniqueStrings(preferredForms, 8),
    avoidForms: uniqueStrings(avoidForms, 10),
    requiredDescriptors: uniqueStrings(requiredDescriptors, 6),
    alternateQueries: uniqueStrings(alternateQueries, 6),
    searchQueries: uniqueStrings(searchQueries, 6),
    verificationTerms: uniqueStrings(verificationTerms, 6),
    shoppingForm: inferredShoppingForm,
    expectedPurchaseUnit: inferredShoppingForm === "fresh_bunch" ? "bunch" : inferredShoppingForm === "whole_produce" ? "item" : null,
    substitutionPolicy,
    confidence: preferredForms.length > 0 ? 0.84 : 0.58,
    reason: preferredForms.length > 0 ? "deterministic_recipe_spec" : "deterministic_default",
  };
}

function collectMatchingRecipeContext(itemName, sourceIngredientNames, recipeContexts) {
  const matchingRecipeIngredients = [];
  const matchingStepSnippets = [];

  for (const recipe of recipeContexts) {
    for (const ingredient of recipe.ingredients ?? []) {
      const displayName = ingredient?.display_name ?? ingredient?.name ?? "";
      const score = Math.max(
        scoreNameMatch(itemName, displayName),
        ...sourceIngredientNames.map((sourceName) => scoreNameMatch(sourceName, displayName)),
      );
      if (score >= 70) {
        matchingRecipeIngredients.push({
          recipeTitle: recipe.title,
          ingredientName: displayName,
          quantityText: ingredient?.quantity_text ?? null,
        });
      }
    }

    const relevantIngredientNames = new Set(
      matchingRecipeIngredients
        .filter((entry) => entry.recipeTitle === recipe.title)
        .map((entry) => normalizeText(entry.ingredientName))
    );

    for (const step of recipe.steps ?? []) {
      const instruction = step?.instruction ?? step?.instruction_text ?? "";
      if (!instruction) continue;
      const normalizedInstruction = normalizeText(instruction);
      const matchesSource = sourceIngredientNames.some((sourceName) => normalizedInstruction.includes(normalizeText(sourceName)));
      const matchesIngredient = [...relevantIngredientNames].some((name) => name && normalizedInstruction.includes(name));
      if (matchesSource || matchesIngredient) {
        matchingStepSnippets.push({
          recipeTitle: recipe.title,
          text: truncateText(instruction, 160),
        });
      }
    }
  }

  return {
    matchingRecipeIngredients: matchingRecipeIngredients.slice(0, 8),
    matchingStepSnippets: matchingStepSnippets.slice(0, 8),
  };
}

function buildItemContext(originalItem, recipeLookup) {
  const sourceIngredients = Array.isArray(originalItem?.sourceIngredients) ? originalItem.sourceIngredients : [];
  const recipeIDs = uniqueStrings(sourceIngredients.map((source) => source?.recipeID), 8);
  const recipeContexts = recipeIDs.map((id) => recipeLookup.get(String(id))).filter(Boolean);
  const sourceIngredientNames = uniqueStrings(sourceIngredients.map((source) => source?.ingredientName), 10);
  const sourceEdgeIDs = sourceEdgeIDsForItem(originalItem);
  const alternativeNames = Array.isArray(originalItem?.shoppingCollation?.alternativeNames)
    ? originalItem.shoppingCollation.alternativeNames
    : [];
  const recipeTitles = uniqueStrings(recipeContexts.map((recipe) => recipe.title), 6);
  const cuisines = uniqueStrings(recipeContexts.flatMap((recipe) => recipe.cuisines ?? recipe.cuisine ?? []), 8);
  const tags = uniqueStrings(recipeContexts.flatMap((recipe) => recipe.tags ?? []), 16);
  const recipeSignals = uniqueStrings([
    ...recipeContexts.map((recipe) => recipe.cookMethod).filter(Boolean),
    ...recipeContexts.map((recipe) => recipe.recipeType).filter(Boolean),
    ...recipeContexts.map((recipe) => recipe.category).filter(Boolean),
    ...recipeContexts.map((recipe) => recipe.mainProtein).filter(Boolean),
    ...tags,
  ], 20);

  const sourceNameSet = new Set(sourceIngredientNames.map((name) => normalizeText(name)));
  const neighborIngredients = uniqueStrings(
    recipeContexts.flatMap((recipe) => (recipe.ingredients ?? [])
      .map((ingredient) => ingredient?.display_name ?? ingredient?.name ?? "")
      .filter((name) => {
        const normalizedName = normalizeText(name);
        return normalizedName && !sourceNameSet.has(normalizedName) && normalizedName !== normalizeText(originalItem?.name);
      })),
    16,
  );

  const { matchingRecipeIngredients, matchingStepSnippets } = collectMatchingRecipeContext(
    originalItem?.name,
    sourceIngredientNames,
    recipeContexts
  );

  const baseQuery = normalizeText(originalItem?.name || sourceIngredientNames[0] || "");
  const deterministic = inferDeterministicIntent(baseQuery, {
    recipeTitles,
    cuisines,
    tags,
    recipeSignals,
    sourceIngredientNames,
    neighborIngredients,
    matchingStepSnippets,
  });
  const quantityPlan = inferQuantityPurchasePlan(baseQuery, originalItem, deterministic);

  return {
    originalName: originalItem?.name ?? baseQuery,
    normalizedQuery: baseQuery,
    originalAmount: Number(originalItem?.amount ?? 1),
    originalUnit: String(originalItem?.unit ?? ""),
    sourceIngredientNames,
    sourceEdgeIDs,
    alternativeNames,
    recipeTitles,
    cuisines,
    tags,
    recipeSignals,
    neighborIngredients,
    matchingRecipeIngredients,
    matchingStepSnippets,
    ...deterministic,
    ...quantityPlan,
  };
}

function shouldResolveWithLLM(context) {
  return (
    AMBIGUOUS_QUERY_SET.has(context.normalizedQuery) ||
    context.preferredForms.length > 0 ||
    context.matchingStepSnippets.length > 0 ||
    context.sourceIngredientNames.length > 0 ||
    context.sourceIngredientNames.some((name) => /additional|optional|or |\(|\)|-|crispy|creamy|tangy|salad|sauce/i.test(name))
  );
}

function buildIntentPrompt(items) {
  return [
    "You convert recipe ingredients into standardized shopping specs for Instacart.",
    "The goal is to preserve what the recipe actually needs before any store selection happens.",
    "Read the recipe titles, matched ingredient rows, neighboring ingredients, and step snippets carefully.",
    "Output exactly one grocery-shopping spec for each input item index. Do not add new items or omit input indexes.",
    "",
    "Rules:",
    "- Standardize the ingredient into the exact or closest store-search-friendly form that still matches the recipe.",
    "- Treat each input as a source-backed shopping demand. Keep the canonical family aligned with the provided sourceEdgeIDs; never split one source ingredient into multiple rows unless it is an explicit multi-component prepared item.",
    "- If the input name contains an alternative such as A or B, A / B, or A (or B), choose the first practical shopping ingredient as the canonical item and put the other names in alternateQueries or avoidForms as appropriate. Do not create a second shopping row for the unchosen alternative.",
    "- Prefer the true grocery family over prep adjectives: shredded chicken breast should standardize to chicken breast, bird eye chilies should standardize to bird eye chili, and similar form-only variants should collapse to the shoppable base grocery.",
    "- Packaging and prep words like cooked, instant, prepared, cup, bag, pack, chopped, shredded, fresh, frozen, boneless, skinless, boxed, and organic are descriptors unless the recipe clearly requires them as a product form.",
    "- Use step context to infer form: raw vs cooked, shredded vs block, romaine vs mixed greens, granulated sugar vs icing sugar, fresh herb vs dried spice, wrappers vs noodles.",
    "- Do not invent a different ingredient family.",
    "- Keep materially different groceries separate: chicken breast vs chicken thigh, rice vs cauliflower rice, green onion vs onion, chili powder vs chili pepper, coconut milk vs coconut water.",
    "- If the recipe text implies a specific descriptor, keep it in requiredDescriptors.",
    "- Mark pantry staples honestly. Salt, pepper, common oils, and common seasoning jars should usually be pantry staples unless the recipe makes them the hero.",
    "- Mark optional items honestly. Optional toppings or garnish-only extras can be optional.",
    "- packageRule should only be set when the shopping unit is obvious: carton eggs, bag rice/flour/sugar/chips, jar seasoning, bottle sauce/dressing/juice, pack cheese, tub yogurt, bunch herbs, head romaine/lettuce, carton broth/stock/milk.",
    "- storeFitWeight should stay between 0.25 and 1.85 and only reflect how strongly this item should influence store selection.",
    "- preferredForms should be concrete retail-style product forms.",
    "- avoidForms should contain product forms that would break the recipe.",
    "- alternateQueries should be additional search phrases worth trying if the main query fails.",
    "- fallbackSearchQuery should be a grocery-safe backup search phrase that is broader or simpler than the main query, for example persian cucumbers -> cucumbers or ripe plantain -> plantain.",
    "- exactness must be one of: strict_exact, preferred_exact, flexible_substitute, optional.",
    "- strict_exact means reject loose substitutions.",
    "- preferred_exact means exact is preferred but a close substitute may still be reasonable later if policy allows.",
    "- flexible_substitute means a close culinary substitute is acceptable.",
    "- optional means the item can be skipped or loosely substituted.",
    "- quantityStrategy should be single_package_minimum_count when the item is a counted protein or seafood item that should be bought as one package containing at least the requested count. In that case, set minimumContainedQuantity to the requested count, desiredPackageCount to 1, and expectedPurchaseUnit to pack.",
    "- quantityStrategy should be exact_quantity for weight-based or non-counted items.",
    "- Return JSON only.",
    "",
    JSON.stringify(items, null, 2),
  ].join("\n");
}

async function resolveAmbiguousIntents(items) {
  if (!openai || items.length === 0) return new Map();

  const response = await openai.chat.completions.create({
    model: INTENT_MODEL,
    ...chatCompletionTemperatureParams(INTENT_MODEL),
    response_format: {
      type: "json_schema",
      json_schema: {
        name: "instacart_recipe_shopping_specs",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            items: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  index: { type: "integer" },
                  canonicalName: { type: "string" },
                  query: { type: "string" },
                  role: { type: "string" },
                  exactness: { type: "string" },
                  preferredForms: { type: "array", items: { type: "string" } },
                  avoidForms: { type: "array", items: { type: "string" } },
                  alternateQueries: { type: "array", items: { type: "string" } },
                  requiredDescriptors: { type: "array", items: { type: "string" } },
                  fallbackSearchQuery: { type: "string" },
                  substitutionPolicy: { type: "string" },
                  isPantryStaple: { type: "boolean" },
                  isOptional: { type: "boolean" },
                  quantityStrategy: { type: "string" },
                  minimumContainedQuantity: { type: ["number", "null"] },
                  desiredPackageCount: { type: ["number", "null"] },
                  expectedPurchaseUnit: { type: ["string", "null"] },
                  packageRule: {
                    type: ["object", "null"],
                    additionalProperties: false,
                    properties: {
                      packageUnit: { type: "string" },
                      packageSize: { type: "number" },
                    },
                    required: ["packageUnit", "packageSize"],
                  },
                  storeFitWeight: { type: "number" },
                  confidence: { type: "number" },
                  reason: { type: "string" },
                },
                required: [
                  "index",
                  "canonicalName",
                  "query",
                  "role",
                  "exactness",
                  "preferredForms",
                  "avoidForms",
                  "alternateQueries",
                  "requiredDescriptors",
                  "fallbackSearchQuery",
                  "substitutionPolicy",
                  "isPantryStaple",
                  "isOptional",
                  "quantityStrategy",
                  "minimumContainedQuantity",
                  "desiredPackageCount",
                  "expectedPurchaseUnit",
                  "packageRule",
                  "storeFitWeight",
                  "confidence",
                  "reason",
                ],
              },
            },
          },
          required: ["items"],
        },
      },
    },
    messages: [
      { role: "system", content: "You are Ounje's grocery spec standardizer. Standardize recipe ingredients into the exact shopping form a grocer search should use." },
      { role: "user", content: buildIntentPrompt(items) },
    ],
  });

  const content = response.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(content);
  return new Map((parsed.items ?? []).map((entry) => [entry.index, entry]));
}

export async function resolveShoppingIntents({ originalItems, normalizedEntries = null, plan }) {
  const recipeLookup = await buildRecipeLookup(plan, originalItems);

  const baseEntries = Array.isArray(normalizedEntries) && normalizedEntries.length === originalItems.length
    ? normalizedEntries
    : (originalItems ?? []).map((item) => ({
        name: item?.name ?? "",
        query: item?.name ?? "",
        confidence: 0.25,
        reason: "cart_source_name",
      }));

  const contexts = baseEntries.map((_, index) => buildItemContext(originalItems[index], recipeLookup));

  const ambiguous = contexts
    .map((context, index) => ({ index, context }))
    .filter(({ context }) => shouldResolveWithLLM(context))
    .map(({ index, context }) => ({
      index,
      originalName: context.originalName,
      normalizedQuery: context.normalizedQuery,
      originalAmount: context.originalAmount,
      originalUnit: context.originalUnit,
      sourceIngredientNames: context.sourceIngredientNames,
      recipeTitles: context.recipeTitles,
      cuisines: context.cuisines,
      recipeSignals: context.recipeSignals,
      neighborIngredients: context.neighborIngredients,
      matchedRecipeIngredients: context.matchingRecipeIngredients,
      matchedStepSnippets: context.matchingStepSnippets,
      deterministicRole: context.role,
      deterministicQuery: context.resolvedQuery,
      deterministicExactness: context.exactness,
      deterministicPreferredForms: context.preferredForms,
      deterministicAvoidForms: context.avoidForms,
      deterministicAlternateQueries: context.alternateQueries,
      deterministicRequiredDescriptors: context.requiredDescriptors,
      deterministicFallbackSearchQuery: context.fallbackSearchQuery,
      deterministicSubstitutionPolicy: context.substitutionPolicy,
      deterministicIsPantryStaple: context.isPantryStaple,
      deterministicIsOptional: context.isOptional,
      deterministicPackageRule: context.packageRule,
      deterministicStoreFitWeight: context.storeFitWeight,
      deterministicQuantityStrategy: context.quantityStrategy,
      deterministicMinimumContainedQuantity: context.minimumContainedQuantity,
      deterministicDesiredPackageCount: context.desiredPackageCount,
      sourceEdgeIDs: context.sourceEdgeIDs,
      deterministicAlternativeNames: context.alternativeNames,
    }));

  let resolvedByIndex = new Map();
  try {
    resolvedByIndex = await resolveAmbiguousIntents(ambiguous);
  } catch {}

  return baseEntries.map((entry, index) => {
    const context = contexts[index];
    const original = originalItems[index] ?? {};
    const collation = original.shoppingCollation ?? canonicalizeIngredientName(original.name ?? entry.name ?? "");
    const resolved = resolvedByIndex.get(index);
    const deterministicQuery = normalizeText(context.resolvedQuery || context.normalizedQuery || entry.query || originalItems[index]?.name);
    const rawResolvedQuery = normalizeText(resolved?.query || deterministicQuery);
    const deterministicFamily = normalizeMainShopFamilyName(deterministicQuery);
    const resolvedFamily = normalizeMainShopFamilyName(rawResolvedQuery);
    const shouldAnchorToDeterministicQuery = Boolean(
      deterministicQuery &&
      deterministicFamily &&
      context.requiredDescriptors.length > 0 &&
      (!resolvedFamily || resolvedFamily === deterministicFamily)
    );
    const rawQuery = shouldAnchorToDeterministicQuery ? deterministicQuery : rawResolvedQuery;
    const query = normalizeMainShopFamilyName(rawQuery) || rawQuery;
    const exactness = String(resolved?.exactness || context.exactness || "preferred_exact").trim().toLowerCase();
    const substitutionPolicy = normalizeSubstitutionPolicy(
      resolved?.substitutionPolicy
        || context.substitutionPolicy
        || (exactness === "flexible_substitute" ? "flexible" : exactness === "optional" ? "optional" : "strict")
    );
    const preferredForms = uniqueStrings([query, ...(resolved?.preferredForms ?? []), ...context.preferredForms], 10);
    const avoidForms = uniqueStrings([...(resolved?.avoidForms ?? []), ...context.avoidForms], 12);
    const alternateQueries = uniqueStrings([...(resolved?.alternateQueries ?? []), ...context.alternateQueries], 8);
    const requiredDescriptors = uniqueStrings([...(resolved?.requiredDescriptors ?? []), ...context.requiredDescriptors], 8);
    const fallbackSearchQuery = normalizeText(
      resolved?.fallbackSearchQuery
        || context.fallbackSearchQuery
        || deriveFallbackSearchQuery(query, context)
        || deriveFallbackSearchQuery(context.resolvedQuery || context.normalizedQuery, context)
        || ""
    );
    const searchQueries = uniqueStrings([...(resolved?.searchQueries ?? []), ...context.searchQueries], 8);
    const verificationTerms = uniqueStrings([...(resolved?.verificationTerms ?? []), ...context.verificationTerms], 8);
    const rawCanonicalName = String(
      shouldAnchorToDeterministicQuery
        ? deterministicQuery
        : (resolved?.canonicalName || query || context.normalizedQuery || originalItems[index]?.name || "")
    ).trim();
    const canonicalName = collation.canonicalName
      || normalizeMainShopFamilyName(rawCanonicalName)
      || normalizeMainShopFamilyName(deterministicQuery)
      || rawCanonicalName;
    const canonicalKey = collation.canonicalKey || normalizeMainShopFamilyName(canonicalName) || canonicalName;
    const role = String(resolved?.role || context.role || "ingredient").trim();
    const isPantryStaple = Boolean(resolved?.isPantryStaple ?? context.isPantryStaple ?? false);
    const isOptional = Boolean(resolved?.isOptional ?? context.isOptional ?? exactness === "optional");
    const packageRule = resolved?.packageRule ?? context.packageRule ?? null;
    const storeFitWeight = Number(resolved?.storeFitWeight ?? context.storeFitWeight ?? 1);
    const quantityStrategy = String(resolved?.quantityStrategy ?? context.quantityStrategy ?? "exact_quantity").trim() || "exact_quantity";
    const resolvedMinimumContainedQuantity = resolved?.minimumContainedQuantity;
    const contextMinimumContainedQuantity = context.minimumContainedQuantity;
    const minimumContainedQuantity = resolvedMinimumContainedQuantity != null && Number.isFinite(Number(resolvedMinimumContainedQuantity))
      ? Number(resolvedMinimumContainedQuantity)
      : contextMinimumContainedQuantity != null && Number.isFinite(Number(contextMinimumContainedQuantity))
        ? Number(contextMinimumContainedQuantity)
        : null;
    const resolvedDesiredPackageCount = resolved?.desiredPackageCount;
    const contextDesiredPackageCount = context.desiredPackageCount;
    const desiredPackageCount = resolvedDesiredPackageCount != null && Number.isFinite(Number(resolvedDesiredPackageCount))
      ? Number(resolvedDesiredPackageCount)
      : contextDesiredPackageCount != null && Number.isFinite(Number(contextDesiredPackageCount))
        ? Number(contextDesiredPackageCount)
        : null;

    return {
      name: entry.name || originalItems[index]?.name || canonicalName,
      canonicalName,
      query,
      confidence: Number(resolved?.confidence ?? entry.confidence ?? context.confidence ?? 0.4),
      reason: String(resolved?.reason || context.reason || entry.reason || "shopping_spec"),
      shoppingContext: {
        canonicalName,
        role,
        exactness,
        preferredForms,
        avoidForms,
        alternateQueries,
        requiredDescriptors,
        fallbackSearchQuery,
        searchQueries,
        verificationTerms,
        shoppingForm: resolved?.shoppingForm ?? context.shoppingForm ?? null,
        expectedPurchaseUnit: resolved?.expectedPurchaseUnit ?? context.expectedPurchaseUnit ?? (quantityStrategy === "single_package_minimum_count" ? "pack" : null),
        substitutionPolicy,
        isPantryStaple,
        isOptional,
        quantityStrategy,
        minimumContainedQuantity: Number.isFinite(minimumContainedQuantity) ? minimumContainedQuantity : null,
        desiredPackageCount: Number.isFinite(desiredPackageCount) ? desiredPackageCount : null,
        packageRule,
        storeFitWeight,
        quantityReason: resolved?.quantityReason ?? context.quantityReason ?? null,
        canonicalKey,
        sourceEdgeIDs: collation.sourceEdgeIDs ?? sourceEdgeIDsForItem(original),
        alternativeNames: uniqueStrings([
          ...(collation.alternativeNames ?? []),
          ...(resolved?.alternativeNames ?? []),
        ], 12),
        coverageState: (collation.sourceEdgeIDs ?? sourceEdgeIDsForItem(original)).length ? "covered" : "fallback",
        sourceIngredientNames: context.sourceIngredientNames,
        recipeTitles: context.recipeTitles,
        cuisines: context.cuisines,
        tags: context.tags,
        recipeSignals: context.recipeSignals,
        neighborIngredients: context.neighborIngredients,
        matchedRecipeIngredients: context.matchingRecipeIngredients,
        matchedStepSnippets: context.matchingStepSnippets,
        originalName: context.originalName,
        normalizedQuery: context.normalizedQuery,
        originalAmount: context.originalAmount,
        originalUnit: context.originalUnit,
        familyKey: canonicalKey,
      },
      canonicalKey,
      sourceEdgeIDs: collation.sourceEdgeIDs ?? sourceEdgeIDsForItem(original),
      alternativeNames: uniqueStrings(collation.alternativeNames ?? [], 12),
      coverageState: (collation.sourceEdgeIDs ?? sourceEdgeIDsForItem(original)).length ? "covered" : "fallback",
    };
  });
}

export async function buildShoppingSpecEntries({ originalItems, plan = null }) {
  const recipeLookup = await buildRecipeLookup(plan, originalItems);
  const expandedItems = (originalItems ?? []).flatMap((item) => {
    const bucketKind = genericBucketKindForName(item?.name ?? item?.canonicalName ?? "");
    if (bucketKind) {
      return [];
    }
    return deconstructCompositeItem(item);
  });
  const resolvedItems = await resolveShoppingIntents({
    originalItems: expandedItems,
    plan,
  });

  const collapsedByKey = new Map();

  for (let index = 0; index < resolvedItems.length; index += 1) {
    const resolved = resolvedItems[index];
    const original = expandedItems[index] ?? {};
    const shoppingContext = resolved.shoppingContext ?? {};
    const collation = original.shoppingCollation ?? canonicalizeIngredientName(original.name ?? resolved.query ?? "");
    const canonicalName = String(collation.canonicalName || shoppingContext.canonicalName || resolved.canonicalName || resolved.query || original.name || "").trim();
    const roleKey = String(shoppingContext.role ?? "ingredient").trim().toLowerCase();
    const canonicalKey = String(collation.canonicalKey || shoppingContext.canonicalKey || normalizedMergeKey(canonicalName)).trim();
    const key = [canonicalKey, roleKey].join("::");
    const sourceEdgeIDs = collation.sourceEdgeIDs ?? sourceEdgeIDsForItem(original);
    const alternativeNames = uniqueStrings([
      ...(collation.alternativeNames ?? []),
      ...(resolved.alternativeNames ?? []),
      ...(shoppingContext.alternativeNames ?? []),
    ], 12);

    const nextEntry = {
      name: resolved.query,
      originalName: original.originalName ?? original.name ?? resolved.query,
      canonicalName,
      canonicalKey,
      amount: Math.max(0, Number(original.amount ?? 1)),
      unit: original.unit || "item",
      estimatedPrice: Number(original.estimatedPrice ?? 0),
      sourceIngredients: Array.isArray(original.sourceIngredients) ? original.sourceIngredients : [],
      sourceEdgeIDs,
      alternativeNames,
      coverageState: sourceEdgeIDs.length ? "covered" : "fallback",
      sourceRecipes: uniqueStrings([
        ...(Array.isArray(original.sourceRecipes) ? original.sourceRecipes : []),
        ...(shoppingContext.recipeTitles ?? []),
      ], 10),
      shoppingContext: {
        ...shoppingContext,
        canonicalKey,
        familyKey: canonicalKey,
        sourceEdgeIDs,
        alternativeNames,
        coverageState: sourceEdgeIDs.length ? "covered" : "fallback",
      },
      confidence: resolved.confidence,
      reason: resolved.reason,
    };

    if (collapsedByKey.has(key)) {
      const existing = collapsedByKey.get(key);
      if (shouldPreferMergeMax(existing, nextEntry)) {
        existing.amount = Math.max(existing.amount, nextEntry.amount);
      } else {
        existing.amount += nextEntry.amount;
      }
      existing.estimatedPrice += nextEntry.estimatedPrice;
      existing.sourceIngredients = [
        ...existing.sourceIngredients,
        ...nextEntry.sourceIngredients,
      ]
        .filter(Boolean)
        .filter((source, sourceIndex, sourceArray) =>
          sourceArray.findIndex((candidate) =>
            String(candidate?.recipeID ?? "").trim() === String(source?.recipeID ?? "").trim()
            && normalizeText(candidate?.ingredientName) === normalizeText(source?.ingredientName)
            && String(candidate?.unit ?? "").trim().toLowerCase() === String(source?.unit ?? "").trim().toLowerCase()
          ) === sourceIndex
        );
      existing.sourceRecipes = [...new Set([...(existing.sourceRecipes ?? []), ...(nextEntry.sourceRecipes ?? [])])];
      existing.sourceEdgeIDs = uniqueStrings([...(existing.sourceEdgeIDs ?? []), ...sourceEdgeIDs], 80);
      existing.alternativeNames = uniqueStrings([...(existing.alternativeNames ?? []), ...alternativeNames], 24);
      existing.coverageState = existing.sourceEdgeIDs.length ? "covered" : "fallback";
      existing.shoppingContext = {
        ...existing.shoppingContext,
        canonicalKey,
        familyKey: canonicalKey,
        sourceEdgeIDs: existing.sourceEdgeIDs,
        alternativeNames: existing.alternativeNames,
        coverageState: existing.coverageState,
        sourceIngredientNames: uniqueStrings([
          ...(existing.shoppingContext?.sourceIngredientNames ?? []),
          ...(shoppingContext.sourceIngredientNames ?? []),
        ], 14),
        recipeTitles: uniqueStrings([
          ...(existing.shoppingContext?.recipeTitles ?? []),
          ...(shoppingContext.recipeTitles ?? []),
        ], 10),
        searchQueries: uniqueStrings([
          ...(existing.shoppingContext?.searchQueries ?? []),
          ...(shoppingContext.searchQueries ?? []),
        ], 8),
        verificationTerms: uniqueStrings([
          ...(existing.shoppingContext?.verificationTerms ?? []),
          ...(shoppingContext.verificationTerms ?? []),
        ], 8),
        fallbackSearchQuery: existing.shoppingContext?.fallbackSearchQuery ?? shoppingContext.fallbackSearchQuery ?? null,
        shoppingForm: existing.shoppingContext?.shoppingForm ?? shoppingContext.shoppingForm ?? null,
        expectedPurchaseUnit: existing.shoppingContext?.expectedPurchaseUnit ?? shoppingContext.expectedPurchaseUnit ?? null,
        quantityStrategy: existing.shoppingContext?.quantityStrategy ?? shoppingContext.quantityStrategy ?? null,
        minimumContainedQuantity: existing.shoppingContext?.minimumContainedQuantity != null && Number.isFinite(Number(existing.shoppingContext?.minimumContainedQuantity))
          ? Number(existing.shoppingContext.minimumContainedQuantity)
          : shoppingContext.minimumContainedQuantity != null && Number.isFinite(Number(shoppingContext.minimumContainedQuantity))
            ? Number(shoppingContext.minimumContainedQuantity)
            : null,
        desiredPackageCount: existing.shoppingContext?.desiredPackageCount != null && Number.isFinite(Number(existing.shoppingContext?.desiredPackageCount))
          ? Number(existing.shoppingContext.desiredPackageCount)
          : shoppingContext.desiredPackageCount != null && Number.isFinite(Number(shoppingContext.desiredPackageCount))
            ? Number(shoppingContext.desiredPackageCount)
            : null,
        quantityReason: existing.shoppingContext?.quantityReason ?? shoppingContext.quantityReason ?? null,
      };
      existing.confidence = Math.max(existing.confidence ?? 0, nextEntry.confidence ?? 0);
      collapsedByKey.set(key, existing);
    } else {
      collapsedByKey.set(key, nextEntry);
    }
  }

  const reconciled = await reconcileShoppingSpecEntries([...collapsedByKey.values()]);

  const finalItems = mergeCanonicalShoppingEntries(reconciled.items.map((entry) => {
    const packageRule = entry.shoppingContext?.packageRule ?? null;
    const quantityStrategy = String(entry.shoppingContext?.quantityStrategy ?? "").trim();
    const purchaseAmount = quantityStrategy === "single_package_minimum_count"
      ? 1
      : packageRule?.packageSize
      ? Math.max(1, Math.ceil(entry.amount / packageRule.packageSize))
      : Math.max(1, Math.ceil(entry.amount));
    const purchaseUnit = quantityStrategy === "single_package_minimum_count"
      ? "pack"
      : packageRule?.packageUnit
      ?? sanitizeShoppingUnit(entry.unit, entry.shoppingContext);

    return {
      ...entry,
      amount: purchaseAmount,
      unit: purchaseUnit,
    };
  }));
  const sourceCoverage = buildSourceEdgeCoverageSummary(expandedItems, finalItems);

  return {
    items: finalItems,
    reconciliationSummary: {
      ...reconciled.summary,
      expandedItemCount: expandedItems.length,
      resolvedItemCount: resolvedItems.length,
      collapsedItemCount: collapsedByKey.size,
      canonicalGroupCount: finalItems.length,
      sourceEdgeCount: sourceCoverage.sourceEdgeCount,
      coveredSourceEdgeCount: sourceCoverage.coveredSourceEdgeCount,
      uncoveredSourceEdgeIDs: sourceCoverage.uncoveredSourceEdgeIDs,
      alternativeCount: finalItems.reduce((sum, item) => sum + (Array.isArray(item.alternativeNames) ? item.alternativeNames.length : 0), 0),
      llmAdjudicationCount: reconciled.summary.lexicalAdjudicationGroupCount ?? 0,
    },
  };
}
