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
