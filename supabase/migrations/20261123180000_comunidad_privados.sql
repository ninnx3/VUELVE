-- Retos privados (solo por invitación, por @usuario) y nuevos tipos automáticos
alter table public.comunidad_retos add column privado boolean not null default false;
alter table public.comunidad_retos drop constraint comunidad_retos_tipo_check;
alter table public.comunidad_retos add constraint comunidad_retos_tipo_check check (tipo in ('pasos','habito','calorias','movimiento'));

create table public.comunidad_invitaciones(
  reto_id uuid references public.comunidad_retos(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  invitada_por uuid not null references auth.users(id) on delete cascade,
  creado timestamptz not null default now(),
  primary key (reto_id,user_id)
);
create index on public.comunidad_invitaciones(user_id);
create index on public.comunidad_invitaciones(invitada_por);
alter table public.comunidad_invitaciones enable row level security;

create or replace function private.puede_ver_reto(r uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.comunidad_retos c where c.id=r and (
    (not c.privado and not c.oculto) or c.creada_por=(select auth.uid())
    or exists(select 1 from public.comunidad_miembros m where m.reto_id=r and m.user_id=(select auth.uid()))
    or exists(select 1 from public.comunidad_invitaciones i where i.reto_id=r and i.user_id=(select auth.uid()))))
$$;
create or replace function private.puede_unirse(r uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.comunidad_retos c where c.id=r and not c.oculto and (
    not c.privado or c.creada_por=(select auth.uid())
    or exists(select 1 from public.comunidad_invitaciones i where i.reto_id=r and i.user_id=(select auth.uid()))))
$$;
grant execute on function private.puede_ver_reto(uuid), private.puede_unirse(uuid) to authenticated;

drop policy "cretos: ver" on public.comunidad_retos;
create policy "cretos: ver" on public.comunidad_retos for select to authenticated
  using ((not oculto and not privado) or creada_por=(select auth.uid()) or private.en_comunidad_reto(id) or private.puede_ver_reto(id) or private.es_admin());

drop policy "cmiembros: unirme" on public.comunidad_miembros;
create policy "cmiembros: unirme" on public.comunidad_miembros for insert to authenticated
  with check (user_id=(select auth.uid()) and private.tiene_perfil() and not private.vetada() and private.puede_unirse(reto_id) and unido between current_date-1 and current_date+1);

create policy "invit: ver" on public.comunidad_invitaciones for select to authenticated
  using (user_id=(select auth.uid()) or invitada_por=(select auth.uid()) or private.en_comunidad_reto(reto_id));
create policy "invit: invitar" on public.comunidad_invitaciones for insert to authenticated
  with check (invitada_por=(select auth.uid()) and user_id<>(select auth.uid()) and private.en_comunidad_reto(reto_id) and not private.vetada());
create policy "invit: quitar" on public.comunidad_invitaciones for delete to authenticated
  using (user_id=(select auth.uid()) or invitada_por=(select auth.uid()));
revoke all on public.comunidad_invitaciones from anon, authenticated;
grant select, insert, delete on public.comunidad_invitaciones to authenticated;

create or replace function private.comunidad_lim_invit() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if (select count(*) from public.comunidad_invitaciones where invitada_por=new.invitada_por and creado>now()-interval '1 day')>=40 then
    raise exception 'Has enviado muchas invitaciones hoy' using errcode='P0001'; end if;
  return new;
end $$;
create trigger lim before insert on public.comunidad_invitaciones for each row execute function private.comunidad_lim_invit();
grant update (privado) on public.comunidad_retos to authenticated;
