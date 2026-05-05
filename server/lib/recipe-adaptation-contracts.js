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
      "The rewrite should remove animal ingredients from both ingredients and steps.",
      "The rewrite should keep the dish complete with a fitting vegetarian base or protein.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 lb chicken thighs", "1 tbsp fish sauce"],
          step_change: "Marinate chicken, skewer, then grill until cooked through.",
        },
        adapted: {
          ingredient_changes: ["14 oz extra-firm tofu, pressed and cubed", "2 tbsp soy sauce", "1 tbsp lemon juice"],
          step_change: "Press tofu, cube it, coat in shawarma marinade, then roast or air-fry until browned at the edges.",
        },
      },
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
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 cup heavy cream", "1/2 cup grated parmesan", "2 tbsp butter"],
          step_change: "Simmer cream and parmesan until the sauce thickens.",
        },
        adapted: {
          ingredient_changes: ["3/4 cup full-fat coconut milk", "2 tbsp olive oil", "1 tbsp nutritional yeast"],
          step_change: "Simmer coconut milk with nutritional yeast and olive oil until glossy; do not add dairy.",
        },
      },
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
    editExamples: [
      {
        base: {
          ingredient_changes: ["1/2 cup brown sugar", "1/4 cup honey", "1 cup sweetened yogurt"],
          step_change: "Whisk sugar and honey into the filling until very sweet.",
        },
        adapted: {
          ingredient_changes: ["2 tbsp brown sugar", "1 tbsp honey", "1 cup plain Greek yogurt", "1/2 tsp vanilla"],
          step_change: "Whisk the smaller amount of honey and sugar with vanilla into plain yogurt; rely on fruit or spice for balance.",
        },
      },
    ],
  },
  more_protein: {
    key: "more_protein",
    label: "More protein",
    requiredActions: [
      "Increase or add a real, named protein source that fits the dish.",
      "Use concrete grocery ingredients, not abstract nutrition labels.",
      "Keep the base dish format intact and upgrade the filling, topping, sauce, or core ingredient with a real protein where appropriate.",
      "Adjust quantities and steps for the higher-protein version.",
      "Update title, summary, and protein-aware tags if helpful.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 cup all-purpose flour", "2 bananas", "1 egg"],
          step_change: "Mix the batter and bake.",
        },
        adapted: {
          ingredient_changes: ["3/4 cup all-purpose flour", "1/2 cup vanilla Greek yogurt", "2 eggs", "2 tbsp almond butter"],
          step_change: "Whisk Greek yogurt, eggs, and almond butter into the wet ingredients before folding in the reduced flour.",
        },
      },
      {
        base: {
          ingredient_changes: ["4 hot dog buns", "4 beef hot dogs"],
          step_change: "Warm hot dogs and assemble in buns.",
        },
        adapted: {
          ingredient_changes: ["4 turkey or beef hot dogs", "1 cup turkey chili", "1/2 cup shredded cheddar"],
          step_change: "Heat the turkey chili separately, spoon it over the hot dogs, then finish with cheddar so the extra protein is part of the dish.",
        },
      },
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
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 tsp paprika", "1 tbsp olive oil", "1 tbsp lemon juice"],
          step_change: "Season and cook the protein.",
        },
        adapted: {
          ingredient_changes: ["1 tsp paprika", "1 tsp cayenne", "1 tbsp chili crisp", "2 tbsp lime juice"],
          step_change: "Bloom cayenne in the hot oil, cook the protein, then finish with chili crisp and lime so the heat has balance.",
        },
      },
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
    editExamples: [
      {
        base: {
          ingredient_changes: ["2-hour marinade", "whole roasted vegetables", "long-simmer sauce"],
          step_change: "Marinate for 2 hours, roast vegetables for 45 minutes, then simmer sauce.",
        },
        adapted: {
          ingredient_changes: ["10-minute spice rub", "thin-sliced vegetables", "quick skillet sauce"],
          step_change: "Rub seasoning directly onto the protein, sear it, saute thin-sliced vegetables in the same pan, and reduce sauce for 3-5 minutes.",
        },
      },
    ],
  },
  extra_veggies: {
    key: "extra_veggies",
    label: "More veggies",
    requiredActions: [
      "Add vegetables that make sense for the dish.",
      "Adjust seasoning, moisture, and cooking steps so the added vegetables do not water down the recipe.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 bell pepper", "1/2 onion"],
          step_change: "Cook aromatics, then add sauce.",
        },
        adapted: {
          ingredient_changes: ["1 bell pepper", "1 zucchini, diced", "1 cup mushrooms, sliced", "1/2 onion"],
          step_change: "Brown mushrooms first to drive off moisture, then add zucchini and bell pepper before the sauce.",
        },
      },
    ],
  },
  low_carb: {
    key: "low_carb",
    label: "Make it low carb",
    requiredActions: [
      "Reduce or replace starch-heavy ingredients where it makes culinary sense.",
      "Update steps and serving format to match the lower-carb version.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["2 cups cooked rice", "4 flour tortillas"],
          step_change: "Serve the filling over rice or wrapped in tortillas.",
        },
        adapted: {
          ingredient_changes: ["3 cups cauliflower rice", "large romaine leaves or low-carb wraps"],
          step_change: "Saute cauliflower rice until dry and fluffy, then serve the filling over it or tuck into lettuce leaves.",
        },
      },
    ],
  },
  crispy: {
    key: "crispy",
    label: "Make it crunchy",
    requiredActions: [
      "Add crunch or crisp texture through technique or ingredient choice.",
      "Update steps with the exact moment and method for getting the texture.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["plain baked topping"],
          step_change: "Bake until warmed through.",
        },
        adapted: {
          ingredient_changes: ["1/2 cup toasted panko", "2 tbsp chopped peanuts", "1 tbsp olive oil"],
          step_change: "Toast panko and peanuts in olive oil until golden, then scatter over the finished dish right before serving.",
        },
      },
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
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 cup mayonnaise", "1 cup white rice", "2 tbsp butter"],
          step_change: "Stir mayonnaise into the sauce and serve over white rice.",
        },
        adapted: {
          ingredient_changes: ["1/3 cup Greek yogurt", "1 cup brown rice or quinoa", "1 tbsp olive oil", "2 cups greens"],
          step_change: "Fold Greek yogurt in off heat, serve over brown rice or quinoa, and wilt greens into the pan at the end.",
        },
      },
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
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 cup cream", "3 tbsp butter", "fried topping"],
          step_change: "Finish with cream, butter, and fried topping.",
        },
        adapted: {
          ingredient_changes: ["1/2 cup broth", "1/4 cup Greek yogurt", "1 tbsp olive oil", "2 tbsp lemon juice", "fresh herbs"],
          step_change: "Reduce broth, stir in Greek yogurt off heat, then finish with lemon juice and herbs instead of frying a topping.",
        },
      },
    ],
  },
  sweeter: {
    key: "sweeter",
    label: "Make it sweet",
    requiredActions: [
      "Increase sweetness or fruit/dessert energy in a balanced way.",
      "Update quantities and steps so the sweetness is integrated, not just renamed.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 tbsp maple syrup", "plain yogurt"],
          step_change: "Top with yogurt and serve.",
        },
        adapted: {
          ingredient_changes: ["2 tbsp maple syrup", "1/2 cup sliced strawberries", "1 tbsp honey", "1/4 tsp cinnamon"],
          step_change: "Warm maple syrup with cinnamon, spoon it over the fruit, then drizzle honey over the finished bowl.",
        },
      },
    ],
  },
  budget_friendly: {
    key: "budget_friendly",
    label: "Budget-friendly",
    requiredActions: [
      "Swap expensive ingredients for cheaper practical ones while preserving the dish.",
      "Keep ingredient count reasonable and update steps for the substitutions.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 lb salmon", "1 cup specialty cheese", "pine nuts"],
          step_change: "Sear salmon and finish with cheese and pine nuts.",
        },
        adapted: {
          ingredient_changes: ["1 lb chicken thighs or canned chickpeas", "1/2 cup shredded cheddar", "sunflower seeds"],
          step_change: "Cook the cheaper protein with the same seasoning profile, then finish with cheddar and toasted sunflower seeds.",
        },
      },
    ],
  },
  meal_prep: {
    key: "meal_prep",
    label: "Make it prep-ready",
    requiredActions: [
      "Make the recipe hold up after storage and reheating.",
      "Adjust ingredients, steps, and serving notes for make-ahead prep.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["crispy lettuce", "delicate sauce mixed in"],
          step_change: "Assemble everything together immediately.",
        },
        adapted: {
          ingredient_changes: ["sturdy greens or roasted vegetables", "sauce packed separately", "extra 1/4 cup sauce for reheating"],
          step_change: "Cook components fully, cool before packing, store sauce separately, and add it after reheating.",
        },
      },
    ],
  },
  kid_friendly: {
    key: "kid_friendly",
    label: "Kid-friendly",
    requiredActions: [
      "Make flavors gentler and texture easier to eat without making the dish bland.",
      "Update steps and serving style for a family-friendly version.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["1 tbsp chili flakes", "sharp pickled garnish", "large chunks"],
          step_change: "Finish with chili flakes and pickled garnish.",
        },
        adapted: {
          ingredient_changes: ["1/4 tsp mild paprika", "1 tbsp honey or ketchup-style glaze", "finely diced vegetables"],
          step_change: "Keep heat mild, dice vegetables smaller, and serve spicy garnish on the side for adults.",
        },
      },
    ],
  },
  comfort: {
    key: "comfort",
    label: "More comfort",
    requiredActions: [
      "Make the dish cozier and more comforting through sauce, texture, warmth, or seasoning.",
      "Update ingredients and steps to create that result.",
    ],
    editExamples: [
      {
        base: {
          ingredient_changes: ["dry grilled protein", "plain vegetables"],
          step_change: "Grill and serve with vegetables.",
        },
        adapted: {
          ingredient_changes: ["1 cup warm tomato or mushroom sauce", "1/2 cup melty cheese", "1 tbsp butter"],
          step_change: "Nestle the cooked protein into the warm sauce, melt cheese over top, and finish with butter for a richer texture.",
        },
      },
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
      editExamples: [
        {
          base: {
            ingredient_changes: ["base ingredient and quantity stay unchanged"],
            step_change: "base method stays unchanged",
          },
          adapted: {
            ingredient_changes: ["change at least one concrete grocery item or quantity based on the request"],
            step_change: "rewrite at least one method step so the ingredient or quantity change is actually cooked into the recipe",
          },
        },
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
