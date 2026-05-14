-- Extra hot-path composite indexes for the current app access patterns.
-- These target filters + ordering that single-column indexes cannot satisfy well.

-- Imported recipe history and duplicate lookups sort terminal jobs by completion.
CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_user_terminal_completed
  ON public.recipe_ingestion_jobs(
    user_id,
    completed_at DESC NULLS LAST,
    saved_at DESC NULLS LAST,
    updated_at DESC,
    created_at DESC
  )
  WHERE status IN ('saved', 'draft', 'needs_review')
    AND recipe_id IS NOT NULL;

-- Active cart/order checks are user-scoped, status-filtered, and newest-first.
CREATE INDEX IF NOT EXISTS idx_grocery_orders_user_status_created_desc
  ON public.grocery_orders(user_id, status, created_at DESC);

-- Provider status checks use both user_id and provider; the unique constraint
-- exists in older migrations but this named index keeps plans stable if schema
-- drift removed or renamed it.
CREATE INDEX IF NOT EXISTS idx_user_provider_accounts_user_provider
  ON public.user_provider_accounts(user_id, provider);

-- Current Instacart activity is looked up by user/status and newest started/created.
CREATE INDEX IF NOT EXISTS idx_instacart_run_logs_user_status_created_desc
  ON public.instacart_run_logs(user_id, status_kind, created_at DESC);

-- Some prep refresh paths order by updated_at rather than generated_at.
CREATE INDEX IF NOT EXISTS idx_meal_prep_cycles_user_updated_at
  ON public.meal_prep_cycles(user_id, updated_at DESC);

-- Looking up the cycle for a specific cart/order is user_id + plan_id.
CREATE INDEX IF NOT EXISTS idx_meal_prep_cycles_user_plan_generated
  ON public.meal_prep_cycles(user_id, plan_id, generated_at DESC);
