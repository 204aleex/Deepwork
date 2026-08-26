-- =====================================================================
--  Deep Work · diagnóstico
--
--  Ejecuta esto ANTES de supabase.sql. Son cuatro comprobaciones sueltas
--  y ninguna cambia nada: sólo sirven para ver qué acepta tu Postgres.
--
--  Pega el resultado (o el error en rojo) tal cual.
-- =====================================================================

-- 1. Versión de Postgres
select version() as postgres;

-- 2. ¿Existen las funciones de hash y de bloqueo que usa el esquema?
select
  to_regprocedure('pg_catalog.hashtext(text)')                    as hashtext,
  to_regprocedure('pg_catalog.pg_advisory_xact_lock(bigint)')     as advisory_lock,
  to_regprocedure('auth.uid()')                                   as auth_uid,
  to_regprocedure('pg_catalog.make_interval(int,int,int,int,int,int,double precision)') as make_interval;

-- 3. ¿Está ya la columna de cuenta? (si sale null, supabase.sql no se aplicó)
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='dw_members' and column_name='user_id') as tiene_user_id,
  (select count(*) from pg_proc where proname='dw_rename_group')  as tiene_rename,
  (select count(*) from pg_proc where proname='dw_my_membership') as tiene_membership,
  (select count(*) from pg_proc where proname='dw_kick')          as tiene_kick;

-- 4. Grupos vacíos que la limpieza se llevaría por delante
select g.name, g.code, g.created_at
  from public.dw_groups g
 where not exists (select 1 from public.dw_members m where m.group_id = g.id)
 order by g.created_at;
