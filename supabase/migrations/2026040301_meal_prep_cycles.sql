CREATE TABLE IF NOT EXISTS public.meal_prep_cycles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL,
  plan_id UUID NOT NULL,
  plan JSONB NOT NULL,
  generated_at TIMESTAMPTZ NOT NULL,
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  cadence TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (user_id, plan_id)
);

CREATE INDEX IF NOT EXISTS idx_meal_prep_cycles_user_generated_at
  ON public.meal_prep_cycles(user_id, generated_at DESC);

CREATE OR REPLACE FUNCTION public.set_meal_prep_cycles_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_meal_prep_cycles_updated_at ON public.meal_prep_cycles;
CREATE TRIGGER trg_meal_prep_cycles_updated_at
  BEFORE UPDATE ON public.meal_prep_cycles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_meal_prep_cycles_updated_at();

ALTER TABLE public.meal_prep_cycles DISABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.meal_prep_cycles TO anon, authenticated;
