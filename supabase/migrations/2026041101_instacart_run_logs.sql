CREATE TABLE IF NOT EXISTS public.instacart_run_logs (
  run_id text PRIMARY KEY,
  user_id text NOT NULL,
  status_kind text NOT NULL,
  success boolean NOT NULL DEFAULT false,
  partial_success boolean NOT NULL DEFAULT false,
  started_at timestamptz,
  completed_at timestamptz,
  selected_store text,
  preferred_store text,
  strict_store text,
  session_source text,
  item_count integer NOT NULL DEFAULT 0,
  resolved_count integer NOT NULL DEFAULT 0,
  unresolved_count integer NOT NULL DEFAULT 0,
  shortfall_count integer NOT NULL DEFAULT 0,
  attempt_count integer NOT NULL DEFAULT 0,
  duration_seconds integer,
  progress numeric(5,3) NOT NULL DEFAULT 0,
  top_issue text,
  search_preview text,
  matches jsonb NOT NULL DEFAULT '[]'::jsonb,
  cart_url text,
  summary_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  trace_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  search_text text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_instacart_run_logs_user_completed_at
  ON public.instacart_run_logs(user_id, completed_at DESC);

CREATE INDEX IF NOT EXISTS idx_instacart_run_logs_user_status_completed_at
  ON public.instacart_run_logs(user_id, status_kind, completed_at DESC);

CREATE INDEX IF NOT EXISTS idx_instacart_run_logs_user_started_at
  ON public.instacart_run_logs(user_id, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_instacart_run_logs_user_progress
  ON public.instacart_run_logs(user_id, progress DESC);

CREATE OR REPLACE FUNCTION public.set_instacart_run_logs_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_instacart_run_logs_updated_at ON public.instacart_run_logs;
CREATE TRIGGER trg_instacart_run_logs_updated_at
  BEFORE UPDATE ON public.instacart_run_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.set_instacart_run_logs_updated_at();

ALTER TABLE public.instacart_run_logs ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  CREATE POLICY "instacart_run_logs_select_own"
    ON public.instacart_run_logs
    FOR SELECT
    USING (auth.uid()::text = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE POLICY "instacart_run_logs_insert_own"
    ON public.instacart_run_logs
    FOR INSERT
    WITH CHECK (auth.uid()::text = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE POLICY "instacart_run_logs_update_own"
    ON public.instacart_run_logs
    FOR UPDATE
    USING (auth.uid()::text = user_id)
    WITH CHECK (auth.uid()::text = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

GRANT SELECT, INSERT, UPDATE ON public.instacart_run_logs TO authenticated;
