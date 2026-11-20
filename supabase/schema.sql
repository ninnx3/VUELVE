-- =========================================================
-- VUELVE · Esquema de base de datos para Supabase
-- Pegar entero en Supabase → SQL Editor → Run.
-- Se puede ejecutar varias veces sin romper nada.
-- =========================================================

-- ---------- Datos privados de cada persona ----------
-- Perfil, diario (un documento por mes), mealprep... Solo los ve su dueña.
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
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------- Resumen diario (lo único que ven tus compañeras de reto) ----------
-- Solo dos sí/no por día: si cumpliste calorías y si te moviste. Nunca qué comiste ni tu peso.
create table if not exists public.dia_resumen (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fecha      date not null,
  cumplido   boolean not null default false,
  movimiento boolean not null default false,
  primary key (user_id, fecha)
);
alter table public.dia_resumen enable row level security;

-- ---------- Retos con amigas ----------
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

-- ---------- Funciones auxiliares (evitan bucles entre reglas) ----------
create or replace function public.mi_email() returns text
  language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;

create or replace function public.es_duena_reto(r uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from retos where id = r and owner_id = auth.uid())
$$;

create or replace function public.es_miembro_reto(r uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from reto_miembros where reto_id = r and user_id = auth.uid() and estado = 'miembro')
$$;

create or replace function public.es_invitada_reto(r uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from reto_miembros where reto_id = r and email = public.mi_email())
$$;

create or replace function public.comparte_reto(otra uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from reto_miembros a join reto_miembros b on a.reto_id = b.reto_id
    where a.user_id = auth.uid() and a.estado = 'miembro'
      and b.user_id = otra and b.estado = 'miembro')
$$;

-- ---------- Reglas: retos ----------
drop policy if exists "retos: ver" on public.retos;
create policy "retos: ver" on public.retos for select
  using (owner_id = auth.uid() or public.es_miembro_reto(id) or public.es_invitada_reto(id));
drop policy if exists "retos: crear" on public.retos;
create policy "retos: crear" on public.retos for insert
  with check (owner_id = auth.uid() and owner_email = public.mi_email());
drop policy if exists "retos: editar" on public.retos;
create policy "retos: editar" on public.retos for update
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "retos: borrar" on public.retos;
create policy "retos: borrar" on public.retos for delete using (owner_id = auth.uid());

-- ---------- Reglas: participantes ----------
drop policy if exists "miembros: ver" on public.reto_miembros;
create policy "miembros: ver" on public.reto_miembros for select
  using (public.es_duena_reto(reto_id) or public.es_miembro_reto(reto_id) or email = public.mi_email());
drop policy if exists "miembros: invitar" on public.reto_miembros;
create policy "miembros: invitar" on public.reto_miembros for insert
  with check (public.es_duena_reto(reto_id));
-- La dueña puede cambiar cualquier fila; cada persona solo la suya (aceptar o rechazar).
drop policy if exists "miembros: actualizar" on public.reto_miembros;
create policy "miembros: actualizar" on public.reto_miembros for update
  using (public.es_duena_reto(reto_id) or email = public.mi_email())
  with check (public.es_duena_reto(reto_id) or (email = public.mi_email() and (user_id is null or user_id = auth.uid())));
drop policy if exists "miembros: quitar" on public.reto_miembros;
create policy "miembros: quitar" on public.reto_miembros for delete
  using (public.es_duena_reto(reto_id) or email = public.mi_email());

-- ---------- Reglas: resumen diario ----------
drop policy if exists "resumen: ver" on public.dia_resumen;
create policy "resumen: ver" on public.dia_resumen for select
  using (user_id = auth.uid() or public.comparte_reto(user_id));
drop policy if exists "resumen: escribir" on public.dia_resumen;
create policy "resumen: escribir" on public.dia_resumen for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- Borrar mi cuenta (lo usa el botón de Mi Espacio) ----------
create or replace function public.borrar_mi_cuenta() returns void
  language sql security definer set search_path = public as $$
  delete from auth.users where id = auth.uid()
$$;
revoke all on function public.borrar_mi_cuenta() from public, anon;
grant execute on function public.borrar_mi_cuenta() to authenticated;
