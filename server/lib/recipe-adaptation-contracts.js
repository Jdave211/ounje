import { parseIngredientObjects } from "./recipe-detail-utils.js";

const WORD_SPLIT = /[^a-z0-9]+/g;

function normalizeText(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[’']/g, "")
    .replace(WORD_SPLIT, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function singularizeToken(token) {
  if (token.length <= 3) return token;
  if (token.endsWith("ies")) return `${token.slice(0, -3)}y`;
  if (token.endsWith("es") && !token.endsWith("ses")) return token.slice(0, -2);
  if (token.endsWith("s") && !token.endsWith("ss")) return token.slice(0, -1);
  return token;
}

function normalizedName(value) {
  return normalizeText(value)
    .split(" ")
    .map(singularizeToken)
    .join(" ")
    .trim();
}

function normalizedIngredientRowsFromRecipe(value) {
  const rawIngredients = Array.isArray(value?.ingredients) ? value.ingredients : [];
  return parseIngredientObjects(rawIngredients)
    .map((ingredient, index) => ({
      displayName: String(ingredient.display_name ?? ingredient.name ?? "").trim(),
      quantityText: String(
        ingredient.quantity_text
          ?? ([ingredient.quantity != null ? String(ingredient.quantity) : null, ingredient.unit]
            .filter(Boolean)
            .join(" ")
            .trim() || "")
      ).trim(),
      index,
    }))
    .filter((ingredient) => ingredient.displayName);
}

function normalizedIngredientRowsFromDetail(detail) {
  return (detail?.ingredients ?? [])
    .map((ingredient, index) => ({
      displayName: String(ingredient.display_name ?? ingredient.displayName ?? ingredient.name ?? "").trim(),
      quantityText: String(ingredient.quantity_text ?? ingredient.quantityText ?? "").trim(),
      index,
    }))
    .filter((ingredient) => ingredient.displayName);
}

function normalizedStepTextsFromRecipe(value) {
  return (value?.steps ?? [])
    .map((step) => normalizeText(typeof step === "string" ? step : step?.text ?? step?.instruction_text ?? ""))
    .filter(Boolean);
}

function normalizedStepTextsFromDetail(detail) {
  return (detail?.steps ?? [])
    .map((step) => normalizeText(step?.text ?? step?.instruction_text ?? ""))
    .filter(Boolean);
}

function containsAny(haystack, terms) {
  const text = normalizeText(haystack);
  return (terms ?? []).some((term) => {
    const normalized = normalizeText(term);
    if (!normalized) return false;
    return new RegExp(`(^|\\s)${normalized.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(\\s|$)`).test(text);
  });
}

function ingredientIsMentionedInSteps(ingredientName, stepHaystack) {
  const normalized = normalizedName(ingredientName);
  if (!normalized) return false;
  if (containsAny(stepHaystack, [normalized])) return true;

  const withoutParenthetical = normalized.replace(/\s*\([^)]*\)\s*/g, " ").replace(/\s+/g, " ").trim();
  if (withoutParenthetical && withoutParenthetical !== normalized && containsAny(stepHaystack, [withoutParenthetical])) {
    return true;
  }

  const tokens = withoutParenthetical
    .split(/\s+/)
    .map((token) => token.replace(/[^a-z0-9-]+/g, ""))
    .filter((token) => token.length >= 4 && !["fresh", "diced", "sliced", "chopped", "optional", "taste", "wash"].includes(token));
  if (!tokens.length) return false;
  const text = normalizeText(stepHaystack);
  const matched = tokens.filter((token) => text.includes(token)).length;
  return matched >= Math.min(2, tokens.length);
}

const GENERIC_PLACEHOLDER_INGREDIENT_TERMS = [
  "protein",
  "extra protein",
  "protein source",
  "lean protein",
  "plant protein",
  "vegetarian protein",
  "healthy ingredient",
  "crunch",
  "crunchy topping",
  "spice",
  "spicy seasoning",
  "vegetables",
  "veggies",
  "sweetener",
  "dairy free substitute",
];

const INTENT_CONTRACTS = {
  vegetarian: {
    key: "vegetarian",
    label: "Make it vegetarian",
    requiredActions: [
      "Remove meat, seafood, meat stock, fish sauce, gelatin, and animal-derived broth from ingredients and steps.",
      "Add a plausible vegetarian protein or plant-forward base so the dish still feels complete.",
      "Rewrite affected cooking steps so removed animal ingredients are not referenced.",
      "Update dietary tags and summary to reflect the vegetarian version.",
    ],
    validationHints: [
      "The semantic validator must confirm animal ingredients were removed from both ingredients and steps.",
      "The semantic validator must confirm the replacement still makes the dish feel complete.",
    ],
  },
  dairy_free: {
    key: "dairy_free",
    label: "Make it dairy-free",
    requiredActions: [
      "Remove or replace dairy ingredients with practical dairy-free alternatives.",
      "Update quantities and steps so the sauce, texture, or fat source still works.",
      "Update dietary tags and summary to reflect the dairy-free version.",
    ],
  },
  less_sugar: {
    key: "less_sugar",
    label: "Less sugar",
    requiredActions: [
      "Reduce sweeteners and sugary ingredients without making the recipe flat.",
      "Adjust steps that depend on sweetness, caramelization, glaze thickness, or dessert texture.",
      "Keep enough balance that the dish remains satisfying.",
    ],
  },
  more_protein: {
    key: "more_protein",
    label: "More protein",
    requiredActions: [
      "Increase or add a real, named protein source that fits the dish.",
      "Never add a placeholder ingredient named protein, extra protein, or protein source.",
      "Keep the base dish format intact and upgrade the filling, topping, sauce, or core ingredient with a real protein where appropriate.",
      "Adjust quantities and steps for the higher-protein version.",
      "Update title, summary, and protein-aware tags if helpful.",
    ],
  },
  spicy: {
    key: "spicy",
    label: "Make it spicy",
    requiredActions: [
      "Add heat in a cuisine-appropriate way.",
      "Balance spice with acid, fat, sweetness, or freshness where needed.",
      "Update steps so the heat source is cooked, bloomed, finished, or served correctly.",
    ],
  },
  quick: {
    key: "quick",
    label: "Make it quick",
    requiredActions: [
      "Shorten cook/prep time or simplify the method.",
      "Cut fussy prep, long marinades, long bakes, or unnecessary steps.",
      "Keep the recipe coherent and weeknight-practical.",
    ],
  },
  extra_veggies: {
    key: "extra_veggies",
    label: "More veggies",
    requiredActions: [
      "Add vegetables that make sense for the dish.",
      "Adjust seasoning, moisture, and cooking steps so the added vegetables do not water down the recipe.",
    ],
  },
  low_carb: {
    key: "low_carb",
    label: "Make it low carb",
    requiredActions: [
      "Reduce or replace starch-heavy ingredients where it makes culinary sense.",
      "Update steps and serving format to match the lower-carb version.",
    ],
  },
  crispy: {
    key: "crispy",
    label: "Make it crunchy",
    requiredActions: [
      "Add crunch or crisp texture through technique or ingredient choice.",
      "Update steps with the exact moment and method for getting the texture.",
    ],
  },
  healthier: {
    key: "healthier",
    label: "Make it healthy",
    requiredActions: [
      "Improve the nutrition profile while keeping the dish satisfying.",
      "Lean on vegetables, balanced fat, protein, and practical quantity changes.",
      "Update steps and summary so the healthier version is still cookable.",
    ],
  },
  lighter: {
    key: "lighter",
    label: "Make it lighter",
    requiredActions: [
      "Reduce heaviness from excess fat, cream, starch, or overly rich components where present.",
      "Add freshness, acid, herbs, or lighter cooking technique where appropriate.",
      "Update steps and quantities to match the lighter version.",
    ],
  },
  sweeter: {
    key: "sweeter",
    label: "Make it sweet",
    requiredActions: [
      "Increase sweetness or fruit/dessert energy in a balanced way.",
      "Update quantities and steps so the sweetness is integrated, not just renamed.",
    ],
  },
  budget_friendly: {
    key: "budget_friendly",
    label: "Budget-friendly",
    requiredActions: [
      "Swap expensive ingredients for cheaper practical ones while preserving the dish.",
      "Keep ingredient count reasonable and update steps for the substitutions.",
    ],
  },
  meal_prep: {
    key: "meal_prep",
    label: "Make it prep-ready",
    requiredActions: [
      "Make the recipe hold up after storage and reheating.",
      "Adjust ingredients, steps, and serving notes for make-ahead prep.",
    ],
  },
  kid_friendly: {
    key: "kid_friendly",
    label: "Kid-friendly",
    requiredActions: [
      "Make flavors gentler and texture easier to eat without making the dish bland.",
      "Update steps and serving style for a family-friendly version.",
    ],
  },
  comfort: {
    key: "comfort",
    label: "More comfort",
    requiredActions: [
      "Make the dish cozier and more comforting through sauce, texture, warmth, or seasoning.",
      "Update ingredients and steps to create that result.",
    ],
  },
};

export function getRecipeAdaptationContract(intentKey = "", intentLabel = "", adaptationPrompt = "") {
  const normalizedKey = normalizeText(intentKey).replace(/\s+/g, "_");
  const inferredKey = normalizedKey || inferIntentKeyFromPrompt(adaptationPrompt);
  const contract = INTENT_CONTRACTS[inferredKey] ?? null;
  if (!contract) {
    return {
      key: inferredKey || "custom",
      label: intentLabel || "Custom rewrite",
      requiredActions: [
        "Rewrite the full recipe to satisfy the user's request.",
        "Update ingredients, quantities, steps, title, summary, tags, and timing wherever the request changes the dish.",
      ],
      validationHints: [
        "The output must not be a title-only or summary-only edit.",
        "Ingredients or quantities and at least one step must change.",
      ],
    };
  }
  return {
    ...contract,
    label: intentLabel || contract.label,
  };
}

function inferIntentKeyFromPrompt(prompt) {
  const text = normalizeText(prompt);
  if (/vegetarian|veggie|plant/.test(text)) return "vegetarian";
  if (/dairy free|no dairy|without dairy/.test(text)) return "dairy_free";
  if (/less sugar|lower sugar|reduce sugar/.test(text)) return "less_sugar";
  if (/protein/.test(text)) return "more_protein";
  if (/spicy|spicier|heat/.test(text)) return "spicy";
  if (/quick|faster|busy weeknight/.test(text)) return "quick";
  if (/vegetable|veggies/.test(text)) return "extra_veggies";
  if (/low carb|lower carb/.test(text)) return "low_carb";
  if (/crisp|crunch/.test(text)) return "crispy";
  if (/healthy|healthier/.test(text)) return "healthier";
  if (/lighter/.test(text)) return "lighter";
  if (/sweet|sweeter/.test(text)) return "sweeter";
  if (/budget|cheap|affordable/.test(text)) return "budget_friendly";
  if (/meal prep|prep ready|reheat/.test(text)) return "meal_prep";
  if (/kid|child|family/.test(text)) return "kid_friendly";
  if (/comfort|cozy/.test(text)) return "comfort";
  return "";
}

export function validateAdaptedRecipe({ baseDetail, adaptedRecipe, contract, strict = true } = {}) {
  const baseIngredients = normalizedIngredientRowsFromDetail(baseDetail);
  const adaptedIngredients = normalizedIngredientRowsFromRecipe(adaptedRecipe);
  const baseSteps = normalizedStepTextsFromDetail(baseDetail);
  const adaptedSteps = normalizedStepTextsFromRecipe(adaptedRecipe);
  const baseNames = new Set(baseIngredients.map((ingredient) => normalizedName(ingredient.displayName)).filter(Boolean));
  const adaptedNames = new Set(adaptedIngredients.map((ingredient) => normalizedName(ingredient.displayName)).filter(Boolean));
  const addedIngredients = adaptedIngredients
    .filter((ingredient) => !baseNames.has(normalizedName(ingredient.displayName)))
    .map((ingredient) => ingredient.displayName);
  const removedIngredients = baseIngredients
    .filter((ingredient) => !adaptedNames.has(normalizedName(ingredient.displayName)))
    .map((ingredient) => ingredient.displayName);
  const changedQuantities = changedQuantityLines(baseIngredients, adaptedIngredients);
  const changedSteps = changedStepLines(baseSteps, adaptedSteps);
  const failures = [];
  const adaptedStepHaystack = adaptedSteps.join(" ");
  if (adaptedIngredients.length < 3) {
    failures.push("The adapted recipe must include at least 3 practical ingredients.");
  }
  if (adaptedSteps.length < 3) {
    failures.push("The adapted recipe must include at least 3 concrete cooking steps.");
  }
  if (!addedIngredients.length && !removedIngredients.length && !changedQuantities.length) {
    failures.push("The adaptation changed no ingredients or quantities.");
  }
  if (!changedSteps.length) {
    failures.push("The adaptation changed no cooking steps.");
  }

  const placeholderIngredients = adaptedIngredients
    .map((ingredient) => ingredient.displayName)
    .filter((name) => GENERIC_PLACEHOLDER_INGREDIENT_TERMS.some((term) => normalizedName(name) === normalizedName(term)));
  if (placeholderIngredients.length) {
    failures.push(`Replace placeholder ingredient names with real groceries: ${placeholderIngredients.slice(0, 6).join(", ")}.`);
  }

  const addedIngredientsMissingFromSteps = addedIngredients.filter((name) => {
    const normalized = normalizedName(name);
    if (!normalized || containsAny(name, ["salt", "pepper", "water"])) return false;
    return !ingredientIsMentionedInSteps(name, adaptedStepHaystack);
  });
  if (addedIngredientsMissingFromSteps.length) {
    failures.push(`Use every added ingredient in the method: ${addedIngredientsMissingFromSteps.slice(0, 6).join(", ")}.`);
  }

  if (strict && failures.length) {
    return {
      valid: false,
      failures,
      editSummary: buildEditSummary({ addedIngredients, removedIngredients, changedQuantities, changedSteps, validationNotes: failures }),
    };
  }

  return {
    valid: failures.length === 0,
    failures,
    editSummary: buildEditSummary({ addedIngredients, removedIngredients, changedQuantities, changedSteps, validationNotes: failures }),
  };
}

function changedQuantityLines(baseIngredients, adaptedIngredients) {
  const adaptedByName = new Map(adaptedIngredients.map((ingredient) => [normalizedName(ingredient.displayName), ingredient]));
  const changes = [];
  for (const baseIngredient of baseIngredients) {
    const key = normalizedName(baseIngredient.displayName);
    const adaptedIngredient = adaptedByName.get(key);
    if (!adaptedIngredient) continue;
    const baseQuantity = normalizeText(baseIngredient.quantityText);
    const adaptedQuantity = normalizeText(adaptedIngredient.quantityText);
    if (adaptedQuantity && baseQuantity !== adaptedQuantity) {
      changes.push(`${baseIngredient.displayName}: ${baseIngredient.quantityText || "unspecified"} -> ${adaptedIngredient.quantityText || "unspecified"}`);
    }
  }
  return changes;
}

function changedStepLines(baseSteps, adaptedSteps) {
  const changes = [];
  const count = Math.max(baseSteps.length, adaptedSteps.length);
  for (let index = 0; index < count; index += 1) {
    const baseStep = baseSteps[index] ?? "";
    const adaptedStep = adaptedSteps[index] ?? "";
    if (baseStep !== adaptedStep && adaptedStep) {
      changes.push(`Step ${index + 1}: ${adaptedStep}`);
    }
  }
  return changes.slice(0, 12);
}

function buildEditSummary({ addedIngredients, removedIngredients, changedQuantities, changedSteps, validationNotes }) {
  return {
    added_ingredients: uniqueStrings(addedIngredients).slice(0, 12),
    removed_ingredients: uniqueStrings(removedIngredients).slice(0, 12),
    changed_ingredients: uniqueStrings([...addedIngredients, ...removedIngredients]).slice(0, 12),
    changed_quantities: uniqueStrings(changedQuantities).slice(0, 12),
    changed_steps: uniqueStrings(changedSteps).slice(0, 12),
    validation_notes: uniqueStrings(validationNotes).slice(0, 12),
  };
}

function uniqueStrings(values) {
  return [...new Set((values ?? []).map((value) => String(value ?? "").trim()).filter(Boolean))];
}

export function mergeEditSummaries(modelSummary = {}, computedSummary = {}) {
  return {
    added_ingredients: uniqueStrings([
      ...(computedSummary.added_ingredients ?? []),
      ...(modelSummary.added_ingredients ?? []),
    ]).slice(0, 12),
    removed_ingredients: uniqueStrings([
      ...(computedSummary.removed_ingredients ?? []),
      ...(modelSummary.removed_ingredients ?? []),
    ]).slice(0, 12),
    changed_ingredients: uniqueStrings([
      ...(computedSummary.changed_ingredients ?? []),
      ...(modelSummary.changed_ingredients ?? []),
    ]).slice(0, 12),
    changed_quantities: uniqueStrings([
      ...(computedSummary.changed_quantities ?? []),
      ...(modelSummary.changed_quantities ?? []),
    ]).slice(0, 12),
    changed_steps: uniqueStrings([
      ...(computedSummary.changed_steps ?? []),
      ...(modelSummary.changed_steps ?? []),
    ]).slice(0, 12),
    validation_notes: uniqueStrings([
      ...(computedSummary.validation_notes ?? []),
      ...(modelSummary.validation_notes ?? []),
    ]).slice(0, 12),
  };
}
