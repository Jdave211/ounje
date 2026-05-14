-- Durable save-state guard: an imported recipe can remain in import history
-- while its saved cookbook bookmark is explicitly suppressed by the user.

CREATE TABLE IF NOT EXISTS public.saved_recipe_tombstones (
  user_id text NOT NULL,
  recipe_id text NOT NULL,
  deleted_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  reason text,
  PRIMARY KEY (user_id, recipe_id)
);

CREATE INDEX IF NOT EXISTS idx_saved_recipe_tombstones_user_deleted_at
  ON public.saved_recipe_tombstones(user_id, deleted_at DESC);

ALTER TABLE public.saved_recipe_tombstones ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.saved_recipe_tombstones FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.saved_recipe_tombstones TO authenticated;

DROP POLICY IF EXISTS "saved_recipe_tombstones_own_all" ON public.saved_recipe_tombstones;
CREATE POLICY "saved_recipe_tombstones_own_all"
  ON public.saved_recipe_tombstones
  FOR ALL
  TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

CREATE OR REPLACE FUNCTION public.prevent_tombstoned_saved_recipe()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.saved_recipe_tombstones tombstone
    WHERE tombstone.user_id = NEW.user_id
      AND tombstone.recipe_id = NEW.recipe_id
  ) THEN
    RETURN NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_tombstoned_saved_recipe ON public.saved_recipes;
CREATE TRIGGER prevent_tombstoned_saved_recipe
  BEFORE INSERT OR UPDATE ON public.saved_recipes
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_tombstoned_saved_recipe();
