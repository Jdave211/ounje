ALTER TABLE public.growth_outreach_runs
  DROP CONSTRAINT IF EXISTS growth_outreach_runs_channel_check;

ALTER TABLE public.growth_outreach_runs
  ADD CONSTRAINT growth_outreach_runs_channel_check
  CHECK (channel IN ('quora', 'roundups', 'both', 'creators', 'all'));

CREATE TABLE IF NOT EXISTS public.creator_profile_candidates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  run_id uuid REFERENCES public.growth_outreach_runs(id) ON DELETE SET NULL,
  platform text NOT NULL CHECK (platform IN ('instagram', 'tiktok')),
  profile_url text NOT NULL,
  handle text NOT NULL,
  display_name text,
  bio_snippet text,
  source_query text,
  relevance_score numeric(4, 2) NOT NULL DEFAULT 0,
  fit_reason text,
  outreach_angle text,
  status text NOT NULL DEFAULT 'candidate'
    CHECK (status IN ('candidate', 'drafted', 'approved', 'contacted', 'rejected', 'stale')),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (user_id, profile_url)
);

CREATE TABLE IF NOT EXISTS public.creator_outreach_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  run_id uuid REFERENCES public.growth_outreach_runs(id) ON DELETE SET NULL,
  creator_candidate_id uuid NOT NULL REFERENCES public.creator_profile_candidates(id) ON DELETE CASCADE,
  platform text NOT NULL CHECK (platform IN ('instagram', 'tiktok')),
  profile_url text NOT NULL,
  handle text NOT NULL,
  message_body text NOT NULL,
  follow_up_body text,
  offer_summary text,
  brief_summary text,
  execution_plan jsonb NOT NULL DEFAULT '{}'::jsonb,
  confidence_notes text,
  compliance_notes jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'pending_review'
    CHECK (status IN ('pending_review', 'approved', 'sent', 'rejected', 'superseded')),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_creator_profile_candidates_user_status
  ON public.creator_profile_candidates(user_id, status, relevance_score DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_creator_outreach_drafts_user_status
  ON public.creator_outreach_drafts(user_id, status, created_at DESC);

DROP TRIGGER IF EXISTS trg_creator_profile_candidates_updated_at ON public.creator_profile_candidates;
CREATE TRIGGER trg_creator_profile_candidates_updated_at
  BEFORE UPDATE ON public.creator_profile_candidates
  FOR EACH ROW
  EXECUTE FUNCTION public.set_growth_outreach_updated_at();

DROP TRIGGER IF EXISTS trg_creator_outreach_drafts_updated_at ON public.creator_outreach_drafts;
CREATE TRIGGER trg_creator_outreach_drafts_updated_at
  BEFORE UPDATE ON public.creator_outreach_drafts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_growth_outreach_updated_at();

ALTER TABLE public.creator_profile_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_outreach_drafts ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  CREATE POLICY "creator_profile_candidates_select_own"
    ON public.creator_profile_candidates
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE POLICY "creator_outreach_drafts_select_own"
    ON public.creator_outreach_drafts
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

REVOKE ALL ON public.creator_profile_candidates FROM anon, authenticated;
REVOKE ALL ON public.creator_outreach_drafts FROM anon, authenticated;

GRANT SELECT ON public.creator_profile_candidates TO authenticated;
GRANT SELECT ON public.creator_outreach_drafts TO authenticated;

GRANT ALL ON public.creator_profile_candidates TO service_role;
GRANT ALL ON public.creator_outreach_drafts TO service_role;
