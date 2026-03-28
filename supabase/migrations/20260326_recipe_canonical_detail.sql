alter table if exists recipes
  add column if not exists ingredients_json jsonb,
  add column if not exists steps_json jsonb,
  add column if not exists servings_count integer;
