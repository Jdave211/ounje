-- Public buckets can serve objects by URL without broad storage.objects SELECT
-- policies. Writes now go through the backend service role, so remove direct
-- client insert/list policies.

DROP POLICY IF EXISTS "Anon insert recipe_images" ON storage.objects;
DROP POLICY IF EXISTS "Public read recipe-images" ON storage.objects;
DROP POLICY IF EXISTS "Public read recipe_images" ON storage.objects;
