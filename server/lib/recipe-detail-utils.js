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

function normalizeRecipeLine(value) {
  return String(value ?? "")
    .replace(/^[-*•\s]+/, "")
    .replace(/\s+/g, " ")
    .trim();
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
  "fillets", "breast", "breasts", "thigh", "thighs"
]);

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
  const name = normalizeRecipeLine(value.name ?? value.ingredient ?? value.label ?? "");
  if (!name) return null;

  const quantityRaw = value.quantity ?? value.amount ?? value.qty ?? null;
  const quantity = typeof quantityRaw === "number" ? quantityRaw : parseQuantityToken(String(quantityRaw ?? "").trim());
  const unit = normalizeRecipeLine(value.unit ?? value.measure ?? "") || null;
  const note = normalizeRecipeLine(value.note ?? value.notes ?? "") || null;
  const imageHint = normalizeRecipeLine(value.image_hint ?? value.imageHint ?? name).toLowerCase() || name.toLowerCase();

  return {
    id: null,
    ingredient_id: null,
    display_name: name,
    quantity_text: [quantity != null ? String(quantity) : null, unit].filter(Boolean).join(" ").trim() || null,
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

  const displayName = normalizeRecipeLine(value.display_name ?? value.name ?? value.ingredient_name ?? "");
  if (!displayName) return null;

  return {
    id: value.id ?? null,
    ingredient_id: value.ingredient_id ?? null,
    display_name: displayName,
    quantity_text: normalizeRecipeLine(value.quantity_text ?? value.amount_text ?? "") || null,
    image_url: value.image_url ?? null,
    sort_order: Number.isFinite(value.sort_order) ? Number(value.sort_order) : null,
    name: displayName,
    quantity: null,
    unit: null,
    note: null,
    image_hint: displayName.toLowerCase(),
  };
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
  const structuredIngredients = Array.isArray(related.recipeIngredients)
    ? related.recipeIngredients.map(normalizeRecipeIngredientRow).filter(Boolean)
    : Array.isArray(recipe.recipe_ingredients)
      ? recipe.recipe_ingredients.map(normalizeRecipeIngredientRow).filter(Boolean)
      : [];

  const fallbackIngredients = parseIngredientObjects(recipe.ingredients_json ?? recipe.ingredients_text);
  const ingredients = structuredIngredients.length ? structuredIngredients : fallbackIngredients;

  const structuredSteps = buildStructuredSteps(
    related.recipeSteps ?? recipe.recipe_steps ?? [],
    related.stepIngredients ?? recipe.recipe_step_ingredients ?? [],
    ingredients
  );

  const steps = structuredSteps.length ? structuredSteps : parseInstructionSteps(recipe.steps_json ?? recipe.instructions_text, ingredients);
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
    recipe_url: recipe.recipe_url ?? null,
    original_recipe_url: recipe.original_recipe_url ?? null,
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
