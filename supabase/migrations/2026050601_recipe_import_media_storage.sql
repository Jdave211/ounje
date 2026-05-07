insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'recipe-import-media',
  'recipe-import-media',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set
  name = excluded.name,
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

alter table storage.objects enable row level security;

do $$
begin
  create policy "recipe-import-media-own-select"
    on storage.objects
    for select
    using (
      bucket_id = 'recipe-import-media'
      and auth.role() = 'authenticated'
      and (storage.foldername(name))[1] = 'users'
      and (storage.foldername(name))[2] = auth.uid()::text
    );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy "recipe-import-media-own-insert"
    on storage.objects
    for insert
    with check (
      bucket_id = 'recipe-import-media'
      and auth.role() = 'authenticated'
      and (storage.foldername(name))[1] = 'users'
      and (storage.foldername(name))[2] = auth.uid()::text
    );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy "recipe-import-media-own-update"
    on storage.objects
    for update
    using (
      bucket_id = 'recipe-import-media'
      and auth.role() = 'authenticated'
      and (storage.foldername(name))[1] = 'users'
      and (storage.foldername(name))[2] = auth.uid()::text
    )
    with check (
      bucket_id = 'recipe-import-media'
      and auth.role() = 'authenticated'
      and (storage.foldername(name))[1] = 'users'
      and (storage.foldername(name))[2] = auth.uid()::text
    );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create policy "recipe-import-media-own-delete"
    on storage.objects
    for delete
    using (
      bucket_id = 'recipe-import-media'
      and auth.role() = 'authenticated'
      and (storage.foldername(name))[1] = 'users'
      and (storage.foldername(name))[2] = auth.uid()::text
    );
exception
  when duplicate_object then null;
end $$;
