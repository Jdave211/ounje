import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX_PATH = path.resolve(__dirname, '../data/flavorgraph/flavorgraph_index.json');

const STOPWORDS = new Set([
  'and','or','with','of','the','a','an','for','to','in','on','at','style','fresh','ground','extra','virgin',
  'low','reduced','free','plain','large','small','medium','sweetened','unsalted','salted','powdered','dried'
]);

const NOISY_PAIRING_TERMS = new Set([
  'skillet', 'sheet pan', 'stir fry', 'one pan', 'mix', 'coating mix', 'kosher salt',
  'fleur de sel', 'salt', 'pepper', 'seasoning', 'seasoning mix', 'hidden valley original ranch dips mix'
]);

const NOISY_PAIRING_FRAGMENTS = [
  'hidden valley',
  'bouillon',
  'granule',
  'sodium',
  'of chicken soup',
  'soup mix',
];

const TRAIT_HINTS = {
  spicy: ['chili', 'jalapeno', 'serrano', 'cayenne', 'harissa', 'scotch bonnet', 'gochujang', 'hot sauce'],
  protein: ['chicken', 'turkey', 'egg', 'greek yogurt', 'tofu', 'salmon', 'shrimp'],
  creamy: ['cream', 'yogurt', 'coconut milk', 'ricotta'],
  bright: ['lemon', 'lime', 'herbs', 'vinegar'],
};

let cached = null;

function loadIndex() {
  if (cached) return cached;
  if (!fs.existsSync(INDEX_PATH)) {
    cached = { aliases: {}, pairings: {} };
    return cached;
  }
  cached = JSON.parse(fs.readFileSync(INDEX_PATH, 'utf8'));
  return cached;
}

function isUsefulPairingTerm(term = '') {
  const value = normalizeIngredientTerm(term);
  if (!value) return false;
  if (NOISY_PAIRING_TERMS.has(value)) return false;
  if (NOISY_PAIRING_FRAGMENTS.some((fragment) => value.includes(fragment))) return false;
  if (value.includes(' mix')) return false;
  if (value.includes('seasoning')) return false;
  if (value.startsWith('of ')) return false;
  if (value.length < 3) return false;
  return true;
}

export function normalizeIngredientTerm(term = '') {
  let value = String(term).toLowerCase().replace(/_/g, ' ');
  value = value.replace(/[^a-z\s-]/g, ' ');
  value = value.replace(/\s+/g, ' ').trim();
  const parts = value.split(' ').filter((part) => part && !STOPWORDS.has(part));
  value = parts.join(' ').trim();
  if (value.endsWith('es') && value.length > 4) value = value.slice(0, -2);
  else if (value.endsWith('s') && value.length > 3) value = value.slice(0, -1);
  return value;
}

export function extractIngredientSignals(rawText = '') {
  return [...new Set(
    String(rawText)
      .split(/[\n,;]+/)
      .map((item) => normalizeIngredientTerm(item))
      .filter(Boolean)
  )];
}

export function expandFlavorTerms(seedTerms = [], limit = 8) {
  const graph = loadIndex();
  const scored = new Map();

  for (const term of seedTerms.map(normalizeIngredientTerm).filter(Boolean)) {
    const neighbors = graph.pairings?.[term] ?? [];
    for (const neighbor of neighbors.slice(0, 12)) {
      const current = scored.get(neighbor.ingredient) ?? 0;
      scored.set(neighbor.ingredient, current + Number(neighbor.score || 0));
    }
  }

  return [...scored.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, limit)
    .map(([term]) => term);
}

export function scoreFlavorAlignment(recipe = {}, seedTerms = [], avoidTerms = []) {
  const title = String(recipe.title ?? '').toLowerCase();
  const ingredients = String(recipe.ingredients_text ?? recipe.ingredientsText ?? '').toLowerCase();
  const corpus = `${title} ${ingredients}`;

  let score = 0;
  for (const term of seedTerms.map(normalizeIngredientTerm).filter(Boolean)) {
    if (corpus.includes(term)) score += 8;
  }

  const expanded = expandFlavorTerms(seedTerms, 10);
  for (const term of expanded) {
    if (corpus.includes(term)) score += 3;
  }

  for (const term of avoidTerms.map(normalizeIngredientTerm).filter(Boolean)) {
    if (corpus.includes(term)) score -= 10;
  }

  return score;
}

export function suggestAdaptationPairings({ ingredientsText = '', adaptationPrompt = '', profile = null, limit = 10 }) {
  const seeds = [
    ...extractIngredientSignals(ingredientsText),
    ...extractIngredientSignals((profile?.favoriteFoods ?? []).join(', ')),
  ];

  const expansion = expandFlavorTerms(seeds, limit * 2);
  const loweredPrompt = String(adaptationPrompt).toLowerCase();
  const hintTerms = Object.entries(TRAIT_HINTS)
    .filter(([key]) => loweredPrompt.includes(key))
    .flatMap(([, terms]) => terms);

  const ranked = new Map();
  for (const term of [...hintTerms, ...expansion]) {
    const normalized = normalizeIngredientTerm(term);
    if (!normalized) continue;
    ranked.set(normalized, (ranked.get(normalized) ?? 0) + (hintTerms.includes(term) ? 2 : 1));
  }

  return [...ranked.entries()]
    .filter(([term]) => isUsefulPairingTerm(term))
    .sort((a, b) => b[1] - a[1])
    .slice(0, limit)
    .map(([term]) => term);
}
