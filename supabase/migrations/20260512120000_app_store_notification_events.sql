-- Ledger for verified App Store Server Notification V2 payloads.
-- Entitlements remain in public.app_user_entitlements; this table is for
-- idempotency, debugging, and audit history only.

CREATE TABLE IF NOT EXISTS public.app_store_notification_events (
  notification_uuid TEXT PRIMARY KEY,
  notification_type TEXT NOT NULL,
  subtype TEXT,
  environment TEXT,
  bundle_id TEXT,
  app_apple_id TEXT,
  product_id TEXT,
  transaction_id TEXT,
  original_transaction_id TEXT,
  user_id TEXT REFERENCES public.profiles(id) ON DELETE SET NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  processed_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_app_store_notification_events_user_processed
  ON public.app_store_notification_events(user_id, processed_at DESC);

CREATE INDEX IF NOT EXISTS idx_app_store_notification_events_original_transaction
  ON public.app_store_notification_events(original_transaction_id, processed_at DESC)
  WHERE original_transaction_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_app_store_notification_events_transaction
  ON public.app_store_notification_events(transaction_id, processed_at DESC)
  WHERE transaction_id IS NOT NULL;

ALTER TABLE public.app_store_notification_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users cannot read App Store notification ledger" ON public.app_store_notification_events;
CREATE POLICY "Users cannot read App Store notification ledger"
  ON public.app_store_notification_events FOR SELECT
  USING (false);

DROP POLICY IF EXISTS "Users cannot mutate App Store notification ledger" ON public.app_store_notification_events;
CREATE POLICY "Users cannot mutate App Store notification ledger"
  ON public.app_store_notification_events FOR ALL
  USING (false)
  WITH CHECK (false);

COMMENT ON TABLE public.app_store_notification_events IS 'Verified App Store Server Notification V2 events processed by the API service role.';
