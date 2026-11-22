-- Juntas: grupo permanente de compañeras (reto tipo 'juntas'), resumen diario ampliado, toques y meta semanal
alter table public.retos drop constraint retos_tipo_check;
alter table public.retos add constraint retos_tipo_check check (tipo = any (array['kcal','mov','ambos','juntas']));
alter table public.retos drop constraint retos_dias_check;
alter table public.retos add constraint retos_dias_check check ((tipo = 'juntas' and dias between 1 and 3660) or (dias between 1 and 366));

alter table public.dia_resumen
  add column if not exists registrado boolean not null default false,
  add column if not exists cerrado boolean not null default false,
  add column if not exists animo text check (animo in ('muy_bien','regular','mal','muy_mal')),
  add column if not exists mov_min integer not null default 0 check (mov_min between 0 and 1440),
  add column if not exists actualizado timestamptz not null default now();

create table public.toques (
  id uuid primary key default gen_random_uuid(),
  de uuid not null default auth.uid() references auth.users(id) on delete cascade,
  de_nombre text check (char_length(de_nombre) <= 60),
  para uuid not null references auth.users(id) on delete cascade,
  tipo text not null check (tipo in ('vamos','cierra','orgullo','mueve','agua','juntas')),
  visto boolean not null default false,
  created_at timestamptz not null default now(),
  check (de <> para)
);
create index toques_para_idx on public.toques (para, created_at desc);
create index toques_de_idx on public.toques (de, created_at desc);
alter table public.toques enable row level security;
create policy "toques: enviar" on public.toques for insert to authenticated
  with check (de = (select auth.uid()) and private.comparte_reto(para));
create policy "toques: ver" on public.toques for select to authenticated
  using (para = (select auth.uid()) or de = (select auth.uid()));
create policy "toques: marcar visto" on public.toques for update to authenticated
  using (para = (select auth.uid())) with check (para = (select auth.uid()));
create policy "toques: borrar" on public.toques for delete to authenticated
  using (para = (select auth.uid()) or de = (select auth.uid()));
revoke update on public.toques from authenticated, anon;
grant update (visto) on public.toques to authenticated;

create or replace function private.toques_limite() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.toques t where t.de = new.de and t.para = new.para and t.created_at > now() - interval '1 day') >= 15 then
    raise exception 'Demasiados toques por hoy';
  end if;
  return new;
end $$;
create trigger toques_limite before insert on public.toques for each row execute function private.toques_limite();

create table public.metas_semana (
  reto_id uuid not null references public.retos(id) on delete cascade,
  semana date not null,
  tipo text not null check (tipo in ('mov','ok','reg')),
  objetivo integer not null check (objetivo between 1 and 60),
  creada_por uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (reto_id, semana)
);
alter table public.metas_semana enable row level security;
create policy "metas: ver" on public.metas_semana for select to authenticated
  using (private.es_miembro_reto(reto_id) or private.es_duena_reto(reto_id));
create policy "metas: crear" on public.metas_semana for insert to authenticated
  with check (private.es_miembro_reto(reto_id) or private.es_duena_reto(reto_id));
create policy "metas: cambiar" on public.metas_semana for update to authenticated
  using (private.es_miembro_reto(reto_id) or private.es_duena_reto(reto_id))
  with check (private.es_miembro_reto(reto_id) or private.es_duena_reto(reto_id));
create policy "metas: borrar" on public.metas_semana for delete to authenticated
  using (private.es_miembro_reto(reto_id) or private.es_duena_reto(reto_id));
