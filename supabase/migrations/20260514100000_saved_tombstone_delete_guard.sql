-- Make saved-recipe unsave durable: a tombstone must remove the cookbook
-- bookmark and prevent import/background paths from resurrecting it.

CREATE OR REPLACE FUNCTION public.delete_tombstoned_saved_recipe()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
BEGIN
  DELETE FROM public.saved_recipes
  WHERE user_id = NEW.user_id
    AND recipe_id = NEW.recipe_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS delete_tombstoned_saved_recipe ON public.saved_recipe_tombstones;
CREATE TRIGGER delete_tombstoned_saved_recipe
  AFTER INSERT OR UPDATE ON public.saved_recipe_tombstones
  FOR EACH ROW
  EXECUTE FUNCTION public.delete_tombstoned_saved_recipe();

DELETE FROM public.saved_recipes saved
USING public.saved_recipe_tombstones tombstone
WHERE saved.user_id = tombstone.user_id
  AND saved.recipe_id = tombstone.recipe_id;

