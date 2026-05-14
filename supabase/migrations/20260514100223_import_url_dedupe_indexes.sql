-- Speed up import URL dedupe before expensive normalization. These indexes
-- support both per-user cache hits and global completed-import reuse.

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_canonical_completed
  ON public.recipe_ingestion_jobs(canonical_url, completed_at DESC)
  WHERE recipe_id IS NOT NULL
    AND status IN ('saved', 'draft', 'needs_review')
    AND canonical_url IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_source_completed
  ON public.recipe_ingestion_jobs(source_url, completed_at DESC)
  WHERE recipe_id IS NOT NULL
    AND status IN ('saved', 'draft', 'needs_review')
    AND source_url IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_dedupe_completed
  ON public.recipe_ingestion_jobs(dedupe_key, completed_at DESC)
  WHERE recipe_id IS NOT NULL
    AND status IN ('saved', 'draft', 'needs_review')
    AND dedupe_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_import_recipes_user_recipe_url
  ON public.user_import_recipes(user_id, recipe_url)
  WHERE recipe_url IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_import_recipes_user_original_url
  ON public.user_import_recipes(user_id, original_recipe_url)
  WHERE original_recipe_url IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_import_recipes_user_attached_video_url
  ON public.user_import_recipes(user_id, attached_video_url)
  WHERE attached_video_url IS NOT NULL;
