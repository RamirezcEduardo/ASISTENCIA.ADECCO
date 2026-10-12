-- ============================================================
-- Picking: funcion diaria de cada colaborador (Picking, Embalaje,
-- Troquelado, Shortpick, ...) + catalogo configurable de funciones.
--
-- Los supervisores asignan cada dia que funcion cumple su personal, para
-- mapear como varia la distribucion. El catalogo (asis_funciones) alimenta
-- el desplegable y se administra desde Configuracion: desactivar una
-- funcion la quita del desplegable sin perder el historial; renombrarla
-- corrige tambien las asignaciones ya guardadas (sirve para typos).
-- ============================================================

create table if not exists public.asis_funciones (
  id         bigint generated always as identity primary key,
  nombre     varchar(40) not null,
  orden      int not null default 0,
  activo     boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists asis_funciones_nombre_uq on public.asis_funciones (upper(nombre));

create table if not exists public.asis_picking_asignaciones (
  dni          varchar not null,
  fecha        date not null,
  funcion      varchar(40) not null,
  asignado_por bigint,
  updated_at   timestamptz not null default now(),
  primary key (dni, fecha)
);
create index if not exists asis_picking_asig_fecha_idx on public.asis_picking_asignaciones (fecha);

alter table public.asis_funciones enable row level security;
alter table public.asis_picking_asignaciones enable row level security;
-- Sin policies: acceso solo via funciones SECURITY DEFINER.

insert into public.asis_funciones (nombre, orden) values
  ('Picking', 1), ('Embalaje', 2), ('Troquelado', 3), ('Shortpick', 4)
on conflict do nothing;

-- Catalogo (incluye inactivas; el panel filtra).
create or replace function public.asis_funciones_listar(p_token text)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if not exists (select 1 from public.b2c_permisos where rol = v_rol and permiso = 'view.asistencia') then
    raise exception 'SIN_PERMISO';
  end if;
  return coalesce((select json_agg(json_build_object('id', id, 'nombre', nombre, 'orden', orden, 'activo', activo) order by orden, nombre)
                   from public.asis_funciones), '[]'::json);
end; $$;

-- Alta / edicion de una funcion (Configuracion).
create or replace function public.asis_funcion_guardar(p_token text, p_id bigint default null, p_nombre text default null,
                                                       p_activo boolean default true, p_orden int default null)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar; v_nombre text := regexp_replace(trim(coalesce(p_nombre, '')), '\s+', ' ', 'g'); v_old text; v_id bigint;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh', 'coordinador') then raise exception 'SIN_PERMISO'; end if;
  if length(v_nombre) < 2 or length(v_nombre) > 40 then raise exception 'DATOS_INCOMPLETOS'; end if;
  begin
    if p_id is null then
      insert into public.asis_funciones (nombre, orden, activo)
      values (v_nombre, coalesce(p_orden, (select coalesce(max(orden), 0) + 1 from public.asis_funciones)), coalesce(p_activo, true))
      returning id into v_id;
    else
      select nombre into v_old from public.asis_funciones where id = p_id;
      if v_old is null then raise exception 'FUNCION_NO_ENCONTRADA'; end if;
      update public.asis_funciones set nombre = v_nombre, activo = coalesce(p_activo, activo), orden = coalesce(p_orden, orden) where id = p_id;
      if upper(v_old) <> upper(v_nombre) or v_old <> v_nombre then
        update public.asis_picking_asignaciones set funcion = v_nombre where upper(funcion) = upper(v_old);
      end if;
      v_id := p_id;
    end if;
  exception when unique_violation then
    raise exception 'FUNCION_DUPLICADA';
  end;
  return json_build_object('id', v_id, 'nombre', v_nombre);
end; $$;

-- Foto del dia: activos a esa fecha (ultimo registro por DNI <= fecha) + su funcion asignada + hora de ingreso.
create or replace function public.asis_picking_dia(p_token text, p_fecha date default null)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar; v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Lima')::date);
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if not exists (select 1 from public.b2c_permisos where rol = v_rol and permiso = 'view.asistencia') then
    raise exception 'SIN_PERMISO';
  end if;
  return coalesce((
    with roster as (
      select distinct on (dni) dni, nombre, puesto, area, turno, supervisor, estado
      from public.b2c_asistencia where fecha <= v_fecha order by dni, fecha desc
    ),
    ing as (
      select dni, min(registrado_en) as ingreso from public.asis_marcaciones where fecha = v_fecha and tipo = 'ingreso' group by dni
    )
    select json_agg(json_build_object(
      'dni', r.dni, 'nombre', r.nombre, 'puesto', r.puesto, 'area', r.area, 'turno', r.turno, 'supervisor', r.supervisor,
      'funcion', a.funcion, 'asignado_por', u.nombre, 'asignado_en', a.updated_at, 'ingreso', i.ingreso
    ) order by r.nombre)
    from roster r
    left join public.asis_picking_asignaciones a on a.dni = r.dni and a.fecha = v_fecha
    left join public.b2c_users u on u.id = a.asignado_por
    left join ing i on i.dni = r.dni
    where upper(trim(r.estado)) = 'ACTIVO'
  ), '[]'::json);
end; $$;

-- Asignar la misma funcion a uno o varios DNI en una fecha (funcion vacia = quitar la asignacion).
create or replace function public.asis_picking_asignar(p_token text, p_fecha date, p_dnis text[], p_funcion text default null)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar; v_hoy date := (now() at time zone 'America/Lima')::date; v_func text; v_n int;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh', 'coordinador', 'supervisor') then raise exception 'SIN_PERMISO'; end if;
  if p_fecha is null or p_fecha < v_hoy - 14 or p_fecha > v_hoy + 1 then raise exception 'FECHA_FUERA_DE_RANGO'; end if;
  if coalesce(array_length(p_dnis, 1), 0) = 0 then raise exception 'DATOS_INCOMPLETOS'; end if;

  if nullif(trim(coalesce(p_funcion, '')), '') is null then
    delete from public.asis_picking_asignaciones where fecha = p_fecha and dni = any(p_dnis);
    get diagnostics v_n = row_count;
    return json_build_object('fecha', p_fecha, 'funcion', null, 'afectados', v_n);
  end if;

  select nombre into v_func from public.asis_funciones where upper(nombre) = upper(trim(p_funcion)) and activo;
  if v_func is null then raise exception 'FUNCION_INVALIDA'; end if;

  insert into public.asis_picking_asignaciones (dni, fecha, funcion, asignado_por, updated_at)
  select distinct trim(d), p_fecha, v_func, v_user_id, now() from unnest(p_dnis) as d
  where exists (select 1 from public.b2c_asistencia b where b.dni = trim(d))
  on conflict (dni, fecha) do update set funcion = excluded.funcion, asignado_por = excluded.asignado_por, updated_at = now();
  get diagnostics v_n = row_count;
  return json_build_object('fecha', p_fecha, 'funcion', v_func, 'afectados', v_n);
end; $$;

-- Copiar la distribucion de un dia a otro, solo para los DNI indicados y solo donde no hay asignacion todavia.
create or replace function public.asis_picking_copiar(p_token text, p_desde date, p_hasta date, p_dnis text[])
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar; v_hoy date := (now() at time zone 'America/Lima')::date; v_n int;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh', 'coordinador', 'supervisor') then raise exception 'SIN_PERMISO'; end if;
  if p_hasta is null or p_hasta < v_hoy - 14 or p_hasta > v_hoy + 1 or p_desde is null then raise exception 'FECHA_FUERA_DE_RANGO'; end if;
  if coalesce(array_length(p_dnis, 1), 0) = 0 then raise exception 'DATOS_INCOMPLETOS'; end if;
  insert into public.asis_picking_asignaciones (dni, fecha, funcion, asignado_por, updated_at)
  select a.dni, p_hasta, a.funcion, v_user_id, now()
  from public.asis_picking_asignaciones a
  where a.fecha = p_desde and a.dni = any(p_dnis)
    and exists (select 1 from public.asis_funciones f where upper(f.nombre) = upper(a.funcion) and f.activo)
  on conflict (dni, fecha) do nothing;
  get diagnostics v_n = row_count;
  return json_build_object('copiados', v_n);
end; $$;

-- Historial crudo para el grafico de evolucion (el panel agrupa y aplica Area/Zona).
create or replace function public.asis_picking_rango(p_token text, p_desde date, p_hasta date)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if not exists (select 1 from public.b2c_permisos where rol = v_rol and permiso = 'view.asistencia') then
    raise exception 'SIN_PERMISO';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 92 then raise exception 'DATOS_INCOMPLETOS'; end if;
  return coalesce((select json_agg(json_build_object('dni', dni, 'fecha', fecha, 'funcion', funcion))
                   from public.asis_picking_asignaciones where fecha between p_desde and p_hasta), '[]'::json);
end; $$;

grant execute on function public.asis_funciones_listar(text) to anon, authenticated;
grant execute on function public.asis_funcion_guardar(text, bigint, text, boolean, int) to anon, authenticated;
grant execute on function public.asis_picking_dia(text, date) to anon, authenticated;
grant execute on function public.asis_picking_asignar(text, date, text[], text) to anon, authenticated;
grant execute on function public.asis_picking_copiar(text, date, date, text[]) to anon, authenticated;
grant execute on function public.asis_picking_rango(text, date, date) to anon, authenticated;
