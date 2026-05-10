-- Production auth hardening for profiles and provider connect session status.

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.profiles FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;

DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
CREATE POLICY "profiles_select_own"
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (auth.uid()::text = id);

DROP POLICY IF EXISTS "profiles_insert_own" ON public.profiles;
CREATE POLICY "profiles_insert_own"
  ON public.profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid()::text = id);

DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own"
  ON public.profiles
  FOR UPDATE
  TO authenticated
  USING (auth.uid()::text = id)
  WITH CHECK (auth.uid()::text = id);

CREATE TABLE IF NOT EXISTS public.provider_connect_sessions (
  session_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'connected', 'expired', 'failed')),
  expires_at timestamptz NOT NULL,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_provider_connect_sessions_user_created
  ON public.provider_connect_sessions(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_provider_connect_sessions_status_expires
  ON public.provider_connect_sessions(status, expires_at);

CREATE OR REPLACE FUNCTION public.set_provider_connect_sessions_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_provider_connect_sessions_updated_at ON public.provider_connect_sessions;
CREATE TRIGGER trg_provider_connect_sessions_updated_at
  BEFORE UPDATE ON public.provider_connect_sessions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_provider_connect_sessions_updated_at();

ALTER TABLE public.provider_connect_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "provider_connect_sessions_select_own" ON public.provider_connect_sessions;
CREATE POLICY "provider_connect_sessions_select_own"
  ON public.provider_connect_sessions
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

REVOKE ALL ON public.provider_connect_sessions FROM anon, authenticated;
GRANT SELECT ON public.provider_connect_sessions TO authenticated;
