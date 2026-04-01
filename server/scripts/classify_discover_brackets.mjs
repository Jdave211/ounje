import fs from "fs";
import path from "path";
import dotenv from "dotenv";
import OpenAI from "openai";
import {
  getClassifiableDiscoverBracketKeys,
  normalizeDiscoverBracketKey,
  sanitizeDiscoverBrackets,
} from "../lib/discover-brackets.js";

dotenv.config({ path: path.resolve(path.dirname(new URL(import.meta.url).pathname), "../.env") });

const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";

if (!OPENAI_API_KEY) {
  console.error("Missing OPENAI_API_KEY");
  process.exit(1);
}

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_ANON_KEY");
  process.exit(1);
}

const openai = new OpenAI({ apiKey: OPENAI_API_KEY });
const CACHE_PATH = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../data/discover/discover_brackets.json"
);
const BATCH_SIZE = 20;
const PAGE_SIZE = 200;
const MODEL = "gpt-4.1-mini";

const CLASSIFIABLE_KEYS = getClassifiableDiscoverBracketKeys().filter((key) => key !== "under500");

const SYSTEM_PROMPT = `You classify recipe cards for Ounje Discover.

Assign each recipe one or more discover bracket keys from this exact allowed list:
${CLASSIFIABLE_KEYS.join(", ")}

Rules:
- Every recipe must receive at least one bracket.
- Multiple brackets are allowed.
- Breakfast should mean real breakfast/brunch, not desserts that happen to be eaten in the morning.
- Dessert is for sweet treats.
- Drinks is only for beverages and sip-style recipes.
- Fish is broad fish/seafood, while salmon is only recipes where salmon is a clear primary anchor.
- Vegetarian and vegan should only be used when the recipe truly fits.
- Beginner is for recipes that are straightforward / approachable.
- Use the recipe's title, description, ingredients, recipe_type, dietary tags, cuisine tags, occasion tags, calories, and cook time.
- Do not invent new brackets.
- Return only valid JSON.`;

const RESPONSE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    recipes: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          id: { type: "string" },
          brackets: {
            type: "array",
            minItems: 1,
            items: {
              type: "string",
              enum: CLASSIFIABLE_KEYS,
            },
          },
        },
        required: ["id", "brackets"],
      },
    },
  },
  required: ["recipes"],
};

const HEADERS = {
  apikey: SUPABASE_ANON_KEY,
  Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
  "Content-Type": "application/json",
};

function ensureCacheDir() {
  fs.mkdirSync(path.dirname(CACHE_PATH), { recursive: true });
}

async function fetchRecipesBatch(offset, limit) {
  const select = [
    "id",
    "title",
    "description",
    "recipe_type",
    "category",
    "dietary_tags",
    "cuisine_tags",
    "occasion_tags",
    "ingredients_text",
    "instructions_text",
    "calories_kcal",
    "cook_time_minutes",
    "skill_level",
  ].join(",");

  const url = `${SUPABASE_URL}/rest/v1/recipes?select=${encodeURIComponent(select)}&order=id.asc&limit=${limit}&offset=${offset}`;
  const response = await fetch(url, { headers: HEADERS });
  const data = await response.json().catch(() => []);
  if (!response.ok) {
    throw new Error(data?.message ?? data?.error ?? "Failed to fetch recipes");
  }
  return Array.isArray(data) ? data : [];
}

function deterministicFallback(recipe) {
  const text = [
    recipe.title,
    recipe.description,
    recipe.recipe_type,
    recipe.category,
    ...(recipe.dietary_tags ?? []),
    ...(recipe.cuisine_tags ?? []),
    ...(recipe.occasion_tags ?? []),
    recipe.ingredients_text,
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  const brackets = new Set();
  const recipeType = String(recipe.recipe_type ?? "").toLowerCase();
  const skill = String(recipe.skill_level ?? "").toLowerCase();
  const calories = Number(recipe.calories_kcal ?? 0);
  const cookMinutes = Number(recipe.cook_time_minutes ?? 0);

  if (recipeType === "breakfast" || /\b(brunch|omelet|oat|pancake|waffle|granola|yogurt bowl|breakfast)\b/.test(text)) brackets.add("breakfast");
  if (recipeType === "lunch" || /\b(lunch|sandwich|wrap|bowl)\b/.test(text)) brackets.add("lunch");
  if (recipeType === "dinner" || /\b(dinner|roast|stir-fry|stir fry|traybake|skillet|curry|chili)\b/.test(text)) brackets.add("dinner");
  if (recipeType === "dessert" || /\b(cookie|cake|dessert|brownie|pudding|ice cream|pie|cheesecake|bar|tart)\b/.test(text)) brackets.add("dessert");
  if (/\b(smoothie|juice|latte|coffee|tea|lemonade|spritz|cocktail|mocktail|soda|drink)\b/.test(text)) brackets.add("drinks");
  if (/\bvegetarian\b/.test(text)) brackets.add("vegetarian");
  if (/\bvegan\b/.test(text)) brackets.add("vegan");
  if (/\b(pasta|spaghetti|linguine|penne|rigatoni|fusilli|macaroni|noodle)\b/.test(text)) brackets.add("pasta");
  if (/\bchicken\b/.test(text)) brackets.add("chicken");
  if (/\b(steak|beef|sirloin|ribeye|flank)\b/.test(text)) brackets.add("steak");
  if (/\bsalmon\b/.test(text)) {
    brackets.add("salmon");
    brackets.add("fish");
  } else if (/\b(fish|cod|snapper|tilapia|trout|sea bass|halibut|mackerel|tuna|shrimp|prawn|seafood)\b/.test(text)) {
    brackets.add("fish");
  }
  if (/\b(salad|slaw|greens|caesar)\b/.test(text)) brackets.add("salad");
  if (/\b(sandwich|burger|wrap|panini|toastie)\b/.test(text)) brackets.add("sandwich");
  if (/\b(bean|beans|lentil|lentils|chickpea|chickpeas|legume|legumes)\b/.test(text)) brackets.add("beans");
  if (/\b(potato|potatoes|sweet potato|hash brown)\b/.test(text)) brackets.add("potatoes");
  if (/(beginner|easy|simple)/.test(skill) || (cookMinutes > 0 && cookMinutes <= 25)) brackets.add("beginner");
  if (calories > 0 && calories <= 500) brackets.add("under500");

  if (!brackets.size) {
    if (recipeType === "dessert") brackets.add("dessert");
    else if (recipeType === "breakfast") brackets.add("breakfast");
    else if (recipeType === "lunch") brackets.add("lunch");
    else if (recipeType === "dinner") brackets.add("dinner");
    else if (/\bvegetarian\b/.test(text)) brackets.add("vegetarian");
    else brackets.add("dinner");
  }

  return [...brackets].map(normalizeDiscoverBracketKey).filter(Boolean);
}

async function classifyBatch(recipes) {
  const completion = await openai.chat.completions.create({
    model: MODEL,
    temperature: 0.1,
    response_format: {
      type: "json_schema",
      json_schema: {
        name: "discover_bracket_batch",
        strict: true,
        schema: RESPONSE_SCHEMA,
      },
    },
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      {
        role: "user",
        content: JSON.stringify({
          recipes: recipes.map((recipe) => ({
            id: recipe.id,
            title: recipe.title,
            description: recipe.description,
            recipe_type: recipe.recipe_type,
            category: recipe.category,
            dietary_tags: recipe.dietary_tags ?? [],
            cuisine_tags: recipe.cuisine_tags ?? [],
            occasion_tags: recipe.occasion_tags ?? [],
            ingredients_text: recipe.ingredients_text ?? "",
            instructions_text: recipe.instructions_text ?? "",
            calories_kcal: recipe.calories_kcal,
            cook_time_minutes: recipe.cook_time_minutes,
            skill_level: recipe.skill_level,
          })),
        }),
      },
    ],
  });

  const content = completion.choices?.[0]?.message?.content;
  if (!content) throw new Error("No classification content returned");

  const parsed = JSON.parse(content);
  const byId = new Map(
    (parsed.recipes ?? []).map((entry) => [
      String(entry.id),
      [...new Set((entry.brackets ?? []).map(normalizeDiscoverBracketKey).filter(Boolean))],
    ])
  );

  return recipes.map((recipe) => {
    const classified = byId.get(String(recipe.id)) ?? [];
    const merged = sanitizeDiscoverBrackets(
      recipe,
      [...new Set([...classified, ...deterministicFallback(recipe)])]
    );
    return {
      id: String(recipe.id),
      title: recipe.title,
      brackets: [...new Set(merged)].filter((key) => key !== "all"),
    };
  });
}

async function hasDiscoverBracketColumn() {
  const url = `${SUPABASE_URL}/rest/v1/recipes?select=id,discover_brackets&limit=1`;
  const response = await fetch(url, { headers: HEADERS });
  if (response.ok) return true;
  const data = await response.json().catch(() => ({}));
  const message = String(data?.message ?? data?.error ?? "");
  if (message.includes("discover_brackets does not exist")) return false;
  throw new Error(message || "Could not verify discover_brackets column");
}

async function patchDbBrackets(row) {
  const now = new Date().toISOString();
  const payload = {
    discover_brackets: row.brackets,
    discover_brackets_enriched_at: now,
  };
  const url = `${SUPABASE_URL}/rest/v1/recipes?id=eq.${encodeURIComponent(row.id)}`;
  const response = await fetch(url, {
    method: "PATCH",
    headers: HEADERS,
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(data?.message ?? data?.error ?? `Failed to update ${row.id}`);
  }
}

function buildCache(rows) {
  const byRecipeId = {};
  const byBracket = {};

  for (const row of rows) {
    const unique = [...new Set(
      sanitizeDiscoverBrackets(row, row.brackets)
        .map(normalizeDiscoverBracketKey)
        .filter(Boolean)
    )];
    byRecipeId[row.id] = {
      title: row.title,
      brackets: unique,
    };
    for (const bracket of unique) {
      byBracket[bracket] ??= [];
      byBracket[bracket].push(row.id);
    }
  }

  for (const bracket of Object.keys(byBracket)) {
    byBracket[bracket].sort();
  }

  return {
    generated_at: new Date().toISOString(),
    model: MODEL,
    by_recipe_id: byRecipeId,
    by_bracket: byBracket,
  };
}

async function main() {
  ensureCacheDir();

  const recipes = [];
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const page = await fetchRecipesBatch(offset, PAGE_SIZE);
    if (!page.length) break;
    recipes.push(...page);
    console.log(`Fetched ${recipes.length} recipes...`);
    if (page.length < PAGE_SIZE) break;
  }

  const classified = [];
  for (let index = 0; index < recipes.length; index += BATCH_SIZE) {
    const batch = recipes.slice(index, index + BATCH_SIZE);
    const result = await classifyBatch(batch);
    classified.push(...result);
    console.log(`Classified ${classified.length}/${recipes.length} recipes...`);
  }

  const cache = buildCache(classified);
  fs.writeFileSync(CACHE_PATH, JSON.stringify(cache, null, 2));
  console.log(`Wrote cache to ${CACHE_PATH}`);

  if (await hasDiscoverBracketColumn()) {
    for (const row of classified) {
      await patchDbBrackets(row);
    }
    console.log("Patched discover_brackets back into Supabase.");
  } else {
    console.log("discover_brackets column does not exist yet; skipped DB patch.");
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
