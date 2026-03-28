import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CORPUS_PATH = path.resolve(__dirname, '../finetune/recipe_corpus.json');

let cache = null;

function loadCorpus() {
  if (cache) return cache;
  if (!fs.existsSync(CORPUS_PATH)) {
    cache = [];
    return cache;
  }
  cache = JSON.parse(fs.readFileSync(CORPUS_PATH, 'utf8'));
  return cache;
}

export function findRecipeStyleExamples({ recipe = null, profile = null, limit = 3 }) {
  const corpus = loadCorpus();
  if (!corpus.length) return [];

  const targetType = String(recipe?.recipe_type ?? recipe?.recipeType ?? '').toLowerCase();
  const targetCuisine = (recipe?.cuisine_tags ?? recipe?.cuisineTags ?? profile?.preferredCuisines ?? []).map((v) => String(v).toLowerCase());
  const targetDietary = (recipe?.dietary_tags ?? recipe?.dietaryTags ?? profile?.dietaryPatterns ?? []).map((v) => String(v).toLowerCase());

  return corpus
    .map((entry) => {
      let score = 0;
      const recipeType = String(entry.recipe_type ?? '').toLowerCase();
      const cuisines = (entry.cuisine_tags ?? []).map((v) => String(v).toLowerCase());
      const dietary = (entry.dietary_tags ?? []).map((v) => String(v).toLowerCase());
      if (targetType && recipeType === targetType) score += 5;
      score += cuisines.filter((v) => targetCuisine.includes(v)).length * 3;
      score += dietary.filter((v) => targetDietary.includes(v)).length * 2;
      return { entry, score };
    })
    .sort((a, b) => b.score - a.score)
    .filter((row) => row.score > 0)
    .slice(0, limit)
    .map((row) => ({
      title: row.entry.title,
      recipe_type: row.entry.recipe_type,
      cuisine_tags: row.entry.cuisine_tags ?? [],
      dietary_tags: row.entry.dietary_tags ?? [],
      cook_time_text: row.entry.cook_time_text,
      ingredients_text: row.entry.ingredients_text,
      instructions_text: row.entry.instructions_text,
    }));
}
