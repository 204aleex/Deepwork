-- =====================================================================
--  Deep Work · ver y limpiar duplicados, y recuperar la propiedad
--
--  Ejecuta los pasos DE UNO EN UNO (selecciona el bloque y "Run selected").
--  El paso 1 sólo mira. Los pasos 2 y 3 cambian cosas.
-- =====================================================================


-- ---------------------------------------------------------------------
-- PASO 1 · Mirar qué hay. No cambia nada.
--
--   soy_el_dueno = true  -> esa fila es la que manda en el grupo
--   horas        -> para saber cuál es tu fila buena y cuál el duplicado
-- ---------------------------------------------------------------------
select
  g.name                                    as grupo,
  g.code                                    as codigo,
  m.nickname                                as apodo,
  (g.owner_id = m.id)                       as es_el_dueno,
  round(coalesce(sum(d.minutes), 0) / 60.0, 1) as horas,
  m.last_seen                               as ultima_conexion,
  m.id                                      as member_id
from public.dw_groups g
join public.dw_members m on m.group_id = g.id
left join public.dw_days d on d.member_id = m.id
group by g.id, g.name, g.code, g.owner_id, m.id, m.nickname, m.last_seen
order by g.name, horas desc;


-- ---------------------------------------------------------------------
-- PASO 2 · Hacerte dueño del grupo.
--
--   Cambia 'Grupo abierto :)' por el nombre exacto de tu grupo, y
--   'TU_APODO' por el apodo de TU fila (la que quieres conservar, la que
--   sale con más horas en el paso 1).
--
--   Después de esto, en la app ya te saldrán "Quitar a alguien",
--   "Grupo abierto" y poder renombrar el grupo.
-- ---------------------------------------------------------------------
update public.dw_groups g
   set owner_id = (
     select m.id from public.dw_members m
      where m.group_id = g.id and m.nickname = 'TU_APODO'
      limit 1
   )
 where g.name = 'Grupo abierto :)';


-- ---------------------------------------------------------------------
-- PASO 3 · Borrar un duplicado.
--
--   Copia el member_id del paso 1 (la fila que quieres quitar) y pégalo
--   aquí. Repite por cada duplicado.
--
--   Esto borra esa fila y sus horas de ese grupo. Lo que esa persona
--   tenga guardado en su propio móvil no se toca.
-- ---------------------------------------------------------------------
-- delete from public.dw_members where id = 'PEGA_AQUI_EL_MEMBER_ID';


-- ---------------------------------------------------------------------
-- PASO 4 · Comprobar que ha quedado bien. No cambia nada.
-- ---------------------------------------------------------------------
-- (vuelve a ejecutar el PASO 1)
