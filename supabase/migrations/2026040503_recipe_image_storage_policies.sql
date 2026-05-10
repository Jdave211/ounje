alter table storage.objects enable row level security;

drop policy if exists "Anon insert recipe_images" on storage.objects;

do $$
begin
  create policy "recipe-images-public-read"
    on storage.objects
    for select
    using (bucket_id = 'recipe-images');
exception
  when duplicate_object then null;
end $$;
