-- Community ratings for public catalog recipes. Personal imports remain private
-- and cannot be rated because recipe_id references public.recipes.

ALTER TABLE public.recipes
  ADD COLUMN IF NOT EXISTS average_rating double precision,
  ADD COLUMN IF NOT EXISTS rating_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS bayesian_rating double precision NOT NULL DEFAULT 4.0;

ALTER TABLE public.recipes
  DROP CONSTRAINT IF EXISTS recipes_average_rating_range,
  DROP CONSTRAINT IF EXISTS recipes_rating_count_nonnegative,
  DROP CONSTRAINT IF EXISTS recipes_bayesian_rating_range;

ALTER TABLE public.recipes
  ADD CONSTRAINT recipes_average_rating_range
    CHECK (average_rating IS NULL OR average_rating BETWEEN 1.0 AND 5.0),
  ADD CONSTRAINT recipes_rating_count_nonnegative
    CHECK (rating_count >= 0),
  ADD CONSTRAINT recipes_bayesian_rating_range
    CHECK (bayesian_rating BETWEEN 1.0 AND 5.0);

CREATE TABLE IF NOT EXISTS public.recipe_ratings (
  recipe_id uuid NOT NULL REFERENCES public.recipes(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (recipe_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_recipe_ratings_user_id
  ON public.recipe_ratings(user_id);

CREATE INDEX IF NOT EXISTS idx_recipes_bayesian_rating
  ON public.recipes(bayesian_rating DESC, rating_count DESC)
  WHERE rating_count > 0;

ALTER TABLE public.recipe_ratings ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.recipe_ratings FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.recipe_ratings TO authenticated;

DROP POLICY IF EXISTS "recipe_ratings_select_own" ON public.recipe_ratings;
CREATE POLICY "recipe_ratings_select_own"
  ON public.recipe_ratings
  FOR SELECT
  TO authenticated
  USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "recipe_ratings_insert_own" ON public.recipe_ratings;
CREATE POLICY "recipe_ratings_insert_own"
  ON public.recipe_ratings
  FOR INSERT
  TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "recipe_ratings_update_own" ON public.recipe_ratings;
CREATE POLICY "recipe_ratings_update_own"
  ON public.recipe_ratings
  FOR UPDATE
  TO authenticated
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "recipe_ratings_delete_own" ON public.recipe_ratings;
CREATE POLICY "recipe_ratings_delete_own"
  ON public.recipe_ratings
  FOR DELETE
  TO authenticated
  USING ((SELECT auth.uid()) = user_id);

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.set_recipe_rating_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := timezone('utc', now());
  RETURN NEW;
END;
$$;

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
  prior_mean constant double precision := 4.0;
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

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.set_recipe_rating_updated_at() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.refresh_recipe_rating_summary() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS set_recipe_rating_updated_at ON public.recipe_ratings;
CREATE TRIGGER set_recipe_rating_updated_at
  BEFORE UPDATE ON public.recipe_ratings
  FOR EACH ROW
  EXECUTE FUNCTION private.set_recipe_rating_updated_at();

DROP TRIGGER IF EXISTS refresh_recipe_rating_summary ON public.recipe_ratings;
CREATE TRIGGER refresh_recipe_rating_summary
  AFTER INSERT OR UPDATE OR DELETE ON public.recipe_ratings
  FOR EACH ROW
  EXECUTE FUNCTION private.refresh_recipe_rating_summary();
