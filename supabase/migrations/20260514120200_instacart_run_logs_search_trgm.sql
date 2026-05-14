-- The instacart run-log list endpoint supports a free-text search via
-- `.ilike("search_text", "%term%")` (server/lib/instacart-run-logs.js).
-- Without a trigram index, ilike with leading/trailing wildcards forces a
-- sequential scan of run logs per user. As history grows the search mode
-- becomes the slowest path of an already chatty endpoint.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_instacart_run_logs_search_text_trgm
  ON public.instacart_run_logs
  USING GIN (search_text gin_trgm_ops)
  WHERE search_text IS NOT NULL;
