CREATE TABLE IF NOT EXISTS public.automation_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  kind text NOT NULL,
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  result jsonb NOT NULL DEFAULT '{}'::jsonb,
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  max_attempts integer NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
  locked_by text,
  locked_until timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  error_message text,
  run_id text,
  grocery_order_id uuid,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_automation_jobs_user_created_at
  ON public.automation_jobs(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_automation_jobs_status_locked_until
  ON public.automation_jobs(status, locked_until, created_at);

CREATE INDEX IF NOT EXISTS idx_automation_jobs_kind_status
  ON public.automation_jobs(kind, status, created_at);

CREATE INDEX IF NOT EXISTS idx_automation_jobs_run_id
  ON public.automation_jobs(run_id)
  WHERE run_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.set_automation_jobs_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_automation_jobs_updated_at ON public.automation_jobs;
CREATE TRIGGER trg_automation_jobs_updated_at
  BEFORE UPDATE ON public.automation_jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.set_automation_jobs_updated_at();

CREATE OR REPLACE FUNCTION public.claim_automation_jobs(
  p_worker_id text,
  p_kinds text[] DEFAULT NULL,
  p_batch_size integer DEFAULT 1,
  p_lock_seconds integer DEFAULT 300
)
RETURNS SETOF public.automation_jobs
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT id
    FROM public.automation_jobs
    WHERE (
      status = 'queued'
      OR (
        status = 'running'
        AND locked_until IS NOT NULL
        AND locked_until < timezone('utc', now())
      )
    )
      AND attempt_count < max_attempts
      AND (p_kinds IS NULL OR kind = ANY(p_kinds))
    ORDER BY created_at ASC
    LIMIT GREATEST(COALESCE(p_batch_size, 1), 1)
    FOR UPDATE SKIP LOCKED
  ),
  claimed AS (
    UPDATE public.automation_jobs jobs
    SET
      status = 'running',
      locked_by = p_worker_id,
      locked_until = timezone('utc', now()) + make_interval(secs => GREATEST(COALESCE(p_lock_seconds, 300), 30)),
      started_at = COALESCE(jobs.started_at, timezone('utc', now())),
      attempt_count = jobs.attempt_count + 1,
      error_message = NULL
    FROM candidates
    WHERE jobs.id = candidates.id
    RETURNING jobs.*
  )
  SELECT * FROM claimed;
END;
$$;

ALTER TABLE public.automation_jobs ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  CREATE POLICY "automation_jobs_select_own"
    ON public.automation_jobs
    FOR SELECT
    USING (auth.uid() = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

GRANT SELECT ON public.automation_jobs TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_automation_jobs(text, text[], integer, integer) TO service_role;
