CREATE OR REPLACE FUNCTION public.claim_recipe_ingestion_jobs(
  p_worker_id text,
  p_batch_size integer DEFAULT 5,
  p_stale_before timestamptz DEFAULT (timezone('utc', now()) - interval '15 minutes')
)
RETURNS SETOF public.recipe_ingestion_jobs
LANGUAGE plpgsql
AS $$
BEGIN
  -- Production recipe ingestion is VM-owned. Render and old droplet workers
  -- should enqueue/read only, not claim jobs and spend OpenAI budget.
  IF lower(coalesce(p_worker_id, '')) NOT LIKE 'vm_recipe_ingest%' THEN
    RETURN;
  END IF;

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
          'event', 'claimed',
          'at', timezone('utc', now()),
          'worker_id', p_worker_id,
          'attempt', jobs.attempts + 1,
          'previous_status', jobs.status
        )
      )
    FROM candidates
    WHERE jobs.id = candidates.id
    RETURNING jobs.*
  )
  SELECT * FROM claimed;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_recipe_ingestion_jobs(text, integer, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_recipe_ingestion_jobs(text, integer, timestamptz) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_recipe_ingestion_jobs(text, integer, timestamptz) TO service_role;
