-- =====================================================================
--  Deep Work · grupos, ranking y presencia
--  Pegar entero en Supabase → SQL Editor → New query → Run.
--  Se puede volver a ejecutar sin miedo: no borra datos.
--
--  IMPORTANTE, dos cosas:
--   1. NO añadas begin; ... commit; a mano. El editor de Supabase ya
--      envuelve todo el buffer en una transacción.
--   2. Cuando termine, ejecuta en una consulta NUEVA y aparte:
--          notify pgrst, 'reload schema';
--      Sin eso, las funciones nuevas devuelven 404 durante unos minutos.
--
--  Modelo de seguridad
--  -------------------
--  La clave publicable de Supabase viaja dentro del navegador, así que
--  cualquiera puede leerla. Por eso las tablas están cerradas a cal y
--  canto (RLS activo y sin políticas: nadie las toca directamente) y
--  todo pasa por estas funciones, que son la única puerta.
--
--  El código del grupo es la contraseña compartida de los grupos
--  privados. Cada miembro tiene además un secreto propio, guardado sólo
--  en su dispositivo, que es lo que le permite escribir sus minutos y
--  los de nadie más. El directorio público NUNCA devuelve códigos: se
--  entra por el id del grupo, que sólo sale del propio directorio.
-- =====================================================================


-- ================================================================ tablas

create table if not exists public.dw_groups (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,
  name        text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.dw_members (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.dw_groups(id) on delete cascade,
  nickname    text not null,
  secret      text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.dw_days (
  member_id   uuid not null references public.dw_members(id) on delete cascade,
  day         date not null,
  minutes     real not null check (minutes >= 0 and minutes <= 1440),
  primary key (member_id, day)
);

-- Apodo único dentro de cada grupo, sin distinguir mayúsculas. Va como
-- índice y no como `unique (...)` de tabla: Postgres sólo admite
-- expresiones como lower() en un índice.
create unique index if not exists dw_members_nick_idx
  on public.dw_members (group_id, lower(nickname));

-- La clave primaria de dw_days ya indexa (member_id, day); sólo hace
-- falta poder recorrer los miembros de un grupo.
create index if not exists dw_members_group_idx on public.dw_members (group_id);


-- ================================================= columnas de presencia
-- Con default constante, PostgreSQL 17 no reescribe la tabla.

alter table public.dw_groups
  add column if not exists is_public  boolean not null default false,
  add column if not exists owner_id   uuid;

alter table public.dw_members
  add column if not exists last_seen           timestamptz,
  add column if not exists session_started_at  timestamptz,
  add column if not exists show_presence       boolean not null default true;

-- El latido reescribe last_seen y session_started_at cada 45 segundos.
-- Deliberadamente NO se indexan esas columnas: la tabla tiene decenas de
-- filas, un índice no acelera nada ahí y en cambio rompe el HOT update,
-- que es lo que permite que la fila se recicle dentro de su propia
-- página en vez de engordar un índice sin parar.
alter table public.dw_members set (fillfactor = 85);

-- Relleno inicial: sin esto, los miembros que ya existen aparecerían
-- todos "en línea" nada más migrar, porque last_seen sería null y luego
-- se llenaría de golpe. Se hereda de updated_at, que es lo más parecido
-- a "la última vez que dio señales".
update public.dw_members
   set last_seen = updated_at
 where last_seen is null;

-- Dueño de cada grupo: el miembro más antiguo. Es quien puede volverlo
-- público o privado. Se comprueba con el par (member_id, secret) que el
-- cliente ya guarda, así que no hay ni una credencial nueva que inventar.
update public.dw_groups g
   set owner_id = (
     select m.id from public.dw_members m
      where m.group_id = g.id
      order by m.created_at asc, m.id asc
      limit 1
   )
 where g.owner_id is null;

create index if not exists dw_groups_public_idx
  on public.dw_groups (is_public) where is_public;


-- =================================================================== RLS
-- Activado y sin ninguna política: el acceso directo queda cerrado.
-- Sólo las funciones de más abajo pueden entrar.

alter table public.dw_groups  enable row level security;
alter table public.dw_members enable row level security;
alter table public.dw_days    enable row level security;

revoke all on table public.dw_groups  from anon, authenticated;
revoke all on table public.dw_members from anon, authenticated;
revoke all on table public.dw_days    from anon, authenticated;


-- ============================================================ auxiliares

-- Código de invitación legible: sin O/0 ni I/1, que se confunden al dictarlo.
create or replace function public.dw_random_code()
returns text
language plpgsql
as $$
declare
  alfabeto text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  salida   text := '';
  i        int;
begin
  for i in 1..6 loop
    salida := salida || substr(alfabeto, 1 + floor(random() * length(alfabeto))::int, 1);
  end loop;
  return salida;
end;
$$;

-- Normaliza y valida un apodo.
create or replace function public.dw_clean_nickname(p_nickname text)
returns text
language plpgsql
as $$
declare
  v text := trim(regexp_replace(coalesce(p_nickname, ''), '\s+', ' ', 'g'));
begin
  if length(v) < 2 then
    raise exception 'El apodo necesita al menos 2 caracteres' using errcode = 'DW001';
  end if;
  if length(v) > 24 then
    raise exception 'El apodo no puede pasar de 24 caracteres' using errcode = 'DW001';
  end if;
  return v;
end;
$$;

-- Racha: días consecutivos con trabajo que terminan hoy o ayer (la racha
-- no se rompe hasta que el día acaba).
--
-- Antes esto era un bucle de plpgsql con UNA CONSULTA POR DÍA de racha.
-- Daba igual cuando sólo corría al pulsar Actualizar; con la presencia
-- encendida pasa a ejecutarse cada 45 segundos por cada miembro, y una
-- racha de 200 días en un grupo de doce eran miles de consultas por
-- refresco. Ahora es un solo recorrido del índice.
--
-- El truco: ordenando los días hacia atrás y numerándolos, (día + nº) es
-- constante dentro de un tramo de días consecutivos. Basta contar los que
-- comparten el tramo del día más reciente, siempre que ese sea hoy o ayer.
create or replace function public.dw_streak(p_member uuid, p_today date)
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with dias as (
    select day, row_number() over (order by day desc)::int as n
      from dw_days
     where member_id = p_member and minutes > 0 and day <= p_today
  ),
  tramos as (
    select day, (day + n) as tramo from dias
  )
  select coalesce(count(*), 0)::int
    from tramos
   where tramo = (
     select tramo from tramos
      where day >= p_today - 1
      order by day desc
      limit 1
   );
$$;


-- ================================================================ tabla
-- Un solo sitio construye las filas del grupo; todas las lecturas
-- delegan aquí.
--
-- La presencia se devuelve SIEMPRE en segundos transcurridos, nunca en
-- fechas. Así el reloj del móvil deja de intervenir: un teléfono con la
-- hora dos horas adelantada no convierte al grupo en fantasmas.
--
-- Y las sesiones fantasma se descartan en la LECTURA (session_started_at
-- de menos de 6 h), que es lo que permite no tener ningún barrendero
-- escribiendo en la ruta caliente.
create or replace function public.dw_board(p_group uuid, p_today date)
returns json
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(json_agg(fila order by fila.total desc, fila.nickname asc), '[]'::json)
  from (
    select
      m.id::text                                        as member_id,
      m.nickname,
      coalesce(d.total, 0)::real                        as total,
      coalesce(d.week,  0)::real                        as week,
      coalesce(d.today, 0)::real                        as today,
      dw_streak(m.id, p_today)                          as streak,
      d.last_day,
      m.show_presence,
      case when m.show_presence and m.last_seen is not null
           then greatest(0, extract(epoch from (now() - m.last_seen))::int)
      end                                               as seen_secs,
      case when m.show_presence
                and m.session_started_at is not null
                and m.session_started_at > now() - interval '6 hours'
           then greatest(0, extract(epoch from (now() - m.session_started_at))::int)
      end                                               as session_secs
    from dw_members m
    -- Un recorrido del índice (member_id, day) en vez de cuatro
    -- subconsultas correlacionadas.
    left join lateral (
      select
        sum(dd.minutes)                                                          as total,
        sum(dd.minutes) filter (
          where dd.day between (p_today - (extract(isodow from p_today)::int - 1)) and p_today
        )                                                                        as week,
        sum(dd.minutes) filter (where dd.day = p_today)                          as today,
        max(dd.day)     filter (where dd.minutes > 0)                            as last_day
      from dw_days dd
      where dd.member_id = m.id
    ) d on true
    where m.group_id = p_group
  ) fila;
$$;


-- ================================================================= sync
-- La RPC única: guarda minutos, sella el latido y devuelve la tabla.
--
-- Antes eran dos viajes (dw_push y dw_leaderboard) y la carrera entre
-- ellos ya costó un parche en el cliente. Fundirlos en una sola petición
-- hace que esa clase entera de errores no pueda existir.
--
-- Autentica por (member_id, secret), no por código de grupo: así se puede
-- marcar como conectado a quien pregunta, y la lectura deja de estar
-- atada al código para siempre.
create or replace function public.dw_sync(
  p_member       uuid,
  p_secret       text,
  p_days         jsonb   default null,
  p_session_secs int     default null,
  p_board        boolean default true,
  p_today        date    default null
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group  uuid;
  v_today  date := coalesce(p_today, current_date);
  v_board  json := null;
  v_code   text;
  v_name   text;
  v_public boolean;
  v_owner  uuid;
  v_show   boolean;
begin
  select group_id into v_group from dw_members where id = p_member and secret = p_secret;
  if v_group is null then
    raise exception 'Credenciales no válidas' using errcode = 'DW005';
  end if;

  -- Los minutos sólo viajan cuando han cambiado. Durante una sesión, el
  -- 95 % de los ciclos no los llevan: son 40 bytes en vez del histórico
  -- entero.
  if p_days is not null and jsonb_typeof(p_days) = 'object' then
    insert into dw_days (member_id, day, minutes)
    select p_member,
           (clave)::date,
           least(greatest((valor #>> '{}')::real, 0), 1440)
      from jsonb_each(p_days) as t(clave, valor)
     where clave ~ '^\d{4}-\d{2}-\d{2}$'
       and jsonb_typeof(valor) = 'number'
    on conflict (member_id, day) do update set minutes = excluded.minutes;
  end if;

  -- Latido. Llegan SEGUNDOS transcurridos, nunca fechas: el instante de
  -- inicio lo reconstruye el servidor con su propio reloj. Una sesión de
  -- más de 6 horas no me la creo y se guarda como si no hubiera ninguna.
  update dw_members
     set last_seen  = now(),
         updated_at = now(),
         session_started_at = case
           when p_session_secs is null then null
           when p_session_secs < 0 or p_session_secs > 21600 then null
           else now() - make_interval(secs => p_session_secs)
         end
   where id = p_member;

  select g.code, g.name, g.is_public, g.owner_id
    into v_code, v_name, v_public, v_owner
    from dw_groups g where g.id = v_group;

  select m.show_presence into v_show from dw_members m where m.id = p_member;

  if p_board then
    v_board := dw_board(v_group, v_today);
  end if;

  return json_build_object(
    'group_id',      v_group,
    'code',          v_code,
    'name',          v_name,
    'is_public',     coalesce(v_public, false),
    'is_owner',      (v_owner = p_member),
    'show_presence', coalesce(v_show, true),
    'members',       v_board
  );
end;
$$;


-- =============================================================== crear
-- OJO: hay que tirar la firma de dos argumentos ANTES de crear la de
-- tres. PostgREST llama con argumentos POR NOMBRE, así que un cuerpo
-- {p_name, p_nickname} encajaría con las dos a la vez y Postgres
-- respondería "function is not unique" (un 300, que no se parece a un
-- error). El drop se lleva también el grant: por eso se vuelve a dar
-- más abajo.
drop function if exists public.dw_create_group(text, text);

create or replace function public.dw_create_group(
  p_name     text,
  p_nickname text,
  p_public   boolean default false
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name     text := trim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_nick     text := dw_clean_nickname(p_nickname);
  v_code     text;
  v_group_id uuid;
  v_member   uuid;
  v_secret   text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_public   boolean := coalesce(p_public, false);
  v_intentos int := 0;
begin
  if length(v_name) < 2 or length(v_name) > 40 then
    raise exception 'El nombre del grupo necesita entre 2 y 40 caracteres' using errcode = 'DW001';
  end if;

  loop
    v_code := dw_random_code();
    exit when not exists (select 1 from dw_groups where code = v_code);
    v_intentos := v_intentos + 1;
    if v_intentos > 50 then
      raise exception 'No se ha podido generar un código libre' using errcode = 'DW002';
    end if;
  end loop;

  insert into dw_groups (code, name, is_public)
    values (v_code, v_name, v_public) returning id into v_group_id;

  -- En un grupo público la presencia arranca APAGADA. "Última conexión
  -- hace 3 minutos" entre cinco amigos es un dato simpático; entre
  -- desconocidos es el registro de horarios de una persona. Los minutos
  -- siguen contando en el ranking igual: se compite sin publicar horario.
  insert into dw_members (group_id, nickname, secret, last_seen, show_presence)
    values (v_group_id, v_nick, v_secret, now(), not v_public)
    returning id into v_member;

  update dw_groups set owner_id = v_member where id = v_group_id;

  return json_build_object(
    'code', v_code, 'name', v_name, 'group_id', v_group_id,
    'member_id', v_member, 'secret', v_secret, 'nickname', v_nick,
    'is_public', v_public, 'is_owner', true, 'show_presence', not v_public
  );
end;
$$;


-- ============================================================== unirse

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

-- Entrar en un grupo público sin código, por su id. El id sólo sale del
-- directorio, y el directorio sólo lista grupos públicos.
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


-- ========================================================== directorio
-- NUNCA devuelve el código: el código es la contraseña de lectura de los
-- grupos privados, y repartirlo aquí dejaría que cualquiera con la clave
-- publicable raspara el directorio y luego siguiera leyendo esos grupos
-- aunque volvieran a ser privados. Se entra por el id.
create or replace function public.dw_public_groups(
  p_query text default null,
  p_limit int  default 40
)
returns json
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    json_agg(fila order by fila.trabajando desc, fila.en_linea desc, fila.week_minutes desc, fila.miembros desc),
    '[]'::json
  )
  from (
    select
      g.id::text as group_id,
      g.name,
      (select count(*) from dw_members m where m.group_id = g.id)::int as miembros,
      (select count(*) from dw_members m
        where m.group_id = g.id and m.show_presence
          and m.last_seen > now() - interval '150 seconds')::int as en_linea,
      (select count(*) from dw_members m
        where m.group_id = g.id and m.show_presence
          and m.session_started_at > now() - interval '6 hours')::int as trabajando,
      coalesce((
        select sum(dd.minutes) from dw_days dd
          join dw_members m on m.id = dd.member_id
         where m.group_id = g.id and dd.day > current_date - 7
      ), 0)::real as week_minutes
    from dw_groups g
    where g.is_public
      -- Se escapan los comodines: sin esto, escribir "%" en el buscador
      -- lista todos los grupos y "_" hace de comodín de un carácter.
      and (
        p_query is null or trim(p_query) = '' or
        g.name ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%'
      )
    order by trabajando desc, en_linea desc, week_minutes desc, miembros desc
    limit greatest(1, least(coalesce(p_limit, 40), 100))
  ) fila;
$$;


-- ====================================================== ajustes y baja

-- Abrir o cerrar el grupo. Sólo el dueño, comprobado con el par
-- (member_id, secret) que el cliente ya guarda.
--
-- Al cerrarlo NO se rota el código: los clientes que ya lo tengan
-- guardado seguirían llamando con él y, si dejara de valer, parecerían
-- expulsados de su propio grupo. Cerrar saca del directorio, nada más.
create or replace function public.dw_set_public(p_member uuid, p_secret text, p_public boolean)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group uuid;
begin
  select m.group_id into v_group
    from dw_members m
    join dw_groups g on g.id = m.group_id
   where m.id = p_member and m.secret = p_secret and g.owner_id = m.id;
  if v_group is null then
    raise exception 'Sólo quien creó el grupo puede abrirlo o cerrarlo' using errcode = 'DW006';
  end if;

  update dw_groups set is_public = coalesce(p_public, false) where id = v_group;
  return json_build_object('ok', true, 'is_public', coalesce(p_public, false));
end;
$$;

-- Cambiar el nombre del grupo. Sólo el dueño, con la misma credencial
-- que ya autoriza a escribir minutos.
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

-- Publicar o no la propia conexión. El filtro vive en el SERVIDOR: si
-- estuviera sólo en el cliente, apagar la presencia te dejaría además sin
-- poder sincronizar minutos.
create or replace function public.dw_set_presence(p_member uuid, p_secret text, p_show boolean)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update dw_members
     set show_presence = coalesce(p_show, true)
   where id = p_member and secret = p_secret;
  if not found then
    raise exception 'Credenciales no válidas' using errcode = 'DW005';
  end if;
  return json_build_object('ok', true, 'show_presence', coalesce(p_show, true));
end;
$$;

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


-- ================================================ compatibilidad y aseo

-- Se conserva para los clientes que aún no hablen dw_sync: el service
-- worker sirve HTML cacheado y habrá versiones viejas circulando días.
create or replace function public.dw_leaderboard(p_code text, p_today date)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code  text := upper(trim(coalesce(p_code, '')));
  v_group uuid;
  v_name  text;
begin
  select id, name into v_group, v_name from dw_groups where code = v_code;
  if v_group is null then
    raise exception 'No existe ningún grupo con ese código' using errcode = 'DW003';
  end if;
  return json_build_object('code', v_code, 'name', v_name,
                           'members', dw_board(v_group, p_today));
end;
$$;

create or replace function public.dw_push(p_member uuid, p_secret text, p_days jsonb, p_nickname text default null)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group uuid;
  v_nick  text;
begin
  select group_id into v_group from dw_members where id = p_member and secret = p_secret;
  if v_group is null then
    raise exception 'Credenciales no válidas' using errcode = 'DW005';
  end if;

  if p_nickname is not null then
    v_nick := dw_clean_nickname(p_nickname);
    begin
      update dw_members set nickname = v_nick where id = p_member;
    exception when unique_violation then
      raise exception 'Ya hay alguien con ese apodo en el grupo' using errcode = 'DW004';
    end;
  end if;

  if p_days is not null and jsonb_typeof(p_days) = 'object' then
    insert into dw_days (member_id, day, minutes)
    select p_member, (clave)::date, least(greatest((valor #>> '{}')::real, 0), 1440)
      from jsonb_each(p_days) as t(clave, valor)
     where clave ~ '^\d{4}-\d{2}-\d{2}$' and jsonb_typeof(valor) = 'number'
    on conflict (member_id, day) do update set minutes = excluded.minutes;
  end if;

  update dw_members set updated_at = now(), last_seen = now() where id = p_member;
  return json_build_object('ok', true);
end;
$$;

-- Existe, pero NO se llama desde ninguna ruta caliente. Meter el barrido
-- dentro de la lectura significaría que cada miembro, cada 45 segundos,
-- escribe en las filas de todos los demás. La verdad sobre las sesiones
-- fantasma vive en la condición de lectura de dw_board.
create or replace function public.dw_sweep_ghosts()
returns int
language sql
security definer
set search_path = public, pg_temp
as $$
  with limpiadas as (
    update dw_members set session_started_at = null
     where session_started_at is not null
       and session_started_at < now() - interval '6 hours'
    returning 1
  )
  select count(*)::int from limpiadas;
$$;


-- ============================================================= permisos
-- Las funciones son la única puerta; las tablas siguen cerradas.
-- El `drop` de dw_create_group se llevó su grant por delante, así que
-- este bloque tiene que ejecutarse siempre después.

grant execute on function public.dw_create_group(text, text, boolean)      to anon, authenticated;
grant execute on function public.dw_join_group(text, text)                 to anon, authenticated;
grant execute on function public.dw_join_public(uuid, text)                to anon, authenticated;
grant execute on function public.dw_sync(uuid, text, jsonb, int, boolean, date) to anon, authenticated;
grant execute on function public.dw_public_groups(text, int)               to anon, authenticated;
grant execute on function public.dw_set_public(uuid, text, boolean)        to anon, authenticated;
grant execute on function public.dw_rename_group(uuid, text, text)        to anon, authenticated;
grant execute on function public.dw_set_presence(uuid, text, boolean)      to anon, authenticated;
grant execute on function public.dw_leave(uuid, text)                      to anon, authenticated;
grant execute on function public.dw_leaderboard(text, date)                to anon, authenticated;
grant execute on function public.dw_push(uuid, text, jsonb, text)          to anon, authenticated;

-- El barrendero no se expone: no lo llama nadie desde el navegador.
revoke all on function public.dw_sweep_ghosts() from anon, authenticated;

-- Comprobación: tiene que devolver UNA sola fila con pronargs = 3.
--   select proname, pronargs from pg_proc where proname = 'dw_create_group';
