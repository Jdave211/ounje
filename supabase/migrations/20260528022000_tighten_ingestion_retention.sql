-- Tighten high-churn ingestion retention.
--
-- Completed recipe details live in user_import_recipes/recipes. Historical
-- recipe_ingestion_jobs rows are diagnostics and queue state; once terminal,
-- they should not keep bloating hot indexes or accidental count scans.

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
  ai_call_logs_days       int := 30;
  trace_days              int := 30;
  ingestion_artifact_days int := 30;
  ingestion_days          int := 30;
  terminal_statuses       text[] := ARRAY['saved', 'failed', 'cancelled', 'draft', 'needs_review', 'superseded'];
  v_count bigint;
BEGIN
  IF to_regclass('public.ai_call_logs') IS NOT NULL THEN
    DELETE FROM public.ai_call_logs
    WHERE created_at < (now() - make_interval(days => ai_call_logs_days));
    GET DIAGNOSTICS v_count = ROW_COUNT;
    table_name := 'ai_call_logs';
    rows_deleted := v_count;
    RETURN NEXT;
  END IF;

  IF to_regclass('public.instacart_run_log_traces') IS NOT NULL THEN
    DELETE FROM public.instacart_run_log_traces
    WHERE created_at < (now() - make_interval(days => trace_days));
    GET DIAGNOSTICS v_count = ROW_COUNT;
    table_name := 'instacart_run_log_traces';
    rows_deleted := v_count;
    RETURN NEXT;
  END IF;

  IF to_regclass('public.recipe_ingestion_artifacts') IS NOT NULL
     AND to_regclass('public.recipe_ingestion_jobs') IS NOT NULL THEN
    DELETE FROM public.recipe_ingestion_artifacts artifacts
    USING public.recipe_ingestion_jobs jobs
    WHERE artifacts.job_id = jobs.id
      AND jobs.status = ANY (terminal_statuses)
      AND artifacts.created_at < (now() - make_interval(days => ingestion_artifact_days));
    GET DIAGNOSTICS v_count = ROW_COUNT;
    table_name := 'recipe_ingestion_artifacts';
    rows_deleted := v_count;
    RETURN NEXT;
  END IF;

  IF to_regclass('public.recipe_ingestion_jobs') IS NOT NULL THEN
    DELETE FROM public.recipe_ingestion_jobs
    WHERE status = ANY (terminal_statuses)
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

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
  ) THEN
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
