-- =====================================================================
--  Deep Work · actualización
--  Pegar en Supabase → SQL Editor → New query → Run.
--  Sin begin/commit a mano: el editor ya envuelve el buffer.
--  Al terminar, en una consulta NUEVA:  notify pgrst, 'reload schema';
--
--  Hace cuatro cosas:
--   1. Borra los grupos que se quedaron sin nadie dentro.
--   2. dw_leave: al salir el último miembro, el grupo se borra solo.
--   3. dw_rename_group: el dueño puede cambiarle el nombre al grupo.
--   4. Serializa altas y bajas del mismo grupo, para que entrar justo
--      cuando sale el último no pise a nadie.
-- =====================================================================


-- ---------------------------------------------- 1. limpieza de una vez
-- Sólo toca grupos con CERO miembros. Un grupo con gente dentro no se
-- roza, se llame como se llame.

delete from public.dw_groups g
 where not exists (
   select 1 from public.dw_members m where m.group_id = g.id
 );


-- --------------------------------------------- 2. funciones al día

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

  -- Se serializa por grupo: sin esto, alguien entrando en el mismo
  -- instante en que sale el ultimo miembro podia perder su fila por la
  -- cascada del borrado, o recibir un error crudo de clave ajena.
  perform pg_advisory_xact_lock(hashtextextended(v_group::text, 0));

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


create or replace function public.dw_rename_group(p_member uuid, p_secret text, p_name text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $BODY$
declare
  v_group uuid;
  v_name  text := trim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  if length(v_name) < 2 or length(v_name) > 40 then
    raise exception 'El nombre del grupo necesita entre 2 y 40 caracteres' using errcode = 'DW001';
  end if;

  select m.group_id into v_group
    from dw_members m
    join dw_groups g on g.id = m.group_id
   where m.id = p_member and m.secret = p_secret and g.owner_id = m.id;
  if v_group is null then
    raise exception 'Sólo quien creó el grupo puede cambiarle el nombre' using errcode = 'DW006';
  end if;

  update dw_groups set name = v_name where id = v_group;
  return json_build_object('ok', true, 'name', v_name);
end;
$BODY$;


create or replace function public.dw_join_group(p_code text, p_nickname text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code     text := upper(trim(coalesce(p_code, '')));
  v_nick     text := dw_clean_nickname(p_nickname);
  v_group_id uuid;
  v_name     text;
  v_public   boolean;
  v_member   uuid;
  v_secret   text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  select id, name, is_public into v_group_id, v_name, v_public
    from dw_groups where code = v_code;
  if v_group_id is null then
    raise exception 'No existe ningún grupo con ese código' using errcode = 'DW003';
  end if;

  -- El índice único es el que manda. Comprobar y luego insertar deja una
  -- rendija: si dos personas entran con el mismo apodo a la vez, las dos
  -- pasan la comprobación y la segunda reventaba con el error crudo de
  -- Postgres. Aquí se atrapa y sale el mismo mensaje de siempre.
  perform pg_advisory_xact_lock(hashtextextended(v_group_id::text, 0));

  begin
    insert into dw_members (group_id, nickname, secret, last_seen, show_presence)
      values (v_group_id, v_nick, v_secret, now(), not coalesce(v_public, false))
      returning id into v_member;
  exception when unique_violation then
    raise exception 'Ya hay alguien con ese apodo en el grupo' using errcode = 'DW004';
  end;

  return json_build_object(
    'code', v_code, 'name', v_name, 'group_id', v_group_id,
    'member_id', v_member, 'secret', v_secret, 'nickname', v_nick,
    'is_public', coalesce(v_public, false), 'is_owner', false,
    'show_presence', not coalesce(v_public, false)
  );
end;
$$;


create or replace function public.dw_join_public(p_group_id uuid, p_nickname text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_nick   text := dw_clean_nickname(p_nickname);
  v_code   text;
  v_name   text;
  v_member uuid;
  v_secret text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  select code, name into v_code, v_name
    from dw_groups where id = p_group_id and is_public;
  if v_code is null then
    raise exception 'Ese grupo ya no está abierto' using errcode = 'DW003';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_group_id::text, 0));

  begin
    insert into dw_members (group_id, nickname, secret, last_seen, show_presence)
      values (p_group_id, v_nick, v_secret, now(), false)
      returning id into v_member;
  exception when unique_violation then
    raise exception 'Ya hay alguien con ese apodo en el grupo' using errcode = 'DW004';
  end;

  return json_build_object(
    'code', v_code, 'name', v_name, 'group_id', p_group_id,
    'member_id', v_member, 'secret', v_secret, 'nickname', v_nick,
    'is_public', true, 'is_owner', false, 'show_presence', false
  );
end;
$$;



-- ------------------------------------------------------------ permisos

grant execute on function public.dw_leave(uuid, text)              to anon, authenticated;
grant execute on function public.dw_rename_group(uuid, text, text) to anon, authenticated;
grant execute on function public.dw_join_group(text, text)         to anon, authenticated;
grant execute on function public.dw_join_public(uuid, text)        to anon, authenticated;


-- ------------------------------------------------------ comprobaciones
-- Debe devolver 0 filas (ya no queda ningún grupo sin gente):
--   select g.name from public.dw_groups g
--    where not exists (select 1 from public.dw_members m where m.group_id = g.id);
