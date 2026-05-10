-- Intentionally no-op.
--
-- User media writes now go through the Render backend with bearer auth and the
-- Supabase service role. Clients should not receive direct Storage write
-- policies; backend code must force paths under users/{auth_user_id}/...
SELECT 1;
