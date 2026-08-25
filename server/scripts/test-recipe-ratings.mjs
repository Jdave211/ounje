import assert from "node:assert/strict";
import {
  calculateBayesianRecipeRating,
  normalizeRecipeRating,
  scoreRecipeCommunityRating,
} from "../lib/recipe-ratings.js";

assert.equal(normalizeRecipeRating(1), 1);
assert.equal(normalizeRecipeRating("5"), 5);
assert.equal(normalizeRecipeRating(0), null);
assert.equal(normalizeRecipeRating(4.5), null);
assert.equal(normalizeRecipeRating("bad"), null);

assert.equal(calculateBayesianRecipeRating(null, 0), 3.5);
assert.ok(Math.abs(calculateBayesianRecipeRating(5, 1, { priorMean: 4.2 }) - (38.6 / 9)) < 0.0001);
assert.ok(calculateBayesianRecipeRating(4.8, 200, { priorMean: 4.2 }) > 4.77);
assert.ok(calculateBayesianRecipeRating(3.5, 100, { priorMean: 4.2 }) < 3.56);

assert.ok(scoreRecipeCommunityRating({ cold_start_rating: 4.6, bayesian_rating: 4.6, rating_count: 0 }) > 0);
assert.ok(scoreRecipeCommunityRating({ cold_start_rating: 3.2, bayesian_rating: 3.2, rating_count: 0 }) < 0);
assert.ok(
  scoreRecipeCommunityRating({ cold_start_rating: 4.6, bayesian_rating: 4.6, rating_count: 20 })
    > scoreRecipeCommunityRating({ cold_start_rating: 4.6, bayesian_rating: 4.6, rating_count: 0 })
);
assert.ok(scoreRecipeCommunityRating({ average_rating: 4.8, rating_count: 200 }) > 0);
assert.ok(scoreRecipeCommunityRating({ average_rating: 2.0, rating_count: 200 }) < 0);
assert.ok(
  scoreRecipeCommunityRating({ cold_start_rating: 4.2, bayesian_rating: 4.29, average_rating: 5, rating_count: 1 })
    < scoreRecipeCommunityRating({ cold_start_rating: 4.2, bayesian_rating: 4.78, average_rating: 4.8, rating_count: 200 })
);

console.log("recipe ratings: all assertions passed");
