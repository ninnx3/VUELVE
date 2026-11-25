-- Categoría de objetivo para los retos de la comunidad (aplicada en Supabase).
alter table public.comunidad_retos add column if not exists categoria text;
alter table public.comunidad_retos drop constraint if exists comunidad_retos_categoria_chk;
alter table public.comunidad_retos add constraint comunidad_retos_categoria_chk check (categoria is null or categoria in ('grasa','musculo','azucar','pasos','movimiento','comida','agua','bienestar'));
