CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_user_canonical_completed
  ON public.recipe_ingestion_jobs(user_id, canonical_url, completed_at DESC)
  WHERE recipe_id IS NOT NULL AND status IN ('saved', 'draft', 'needs_review') AND canonical_url IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_user_source_completed
  ON public.recipe_ingestion_jobs(user_id, source_url, completed_at DESC)
  WHERE recipe_id IS NOT NULL AND status IN ('saved', 'draft', 'needs_review') AND source_url IS NOT NULL;

