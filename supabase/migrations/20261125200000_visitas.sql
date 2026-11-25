-- Analítica propia y anónima: solo el nombre de la pantalla, sin datos personales.
create table if not exists public.visitas(
  id bigint generated always as identity primary key,
  sid text not null check (length(sid)<=40),
  vista text not null check (length(vista)<=40),
  t timestamptz not null default now()
);
create index if not exists visitas_t_idx on public.visitas(t);
create index if not exists visitas_sid_idx on public.visitas(sid,t);
alter table public.visitas enable row level security;
drop policy if exists visitas_insert on public.visitas;
create policy visitas_insert on public.visitas for insert to anon, authenticated with check (length(sid)<=40 and length(vista)<=40);

create or replace function public.admin_visitas(dias int default 30)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r jsonb;
begin
  if not exists(select 1 from public.admins where user_id=auth.uid()) then raise exception 'no autorizada'; end if;
  with s as (
    select sid,vista,t,
      row_number() over(partition by sid order by t) rn,
      row_number() over(partition by sid order by t desc) rd,
      lead(t) over(partition by sid order by t) nt
    from public.visitas where t>now()-make_interval(days=>greatest(1,least(dias,365)))
  )
  select jsonb_build_object(
    'sesiones',(select count(distinct sid) from s),
    'visitas',(select count(*) from s),
    'vistas',(select coalesce(jsonb_agg(to_jsonb(x) order by x.n desc),'[]'::jsonb) from (select vista,count(*) n,count(distinct sid) ses,coalesce(round(avg(least(extract(epoch from nt-t),300)) filter(where nt is not null)),0)::int seg from s group by vista) x),
    'entradas',(select coalesce(jsonb_agg(to_jsonb(x) order by x.n desc),'[]'::jsonb) from (select vista,count(*) n from s where rn=1 group by vista) x),
    'salidas',(select coalesce(jsonb_agg(to_jsonb(x) order by x.n desc),'[]'::jsonb) from (select vista,count(*) n from s where rd=1 group by vista) x),
    'dias',(select coalesce(jsonb_agg(to_jsonb(x) order by x.d),'[]'::jsonb) from (select (t at time zone 'Europe/Madrid')::date d,count(distinct sid) n from s group by 1) x)
  ) into r;
  return r;
end $$;
revoke all on function public.admin_visitas(int) from public, anon;
grant execute on function public.admin_visitas(int) to authenticated;
