-- Give unrated catalog recipes a transparent launch score. This is a content
-- quality prior, not a fabricated community review. Real ratings progressively
-- replace its influence through the existing Bayesian aggregate.

ALTER TABLE public.recipes
  ADD COLUMN IF NOT EXISTS cold_start_rating double precision NOT NULL DEFAULT 3.5;

ALTER TABLE public.recipes
  DROP CONSTRAINT IF EXISTS recipes_cold_start_rating_range;

ALTER TABLE public.recipes
  ADD CONSTRAINT recipes_cold_start_rating_range
    CHECK (cold_start_rating BETWEEN 1.0 AND 5.0);

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
      length(trim(COALESCE(r.description, ''))) AS description_length,
      COALESCE(NULLIF(trim(r.discover_card_image_url), ''), NULLIF(trim(r.hero_image_url), '')) IS NOT NULL AS has_image,
      COALESCE(NULLIF(trim(r.author_handle), ''), NULLIF(trim(r.author_name), '')) IS NOT NULL AS has_creator,
      COALESCE(r.cook_time_minutes, 0) > 0 OR NULLIF(trim(COALESCE(r.cook_time_text, '')), '') IS NOT NULL AS has_time,
      NULLIF(trim(COALESCE(r.attached_video_url, '')), '') IS NOT NULL AS has_video,
      NULLIF(trim(COALESCE(r.source, '')), '') IS NOT NULL AS has_source,
      COALESCE(r.calories_kcal, 0) > 0 AS has_nutrition
    FROM public.recipes r
    WHERE r.id = p_recipe_id
  )
  SELECT ROUND(
    LEAST(4.8, GREATEST(3.0,
      3.0
      + CASE WHEN has_image THEN 0.30 ELSE 0 END
      + CASE
          WHEN description_length >= 100 THEN 0.20
          WHEN description_length >= 50 THEN 0.12
          ELSE 0
        END
      + CASE
          WHEN ingredient_count >= 10 THEN 0.50
          WHEN ingredient_count >= 7 THEN 0.42
          WHEN ingredient_count >= 4 THEN 0.27
          WHEN ingredient_count >= 2 THEN 0.12
          ELSE 0
        END
      + CASE
          WHEN step_count >= 8 THEN 0.50
          WHEN step_count >= 5 THEN 0.42
          WHEN step_count >= 3 THEN 0.27
          WHEN step_count >= 2 THEN 0.12
          ELSE 0
        END
      + CASE WHEN has_creator THEN 0.15 ELSE 0 END
      + CASE WHEN has_time THEN 0.10 ELSE 0 END
      + CASE WHEN has_video THEN 0.10 ELSE 0 END
      + CASE WHEN has_source THEN 0.05 ELSE 0 END
      + CASE WHEN has_nutrition THEN 0.10 ELSE 0 END
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

CREATE OR REPLACE FUNCTION private.refresh_recipe_cold_start_rating()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target_recipe_id uuid;
  next_cold_start_rating double precision;
BEGIN
  IF TG_TABLE_NAME = 'recipes' THEN
    target_recipe_id := NEW.id;
  ELSIF TG_OP = 'DELETE' THEN
    target_recipe_id := OLD.recipe_id;
  ELSE
    target_recipe_id := NEW.recipe_id;
  END IF;

  next_cold_start_rating := private.calculate_recipe_cold_start_rating(target_recipe_id);
  IF next_cold_start_rating IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  UPDATE public.recipes
  SET
    cold_start_rating = next_cold_start_rating,
    bayesian_rating = CASE
      WHEN rating_count > 0 AND average_rating IS NOT NULL THEN
        ((rating_count * average_rating) + (8.0 * next_cold_start_rating)) / (rating_count + 8.0)
      ELSE next_cold_start_rating
    END
  WHERE id = target_recipe_id;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.refresh_recipe_cold_start_rating() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS refresh_recipe_cold_start_rating_from_recipe ON public.recipes;
CREATE TRIGGER refresh_recipe_cold_start_rating_from_recipe
  AFTER INSERT OR UPDATE OF title, description, author_name, author_handle, cook_time_text,
    cook_time_minutes, discover_card_image_url, hero_image_url, attached_video_url,
    source, calories_kcal, ingredients_json, steps_json
  ON public.recipes
  FOR EACH ROW
  EXECUTE FUNCTION private.refresh_recipe_cold_start_rating();

DROP TRIGGER IF EXISTS refresh_recipe_cold_start_rating_from_ingredient ON public.recipe_ingredients;
CREATE TRIGGER refresh_recipe_cold_start_rating_from_ingredient
  AFTER INSERT OR UPDATE OR DELETE ON public.recipe_ingredients
  FOR EACH ROW
  EXECUTE FUNCTION private.refresh_recipe_cold_start_rating();

DROP TRIGGER IF EXISTS refresh_recipe_cold_start_rating_from_step ON public.recipe_steps;
CREATE TRIGGER refresh_recipe_cold_start_rating_from_step
  AFTER INSERT OR UPDATE OR DELETE ON public.recipe_steps
  FOR EACH ROW
  EXECUTE FUNCTION private.refresh_recipe_cold_start_rating();

CREATE OR REPLACE FUNCTION private.refresh_recipe_rating_summary()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target_recipe_id uuid;
  total_ratings integer;
  arithmetic_average double precision;
  prior_mean double precision;
  prior_weight constant double precision := 8.0;
BEGIN
  IF TG_OP = 'DELETE' THEN
    target_recipe_id := OLD.recipe_id;
  ELSE
    target_recipe_id := NEW.recipe_id;
  END IF;

  SELECT COUNT(*)::integer, AVG(rating)::double precision
  INTO total_ratings, arithmetic_average
  FROM public.recipe_ratings
  WHERE recipe_id = target_recipe_id;

  SELECT cold_start_rating
  INTO prior_mean
  FROM public.recipes
  WHERE id = target_recipe_id;
  prior_mean := COALESCE(prior_mean, 3.5);

  UPDATE public.recipes
  SET
    rating_count = total_ratings,
    average_rating = CASE WHEN total_ratings > 0 THEN arithmetic_average ELSE NULL END,
    bayesian_rating = CASE
      WHEN total_ratings > 0 THEN
        ((total_ratings * arithmetic_average) + (prior_weight * prior_mean))
          / (total_ratings + prior_weight)
      ELSE prior_mean
    END
  WHERE id = target_recipe_id;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.refresh_recipe_rating_summary() FROM PUBLIC, anon, authenticated;

DROP INDEX IF EXISTS public.idx_recipes_bayesian_rating;
CREATE INDEX idx_recipes_bayesian_rating
  ON public.recipes(bayesian_rating DESC, rating_count DESC);
