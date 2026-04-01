alter table if exists recipes
  add column if not exists discover_brackets text[] not null default '{}'::text[];

alter table if exists recipes
  add column if not exists discover_brackets_enriched_at timestamptz;

create index if not exists idx_recipes_discover_brackets
  on recipes using gin (discover_brackets);
