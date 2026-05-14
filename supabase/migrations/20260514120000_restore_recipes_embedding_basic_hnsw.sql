-- Restore the HNSW ANN index on recipes.embedding_basic that was dropped in
-- 20260510071003_drop_duplicate_recipe_embedding_index.sql.
--
-- Background: the drop migration was intended to remove a duplicate, but no
-- companion index covers embedding_basic, so match_recipes_basic /
-- match_recipes_hybrid currently degrade to sequential scans + sorts over the
-- entire recipes table on every discover/search call. This is the dominant
-- driver of discover timeouts.
--
-- We rebuild the same index shape that 2026040102_recipe_vector_indexes.sql
-- originally created.
--
-- Hosted Postgres defaults include a statement_timeout; HNSW builds on large
-- tables routinely exceed it. Disable for the rest of this migration session.
SET statement_timeout = 0;
SET lock_timeout = 0;

CREATE INDEX IF NOT EXISTS idx_recipes_embedding_basic_hnsw
  ON public.recipes
  USING hnsw (embedding_basic vector_cosine_ops);

ANALYZE public.recipes;
