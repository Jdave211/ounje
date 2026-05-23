-- Reduce per-row RLS auth function evaluation.
--
-- Supabase's performance advisor flags policies that call auth.uid() directly
-- because Postgres may re-evaluate the function per row. Wrapping it in a
-- SELECT turns it into an initPlan value evaluated once per statement while
-- preserving the same authorization behavior.

DO $$
DECLARE
  policy record;
  new_qual text;
  new_with_check text;
  statement text;
BEGIN
  FOR policy IN
    SELECT schemaname, tablename, policyname, qual, with_check
    FROM pg_policies
    WHERE schemaname = 'public'
      AND (
        qual LIKE '%auth.uid()%'
        OR with_check LIKE '%auth.uid()%'
        OR qual LIKE '%auth.jwt()%'
        OR with_check LIKE '%auth.jwt()%'
      )
  LOOP
    new_qual := replace(
      replace(policy.qual, 'auth.uid()', '(select auth.uid())'),
      'auth.jwt()',
      '(select auth.jwt())'
    );
    new_with_check := replace(
      replace(policy.with_check, 'auth.uid()', '(select auth.uid())'),
      'auth.jwt()',
      '(select auth.jwt())'
    );

    statement := format(
      'ALTER POLICY %I ON %I.%I',
      policy.policyname,
      policy.schemaname,
      policy.tablename
    );

    IF new_qual IS NOT NULL THEN
      statement := statement || format(' USING (%s)', new_qual);
    END IF;

    IF new_with_check IS NOT NULL THEN
      statement := statement || format(' WITH CHECK (%s)', new_with_check);
    END IF;

    EXECUTE statement;
  END LOOP;
END $$;

-- Keep the explicitly named HNSW index and remove the duplicate copy.
DROP INDEX IF EXISTS public.idx_recipes_embedding_basic;
