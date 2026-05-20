CREATE TABLE IF NOT EXISTS public.growth_outreach_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  automation_job_id uuid REFERENCES public.automation_jobs(id) ON DELETE SET NULL,
  channel text NOT NULL DEFAULT 'both'
    CHECK (channel IN ('quora', 'roundups', 'both')),
  status text NOT NULL DEFAULT 'running'
    CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')),
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  summary jsonb NOT NULL DEFAULT '{}'::jsonb,
  started_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE TABLE IF NOT EXISTS public.quora_question_candidates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  run_id uuid REFERENCES public.growth_outreach_runs(id) ON DELETE SET NULL,
  question_url text NOT NULL,
  question_title text NOT NULL,
  snippet text,
  source_query text,
  relevance_score numeric(4, 2) NOT NULL DEFAULT 0,
  fit_reason text,
  answer_angle text,
  status text NOT NULL DEFAULT 'candidate'
    CHECK (status IN ('candidate', 'drafted', 'approved', 'posted', 'rejected', 'stale')),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (user_id, question_url)
);

CREATE TABLE IF NOT EXISTS public.quora_answer_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  run_id uuid REFERENCES public.growth_outreach_runs(id) ON DELETE SET NULL,
  question_candidate_id uuid NOT NULL REFERENCES public.quora_question_candidates(id) ON DELETE CASCADE,
  draft_body text NOT NULL,
  affiliation_disclosure text NOT NULL,
  app_mention text,
  confidence_notes text,
  compliance_notes jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'pending_review'
    CHECK (status IN ('pending_review', 'approved', 'posted', 'rejected', 'superseded')),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE TABLE IF NOT EXISTS public.roundup_list_opportunities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  run_id uuid REFERENCES public.growth_outreach_runs(id) ON DELETE SET NULL,
  post_url text NOT NULL,
  post_title text NOT NULL,
  site_name text,
  author_name text,
  contact_url text,
  contact_email text,
  snippet text,
  source_query text,
  relevance_score numeric(4, 2) NOT NULL DEFAULT 0,
  fit_reason text,
  status text NOT NULL DEFAULT 'candidate'
    CHECK (status IN ('candidate', 'contact_found', 'pitched', 'followed_up', 'included', 'rejected', 'stale')),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (user_id, post_url)
);

CREATE TABLE IF NOT EXISTS public.roundup_pitch_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  run_id uuid REFERENCES public.growth_outreach_runs(id) ON DELETE SET NULL,
  roundup_opportunity_id uuid NOT NULL REFERENCES public.roundup_list_opportunities(id) ON DELETE CASCADE,
  subject text NOT NULL,
  body text NOT NULL,
  follow_up_1_body text,
  follow_up_2_body text,
  status text NOT NULL DEFAULT 'pending_review'
    CHECK (status IN ('pending_review', 'approved', 'sent', 'rejected', 'superseded')),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_growth_outreach_runs_user_created_at
  ON public.growth_outreach_runs(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_growth_outreach_runs_status
  ON public.growth_outreach_runs(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_quora_question_candidates_user_status
  ON public.quora_question_candidates(user_id, status, relevance_score DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_quora_answer_drafts_user_status
  ON public.quora_answer_drafts(user_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_roundup_list_opportunities_user_status
  ON public.roundup_list_opportunities(user_id, status, relevance_score DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_roundup_pitch_drafts_user_status
  ON public.roundup_pitch_drafts(user_id, status, created_at DESC);

CREATE OR REPLACE FUNCTION public.set_growth_outreach_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_growth_outreach_runs_updated_at ON public.growth_outreach_runs;
CREATE TRIGGER trg_growth_outreach_runs_updated_at
  BEFORE UPDATE ON public.growth_outreach_runs
  FOR EACH ROW
  EXECUTE FUNCTION public.set_growth_outreach_updated_at();

DROP TRIGGER IF EXISTS trg_quora_question_candidates_updated_at ON public.quora_question_candidates;
CREATE TRIGGER trg_quora_question_candidates_updated_at
  BEFORE UPDATE ON public.quora_question_candidates
  FOR EACH ROW
  EXECUTE FUNCTION public.set_growth_outreach_updated_at();

DROP TRIGGER IF EXISTS trg_quora_answer_drafts_updated_at ON public.quora_answer_drafts;
CREATE TRIGGER trg_quora_answer_drafts_updated_at
  BEFORE UPDATE ON public.quora_answer_drafts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_growth_outreach_updated_at();

DROP TRIGGER IF EXISTS trg_roundup_list_opportunities_updated_at ON public.roundup_list_opportunities;
CREATE TRIGGER trg_roundup_list_opportunities_updated_at
  BEFORE UPDATE ON public.roundup_list_opportunities
  FOR EACH ROW
  EXECUTE FUNCTION public.set_growth_outreach_updated_at();

DROP TRIGGER IF EXISTS trg_roundup_pitch_drafts_updated_at ON public.roundup_pitch_drafts;
CREATE TRIGGER trg_roundup_pitch_drafts_updated_at
  BEFORE UPDATE ON public.roundup_pitch_drafts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_growth_outreach_updated_at();

ALTER FUNCTION public.set_growth_outreach_updated_at() SET search_path = public, extensions;

ALTER TABLE public.growth_outreach_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quora_question_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quora_answer_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roundup_list_opportunities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roundup_pitch_drafts ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  CREATE POLICY "growth_outreach_runs_select_own"
    ON public.growth_outreach_runs
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE POLICY "quora_question_candidates_select_own"
    ON public.quora_question_candidates
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE POLICY "quora_answer_drafts_select_own"
    ON public.quora_answer_drafts
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE POLICY "roundup_list_opportunities_select_own"
    ON public.roundup_list_opportunities
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE POLICY "roundup_pitch_drafts_select_own"
    ON public.roundup_pitch_drafts
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

REVOKE ALL ON public.growth_outreach_runs FROM anon, authenticated;
REVOKE ALL ON public.quora_question_candidates FROM anon, authenticated;
REVOKE ALL ON public.quora_answer_drafts FROM anon, authenticated;
REVOKE ALL ON public.roundup_list_opportunities FROM anon, authenticated;
REVOKE ALL ON public.roundup_pitch_drafts FROM anon, authenticated;

GRANT SELECT ON public.growth_outreach_runs TO authenticated;
GRANT SELECT ON public.quora_question_candidates TO authenticated;
GRANT SELECT ON public.quora_answer_drafts TO authenticated;
GRANT SELECT ON public.roundup_list_opportunities TO authenticated;
GRANT SELECT ON public.roundup_pitch_drafts TO authenticated;

GRANT ALL ON public.growth_outreach_runs TO service_role;
GRANT ALL ON public.quora_question_candidates TO service_role;
GRANT ALL ON public.quora_answer_drafts TO service_role;
GRANT ALL ON public.roundup_list_opportunities TO service_role;
GRANT ALL ON public.roundup_pitch_drafts TO service_role;
