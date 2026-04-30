CREATE TABLE IF NOT EXISTS public.prep_recurring_recipes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recipe_id TEXT NOT NULL,
  recipe_title TEXT NOT NULL,
  recipe JSONB NOT NULL,
  is_enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (user_id, recipe_id)
);

CREATE INDEX IF NOT EXISTS idx_prep_recurring_recipes_user_updated
  ON public.prep_recurring_recipes(user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS public.meal_prep_automation_state (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  last_evaluated_at TIMESTAMPTZ,
  next_planning_window_at TIMESTAMPTZ,
  last_generated_for_delivery_at TIMESTAMPTZ,
  last_generated_plan_id UUID,
  last_generated_reason TEXT,
  last_cart_sync_for_delivery_at TIMESTAMPTZ,
  last_cart_sync_plan_id UUID,
  last_cart_signature TEXT,
  last_instacart_run_id TEXT,
  last_instacart_run_status TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

CREATE OR REPLACE FUNCTION public.set_prep_recurring_recipes_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prep_recurring_recipes_updated_at ON public.prep_recurring_recipes;
CREATE TRIGGER trg_prep_recurring_recipes_updated_at
  BEFORE UPDATE ON public.prep_recurring_recipes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_prep_recurring_recipes_updated_at();

CREATE OR REPLACE FUNCTION public.set_meal_prep_automation_state_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_meal_prep_automation_state_updated_at ON public.meal_prep_automation_state;
CREATE TRIGGER trg_meal_prep_automation_state_updated_at
  BEFORE UPDATE ON public.meal_prep_automation_state
  FOR EACH ROW
  EXECUTE FUNCTION public.set_meal_prep_automation_state_updated_at();

ALTER TABLE public.prep_recurring_recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_prep_automation_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own recurring prep recipes" ON public.prep_recurring_recipes;
CREATE POLICY "Users can view own recurring prep recipes"
  ON public.prep_recurring_recipes
  FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own recurring prep recipes" ON public.prep_recurring_recipes;
CREATE POLICY "Users can insert own recurring prep recipes"
  ON public.prep_recurring_recipes
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own recurring prep recipes" ON public.prep_recurring_recipes;
CREATE POLICY "Users can update own recurring prep recipes"
  ON public.prep_recurring_recipes
  FOR UPDATE
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own recurring prep recipes" ON public.prep_recurring_recipes;
CREATE POLICY "Users can delete own recurring prep recipes"
  ON public.prep_recurring_recipes
  FOR DELETE
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can view own meal prep automation state" ON public.meal_prep_automation_state;
CREATE POLICY "Users can view own meal prep automation state"
  ON public.meal_prep_automation_state
  FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own meal prep automation state" ON public.meal_prep_automation_state;
CREATE POLICY "Users can insert own meal prep automation state"
  ON public.meal_prep_automation_state
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own meal prep automation state" ON public.meal_prep_automation_state;
CREATE POLICY "Users can update own meal prep automation state"
  ON public.meal_prep_automation_state
  FOR UPDATE
  USING (auth.uid() = user_id);
