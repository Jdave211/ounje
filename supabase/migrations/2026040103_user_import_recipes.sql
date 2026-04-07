CREATE TABLE IF NOT EXISTS public.user_import_recipes (
  id text PRIMARY KEY,
  user_id text NOT NULL,
  source_job_id text REFERENCES public.recipe_ingestion_jobs(id) ON DELETE SET NULL,
  dedupe_key text,
  title text NOT NULL,
  description text,
  author_name text,
  author_handle text,
  author_url text,
  source text,
  source_platform text,
  category text,
  subcategory text,
  recipe_type text,
  skill_level text,
  cook_time_text text,
  servings_text text,
  serving_size_text text,
  daily_diet_text text,
  est_cost_text text,
  est_calories_text text,
  carbs_text text,
  protein_text text,
  fats_text text,
  calories_kcal numeric,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  prep_time_minutes integer,
  cook_time_minutes integer,
  hero_image_url text,
  discover_card_image_url text,
  recipe_url text,
  original_recipe_url text,
  attached_video_url text,
  detail_footnote text,
  image_caption text,
  dietary_tags text[] NOT NULL DEFAULT '{}'::text[],
  flavor_tags text[] NOT NULL DEFAULT '{}'::text[],
  cuisine_tags text[] NOT NULL DEFAULT '{}'::text[],
  occasion_tags text[] NOT NULL DEFAULT '{}'::text[],
  main_protein text,
  cook_method text,
  published_date text,
  ingredients_text text,
  instructions_text text,
  ingredients_json jsonb NOT NULL DEFAULT '[]'::jsonb,
  steps_json jsonb NOT NULL DEFAULT '[]'::jsonb,
  servings_count integer,
  review_state text NOT NULL DEFAULT 'pending',
  confidence_score numeric(5, 4),
  quality_flags text[] NOT NULL DEFAULT '{}'::text[],
  accepted_recipe_id text,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_user_import_recipes_user_created_at
  ON public.user_import_recipes(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_import_recipes_user_updated_at
  ON public.user_import_recipes(user_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_import_recipes_source_job_id
  ON public.user_import_recipes(source_job_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_import_recipes_user_dedupe_key
  ON public.user_import_recipes(user_id, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.user_import_recipe_ingredients (
  id text PRIMARY KEY,
  recipe_id text NOT NULL REFERENCES public.user_import_recipes(id) ON DELETE CASCADE,
  ingredient_id text,
  display_name text NOT NULL,
  quantity_text text,
  image_url text,
  sort_order integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_user_import_recipe_ingredients_recipe_sort
  ON public.user_import_recipe_ingredients(recipe_id, sort_order ASC);

CREATE TABLE IF NOT EXISTS public.user_import_recipe_steps (
  id text PRIMARY KEY,
  recipe_id text NOT NULL REFERENCES public.user_import_recipes(id) ON DELETE CASCADE,
  step_number integer NOT NULL,
  instruction_text text NOT NULL,
  tip_text text,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_user_import_recipe_steps_recipe_step
  ON public.user_import_recipe_steps(recipe_id, step_number ASC);

CREATE TABLE IF NOT EXISTS public.user_import_recipe_step_ingredients (
  id text PRIMARY KEY,
  recipe_step_id text NOT NULL REFERENCES public.user_import_recipe_steps(id) ON DELETE CASCADE,
  ingredient_id text,
  display_name text NOT NULL,
  quantity_text text,
  sort_order integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS idx_user_import_recipe_step_ingredients_step_sort
  ON public.user_import_recipe_step_ingredients(recipe_step_id, sort_order ASC);

CREATE OR REPLACE FUNCTION public.set_user_import_recipes_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_import_recipes_updated_at ON public.user_import_recipes;
CREATE TRIGGER trg_user_import_recipes_updated_at
  BEFORE UPDATE ON public.user_import_recipes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_user_import_recipes_updated_at();

ALTER TABLE public.user_import_recipes DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_import_recipe_ingredients DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_import_recipe_steps DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_import_recipe_step_ingredients DISABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_import_recipes TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_import_recipe_ingredients TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_import_recipe_steps TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_import_recipe_step_ingredients TO anon, authenticated;
