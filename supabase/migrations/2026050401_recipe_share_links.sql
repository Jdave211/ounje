CREATE TABLE IF NOT EXISTS public.recipe_share_links (
  share_id text PRIMARY KEY,
  recipe_id text NOT NULL,
  recipe_kind text NOT NULL DEFAULT 'public',
  created_by_user_id text,
  snapshot_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  snapshot_hash text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT recipe_share_links_recipe_kind_check CHECK (recipe_kind IN ('public', 'user_import')),
  CONSTRAINT recipe_share_links_status_check CHECK (status IN ('active', 'disabled'))
);

CREATE INDEX IF NOT EXISTS idx_recipe_share_links_recipe_id
  ON public.recipe_share_links(recipe_id);

CREATE INDEX IF NOT EXISTS idx_recipe_share_links_created_by_user
  ON public.recipe_share_links(created_by_user_id, updated_at DESC)
  WHERE created_by_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recipe_share_links_status_updated
  ON public.recipe_share_links(status, updated_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_recipe_share_links_active_snapshot_user
  ON public.recipe_share_links(recipe_id, snapshot_hash, (COALESCE(created_by_user_id, '')))
  WHERE status = 'active';

CREATE OR REPLACE FUNCTION public.set_recipe_share_links_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recipe_share_links_updated_at ON public.recipe_share_links;
CREATE TRIGGER trg_recipe_share_links_updated_at
  BEFORE UPDATE ON public.recipe_share_links
  FOR EACH ROW
  EXECUTE FUNCTION public.set_recipe_share_links_updated_at();

ALTER TABLE public.recipe_share_links ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.recipe_share_links FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.recipe_share_links TO service_role;
