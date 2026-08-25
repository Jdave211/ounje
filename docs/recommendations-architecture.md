# Recommendations Architecture

## Discover Product Contract

Discover is Ounje's public recipe network, not a second cookbook. Its catalog contains only:

- Public recipes promoted from TikTok, Instagram, and other supported imports.
- Recipes created and published by Ounje.

Private user imports never enter Discover unless they are deliberately promoted into the shared catalog. Every imported recipe keeps its original creator attribution and source link.

The primary social action is a 1-5 star recipe rating. Each signed-in member can hold one current rating per recipe and can change it later. Cards show the weighted average and rating count; recipe detail is where a member submits or edits a rating.

Ratings measure recipe quality, while saves, plan additions, cooks, and dismissals measure personal relevance. Ranking must use both. A recipe with one five-star rating must not outrank a well-established 4.7-star recipe, so public ordering uses a confidence-adjusted score with a minimum-vote prior rather than the raw average.

## Goal

Give a new Ounje member useful recipes immediately, then improve selections from their saves, plans, grocery actions, and explicit feedback. Recommendations are drawn only from the shared `recipes` catalog, never from another person's private imports.

## Inputs

- Onboarding: dietary restrictions, allergies, cuisine interests, cooking confidence, household size, time and budget preference.
- Recipe metadata: ingredients, cuisines, diets, protein, method, duration, cost, nutrition, source quality, and a semantic embedding.
- Behaviour: impressions, opens, saves, plan additions, cart additions, cooks, dismissals, completion of planned meals, and explicit 1-5 star ratings.
- Context: local time, day of week, current plan gaps, recent history, and seasonality.

## Serving Path

1. Candidate generation: retrieve recipes from profile-matched pools, current plan gaps, recent popular saves, and embedding-nearest recipes. New users receive curated cold-start pools.
2. Hard filters: remove allergens, incompatible diets, duplicates, recipes already saved, and recently dismissed items.
3. Ranking: score candidate fit, likely intent, confidence-adjusted community rating, source quality, freshness, and predicted save/plan value.
4. Diversity: re-rank so a feed does not repeat the same meal type, protein, cuisine, or creator.
5. Explanation: retain the primary reason for each result, such as `Matches your quick dinner preference` or `Completes this week's plan`.

## First Session

The first `For You` feed should contain 12 recipes: a balanced mix of stated preferences, quick dinners, one cook-once meal, a lunch option, and a dessert. It should work before any behavioural data exists and record every impression.

## Feedback Events

`recommendation_impression`, `recipe_opened`, `recipe_saved`, `recipe_added_to_plan`, `recipe_added_to_cart`, `recipe_cooked`, `recipe_rated`, and `recommendation_dismissed` should include the surface, position, candidate source, rank score, and recommendation run ID.

## Future Data Model

- `user_taste_profiles`: explicit onboarding preferences plus derived ingredient/cuisine vectors.
- `recommendation_events`: append-only event log for learning and debugging.
- `recommendation_runs`: snapshot of candidate sources, scores, rank, and explanation for each served feed.
- `recipe_ratings`: one 1-5 rating per user and public recipe, with timestamps for edits and abuse review.
- `recipe_quality_signals`: rating average, rating count, confidence-adjusted rating, source quality, freshness, popularity, and moderation state.

## Rollout

Start with deterministic rules and diversity re-ranking. Add embedding retrieval after the social catalog is quality-gated. Add learned ranking only after enough real interaction data is available, with a small exploration allocation and clear quality guardrails.
