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
  WITH base AS (
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
      r.embedding_basic,
      r.fts_doc
    FROM recipes r
    WHERE
      r.embedding_basic IS NOT NULL
      AND (filter_type IS NULL OR lower(r.recipe_type) = lower(filter_type))
      AND (filter_cuisine IS NULL OR r.cuisine_tags @> ARRAY[filter_cuisine])
      AND (filter_protein IS NULL OR lower(r.main_protein) = lower(filter_protein))
      AND (max_calories IS NULL OR r.calories_kcal <= max_calories)
      AND (max_cook_minutes IS NULL OR r.cook_time_minutes <= max_cook_minutes)
  ),
  vector_ranked AS (
    SELECT
      base.id,
      ROW_NUMBER() OVER (ORDER BY base.embedding_basic <=> query_embedding) AS rank
    FROM base
  ),
  fts_ranked AS (
    SELECT
      base.id,
      ROW_NUMBER() OVER (
        ORDER BY ts_rank(base.fts_doc, plainto_tsquery('english', query_text)) DESC
      ) AS rank
    FROM base
    WHERE query_text <> '' AND base.fts_doc @@ plainto_tsquery('english', query_text)
  )
  SELECT
    b.id,
    b.title,
    b.description,
    b.recipe_type,
    b.hero_image_url,
    b.cook_time_minutes,
    b.calories_kcal,
    b.main_protein,
    b.cuisine_tags,
    b.dietary_tags,
    (
      COALESCE(1.0 / (rrf_k + vr.rank), 0)
      + COALESCE(1.0 / (rrf_k + fr.rank), 0)
    )::double precision AS rrf_score
  FROM base b
  JOIN vector_ranked vr ON b.id = vr.id
  LEFT JOIN fts_ranked fr ON b.id = fr.id
  ORDER BY rrf_score DESC
  LIMIT match_count;
END;
$$;
