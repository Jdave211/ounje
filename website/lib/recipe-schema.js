export class RecipeSnapshotError extends Error {
  constructor(message) {
    super(message);
    this.name = "RecipeSnapshotError";
  }
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function text(value) {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function positiveNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function firstText(values) {
  return values.map(text).find(Boolean) ?? "";
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

export function safeHTTPURL(value) {
  const raw = text(value);
  if (!raw) return null;
  try {
    const url = new URL(raw.replaceAll(" ", "%20"));
    return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function isDirectVideoURL(value) {
  try {
    return [".mp4", ".m4v", ".mov", ".m3u8"].some((extension) => new URL(value).pathname.toLowerCase().endsWith(extension));
  } catch {
    return false;
  }
}

function isJulienneURL(value) {
  try {
    const host = new URL(value).hostname.toLowerCase();
    return host === "withjulienne.com" || host.endsWith(".withjulienne.com");
  } catch {
    return false;
  }
}

function isTikTokURL(value) {
  try {
    const host = new URL(value).hostname.toLowerCase();
    return host === "tiktok.com" || host.endsWith(".tiktok.com");
  } catch {
    return false;
  }
}

function isVideoSourceURL(value) {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    const path = url.pathname.toLowerCase();
    const isHost = (domain) => host === domain || host.endsWith(`.${domain}`);

    return isTikTokURL(value)
      || isHost("youtube.com")
      || host === "youtu.be"
      || isHost("vimeo.com")
      || host === "fb.watch"
      || ((isHost("instagram.com") || isHost("facebook.com"))
        && ["/reel/", "/reels/", "/watch/"].some((segment) => path.includes(segment)));
  } catch {
    return false;
  }
}

function isVideoSourcePlatform(value) {
  const platform = text(value).toLowerCase();
  return platform === "video"
    || ["tiktok", "youtube", "vimeo"].some((name) => platform.includes(name));
}

function displayableCreator(value) {
  const raw = text(value).replace(/^@+/, "").trim();
  if (!raw) return null;
  const compact = raw.replace(/[^A-Za-z0-9]/g, "");
  const lowered = raw.toLowerCase();
  if (/^\d{8,}$/.test(compact)) return null;
  if (lowered === "source pending" || lowered === "ounje source") return null;
  return `@${raw}`;
}

function collectProvenanceURLs(provenance) {
  if (!isRecord(provenance)) return [];
  const nestedSources = [
    provenance.original_social_source,
    provenance.evidence_bundle?.original_social_source,
    provenance.evidence_bundle,
    provenance,
  ].filter(isRecord);
  return unique(
    nestedSources.flatMap((source) => [source.url, source.canonical_url, source.source_url]).map(safeHTTPURL)
  );
}

function originalSourceURL(detail, card) {
  const candidates = unique([
    ...collectProvenanceURLs(detail.source_provenance_json),
    safeHTTPURL(detail.original_recipe_url),
    safeHTTPURL(detail.recipe_url),
    safeHTTPURL(card.recipe_url),
  ]);
  return candidates.find((candidate) => !isDirectVideoURL(candidate) && !isJulienneURL(candidate)) ?? null;
}

function formatQuantity(ingredient) {
  const explicit = text(ingredient.quantity_text);
  if (explicit) return explicit;
  const quantity = positiveNumber(ingredient.quantity);
  const unit = text(ingredient.unit);
  if (quantity === null) return unit;
  const amount = Number.isInteger(quantity) ? String(quantity) : String(Math.round(quantity * 100) / 100);
  return `${amount}${unit ? ` ${unit}` : ""}`;
}

function normalizeIngredient(value, index) {
  if (!isRecord(value)) {
    throw new RecipeSnapshotError(`Ingredient ${index + 1} is not an object.`);
  }
  const name = firstText([value.display_name, value.name]);
  if (!name) {
    throw new RecipeSnapshotError(`Ingredient ${index + 1} has no name.`);
  }
  return {
    id: firstText([value.id, value.ingredient_id]) || `ingredient-${index + 1}`,
    name,
    quantity: formatQuantity(value),
    imageURL: safeHTTPURL(value.image_url),
  };
}

function normalizeStep(value, index) {
  if (!isRecord(value)) {
    throw new RecipeSnapshotError(`Step ${index + 1} is not an object.`);
  }
  const instruction = text(value.text);
  if (!instruction) {
    throw new RecipeSnapshotError(`Step ${index + 1} has no instruction.`);
  }
  const ingredientRefs = Array.isArray(value.ingredient_refs)
    ? value.ingredient_refs.map(text).filter(Boolean)
    : Array.isArray(value.ingredients)
      ? value.ingredients.map((ingredient) => firstText([ingredient?.display_name, ingredient?.name])).filter(Boolean)
      : [];
  return {
    number: Math.max(1, Math.round(positiveNumber(value.number) ?? index + 1)),
    instruction,
    tip: text(value.tip_text),
    ingredientRefs: unique(ingredientRefs),
  };
}

function metricNumber(primary, fallback, suffix) {
  const numeric = positiveNumber(primary);
  if (numeric !== null) return `${Math.round(numeric)}${suffix}`;
  return text(fallback) || "—";
}

function formatDuration(minutes) {
  const value = Math.round(positiveNumber(minutes) ?? 0);
  if (!value) return "";
  const hours = Math.floor(value / 60);
  const remainder = value % 60;
  if (hours && remainder) return `${hours} hr ${remainder} min`;
  if (hours) return `${hours} hr`;
  return `${remainder} min`;
}

function normalizedSource(detail, creator) {
  if (creator) return creator;
  const source = firstText([detail.source_platform, detail.source]);
  if (!source) return "—";
  return source.toLowerCase() === "withjulienne" ? "Julienne" : source;
}

function normalizeSnapshotInput(snapshotJSON) {
  if (typeof snapshotJSON === "string") {
    try {
      return JSON.parse(snapshotJSON);
    } catch {
      throw new RecipeSnapshotError("Snapshot JSON cannot be parsed.");
    }
  }
  return snapshotJSON;
}

export function parseRecipeSnapshot(snapshotJSON) {
  const snapshot = normalizeSnapshotInput(snapshotJSON);
  if (!isRecord(snapshot)) throw new RecipeSnapshotError("Snapshot is not an object.");

  const detail = isRecord(snapshot.recipe_detail) ? snapshot.recipe_detail : null;
  const card = isRecord(snapshot.recipe_card) ? snapshot.recipe_card : {};
  if (!detail) throw new RecipeSnapshotError("Snapshot has no recipe detail.");
  if (!Array.isArray(detail.ingredients) || !Array.isArray(detail.steps)) {
    throw new RecipeSnapshotError("Snapshot ingredient or step lists are malformed.");
  }

  const title = firstText([detail.title, card.title]);
  if (!title) throw new RecipeSnapshotError("Snapshot has no recipe title.");

  const ingredients = detail.ingredients.map(normalizeIngredient);
  const steps = detail.steps.map(normalizeStep);
  if (!ingredients.length || !steps.length) {
    throw new RecipeSnapshotError("Snapshot does not contain a complete recipe.");
  }

  const creator = [detail.author_handle, detail.author_name, card.author_handle, card.author_name]
    .map(displayableCreator)
    .find(Boolean) ?? "@ounje";
  const servings = Math.round(
    positiveNumber(detail.servings_count)
      ?? positiveNumber(text(detail.servings_text).match(/^\d+/)?.[0])
      ?? 4
  );
  const cookMinutes = (positiveNumber(detail.cook_time_minutes) ?? 0) + (positiveNumber(detail.prep_time_minutes) ?? 0);
  const cookTime = text(detail.cook_time_text) || formatDuration(cookMinutes) || "—";
  const cuisine = Array.isArray(detail.cuisine_tags)
    ? detail.cuisine_tags.map(text).find(Boolean)
    : "";
  const source = normalizedSource(detail, creator);

  const metrics = [
    { label: "Cooktime", value: cookTime },
    { label: "Serving", value: String(servings) },
    { label: "Calories", value: metricNumber(detail.calories_kcal, detail.est_calories_text, " kcal") },
    { label: "Protein", value: metricNumber(detail.protein_g, detail.protein_text, "g") },
    { label: "Carbs", value: metricNumber(detail.carbs_g, detail.carbs_text, "g") },
    { label: "Fats", value: metricNumber(detail.fat_g, detail.fats_text, "g") },
    { label: "Type", value: firstText([detail.recipe_type, detail.category, detail.subcategory]) || "—" },
    { label: "Cuisine", value: cuisine || firstText([detail.category, detail.subcategory]) || "—" },
    { label: "Source", value: source },
  ];

  const heroURL = [
    detail.hero_image_url,
    detail.discover_card_image_url,
    detail.image_url,
    card.hero_image_url,
    card.discover_card_image_url,
    card.image_url,
  ].map(safeHTTPURL).find(Boolean) ?? null;
  const sourceURL = originalSourceURL(detail, card);
  const recipeID = firstText([detail.id, card.id]);
  const sourcePlatform = firstText([detail.source_platform, card.source_platform]).toLowerCase();
  const originalSourceKind = isVideoSourcePlatform(sourcePlatform) || isVideoSourceURL(sourceURL)
    ? "video"
    : "link";
  const usesSquircleHero = recipeID.startsWith("uir_")
    || originalSourceKind === "video";

  return {
    title,
    description: firstText([detail.description, card.description]),
    creator,
    originalSourceURL: sourceURL,
    originalSourceKind,
    heroURL,
    usesSquircleHero,
    imageCaption: text(detail.image_caption),
    servings,
    prepTimeMinutes: positiveNumber(detail.prep_time_minutes),
    cookTimeMinutes: positiveNumber(detail.cook_time_minutes),
    caloriesKcal: positiveNumber(detail.calories_kcal),
    proteinG: positiveNumber(detail.protein_g),
    carbsG: positiveNumber(detail.carbs_g),
    fatG: positiveNumber(detail.fat_g),
    publishedDate: text(card.published_date),
    ingredients,
    steps,
    metrics,
  };
}

function isoDuration(minutes) {
  const value = Math.round(positiveNumber(minutes) ?? 0);
  return value > 0 ? `PT${value}M` : undefined;
}

export function buildRecipeJSONLD(recipe, canonicalURL) {
  const nutrition = recipe.caloriesKcal || recipe.proteinG || recipe.carbsG || recipe.fatG
    ? {
        "@type": "NutritionInformation",
        calories: recipe.caloriesKcal ? `${Math.round(recipe.caloriesKcal)} calories` : undefined,
        proteinContent: recipe.proteinG ? `${Math.round(recipe.proteinG)} g` : undefined,
        carbohydrateContent: recipe.carbsG ? `${Math.round(recipe.carbsG)} g` : undefined,
        fatContent: recipe.fatG ? `${Math.round(recipe.fatG)} g` : undefined,
      }
    : undefined;

  return {
    "@context": "https://schema.org",
    "@type": "Recipe",
    name: recipe.title,
    description: recipe.description || undefined,
    image: recipe.heroURL ? [recipe.heroURL] : undefined,
    author: {
      "@type": "Person",
      name: recipe.creator.replace(/^@/, ""),
    },
    datePublished: recipe.publishedDate || undefined,
    prepTime: isoDuration(recipe.prepTimeMinutes),
    cookTime: isoDuration(recipe.cookTimeMinutes),
    recipeYield: `${recipe.servings} servings`,
    nutrition,
    recipeIngredient: recipe.ingredients.map((ingredient) => `${ingredient.quantity ? `${ingredient.quantity} ` : ""}${ingredient.name}`),
    recipeInstructions: recipe.steps.map((step) => ({
      "@type": "HowToStep",
      position: step.number,
      text: step.instruction,
    })),
    mainEntityOfPage: canonicalURL,
  };
}

export function serializeJSONForHTML(value) {
  return JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll("\u2028", "\\u2028")
    .replaceAll("\u2029", "\\u2029");
}

export function ingredientMonogram(name) {
  const words = text(name).split(/[^A-Za-z0-9]+/).filter((word) => word.length > 1);
  if (words.length >= 2) return `${words[0][0]}${words[1][0]}`.toUpperCase();
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
  return "OU";
}
