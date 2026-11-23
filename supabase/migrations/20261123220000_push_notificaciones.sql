-- Notificaciones push (Web Push). La clave privada VAPID la genera la función "push" y se guarda en private.push_cfg.
create extension if not exists pg_net;

create table private.push_cfg(id int primary key default 1 check (id=1), vapid_pub text, vapid_priv text, hook_secret text not null default encode(gen_random_bytes(32),'hex'));
insert into private.push_cfg(id) values (1) on conflict do nothing;
revoke all on private.push_cfg from public, anon, authenticated;

create or replace function public.push_cfg_get() returns table(vapid_pub text, vapid_priv text, hook_secret text) language sql stable security definer set search_path='' as
$$ select vapid_pub, vapid_priv, hook_secret from private.push_cfg where id=1 $$;
create or replace function public.push_cfg_set(p_pub text, p_priv text) returns void language sql security definer set search_path='' as
$$ update private.push_cfg set vapid_pub=p_pub, vapid_priv=p_priv where id=1 and vapid_priv is null $$;
revoke all on function public.push_cfg_get(), public.push_cfg_set(text,text) from public, anon, authenticated;
grant execute on function public.push_cfg_get(), public.push_cfg_set(text,text) to service_role;

create table public.push_subs(
  endpoint text primary key check (endpoint ~ '^https://'),
  user_id uuid not null references auth.users(id) on delete cascade,
  p256dh text not null, auth text not null,
  creado timestamptz not null default now(), actualizado timestamptz not null default now()
);
create index on public.push_subs(user_id);
alter table public.push_subs enable row level security;
create policy "push_subs: mias" on public.push_subs for all to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
revoke all on public.push_subs from anon, authenticated;
grant select, insert, update, delete on public.push_subs to authenticated;

create table public.push_prefs(
  user_id uuid primary key references auth.users(id) on delete cascade,
  chat_on boolean not null default true, foto_on boolean not null default true, foto_prox date,
  actualizado timestamptz not null default now()
);
alter table public.push_prefs enable row level security;
create policy "push_prefs: mias" on public.push_prefs for all to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
revoke all on public.push_prefs from anon, authenticated;
grant select, insert, update, delete on public.push_prefs to authenticated;

alter table public.comunidad_miembros add column silenciado boolean not null default false;
grant update (silenciado) on public.comunidad_miembros to authenticated;

create or replace function private.push_disparar() returns trigger language plpgsql security definer set search_path='' as $$
declare s text; body jsonb;
begin
  select hook_secret into s from private.push_cfg where id=1;
  if tg_table_name='comunidad_invitaciones' then body:=jsonb_build_object('tabla',tg_table_name,'reto_id',new.reto_id,'user_id',new.user_id,'por',new.invitada_por);
  else body:=jsonb_build_object('tabla',tg_table_name,'id',new.id); end if;
  perform net.http_post(url:='https://vzzkzajzzehhxzwonpgv.supabase.co/functions/v1/push',
    headers:=jsonb_build_object('Content-Type','application/json','x-hook',s), body:=body, timeout_milliseconds:=8000);
  return null;
exception when others then return null;
end $$;
create trigger push after insert on public.comunidad_mensajes for each row execute function private.push_disparar();
create trigger push after insert on public.comunidad_invitaciones for each row execute function private.push_disparar();
create trigger push after insert on public.toques for each row execute function private.push_disparar();

create or replace function private.push_fotos() returns void language plpgsql security definer set search_path='' as $$
declare s text;
begin
  select hook_secret into s from private.push_cfg where id=1;
  perform net.http_post(url:='https://vzzkzajzzehhxzwonpgv.supabase.co/functions/v1/push',
    headers:=jsonb_build_object('Content-Type','application/json','x-hook',s), body:=jsonb_build_object('tabla','fotos'), timeout_milliseconds:=8000);
end $$;
revoke all on function private.push_fotos(), private.push_disparar() from public, anon, authenticated;
select cron.schedule('vuelve-push-fotos', '13 8 * * *', $$select private.push_fotos()$$);
