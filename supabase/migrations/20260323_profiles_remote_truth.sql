ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS auth_provider TEXT,
  ADD COLUMN IF NOT EXISTS last_onboarding_step INTEGER NOT NULL DEFAULT 0;

UPDATE public.profiles
SET last_onboarding_step = 7
WHERE onboarded = TRUE
  AND COALESCE(last_onboarding_step, 0) < 7;
