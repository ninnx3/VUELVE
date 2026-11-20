-- Biblioteca de recetas creada por el equipo de Vuelve.
-- Todas las usuarias pueden leer las recetas publicadas; solo las administradoras crean, editan y borran.

create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
drop policy if exists "admins: verme" on public.admins;
create policy "admins: verme" on public.admins for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.admins from anon, authenticated;
grant select on public.admins to authenticated;

create or replace function private.es_admin() returns boolean
  language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = (select auth.uid())) $$;
revoke all on function private.es_admin() from public, anon;
grant execute on function private.es_admin() to authenticated;

create table if not exists public.recetas (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('Desayuno','Comida','Cena','Snack','Capricho','Cheatmeal')),
  nombre text not null check (char_length(nombre) between 1 and 120),
  emoji text not null default '🍽️',
  descripcion text not null default '',
  kcal integer not null default 0 check (kcal between 0 and 3000),
  p integer not null default 0 check (p between 0 and 300),
  c integer not null default 0 check (c between 0 and 400),
  g integer not null default 0 check (g between 0 and 200),
  prep_min integer not null default 0,
  coccion_min integer not null default 0,
  raciones_lote integer not null default 4,
  ingredientes jsonb not null default '[]'::jsonb,
  pasos jsonb not null default '[]'::jsonb,
  conservacion text not null default '',
  consejo text not null default '',
  alergenos text[] not null default '{}',
  etiquetas text[] not null default '{}',
  enfoques integer[] not null default '{}',
  publicada boolean not null default false,
  creado_por uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists recetas_tipo_idx on public.recetas (tipo) where publicada;
create index if not exists recetas_creado_por_idx on public.recetas (creado_por);
alter table public.recetas enable row level security;

drop policy if exists "recetas: ver" on public.recetas;
create policy "recetas: ver" on public.recetas for select to authenticated
  using (publicada or (select private.es_admin()));
drop policy if exists "recetas: crear" on public.recetas;
create policy "recetas: crear" on public.recetas for insert to authenticated
  with check ((select private.es_admin()));
drop policy if exists "recetas: editar" on public.recetas;
create policy "recetas: editar" on public.recetas for update to authenticated
  using ((select private.es_admin())) with check ((select private.es_admin()));
drop policy if exists "recetas: borrar" on public.recetas;
create policy "recetas: borrar" on public.recetas for delete to authenticated
  using ((select private.es_admin()));

revoke all on public.recetas from anon;
grant select, insert, update, delete on public.recetas to authenticated;

create or replace function private.recetas_touch() returns trigger
  language plpgsql set search_path = '' as $$ begin new.updated_at = now(); return new; end $$;
revoke all on function private.recetas_touch() from public, anon, authenticated;
drop trigger if exists recetas_touch on public.recetas;
create trigger recetas_touch before update on public.recetas
  for each row execute function private.recetas_touch();
