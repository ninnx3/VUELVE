-- VUELVE · Esquema inicial (tablas, funciones, reglas RLS y permisos)

create table if not exists public.user_docs (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null,
  body       jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);
alter table public.user_docs enable row level security;
drop policy if exists "user_docs: solo la dueña" on public.user_docs;
create policy "user_docs: solo la dueña" on public.user_docs
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create table if not exists public.dia_resumen (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fecha      date not null,
  cumplido   boolean not null default false,
  movimiento boolean not null default false,
  primary key (user_id, fecha)
);
alter table public.dia_resumen enable row level security;

create table if not exists public.retos (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  owner_email text not null,
  nombre      text not null check (char_length(nombre) between 1 and 80),
  tipo        text not null check (tipo in ('kcal','mov','ambos')),
  inicio      date not null,
  dias        int  not null check (dias between 1 and 366),
  created_at  timestamptz not null default now()
);
alter table public.retos enable row level security;

create table if not exists public.reto_miembros (
  reto_id uuid not null references public.retos(id) on delete cascade,
  email   text not null check (email = lower(email)),
  user_id uuid references auth.users(id) on delete cascade,
  nombre  text,
  estado  text not null default 'invitado' check (estado in ('invitado','miembro','rechazado')),
  primary key (reto_id, email)
);
alter table public.reto_miembros enable row level security;

drop policy if exists "retos: editar" on public.retos;
create policy "retos: editar" on public.retos for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
drop policy if exists "retos: borrar" on public.retos;
create policy "retos: borrar" on public.retos for delete to authenticated using (owner_id = (select auth.uid()));

drop policy if exists "resumen: escribir" on public.dia_resumen;
create policy "resumen: escribir" on public.dia_resumen for insert to authenticated
  with check (user_id = (select auth.uid()));
drop policy if exists "resumen: actualizar" on public.dia_resumen;
create policy "resumen: actualizar" on public.dia_resumen for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "resumen: borrar" on public.dia_resumen;
create policy "resumen: borrar" on public.dia_resumen for delete to authenticated
  using (user_id = (select auth.uid()));

-- Permisos: solo usuarias con sesión; nadie anónimo.
revoke all on public.user_docs, public.dia_resumen, public.retos, public.reto_miembros from anon;
grant select, insert, update, delete on public.user_docs, public.dia_resumen to authenticated;
grant select, insert, delete on public.retos, public.reto_miembros to authenticated;
-- Solo estas columnas se pueden modificar (no se puede mover una fila a otro reto ni cambiar la dueña).
revoke update on public.retos, public.reto_miembros from authenticated;
grant update (nombre, tipo, inicio, dias) on public.retos to authenticated;
grant update (estado, user_id, nombre) on public.reto_miembros to authenticated;

-- Botón "Borrar mi cuenta" de Mi Espacio (borra la usuaria y, en cascada, todos sus datos).
create or replace function public.borrar_mi_cuenta() returns void
  language sql security definer set search_path = '' as $$
  delete from auth.users where id = (select auth.uid())
$$;
revoke all on function public.borrar_mi_cuenta() from public, anon;
grant execute on function public.borrar_mi_cuenta() to authenticated;

-- (Las reglas de ver/crear retos, participantes y resumen están en la migración siguiente,
--  que usa funciones auxiliares en el esquema privado.)
