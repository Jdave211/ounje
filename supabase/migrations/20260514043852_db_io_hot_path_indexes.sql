-- Add indexes for the read paths currently timing out under IO pressure.
-- The imported recipe detail tables already had these indexes; the public
-- recipe detail tables did not, even though recipe detail opens query them
-- directly by recipe_id and then sort.

CREATE INDEX IF NOT EXISTS idx_recipe_ingredients_recipe_sort
  ON public.recipe_ingredients(recipe_id, sort_order ASC);

CREATE INDEX IF NOT EXISTS idx_recipe_steps_recipe_step
  ON public.recipe_steps(recipe_id, step_number ASC);

CREATE INDEX IF NOT EXISTS idx_recipe_step_ingredients_step_sort
  ON public.recipe_step_ingredients(recipe_step_id, sort_order ASC);

-- Bootstrap/import status reads sort a user's recent ingestion jobs by
-- updated_at and also count completed-ish rows by status.
CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_user_updated_at
  ON public.recipe_ingestion_jobs(user_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_user_status_updated_at
  ON public.recipe_ingestion_jobs(user_id, status, updated_at DESC);

-- Keep the worker claim RPC on narrow partial indexes instead of scanning
-- every historical ingestion job during each poll.
CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_claim_ready
  ON public.recipe_ingestion_jobs(queued_at ASC)
  WHERE status IN ('queued', 'retryable');

CREATE INDEX IF NOT EXISTS idx_recipe_ingestion_jobs_claim_stale
  ON public.recipe_ingestion_jobs(leased_at ASC)
  WHERE status IN ('processing', 'fetching', 'parsing', 'normalized')
    AND leased_at IS NOT NULL;

-- Bootstrap cart counts filter by user_id only. Existing cart indexes are
-- user_id + plan_id, which cannot fully serve user-level counts.
CREATE INDEX IF NOT EXISTS idx_main_shop_items_user_id
  ON public.main_shop_items(user_id);

CREATE INDEX IF NOT EXISTS idx_base_cart_items_user_id
  ON public.base_cart_items(user_id);
