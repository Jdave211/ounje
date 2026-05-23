-- Include recipe ingestion artifacts in high-churn retention cleanup.
--
-- Artifacts are diagnostic breadcrumbs for ingestion debugging. They are not
-- needed forever after a job reaches a terminal state, and they grow much
-- faster than the job rows themselves.

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
  ingestion_days          int := 60;
  terminal_statuses       text[] := ARRAY['saved', 'failed', 'cancelled', 'draft', 'needs_review'];
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

  -- recipe_ingestion_artifacts: keep 30 days for terminal jobs. Live queue
  -- artifacts are never removed, so active imports are unaffected.
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

  -- recipe_ingestion_jobs: keep terminal rows for 60 days. Non-terminal
  -- (queued / claimed / processing) rows are never deleted so the worker
  -- queue is unaffected.
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

