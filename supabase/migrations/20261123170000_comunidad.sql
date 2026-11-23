-- Comunidad: nombres de usuario, retos abiertos y chat de grupo por reto.
-- Separado de retos/reto_miembros a propósito: aquí nunca se comparten emails ni el diario.

create table public.perfiles_publicos(
  user_id uuid primary key references auth.users(id) on delete cascade,
  usuario text not null,
  normas_aceptadas timestamptz not null default now(),
  creado timestamptz not null default now(),
  constraint usuario_formato check (usuario ~ '^[a-z0-9][a-z0-9._]{2,19}$'),
  constraint usuario_reservado check (usuario !~ '^(vuelve|admin|moderador|moderadora|soporte|oficial)')
);
create unique index perfiles_publicos_usuario on public.perfiles_publicos(lower(usuario));

create table public.comunidad_vetadas(
  user_id uuid primary key references auth.users(id) on delete cascade,
  motivo text, por uuid, creado timestamptz not null default now()
);

create table public.comunidad_retos(
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (char_length(titulo) between 3 and 60),
  descripcion text check (char_length(descripcion) <= 220),
  tipo text not null check (tipo in ('pasos','habito')),
  meta integer check (meta is null or meta between 1000 and 40000),
  dias integer not null check (dias between 3 and 90),
  icono text not null default 'compartido' check (icono ~ '^[a-z0-9-]{1,30}$'),
  oficial boolean not null default false,
  oculto boolean not null default false,
  n_miembros integer not null default 0,
  creada_por uuid references auth.users(id) on delete set null,
  creado timestamptz not null default now()
);

create table public.comunidad_miembros(
  reto_id uuid references public.comunidad_retos(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  unido date not null default current_date,
  creado timestamptz not null default now(),
  primary key (reto_id,user_id)
);
create index on public.comunidad_miembros(user_id);

create table public.comunidad_checkins(
  reto_id uuid, user_id uuid, fecha date not null,
  valor integer, hecho boolean not null default false,
  primary key (reto_id,user_id,fecha),
  foreign key (reto_id,user_id) references public.comunidad_miembros(reto_id,user_id) on delete cascade
);

create table public.comunidad_mensajes(
  id uuid primary key default gen_random_uuid(),
  reto_id uuid not null references public.comunidad_retos(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  texto text not null check (char_length(btrim(texto)) between 1 and 500),
  borrado boolean not null default false,
  creado timestamptz not null default now(),
  constraint sin_enlaces check (texto !~* '(https?://|www\.|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})')
);
create index on public.comunidad_mensajes(reto_id, creado desc);
create index on public.comunidad_mensajes(user_id);

create table public.comunidad_reportes(
  id uuid primary key default gen_random_uuid(),
  mensaje_id uuid references public.comunidad_mensajes(id) on delete cascade,
  reportada_por uuid not null references auth.users(id) on delete cascade,
  motivo text not null check (char_length(motivo) between 2 and 300),
  resuelto boolean not null default false,
  creado timestamptz not null default now(),
  unique (mensaje_id, reportada_por)
);

create table public.comunidad_bloqueos(
  user_id uuid references auth.users(id) on delete cascade,
  bloqueada uuid references auth.users(id) on delete cascade,
  creado timestamptz not null default now(),
  primary key (user_id,bloqueada)
);

create index on public.comunidad_reportes(reportada_por);
create index on public.comunidad_bloqueos(bloqueada);
create index on public.comunidad_retos(creada_por);

-- Helpers
create or replace function private.tiene_perfil() returns boolean language sql stable security definer set search_path='' as
$$ select exists(select 1 from public.perfiles_publicos where user_id=(select auth.uid())) $$;
create or replace function private.vetada() returns boolean language sql stable security definer set search_path='' as
$$ select exists(select 1 from public.comunidad_vetadas where user_id=(select auth.uid())) $$;
create or replace function private.en_comunidad_reto(r uuid) returns boolean language sql stable security definer set search_path='' as
$$ select exists(select 1 from public.comunidad_miembros where reto_id=r and user_id=(select auth.uid())) $$;
grant usage on schema private to authenticated;
grant execute on function private.tiene_perfil(), private.vetada(), private.en_comunidad_reto(uuid) to authenticated;

-- Contador de miembros
create or replace function private.comunidad_contar() returns trigger language plpgsql security definer set search_path='' as $$
begin
  update public.comunidad_retos set n_miembros=(select count(*) from public.comunidad_miembros where reto_id=coalesce(new.reto_id,old.reto_id)) where id=coalesce(new.reto_id,old.reto_id);
  return null;
end $$;
create trigger comunidad_contar after insert or delete on public.comunidad_miembros for each row execute function private.comunidad_contar();

-- Límites anti-spam
create or replace function private.comunidad_limites() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='comunidad_mensajes' then
    if (select count(*) from public.comunidad_mensajes where user_id=new.user_id and creado>now()-interval '1 minute')>=8 then
      raise exception 'Vas muy rápido: espera un momento antes de escribir otra vez' using errcode='P0001'; end if;
  elsif tg_table_name='comunidad_retos' then
    if (select count(*) from public.comunidad_retos where creada_por=new.creada_por and creado>now()-interval '1 day')>=3 then
      raise exception 'Puedes crear como máximo 3 retos al día' using errcode='P0001'; end if;
  elsif tg_table_name='comunidad_reportes' then
    if (select count(*) from public.comunidad_reportes where reportada_por=new.reportada_por and creado>now()-interval '1 hour')>=20 then
      raise exception 'Demasiados reportes seguidos' using errcode='P0001'; end if;
  end if;
  return new;
end $$;
create trigger lim before insert on public.comunidad_mensajes for each row execute function private.comunidad_limites();
create trigger lim before insert on public.comunidad_retos for each row execute function private.comunidad_limites();
create trigger lim before insert on public.comunidad_reportes for each row execute function private.comunidad_limites();

-- RLS
alter table public.perfiles_publicos enable row level security;
alter table public.comunidad_vetadas enable row level security;
alter table public.comunidad_retos enable row level security;
alter table public.comunidad_miembros enable row level security;
alter table public.comunidad_checkins enable row level security;
alter table public.comunidad_mensajes enable row level security;
alter table public.comunidad_reportes enable row level security;
alter table public.comunidad_bloqueos enable row level security;

create policy "perfiles: ver" on public.perfiles_publicos for select to authenticated using (true);
create policy "perfiles: crear" on public.perfiles_publicos for insert to authenticated with check (user_id=(select auth.uid()) and not private.vetada());
create policy "perfiles: cambiar" on public.perfiles_publicos for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
create policy "perfiles: borrar" on public.perfiles_publicos for delete to authenticated using (user_id=(select auth.uid()));

create policy "vetadas: ver" on public.comunidad_vetadas for select to authenticated using (user_id=(select auth.uid()) or private.es_admin());
create policy "vetadas: admin crear" on public.comunidad_vetadas for insert to authenticated with check (private.es_admin());
create policy "vetadas: admin borrar" on public.comunidad_vetadas for delete to authenticated using (private.es_admin());

create policy "cretos: ver" on public.comunidad_retos for select to authenticated using (not oculto or creada_por=(select auth.uid()) or private.es_admin());
create policy "cretos: crear" on public.comunidad_retos for insert to authenticated with check (creada_por=(select auth.uid()) and not oficial and not oculto and n_miembros=0 and private.tiene_perfil() and not private.vetada());
create policy "cretos: admin editar" on public.comunidad_retos for update to authenticated using (private.es_admin()) with check (private.es_admin());
create policy "cretos: borrar" on public.comunidad_retos for delete to authenticated using ((creada_por=(select auth.uid()) and not oficial) or private.es_admin());

create policy "cmiembros: ver" on public.comunidad_miembros for select to authenticated using (user_id=(select auth.uid()) or private.en_comunidad_reto(reto_id));
create policy "cmiembros: unirme" on public.comunidad_miembros for insert to authenticated with check (user_id=(select auth.uid()) and private.tiene_perfil() and not private.vetada() and unido between current_date-1 and current_date+1);
create policy "cmiembros: reiniciar" on public.comunidad_miembros for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()) and unido between current_date-1 and current_date+1);
create policy "cmiembros: salir" on public.comunidad_miembros for delete to authenticated using (user_id=(select auth.uid()));

create policy "checkins: ver" on public.comunidad_checkins for select to authenticated using (private.en_comunidad_reto(reto_id));
create policy "checkins: crear" on public.comunidad_checkins for insert to authenticated with check (user_id=(select auth.uid()) and fecha between current_date-2 and current_date+1);
create policy "checkins: cambiar" on public.comunidad_checkins for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()) and fecha between current_date-2 and current_date+1);
create policy "checkins: borrar" on public.comunidad_checkins for delete to authenticated using (user_id=(select auth.uid()));

create policy "mensajes: ver" on public.comunidad_mensajes for select to authenticated using (private.en_comunidad_reto(reto_id) or private.es_admin());
create policy "mensajes: escribir" on public.comunidad_mensajes for insert to authenticated with check (user_id=(select auth.uid()) and not borrado and private.en_comunidad_reto(reto_id) and private.tiene_perfil() and not private.vetada());
create policy "mensajes: borrar" on public.comunidad_mensajes for update to authenticated using (user_id=(select auth.uid()) or private.es_admin()) with check (borrado);

create policy "reportes: crear" on public.comunidad_reportes for insert to authenticated with check (reportada_por=(select auth.uid()) and not resuelto);
create policy "reportes: admin ver" on public.comunidad_reportes for select to authenticated using (private.es_admin());
create policy "reportes: admin resolver" on public.comunidad_reportes for update to authenticated using (private.es_admin()) with check (private.es_admin());

create policy "bloqueos: mios" on public.comunidad_bloqueos for all to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()) and bloqueada<>user_id);

-- Permisos: solo usuarias con sesión
revoke all on public.perfiles_publicos, public.comunidad_vetadas, public.comunidad_retos, public.comunidad_miembros, public.comunidad_checkins, public.comunidad_mensajes, public.comunidad_reportes, public.comunidad_bloqueos from anon;
revoke all on public.perfiles_publicos, public.comunidad_vetadas, public.comunidad_retos, public.comunidad_miembros, public.comunidad_checkins, public.comunidad_mensajes, public.comunidad_reportes, public.comunidad_bloqueos from authenticated;
grant select, insert, delete on public.perfiles_publicos to authenticated;
grant update (usuario) on public.perfiles_publicos to authenticated;
grant select, insert, delete on public.comunidad_vetadas to authenticated;
grant select, insert, delete on public.comunidad_retos to authenticated;
grant update (oculto, titulo, descripcion) on public.comunidad_retos to authenticated;
grant select, insert, delete on public.comunidad_miembros to authenticated;
grant update (unido) on public.comunidad_miembros to authenticated;
grant select, insert, update, delete on public.comunidad_checkins to authenticated;
grant select, insert on public.comunidad_mensajes to authenticated;
grant update (borrado) on public.comunidad_mensajes to authenticated;
grant select, insert on public.comunidad_reportes to authenticated;
grant update (resuelto) on public.comunidad_reportes to authenticated;
grant select, insert, delete on public.comunidad_bloqueos to authenticated;

-- Chat en tiempo real
alter publication supabase_realtime add table public.comunidad_mensajes;

-- Retos oficiales de serie
insert into public.comunidad_retos(titulo,descripcion,tipo,meta,dias,icono,oficial) values
 ('30 días · 6.000 pasos','Camina al menos 6.000 pasos cada día durante un mes. Tus pasos se cuentan solos desde la app.','pasos',6000,30,'act-pasos',true),
 ('15 días sin azúcar añadido','Nada de azúcar añadido durante 15 días: la fruta sí, los dulces y refrescos no.','habito',null,15,'consejo',true),
 ('21 días · 2 litros de agua','Bebe al menos 2 litros de agua al día durante tres semanas.','habito',null,21,'consejo',true),
 ('30 días moviéndote 20 minutos','Cualquier movimiento cuenta: fuerza, pilates, bici, baile o un paseo a buen ritmo.','habito',null,30,'act-alta',true),
 ('14 días cocinando en casa','Prepara tú misma tus comidas principales durante dos semanas.','habito',null,14,'comida-almuerzo',true),
 ('7 días · 10.000 pasos','Una semana intensa: 10.000 pasos al día.','pasos',10000,7,'act-pasos',true);
