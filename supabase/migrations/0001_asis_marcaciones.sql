-- ============================================================
-- Control de Asistencia (ingreso / inicio almuerzo / fin almuerzo / salida)
--
-- Vive en el mismo proyecto Supabase que SSOMA y el dashboard
-- Adecco KPI (marlon220901's Project). Reutiliza:
--   - b2c_asistencia como roster diario de colaboradores (DNI,
--     nombre, puesto, área, turno, estado) para validar quién
--     puede marcar, en vez de mantener un maestro de personal
--     propio y duplicado.
--   - b2c_login / b2c_sesion_actual / b2c_require_session para el
--     panel administrativo (mismas credenciales que el resto del
--     ecosistema Adecco KPI).
--   - b2c_permisos / b2c_permisos_catalogo para controlar qué
--     roles ven el panel de asistencia (permiso "view.asistencia").
--
-- La pantalla de marcación (kiosko) no tiene login: cualquier
-- colaborador activo en el roster puede marcar con su DNI, igual
-- que un reloj de asistencia físico. Por eso la tabla no tiene
-- políticas RLS para anon/authenticated: todo el acceso pasa por
-- las funciones RPC de abajo (mismo patrón que b2c_users/b2c_sessions).
-- ============================================================

create table if not exists asis_marcaciones (
  id            bigint generated always as identity primary key,
  dni           varchar not null,
  nombre        text not null,
  puesto        text,
  area          text,
  turno         varchar,
  tipo          varchar not null check (tipo in ('ingreso','almuerzo_inicio','almuerzo_fin','salida')),
  fecha         date not null,
  registrado_en timestamptz not null default now(),
  lat           double precision,
  lng           double precision,
  dispositivo   text,
  editado_por   bigint references b2c_users(id),
  created_at    timestamptz not null default now(),
  unique (dni, fecha, tipo)
);

comment on table asis_marcaciones is 'Marcaciones de asistencia (ingreso/almuerzo/salida). Roster de colaboradores tomado de b2c_asistencia; sin login para marcar, con login compartido (b2c_users) solo para el panel administrativo.';

create index if not exists asis_marcaciones_fecha_idx on asis_marcaciones(fecha);
create index if not exists asis_marcaciones_dni_fecha_idx on asis_marcaciones(dni, fecha);

alter table asis_marcaciones enable row level security;
-- Sin policies: acceso únicamente vía funciones SECURITY DEFINER.

-- ------------------------------------------------------------
-- Buscar colaborador por DNI (pantalla de marcación) + sus
-- marcaciones de hoy, para que el kiosko sepa qué botón sigue.
-- ------------------------------------------------------------
create or replace function public.asis_buscar_dni(p_dni text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_roster record;
  v_fecha date := (now() at time zone 'America/Lima')::date;
  v_marcas json;
begin
  select dni, nombre, puesto, area, turno, estado
  into v_roster
  from public.b2c_asistencia
  where dni = trim(p_dni)
  order by fecha desc
  limit 1;

  if v_roster.dni is null then
    raise exception 'DNI_NO_ENCONTRADO';
  end if;

  if v_roster.estado is distinct from 'ACTIVO' then
    raise exception 'COLABORADOR_INACTIVO';
  end if;

  select coalesce(json_agg(json_build_object('tipo', tipo, 'registrado_en', registrado_en) order by registrado_en), '[]'::json)
  into v_marcas
  from public.asis_marcaciones
  where dni = v_roster.dni and fecha = v_fecha;

  return json_build_object(
    'dni', v_roster.dni,
    'nombre', v_roster.nombre,
    'puesto', v_roster.puesto,
    'area', v_roster.area,
    'turno', v_roster.turno,
    'marcas_hoy', v_marcas
  );
end;
$$;

-- ------------------------------------------------------------
-- Registrar una marcación. Valida DNI activo y la secuencia del
-- día (no se puede marcar fin de almuerzo sin haber marcado
-- inicio, etc.), y evita duplicar el mismo tipo el mismo día.
-- ------------------------------------------------------------
create or replace function public.asis_marcar(
  p_dni text,
  p_tipo text,
  p_lat double precision default null,
  p_lng double precision default null,
  p_dispositivo text default null
)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_roster record;
  v_fecha date := (now() at time zone 'America/Lima')::date;
  v_id bigint;
  v_registrado_en timestamptz;
begin
  if p_tipo not in ('ingreso','almuerzo_inicio','almuerzo_fin','salida') then
    raise exception 'TIPO_INVALIDO';
  end if;

  select dni, nombre, puesto, area, turno, estado
  into v_roster
  from public.b2c_asistencia
  where dni = trim(p_dni)
  order by fecha desc
  limit 1;

  if v_roster.dni is null then
    raise exception 'DNI_NO_ENCONTRADO';
  end if;
  if v_roster.estado is distinct from 'ACTIVO' then
    raise exception 'COLABORADOR_INACTIVO';
  end if;

  if p_tipo in ('almuerzo_inicio','salida') and not exists (
    select 1 from public.asis_marcaciones where dni = v_roster.dni and fecha = v_fecha and tipo = 'ingreso'
  ) then
    raise exception 'FALTA_INGRESO';
  end if;

  if p_tipo = 'almuerzo_fin' and not exists (
    select 1 from public.asis_marcaciones where dni = v_roster.dni and fecha = v_fecha and tipo = 'almuerzo_inicio'
  ) then
    raise exception 'FALTA_INICIO_ALMUERZO';
  end if;

  insert into public.asis_marcaciones (dni, nombre, puesto, area, turno, tipo, fecha, lat, lng, dispositivo)
  values (v_roster.dni, v_roster.nombre, v_roster.puesto, v_roster.area, v_roster.turno, p_tipo, v_fecha, p_lat, p_lng, p_dispositivo)
  on conflict (dni, fecha, tipo) do nothing
  returning id, registrado_en into v_id, v_registrado_en;

  if v_id is null then
    raise exception 'YA_REGISTRADO';
  end if;

  return json_build_object('id', v_id, 'dni', v_roster.dni, 'nombre', v_roster.nombre, 'tipo', p_tipo, 'registrado_en', v_registrado_en);
end;
$$;

-- ------------------------------------------------------------
-- Panel administrativo: reporte por rango de fechas (requiere
-- sesión válida + permiso view.asistencia).
-- ------------------------------------------------------------
create or replace function public.asis_reporte(p_token text, p_desde date, p_hasta date, p_area text default null)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id bigint;
  v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if not exists (select 1 from public.b2c_permisos where rol = v_rol and permiso = 'view.asistencia') then
    raise exception 'SIN_PERMISO';
  end if;

  return coalesce((
    select json_agg(row_to_json(t))
    from (
      select id, dni, nombre, puesto, area, turno, tipo, fecha, registrado_en
      from public.asis_marcaciones
      where fecha between p_desde and p_hasta
        and (p_area is null or p_area = '' or area = p_area)
      order by fecha desc, nombre, registrado_en
    ) t
  ), '[]'::json);
end;
$$;

-- ------------------------------------------------------------
-- Panel administrativo: áreas distintas con marcaciones (para el filtro).
-- ------------------------------------------------------------
create or replace function public.asis_areas(p_token text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id bigint;
begin
  v_user_id := public.b2c_require_session(p_token);
  return coalesce((
    select json_agg(distinct area order by area)
    from public.asis_marcaciones
    where area is not null
  ), '[]'::json);
end;
$$;

-- ------------------------------------------------------------
-- Panel administrativo: corregir o eliminar una marcación.
-- ------------------------------------------------------------
create or replace function public.asis_editar(p_token text, p_id bigint, p_tipo text, p_registrado_en timestamptz)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id bigint;
  v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if not exists (select 1 from public.b2c_permisos where rol = v_rol and permiso = 'view.asistencia') then
    raise exception 'SIN_PERMISO';
  end if;
  if p_tipo not in ('ingreso','almuerzo_inicio','almuerzo_fin','salida') then
    raise exception 'TIPO_INVALIDO';
  end if;

  update public.asis_marcaciones
     set tipo = p_tipo, registrado_en = p_registrado_en, fecha = (p_registrado_en at time zone 'America/Lima')::date, editado_por = v_user_id
   where id = p_id;

  if not found then
    raise exception 'MARCACION_NO_ENCONTRADA';
  end if;
end;
$$;

create or replace function public.asis_eliminar(p_token text, p_id bigint)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id bigint;
  v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if not exists (select 1 from public.b2c_permisos where rol = v_rol and permiso = 'view.asistencia') then
    raise exception 'SIN_PERMISO';
  end if;
  delete from public.asis_marcaciones where id = p_id;
  if not found then
    raise exception 'MARCACION_NO_ENCONTRADA';
  end if;
end;
$$;

grant execute on function public.asis_buscar_dni(text) to anon, authenticated;
grant execute on function public.asis_marcar(text, text, double precision, double precision, text) to anon, authenticated;
grant execute on function public.asis_reporte(text, date, date, text) to anon, authenticated;
grant execute on function public.asis_areas(text) to anon, authenticated;
grant execute on function public.asis_editar(text, bigint, text, timestamptz) to anon, authenticated;
grant execute on function public.asis_eliminar(text, bigint) to anon, authenticated;

-- ------------------------------------------------------------
-- Permiso para ver/administrar el panel de asistencia.
-- ------------------------------------------------------------
insert into public.b2c_permisos_catalogo (permiso, etiqueta, grupo, descripcion, orden)
values ('view.asistencia', 'Control de Asistencia', 'Vistas', 'Panel administrativo de marcaciones de ingreso/almuerzo/salida.', 50)
on conflict (permiso) do nothing;

insert into public.b2c_permisos (rol, permiso)
select rol, 'view.asistencia'
from public.b2c_roles
where rol in ('admin', 'gerencia', 'coordinador', 'rrhh', 'supervisor')
on conflict (rol, permiso) do nothing;
