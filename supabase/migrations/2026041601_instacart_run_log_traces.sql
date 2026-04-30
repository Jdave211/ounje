CREATE TABLE IF NOT EXISTS public.instacart_run_log_traces (
  run_id text PRIMARY KEY,
  user_id text NOT NULL,
  trace_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_instacart_run_log_traces_user_created_at
  ON public.instacart_run_log_traces(user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.set_instacart_run_log_traces_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_instacart_run_log_traces_updated_at ON public.instacart_run_log_traces;
CREATE TRIGGER trg_instacart_run_log_traces_updated_at
  BEFORE UPDATE ON public.instacart_run_log_traces
  FOR EACH ROW
  EXECUTE FUNCTION public.set_instacart_run_log_traces_updated_at();

ALTER TABLE public.instacart_run_log_traces ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  CREATE POLICY "instacart_run_log_traces_select_own"
    ON public.instacart_run_log_traces
    FOR SELECT
    USING (auth.uid()::text = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE POLICY "instacart_run_log_traces_insert_own"
    ON public.instacart_run_log_traces
    FOR INSERT
    WITH CHECK (auth.uid()::text = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE POLICY "instacart_run_log_traces_update_own"
    ON public.instacart_run_log_traces
    FOR UPDATE
    USING (auth.uid()::text = user_id)
    WITH CHECK (auth.uid()::text = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

GRANT SELECT, INSERT, UPDATE ON public.instacart_run_log_traces TO authenticated;

INSERT INTO public.instacart_run_log_traces (run_id, user_id, trace_json, created_at, updated_at)
SELECT run_id, user_id, trace_json, created_at, updated_at
FROM public.instacart_run_logs
WHERE trace_json IS NOT NULL
  AND trace_json <> '{}'::jsonb
ON CONFLICT (run_id) DO UPDATE
SET user_id = EXCLUDED.user_id,
    trace_json = EXCLUDED.trace_json,
    updated_at = timezone('utc', now());
