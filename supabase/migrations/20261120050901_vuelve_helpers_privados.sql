-- Funciones auxiliares de las reglas en un esquema privado (no expuesto por la API) y reglas que las usan.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.mi_email() returns text
  language sql stable set search_path = '' as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;
create or replace function private.es_duena_reto(r uuid) returns boolean
  language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.retos where id = r and owner_id = (select auth.uid())) $$;
create or replace function private.es_miembro_reto(r uuid) returns boolean
  language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.reto_miembros where reto_id = r and user_id = (select auth.uid()) and estado = 'miembro') $$;
create or replace function private.es_invitada_reto(r uuid) returns boolean
  language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.reto_miembros where reto_id = r and email = private.mi_email()) $$;
create or replace function private.comparte_reto(otra uuid) returns boolean
  language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.reto_miembros a join public.reto_miembros b on a.reto_id = b.reto_id
    where a.user_id = (select auth.uid()) and a.estado = 'miembro' and b.user_id = otra and b.estado = 'miembro') $$;
revoke all on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

drop policy if exists "retos: ver" on public.retos;
create policy "retos: ver" on public.retos for select to authenticated
  using (owner_id = (select auth.uid()) or private.es_miembro_reto(id) or private.es_invitada_reto(id));
drop policy if exists "retos: crear" on public.retos;
create policy "retos: crear" on public.retos for insert to authenticated
  with check (owner_id = (select auth.uid()) and owner_email = private.mi_email());

drop policy if exists "miembros: ver" on public.reto_miembros;
create policy "miembros: ver" on public.reto_miembros for select to authenticated
  using (private.es_duena_reto(reto_id) or private.es_miembro_reto(reto_id) or email = private.mi_email());
-- La dueña solo puede INVITAR; nadie entra como participante sin aceptar.
drop policy if exists "miembros: invitar" on public.reto_miembros;
create policy "miembros: invitar" on public.reto_miembros for insert to authenticated
  with check (private.es_duena_reto(reto_id) and (
    (estado = 'invitado' and user_id is null) or
    (estado = 'miembro' and user_id = (select auth.uid()) and email = private.mi_email())));
drop policy if exists "miembros: actualizar" on public.reto_miembros;
create policy "miembros: actualizar" on public.reto_miembros for update to authenticated
  using (private.es_duena_reto(reto_id) or email = private.mi_email())
  with check ((private.es_duena_reto(reto_id) and (user_id is null or user_id = (select auth.uid())))
           or (email = private.mi_email() and (user_id is null or user_id = (select auth.uid()))));
drop policy if exists "miembros: quitar" on public.reto_miembros;
create policy "miembros: quitar" on public.reto_miembros for delete to authenticated
  using (private.es_duena_reto(reto_id) or email = private.mi_email());

drop policy if exists "resumen: ver" on public.dia_resumen;
create policy "resumen: ver" on public.dia_resumen for select to authenticated
  using (user_id = (select auth.uid()) or private.comparte_reto(user_id));

-- Limpieza de la primera versión (funciones auxiliares que estaban en public).
drop function if exists public.mi_email();
drop function if exists public.es_duena_reto(uuid);
drop function if exists public.es_miembro_reto(uuid);
drop function if exists public.es_invitada_reto(uuid);
drop function if exists public.comparte_reto(uuid);

-- El disparador de RLS automático de Supabase no debe poder llamarse desde la API.
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'rls_auto_enable') then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;
