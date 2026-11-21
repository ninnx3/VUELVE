-- Tienda de Vuelve: productos (descargas y, más adelante, merch), compras y configuración.
-- Los pagos los gestiona Stripe desde funciones Edge (tienda-checkout, tienda-webhook, tienda-descarga),
-- que usan la clave service_role del propio servidor. Ningún cliente puede crear compras.

create table if not exists public.productos (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9-]{2,60}$'),
  tipo text not null default 'descarga' check (tipo in ('descarga','fisico')),
  nombre text not null check (char_length(nombre) between 1 and 120),
  nombre_en text check (nombre_en is null or char_length(nombre_en) <= 120),
  descripcion text not null default '' check (char_length(descripcion) <= 4000),
  descripcion_en text check (descripcion_en is null or char_length(descripcion_en) <= 4000),
  incluye text[] not null default '{}',
  incluye_en text[] not null default '{}',
  precio_cent integer not null check (precio_cent between 50 and 100000),
  moneda text not null default 'eur' check (moneda in ('eur')),
  portada text,
  archivos text[] not null default '{}',
  activo boolean not null default false,
  orden integer not null default 0,
  creado timestamptz not null default now(),
  actualizado timestamptz not null default now()
);
alter table public.productos enable row level security;
revoke all on public.productos from anon, authenticated;
grant select on public.productos to anon, authenticated;
grant insert, update, delete on public.productos to authenticated;
create policy "productos: ver activos" on public.productos for select to anon, authenticated
  using (activo or (select private.es_admin()));
create policy "productos: admin crea" on public.productos for insert to authenticated with check ((select private.es_admin()));
create policy "productos: admin edita" on public.productos for update to authenticated using ((select private.es_admin())) with check ((select private.es_admin()));
create policy "productos: admin borra" on public.productos for delete to authenticated using ((select private.es_admin()));

-- La lista de archivos privados no se expone al público: solo su número.
create or replace view public.productos_publicos with (security_invoker = true) as
  select id, slug, tipo, nombre, nombre_en, descripcion, descripcion_en, incluye, incluye_en, precio_cent, moneda, portada,
         coalesce(array_length(archivos, 1), 0) as n_archivos, orden
  from public.productos where activo;
grant select on public.productos_publicos to anon, authenticated;

create table if not exists public.compras (
  id uuid primary key default gen_random_uuid(),
  session_id text not null unique,
  producto_id uuid references public.productos (id) on delete set null,
  email text not null,
  user_id uuid references auth.users (id) on delete set null,
  importe_cent integer not null,
  moneda text not null,
  modo text not null default 'test' check (modo in ('test','live')),
  creado timestamptz not null default now()
);
alter table public.compras enable row level security;
revoke all on public.compras from anon, authenticated;
grant select on public.compras to authenticated;
create policy "compras: las mías" on public.compras for select to authenticated
  using (lower(email) = lower((select auth.jwt()) ->> 'email') or user_id = (select auth.uid()) or (select private.es_admin()));
create index if not exists compras_email_idx on public.compras (lower(email));

create table if not exists public.tienda_config (
  id integer primary key default 1 check (id = 1),
  abierta boolean not null default false,
  actualizado timestamptz not null default now()
);
insert into public.tienda_config (id) values (1) on conflict do nothing;
alter table public.tienda_config enable row level security;
revoke all on public.tienda_config from anon, authenticated;
grant select on public.tienda_config to anon, authenticated;
grant update on public.tienda_config to authenticated;
create policy "tienda_config: ver" on public.tienda_config for select to anon, authenticated using (true);
create policy "tienda_config: admin" on public.tienda_config for update to authenticated using ((select private.es_admin())) with check ((select private.es_admin()));

-- Portadas públicas y archivos privados (solo las funciones del servidor generan enlaces de descarga).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tienda-portadas','tienda-portadas',true,3145728,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tienda','tienda',false,52428800,array['application/pdf','application/zip','video/mp4','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;
create policy "tienda: admin ve" on storage.objects for select to authenticated
  using (bucket_id in ('tienda','tienda-portadas') and (select private.es_admin()));
create policy "tienda: admin sube" on storage.objects for insert to authenticated
  with check (bucket_id in ('tienda','tienda-portadas') and (select private.es_admin()));
create policy "tienda: admin cambia" on storage.objects for update to authenticated
  using (bucket_id in ('tienda','tienda-portadas') and (select private.es_admin()))
  with check (bucket_id in ('tienda','tienda-portadas') and (select private.es_admin()));
create policy "tienda: admin borra" on storage.objects for delete to authenticated
  using (bucket_id in ('tienda','tienda-portadas') and (select private.es_admin()));
