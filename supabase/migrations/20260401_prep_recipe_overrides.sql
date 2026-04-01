CREATE TABLE IF NOT EXISTS public.prep_recipe_overrides (
  user_id text NOT NULL,
  recipe_id text NOT NULL,
  recipe jsonb NOT NULL,
  servings integer NOT NULL DEFAULT 1,
  is_included_in_prep boolean NOT NULL DEFAULT TRUE,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (user_id, recipe_id)
);

CREATE INDEX IF NOT EXISTS idx_prep_recipe_overrides_user_updated_at
  ON public.prep_recipe_overrides(user_id, updated_at DESC);

CREATE OR REPLACE FUNCTION public.set_prep_recipe_overrides_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prep_recipe_overrides_updated_at ON public.prep_recipe_overrides;
CREATE TRIGGER trg_prep_recipe_overrides_updated_at
  BEFORE UPDATE ON public.prep_recipe_overrides
  FOR EACH ROW
  EXECUTE FUNCTION public.set_prep_recipe_overrides_updated_at();

ALTER TABLE public.prep_recipe_overrides DISABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.prep_recipe_overrides TO anon, authenticated;
