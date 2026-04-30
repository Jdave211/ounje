-- Canonical user membership entitlements resolved from StoreKit and manual grants.

CREATE TABLE IF NOT EXISTS public.app_user_entitlements (
  user_id TEXT PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  tier TEXT NOT NULL CHECK (tier IN ('free', 'plus', 'autopilot', 'foundingLifetime')),
  status TEXT NOT NULL CHECK (status IN ('active', 'expired', 'revoked', 'inactive')),
  source TEXT NOT NULL CHECK (source IN ('app_store', 'manual', 'system')),
  product_id TEXT,
  transaction_id TEXT,
  original_transaction_id TEXT,
  expires_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

ALTER TABLE public.app_user_entitlements
  ADD COLUMN IF NOT EXISTS tier TEXT,
  ADD COLUMN IF NOT EXISTS status TEXT,
  ADD COLUMN IF NOT EXISTS source TEXT,
  ADD COLUMN IF NOT EXISTS product_id TEXT,
  ADD COLUMN IF NOT EXISTS transaction_id TEXT,
  ADD COLUMN IF NOT EXISTS original_transaction_id TEXT,
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now());

UPDATE public.app_user_entitlements
SET
  tier = COALESCE(NULLIF(tier, ''), 'free'),
  status = COALESCE(NULLIF(status, ''), 'inactive'),
  source = COALESCE(NULLIF(source, ''), 'system')
WHERE tier IS NULL
   OR status IS NULL
   OR source IS NULL
   OR tier = ''
   OR status = ''
   OR source = '';

ALTER TABLE public.app_user_entitlements
  ALTER COLUMN tier SET NOT NULL,
  ALTER COLUMN status SET NOT NULL,
  ALTER COLUMN source SET NOT NULL;

DROP TRIGGER IF EXISTS trg_app_user_entitlements_updated_at ON public.app_user_entitlements;
DROP FUNCTION IF EXISTS public.set_app_user_entitlements_updated_at();

CREATE OR REPLACE FUNCTION public.set_app_user_entitlements_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_app_user_entitlements_updated_at
  BEFORE UPDATE ON public.app_user_entitlements
  FOR EACH ROW
  EXECUTE FUNCTION public.set_app_user_entitlements_updated_at();

CREATE INDEX IF NOT EXISTS idx_app_user_entitlements_status_updated
  ON public.app_user_entitlements(status, updated_at DESC);

ALTER TABLE public.app_user_entitlements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own entitlements" ON public.app_user_entitlements;
CREATE POLICY "Users can view own entitlements"
  ON public.app_user_entitlements FOR SELECT
  USING (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "Users cannot mutate entitlements directly" ON public.app_user_entitlements;
CREATE POLICY "Users cannot mutate entitlements directly"
  ON public.app_user_entitlements FOR ALL
  USING (false)
  WITH CHECK (false);

COMMENT ON TABLE public.app_user_entitlements IS 'Canonical membership entitlements resolved from StoreKit sync and manual/admin grants.';
