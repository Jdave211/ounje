-- Retention policy for high-churn diagnostic / log tables.
--
-- These tables grow continuously with normal usage and have no application-
-- level cleanup today:
--   * ai_call_logs               -- every backend OpenAI call
--   * instacart_run_log_traces   -- per-step browser-automation trace events
--   * recipe_ingestion_jobs      -- only the terminal (saved / failed / cancelled) rows
--
-- Unbounded growth leads to:
--   - table bloat and slower index scans on the live working set
--   - heavier autovacuum cycles
--   - larger snapshot/backup costs
--
-- We define an idempotent cleanup function and schedule it daily with pg_cron
-- if the extension is available. Retention windows are conservative; tweak
-- via the ENV-controlled application setting `app.retention_days_*` if
-- desired in the future.

CREATE OR REPLACE FUNCTION public.run_log_retention_cleanup()
RETURNS TABLE (
  table_name text,
  rows_deleted bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  ai_call_logs_days int := 30;
  trace_days        int := 30;
  ingestion_days    int := 60;
  v_count bigint;
BEGIN
  -- ai_call_logs: keep 30 days of detailed OpenAI usage rows.
  IF to_regclass('public.ai_call_logs') IS NOT NULL THEN
    DELETE FROM public.ai_call_logs
    WHERE created_at < (now() - make_interval(days => ai_call_logs_days));
    GET DIAGNOSTICS v_count = ROW_COUNT;
    table_name := 'ai_call_logs';
    rows_deleted := v_count;
    RETURN NEXT;
  END IF;

  -- instacart_run_log_traces: keep 30 days of per-step trace events.
  IF to_regclass('public.instacart_run_log_traces') IS NOT NULL THEN
    DELETE FROM public.instacart_run_log_traces
    WHERE created_at < (now() - make_interval(days => trace_days));
    GET DIAGNOSTICS v_count = ROW_COUNT;
    table_name := 'instacart_run_log_traces';
    rows_deleted := v_count;
    RETURN NEXT;
  END IF;

  -- recipe_ingestion_jobs: keep terminal rows for 60 days. Non-terminal
  -- (queued / claimed / processing) rows are never deleted so the worker
  -- queue is unaffected.
  IF to_regclass('public.recipe_ingestion_jobs') IS NOT NULL THEN
    DELETE FROM public.recipe_ingestion_jobs
    WHERE status IN ('saved', 'failed', 'cancelled')
      AND COALESCE(completed_at, updated_at, created_at)
          < (now() - make_interval(days => ingestion_days));
    GET DIAGNOSTICS v_count = ROW_COUNT;
    table_name := 'recipe_ingestion_jobs';
    rows_deleted := v_count;
    RETURN NEXT;
  END IF;

  RETURN;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.run_log_retention_cleanup() FROM PUBLIC;

-- Schedule via pg_cron if the extension exists in this project. Wrapped in a
-- DO block so the migration succeeds on projects without pg_cron.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
  ) THEN
    -- Unschedule any prior version of this job before reinstalling.
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'ounje_run_log_retention';

    PERFORM cron.schedule(
      'ounje_run_log_retention',
      '17 4 * * *',
      $cron$SELECT public.run_log_retention_cleanup();$cron$
    );
  END IF;
END $$;
