ALTER TABLE public.meal_prep_automation_state
  ADD COLUMN IF NOT EXISTS autoshop_enabled BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS autoshop_lead_days INTEGER NOT NULL DEFAULT 1 CHECK (autoshop_lead_days BETWEEN 0 AND 7),
  ADD COLUMN IF NOT EXISTS next_prep_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS next_cart_sync_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_cart_sync_trigger TEXT,
  ADD COLUMN IF NOT EXISTS last_instacart_retry_queued_for_run_id TEXT,
  ADD COLUMN IF NOT EXISTS last_instacart_retry_queued_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_meal_prep_automation_state_autoshop_due
  ON public.meal_prep_automation_state(next_cart_sync_at, autoshop_enabled)
  WHERE autoshop_enabled = true;
