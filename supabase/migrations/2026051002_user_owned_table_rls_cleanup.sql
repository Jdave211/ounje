-- Lock down remaining user-owned prototype tables before launch.

ALTER TABLE public.meal_prep_cycles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_prep_cycle_completions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prep_recipe_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.main_shop_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.base_cart_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_import_recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_import_recipe_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_import_recipe_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_import_recipe_step_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_ingestion_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_ingestion_artifacts ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.meal_prep_cycles FROM anon, authenticated;
REVOKE ALL ON public.meal_prep_cycle_completions FROM anon, authenticated;
REVOKE ALL ON public.prep_recipe_overrides FROM anon, authenticated;
REVOKE ALL ON public.main_shop_items FROM anon, authenticated;
REVOKE ALL ON public.base_cart_items FROM anon, authenticated;
REVOKE ALL ON public.user_import_recipes FROM anon, authenticated;
REVOKE ALL ON public.user_import_recipe_ingredients FROM anon, authenticated;
REVOKE ALL ON public.user_import_recipe_steps FROM anon, authenticated;
REVOKE ALL ON public.user_import_recipe_step_ingredients FROM anon, authenticated;
REVOKE ALL ON public.recipe_ingestion_jobs FROM anon, authenticated;
REVOKE ALL ON public.recipe_ingestion_artifacts FROM anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.meal_prep_cycles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.meal_prep_cycle_completions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.prep_recipe_overrides TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.main_shop_items TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.base_cart_items TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_import_recipes TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_import_recipe_ingredients TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_import_recipe_steps TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_import_recipe_step_ingredients TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.recipe_ingestion_jobs TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.recipe_ingestion_artifacts TO authenticated;

DROP POLICY IF EXISTS "meal_prep_cycles_own_all" ON public.meal_prep_cycles;
CREATE POLICY "meal_prep_cycles_own_all"
  ON public.meal_prep_cycles
  FOR ALL
  TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "meal_prep_cycle_completions_own_all" ON public.meal_prep_cycle_completions;
CREATE POLICY "meal_prep_cycle_completions_own_all"
  ON public.meal_prep_cycle_completions
  FOR ALL
  TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "prep_recipe_overrides_own_all" ON public.prep_recipe_overrides;
CREATE POLICY "prep_recipe_overrides_own_all"
  ON public.prep_recipe_overrides
  FOR ALL
  TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "main_shop_items_own_all" ON public.main_shop_items;
CREATE POLICY "main_shop_items_own_all"
  ON public.main_shop_items
  FOR ALL
  TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "base_cart_items_own_all" ON public.base_cart_items;
CREATE POLICY "base_cart_items_own_all"
  ON public.base_cart_items
  FOR ALL
  TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "user_import_recipes_own_all" ON public.user_import_recipes;
CREATE POLICY "user_import_recipes_own_all"
  ON public.user_import_recipes
  FOR ALL
  TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "user_import_recipe_ingredients_own_all" ON public.user_import_recipe_ingredients;
CREATE POLICY "user_import_recipe_ingredients_own_all"
  ON public.user_import_recipe_ingredients
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.user_import_recipes recipes
      WHERE recipes.id = recipe_id
        AND recipes.user_id = auth.uid()::text
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.user_import_recipes recipes
      WHERE recipes.id = recipe_id
        AND recipes.user_id = auth.uid()::text
    )
  );

DROP POLICY IF EXISTS "user_import_recipe_steps_own_all" ON public.user_import_recipe_steps;
CREATE POLICY "user_import_recipe_steps_own_all"
  ON public.user_import_recipe_steps
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.user_import_recipes recipes
      WHERE recipes.id = recipe_id
        AND recipes.user_id = auth.uid()::text
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.user_import_recipes recipes
      WHERE recipes.id = recipe_id
        AND recipes.user_id = auth.uid()::text
    )
  );

DROP POLICY IF EXISTS "user_import_recipe_step_ingredients_own_all" ON public.user_import_recipe_step_ingredients;
CREATE POLICY "user_import_recipe_step_ingredients_own_all"
  ON public.user_import_recipe_step_ingredients
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.user_import_recipe_steps steps
      JOIN public.user_import_recipes recipes ON recipes.id = steps.recipe_id
      WHERE steps.id = recipe_step_id
        AND recipes.user_id = auth.uid()::text
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.user_import_recipe_steps steps
      JOIN public.user_import_recipes recipes ON recipes.id = steps.recipe_id
      WHERE steps.id = recipe_step_id
        AND recipes.user_id = auth.uid()::text
    )
  );

DROP POLICY IF EXISTS "recipe_ingestion_jobs_own_all" ON public.recipe_ingestion_jobs;
CREATE POLICY "recipe_ingestion_jobs_own_all"
  ON public.recipe_ingestion_jobs
  FOR ALL
  TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "recipe_ingestion_artifacts_own_all" ON public.recipe_ingestion_artifacts;
CREATE POLICY "recipe_ingestion_artifacts_own_all"
  ON public.recipe_ingestion_artifacts
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.recipe_ingestion_jobs jobs
      WHERE jobs.id = job_id
        AND jobs.user_id = auth.uid()::text
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.recipe_ingestion_jobs jobs
      WHERE jobs.id = job_id
        AND jobs.user_id = auth.uid()::text
    )
  );

