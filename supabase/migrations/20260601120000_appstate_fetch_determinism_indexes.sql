-- Indexes backing the deterministic app-state fetch paths.
--
-- Two reads were timing out (8-12s in prod logs) and returning rows in
-- non-deterministic order, which surfaced as "completed imports randomly sorted"
-- and "sometimes no saved recipes after sign in":
--
--   1. The completed-imports history query filters
--        status IN ('saved','needs_review','draft') AND user_id = ?
--      and orders by completed_at DESC, updated_at DESC, created_at DESC, id DESC.
--      The existing partial index idx_recipe_ingestion_jobs_user_terminal_completed
--      additionally requires `recipe_id IS NOT NULL`, so it does NOT cover this
--      query (which keeps recipe-less draft/needs_review rows) -> sequential scan
--      + sort. This index drops that condition and leads with completed_at so the
--      read is an ordered index range scan.
--
--   2. Saved recipes are ordered saved_at DESC, recipe_id DESC (recipe_id is the
--      unique per-user tiebreaker). The existing idx_saved_recipes_user_saved_at
--      stops at saved_at, so equal-saved_at rows (common in migrated data) required
--      an extra sort and returned an arbitrary subset under a LIMIT. Including
--      recipe_id makes the exact ORDER BY fully index-backed and stable.

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_user_completed_history
  ON public.recipe_ingestion_jobs(
    user_id,
    completed_at DESC NULLS LAST,
    updated_at DESC,
    created_at DESC,
    id DESC
  )
  WHERE status IN ('saved', 'needs_review', 'draft');

CREATE INDEX IF NOT EXISTS idx_saved_recipes_user_saved_at_recipe_id
  ON public.saved_recipes(user_id, saved_at DESC, recipe_id DESC);
