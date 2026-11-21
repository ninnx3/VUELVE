-- Lista de espera pública (página /unete/). Cualquiera puede apuntarse; solo las administradoras pueden leerla.
create table if not exists public.lista_espera (
  id bigint generated always as identity primary key,
  email text not null unique check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  nombre text check (nombre is null or length(nombre) <= 60),
  intereses text[] not null default '{}',
  idioma text not null default 'es' check (idioma in ('es','en')),
  origen text check (origen is null or length(origen) <= 40),
  consentimiento timestamptz not null default now(),
  creado timestamptz not null default now(),
  baja timestamptz
);
alter table public.lista_espera enable row level security;
revoke all on public.lista_espera from anon, authenticated;
grant select, update on public.lista_espera to authenticated;
create policy "lista_espera: admin lee" on public.lista_espera for select to authenticated using ((select private.es_admin()));
create policy "lista_espera: admin marca baja" on public.lista_espera for update to authenticated using ((select private.es_admin())) with check ((select private.es_admin()));

-- Alta: no devuelve si el email ya existía (así nadie puede comprobar quién está apuntado).
create or replace function public.unirse_lista(p_email text, p_nombre text default null, p_intereses text[] default '{}', p_idioma text default 'es', p_origen text default null, p_acepto boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare e text := lower(btrim(coalesce(p_email, ''))); i text[];
begin
  if not coalesce(p_acepto, false) then raise exception 'Falta el consentimiento' using errcode = '22023'; end if;
  if e !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(e) > 254 then raise exception 'Email no válido' using errcode = '22023'; end if;
  select coalesce(array_agg(distinct x), '{}') into i from unnest(coalesce(p_intereses, '{}')) x where x in ('recetas','rutinas','merch','app');
  insert into public.lista_espera(email, nombre, intereses, idioma, origen)
  values (e, nullif(left(btrim(coalesce(p_nombre, '')), 60), ''), i, case when p_idioma = 'en' then 'en' else 'es' end, nullif(left(regexp_replace(coalesce(p_origen, ''), '[^a-zA-Z0-9_-]', '', 'g'), 40), ''))
  on conflict (email) do update set intereses = (select coalesce(array_agg(distinct x), '{}') from unnest(public.lista_espera.intereses || excluded.intereses) x),
    nombre = coalesce(excluded.nombre, public.lista_espera.nombre), baja = null, consentimiento = now();
end $$;
revoke all on function public.unirse_lista(text, text, text[], text, text, boolean) from public;
grant execute on function public.unirse_lista(text, text, text[], text, text, boolean) to anon, authenticated;
