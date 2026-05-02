-- Repair profiles that reached the final onboarding step but were left marked
-- not onboarded by a racing draft save.
UPDATE public.profiles
SET onboarded = TRUE,
    onboarding_completed_at = COALESCE(onboarding_completed_at, updated_at, timezone('utc', now())),
    last_onboarding_step = GREATEST(COALESCE(last_onboarding_step, 0), 7)
WHERE onboarded IS NOT TRUE
  AND profile_json IS NOT NULL
  AND COALESCE(last_onboarding_step, 0) >= 7;
