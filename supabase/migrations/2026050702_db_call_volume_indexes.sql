-- High-volume API indexes for launch traffic.
--
-- For production, prefer applying the CREATE INDEX statements with
-- CONCURRENTLY from psql/SQL editor autocommit mode. Supabase migration
-- runners may wrap files in a transaction, so this migration intentionally
-- avoids CONCURRENTLY for compatibility.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_recipes_updated_published_desc
  ON public.recipes (updated_at DESC NULLS LAST, published_date DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_recipe_ingredients_display_name_trgm_notnull_image
  ON public.recipe_ingredients USING gin (display_name gin_trgm_ops)
  WHERE image_url IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recipe_ingredients_ingredient_id_notnull_image
  ON public.recipe_ingredients (ingredient_id ASC)
  WHERE image_url IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_grocery_orders_user_created_desc
  ON public.grocery_orders (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_app_notification_events_user_undelivered_scheduled_asc
  ON public.app_notification_events (user_id, scheduled_for ASC)
  WHERE delivered_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_instacart_run_logs_user_completed_started
  ON public.instacart_run_logs (
    user_id,
    completed_at DESC NULLS FIRST,
    started_at DESC NULLS LAST
  );

-- Claim RPC should already be locked down by
-- 2026050402_recipe_ingestion_vm_worker_claims.sql. Keep this here so a
-- partial migration replay cannot accidentally re-expose worker claims.
REVOKE ALL ON FUNCTION public.claim_recipe_ingestion_jobs(text, integer, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_recipe_ingestion_jobs(text, integer, timestamptz) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_recipe_ingestion_jobs(text, integer, timestamptz) TO service_role;
