-- Tighten match_user_import_recipes_basic authorization.
--
-- The original definition in 20260510181700_user_import_recipe_embeddings.sql
-- has SECURITY DEFINER + EXECUTE granted to anon, and the guard only rejects
-- when auth.uid() IS NOT NULL AND auth.uid()::text <> p_user_id. That means
-- an anonymous caller (auth.uid() IS NULL) can request ANY p_user_id and
-- receive that user's imported recipes. That is both a data-exposure bug and
-- a free way to burn server-side embedding compute.
--
-- Fix: require auth.uid() to be present AND equal to p_user_id, and revoke
-- execute from anon. Only authenticated users should call this RPC, and they
-- can only query their own imports.

CREATE OR REPLACE FUNCTION public.match_user_import_recipes_basic(
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
  -- Strict auth: caller must be authenticated AND must match p_user_id.
  -- Anonymous callers (auth.uid() IS NULL) are rejected.
  IF auth.uid() IS NULL OR auth.uid()::text <> p_user_id THEN
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

REVOKE EXECUTE ON FUNCTION public.match_user_import_recipes_basic(text, vector, int, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.match_user_import_recipes_basic(text, vector, int, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.match_user_import_recipes_basic(text, vector, int, text) TO authenticated;
