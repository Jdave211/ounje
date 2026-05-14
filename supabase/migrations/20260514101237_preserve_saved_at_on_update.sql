-- saved_at is the explicit bookmark time. Metadata hydration, import refreshes,
-- and cache repair upserts must never move an existing saved recipe to the top.

CREATE OR REPLACE FUNCTION public.preserve_saved_recipe_saved_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.saved_at = OLD.saved_at;
  END IF;

  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS preserve_saved_recipe_saved_at ON public.saved_recipes;
CREATE TRIGGER preserve_saved_recipe_saved_at
  BEFORE UPDATE ON public.saved_recipes
  FOR EACH ROW
  EXECUTE FUNCTION public.preserve_saved_recipe_saved_at();
