-- =====================================================================
--  Deep Work · limpieza de duplicados
--
--  Ejecuta los bloques DE UNO EN UNO: selecciona el bloque y pulsa
--  "Run selected". Así ves el efecto de cada paso.
--
--  Se identifica a la gente por apodo dentro de su grupo, que es único,
--  en vez de por UUID: menos margen para equivocarse copiando.
-- =====================================================================


-- ---------------------------------------------------------------------
-- PASO 1 · Mirar. No cambia nada.
-- ---------------------------------------------------------------------
select
  g.name                                                  as grupo,
  m.nickname                                              as apodo,
  (g.owner_id = m.id)                                     as es_el_dueno,
  round((coalesce(sum(d.minutes), 0) / 60.0)::numeric, 1) as horas,
  m.id                                                    as member_id
from public.dw_groups g
join public.dw_members m on m.group_id = g.id
left join public.dw_days d on d.member_id = m.id
group by g.id, g.name, g.owner_id, m.id, m.nickname
order by g.name, horas desc;


-- ---------------------------------------------------------------------
-- PASO 2 · Borrar los grupos de prueba enteros.
--   "Verificacion actualizar" y "Verificacion post-migracion" son grupos
--   que creé yo comprobando el esquema. "Chichablood" lo confirmaste
--   como de pruebas.
--   El borrado arrastra en cascada sus miembros y sus días.
-- ---------------------------------------------------------------------
delete from public.dw_groups
 where name in (
   'Verificacion actualizar',
   'Verificacion post-migracion',
   'Chichablood'
 );


-- ---------------------------------------------------------------------
-- PASO 3 · Hacerte dueño de "Grupo abierto :)".
--   Tu fila es 'Alex pc 2', la de 6,3 h. La propiedad se había quedado
--   en 'Alex pc', que es una fila vieja.
--   Esto va ANTES de borrar nada, para no dejar el grupo sin dueño.
-- ---------------------------------------------------------------------
update public.dw_groups g
   set owner_id = (
     select m.id from public.dw_members m
      where m.group_id = g.id and m.nickname = 'Alex pc 2'
      limit 1
   )
 where g.name = 'Grupo abierto :)';


-- ---------------------------------------------------------------------
-- PASO 4 · Borrar tus tres filas duplicadas.
--   Se borran por apodo y sólo dentro de ese grupo. 'Alex pc 2' NO está
--   en la lista, así que tu fila buena no se toca.
-- ---------------------------------------------------------------------
delete from public.dw_members m
 using public.dw_groups g
 where m.group_id = g.id
   and g.name = 'Grupo abierto :)'
   and m.nickname in ('Alex pc', 'Movil 3', 'Movil 2');


-- ---------------------------------------------------------------------
-- PASO 5 · Comprobar. Debe quedar un solo grupo con una sola fila tuya,
--   y es_el_dueno en true.
-- ---------------------------------------------------------------------
select
  g.name                                                  as grupo,
  m.nickname                                              as apodo,
  (g.owner_id = m.id)                                     as es_el_dueno,
  round((coalesce(sum(d.minutes), 0) / 60.0)::numeric, 1) as horas
from public.dw_groups g
join public.dw_members m on m.group_id = g.id
left join public.dw_days d on d.member_id = m.id
group by g.id, g.name, g.owner_id, m.id, m.nickname
order by g.name, horas desc;
