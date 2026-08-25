-- =====================================================================
--  Deep Work · limpieza de grupos vacíos
--  Pegar en Supabase → SQL Editor → New query → Run.
--  Sin begin/commit a mano: el editor ya envuelve el buffer.
--
--  Hace dos cosas:
--   1. Borra los grupos que se quedaron sin nadie dentro.
--   2. Actualiza dw_leave para que eso no vuelva a pasar: cuando sale el
--      último miembro, el grupo se borra solo.
-- =====================================================================


-- ---------------------------------------------- 1. limpieza de una vez
-- Sólo toca grupos con CERO miembros. Un grupo con gente dentro no se
-- roza, se llame como se llame.

delete from public.dw_groups g
 where not exists (
   select 1 from public.dw_members m where m.group_id = g.id
 );


-- ------------------------------------------- 2. que no se repita nunca

create or replace function public.dw_leave(p_member uuid, p_secret text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group uuid;
  v_owner uuid;
begin
  select group_id into v_group from dw_members where id = p_member and secret = p_secret;
  if v_group is null then
    raise exception 'Credenciales no válidas' using errcode = 'DW005';
  end if;

  delete from dw_members where id = p_member;

  -- Si no queda nadie, el grupo se borra solo. Un grupo vacío no le sirve
  -- a nadie y, si era público, saldría en el directorio como un sitio con
  -- cero personas dentro. El borrado arrastra en cascada dw_members y
  -- dw_days, que a estas alturas ya están vacíos.
  if not exists (select 1 from dw_members where group_id = v_group) then
    delete from dw_groups where id = v_group;
    return json_build_object('ok', true, 'group_deleted', true);
  end if;

  -- Si se va el dueño, el mando pasa al miembro más antiguo que quede.
  select owner_id into v_owner from dw_groups where id = v_group;
  if v_owner = p_member then
    update dw_groups
       set owner_id = (
         select m.id from dw_members m
          where m.group_id = v_group
          order by m.created_at asc, m.id asc
          limit 1
       )
     where id = v_group;
  end if;

  return json_build_object('ok', true, 'group_deleted', false);
end;
$$;

grant execute on function public.dw_leave(uuid, text) to anon, authenticated;


-- ------------------------------------------------------ comprobación
-- Debe devolver 0 filas: ya no queda ningún grupo sin gente.
--   select g.name from public.dw_groups g
--    where not exists (select 1 from public.dw_members m where m.group_id = g.id);
