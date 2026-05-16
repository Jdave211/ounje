function sanitizeRecipeText(value) {
  return String(value ?? "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/\r/g, "\n")
    .replace(/\u00a0/g, " ")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function normalizeText(value) {
  return sanitizeRecipeText(value).toLowerCase();
}

function normalizeRecipeLine(value) {
  return String(value ?? "")
    .replace(/^[-*•\s]+/, "")
    .replace(/\s+/g, " ")
    .trim();
}

function cleanSourceURL(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return null;
  try {
    return new URL(raw).toString();
  } catch (_error) {
    return null;
  }
}

function isJulienneURL(value) {
  const cleaned = cleanSourceURL(value);
  if (!cleaned) return false;
  try {
    const host = new URL(cleaned).hostname.toLowerCase();
    return host === "withjulienne.com" || host.endsWith(".withjulienne.com");
  } catch (_error) {
    return false;
  }
}

function isSocialPlatformURL(value) {
  const cleaned = cleanSourceURL(value);
  if (!cleaned) return false;
  try {
    const host = new URL(cleaned).hostname.toLowerCase();
    return host.includes("tiktok.com")
      || host.includes("instagram.com")
      || host === "youtu.be"
      || host.includes("youtube.com")
      || host.includes("youtube-nocookie.com");
  } catch (_error) {
    return false;
  }
}

function isWatchableSocialVideoURL(value) {
  const cleaned = cleanSourceURL(value);
  if (!cleaned) return false;
  const url = new URL(cleaned);
  const host = url.hostname.toLowerCase();
  const path = url.pathname.toLowerCase();
  if (host.includes("tiktok.com")) {
    return host === "vt.tiktok.com" || host === "vm.tiktok.com" || path.includes("/video/") || path.includes("/t/");
  }
  if (host.includes("instagram.com")) {
    return path.includes("/reel/") || path.includes("/p/") || path.includes("/tv/");
  }
  if (host === "youtu.be" || host.includes("youtube.com") || host.includes("youtube-nocookie.com")) {
    return host === "youtu.be" || path.includes("/shorts/") || path.includes("/watch");
  }
  return false;
}

function displayableOriginalSourceURL(value) {
  const cleaned = cleanSourceURL(value);
  if (!cleaned || isJulienneURL(cleaned)) return null;
  if (isSocialPlatformURL(cleaned) && !isWatchableSocialVideoURL(cleaned)) return null;
  return cleaned;
}

function collectSourceProvenanceURLStrings(provenance) {
  if (!provenance || typeof provenance !== "object") return [];
  const originalSocialSource = provenance.original_social_source && typeof provenance.original_social_source === "object"
    ? provenance.original_social_source
    : {};
  const evidenceBundle = provenance.evidence_bundle && typeof provenance.evidence_bundle === "object"
    ? provenance.evidence_bundle
    : {};
  const evidenceOriginalSocialSource = evidenceBundle.original_social_source && typeof evidenceBundle.original_social_source === "object"
    ? evidenceBundle.original_social_source
    : {};

  return [
    originalSocialSource.url,
    originalSocialSource.attached_video_url,
    originalSocialSource.canonical_url,
    originalSocialSource.source_url,
    evidenceOriginalSocialSource.url,
    evidenceOriginalSocialSource.attached_video_url,
    evidenceOriginalSocialSource.canonical_url,
    evidenceOriginalSocialSource.source_url,
    provenance.url,
    provenance.attached_video_url,
    provenance.canonical_url,
    provenance.source_url,
    evidenceBundle.url,
    evidenceBundle.attached_video_url,
    evidenceBundle.canonical_url,
    evidenceBundle.source_url,
    ...(Array.isArray(evidenceBundle.reference_urls) ? evidenceBundle.reference_urls : []),
  ];
}

function resolveRecipeSourceURLs(recipe) {
  const candidates = [
    ...collectSourceProvenanceURLStrings(recipe.source_provenance_json),
    recipe.original_recipe_url,
    recipe.recipe_url,
    recipe.attached_video_url,
  ];
  const displayable = [];
  const seen = new Set();
  for (const candidate of candidates) {
    const cleaned = displayableOriginalSourceURL(candidate);
    if (!cleaned || seen.has(cleaned)) continue;
    seen.add(cleaned);
    displayable.push(cleaned);
  }
  const firstDisplayable = displayable[0] ?? null;
  const firstVideo = displayable.find(isWatchableSocialVideoURL) ?? null;

  return {
    recipe_url: firstDisplayable ?? cleanSourceURL(recipe.recipe_url),
    original_recipe_url: firstDisplayable ?? cleanSourceURL(recipe.original_recipe_url),
    attached_video_url: firstVideo ?? cleanSourceURL(recipe.attached_video_url),
  };
}

const INGREDIENT_UNIT_WORDS = new Set([
  "cup",
  "cups",
  "tbsp",
  "tablespoon",
  "tablespoons",
  "tsp",
  "teaspoon",
  "teaspoons",
  "oz",
  "ounce",
  "ounces",
  "lb",
  "lbs",
  "pound",
  "pounds",
  "g",
  "kg",
  "ml",
  "l",
  "pinch",
  "pinches",
  "dash",
  "dashes",
  "clove",
  "cloves",
  "can",
  "cans",
  "packet",
  "packets",
  "stick",
  "sticks",
  "slice",
  "slices",
  "bunch",
  "bunches",
  "head",
  "heads",
  "medium",
  "large",
  "small",
  "extra-large",
  "jumbo",
  "package",
  "packages",
  "pkg",
  "pkgs",
]);

const FRACTION_CHARACTER_PATTERN = "¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞";

function cleanIngredientDisplayName(value) {
  let normalized = normalizeRecipeLine(value);
  if (!normalized) return "";

  const exampleMatch = normalized.match(/\s*\((?:e\.?g\.?|example|examples).*$/i);
  if (exampleMatch) {
    normalized = normalized.slice(0, exampleMatch.index).trim();
  } else {
    const openIndex = normalized.indexOf("(");
    const closeIndex = normalized.indexOf(")");
    if (openIndex >= 0 && (closeIndex < 0 || closeIndex < openIndex)) {
      normalized = normalized.slice(0, openIndex).trim();
    }
  }

  return normalized.replace(/\s{2,}/g, " ").trim();
}

function splitIngredientQuantityPrefix(displayName, quantityText = null) {
  const name = cleanIngredientDisplayName(displayName);
  const quantity = normalizeRecipeLine(quantityText ?? "") || null;
  if (!name) {
    return { displayName: name, quantityText: quantity };
  }

  if (quantity && isLikelyIngredientAbbreviation(name) && looksLikePromotableIngredientName(quantity)) {
    return {
      displayName: stripLeadingIngredientQuantityTerms(quantity),
      quantityText: null,
    };
  }

  let workingName = name;
  let workingQuantity = quantity;

  if (workingQuantity) {
    const loweredName = workingName.toLowerCase();
    const loweredQuantity = workingQuantity.toLowerCase();
    if (loweredName.startsWith(loweredQuantity)) {
      workingName = workingName.slice(workingQuantity.length).trim();
      workingName = workingName.replace(/^[,;:\-\u2013\u2014]+\s*/, "");

      const tokens = workingName.split(/\s+/).filter(Boolean);
      while (tokens.length && INGREDIENT_UNIT_WORDS.has(tokens[0].toLowerCase())) {
        if (!workingQuantity) {
          workingQuantity = tokens.shift();
        } else {
          workingQuantity = `${workingQuantity} ${tokens.shift()}`;
        }
      }
      workingName = tokens.join(" ").trim();
    }
  }

  const leadingMatch = workingName.match(new RegExp(`^((?:\\d+\\s+)?\\d+\\/\\d+|\\d+(?:\\.\\d+)?|[${FRACTION_CHARACTER_PATTERN}])(?:\\s+([a-zA-Z-]+))?\\s+(.+)$`));
  if (leadingMatch) {
    const parsedQuantity = leadingMatch[1].trim();
    const parsedUnit = normalizeRecipeLine(leadingMatch[2] ?? "") || null;
    const parsedName = cleanIngredientDisplayName(leadingMatch[3]);
    return {
      displayName: parsedName || workingName,
      quantityText: [parsedQuantity, parsedUnit].filter(Boolean).join(" ").trim() || workingQuantity,
    };
  }

  return {
    displayName: workingName,
    quantityText: workingQuantity,
  };
}

function isLikelyIngredientAbbreviation(value) {
  const trimmed = normalizeRecipeLine(value);
  if (!trimmed || trimmed.includes(" ") || trimmed.length > 4) return false;
  return trimmed === trimmed.toUpperCase() || /\d/.test(trimmed) || trimmed.length <= 2;
}

function stripLeadingIngredientQuantityTerms(value) {
  const tokens = normalizeRecipeLine(value).split(/\s+/).filter(Boolean);
  while (tokens.length) {
    const lowered = tokens[0].replace(/[^\p{L}\p{N}/.-]+/gu, "").toLowerCase();
    const numericLike = /\d/.test(lowered) || lowered.includes("/") || [...lowered].some((char) => FRACTIONS[char] != null);
    if (numericLike || INGREDIENT_UNIT_WORDS.has(lowered)) {
      tokens.shift();
      continue;
    }
    break;
  }
  return tokens.join(" ").replace(/^of\s+/i, "").trim();
}

function looksLikePromotableIngredientName(value) {
  const stripped = stripLeadingIngredientQuantityTerms(value);
  if (!stripped || !/[a-z]/i.test(stripped)) return false;
  const lowered = stripped.toLowerCase();
  return !["to taste", "as needed", "for serving", "optional", "divided"].includes(lowered);
}

function normalizeStepText(value) {
  return String(value ?? "")
    .replace(/^[-*•\s]+/, "")
    .replace(/\s+/g, " ")
    .trim();
}

function parseFirstInteger(value) {
  const match = String(value ?? "").match(/\d{1,3}/);
  return match ? Number.parseInt(match[0], 10) : null;
}

function dedupeStrings(values) {
  const seen = new Set();
  return values.filter((value) => {
    const key = value.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

const FRACTIONS = {
  "¼": 0.25,
  "½": 0.5,
  "¾": 0.75,
  "⅐": 1 / 7,
  "⅑": 1 / 9,
  "⅒": 0.1,
  "⅓": 1 / 3,
  "⅔": 2 / 3,
  "⅕": 0.2,
  "⅖": 0.4,
  "⅗": 0.6,
  "⅘": 0.8,
  "⅙": 1 / 6,
  "⅚": 5 / 6,
  "⅛": 0.125,
  "⅜": 0.375,
  "⅝": 0.625,
  "⅞": 0.875,
};

const UNITS = new Set([
  "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons",
  "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds", "g", "gram", "grams",
  "kg", "ml", "l", "liter", "liters", "pinch", "pinches", "clove", "cloves", "can",
  "cans", "package", "packages", "pkg", "pkgs", "slice", "slices", "piece", "pieces",
  "sprig", "sprigs", "bunch", "bunches", "stalk", "stalks", "head", "heads", "fillet",
  "fillets", "breast", "breasts", "thigh", "thighs", "medium", "large", "small",
  "extra-large", "jumbo"
]);

function splitCompactQuantityUnit(value) {
  const normalized = normalizeRecipeLine(value);
  if (!normalized) return null;
  const unitAlternation = [...UNITS]
    .sort((left, right) => right.length - left.length)
    .map((unit) => unit.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join("|");
  const pattern = new RegExp(`^((?:\\d+\\s+)?\\d+\\/\\d+|\\d+-\\d+\\/\\d+|\\d+(?:\\.\\d+)?[${FRACTION_CHARACTER_PATTERN}]?|[${FRACTION_CHARACTER_PATTERN}])\\s*(${unitAlternation})$`, "i");
  const match = normalized.match(pattern);
  if (!match) return null;
  const quantity = parseQuantityToken(match[1]);
  if (quantity == null) return null;
  return {
    quantity,
    unit: match[2],
  };
}

function parseQuantityToken(token) {
  if (!token) return null;
  const normalized = token.trim();
  if (!normalized) return null;

  if (normalized.toLowerCase() === "a" || normalized.toLowerCase() === "an") return 1;
  if (FRACTIONS[normalized] != null) return FRACTIONS[normalized];
  if (/^\d+(?:\.\d+)?$/.test(normalized)) return Number.parseFloat(normalized);
  if (/^\d+\/\d+$/.test(normalized)) {
    const [a, b] = normalized.split("/").map(Number);
    return b ? a / b : null;
  }
  if (/^\d+-\d+\/\d+$/.test(normalized)) {
    const [whole, frac] = normalized.split("-");
    return Number(whole) + (parseQuantityToken(frac) ?? 0);
  }
  if (/^\d+\s+\d+\/\d+$/.test(normalized)) {
    const [whole, frac] = normalized.split(/\s+/);
    return Number(whole) + (parseQuantityToken(frac) ?? 0);
  }

  const unicodeExpanded = [...normalized].map((char) => (FRACTIONS[char] != null ? ` ${FRACTIONS[char]} ` : char)).join("").trim();
  if (unicodeExpanded !== normalized) {
    const compact = unicodeExpanded.replace(/\s+/g, " ");
    if (/^\d+\s+0?\.\d+$/.test(compact)) {
      const [whole, frac] = compact.split(/\s+/);
      return Number(whole) + Number(frac);
    }
    if (/^0?\.\d+$/.test(compact)) {
      return Number(compact);
    }
  }

  return null;
}

function parseQuantityAndUnitText(value) {
  const normalized = normalizeRecipeLine(value);
  if (!normalized) return { quantity: null, unit: null };

  const compact = splitCompactQuantityUnit(normalized);
  if (compact) return compact;

  const tokens = normalized.split(/\s+/).filter(Boolean);
  if (!tokens.length) return { quantity: null, unit: null };

  let quantity = null;
  let quantityTokens = 0;
  const firstTwo = tokens.length >= 2 ? parseQuantityToken(`${tokens[0]} ${tokens[1]}`) : null;
  const first = parseQuantityToken(tokens[0]);

  if (firstTwo != null) {
    quantity = firstTwo;
    quantityTokens = 2;
  } else if (first != null) {
    quantity = first;
    quantityTokens = 1;
  }

  if (quantityTokens === 0) {
    return { quantity: null, unit: null };
  }

  const unitCandidate = tokens[quantityTokens]?.replace(/[^\p{L}-]+/gu, "").toLowerCase() ?? "";
  const unit = unitCandidate && UNITS.has(unitCandidate) ? tokens[quantityTokens] : null;
  return { quantity, unit };
}

function parseIngredientLine(line) {
  const normalized = normalizeRecipeLine(line);
  if (!normalized) return null;

  let remainder = normalized;
  let quantity = null;
  let unit = null;
  let note = null;

  const parenMatches = [...normalized.matchAll(/\(([^)]+)\)/g)].map((match) => match[1].trim()).filter(Boolean);
  if (parenMatches.length) {
    note = parenMatches.join(", ");
    remainder = normalized.replace(/\(([^)]+)\)/g, "").replace(/\s+/g, " ").trim();
  }

  const tokens = remainder.split(/\s+/);
  if (tokens.length) {
    const first = parseQuantityToken(tokens[0]);
    const firstTwo = tokens.length >= 2 ? parseQuantityToken(`${tokens[0]} ${tokens[1]}`) : null;

    let quantityTokens = 0;
    if (firstTwo != null) {
      quantity = firstTwo;
      quantityTokens = 2;
    } else if (first != null) {
      quantity = first;
      quantityTokens = 1;
    }

    if (quantityTokens > 0) {
      tokens.splice(0, quantityTokens);
      if (tokens.length && UNITS.has(tokens[0].toLowerCase())) {
        unit = tokens.shift();
      }
    }
  }

  remainder = tokens.join(" ").replace(/^of\s+/i, "").trim();
  if (!remainder) remainder = normalized;

  const commaIndex = remainder.indexOf(",");
  if (commaIndex > 0) {
    const lead = remainder.slice(0, commaIndex).trim();
    const tail = remainder.slice(commaIndex + 1).trim();
    if (tail) {
      note = note ? `${note}, ${tail}` : tail;
    }
    remainder = lead;
  }

  return {
    name: remainder,
    quantity,
    unit,
    note,
    image_hint: remainder.toLowerCase(),
  };
}

function normalizeIngredientObject(value) {
  if (!value || typeof value !== "object") return null;
  const rawName = normalizeRecipeLine(value.display_name ?? value.name ?? value.ingredient ?? value.label ?? "");
  const rawQuantityText = value.quantity_text ?? value.amount_text ?? value.quantity ?? value.amount ?? value.qty ?? null;
  const split = splitIngredientQuantityPrefix(rawName, rawQuantityText);
  const name = split.displayName;
  if (!name) return null;

  const quantityRaw = value.quantity ?? value.amount ?? value.qty ?? value.quantity_text ?? value.amount_text ?? null;
  const quantity = typeof quantityRaw === "number" ? quantityRaw : parseQuantityToken(String(split.quantityText ?? quantityRaw ?? "").trim());
  const unit = normalizeRecipeLine(value.unit ?? value.measure ?? "") || null;
  const quantityText = split.quantityText || normalizeRecipeLine(value.quantity_text ?? value.amount_text ?? "") || null;
  const note = normalizeRecipeLine(value.note ?? value.notes ?? "") || null;
  const imageHint = normalizeRecipeLine(value.image_hint ?? value.imageHint ?? name).toLowerCase() || name.toLowerCase();

  return {
    id: null,
    ingredient_id: null,
    display_name: name,
    quantity_text: quantityText || [quantity != null ? String(quantity) : null, unit].filter(Boolean).join(" ").trim() || null,
    image_url: null,
    sort_order: null,
    name,
    quantity: quantity != null && Number.isFinite(quantity) ? quantity : null,
    unit,
    note,
    image_hint: imageHint,
  };
}

function normalizeRecipeIngredientRow(value) {
  if (!value || typeof value !== "object") return null;

  const rawDisplayName = normalizeRecipeLine(value.display_name ?? value.name ?? value.ingredient_name ?? "");
  const split = splitIngredientQuantityPrefix(rawDisplayName, value.quantity_text ?? value.amount_text ?? "");
  const displayName = split.displayName;
  if (!displayName) return null;
  const normalizedQuantityText = split.quantityText || normalizeRecipeLine(value.quantity_text ?? value.amount_text ?? "") || null;
  const parsedQuantity = parseQuantityAndUnitText(normalizedQuantityText);

  return {
    id: value.id ?? null,
    ingredient_id: value.ingredient_id ?? null,
    display_name: displayName,
    quantity_text: normalizedQuantityText,
    image_url: value.image_url ?? null,
    sort_order: Number.isFinite(value.sort_order) ? Number(value.sort_order) : null,
    name: displayName,
    quantity: parsedQuantity.quantity,
    unit: parsedQuantity.unit,
    note: null,
    image_hint: displayName.toLowerCase(),
  };
}

function normalizedIngredientKey(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function quantityTextForIngredient(ingredient) {
  return normalizeRecipeLine(ingredient?.quantity_text ?? ingredient?.amount_text ?? "") || null;
}

function enrichIngredientQuantities(ingredients, stepIngredients) {
  const candidates = [...(ingredients ?? []), ...(stepIngredients ?? [])];
  const quantityByID = new Map();
  const quantityByName = new Map();

  for (const ingredient of candidates) {
    const quantityText = quantityTextForIngredient(ingredient);
    if (!quantityText) continue;

    const ingredientID = normalizeRecipeLine(ingredient.ingredient_id ?? ingredient.ingredientID ?? "");
    if (ingredientID && !quantityByID.has(ingredientID.toLowerCase())) {
      quantityByID.set(ingredientID.toLowerCase(), quantityText);
    }

    const displayName = normalizeRecipeLine(ingredient.display_name ?? ingredient.displayName ?? ingredient.name ?? "");
    const nameKey = normalizedIngredientKey(displayName);
    if (nameKey && !quantityByName.has(nameKey)) {
      quantityByName.set(nameKey, quantityText);
    }
  }

  return (ingredients ?? []).map((ingredient) => {
    const existingQuantity = quantityTextForIngredient(ingredient);
    if (existingQuantity) {
      return ingredient;
    }

    const ingredientID = normalizeRecipeLine(ingredient.ingredient_id ?? ingredient.ingredientID ?? "").toLowerCase();
    if (ingredientID && quantityByID.has(ingredientID)) {
      return { ...ingredient, quantity_text: quantityByID.get(ingredientID) };
    }

    const displayName = normalizeRecipeLine(ingredient.display_name ?? ingredient.displayName ?? ingredient.name ?? "");
    const nameKey = normalizedIngredientKey(displayName);
    if (nameKey && quantityByName.has(nameKey)) {
      return { ...ingredient, quantity_text: quantityByName.get(nameKey) };
    }

    return ingredient;
  });
}

const GENERIC_INGREDIENT_BUCKETS = new Set([
  "spice",
  "spices",
  "seasoning",
  "seasonings",
  "herb",
  "herbs",
  "blend",
  "mix",
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

const CONCRETE_INGREDIENT_HINTS = [
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
];

function normalizeGenericIngredientBucket(value) {
  const normalized = normalizeRecipeLine(value ?? "").toLowerCase();
  if (!normalized) return "";
  if (["spice", "spices", "seasoning", "seasonings"].includes(normalized)) return "seasoning blend";
  if (["herb", "herbs"].includes(normalized)) return "herb blend";
  if (["sauce", "sauces", "dressing", "dressings", "marinade", "marinades", "glaze", "glazes"].includes(normalized)) return "sauce mix";
  if (["topping", "toppings", "garnish", "garnishes"].includes(normalized)) return "topping mix";
  return normalized;
}

function isConcreteIngredientName(value) {
  const normalized = normalizeRecipeLine(value ?? "");
  if (!normalized) return false;
  if (GENERIC_INGREDIENT_BUCKETS.has(normalized.toLowerCase())) return false;
  return CONCRETE_INGREDIENT_HINTS.some((pattern) => pattern.test(normalized));
}

function shouldDropGenericIngredientRow(ingredient, ingredients = [], steps = []) {
  const displayName = normalizeRecipeLine(ingredient?.display_name ?? ingredient?.displayName ?? ingredient?.name ?? "");
  const normalized = displayName.toLowerCase();
  if (!GENERIC_INGREDIENT_BUCKETS.has(normalized)) return false;

  const concreteSiblingCount = (ingredients ?? []).filter((candidate) => {
    const candidateName = normalizeRecipeLine(candidate?.display_name ?? candidate?.displayName ?? candidate?.name ?? "");
    if (!candidateName) return false;
    if (candidateName.toLowerCase() === normalized) return false;
    return isConcreteIngredientName(candidateName);
  }).length;

  if (concreteSiblingCount >= 1) {
    return true;
  }

  const stepMentionsConcreteSibling = (steps ?? []).some((step) => {
    const text = normalizeText(step?.text ?? step?.instruction_text ?? step?.instruction ?? "");
    if (!text) return false;
    return (ingredients ?? []).some((candidate) => {
      const candidateName = normalizeRecipeLine(candidate?.display_name ?? candidate?.displayName ?? candidate?.name ?? "");
      return candidateName && candidateName.toLowerCase() !== normalized && isConcreteIngredientName(candidateName) && text.includes(candidateName.toLowerCase());
    });
  });

  return stepMentionsConcreteSibling;
}

function parseIngredientObjects(value) {
  if (Array.isArray(value)) {
    return value.map(normalizeIngredientObject).filter(Boolean);
  }

  const text = sanitizeRecipeText(value);
  if (!text) return [];

  const newlineParts = text
    .split(/\n+/)
    .map(normalizeRecipeLine)
    .filter(Boolean);

  const lines = newlineParts.length >= 2
    ? dedupeStrings(newlineParts)
    : dedupeStrings(
        text
          .split(/,(?!\s?\d)/)
          .map(normalizeRecipeLine)
          .filter(Boolean)
      );

  return lines.map(parseIngredientLine).filter(Boolean);
}

function buildIngredientRefs(stepText, ingredients) {
  const haystack = String(stepText ?? "").toLowerCase();
  const refs = [];
  const seen = new Set();

  for (const ingredient of ingredients) {
    const name = String(ingredient.name ?? "").trim();
    if (!name) continue;
    const normalized = name.toLowerCase();
    const keywords = normalized.split(/[^a-z0-9]+/).filter((part) => part.length >= 4);
    const matches = haystack.includes(normalized) || keywords.some((keyword) => haystack.includes(keyword));
    if (matches && !seen.has(normalized)) {
      refs.push(name);
      seen.add(normalized);
    }
  }

  return refs;
}

function normalizeStepObject(value, ingredients = []) {
  if (!value || typeof value !== "object") return null;
  const text = normalizeStepText(value.text ?? value.body ?? value.instruction ?? "");
  if (!text) return null;
  const number = Number.isFinite(value.number) ? Number(value.number) : null;
  const providedRefs = Array.isArray(value.ingredient_refs) ? value.ingredient_refs.map(normalizeRecipeLine).filter(Boolean) : [];
  return {
    number,
    text,
    tip_text: normalizeStepText(value.tip_text ?? value.tip ?? value.note ?? "") || null,
    ingredient_refs: providedRefs.length ? providedRefs : buildIngredientRefs(text, ingredients),
    ingredients: [],
  };
}

function parseInstructionSteps(value, ingredients = []) {
  if (Array.isArray(value)) {
    return value
      .map((step) => normalizeStepObject(step, ingredients))
      .filter(Boolean)
      .map((step, index) => ({ ...step, number: step.number ?? index + 1 }));
  }

  const htmlText = String(value ?? "")
    .replace(/<\/li>/gi, "\n")
    .replace(/<li[^>]*>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n");
  const text = sanitizeRecipeText(htmlText);
  if (!text) return [];

  const numbered = text
    .split(/\s*(?:^|\n|\r|\t)(?:step\s*)?\d{1,2}[.)]\s*/i)
    .map(normalizeStepText)
    .filter(Boolean);

  const lines = numbered.length >= 2
    ? numbered
    : (() => {
        const newlineParts = text.split(/\n+/).map(normalizeStepText).filter(Boolean);
        if (newlineParts.length >= 2) return newlineParts;
        return text
          .split(/(?<=[.!?])\s+(?=[A-Z])/)
          .map(normalizeStepText)
          .filter(Boolean);
      })();

  return lines.map((line, index) => ({
    number: index + 1,
    text: line,
    tip_text: null,
    ingredient_refs: buildIngredientRefs(line, ingredients),
    ingredients: ingredients
      .filter((ingredient) => buildIngredientRefs(line, [ingredient]).length > 0)
      .slice(0, 4),
  }));
}

function buildStructuredSteps(stepRows, stepIngredientRows, ingredients) {
  if (!Array.isArray(stepRows) || !stepRows.length) return [];

  const ingredientById = new Map(
    (ingredients ?? [])
      .filter(Boolean)
      .map((ingredient) => [String(ingredient.ingredient_id ?? ingredient.id ?? ingredient.display_name ?? ""), ingredient])
  );

  const stepIngredientsByStepID = new Map();
  for (const row of stepIngredientRows ?? []) {
    if (!row?.recipe_step_id) continue;
    const normalizedRow = normalizeRecipeIngredientRow({
      ...row,
      image_url: ingredientById.get(String(row.ingredient_id ?? ""))?.image_url ?? null,
    });
    if (!normalizedRow) continue;
    const key = String(row.recipe_step_id);
    const current = stepIngredientsByStepID.get(key) ?? [];
    current.push(normalizedRow);
    stepIngredientsByStepID.set(key, current);
  }

  return stepRows
    .map((row, index) => {
      const text = normalizeStepText(row.instruction_text ?? row.text ?? "");
      if (!text) return null;

      const stepIngredients = (stepIngredientsByStepID.get(String(row.id)) ?? [])
        .sort((a, b) => (a.sort_order ?? 9999) - (b.sort_order ?? 9999));

      return {
        number: Number.isFinite(row.step_number) ? Number(row.step_number) : index + 1,
        text,
        tip_text: normalizeStepText(row.tip_text ?? "") || null,
        ingredient_refs: stepIngredients.map((ingredient) => ingredient.display_name),
        ingredients: stepIngredients,
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.number - b.number);
}

export function normalizeRecipeDetail(recipe, related = {}) {
  const sourceURLs = resolveRecipeSourceURLs(recipe);
  const structuredIngredients = Array.isArray(related.recipeIngredients)
    ? related.recipeIngredients.map(normalizeRecipeIngredientRow).filter(Boolean)
    : Array.isArray(recipe.recipe_ingredients)
      ? recipe.recipe_ingredients.map(normalizeRecipeIngredientRow).filter(Boolean)
      : [];

  const fallbackIngredients = parseIngredientObjects(recipe.ingredients_json ?? recipe.ingredients_text);
  const ingredientSources = structuredIngredients.length ? structuredIngredients : fallbackIngredients;

  const structuredSteps = buildStructuredSteps(
    related.recipeSteps ?? recipe.recipe_steps ?? [],
    related.stepIngredients ?? recipe.recipe_step_ingredients ?? [],
    ingredientSources
  );

  const steps = structuredSteps.length ? structuredSteps : parseInstructionSteps(recipe.steps_json ?? recipe.instructions_text, ingredientSources);
  const enrichedIngredients = enrichIngredientQuantities(
    ingredientSources,
    steps.flatMap((step) => Array.isArray(step.ingredients) ? step.ingredients : [])
  );
  const ingredients = enrichedIngredients
    .map((ingredient) => {
      const displayName = normalizeRecipeLine(ingredient.display_name ?? ingredient.displayName ?? ingredient.name ?? "");
      if (!displayName) return null;
      if (shouldDropGenericIngredientRow(ingredient, enrichedIngredients, steps)) {
        return null;
      }
      const normalizedName = displayName.toLowerCase();
      if (GENERIC_INGREDIENT_BUCKETS.has(normalizedName)) {
        return {
          ...ingredient,
          display_name: normalizeGenericIngredientBucket(displayName),
          name: normalizeGenericIngredientBucket(displayName),
          image_hint: normalizeGenericIngredientBucket(displayName).toLowerCase(),
        };
      }
      return ingredient;
    })
    .filter(Boolean);
  const servingsCount = Number.isFinite(recipe.servings_count)
    ? Number(recipe.servings_count)
    : parseFirstInteger(recipe.servings_text);

  return {
    id: recipe.id,
    title: recipe.title ?? "",
    description: recipe.description ?? "",
    author_name: recipe.author_name ?? null,
    author_handle: recipe.author_handle ?? null,
    source: recipe.source ?? null,
    source_platform: recipe.source_platform ?? null,
    category: recipe.category ?? null,
    subcategory: recipe.subcategory ?? null,
    recipe_type: recipe.recipe_type ?? null,
    skill_level: recipe.skill_level ?? null,
    cook_time_text: recipe.cook_time_text ?? null,
    servings_text: recipe.servings_text ?? null,
    serving_size_text: recipe.serving_size_text ?? null,
    daily_diet_text: recipe.daily_diet_text ?? null,
    est_cost_text: recipe.est_cost_text ?? null,
    est_calories_text: recipe.est_calories_text ?? null,
    carbs_text: recipe.carbs_text ?? null,
    protein_text: recipe.protein_text ?? null,
    fats_text: recipe.fats_text ?? null,
    calories_kcal: recipe.calories_kcal ?? null,
    protein_g: recipe.protein_g ?? null,
    carbs_g: recipe.carbs_g ?? null,
    fat_g: recipe.fat_g ?? null,
    prep_time_minutes: recipe.prep_time_minutes ?? null,
    cook_time_minutes: recipe.cook_time_minutes ?? null,
    hero_image_url: recipe.hero_image_url ?? null,
    discover_card_image_url: recipe.discover_card_image_url ?? null,
    recipe_url: sourceURLs.recipe_url,
    original_recipe_url: sourceURLs.original_recipe_url,
    attached_video_url: sourceURLs.attached_video_url,
    source_provenance_json: recipe.source_provenance_json ?? null,
    detail_footnote: recipe.detail_footnote ?? null,
    image_caption: recipe.image_caption ?? null,
    dietary_tags: Array.isArray(recipe.dietary_tags) ? recipe.dietary_tags : [],
    flavor_tags: Array.isArray(recipe.flavor_tags) ? recipe.flavor_tags : [],
    cuisine_tags: Array.isArray(recipe.cuisine_tags) ? recipe.cuisine_tags : [],
    occasion_tags: Array.isArray(recipe.occasion_tags) ? recipe.occasion_tags : [],
    main_protein: recipe.main_protein ?? null,
    cook_method: recipe.cook_method ?? null,
    ingredients,
    steps,
    servings_count: servingsCount,
  };
}

export function buildCanonicalRecipePayload(recipe) {
  const normalized = normalizeRecipeDetail(recipe);
  return {
    ingredients_json: normalized.ingredients,
    steps_json: normalized.steps,
    servings_count: normalized.servings_count,
  };
}

export {
  parseFirstInteger,
  parseIngredientObjects,
  parseInstructionSteps,
  sanitizeRecipeText,
};
