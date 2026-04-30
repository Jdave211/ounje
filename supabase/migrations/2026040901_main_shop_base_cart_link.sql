-- Normalize cart persistence:
-- - main_shop_items = canonical rows shown in Main shop
-- - base_cart_items = raw grocery/base-cart rows
-- Every base_cart_items row MUST reference a main_shop_items primary key.

CREATE TABLE IF NOT EXISTS public.main_shop_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL,
  plan_id UUID NOT NULL,
  canonical_key TEXT NOT NULL,
  name TEXT NOT NULL,
  quantity_text TEXT NOT NULL DEFAULT '',
  supporting_text TEXT,
  image_url TEXT,
  estimated_price_text TEXT,
  estimated_price_value DOUBLE PRECISION NOT NULL DEFAULT 0,
  section_kind INTEGER,
  removal_key TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_main_shop_items_user_plan_canonical
  ON public.main_shop_items(user_id, plan_id, canonical_key);

-- Needed for composite FK enforcement from base_cart_items.
CREATE UNIQUE INDEX IF NOT EXISTS idx_main_shop_items_id_user_plan
  ON public.main_shop_items(id, user_id, plan_id);

CREATE INDEX IF NOT EXISTS idx_main_shop_items_user_plan
  ON public.main_shop_items(user_id, plan_id);

CREATE TABLE IF NOT EXISTS public.base_cart_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL,
  plan_id UUID NOT NULL,
  grocery_key TEXT NOT NULL,
  name TEXT NOT NULL,
  amount DOUBLE PRECISION NOT NULL DEFAULT 0,
  unit TEXT NOT NULL DEFAULT '',
  estimated_price DOUBLE PRECISION NOT NULL DEFAULT 0,
  source_ingredients JSONB NOT NULL DEFAULT '[]'::jsonb,
  main_shop_item_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_base_cart_items_user_plan_grocery_key
  ON public.base_cart_items(user_id, plan_id, grocery_key);

CREATE INDEX IF NOT EXISTS idx_base_cart_items_user_plan
  ON public.base_cart_items(user_id, plan_id);

CREATE INDEX IF NOT EXISTS idx_base_cart_items_main_shop_item_id
  ON public.base_cart_items(main_shop_item_id);

DO $$
BEGIN
  ALTER TABLE public.base_cart_items
    ADD CONSTRAINT base_cart_items_main_shop_fk
    FOREIGN KEY (main_shop_item_id, user_id, plan_id)
    REFERENCES public.main_shop_items (id, user_id, plan_id)
    ON DELETE CASCADE;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;

CREATE OR REPLACE FUNCTION public.set_main_shop_items_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_base_cart_items_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_main_shop_items_updated_at ON public.main_shop_items;
CREATE TRIGGER trg_main_shop_items_updated_at
  BEFORE UPDATE ON public.main_shop_items
  FOR EACH ROW
  EXECUTE FUNCTION public.set_main_shop_items_updated_at();

DROP TRIGGER IF EXISTS trg_base_cart_items_updated_at ON public.base_cart_items;
CREATE TRIGGER trg_base_cart_items_updated_at
  BEFORE UPDATE ON public.base_cart_items
  FOR EACH ROW
  EXECUTE FUNCTION public.set_base_cart_items_updated_at();

ALTER TABLE public.main_shop_items DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.base_cart_items DISABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.main_shop_items TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.base_cart_items TO anon, authenticated;

