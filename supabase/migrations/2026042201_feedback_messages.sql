-- Feedback thread messages

CREATE TABLE IF NOT EXISTS app_feedback_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  author_role TEXT NOT NULL CHECK (author_role IN ('user', 'system', 'founder')),
  body TEXT NOT NULL DEFAULT '',
  attachments JSONB NOT NULL DEFAULT '[]'::jsonb,
  email_forward_target TEXT,
  email_forward_transport TEXT,
  email_forward_requested_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_app_feedback_messages_user_created
  ON app_feedback_messages(user_id, created_at ASC);

ALTER TABLE app_feedback_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own feedback messages" ON app_feedback_messages;
CREATE POLICY "Users can view own feedback messages"
  ON app_feedback_messages FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own feedback messages" ON app_feedback_messages;
CREATE POLICY "Users can insert own feedback messages"
  ON app_feedback_messages FOR INSERT
  WITH CHECK (auth.uid() = user_id);

COMMENT ON TABLE app_feedback_messages IS 'User-scoped feedback thread entries between Ounje users and the product team.';
