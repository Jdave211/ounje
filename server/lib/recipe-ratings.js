export const RECIPE_RATING_PRIOR_MEAN = 3.5;
export const RECIPE_RATING_PRIOR_WEIGHT = 8.0;
export const RECIPE_RATING_RANKING_CENTER = 3.8;

export function normalizeRecipeRating(value) {
  const rating = Number(value);
  if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
    return null;
  }
  return rating;
}

export function calculateBayesianRecipeRating(
  averageRating,
  ratingCount,
  { priorMean = RECIPE_RATING_PRIOR_MEAN, priorWeight = RECIPE_RATING_PRIOR_WEIGHT } = {}
) {
  const count = Math.max(0, Number(ratingCount) || 0);
  const average = Number(averageRating);
  const safePriorMean = Math.min(5, Math.max(1, Number(priorMean) || RECIPE_RATING_PRIOR_MEAN));
  const safePriorWeight = Math.max(0, Number(priorWeight) || 0);

  if (count <= 0 || !Number.isFinite(average)) {
    return safePriorMean;
  }

  return ((count * Math.min(5, Math.max(1, average))) + (safePriorWeight * safePriorMean))
    / (count + safePriorWeight);
}

export function scoreRecipeCommunityRating(recipe = {}) {
  const count = Math.max(0, Number(recipe.rating_count) || 0);
  const coldStartRating = Number.isFinite(Number(recipe.cold_start_rating))
    ? Number(recipe.cold_start_rating)
    : RECIPE_RATING_PRIOR_MEAN;

  const weighted = Number.isFinite(Number(recipe.bayesian_rating))
    ? Number(recipe.bayesian_rating)
    : calculateBayesianRecipeRating(
        recipe.average_rating ?? recipe.rating_average,
        count,
        { priorMean: coldStartRating }
      );

  // Cold-start quality is useful at launch; confidence only grows from real votes.
  const qualitySignal = Math.max(-8, Math.min(8, (weighted - RECIPE_RATING_RANKING_CENTER) * 8));
  const confidenceSignal = Math.min(4, Math.log1p(count) * 1.2);
  const qualityWeight = count > 0
    ? Math.min(1, 0.35 + Math.log1p(count) / 4)
    : 0.25;
  return qualitySignal * qualityWeight + confidenceSignal;
}
