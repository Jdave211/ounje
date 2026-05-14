-- Make APNs token registration and push fanout explicit for server-side code.
-- The Node API writes device_tokens and app_notification_events with the
-- Supabase service role, so do not rely on project default privileges.

GRANT SELECT, INSERT, UPDATE, DELETE ON public.device_tokens TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.app_notification_events TO service_role;
