-- Limpieza diaria del chat: mensajes de más de 90 días y mensajes borrados de más de 7 días
-- (salvo los que tienen un reporte sin resolver). Reportes resueltos de más de 90 días.
create extension if not exists pg_cron;

create or replace function private.comunidad_limpieza() returns void language plpgsql security definer set search_path='' as $$
begin
  delete from public.comunidad_mensajes m
   where (m.creado < now() - interval '90 days' or (m.borrado and m.creado < now() - interval '7 days'))
     and not exists (select 1 from public.comunidad_reportes r where r.mensaje_id=m.id and not r.resuelto);
  delete from public.comunidad_reportes where resuelto and creado < now() - interval '90 days';
end $$;
revoke all on function private.comunidad_limpieza() from public, anon, authenticated;

select cron.schedule('vuelve-limpieza-chat', '17 3 * * *', $$select private.comunidad_limpieza()$$);
