-- Extend the notification kind enum and add the device_tokens table for APNs.
--
-- Why:
--   * grocery_cart_partial is referenced in server/api/v1/instacart.js but was
--     never added to the enum → the row insert quietly fails and the user gets
--     no notification for partial cart failures.
--   * recipe_import_* and autoshop_* kinds are needed for the new push events
--     we are wiring up.
--   * device_tokens stores APNs tokens per (user, device) so the server can
--     push to backgrounded / killed apps.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. New enum values. ADD VALUE IF NOT EXISTS is safe inside a transaction
--    block on Postgres 12+ (Supabase runs 15+).
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TYPE app_notification_kind ADD VALUE IF NOT EXISTS 'grocery_cart_partial';
ALTER TYPE app_notification_kind ADD VALUE IF NOT EXISTS 'recipe_import_queued';
ALTER TYPE app_notification_kind ADD VALUE IF NOT EXISTS 'recipe_import_completed';
ALTER TYPE app_notification_kind ADD VALUE IF NOT EXISTS 'recipe_import_failed';
ALTER TYPE app_notification_kind ADD VALUE IF NOT EXISTS 'autoshop_started';
ALTER TYPE app_notification_kind ADD VALUE IF NOT EXISTS 'autoshop_completed';
ALTER TYPE app_notification_kind ADD VALUE IF NOT EXISTS 'autoshop_failed';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. device_tokens table.
--    Primary key on (user_id, token) so the same physical device that signs in
--    as a different user gets its own row. Apple rotates tokens periodically
--    so last_seen_at lets us prune stale entries.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.device_tokens (
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token        TEXT NOT NULL,
  platform     TEXT NOT NULL DEFAULT 'ios'
                 CHECK (platform IN ('ios', 'ipad', 'macos')),
  environment  TEXT NOT NULL DEFAULT 'production'
                 CHECK (environment IN ('sandbox', 'production')),
  app_version  TEXT,
  device_model TEXT,
  os_version   TEXT,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (user_id, token)
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_user_last_seen
  ON public.device_tokens(user_id, last_seen_at DESC);

CREATE INDEX IF NOT EXISTS idx_device_tokens_token
  ON public.device_tokens(token);

ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

-- Users can see their own registered devices (useful if we ever expose a
-- "where am I signed in" UI). All writes are gated to the service role —
-- the Node API is the only authoritative writer.
DROP POLICY IF EXISTS "device_tokens_select_own" ON public.device_tokens;
CREATE POLICY "device_tokens_select_own"
  ON public.device_tokens
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "device_tokens_no_client_write" ON public.device_tokens;
CREATE POLICY "device_tokens_no_client_write"
  ON public.device_tokens
  FOR ALL
  USING (false)
  WITH CHECK (false);

REVOKE ALL ON public.device_tokens FROM anon, authenticated;
GRANT SELECT ON public.device_tokens TO authenticated;

COMMENT ON TABLE public.device_tokens IS
  'APNs device tokens per (user, device). Written by the Node API via service role on /v1/push-tokens/register; read by the APNs sender to fan out push payloads.';
