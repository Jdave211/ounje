create table public.first_run_guide_progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  catalog_version integer not null,
  phase text not null check (phase in (
    'recipeSuggestion', 'planReady', 'planOpened', 'cartSelect',
    'cartIngredient', 'cartAlreadyHave', 'cartScope', 'cartShopNow',
    'discover', 'discoverRecipe', 'addRecipe', 'completed', 'dismissed'
  )),
  seed_recipe_id text not null,
  preset_plan_id text,
  plan_id uuid not null,
  is_replay boolean not null default false,
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  dismissed_at timestamptz
);

create function public.keep_newest_first_run_guide_progress()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.updated_at < old.updated_at then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.keep_newest_first_run_guide_progress() from public, anon, authenticated;

create trigger keep_newest_first_run_guide_progress
before update on public.first_run_guide_progress
for each row execute function public.keep_newest_first_run_guide_progress();

alter table public.first_run_guide_progress enable row level security;

revoke all on table public.first_run_guide_progress from anon, authenticated;
grant select, insert, update on table public.first_run_guide_progress to authenticated;

create policy "Users can read their first-run guide"
on public.first_run_guide_progress
for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Users can create their first-run guide"
on public.first_run_guide_progress
for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy "Users can update their first-run guide"
on public.first_run_guide_progress
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);
