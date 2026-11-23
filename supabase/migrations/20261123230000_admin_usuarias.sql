-- Listado de usuarias solo para administradoras
create or replace function public.admin_usuarias()
returns table(user_id uuid, email text, nombre text, usuario text, alta timestamptz, ultimo_acceso timestamptz, confirmada boolean, retos int, vetada boolean, avisos boolean)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.es_admin() then raise exception 'Solo administradoras' using errcode='42501'; end if;
  return query
  select u.id, u.email::text, coalesce(u.raw_user_meta_data->>'nombre', u.raw_user_meta_data->>'name', '')::text,
         p.usuario, u.created_at, u.last_sign_in_at, (u.email_confirmed_at is not null),
         (select count(*)::int from public.comunidad_miembros m where m.user_id=u.id),
         exists(select 1 from public.comunidad_vetadas v where v.user_id=u.id),
         exists(select 1 from public.push_subs s where s.user_id=u.id)
  from auth.users u left join public.perfiles_publicos p on p.user_id=u.id
  order by u.created_at desc;
end $$;
revoke all on function public.admin_usuarias() from public, anon;
grant execute on function public.admin_usuarias() to authenticated;
