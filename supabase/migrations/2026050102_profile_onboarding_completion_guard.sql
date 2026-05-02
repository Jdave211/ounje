-- Completed onboarding should be monotonic. Draft writes can race final writes from
-- mobile clients, so the database must reject true -> false downgrades.
CREATE OR REPLACE FUNCTION public.prevent_profile_onboarding_downgrade()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.onboarded IS TRUE AND NEW.onboarded IS NOT TRUE THEN
    NEW.onboarded = TRUE;
    NEW.onboarding_completed_at = COALESCE(OLD.onboarding_completed_at, NEW.onboarding_completed_at, timezone('utc', now()));
  END IF;

  IF OLD.onboarded IS TRUE THEN
    NEW.last_onboarding_step = GREATEST(COALESCE(NEW.last_onboarding_step, 0), COALESCE(OLD.last_onboarding_step, 0));
  END IF;

  IF NEW.onboarded IS TRUE AND NEW.onboarding_completed_at IS NULL THEN
    NEW.onboarding_completed_at = timezone('utc', now());
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_profiles_prevent_onboarding_downgrade ON public.profiles;
CREATE TRIGGER trg_profiles_prevent_onboarding_downgrade
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_profile_onboarding_downgrade();
