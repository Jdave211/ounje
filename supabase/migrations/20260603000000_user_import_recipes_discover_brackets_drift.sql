-- user_import_recipes drifted behind the public `recipes` catalog: the ingestion
-- code writes discover_brackets / external_id / recipe_path (and reads
-- discover_brackets_enriched_at), but user_import_recipes lacked these columns,
-- producing schema-cache warnings on every social/photo import (and silently
-- dropping discover_brackets, which degrades Discover diversity for imports).
-- Mirror the catalog table so the columns persist.

alter table if exists user_import_recipes
  add column if not exists discover_brackets text[] not null default '{}'::text[];

alter table if exists user_import_recipes
  add column if not exists discover_brackets_enriched_at timestamptz;

alter table if exists user_import_recipes
  add column if not exists external_id text;

alter table if exists user_import_recipes
  add column if not exists recipe_path text;

create index if not exists idx_user_import_recipes_discover_brackets
  on user_import_recipes using gin (discover_brackets);
