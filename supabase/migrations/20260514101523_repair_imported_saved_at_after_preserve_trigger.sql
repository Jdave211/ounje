-- The first preserve trigger migration intentionally made saved_at immutable on
-- UPDATE, but its repair UPDATE ran after the trigger was installed. That means
-- the trigger protected the already-corrupted values too. Repair imported saved
-- rows from their import record timestamp, then reinstall the immutable guard.

DROP TRIGGER IF EXISTS preserve_saved_recipe_saved_at ON public.saved_recipes;

UPDATE public.saved_recipes AS saved
SET saved_at = imported.created_at
FROM public.user_import_recipes AS imported
WHERE saved.user_id = imported.user_id
  AND saved.recipe_id = imported.id
  AND imported.created_at IS NOT NULL
  AND saved.saved_at >= '2026-05-14T10:00:00Z'::timestamptz
  AND saved.saved_at > imported.created_at + interval '5 minutes';

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

CREATE TRIGGER preserve_saved_recipe_saved_at
  BEFORE UPDATE ON public.saved_recipes
  FOR EACH ROW
  EXECUTE FUNCTION public.preserve_saved_recipe_saved_at();
