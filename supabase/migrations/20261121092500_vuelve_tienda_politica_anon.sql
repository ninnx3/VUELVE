-- anon no puede ejecutar private.es_admin(): política propia para visitas sin cuenta
drop policy if exists "productos: ver activos" on public.productos;
create policy "productos: anon ve activos" on public.productos for select to anon using (activo);
create policy "productos: ver activos" on public.productos for select to authenticated using (activo or (select private.es_admin()));
