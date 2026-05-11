-- Private storage bucket + policies for feedback attachments (photos + videos).
--
-- Path convention: <user_id>/<message_id>/<filename>.
-- The first path segment is the auth.uid() so we can use storage.foldername()
-- for tenant isolation without managing a row-per-object metadata table.

INSERT INTO storage.buckets (id, name, public)
VALUES ('feedback-attachments', 'feedback-attachments', false)
ON CONFLICT (id) DO NOTHING;

-- Users can read, upload, and delete only objects whose first path segment
-- equals their auth.uid()::text. Admin / founder access goes through the
-- service role (RLS bypassed).
DROP POLICY IF EXISTS "feedback_attachments_user_read" ON storage.objects;
CREATE POLICY "feedback_attachments_user_read"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'feedback-attachments'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "feedback_attachments_user_write" ON storage.objects;
CREATE POLICY "feedback_attachments_user_write"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'feedback-attachments'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "feedback_attachments_user_update" ON storage.objects;
CREATE POLICY "feedback_attachments_user_update"
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'feedback-attachments'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'feedback-attachments'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "feedback_attachments_user_delete" ON storage.objects;
CREATE POLICY "feedback_attachments_user_delete"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'feedback-attachments'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
