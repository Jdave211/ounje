CREATE TABLE IF NOT EXISTS public.ai_call_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  environment text,
  service text,
  route text,
  method text,
  operation text NOT NULL DEFAULT 'openai.call',
  provider text NOT NULL DEFAULT 'openai',
  api_type text,
  status text NOT NULL DEFAULT 'succeeded',
  user_id text,
  job_id text,
  request_id text,
  model text,
  duration_ms integer,
  input_tokens integer,
  output_tokens integer,
  total_tokens integer,
  estimated_cost_usd numeric(12,6),
  input_bytes integer,
  output_bytes integer,
  prompt_hash text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_message text,
  CONSTRAINT ai_call_logs_status_check CHECK (status IN ('succeeded', 'failed'))
);

ALTER TABLE public.ai_call_logs ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS ai_call_logs_created_at_idx
  ON public.ai_call_logs (created_at DESC);

CREATE INDEX IF NOT EXISTS ai_call_logs_user_created_at_idx
  ON public.ai_call_logs (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS ai_call_logs_operation_created_at_idx
  ON public.ai_call_logs (operation, created_at DESC);

CREATE INDEX IF NOT EXISTS ai_call_logs_route_created_at_idx
  ON public.ai_call_logs (route, created_at DESC);

CREATE INDEX IF NOT EXISTS ai_call_logs_job_id_idx
  ON public.ai_call_logs (job_id)
  WHERE job_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ai_call_logs_model_created_at_idx
  ON public.ai_call_logs (model, created_at DESC);

REVOKE ALL ON public.ai_call_logs FROM anon, authenticated;
GRANT SELECT, INSERT ON public.ai_call_logs TO service_role;
