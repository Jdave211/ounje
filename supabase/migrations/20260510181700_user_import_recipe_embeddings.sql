-- Add embedding column to user_import_recipes so similar-recipe matching
-- can cross-reference user imports against the public catalog (and vice versa).
ALTER TABLE public.user_import_recipes
  ADD COLUMN IF NOT EXISTS embedding_basic vector(1536);

-- Index for fast ANN search within a single user's imported recipes.
-- partial index keeps it small: only rows that actually have an embedding.
CREATE INDEX IF NOT EXISTS idx_user_import_recipes_embedding_basic
  ON public.user_import_recipes
  USING ivfflat (embedding_basic vector_cosine_ops)
  WITH (lists = 50)
  WHERE embedding_basic IS NOT NULL;

-- Helper RPC used by the /recipe/detail/:id/similar endpoint to search a
-- single user's imported recipes by vector similarity.
CREATE OR REPLACE FUNCTION match_user_import_recipes_basic(
  p_user_id       text,
  query_embedding vector(1536),
  match_count     int  DEFAULT 10,
  exclude_id      text DEFAULT NULL
)
RETURNS TABLE (
  id               text,
  title            text,
  description      text,
  recipe_type      text,
  hero_image_url   text,
  cook_time_minutes int,
  calories_kcal    numeric,
  main_protein     text,
  cuisine_tags     text[],
  dietary_tags     text[],
  similarity       float
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  -- Enforce that the caller can only query their own imports:
  -- auth.uid() returns NULL for anon callers, which will match nothing.
  IF auth.uid() IS NOT NULL AND auth.uid()::text <> p_user_id THEN
    RETURN;
  END IF;

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
  FROM public.user_import_recipes r
  WHERE
    r.user_id = p_user_id
    AND r.embedding_basic IS NOT NULL
    AND (exclude_id IS NULL OR r.id <> exclude_id)
  ORDER BY r.embedding_basic <=> query_embedding
  LIMIT match_count;
END;
$$;

GRANT EXECUTE ON FUNCTION match_user_import_recipes_basic(text, vector, int, text) TO anon, authenticated;
