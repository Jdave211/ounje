-- Profile bootstrapping and schema cleanup.
--
-- Problem this fixes:
--   * auth.users rows did not automatically get a public.profiles row. If the
--     iOS client's bootstrap upsert failed (network, RLS, app crash) the user
--     could sign up, enter the app, and never appear in profiles. Downstream,
--     app_user_entitlements.user_id REFERENCES profiles(id) — the FK silently
--     blocks entitlement upserts and subscription tracking never updates.
--
-- Strategy:
--   1. AFTER INSERT trigger on auth.users → insert a stub profiles row.
--   2. Backfill existing auth.users that have no profile.
--   3. Drop delivery_time_minutes (never written by SupabaseProfileUpsertPayload
--      — live value lives in profile_json.deliveryTimeMinutes).
--   4. Index profiles.email for the recovery / merge lookup path.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Auto-create profile on signup
-- ─────────────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER + explicit search_path so the function can write to
-- public.profiles regardless of the calling user's RLS context. The trigger
-- fires under auth schema's permissions during signup, where auth.uid() is
-- typically null.
CREATE OR REPLACE FUNCTION public.create_profile_for_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email        TEXT;
  v_display_name TEXT;
  v_provider     TEXT;
BEGIN
  v_email := COALESCE(NEW.email, '');
  v_display_name := COALESCE(
    NEW.raw_user_meta_data ->> 'full_name',
    NEW.raw_user_meta_data ->> 'name',
    NEW.raw_user_meta_data ->> 'display_name',
    split_part(v_email, '@', 1)
  );
  v_provider := COALESCE(
    NEW.raw_app_meta_data ->> 'provider',
    'unknown'
  );

  INSERT INTO public.profiles (
    id,
    email,
    display_name,
    auth_provider,
    onboarded,
    last_onboarding_step,
    created_at,
    updated_at
  ) VALUES (
    NEW.id::text,
    NULLIF(v_email, ''),
    NULLIF(v_display_name, ''),
    v_provider,
    false,
    0,
    timezone('utc', now()),
    timezone('utc', now())
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_create_profile_for_new_user ON auth.users;
CREATE TRIGGER trg_create_profile_for_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.create_profile_for_new_user();

COMMENT ON FUNCTION public.create_profile_for_new_user IS
  'Auto-creates a public.profiles stub row on auth.users insert so downstream FKs (app_user_entitlements, etc.) never fail silently because the profile is missing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backfill missing profiles for existing auth users
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.profiles (
  id, email, display_name, auth_provider, onboarded, last_onboarding_step,
  created_at, updated_at
)
SELECT
  u.id::text,
  NULLIF(COALESCE(u.email, ''), ''),
  NULLIF(
    COALESCE(
      u.raw_user_meta_data ->> 'full_name',
      u.raw_user_meta_data ->> 'name',
      u.raw_user_meta_data ->> 'display_name',
      split_part(COALESCE(u.email, ''), '@', 1)
    ),
    ''
  ),
  COALESCE(u.raw_app_meta_data ->> 'provider', 'unknown'),
  false,
  0,
  COALESCE(u.created_at, timezone('utc', now())),
  timezone('utc', now())
FROM auth.users u
LEFT JOIN public.profiles p ON p.id = u.id::text
WHERE p.id IS NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Drop legacy column delivery_time_minutes (unused in client payload)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.profiles DROP COLUMN IF EXISTS delivery_time_minutes;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Index for case-insensitive email recovery lookups
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_profiles_email_lower
  ON public.profiles (lower(email))
  WHERE email IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Self-documenting comments on the columns we want to keep visible
--    (these become tooltips in the Supabase dashboard).
-- ─────────────────────────────────────────────────────────────────────────────
COMMENT ON COLUMN public.profiles.food_persona      IS 'Identity persona from the onboarding "Describes me" step (student / parent / home cook / …).';
COMMENT ON COLUMN public.profiles.food_goals        IS 'Food goals selected on the onboarding "What slows you down" step (array of human-readable goals).';
COMMENT ON COLUMN public.profiles.dietary_patterns  IS 'Diet patterns from the onboarding "Diets" step (vegetarian, keto, …).';
COMMENT ON COLUMN public.profiles.hard_restrictions IS 'Absolute restrictions = allergies + hard restrictions + never-include items, deduplicated.';
COMMENT ON COLUMN public.profiles.profile_json      IS 'Canonical structured UserProfile blob — preferences, cuisines, consumption, allergies, addresses, tier signals.';
COMMENT ON COLUMN public.profiles.account_status    IS 'active | deactivated. Server-written when the user requests account deletion.';
COMMENT ON COLUMN public.profiles.onboarded         IS 'True once the user finishes the full first-login onboarding flow. Source of truth for client gating.';
