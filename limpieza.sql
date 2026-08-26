-- =====================================================================
--  Deep Work · limpieza puntual (opcional)
--
--  Esto es lo ÚNICO que borra datos, y por eso va aparte de supabase.sql.
--  Quita los grupos que se quedaron sin nadie dentro.
--
--  Ojo: sólo toca grupos con CERO miembros. Un grupo con gente dentro no
--  se roza, se llame como se llame.
--
--  A partir de ahora no hace falta: dw_leave borra el grupo solo cuando
--  sale su último miembro.
-- =====================================================================

-- Antes de borrar, mira qué se va a ir:
--   select g.name, g.code from public.dw_groups g
--    where not exists (select 1 from public.dw_members m where m.group_id = g.id);

delete from public.dw_groups g
 where not exists (
   select 1 from public.dw_members m where m.group_id = g.id
 );
