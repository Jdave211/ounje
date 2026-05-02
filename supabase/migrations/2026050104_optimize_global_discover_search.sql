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
    (1 - ((r.embedding_rich::halfvec(3072)) <=> (query_embedding::halfvec(3072))))::double precision AS similarity
  FROM recipes r
  WHERE
    r.embedding_rich IS NOT NULL
    AND (
      filter_type IS NULL
      OR (
        lower(filter_type) IN ('vegan', 'vegetarian')
        AND (
          lower(r.recipe_type) = lower(filter_type)
          OR COALESCE(r.dietary_tags, ARRAY[]::text[]) @> ARRAY[lower(filter_type)]
        )
      )
      OR (
        lower(filter_type) NOT IN ('vegan', 'vegetarian')
        AND lower(r.recipe_type) = lower(filter_type)
      )
    )
    AND (filter_cuisine IS NULL OR r.cuisine_tags @> ARRAY[filter_cuisine])
    AND (filter_protein IS NULL OR lower(r.main_protein) = lower(filter_protein))
    AND (max_calories IS NULL OR r.calories_kcal <= max_calories)
    AND (max_cook_minutes IS NULL OR r.cook_time_minutes <= max_cook_minutes)
  ORDER BY (r.embedding_rich::halfvec(3072)) <=> (query_embedding::halfvec(3072))
  LIMIT match_count;
END;
$$;

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
DECLARE
  candidate_count int := GREATEST(match_count * 4, 80);
BEGIN
  RETURN QUERY
  WITH
  vector_ranked AS (
    SELECT
      vc.id,
      ROW_NUMBER() OVER (ORDER BY vc.distance) AS rank
    FROM (
      SELECT
        r.id,
        r.embedding_basic <=> query_embedding AS distance
      FROM recipes r
      WHERE
        r.embedding_basic IS NOT NULL
        AND (
          filter_type IS NULL
          OR (
            lower(filter_type) IN ('vegan', 'vegetarian')
            AND (
              lower(r.recipe_type) = lower(filter_type)
              OR COALESCE(r.dietary_tags, ARRAY[]::text[]) @> ARRAY[lower(filter_type)]
            )
          )
          OR (
            lower(filter_type) NOT IN ('vegan', 'vegetarian')
            AND lower(r.recipe_type) = lower(filter_type)
          )
        )
        AND (filter_cuisine IS NULL OR r.cuisine_tags @> ARRAY[filter_cuisine])
        AND (filter_protein IS NULL OR lower(r.main_protein) = lower(filter_protein))
        AND (max_calories IS NULL OR r.calories_kcal <= max_calories)
        AND (max_cook_minutes IS NULL OR r.cook_time_minutes <= max_cook_minutes)
      ORDER BY r.embedding_basic <=> query_embedding
      LIMIT candidate_count
    ) vc
  ),
  fts_ranked AS (
    SELECT
      fc.id,
      ROW_NUMBER() OVER (ORDER BY fc.text_rank DESC) AS rank
    FROM (
      SELECT
        r.id,
        ts_rank_cd(r.fts_doc, plainto_tsquery('english', query_text)) AS text_rank
      FROM recipes r
      WHERE
        query_text <> ''
        AND r.fts_doc @@ plainto_tsquery('english', query_text)
        AND (
          filter_type IS NULL
          OR (
            lower(filter_type) IN ('vegan', 'vegetarian')
            AND (
              lower(r.recipe_type) = lower(filter_type)
              OR COALESCE(r.dietary_tags, ARRAY[]::text[]) @> ARRAY[lower(filter_type)]
            )
          )
          OR (
            lower(filter_type) NOT IN ('vegan', 'vegetarian')
            AND lower(r.recipe_type) = lower(filter_type)
          )
        )
        AND (filter_cuisine IS NULL OR r.cuisine_tags @> ARRAY[filter_cuisine])
        AND (filter_protein IS NULL OR lower(r.main_protein) = lower(filter_protein))
        AND (max_calories IS NULL OR r.calories_kcal <= max_calories)
        AND (max_cook_minutes IS NULL OR r.cook_time_minutes <= max_cook_minutes)
      ORDER BY text_rank DESC
      LIMIT candidate_count
    ) fc
  ),
  fused AS (
    SELECT
      COALESCE(vr.id, fr.id) AS id,
      COALESCE(1.0 / (rrf_k + vr.rank), 0)
      + COALESCE(1.0 / (rrf_k + fr.rank), 0) AS rrf_score
    FROM vector_ranked vr
    FULL OUTER JOIN fts_ranked fr ON fr.id = vr.id
  )
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
    fused.rrf_score::double precision
  FROM fused
  JOIN recipes r ON r.id = fused.id
  ORDER BY fused.rrf_score DESC
  LIMIT match_count;
END;
$$;
