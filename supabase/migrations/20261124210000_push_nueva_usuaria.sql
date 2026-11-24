-- Aviso push a las administradoras cuando se registra una usuaria nueva.
create or replace function private.push_nueva_usuaria() returns trigger language plpgsql security definer set search_path='' as $$
declare s text;
begin
  select hook_secret into s from private.push_cfg where id=1;
  perform net.http_post(url:='https://vzzkzajzzehhxzwonpgv.supabase.co/functions/v1/push',
    headers:=jsonb_build_object('Content-Type','application/json','x-hook',s),
    body:=jsonb_build_object('tabla','nuevas','user_id',new.id), timeout_milliseconds:=8000);
  return null;
exception when others then return null;
end $$;
revoke all on function private.push_nueva_usuaria() from public, anon, authenticated;
drop trigger if exists vuelve_push_nueva on auth.users;
create trigger vuelve_push_nueva after insert on auth.users for each row execute function private.push_nueva_usuaria();
