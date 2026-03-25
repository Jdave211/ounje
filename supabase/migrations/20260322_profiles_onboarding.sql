-- Expand profiles from a simple onboarding flag into the full onboarding persistence record.
CREATE TABLE IF NOT EXISTS public.profiles (
  id TEXT PRIMARY KEY,
  email TEXT,
  display_name TEXT,
  auth_provider TEXT,
  onboarded BOOLEAN NOT NULL DEFAULT FALSE,
  onboarding_completed_at TIMESTAMPTZ,
  last_onboarding_step INTEGER NOT NULL DEFAULT 0,
  preferred_name TEXT,
  preferred_cuisines TEXT[] NOT NULL DEFAULT '{}',
  cuisine_countries TEXT[] NOT NULL DEFAULT '{}',
  dietary_patterns TEXT[] NOT NULL DEFAULT '{}',
  hard_restrictions TEXT[] NOT NULL DEFAULT '{}',
  meal_prep_goals TEXT[] NOT NULL DEFAULT '{}',
  cadence TEXT,
  delivery_anchor_day TEXT,
  adults INTEGER,
  kids INTEGER,
  cooks_for_others BOOLEAN NOT NULL DEFAULT FALSE,
  meals_per_week INTEGER,
  budget_per_cycle NUMERIC(10, 2),
  budget_window TEXT,
  budget_flexibility TEXT,
  ordering_autonomy TEXT,
  kitchen_equipment TEXT[] NOT NULL DEFAULT '{}',
  address_line1 TEXT,
  address_line2 TEXT,
  city TEXT,
  region TEXT,
  postal_code TEXT,
  delivery_notes TEXT,
  profile_json JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS email TEXT,
  ADD COLUMN IF NOT EXISTS display_name TEXT,
  ADD COLUMN IF NOT EXISTS auth_provider TEXT,
  ADD COLUMN IF NOT EXISTS onboarded BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS onboarding_completed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_onboarding_step INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS preferred_name TEXT,
  ADD COLUMN IF NOT EXISTS preferred_cuisines TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS cuisine_countries TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS dietary_patterns TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS hard_restrictions TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS meal_prep_goals TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS cadence TEXT,
  ADD COLUMN IF NOT EXISTS delivery_anchor_day TEXT,
  ADD COLUMN IF NOT EXISTS adults INTEGER,
  ADD COLUMN IF NOT EXISTS kids INTEGER,
  ADD COLUMN IF NOT EXISTS cooks_for_others BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS meals_per_week INTEGER,
  ADD COLUMN IF NOT EXISTS budget_per_cycle NUMERIC(10, 2),
  ADD COLUMN IF NOT EXISTS budget_window TEXT,
  ADD COLUMN IF NOT EXISTS budget_flexibility TEXT,
  ADD COLUMN IF NOT EXISTS ordering_autonomy TEXT,
  ADD COLUMN IF NOT EXISTS kitchen_equipment TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS address_line1 TEXT,
  ADD COLUMN IF NOT EXISTS address_line2 TEXT,
  ADD COLUMN IF NOT EXISTS city TEXT,
  ADD COLUMN IF NOT EXISTS region TEXT,
  ADD COLUMN IF NOT EXISTS postal_code TEXT,
  ADD COLUMN IF NOT EXISTS delivery_notes TEXT,
  ADD COLUMN IF NOT EXISTS profile_json JSONB,
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now());

CREATE OR REPLACE FUNCTION public.set_profiles_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_profiles_updated_at();

ALTER TABLE public.profiles DISABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.profiles TO anon, authenticated;
