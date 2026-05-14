-- Feedback chat hot path.
-- The primary thread query is user-scoped and ordered oldest-first. The older
-- index covers this already, but adding id as a tie-breaker keeps pagination
-- and repeated same-timestamp rows deterministic.
CREATE INDEX IF NOT EXISTS idx_app_feedback_messages_user_created_id
  ON public.app_feedback_messages (user_id, created_at ASC, id ASC);

-- The feedback fallback reads hidden "shadow" rows from app_notification_events
-- with `metadata @> {"feedback_thread": true}`. Without this partial index,
-- Postgres has to scan a user's notification history and evaluate JSONB rows.
CREATE INDEX IF NOT EXISTS idx_app_notification_feedback_shadow_user_created
  ON public.app_notification_events (user_id, created_at ASC, id ASC)
  WHERE metadata @> '{"feedback_thread": true}'::jsonb;
