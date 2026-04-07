CREATE TABLE IF NOT EXISTS public.recipe_ingestion_evidence_bundles (
  id text PRIMARY KEY,
  job_id text NOT NULL UNIQUE REFERENCES public.recipe_ingestion_jobs(id) ON DELETE CASCADE,
  source_type text,
  platform text,
  source_url text,
  canonical_url text,
  title text,
  description text,
  author_name text,
  author_handle text,
  transcript_text text,
  frame_count integer,
  frame_ocr_json jsonb NOT NULL DEFAULT '[]'::jsonb,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_evidence_bundles_job_created_at
  ON public.recipe_ingestion_evidence_bundles(job_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_review_state
  ON public.recipe_ingestion_jobs(review_state, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_import_recipes_review_state
  ON public.user_import_recipes(user_id, review_state, updated_at DESC);

ALTER TABLE public.recipe_ingestion_jobs
  ADD COLUMN IF NOT EXISTS evidence_bundle_id text;

ALTER TABLE public.recipe_ingestion_jobs
  ADD COLUMN IF NOT EXISTS source_provenance_json jsonb;

ALTER TABLE public.user_import_recipes
  ADD COLUMN IF NOT EXISTS source_provenance_json jsonb;

ALTER TABLE IF EXISTS public.recipes
  ADD COLUMN IF NOT EXISTS source_provenance_json jsonb;

ALTER TABLE public.recipe_ingestion_evidence_bundles DISABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.recipe_ingestion_evidence_bundles TO anon, authenticated;
