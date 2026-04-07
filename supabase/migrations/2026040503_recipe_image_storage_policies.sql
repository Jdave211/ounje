alter table storage.objects enable row level security;

do $$
begin
  create policy "recipe-images-public-read"
    on storage.objects
    for select
    using (bucket_id = 'recipe-images');
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy "recipe-images-authenticated-insert"
    on storage.objects
    for insert
    with check (
      bucket_id = 'recipe-images'
      and auth.role() = 'authenticated'
    );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy "recipe-images-authenticated-update"
    on storage.objects
    for update
    using (
      bucket_id = 'recipe-images'
      and auth.role() = 'authenticated'
    )
    with check (
      bucket_id = 'recipe-images'
      and auth.role() = 'authenticated'
    );
exception
  when duplicate_object then null;
end $$;
