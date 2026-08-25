-- =====================================================================
--  Deep Work · ranking por grupos
--  Pegar entero en Supabase → SQL Editor → New query → Run.
--  Se puede volver a ejecutar sin miedo: no borra datos.
--
--  Modelo de seguridad
--  -------------------
--  La clave "anon" de Supabase viaja dentro del navegador, así que
--  cualquiera puede leerla. Por eso las tablas están cerradas a cal y
--  canto (RLS activo y sin políticas: nadie las toca directamente) y
--  todo pasa por estas funciones, que son la única puerta.
--  El código del grupo es la contraseña compartida: sin él no se puede
--  leer el ranking de nadie. Cada miembro tiene además un secreto
--  privado, guardado solo en su dispositivo, que es lo que le permite
--  escribir sus propios minutos y los de nadie más.
-- =====================================================================

-- ---------------------------------------------------------------- tablas

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

-- Apodo único dentro de cada grupo, sin distinguir mayúsculas. Va como
-- índice y no como `unique (...)` de tabla: Postgres sólo admite
-- expresiones como lower() en un índice.
create unique index if not exists dw_members_nick_idx
  on public.dw_members (group_id, lower(nickname));

create table if not exists public.dw_days (
  member_id   uuid not null references public.dw_members(id) on delete cascade,
  day         date not null,
  minutes     real not null check (minutes >= 0 and minutes <= 1440),
  primary key (member_id, day)
);

-- La clave primaria de dw_days ya indexa (member_id, day); sólo hace
-- falta poder recorrer los miembros de un grupo.
create index if not exists dw_members_group_idx on public.dw_members (group_id);

-- ------------------------------------------------------------------ RLS
-- Activado y sin ninguna política: el acceso directo queda cerrado.
-- Sólo las funciones de más abajo pueden entrar.

alter table public.dw_groups  enable row level security;
alter table public.dw_members enable row level security;
alter table public.dw_days    enable row level security;

revoke all on table public.dw_groups  from anon, authenticated;
revoke all on table public.dw_members from anon, authenticated;
revoke all on table public.dw_days    from anon, authenticated;

-- ------------------------------------------------------------- auxiliares

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

-- Días consecutivos con trabajo, contando hacia atrás desde hoy (o ayer,
-- si hoy todavía no se ha registrado nada: la racha no se rompe hasta
-- que el día termina).
create or replace function public.dw_streak(p_member uuid, p_today date)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dia   date := p_today;
  v_total int  := 0;
begin
  if not exists (select 1 from dw_days where member_id = p_member and day = v_dia and minutes > 0) then
    v_dia := p_today - 1;
  end if;

  loop
    exit when not exists (select 1 from dw_days where member_id = p_member and day = v_dia and minutes > 0);
    v_total := v_total + 1;
    v_dia := v_dia - 1;
  end loop;

  return v_total;
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

-- --------------------------------------------------------------- crear

create or replace function public.dw_create_group(p_name text, p_nickname text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name     text := trim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_nick     text := dw_clean_nickname(p_nickname);
  v_code     text;
  v_group_id uuid;
  v_member   uuid;
  v_secret   text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_intentos int  := 0;
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

  insert into dw_groups (code, name) values (v_code, v_name) returning id into v_group_id;
  insert into dw_members (group_id, nickname, secret)
    values (v_group_id, v_nick, v_secret) returning id into v_member;

  return json_build_object(
    'code', v_code, 'name', v_name,
    'member_id', v_member, 'secret', v_secret, 'nickname', v_nick
  );
end;
$$;

-- --------------------------------------------------------------- unirse

create or replace function public.dw_join_group(p_code text, p_nickname text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code     text := upper(trim(coalesce(p_code, '')));
  v_nick     text := dw_clean_nickname(p_nickname);
  v_group_id uuid;
  v_name     text;
  v_member   uuid;
  v_secret   text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  select id, name into v_group_id, v_name from dw_groups where code = v_code;
  if v_group_id is null then
    raise exception 'No existe ningún grupo con ese código' using errcode = 'DW003';
  end if;

  if exists (select 1 from dw_members where group_id = v_group_id and lower(nickname) = lower(v_nick)) then
    raise exception 'Ya hay alguien con ese apodo en el grupo' using errcode = 'DW004';
  end if;

  insert into dw_members (group_id, nickname, secret)
    values (v_group_id, v_nick, v_secret) returning id into v_member;

  return json_build_object(
    'code', v_code, 'name', v_name,
    'member_id', v_member, 'secret', v_secret, 'nickname', v_nick
  );
end;
$$;

-- --------------------------------------------------------------- enviar
-- Sustituye los minutos del miembro. p_days es {"2026-08-25": 120, ...}

create or replace function public.dw_push(p_member uuid, p_secret text, p_days jsonb, p_nickname text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group uuid;
  v_nick  text;
  v_filas int := 0;
begin
  select group_id into v_group from dw_members where id = p_member and secret = p_secret;
  if v_group is null then
    raise exception 'Credenciales no válidas' using errcode = 'DW005';
  end if;

  if p_nickname is not null then
    v_nick := dw_clean_nickname(p_nickname);
    if exists (
      select 1 from dw_members
      where group_id = v_group and lower(nickname) = lower(v_nick) and id <> p_member
    ) then
      raise exception 'Ya hay alguien con ese apodo en el grupo' using errcode = 'DW004';
    end if;
    update dw_members set nickname = v_nick where id = p_member;
  end if;

  if p_days is not null and jsonb_typeof(p_days) = 'object' then
    insert into dw_days (member_id, day, minutes)
    select p_member,
           (clave)::date,
           least(greatest((valor #>> '{}')::real, 0), 1440)
      from jsonb_each(p_days) as t(clave, valor)
     where clave ~ '^\d{4}-\d{2}-\d{2}$'
       and jsonb_typeof(valor) = 'number'
    on conflict (member_id, day) do update set minutes = excluded.minutes;
    get diagnostics v_filas = row_count;
  end if;

  update dw_members set updated_at = now() where id = p_member;
  return json_build_object('ok', true, 'days', v_filas);
end;
$$;

-- ------------------------------------------------------------- ranking
-- p_today es la fecha local de quien pregunta: así "hoy" y "esta semana"
-- salen bien aunque el servidor vaya en UTC.

create or replace function public.dw_leaderboard(p_code text, p_today date)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code       text := upper(trim(coalesce(p_code, '')));
  v_group_id   uuid;
  v_name       text;
  v_week_start date := p_today - (extract(isodow from p_today)::int - 1);
  v_members    json;
begin
  select id, name into v_group_id, v_name from dw_groups where code = v_code;
  if v_group_id is null then
    raise exception 'No existe ningún grupo con ese código' using errcode = 'DW003';
  end if;

  select coalesce(json_agg(fila order by fila.total desc), '[]'::json) into v_members
  from (
    select
      m.id::text as member_id,
      m.nickname,
      coalesce((select sum(d.minutes) from dw_days d
                 where d.member_id = m.id), 0)::real as total,
      coalesce((select sum(d.minutes) from dw_days d
                 where d.member_id = m.id and d.day between v_week_start and p_today), 0)::real as week,
      coalesce((select sum(d.minutes) from dw_days d
                 where d.member_id = m.id and d.day = p_today), 0)::real as today,
      dw_streak(m.id, p_today) as streak,
      (select max(d.day) from dw_days d where d.member_id = m.id and d.minutes > 0) as last_day
    from dw_members m
    where m.group_id = v_group_id
  ) fila;

  return json_build_object('code', v_code, 'name', v_name, 'members', v_members);
end;
$$;

-- --------------------------------------------------------------- salir

create or replace function public.dw_leave(p_member uuid, p_secret text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from dw_members where id = p_member and secret = p_secret;
  if not found then
    raise exception 'Credenciales no válidas' using errcode = 'DW005';
  end if;
  return json_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------- permisos
-- Las funciones son la única puerta; las tablas siguen cerradas.

grant execute on function public.dw_create_group(text, text)            to anon, authenticated;
grant execute on function public.dw_join_group(text, text)              to anon, authenticated;
grant execute on function public.dw_push(uuid, text, jsonb, text)       to anon, authenticated;
grant execute on function public.dw_leaderboard(text, date)             to anon, authenticated;
grant execute on function public.dw_leave(uuid, text)                   to anon, authenticated;
