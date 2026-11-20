-- Fotos de motivación: privadas/<uid>/... solo la dueña; compartidas/<uid>/... también sus compañeras de retos
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos','fotos',false,6291456,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;
create or replace function private.carpeta_uid(nombre text) returns uuid
  language sql immutable set search_path = '' as $$
  select case when (storage.foldername(nombre))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then ((storage.foldername(nombre))[2])::uuid end $$;
revoke all on function private.carpeta_uid(text) from public, anon;
grant execute on function private.carpeta_uid(text) to authenticated;
create policy "fotos: ver" on storage.objects for select to authenticated
  using (bucket_id='fotos' and (private.carpeta_uid(name) = (select auth.uid())
    or ((storage.foldername(name))[1]='compartidas' and private.comparte_reto(private.carpeta_uid(name)))));
create policy "fotos: subir" on storage.objects for insert to authenticated
  with check (bucket_id='fotos' and (storage.foldername(name))[1] in ('privadas','compartidas') and private.carpeta_uid(name) = (select auth.uid()));
create policy "fotos: cambiar" on storage.objects for update to authenticated
  using (bucket_id='fotos' and private.carpeta_uid(name) = (select auth.uid()))
  with check (bucket_id='fotos' and (storage.foldername(name))[1] in ('privadas','compartidas') and private.carpeta_uid(name) = (select auth.uid()));
create policy "fotos: borrar" on storage.objects for delete to authenticated
  using (bucket_id='fotos' and private.carpeta_uid(name) = (select auth.uid()));
