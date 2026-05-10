-- Tighten exposed public tables for launch.
-- Public catalog data remains read-only. User/private/backend tables rely on RLS
-- ownership policies or service-role-only access.

ALTER TABLE public.ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_breadcrumbs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_scrapes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_step_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.schema_migrations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.ingredients FROM anon, authenticated;
REVOKE ALL ON public.recipe_breadcrumbs FROM anon, authenticated;
REVOKE ALL ON public.recipe_ingredients FROM anon, authenticated;
REVOKE ALL ON public.recipe_media FROM anon, authenticated;
REVOKE ALL ON public.recipe_scrapes FROM anon, authenticated;
REVOKE ALL ON public.recipe_step_ingredients FROM anon, authenticated;
REVOKE ALL ON public.recipe_steps FROM anon, authenticated;
REVOKE ALL ON public.recipes FROM anon, authenticated;
REVOKE ALL ON public.schema_migrations FROM anon, authenticated;

GRANT SELECT ON public.ingredients TO anon, authenticated;
GRANT SELECT ON public.recipe_breadcrumbs TO anon, authenticated;
GRANT SELECT ON public.recipe_ingredients TO anon, authenticated;
GRANT SELECT ON public.recipe_media TO anon, authenticated;
GRANT SELECT ON public.recipe_step_ingredients TO anon, authenticated;
GRANT SELECT ON public.recipe_steps TO anon, authenticated;
GRANT SELECT ON public.recipes TO anon, authenticated;

DROP POLICY IF EXISTS "public_read_ingredients" ON public.ingredients;
CREATE POLICY "public_read_ingredients"
  ON public.ingredients
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "public_read_recipe_breadcrumbs" ON public.recipe_breadcrumbs;
CREATE POLICY "public_read_recipe_breadcrumbs"
  ON public.recipe_breadcrumbs
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "public_read_recipe_ingredients" ON public.recipe_ingredients;
CREATE POLICY "public_read_recipe_ingredients"
  ON public.recipe_ingredients
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "public_read_recipe_media" ON public.recipe_media;
CREATE POLICY "public_read_recipe_media"
  ON public.recipe_media
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "public_read_recipe_step_ingredients" ON public.recipe_step_ingredients;
CREATE POLICY "public_read_recipe_step_ingredients"
  ON public.recipe_step_ingredients
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "public_read_recipe_steps" ON public.recipe_steps;
CREATE POLICY "public_read_recipe_steps"
  ON public.recipe_steps
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "public_read_recipes" ON public.recipes;
CREATE POLICY "public_read_recipes"
  ON public.recipes
  FOR SELECT
  TO anon, authenticated
  USING (true);

REVOKE ALL ON public.app_feedback_messages FROM anon, authenticated;
REVOKE ALL ON public.app_user_entitlements FROM anon, authenticated;
REVOKE ALL ON public.automation_jobs FROM anon, authenticated;
REVOKE ALL ON public.instacart_run_logs FROM anon, authenticated;
REVOKE ALL ON public.landing_events FROM anon, authenticated;
REVOKE ALL ON public.prep_recurring_recipes FROM anon, authenticated;

GRANT SELECT, INSERT ON public.app_feedback_messages TO authenticated;
GRANT SELECT ON public.app_user_entitlements TO authenticated;
GRANT SELECT ON public.automation_jobs TO authenticated;
GRANT SELECT ON public.instacart_run_logs TO authenticated;
GRANT INSERT ON public.landing_events TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.prep_recurring_recipes TO authenticated;

DROP POLICY IF EXISTS "authenticated_insert_landing_events" ON public.landing_events;
CREATE POLICY "authenticated_insert_landing_events"
  ON public.landing_events
  FOR INSERT
  TO authenticated
  WITH CHECK (true);
