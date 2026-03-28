CREATE TABLE IF NOT EXISTS saved_recipes (
  user_id text NOT NULL,
  recipe_id text NOT NULL,
  title text NOT NULL,
  description text,
  author_name text,
  author_handle text,
  category text,
  recipe_type text,
  cook_time_text text,
  published_date text,
  discover_card_image_url text,
  hero_image_url text,
  recipe_url text,
  source text,
  saved_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (user_id, recipe_id)
);

CREATE INDEX IF NOT EXISTS idx_saved_recipes_user_saved_at
  ON saved_recipes(user_id, saved_at DESC);
