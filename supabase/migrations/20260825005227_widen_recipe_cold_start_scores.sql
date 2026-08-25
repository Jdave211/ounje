-- Broaden launch-only recipe scores so unrated Discover cards do not cluster
-- around four stars. Real community ratings continue to use the Bayesian blend.

CREATE OR REPLACE FUNCTION private.calculate_recipe_cold_start_rating(p_recipe_id uuid)
RETURNS double precision
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH signals AS (
    SELECT
      r.id,
      lower(COALESCE(r.title, '')) AS normalized_title,
      GREATEST(
        CASE
          WHEN jsonb_typeof(r.ingredients_json) = 'array' THEN jsonb_array_length(r.ingredients_json)
          ELSE 0
        END,
        (SELECT COUNT(*)::integer FROM public.recipe_ingredients ri WHERE ri.recipe_id = r.id)
      ) AS ingredient_count,
      GREATEST(
        CASE
          WHEN jsonb_typeof(r.steps_json) = 'array' THEN jsonb_array_length(r.steps_json)
          ELSE 0
        END,
        (SELECT COUNT(*)::integer FROM public.recipe_steps rs WHERE rs.recipe_id = r.id)
      ) AS step_count,
      (SELECT COUNT(*)::integer FROM public.saved_recipes sr WHERE sr.recipe_id = r.id::text) AS save_count,
      length(trim(COALESCE(r.description, ''))) AS description_length,
      COALESCE(NULLIF(trim(r.discover_card_image_url), ''), NULLIF(trim(r.hero_image_url), '')) IS NOT NULL AS has_image,
      COALESCE(NULLIF(trim(r.author_handle), ''), NULLIF(trim(r.author_name), '')) IS NOT NULL AS has_creator,
      COALESCE(r.cook_time_minutes, 0) AS cook_minutes,
      NULLIF(trim(COALESCE(r.attached_video_url, '')), '') IS NOT NULL AS has_video,
      (
        (
          ('x' || substr(replace(r.id::text, '-', ''), 1, 7))::bit(28)::bigint % 1000
        )::double precision / 999.0 - 0.5
      ) * 1.4 AS audience_variance
    FROM public.recipes r
    WHERE r.id = p_recipe_id
  )
  SELECT ROUND(
    LEAST(4.8, GREATEST(2.4,
      3.15
      + audience_variance
      + CASE
          WHEN normalized_title ~* '(chicken|pasta|rice|bread|potato|salmon|steak|taco|pizza|burger|noodle|cake|cookie|brownie|cheesecake|french toast|pancake|banana|chocolate|shrimp|curry|soup|sandwich|meatball|lasagna)' THEN 0.35
          WHEN normalized_title ~* '(salad|beans|oat|egg|fish|plantain|jollof|stew|garlic|honey|barbecue|bbq|biscuit|waffle|tiramisu)' THEN 0.15
          ELSE -0.05
        END
      + LEAST(0.35, ln(1.0 + save_count) * 0.18)
      + CASE
          WHEN ingredient_count BETWEEN 6 AND 16 THEN 0.12
          WHEN ingredient_count BETWEEN 4 AND 24 THEN 0.04
          WHEN ingredient_count < 3 THEN -0.30
          WHEN ingredient_count > 30 THEN -0.12
          ELSE 0
        END
      + CASE
          WHEN step_count BETWEEN 4 AND 10 THEN 0.12
          WHEN step_count BETWEEN 2 AND 16 THEN 0.04
          WHEN step_count < 2 THEN -0.30
          WHEN step_count > 20 THEN -0.12
          ELSE 0
        END
      + CASE
          WHEN cook_minutes BETWEEN 1 AND 45 THEN 0.10
          WHEN cook_minutes BETWEEN 46 AND 75 THEN 0.04
          WHEN cook_minutes > 150 THEN -0.15
          ELSE 0
        END
      + CASE WHEN has_image THEN 0.06 ELSE 0 END
      + CASE WHEN has_creator THEN 0.03 ELSE 0 END
      + CASE WHEN has_video THEN 0.03 ELSE 0 END
      + CASE WHEN description_length >= 60 THEN 0.04 ELSE 0 END
    ))::numeric,
    2
  )::double precision
  FROM signals;
$$;

REVOKE ALL ON FUNCTION private.calculate_recipe_cold_start_rating(uuid) FROM PUBLIC, anon, authenticated;

UPDATE public.recipes r
SET cold_start_rating = COALESCE(private.calculate_recipe_cold_start_rating(r.id), 3.5);

UPDATE public.recipes
SET bayesian_rating = CASE
  WHEN rating_count > 0 AND average_rating IS NOT NULL THEN
    ((rating_count * average_rating) + (8.0 * cold_start_rating)) / (rating_count + 8.0)
  ELSE cold_start_rating
END;
