import OpenAI from "openai";
import "dotenv/config";
import { normalizeRecipeDetail } from "./recipe-detail-utils.js";

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const INTENT_MODEL = process.env.INSTACART_QUERY_MODEL ?? "gpt-4.1-mini";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";

const openai = OPENAI_API_KEY ? new OpenAI({ apiKey: OPENAI_API_KEY }) : null;

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

  return {
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

  if (combined.includes("shredded chicken breast")
    || combined.includes("cooked chicken breast")
    || combined.includes("chicken breast")) {
    return [component("chicken breast")];
  }

  if (combined.includes("shredded chicken")
    || combined.includes("cooked chicken")
    || combined.includes("pulled chicken")) {
    return [component("chicken breast")];
  }

  if (combined.includes("cooked jasmine rice") || combined.includes("jasmine rice")) {
    return [component("jasmine rice")];
  }

  if (combined.includes("cooked rice")) {
    return [component("rice")];
  }

  if (combined.includes("crispy romaine")) {
    return [component("romaine lettuce")];
  }

  return [base];
}

function inferDeterministicIntent(normalizedQuery, itemContext) {
  const role = (() => {
    if (["chicken", "shrimp", "salmon", "steak", "eggs"].includes(normalizedQuery)) return "protein";
    if (["cilantro", "green onions", "green onion", "onion"].includes(normalizedQuery)) return "fresh garnish";
    if (["cotija cheese", "shredded cheese", "yogurt"].includes(normalizedQuery)) return "dairy";
    if (["rice paper", "rice paper wrappers"].includes(normalizedQuery)) return "wrapper";
    if (["greens", "romaine lettuce", "crispy romaine"].includes(normalizedQuery)) return "salad base";
    if (["seasoning", "black pepper", "cinnamon", "baking powder"].includes(normalizedQuery)) return "pantry";
    if (["skewers", "bamboo skewers"].includes(normalizedQuery)) return "cooking tool";
    if (["bang bang sauce", "cilantro lime caesar dressing", "ranch dressing"].includes(normalizedQuery)) return "sauce";
    return "ingredient";
  })();

  const preferredForms = [];
  const avoidForms = [];
  const requiredDescriptors = [];
  const alternateQueries = [];
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
      resolvedQuery = "fresh cilantro";
      break;
    case "green onions":
    case "green onion":
    case "onion":
      preferredForms.push("green onions bunch", "scallions", "green onions");
      avoidForms.push("yellow onions", "white onions", "fried onions");
      requiredDescriptors.push("green");
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
      break;
    case "jalapeños":
    case "jalape os":
      preferredForms.push("fresh jalapeños", "jalapeño peppers");
      avoidForms.push("pickled jalapeños", "jalapeño chips", "chili sauce");
      requiredDescriptors.push("fresh");
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

  const isOptional = /optional/.test(normalizedQuery)
    || itemContext.sourceIngredientNames.some((name) => /optional/i.test(name));

  const exactness = (() => {
    if (["rice paper", "rice paper wrappers", "bang bang sauce", "cilantro lime caesar dressing"].includes(normalizedQuery)) return "strict_exact";
    if (isOptional) return "optional";
    if (["cotija cheese", "shredded cheese", "greens", "romaine lettuce", "jalapeños", "jalape os"].includes(normalizedQuery)) return "flexible_substitute";
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
    exactness,
    isPantryStaple,
    isOptional,
    packageRule,
    storeFitWeight,
    preferredForms: uniqueStrings(preferredForms, 8),
    avoidForms: uniqueStrings(avoidForms, 10),
    requiredDescriptors: uniqueStrings(requiredDescriptors, 6),
    alternateQueries: uniqueStrings(alternateQueries, 6),
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

  return {
    originalName: originalItem?.name ?? baseQuery,
    normalizedQuery: baseQuery,
    sourceIngredientNames,
    recipeTitles,
    cuisines,
    tags,
    recipeSignals,
    neighborIngredients,
    matchingRecipeIngredients,
    matchingStepSnippets,
    ...deterministic,
  };
}

function shouldResolveWithLLM(context) {
  return (
    AMBIGUOUS_QUERY_SET.has(context.normalizedQuery) ||
    context.preferredForms.length > 0 ||
    context.matchingStepSnippets.length > 0 ||
    context.sourceIngredientNames.some((name) => /additional|optional|or |\(|\)|-|crispy|creamy|tangy|salad|sauce/i.test(name))
  );
}

function buildIntentPrompt(items) {
  return [
    "You convert recipe ingredients into standardized shopping specs for Instacart.",
    "The goal is to preserve what the recipe actually needs before any store selection happens.",
    "Read the recipe titles, matched ingredient rows, neighboring ingredients, and step snippets carefully.",
    "Output a grocery-shopping spec for each item.",
    "",
    "Rules:",
    "- Standardize the ingredient into the exact or closest store-search-friendly form that still matches the recipe.",
    "- Use step context to infer form: raw vs cooked, shredded vs block, romaine vs mixed greens, granulated sugar vs icing sugar, fresh herb vs dried spice, wrappers vs noodles.",
    "- Do not invent a different ingredient family.",
    "- If the recipe text implies a specific descriptor, keep it in requiredDescriptors.",
    "- Mark pantry staples honestly. Salt, pepper, common oils, and common seasoning jars should usually be pantry staples unless the recipe makes them the hero.",
    "- Mark optional items honestly. Optional toppings or garnish-only extras can be optional.",
    "- packageRule should only be set when the shopping unit is obvious: carton eggs, bag rice/flour/sugar/chips, jar seasoning, bottle sauce/dressing/juice, pack cheese, tub yogurt, bunch herbs, head romaine/lettuce, carton broth/stock/milk.",
    "- storeFitWeight should stay between 0.25 and 1.85 and only reflect how strongly this item should influence store selection.",
    "- preferredForms should be concrete retail-style product forms.",
    "- avoidForms should contain product forms that would break the recipe.",
    "- alternateQueries should be additional search phrases worth trying if the main query fails.",
    "- exactness must be one of: strict_exact, preferred_exact, flexible_substitute, optional.",
    "- strict_exact means reject loose substitutions.",
    "- preferred_exact means exact is preferred but a close substitute may still be reasonable later if policy allows.",
    "- flexible_substitute means a close culinary substitute is acceptable.",
    "- optional means the item can be skipped or loosely substituted.",
    "- Return JSON only.",
    "",
    JSON.stringify(items, null, 2),
  ].join("\n");
}

async function resolveAmbiguousIntents(items) {
  if (!openai || items.length === 0) return new Map();

  const response = await openai.chat.completions.create({
    model: INTENT_MODEL,
    temperature: 0,
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
                  substitutionPolicy: { type: "string" },
                  isPantryStaple: { type: "boolean" },
                  isOptional: { type: "boolean" },
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
                  "substitutionPolicy",
                  "isPantryStaple",
                  "isOptional",
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
      deterministicSubstitutionPolicy: context.substitutionPolicy,
      deterministicIsPantryStaple: context.isPantryStaple,
      deterministicIsOptional: context.isOptional,
      deterministicPackageRule: context.packageRule,
      deterministicStoreFitWeight: context.storeFitWeight,
    }));

  let resolvedByIndex = new Map();
  try {
    resolvedByIndex = await resolveAmbiguousIntents(ambiguous);
  } catch {}

  return baseEntries.map((entry, index) => {
    const context = contexts[index];
    const resolved = resolvedByIndex.get(index);
    const query = normalizeText(resolved?.query || context.resolvedQuery || entry.query || originalItems[index]?.name);
    const exactness = String(resolved?.exactness || context.exactness || "preferred_exact").trim().toLowerCase();
    const substitutionPolicy = String(
      resolved?.substitutionPolicy
        || context.substitutionPolicy
        || (exactness === "flexible_substitute" ? "flexible" : exactness === "optional" ? "optional" : "strict")
    ).trim().toLowerCase();
    const preferredForms = uniqueStrings([query, ...(resolved?.preferredForms ?? []), ...context.preferredForms], 10);
    const avoidForms = uniqueStrings([...(resolved?.avoidForms ?? []), ...context.avoidForms], 12);
    const alternateQueries = uniqueStrings([...(resolved?.alternateQueries ?? []), ...context.alternateQueries], 8);
    const requiredDescriptors = uniqueStrings([...(resolved?.requiredDescriptors ?? []), ...context.requiredDescriptors], 8);
    const canonicalName = String(resolved?.canonicalName || query || context.normalizedQuery || originalItems[index]?.name || "").trim();
    const role = String(resolved?.role || context.role || "ingredient").trim();
    const isPantryStaple = Boolean(resolved?.isPantryStaple ?? context.isPantryStaple ?? false);
    const isOptional = Boolean(resolved?.isOptional ?? context.isOptional ?? exactness === "optional");
    const packageRule = resolved?.packageRule ?? context.packageRule ?? null;
    const storeFitWeight = Number(resolved?.storeFitWeight ?? context.storeFitWeight ?? 1);

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
        substitutionPolicy,
        isPantryStaple,
        isOptional,
        packageRule,
        storeFitWeight,
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
      },
    };
  });
}

export async function buildShoppingSpecEntries({ originalItems, plan = null }) {
  const expandedItems = (originalItems ?? []).flatMap((item) => deconstructCompositeItem(item));
  const resolvedItems = await resolveShoppingIntents({
    originalItems: expandedItems,
    plan,
  });

  const collapsedByKey = new Map();

  for (let index = 0; index < resolvedItems.length; index += 1) {
    const resolved = resolvedItems[index];
    const original = expandedItems[index] ?? {};
    const shoppingContext = resolved.shoppingContext ?? {};
    const canonicalName = String(shoppingContext.canonicalName || resolved.canonicalName || resolved.query || original.name || "").trim();
    const key = normalizedKey(canonicalName);

    const nextEntry = {
      name: resolved.query,
      originalName: original.originalName ?? original.name ?? resolved.query,
      canonicalName,
      amount: Math.max(0, Number(original.amount ?? 1)),
      unit: original.unit || "item",
      estimatedPrice: Number(original.estimatedPrice ?? 0),
      sourceIngredients: Array.isArray(original.sourceIngredients) ? original.sourceIngredients : [],
      sourceRecipes: uniqueStrings([
        ...(Array.isArray(original.sourceRecipes) ? original.sourceRecipes : []),
        ...(shoppingContext.recipeTitles ?? []),
      ], 10),
      shoppingContext,
      confidence: resolved.confidence,
      reason: resolved.reason,
    };

    if (collapsedByKey.has(key)) {
      const existing = collapsedByKey.get(key);
      existing.amount += nextEntry.amount;
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
      existing.shoppingContext = {
        ...existing.shoppingContext,
        sourceIngredientNames: uniqueStrings([
          ...(existing.shoppingContext?.sourceIngredientNames ?? []),
          ...(shoppingContext.sourceIngredientNames ?? []),
        ], 14),
        recipeTitles: uniqueStrings([
          ...(existing.shoppingContext?.recipeTitles ?? []),
          ...(shoppingContext.recipeTitles ?? []),
        ], 10),
      };
      existing.confidence = Math.max(existing.confidence ?? 0, nextEntry.confidence ?? 0);
      collapsedByKey.set(key, existing);
    } else {
      collapsedByKey.set(key, nextEntry);
    }
  }

  return [...collapsedByKey.values()].map((entry) => {
    const packageRule = entry.shoppingContext?.packageRule ?? null;
    const purchaseAmount = packageRule?.packageSize
      ? Math.max(1, Math.ceil(entry.amount / packageRule.packageSize))
      : Math.max(1, Math.ceil(entry.amount));

    return {
      ...entry,
      amount: purchaseAmount,
      unit: packageRule?.packageUnit ?? entry.unit ?? "item",
    };
  });
}
