-- Consejos de bienvenida por push (día 1, 3, 7, 14, 21, 30). El texto vive en la función "push".
alter table public.push_prefs add column if not exists consejos_on boolean not null default true;

create table if not exists public.push_consejos(
  user_id uuid not null references auth.users(id) on delete cascade,
  aviso text not null, enviado timestamptz not null default now(),
  primary key (user_id, aviso)
);
alter table public.push_consejos enable row level security;
revoke all on public.push_consejos from anon, authenticated;
grant select, insert on public.push_consejos to service_role;

-- Usuarias con aviso activado en algún móvil, con los días que llevan en Vuelve y lo que ya se les envió.
create or replace function public.push_consejos_cola() returns table(user_id uuid, edad int, enviados text[]) language sql stable security definer set search_path='' as $$
  select s.user_id, (current_date - u.created_at::date)::int,
    coalesce((select array_agg(c.aviso) from public.push_consejos c where c.user_id=s.user_id), '{}')
  from (select distinct ps.user_id from public.push_subs ps) s
  join auth.users u on u.id=s.user_id
  left join public.push_prefs p on p.user_id=s.user_id
  where coalesce(p.consejos_on, true)
$$;
revoke all on function public.push_consejos_cola() from public, anon, authenticated;
grant execute on function public.push_consejos_cola() to service_role;

create or replace function private.push_consejos() returns void language plpgsql security definer set search_path='' as $$
declare s text;
begin
  select hook_secret into s from private.push_cfg where id=1;
  perform net.http_post(url:='https://vzzkzajzzehhxzwonpgv.supabase.co/functions/v1/push',
    headers:=jsonb_build_object('Content-Type','application/json','x-hook',s), body:=jsonb_build_object('tabla','consejos'), timeout_milliseconds:=20000);
end $$;
revoke all on function private.push_consejos() from public, anon, authenticated;
select cron.schedule('vuelve-push-consejos', '11 9 * * *', $$select private.push_consejos()$$);
