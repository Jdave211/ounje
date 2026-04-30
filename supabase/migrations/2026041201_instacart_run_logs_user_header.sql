create or replace function public.instacart_run_logs_actor_user_id()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(auth.uid()::text, ''),
    nullif((current_setting('request.headers', true)::jsonb ->> 'x-user-id'), '')
  )
$$;

drop policy if exists instacart_run_logs_select_own on public.instacart_run_logs;
drop policy if exists instacart_run_logs_insert_own on public.instacart_run_logs;
drop policy if exists instacart_run_logs_update_own on public.instacart_run_logs;

create policy instacart_run_logs_select_own
on public.instacart_run_logs
for select
to public
using (
  user_id = public.instacart_run_logs_actor_user_id()
);

create policy instacart_run_logs_insert_own
on public.instacart_run_logs
for insert
to public
with check (
  user_id = public.instacart_run_logs_actor_user_id()
);

create policy instacart_run_logs_update_own
on public.instacart_run_logs
for update
to public
using (
  user_id = public.instacart_run_logs_actor_user_id()
)
with check (
  user_id = public.instacart_run_logs_actor_user_id()
);
