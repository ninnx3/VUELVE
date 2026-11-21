-- Pasos automáticos desde un Atajo de iPhone (ver la función aplicada en Supabase: crear_token_pasos / registrar_pasos)
create table if not exists public.pasos_token (user_id uuid primary key references auth.users (id) on delete cascade, token_hash text not null unique, creado timestamptz not null default now(), ultimo_uso timestamptz);
alter table public.pasos_token enable row level security;
create policy "pasos_token: ver" on public.pasos_token for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.pasos_token from anon, authenticated; grant select on public.pasos_token to authenticated;
create table if not exists public.pasos_auto (user_id uuid not null references auth.users (id) on delete cascade, fecha date not null, pasos integer not null check (pasos between 0 and 200000), updated_at timestamptz not null default now(), primary key (user_id, fecha));
alter table public.pasos_auto enable row level security;
create policy "pasos_auto: ver" on public.pasos_auto for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.pasos_auto from anon, authenticated; grant select on public.pasos_auto to authenticated;
create or replace function public.crear_token_pasos() returns text language plpgsql security definer set search_path = '' as $$
declare t text; begin
  if auth.uid() is null then raise exception 'no autenticado'; end if;
  t := 'vp_' || encode(extensions.gen_random_bytes(18), 'hex');
  insert into public.pasos_token(user_id, token_hash) values (auth.uid(), encode(extensions.digest(t, 'sha256'), 'hex'))
  on conflict (user_id) do update set token_hash = excluded.token_hash, creado = now(), ultimo_uso = null;
  return t; end $$;
revoke all on function public.crear_token_pasos() from public, anon; grant execute on function public.crear_token_pasos() to authenticated;
create or replace function public.registrar_pasos(p_token text, p_pasos numeric, p_fecha text default null) returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid; f date; n integer; begin
  select user_id into uid from public.pasos_token where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
  if uid is null then raise exception 'Código no válido' using errcode = '28000'; end if;
  n := round(coalesce(p_pasos, 0)); if n < 0 or n > 200000 then raise exception 'Número de pasos no válido'; end if;
  begin f := coalesce(nullif(p_fecha, '')::date, (now() at time zone 'Europe/Madrid')::date); exception when others then f := (now() at time zone 'Europe/Madrid')::date; end;
  if f > (now() at time zone 'Europe/Madrid')::date + 1 or f < (now() at time zone 'Europe/Madrid')::date - 7 then raise exception 'Fecha fuera de rango'; end if;
  insert into public.pasos_auto(user_id, fecha, pasos, updated_at) values (uid, f, n, now()) on conflict (user_id, fecha) do update set pasos = excluded.pasos, updated_at = now();
  update public.pasos_token set ultimo_uso = now() where user_id = uid;
  return 'OK · ' || n || ' pasos el ' || to_char(f, 'DD/MM'); end $$;
revoke all on function public.registrar_pasos(text, numeric, text) from public; grant execute on function public.registrar_pasos(text, numeric, text) to anon, authenticated;
