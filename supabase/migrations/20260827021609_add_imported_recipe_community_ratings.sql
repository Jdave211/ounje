-- Imported recipes use text IDs and cannot participate in recipe_ratings,
-- whose recipe_id intentionally references the UUID-based public catalog.
-- Keep the user rating private and expose only an owner-readable aggregate.

CREATE TABLE IF NOT EXISTS public.user_import_recipe_ratings (
  recipe_id text NOT NULL REFERENCES public.user_import_recipes(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (recipe_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_import_recipe_ratings_user_id
  ON public.user_import_recipe_ratings(user_id);

CREATE TABLE IF NOT EXISTS public.user_import_recipe_rating_summaries (
  recipe_id text PRIMARY KEY REFERENCES public.user_import_recipes(id) ON DELETE CASCADE,
  average_rating double precision,
  rating_count integer NOT NULL DEFAULT 0,
  bayesian_rating double precision NOT NULL DEFAULT 3.5,
  cold_start_rating double precision NOT NULL DEFAULT 3.5,
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT user_import_recipe_rating_summaries_average_range
    CHECK (average_rating IS NULL OR average_rating BETWEEN 1.0 AND 5.0),
  CONSTRAINT user_import_recipe_rating_summaries_count_nonnegative
    CHECK (rating_count >= 0),
  CONSTRAINT user_import_recipe_rating_summaries_bayesian_range
    CHECK (bayesian_rating BETWEEN 1.0 AND 5.0),
  CONSTRAINT user_import_recipe_rating_summaries_cold_start_range
    CHECK (cold_start_rating BETWEEN 1.0 AND 5.0)
);

INSERT INTO public.user_import_recipe_rating_summaries (recipe_id)
SELECT id
FROM public.user_import_recipes
ON CONFLICT (recipe_id) DO NOTHING;

ALTER TABLE public.user_import_recipe_ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_import_recipe_rating_summaries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.user_import_recipe_ratings FROM anon, authenticated;
REVOKE ALL ON public.user_import_recipe_rating_summaries FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_import_recipe_ratings TO authenticated;
GRANT SELECT ON public.user_import_recipe_rating_summaries TO authenticated;

DROP POLICY IF EXISTS "user_import_recipe_ratings_select_own" ON public.user_import_recipe_ratings;
CREATE POLICY "user_import_recipe_ratings_select_own"
  ON public.user_import_recipe_ratings
  FOR SELECT
  TO authenticated
  USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "user_import_recipe_ratings_insert_own" ON public.user_import_recipe_ratings;
CREATE POLICY "user_import_recipe_ratings_insert_own"
  ON public.user_import_recipe_ratings
  FOR INSERT
  TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "user_import_recipe_ratings_update_own" ON public.user_import_recipe_ratings;
CREATE POLICY "user_import_recipe_ratings_update_own"
  ON public.user_import_recipe_ratings
  FOR UPDATE
  TO authenticated
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "user_import_recipe_ratings_delete_own" ON public.user_import_recipe_ratings;
CREATE POLICY "user_import_recipe_ratings_delete_own"
  ON public.user_import_recipe_ratings
  FOR DELETE
  TO authenticated
  USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "user_import_recipe_rating_summaries_select_owner"
  ON public.user_import_recipe_rating_summaries;
CREATE POLICY "user_import_recipe_rating_summaries_select_owner"
  ON public.user_import_recipe_rating_summaries
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.user_import_recipes imported
      WHERE imported.id = public.user_import_recipe_rating_summaries.recipe_id
        AND imported.user_id = (SELECT auth.uid())::text
    )
  );

CREATE OR REPLACE FUNCTION private.ensure_user_import_recipe_rating_summary()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.user_import_recipe_rating_summaries (recipe_id)
  VALUES (NEW.id)
  ON CONFLICT (recipe_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.set_user_import_recipe_rating_updated_at()
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

CREATE OR REPLACE FUNCTION private.refresh_user_import_recipe_rating_summary()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target_recipe_id text;
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
  FROM public.user_import_recipe_ratings
  WHERE recipe_id = target_recipe_id;

  SELECT cold_start_rating
  INTO prior_mean
  FROM public.user_import_recipe_rating_summaries
  WHERE recipe_id = target_recipe_id;
  prior_mean := COALESCE(prior_mean, 3.5);

  INSERT INTO public.user_import_recipe_rating_summaries (
    recipe_id,
    average_rating,
    rating_count,
    bayesian_rating,
    cold_start_rating,
    updated_at
  )
  VALUES (
    target_recipe_id,
    CASE WHEN total_ratings > 0 THEN arithmetic_average ELSE NULL END,
    total_ratings,
    CASE
      WHEN total_ratings > 0 THEN
        ((total_ratings * arithmetic_average) + (prior_weight * prior_mean))
          / (total_ratings + prior_weight)
      ELSE prior_mean
    END,
    prior_mean,
    timezone('utc', now())
  )
  ON CONFLICT (recipe_id) DO UPDATE
  SET
    average_rating = EXCLUDED.average_rating,
    rating_count = EXCLUDED.rating_count,
    bayesian_rating = EXCLUDED.bayesian_rating,
    cold_start_rating = EXCLUDED.cold_start_rating,
    updated_at = EXCLUDED.updated_at;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.ensure_user_import_recipe_rating_summary() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.set_user_import_recipe_rating_updated_at() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.refresh_user_import_recipe_rating_summary() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS ensure_user_import_recipe_rating_summary ON public.user_import_recipes;
CREATE TRIGGER ensure_user_import_recipe_rating_summary
  AFTER INSERT ON public.user_import_recipes
  FOR EACH ROW
  EXECUTE FUNCTION private.ensure_user_import_recipe_rating_summary();

DROP TRIGGER IF EXISTS set_user_import_recipe_rating_updated_at ON public.user_import_recipe_ratings;
CREATE TRIGGER set_user_import_recipe_rating_updated_at
  BEFORE UPDATE ON public.user_import_recipe_ratings
  FOR EACH ROW
  EXECUTE FUNCTION private.set_user_import_recipe_rating_updated_at();

DROP TRIGGER IF EXISTS refresh_user_import_recipe_rating_summary ON public.user_import_recipe_ratings;
CREATE TRIGGER refresh_user_import_recipe_rating_summary
  AFTER INSERT OR UPDATE OR DELETE ON public.user_import_recipe_ratings
  FOR EACH ROW
  EXECUTE FUNCTION private.refresh_user_import_recipe_rating_summary();
