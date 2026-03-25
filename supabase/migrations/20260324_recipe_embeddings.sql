-- ============================================================
-- Recipe Embeddings + Enrichment Migration
-- Adds enrichment tags, numeric nutrition, vector columns,
-- fts_doc generated column, and hybrid search RPC functions.
-- ============================================================

-- 1. Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Enrichment tag columns
ALTER TABLE recipes
  ADD COLUMN IF NOT EXISTS cuisine_tags    text[]  DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS dietary_tags    text[]  DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS flavor_tags     text[]  DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS main_protein    text,
  ADD COLUMN IF NOT EXISTS cook_method     text[]  DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS occasion_tags   text[]  DEFAULT '{}';

-- 3. Numeric nutrition / timing (parsed from existing _text fields)
ALTER TABLE recipes
  ADD COLUMN IF NOT EXISTS prep_time_minutes  int,
  ADD COLUMN IF NOT EXISTS cook_time_minutes  int,
  ADD COLUMN IF NOT EXISTS calories_kcal      int,
  ADD COLUMN IF NOT EXISTS protein_g          float,
  ADD COLUMN IF NOT EXISTS carbs_g            float,
  ADD COLUMN IF NOT EXISTS fat_g              float;

-- 4. Embedding input text fields (populated by enrichment script)
ALTER TABLE recipes
  ADD COLUMN IF NOT EXISTS ingredients_text   text,
  ADD COLUMN IF NOT EXISTS instructions_text  text,
  ADD COLUMN IF NOT EXISTS image_caption      text;

-- 5. Lifecycle tracking
ALTER TABLE recipes
  ADD COLUMN IF NOT EXISTS enriched_at             timestamptz,
  ADD COLUMN IF NOT EXISTS embeddings_generated_at timestamptz;

-- 6. Vector columns
ALTER TABLE recipes
  ADD COLUMN IF NOT EXISTS embedding_basic  vector(1536),
  ADD COLUMN IF NOT EXISTS embedding_rich   vector(3072);

-- 7. Full-text search document — generated, stored, auto-updated
--    NOTE: if fts_doc already exists as a plain column, drop it first.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='recipes' AND column_name='fts_doc'
    AND is_generated = 'NEVER'
  ) THEN
    ALTER TABLE recipes DROP COLUMN fts_doc;
  END IF;
END $$;

ALTER TABLE recipes
  ADD COLUMN IF NOT EXISTS fts_doc tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english',
      COALESCE(title, '')                                    || ' ' ||
      COALESCE(description, '')                              || ' ' ||
      COALESCE(ingredients_text, '')                         || ' ' ||
      COALESCE(image_caption, '')                            || ' ' ||
      COALESCE(array_to_string(cuisine_tags, ' '), '')       || ' ' ||
      COALESCE(array_to_string(dietary_tags, ' '), '')       || ' ' ||
      COALESCE(array_to_string(flavor_tags, ' '), '')        || ' ' ||
      COALESCE(array_to_string(cook_method, ' '), '')        || ' ' ||
      COALESCE(array_to_string(occasion_tags, ' '), '')      || ' ' ||
      COALESCE(main_protein, '')                             || ' ' ||
      COALESCE(recipe_type, '')                              || ' ' ||
      COALESCE(skill_level, '')
    )
  ) STORED;

-- 8. Indexes

-- GIN for full-text search
CREATE INDEX IF NOT EXISTS idx_recipes_fts
  ON recipes USING GIN(fts_doc);

-- GIN for array tag filtering
CREATE INDEX IF NOT EXISTS idx_recipes_cuisine_tags
  ON recipes USING GIN(cuisine_tags);
CREATE INDEX IF NOT EXISTS idx_recipes_dietary_tags
  ON recipes USING GIN(dietary_tags);
CREATE INDEX IF NOT EXISTS idx_recipes_flavor_tags
  ON recipes USING GIN(flavor_tags);

-- B-tree for numeric range queries
CREATE INDEX IF NOT EXISTS idx_recipes_calories
  ON recipes(calories_kcal);
CREATE INDEX IF NOT EXISTS idx_recipes_cook_time
  ON recipes(cook_time_minutes);
CREATE INDEX IF NOT EXISTS idx_recipes_main_protein
  ON recipes(main_protein);

-- NOTE: HNSW vector indexes are added in the next migration
-- (20260324_recipe_vector_indexes.sql) after embeddings are populated.

-- ============================================================
-- 9. Hybrid search RPC functions
-- ============================================================

-- 9a. Basic vector search (fast, uses embedding_basic)
CREATE OR REPLACE FUNCTION match_recipes_basic(
  query_embedding  vector(1536),
  match_count      int     DEFAULT 10,
  filter_type      text    DEFAULT NULL,
  filter_cuisine   text    DEFAULT NULL,
  filter_protein   text    DEFAULT NULL,
  max_calories     int     DEFAULT NULL,
  max_cook_minutes int     DEFAULT NULL
)
RETURNS TABLE (
  id                  uuid,
  title               text,
  description         text,
  recipe_type         text,
  hero_image_url      text,
  cook_time_minutes   int,
  calories_kcal       int,
  main_protein        text,
  cuisine_tags        text[],
  dietary_tags        text[],
  similarity          float
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  SELECT
    r.id,
    r.title,
    r.description,
    r.recipe_type,
    r.hero_image_url,
    r.cook_time_minutes,
    r.calories_kcal,
    r.main_protein,
    r.cuisine_tags,
    r.dietary_tags,
    1 - (r.embedding_basic <=> query_embedding) AS similarity
  FROM recipes r
  WHERE
    r.embedding_basic IS NOT NULL
    AND (filter_type    IS NULL OR lower(r.recipe_type)  = lower(filter_type))
    AND (filter_cuisine IS NULL OR r.cuisine_tags        @> ARRAY[filter_cuisine])
    AND (filter_protein IS NULL OR lower(r.main_protein) = lower(filter_protein))
    AND (max_calories     IS NULL OR r.calories_kcal     <= max_calories)
    AND (max_cook_minutes IS NULL OR r.cook_time_minutes <= max_cook_minutes)
  ORDER BY r.embedding_basic <=> query_embedding
  LIMIT match_count;
END;
$$;

-- 9b. Rich vector search (deep, uses embedding_rich)
CREATE OR REPLACE FUNCTION match_recipes_rich(
  query_embedding  vector(3072),
  match_count      int     DEFAULT 10,
  filter_type      text    DEFAULT NULL,
  filter_cuisine   text    DEFAULT NULL,
  filter_protein   text    DEFAULT NULL,
  max_calories     int     DEFAULT NULL,
  max_cook_minutes int     DEFAULT NULL
)
RETURNS TABLE (
  id                  uuid,
  title               text,
  description         text,
  recipe_type         text,
  hero_image_url      text,
  cook_time_minutes   int,
  calories_kcal       int,
  main_protein        text,
  cuisine_tags        text[],
  dietary_tags        text[],
  flavor_tags         text[],
  occasion_tags       text[],
  instructions_text   text,
  ingredients_text    text,
  similarity          float
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  SELECT
    r.id,
    r.title,
    r.description,
    r.recipe_type,
    r.hero_image_url,
    r.cook_time_minutes,
    r.calories_kcal,
    r.main_protein,
    r.cuisine_tags,
    r.dietary_tags,
    r.flavor_tags,
    r.occasion_tags,
    r.instructions_text,
    r.ingredients_text,
    1 - (r.embedding_rich <=> query_embedding) AS similarity
  FROM recipes r
  WHERE
    r.embedding_rich IS NOT NULL
    AND (filter_type    IS NULL OR lower(r.recipe_type)  = lower(filter_type))
    AND (filter_cuisine IS NULL OR r.cuisine_tags        @> ARRAY[filter_cuisine])
    AND (filter_protein IS NULL OR lower(r.main_protein) = lower(filter_protein))
    AND (max_calories     IS NULL OR r.calories_kcal     <= max_calories)
    AND (max_cook_minutes IS NULL OR r.cook_time_minutes <= max_cook_minutes)
  ORDER BY r.embedding_rich <=> query_embedding
  LIMIT match_count;
END;
$$;

-- 9c. Hybrid search — Reciprocal Rank Fusion (vector + full-text)
CREATE OR REPLACE FUNCTION match_recipes_hybrid(
  query_embedding  vector(1536),
  query_text       text,
  match_count      int     DEFAULT 10,
  rrf_k            int     DEFAULT 60,
  filter_type      text    DEFAULT NULL,
  filter_cuisine   text    DEFAULT NULL,
  filter_protein   text    DEFAULT NULL,
  max_calories     int     DEFAULT NULL,
  max_cook_minutes int     DEFAULT NULL
)
RETURNS TABLE (
  id                uuid,
  title             text,
  description       text,
  recipe_type       text,
  hero_image_url    text,
  cook_time_minutes int,
  calories_kcal     int,
  main_protein      text,
  cuisine_tags      text[],
  dietary_tags      text[],
  rrf_score         float
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  WITH
  -- base filter applied once
  base AS (
    SELECT r.id, r.title, r.description, r.recipe_type, r.hero_image_url,
           r.cook_time_minutes, r.calories_kcal, r.main_protein,
           r.cuisine_tags, r.dietary_tags,
           r.embedding_basic, r.fts_doc
    FROM recipes r
    WHERE
      r.embedding_basic IS NOT NULL
      AND (filter_type    IS NULL OR lower(r.recipe_type)  = lower(filter_type))
      AND (filter_cuisine IS NULL OR r.cuisine_tags        @> ARRAY[filter_cuisine])
      AND (filter_protein IS NULL OR lower(r.main_protein) = lower(filter_protein))
      AND (max_calories     IS NULL OR r.calories_kcal     <= max_calories)
      AND (max_cook_minutes IS NULL OR r.cook_time_minutes <= max_cook_minutes)
  ),
  -- vector rank
  vector_ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (ORDER BY embedding_basic <=> query_embedding) AS rank
    FROM base
  ),
  -- full-text rank (only when query_text is non-empty)
  fts_ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (ORDER BY ts_rank(fts_doc,
             plainto_tsquery('english', query_text)) DESC) AS rank
    FROM base
    WHERE query_text <> '' AND fts_doc @@ plainto_tsquery('english', query_text)
  )
  SELECT
    b.id, b.title, b.description, b.recipe_type, b.hero_image_url,
    b.cook_time_minutes, b.calories_kcal, b.main_protein,
    b.cuisine_tags, b.dietary_tags,
    COALESCE(1.0 / (rrf_k + vr.rank), 0)
    + COALESCE(1.0 / (rrf_k + fr.rank), 0) AS rrf_score
  FROM base b
  JOIN vector_ranked vr ON b.id = vr.id
  LEFT JOIN fts_ranked fr ON b.id = fr.id
  ORDER BY rrf_score DESC
  LIMIT match_count;
END;
$$;
