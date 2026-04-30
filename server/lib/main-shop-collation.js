const SAFE_DESCRIPTOR_WORDS = new Set([
  "additional",
  "boneless",
  "boxed",
  "chopped",
  "cooked",
  "crushed",
  "diced",
  "drained",
  "fresh",
  "frozen",
  "grated",
  "ground",
  "instant",
  "large",
  "medium",
  "minced",
  "optional",
  "organic",
  "peeled",
  "prepared",
  "raw",
  "ripe",
  "shredded",
  "sliced",
  "small",
  "skinless",
  "thawed",
  "whole",
]);

const PACKAGE_WORDS = new Set([
  "bag",
  "bags",
  "box",
  "boxes",
  "can",
  "cans",
  "carton",
  "cartons",
  "container",
  "containers",
  "cup",
  "cups",
  "jar",
  "jars",
  "pack",
  "packs",
  "packet",
  "packets",
  "package",
  "packages",
]);

const CONNECTOR_WORDS = new Set(["a", "an", "and", "for", "of", "or", "the", "to", "with"]);

function normalizeText(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s/()]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeKey(value) {
  return normalizeText(value)
    .replace(/[^\p{L}\p{N}\s]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeToken(token) {
  let normalized = String(token ?? "").trim().toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");
  if (!normalized) return "";
  if (/^chil(?:i|ies|is|y|ly|le|es|li|les)?$/.test(normalized)) return "chili";
  if (/^tomatoes?$/.test(normalized)) return "tomato";
  if (/^potatoes?$/.test(normalized)) return "potato";
  if (/^avocados?$/.test(normalized)) return "avocado";
  if (/^onions?$/.test(normalized)) return "onion";
  if (/^scallions?$/.test(normalized)) return "scallion";
  if (/^thighs?$/.test(normalized)) return "thigh";
  if (/^breasts?$/.test(normalized)) return "breast";
  if (normalized.endsWith("ies") && normalized.length > 4) return `${normalized.slice(0, -3)}y`;
  if (normalized.endsWith("oes") && normalized.length > 4) return normalized.slice(0, -2);
  if (normalized.endsWith("es") && normalized.length > 4 && !normalized.endsWith("ses")) return normalized.slice(0, -2);
  if (normalized.endsWith("s") && normalized.length > 3 && !normalized.endsWith("ss")) return normalized.slice(0, -1);
  return normalized;
}

function tokenize(value) {
  return normalizeKey(value).split(" ").map(normalizeToken).filter(Boolean);
}

function sourceEdgeID(source) {
  const recipeID = normalizeKey(source?.recipeID ?? source?.recipe_id ?? source?.recipeId ?? "");
  const ingredientName = normalizeKey(source?.ingredientName ?? source?.ingredient_name ?? "");
  const unit = normalizeKey(source?.unit ?? "");
  if (!recipeID || !ingredientName) return "";
  return [recipeID, ingredientName, unit].join("::");
}

function sourceEdgeIDsForItem(item) {
  return [...new Set((Array.isArray(item?.sourceIngredients) ? item.sourceIngredients : [])
    .map(sourceEdgeID)
    .filter(Boolean))];
}

function extractAlternativeParts(rawName) {
  const normalized = normalizeText(rawName);
  if (!normalized) return { primary: "", alternatives: [] };

  const parentheticalAlternatives = [];
  const withoutOrParentheticals = normalized.replace(/\((?:or\s+)?([^()]+)\)/giu, (_, candidate) => {
    const cleaned = normalizeText(candidate);
    if (cleaned) parentheticalAlternatives.push(cleaned);
    return " ";
  });

  const slashParts = withoutOrParentheticals
    .split(/\s+\/\s+|\/+/u)
    .map(normalizeText)
    .filter(Boolean);
  const slashPrimary = slashParts.length > 1 ? slashParts[0] : withoutOrParentheticals;
  const slashAlternatives = slashParts.length > 1 ? slashParts.slice(1) : [];

  const orParts = slashPrimary
    .split(/\s+(?:or|or use|or substitute|substitute)\s+/u)
    .map(normalizeText)
    .filter(Boolean);
  const primary = orParts[0] || slashPrimary;
  const alternatives = [...orParts.slice(1), ...slashAlternatives, ...parentheticalAlternatives]
    .map(normalizeText)
    .filter((value) => value && value !== primary);

  return {
    primary: normalizeText(primary),
    alternatives: [...new Set(alternatives)],
  };
}

function canonicalTokensForName(rawName) {
  const { primary, alternatives } = extractAlternativeParts(rawName);
  const primaryTokens = tokenize(primary || rawName);
  const filtered = primaryTokens.filter((token, index, tokens) => {
    if (CONNECTOR_WORDS.has(token)) return false;
    if (SAFE_DESCRIPTOR_WORDS.has(token)) return false;
    if (PACKAGE_WORDS.has(token) && tokens.length > 1) return false;
    return true;
  });

  return {
    tokens: filtered.length ? filtered : primaryTokens,
    primary,
    alternatives,
  };
}

function titleCase(value) {
  return String(value ?? "")
    .split(" ")
    .filter(Boolean)
    .map((token) => {
      const lowered = token.toLowerCase();
      return ["bbq", "caesar"].includes(lowered) ? lowered.toUpperCase() : `${lowered.slice(0, 1).toUpperCase()}${lowered.slice(1)}`;
    })
    .join(" ");
}

function canonicalizeIngredientName(rawName) {
  const { tokens, primary, alternatives } = canonicalTokensForName(rawName);
  const canonicalKey = tokens.join(" ").trim();
  const canonicalName = canonicalKey || normalizeKey(primary || rawName);
  return {
    canonicalKey,
    canonicalName,
    preferredDisplayName: titleCase(canonicalName),
    primaryName: primary,
    alternativeNames: alternatives.map(titleCase),
  };
}

function applySourceCollationToItem(item) {
  const rawName = item?.name ?? item?.canonicalName ?? "";
  const collation = canonicalizeIngredientName(rawName);
  const sourceEdgeIDs = sourceEdgeIDsForItem(item);
  return {
    ...item,
    name: collation.canonicalName || rawName,
    originalName: item?.originalName ?? rawName,
    shoppingCollation: {
      ...collation,
      sourceEdgeIDs,
      coverageState: sourceEdgeIDs.length ? "covered" : "fallback",
    },
  };
}

function mergeUnique(values, limit = 40) {
  return [...new Set((values ?? []).map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, limit);
}

function uniqueSources(sources = []) {
  const seen = new Set();
  const result = [];
  for (const source of Array.isArray(sources) ? sources : []) {
    const key = sourceEdgeID(source);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    result.push(source);
  }
  return result;
}

function entryCanonicalKey(entry) {
  const explicit = String(
    entry?.canonicalKey
      ?? entry?.shoppingContext?.canonicalKey
      ?? entry?.shoppingContext?.familyKey
      ?? ""
  ).trim();
  if (explicit) return explicit;
  return canonicalizeIngredientName(
    entry?.shoppingContext?.canonicalName
      ?? entry?.canonicalName
      ?? entry?.name
      ?? ""
  ).canonicalKey;
}

function mergeEntryGroup(items) {
  const sorted = [...items].sort((lhs, rhs) => {
    const lhsSources = Array.isArray(lhs?.sourceIngredients) ? lhs.sourceIngredients.length : 0;
    const rhsSources = Array.isArray(rhs?.sourceIngredients) ? rhs.sourceIngredients.length : 0;
    if (lhsSources !== rhsSources) return rhsSources - lhsSources;
    return String(rhs?.name ?? "").length - String(lhs?.name ?? "").length;
  });
  const representative = sorted[0];
  const canonicalKey = entryCanonicalKey(representative);
  const canonical = canonicalizeIngredientName(canonicalKey);
  const sourceIngredients = uniqueSources(sorted.flatMap((item) => item?.sourceIngredients ?? []));
  const sourceEdgeIDs = mergeUnique(sorted.flatMap((item) =>
    item?.sourceEdgeIDs
      ?? item?.shoppingContext?.sourceEdgeIDs
      ?? sourceEdgeIDsForItem(item)
  ), 80);
  const alternativeNames = mergeUnique(sorted.flatMap((item) =>
    item?.alternativeNames
      ?? item?.shoppingContext?.alternativeNames
      ?? item?.shoppingContext?.alternateQueries
      ?? []
  ), 24);

  return {
    ...representative,
    name: representative?.name || canonical.preferredDisplayName,
    canonicalName: canonical.canonicalName || representative?.canonicalName,
    canonicalKey,
    amount: sorted.reduce((sum, item) => sum + Math.max(0, Number(item?.amount ?? 0)), 0),
    estimatedPrice: sorted.reduce((sum, item) => sum + Number(item?.estimatedPrice ?? 0), 0),
    sourceIngredients,
    sourceEdgeIDs,
    alternativeNames,
    coverageState: sourceEdgeIDs.length ? "covered" : "fallback",
    shoppingContext: {
      ...(representative?.shoppingContext ?? {}),
      canonicalName: canonical.canonicalName || representative?.shoppingContext?.canonicalName || representative?.canonicalName,
      canonicalKey,
      familyKey: canonicalKey,
      sourceEdgeIDs,
      alternativeNames,
      coverageState: sourceEdgeIDs.length ? "covered" : "fallback",
      sourceIngredientNames: mergeUnique(sorted.flatMap((item) =>
        item?.shoppingContext?.sourceIngredientNames
          ?? (item?.sourceIngredients ?? []).map((source) => source?.ingredientName)
          ?? []
      ), 40),
    },
  };
}

function mergeCanonicalShoppingEntries(entries = []) {
  const groups = new Map();
  const order = [];
  for (const entry of Array.isArray(entries) ? entries : []) {
    const key = entryCanonicalKey(entry);
    if (!key) continue;
    if (!groups.has(key)) {
      groups.set(key, []);
      order.push(key);
    }
    groups.get(key).push(entry);
  }
  return order.map((key) => {
    const items = groups.get(key) ?? [];
    return items.length === 1 ? mergeEntryGroup(items) : mergeEntryGroup(items);
  });
}

function buildSourceEdgeCoverageSummary(originalItems = [], specItems = []) {
  const expectedSourceEdgeIDs = mergeUnique(originalItems.flatMap(sourceEdgeIDsForItem), 500);
  const coveredSourceEdgeIDs = mergeUnique(specItems.flatMap((item) =>
    item?.sourceEdgeIDs
      ?? item?.shoppingContext?.sourceEdgeIDs
      ?? sourceEdgeIDsForItem(item)
  ), 500);
  const covered = new Set(coveredSourceEdgeIDs);
  const uncoveredSourceEdgeIDs = expectedSourceEdgeIDs.filter((id) => !covered.has(id));
  return {
    sourceEdgeCount: expectedSourceEdgeIDs.length,
    coveredSourceEdgeCount: coveredSourceEdgeIDs.length,
    uncoveredSourceEdgeIDs,
  };
}

export {
  applySourceCollationToItem,
  buildSourceEdgeCoverageSummary,
  canonicalizeIngredientName,
  entryCanonicalKey,
  mergeCanonicalShoppingEntries,
  sourceEdgeID,
  sourceEdgeIDsForItem,
};
