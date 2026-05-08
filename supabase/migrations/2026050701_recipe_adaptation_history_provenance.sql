ALTER TABLE public.recipe_ingestion_jobs
  ADD COLUMN IF NOT EXISTS source_provenance_json jsonb;

ALTER TABLE public.user_import_recipes
  ADD COLUMN IF NOT EXISTS source_provenance_json jsonb;

ALTER TABLE IF EXISTS public.recipes
  ADD COLUMN IF NOT EXISTS source_provenance_json jsonb;

CREATE INDEX IF NOT EXISTS idx_user_import_recipes_adaptation_history
  ON public.user_import_recipes (
    user_id,
    ((source_provenance_json ->> 'adapted_from_recipe_id')),
    updated_at DESC
  )
  WHERE source_platform = 'Ounje'
    AND source_provenance_json ->> 'kind' = 'recipe_adaptation';
