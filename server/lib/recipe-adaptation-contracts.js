import { parseFirstInteger, parseIngredientObjects } from "./recipe-detail-utils.js";

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

function recipeHaystack({ ingredients = [], steps = [], title = "", summary = "", tags = [] } = {}) {
  return normalizeText([
    title,
    summary,
    ...(ingredients ?? []).map((ingredient) => `${ingredient.quantityText ?? ""} ${ingredient.displayName ?? ""}`),
    ...(steps ?? []),
    ...(tags ?? []),
  ].join(" "));
}

function containsAny(haystack, terms) {
  const text = normalizeText(haystack);
  return (terms ?? []).some((term) => {
    const normalized = normalizeText(term);
    if (!normalized) return false;
    return new RegExp(`(^|\\s)${normalized.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(\\s|$)`).test(text);
  });
}

function countMatches(haystack, terms) {
  const text = normalizeText(haystack);
  return (terms ?? []).reduce((count, term) => count + (containsAny(text, [term]) ? 1 : 0), 0);
}

const MEAT_AND_SEAFOOD_TERMS = [
  "chicken", "beef", "steak", "pork", "bacon", "ham", "sausage", "turkey", "lamb", "duck",
  "veal", "goat", "fish", "salmon", "tuna", "cod", "tilapia", "shrimp", "prawn", "crab",
  "lobster", "anchovy", "gelatin", "bone broth", "chicken stock", "beef stock", "fish sauce",
];

const PLANT_FORWARD_TERMS = [
  "tofu", "tempeh", "lentil", "lentils", "chickpea", "chickpeas", "bean", "beans", "black bean", "white bean", "mushroom", "mushrooms",
  "eggplant", "cauliflower", "jackfruit", "seitan", "plant based", "walnut", "cashew",
  "paneer", "halloumi", "egg", "quinoa",
];

const DAIRY_TERMS = [
  "milk", "whole milk", "cow milk", "dairy milk", "evaporated milk", "condensed milk", "butter", "cream", "cheese", "cheddar", "mozzarella", "parmesan", "yogurt",
  "yoghurt", "sour cream", "buttermilk", "ghee", "whey", "lactose", "half and half",
];

const DAIRY_FREE_SWAP_TERMS = [
  "olive oil", "avocado oil", "coconut milk", "coconut cream", "oat milk", "almond milk",
  "cashew cream", "vegan butter", "nutritional yeast", "tahini",
];

const SUGAR_TERMS = [
  "sugar", "brown sugar", "white sugar", "honey", "maple syrup", "corn syrup", "agave",
  "molasses", "sweetened condensed milk", "jam", "jelly", "caramel", "chocolate chips",
];

const HEAT_TERMS = [
  "chili", "chilli", "jalapeno", "serrano", "habanero", "scotch bonnet", "cayenne",
  "paprika", "hot sauce", "sriracha", "gochujang", "harissa", "pepper flakes",
  "red pepper flakes", "chipotle", "peri peri",
];

const PROTEIN_TERMS = [
  "chicken", "turkey", "beef", "salmon", "tuna", "shrimp", "egg", "eggs", "tofu",
  "tempeh", "seitan", "lentil", "chickpea", "bean", "beans", "greek yogurt", "cottage cheese",
  "protein", "quinoa",
];

const VEGETABLE_TERMS = [
  "broccoli", "spinach", "kale", "pepper", "bell pepper", "carrot", "zucchini", "mushroom",
  "tomato", "cabbage", "cauliflower", "eggplant", "asparagus", "green bean", "peas",
  "onion", "scallion", "arugula", "lettuce", "cucumber", "squash",
];

const CRISP_TERMS = [
  "crispy", "crisp", "crunchy", "crunch", "toast", "toasted", "sear", "seared", "broil",
  "air fry", "panko", "breadcrumbs", "nuts", "sesame", "fried shallot",
];

const STARCH_TERMS = [
  "rice", "pasta", "noodle", "bread", "potato", "tortilla", "flour", "bun", "wrap",
  "couscous", "orzo", "cracker",
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
    forbiddenTerms: MEAT_AND_SEAFOOD_TERMS,
    requiredReplacementTerms: PLANT_FORWARD_TERMS,
    validationHints: [
      "No meat/seafood terms may remain in ingredient names or step text.",
      "A vegetarian protein or plant-forward replacement should appear.",
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
    forbiddenTerms: DAIRY_TERMS,
    replacementTerms: DAIRY_FREE_SWAP_TERMS,
  },
  less_sugar: {
    key: "less_sugar",
    label: "Less sugar",
    requiredActions: [
      "Reduce sweeteners and sugary ingredients without making the recipe flat.",
      "Adjust steps that depend on sweetness, caramelization, glaze thickness, or dessert texture.",
      "Keep enough balance that the dish remains satisfying.",
    ],
    focusedTerms: SUGAR_TERMS,
  },
  more_protein: {
    key: "more_protein",
    label: "More protein",
    requiredActions: [
      "Increase or add a plausible protein source that fits the dish.",
      "Adjust quantities and steps for the higher-protein version.",
      "Update title, summary, and protein-aware tags if helpful.",
    ],
    focusedTerms: PROTEIN_TERMS,
  },
  spicy: {
    key: "spicy",
    label: "Make it spicy",
    requiredActions: [
      "Add heat in a cuisine-appropriate way.",
      "Balance spice with acid, fat, sweetness, or freshness where needed.",
      "Update steps so the heat source is cooked, bloomed, finished, or served correctly.",
    ],
    focusedTerms: HEAT_TERMS,
  },
  quick: {
    key: "quick",
    label: "Make it quick",
    requiredActions: [
      "Shorten cook/prep time or simplify the method.",
      "Cut fussy prep, long marinades, long bakes, or unnecessary steps.",
      "Keep the recipe coherent and weeknight-practical.",
    ],
    requiresFasterTiming: true,
  },
  extra_veggies: {
    key: "extra_veggies",
    label: "More veggies",
    requiredActions: [
      "Add vegetables that make sense for the dish.",
      "Adjust seasoning, moisture, and cooking steps so the added vegetables do not water down the recipe.",
    ],
    focusedTerms: VEGETABLE_TERMS,
  },
  low_carb: {
    key: "low_carb",
    label: "Make it low carb",
    requiredActions: [
      "Reduce or replace starch-heavy ingredients where it makes culinary sense.",
      "Update steps and serving format to match the lower-carb version.",
    ],
    focusedTerms: STARCH_TERMS,
  },
  crispy: {
    key: "crispy",
    label: "Make it crunchy",
    requiredActions: [
      "Add crunch or crisp texture through technique or ingredient choice.",
      "Update steps with the exact moment and method for getting the texture.",
    ],
    focusedTerms: CRISP_TERMS,
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
    focusedTerms: SUGAR_TERMS,
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
  const resolvedContract = contract ?? getRecipeAdaptationContract("", "", "");
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
  const baseIngredientHaystack = recipeHaystack({ ingredients: baseIngredients });
  const adaptedIngredientHaystack = recipeHaystack({ ingredients: adaptedIngredients });
  const adaptedFullHaystack = recipeHaystack({
    title: adaptedRecipe?.title,
    summary: adaptedRecipe?.summary,
    ingredients: adaptedIngredients,
    steps: adaptedSteps,
    tags: [
      ...(adaptedRecipe?.dietary_fit ?? []),
      ...(adaptedRecipe?.dietary_tags ?? []),
      ...(adaptedRecipe?.flavor_tags ?? []),
    ],
  });

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

  const baseForbiddenTerms = forbiddenTermsStillPresent(baseIngredientHaystack, resolvedContract.forbiddenTerms ?? [], resolvedContract.key);

  if (resolvedContract.forbiddenTerms?.length && baseForbiddenTerms.length) {
    const stillPresent = forbiddenTermsStillPresent(adaptedFullHaystack, resolvedContract.forbiddenTerms, resolvedContract.key);
    if (stillPresent.length) {
      failures.push(`Remove these forbidden ingredients from ingredients and steps: ${stillPresent.slice(0, 8).join(", ")}.`);
    }
  }

  if (resolvedContract.requiredReplacementTerms?.length && baseForbiddenTerms.length) {
    if (!containsAny(adaptedIngredientHaystack, resolvedContract.requiredReplacementTerms)) {
      failures.push(`Add a plausible replacement such as ${resolvedContract.requiredReplacementTerms.slice(0, 8).join(", ")}.`);
    }
  }

  if (resolvedContract.replacementTerms?.length && baseForbiddenTerms.length) {
    if (!removedIngredients.length && !containsAny(adaptedIngredientHaystack, resolvedContract.replacementTerms)) {
      failures.push(`Use a clear substitution such as ${resolvedContract.replacementTerms.slice(0, 8).join(", ")}.`);
    }
  }

  if (resolvedContract.key === "less_sugar") {
    const baseSugarCount = countMatches(baseIngredientHaystack, SUGAR_TERMS);
    const adaptedSugarCount = countMatches(adaptedIngredientHaystack, SUGAR_TERMS);
    const changedSugarQuantity = changedQuantities.some((line) => containsAny(line, SUGAR_TERMS));
    if (baseSugarCount > 0 && adaptedSugarCount >= baseSugarCount && !changedSugarQuantity) {
      failures.push("Reduce or replace at least one sweetener quantity; the sugar profile still looks unchanged.");
    }
  }

  if (resolvedContract.key === "more_protein") {
    const baseProteinCount = countMatches(baseIngredientHaystack, PROTEIN_TERMS);
    const adaptedProteinCount = countMatches(adaptedIngredientHaystack, PROTEIN_TERMS);
    const changedProteinQuantity = changedQuantities.some((line) => containsAny(line, PROTEIN_TERMS));
    if (adaptedProteinCount <= baseProteinCount && !changedProteinQuantity && !addedIngredients.some((name) => containsAny(name, PROTEIN_TERMS))) {
      failures.push("Add or increase a plausible protein source.");
    }
  }

  if (resolvedContract.key === "spicy" && !containsAny(adaptedFullHaystack, HEAT_TERMS)) {
    failures.push("Add a clear heat source and reference it in the method.");
  }

  if (resolvedContract.key === "extra_veggies") {
    const baseVegCount = countMatches(baseIngredientHaystack, VEGETABLE_TERMS);
    const adaptedVegCount = countMatches(adaptedIngredientHaystack, VEGETABLE_TERMS);
    if (adaptedVegCount <= baseVegCount) {
      failures.push("Add at least one vegetable that fits the dish.");
    }
  }

  if (resolvedContract.key === "crispy" && !containsAny(adaptedFullHaystack, CRISP_TERMS)) {
    failures.push("Add a concrete crispy/crunchy technique or ingredient.");
  }

  if (resolvedContract.key === "quick" && !looksFaster(baseDetail, adaptedRecipe, baseSteps, adaptedSteps)) {
    failures.push("Shorten the timing, step count, or method enough to make the recipe clearly quicker.");
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
    if (baseQuantity && adaptedQuantity && baseQuantity !== adaptedQuantity) {
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

function looksFaster(baseDetail, adaptedRecipe, baseSteps, adaptedSteps) {
  const baseMinutes = Number(baseDetail?.cook_time_minutes ?? parseFirstInteger(baseDetail?.cook_time_text));
  const adaptedMinutes = Number(parseFirstInteger(adaptedRecipe?.cook_time_text));
  if (Number.isFinite(baseMinutes) && Number.isFinite(adaptedMinutes) && adaptedMinutes > 0 && adaptedMinutes < baseMinutes) {
    return true;
  }
  if (baseSteps.length >= 5 && adaptedSteps.length < baseSteps.length) return true;
  const adaptedText = adaptedSteps.join(" ");
  return /quick|faster|weeknight|shortcut|same pan|one pan|no marinade|skip/.test(adaptedText);
}

function forbiddenTermsStillPresent(haystack, terms, contractKey = "") {
  let text = normalizeText(haystack);
  if (contractKey === "dairy_free") {
    const dairyFreeExceptions = [
      "almond milk", "oat milk", "soy milk", "coconut milk", "cashew milk", "rice milk", "hemp milk",
      "coconut cream", "cashew cream", "oat cream", "vegan cream",
      "vegan butter", "plant based butter", "plant butter",
      "vegan cheese", "dairy free cheese", "nutritional yeast",
    ];
    for (const exception of dairyFreeExceptions) {
      text = text.replace(new RegExp(`(^|\\s)${normalizeText(exception).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(\\s|$)`, "g"), " ");
    }
    text = text.replace(/\s+/g, " ").trim();
  }
  return (terms ?? []).filter((term) => containsAny(text, [term]));
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
