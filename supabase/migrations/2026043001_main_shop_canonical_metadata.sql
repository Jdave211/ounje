-- Store backend canonicalization coverage on main-shop rows.
-- base_cart_items remains the detailed source record linked to these rows.

ALTER TABLE public.main_shop_items
  ADD COLUMN IF NOT EXISTS source_ingredients JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS source_edge_ids TEXT[] NOT NULL DEFAULT '{}'::text[],
  ADD COLUMN IF NOT EXISTS reconciliation_meta JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_main_shop_items_source_edge_ids
  ON public.main_shop_items USING GIN (source_edge_ids);
