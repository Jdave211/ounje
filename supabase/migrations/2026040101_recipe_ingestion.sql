CREATE TABLE IF NOT EXISTS public.recipe_ingestion_jobs (
  id text PRIMARY KEY,
  user_id text,
  target_state text NOT NULL DEFAULT 'saved',
  source_type text NOT NULL,
  source_url text,
  canonical_url text,
  input_text text,
  request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  dedupe_key text,
  dedupe_recipe_id text,
  recipe_id text,
  status text NOT NULL DEFAULT 'queued',
  review_state text NOT NULL DEFAULT 'pending',
  confidence_score numeric(5, 4),
  quality_flags text[] NOT NULL DEFAULT '{}'::text[],
  review_reason text,
  error_message text,
  attempts integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 3,
  worker_id text,
  leased_at timestamptz,
  queued_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  fetched_at timestamptz,
  parsed_at timestamptz,
  normalized_at timestamptz,
  saved_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  event_log jsonb NOT NULL DEFAULT '[]'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_status_queued_at
  ON public.recipe_ingestion_jobs(status, queued_at ASC);

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_user_created_at
  ON public.recipe_ingestion_jobs(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_recipe_id
  ON public.recipe_ingestion_jobs(recipe_id);

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_dedupe_key
  ON public.recipe_ingestion_jobs(dedupe_key);

CREATE TABLE IF NOT EXISTS public.recipe_ingestion_artifacts (
  id text PRIMARY KEY,
  job_id text NOT NULL REFERENCES public.recipe_ingestion_jobs(id) ON DELETE CASCADE,
  artifact_type text NOT NULL,
  content_type text,
  source_url text,
  text_content text,
  raw_json jsonb,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_artifacts_job_created_at
  ON public.recipe_ingestion_artifacts(job_id, created_at ASC);

CREATE OR REPLACE FUNCTION public.set_recipe_ingestion_jobs_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recipe_ingestion_jobs_updated_at ON public.recipe_ingestion_jobs;
CREATE TRIGGER trg_recipe_ingestion_jobs_updated_at
  BEFORE UPDATE ON public.recipe_ingestion_jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.set_recipe_ingestion_jobs_updated_at();

CREATE OR REPLACE FUNCTION public.claim_recipe_ingestion_jobs(
  p_worker_id text,
  p_batch_size integer DEFAULT 5,
  p_stale_before timestamptz DEFAULT (timezone('utc', now()) - interval '15 minutes')
)
RETURNS SETOF public.recipe_ingestion_jobs
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT id
    FROM public.recipe_ingestion_jobs
    WHERE (
      status IN ('queued', 'retryable')
      OR (
        status IN ('processing', 'fetching', 'parsing', 'normalized')
        AND leased_at IS NOT NULL
        AND leased_at < p_stale_before
      )
    )
      AND attempts < max_attempts
    ORDER BY queued_at ASC
    LIMIT GREATEST(COALESCE(p_batch_size, 1), 1)
    FOR UPDATE SKIP LOCKED
  ),
  claimed AS (
    UPDATE public.recipe_ingestion_jobs jobs
    SET
      status = 'processing',
      worker_id = p_worker_id,
      leased_at = timezone('utc', now()),
      attempts = jobs.attempts + 1,
      event_log = COALESCE(jobs.event_log, '[]'::jsonb) || jsonb_build_array(
        jsonb_build_object(
          'event', 'processing',
          'at', timezone('utc', now()),
          'worker_id', p_worker_id,
          'attempt', jobs.attempts + 1
        )
      )
    FROM candidates
    WHERE jobs.id = candidates.id
    RETURNING jobs.*
  )
  SELECT * FROM claimed;
END;
$$;

ALTER TABLE public.recipe_ingestion_jobs DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_ingestion_artifacts DISABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.recipe_ingestion_jobs TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.recipe_ingestion_artifacts TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_recipe_ingestion_jobs(text, integer, timestamptz) TO anon, authenticated;
