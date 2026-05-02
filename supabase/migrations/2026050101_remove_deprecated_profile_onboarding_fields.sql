-- Remove profile fields that are no longer collected during onboarding.
ALTER TABLE public.profiles
  DROP COLUMN IF EXISTS meal_prep_goals,
  DROP COLUMN IF EXISTS budget_flexibility,
  DROP COLUMN IF EXISTS kitchen_equipment;

UPDATE public.profiles
SET profile_json = profile_json
  - 'mealPrepGoals'
  - 'budgetFlexibility'
  - 'kitchenEquipment'
WHERE profile_json IS NOT NULL;
