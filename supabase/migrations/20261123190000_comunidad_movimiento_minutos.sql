-- Retos de movimiento con minutos mínimos al día
alter table public.comunidad_retos drop constraint comunidad_retos_meta_check;
alter table public.comunidad_retos add constraint comunidad_retos_meta_check check (
  meta is null or (tipo='pasos' and meta between 1000 and 40000) or (tipo='movimiento' and meta between 5 and 300));
update public.comunidad_retos set tipo='movimiento', meta=20, descripcion='Muévete al menos 20 minutos al día: fuerza, pilates, bici, baile o un paseo a buen ritmo. Se marca solo con lo que registras en Movimiento.'
 where oficial and titulo='30 días moviéndote 20 minutos';
