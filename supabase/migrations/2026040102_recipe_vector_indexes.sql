CREATE INDEX IF NOT EXISTS idx_recipes_embedding_basic_hnsw
  ON recipes
  USING hnsw (embedding_basic vector_cosine_ops);
