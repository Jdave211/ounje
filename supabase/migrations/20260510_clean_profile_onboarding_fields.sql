-- Onboarding schema cleanup
-- 1. Remove dedicated scalar columns that are no longer actively collected in
--    the onboarding flow and are fully redundant with profile_json.
--    * preferred_cuisines — the .cuisines step is excluded from allCases; users
--      keep starter defaults; the full cuisine list lives in profile_json.
--    * cuisine_countries — same reasoning.
ALTER TABLE public.profiles
  DROP COLUMN IF EXISTS preferred_cuisines,
  DROP COLUMN IF EXISTS cuisine_countries;

-- 2. Add clean, first-class columns for onboarding signals that ARE actively
--    collected but were previously buried inside the profile_json blob.
--    * food_persona  — identity persona chosen on the "What best describes you?" step
--                      (e.g. "student", "parent", "home cook")
--    * food_goals    — food goals / challenges selected on the "Food goals" step
--                      (e.g. {"Save money", "Eat healthier", "Spend less time cooking"})
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS food_persona TEXT,
  ADD COLUMN IF NOT EXISTS food_goals   TEXT[] NOT NULL DEFAULT '{}';

-- 3. Backfill food_persona / food_goals from profile_json for existing rows.
--    The onboarding view stores these as the first element of mealPrepGoals in
--    the format "Describes me: <persona>" and "Food goals: <g1>; <g2>; ...".
--    We extract them defensively so malformed JSON just leaves the columns null/empty.
UPDATE public.profiles
SET
  food_persona = CASE
    WHEN profile_json IS NOT NULL
         AND (profile_json -> 'mealPrepGoals') IS NOT NULL
    THEN (
      SELECT trim(substring(elem FROM 'Describes me: (.+)'))
      FROM jsonb_array_elements_text(profile_json -> 'mealPrepGoals') AS elem
      WHERE elem LIKE 'Describes me: %'
      LIMIT 1
    )
    ELSE NULL
  END,
  food_goals = CASE
    WHEN profile_json IS NOT NULL
         AND (profile_json -> 'mealPrepGoals') IS NOT NULL
    THEN (
      SELECT COALESCE(
        string_to_array(
          trim(substring(elem FROM 'Food goals: (.+)')),
          '; '
        ),
        '{}'::TEXT[]
      )
      FROM jsonb_array_elements_text(profile_json -> 'mealPrepGoals') AS elem
      WHERE elem LIKE 'Food goals: %'
      LIMIT 1
    )
    ELSE '{}'::TEXT[]
  END
WHERE profile_json IS NOT NULL;

-- 4. Index food_persona for potential future segment queries.
CREATE INDEX IF NOT EXISTS idx_profiles_food_persona
  ON public.profiles (food_persona)
  WHERE food_persona IS NOT NULL;
