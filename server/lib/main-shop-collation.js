const CONNECTOR_WORDS = new Set(["a", "an", "and", "for", "of", "or", "the", "to", "with"]);

const PREPARATION_WORDS = new Set([
  "beaten", "boneless", "chopped", "coarsely", "cracked", "crushed", "diced",
  "divided", "finely", "freshly", "grated", "large", "mashed", "medium",
  "melted", "minced", "optional", "packed", "peeled", "ripe", "roughly",
  "shredded", "skinless", "sliced", "small", "softened", "thinly", "thickly",
]);

// Shopping identities only. These families never rewrite recipe ingredients.
// A family is included only when every alias can be bought as the same grocery.
const INGREDIENT_ALIAS_FAMILIES = [
  ["Eggs", ["egg", "eggs", "large egg", "large eggs", "medium egg", "medium eggs", "small egg", "small eggs", "whole egg", "whole eggs", "beaten egg", "beaten eggs", "egg yolk", "egg yolks", "large egg yolk", "large egg yolks", "egg white", "egg whites"]],
  ["Heavy Cream", ["cream", "fresh cream", "heavy cream", "heavy whipping cream", "whipping cream", "double cream"]],
  ["Black Pepper", ["pepper", "black pepper", "ground black pepper", "black pepper ground", "black pepper powder", "fresh ground black pepper", "freshly ground black pepper", "cracked black pepper", "freshly cracked black pepper", "coarse ground black pepper", "fresh black pepper"]],
  ["Smoked Paprika", ["smoked paprika", "smoked paprika powder"]],
  ["Paprika", ["paprika", "paprika powder"]],
  ["Garlic Powder", ["garlic powder", "garlic granules", "granulated garlic"]],
  ["Onion Powder", ["onion powder", "onion granules", "granulated onion"]],
  ["Cinnamon", ["cinnamon", "ground cinnamon", "cinnamon powder"]],
  ["Ground Cumin", ["cumin", "ground cumin", "cumin powder"]],
  ["Ground Coriander", ["ground coriander", "coriander powder"]],
  ["Nutmeg", ["nutmeg", "ground nutmeg", "nutmeg powder", "grated nutmeg", "freshly grated nutmeg", "grated whole nutmeg"]],
  ["Turmeric", ["turmeric", "ground turmeric", "turmeric powder"]],
  ["Cayenne Pepper", ["cayenne", "cayenne pepper", "cayenne powder"]],
  ["Chili Flakes", ["chili flakes", "chilli flakes", "red chili flakes", "red chilli flakes", "red pepper flakes", "crushed red pepper", "crushed red pepper flakes", "crushed chili flakes", "crushed chilli flakes", "dried chili flakes", "dried chilli flakes"]],
  ["Green Onions", ["green onion", "green onions", "scallion", "scallions", "spring onion", "spring onions"]],
  ["Cilantro", ["cilantro", "fresh cilantro", "cilantro leaves", "fresh cilantro leaves", "chopped cilantro", "coriander leaves", "fresh coriander", "fresh coriander leaves", "chopped coriander"]],
  ["Parsley", ["parsley", "fresh parsley", "parsley fresh", "parsley chopped", "chopped parsley", "italian parsley", "flat leaf parsley", "flat leaf italian parsley"]],
  ["Fresh Basil", ["basil", "fresh basil", "basil leaves", "fresh basil leaves"]],
  ["Fresh Dill", ["dill", "fresh dill", "dill leaves", "fresh dill leaves"]],
  ["Fresh Thyme", ["thyme", "fresh thyme", "fresh thyme leaves", "thyme leaves", "fresh thyme sprigs", "thyme sprigs"]],
  ["Fresh Rosemary", ["rosemary", "fresh rosemary", "rosemary sprig", "rosemary sprigs"]],
  ["Fresh Mint", ["mint", "fresh mint", "mint leaves", "fresh mint leaves"]],
  ["Garlic", ["garlic", "fresh garlic", "garlic clove", "garlic cloves", "minced garlic", "garlic minced", "chopped garlic", "crushed garlic", "grated garlic", "freshly grated garlic", "minced garlic clove", "minced garlic cloves", "garlic clove minced", "garlic cloves minced", "garlic cloves finely grated"]],
  ["Red Onion", ["red onion", "red onions", "small red onion", "red onion thinly sliced", "small red onion finely diced"]],
  ["Yellow Onion", ["yellow onion", "yellow onions", "yellow onion diced"]],
  ["White Onion", ["white onion", "white onions"]],
  ["Onion", ["onion", "onions", "diced onion", "onion diced", "medium onion", "medium onion diced", "chopped onion"]],
  ["Shallots", ["shallot", "shallots"]],
  ["Cherry Tomatoes", ["cherry tomato", "cherry tomatoes"]],
  ["Tomatoes", ["tomato", "tomatoes"]],
  ["Jalapenos", ["jalapeno", "jalapenos", "jalapeño", "jalapeños", "jalapeno pepper", "jalapeño pepper"]],
  ["Celery", ["celery", "celery stalk", "celery stalks", "celery rib", "celery ribs", "diced celery"]],
  ["Broccoli", ["broccoli", "broccoli florets", "broccoli crown"]],
  ["Carrots", ["carrot", "carrots"]],
  ["Avocados", ["avocado", "avocados", "ripe avocado", "ripe avocados"]],
  ["Bananas", ["banana", "bananas", "ripe banana", "ripe bananas", "medium banana", "medium bananas", "mashed banana", "mashed bananas", "overripe banana", "overripe bananas"]],
  ["Lemons", ["lemon", "lemons"]],
  ["Limes", ["lime", "limes"]],
  ["Apples", ["apple", "apples"]],
  ["Peaches", ["peach", "peaches"]],
  ["Mangoes", ["mango", "mangos", "mangoes"]],
  ["Sweet Potatoes", ["sweet potato", "sweet potatoes"]],
  ["Chicken Breast", ["chicken breast", "chicken breasts", "boneless chicken breast", "boneless chicken breasts", "boneless skinless chicken breast", "boneless skinless chicken breasts", "skinless chicken breast", "skinless chicken breasts", "diced chicken breast", "chicken breast diced", "chicken breast fillet", "chicken breast fillets"]],
  ["Chicken Thighs", ["chicken thigh", "chicken thighs", "boneless chicken thigh", "boneless chicken thighs", "boneless skinless chicken thigh", "boneless skinless chicken thighs", "skinless chicken thigh", "skinless chicken thighs", "chicken thigh fillet", "chicken thigh fillets"]],
  ["Ground Chicken", ["ground chicken", "chicken mince", "minced chicken"]],
  ["Ground Beef", ["ground beef", "lean ground beef", "beef mince", "lean beef mince", "minced beef"]],
  ["Salmon Fillets", ["salmon", "salmon fillet", "salmon fillets", "salmon filet", "salmon filets"]],
  ["Shrimp", ["shrimp", "raw shrimp", "prawn", "prawns", "raw prawns"]],
  ["Chickpeas", ["chickpea", "chickpeas", "garbanzo bean", "garbanzo beans"]],
  ["Parmesan", ["parmesan", "parmesan cheese", "grated parmesan", "grated parmesan cheese", "shredded parmesan", "shredded parmesan cheese", "shaved parmesan", "parmesan grated", "parmesan cheese grated", "fresh parmesan cheese", "fresh grated parmesan", "fresh grated parmesan cheese", "freshly grated parmesan", "finely grated parmesan", "parmigiano reggiano", "parmigiano reggiano cheese"]],
  ["Mozzarella", ["mozzarella", "mozzarella cheese", "shredded mozzarella", "shredded mozzarella cheese", "grated mozzarella", "grated mozzarella cheese"]],
  ["Cheddar Cheese", ["cheddar", "cheddar cheese", "shredded cheddar", "shredded cheddar cheese", "grated cheddar", "grated cheddar cheese"]],
  ["Feta", ["feta", "feta cheese"]],
  ["Ricotta", ["ricotta", "ricotta cheese"]],
  ["Mascarpone", ["mascarpone", "mascarpone cheese"]],
  ["Halloumi", ["halloumi", "halloumi cheese"]],
  ["Burrata", ["burrata", "burrata cheese"]],
  ["Brie", ["brie", "brie cheese"]],
  ["Pecorino Romano", ["pecorino romano", "pecorino romano cheese"]],
  ["Greek Yogurt", ["greek yogurt", "plain greek yogurt", "plain full fat greek yogurt"]],
  ["Cream Cheese", ["cream cheese", "softened cream cheese", "cream cheese softened"]],
  ["Unsalted Butter", ["unsalted butter", "melted unsalted butter", "unsalted butter melted", "unsalted butter melted cooled"]],
  ["Salted Butter", ["salted butter", "melted salted butter", "salted butter melted"]],
  ["Butter", ["butter", "melted butter", "butter melted"]],
  ["Granulated Sugar", ["sugar", "granulated sugar", "white sugar"]],
  ["Powdered Sugar", ["powdered sugar", "icing sugar", "confectioners sugar", "confectioner sugar"]],
  ["All-Purpose Flour", ["flour", "all purpose flour", "all-purpose flour", "plain flour"]],
  ["Cornstarch", ["cornstarch", "corn starch", "cornflour", "corn flour"]],
  ["Panko Breadcrumbs", ["panko", "panko breadcrumbs", "panko bread crumbs"]],
  ["Breadcrumbs", ["breadcrumbs", "bread crumbs"]],
  ["Vanilla Extract", ["vanilla extract", "pure vanilla extract"]],
  ["Lemon Juice", ["lemon juice", "fresh lemon juice"]],
  ["Lime Juice", ["lime juice", "fresh lime juice"]],
  ["Chicken Broth", ["chicken broth", "chicken stock", "low sodium chicken broth", "low sodium chicken stock"]],
  ["Vegetable Broth", ["vegetable broth", "vegetable stock"]],
  ["Beef Broth", ["beef broth", "beef stock"]],
  ["Mayonnaise", ["mayonnaise", "mayo"]],
  ["BBQ Sauce", ["bbq sauce", "barbecue sauce"]],
  ["Rice Vinegar", ["rice vinegar", "rice wine vinegar"]],
  ["White Vinegar", ["white vinegar", "distilled white vinegar"]],
  ["Olive Oil", ["olive oil", "extra virgin olive oil", "extra-virgin olive oil"]],
  ["Sesame Seeds", ["sesame seed", "sesame seeds", "toasted sesame seed", "toasted sesame seeds", "roasted sesame seeds"]],
  ["Bay Leaves", ["bay leaf", "bay leaves"]],
];

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

const SHOPPABLE_WATER_WORDS = new Set([
  "aloe", "blossom", "coconut", "mineral", "orange", "rose", "soda", "sparkling",
  "tonic", "vitamin",
]);

function isNonShoppingWater(value) {
  const tokens = normalizeKey(value).split(" ").filter(Boolean);
  return tokens.includes("water") && tokens.every((token) => !SHOPPABLE_WATER_WORDS.has(token));
}

const INGREDIENT_ALIAS_LOOKUP = (() => {
  const values = new Map();
  for (const [displayName, aliases] of INGREDIENT_ALIAS_FAMILIES) {
    const canonicalKey = normalizeKey(displayName);
    const match = { canonicalKey, displayName };
    values.set(canonicalKey, match);
    for (const alias of aliases) {
      values.set(normalizeKey(alias), match);
    }
  }
  return values;
})();

function ingredientAliasMatch(value) {
  const normalized = normalizeKey(value);
  if (!normalized) return null;
  const exact = INGREDIENT_ALIAS_LOOKUP.get(normalized);
  if (exact) return exact;

  const simplified = normalized
    .split(" ")
    .filter((token) => token && !PREPARATION_WORDS.has(token))
    .join(" ")
    .trim();
  const simplifiedMatch = INGREDIENT_ALIAS_LOOKUP.get(simplified) ?? null;
  if (["tomatoes", "cherry tomatoes"].includes(simplifiedMatch?.canonicalKey)) {
    return null;
  }
  return simplifiedMatch;
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
  const rawTokens = tokenize(rawName);
  const filtered = rawTokens.filter((token) => {
    if (CONNECTOR_WORDS.has(token)) return false;
    return true;
  });

  return {
    tokens: filtered.length ? filtered : rawTokens,
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
  const alias = ingredientAliasMatch(primary || rawName);
  if (alias) {
    return {
      canonicalKey: alias.canonicalKey,
      canonicalName: alias.canonicalKey,
      preferredDisplayName: alias.displayName,
      primaryName: primary,
      alternativeNames: alternatives.map(titleCase),
    };
  }

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
    name: rawName,
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
  if (explicit) return canonicalizeIngredientName(explicit).canonicalKey;
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
  isNonShoppingWater,
  mergeCanonicalShoppingEntries,
  sourceEdgeID,
  sourceEdgeIDsForItem,
};
