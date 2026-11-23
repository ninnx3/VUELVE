grant select, insert, update, delete on public.metas_semana to authenticated;
grant select, insert, delete on public.toques to authenticated;
grant update (visto) on public.toques to authenticated;
revoke all on public.metas_semana from anon;
revoke all on public.toques from anon;
