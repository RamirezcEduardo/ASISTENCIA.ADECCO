-- ============================================================
-- Actualizacion masiva del censo desde el Excel de ACTIVOS + registro de
-- movimientos de personal (altas, bajas/renuncias, reingresos y cambios de
-- turno / area / puesto / supervisor).
--
-- - asis_personal_actual     : ultimo registro de cada persona (para comparar con el Excel).
-- - asis_importar_aplicar    : escribe el censo del dia con lo que confirmo el usuario y registra cada movimiento.
-- - asis_movimientos_listar  : historial de movimientos por rango de fechas.
-- - asis_importaciones_listar: cargas realizadas (archivo, quien, cuando, totales).
-- - asis_personal_guardar    : (reemplaza la de 0009) ahora conserva supervisor / fecha de ingreso al
--                              crear la fila del dia y deja registrado el movimiento.
-- ============================================================

create table if not exists public.asis_importaciones (
  id             bigint generated always as identity primary key,
  fecha          date not null,
  archivo        varchar(200),
  usuario_id     bigint,
  usuario_nombre varchar(120),
  activos        int not null default 0,
  nuevos         int not null default 0,
  reingresos     int not null default 0,
  cambios        int not null default 0,
  bajas          int not null default 0,
  mantenidos     int not null default 0,
  created_at     timestamptz not null default now()
);

create table if not exists public.asis_movimientos (
  id             bigint generated always as identity primary key,
  importacion_id bigint references public.asis_importaciones(id) on delete set null,
  fecha          date not null,
  dni            varchar not null,
  nombre         varchar,
  tipo           varchar(12) not null,      -- ALTA | BAJA | REINGRESO | CAMBIO
  campo          varchar(20),               -- turno | area | puesto | supervisor (solo CAMBIO)
  valor_anterior text,
  valor_nuevo    text,
  motivo         text,
  usuario_nombre varchar(120),
  created_at     timestamptz not null default now()
);
create index if not exists asis_movimientos_fecha_idx on public.asis_movimientos (fecha desc);
create index if not exists asis_movimientos_dni_idx   on public.asis_movimientos (dni);

alter table public.asis_importaciones enable row level security;
alter table public.asis_movimientos   enable row level security;
-- Sin policies: acceso solo via funciones SECURITY DEFINER.

-- ------------------------------------------------------------
-- Ultimo registro de cada persona (incluye cesados): base para comparar el Excel.
-- ------------------------------------------------------------
create or replace function public.asis_personal_actual(p_token text)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh', 'coordinador', 'gerencia') then raise exception 'SIN_PERMISO'; end if;
  return coalesce((
    select json_agg(json_build_object(
      'dni', t.dni, 'nombre', t.nombre, 'estado', t.estado, 'area', t.area, 'puesto', t.puesto, 'turno', t.turno,
      'supervisor', t.supervisor, 'f_ingreso', t.f_ingreso, 'f_cese', t.f_cese, 'motivo_cese', t.motivo_cese, 'fecha', t.fecha))
    from (
      select distinct on (dni) dni, nombre, estado, area, puesto, turno, supervisor, f_ingreso, f_cese, motivo_cese, fecha
      from public.b2c_asistencia order by dni, fecha desc
    ) t
  ), '[]'::json);
end; $$;

-- ------------------------------------------------------------
-- Aplica la carga: p_activos = personas del Excel (quedan ACTIVAS con esos datos), p_bajas = personas que el
-- usuario confirmo dar de baja ({dni, motivo, f_cese}), p_mantener = DNIs activos que no venian en el Excel y
-- el usuario decidio conservar (se copian al censo del dia para que no desaparezcan de "ultimo dia").
-- Re-cargar el mismo archivo no cambia nada ni genera movimientos.
-- ------------------------------------------------------------
create or replace function public.asis_importar_aplicar(
  p_token text, p_fecha date, p_archivo text,
  p_activos jsonb, p_bajas jsonb default '[]'::jsonb, p_mantener jsonb default '[]'::jsonb)
returns json language plpgsql security definer set search_path to 'public' as $$
declare
  v_user_id bigint; v_rol varchar; v_unombre varchar;
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Lima')::date);
  v_imp bigint;
  a jsonb; b jsonb; m jsonb;
  prev public.b2c_asistencia%rowtype;
  v_hay boolean; v_rein boolean;
  v_dni text; v_nom text; v_area text; v_puesto text; v_turno text; v_sup text; v_fing date;
  v_motivo text; v_fcese date; v_dnis_act text[];
  n_act int := 0; n_nuevos int := 0; n_rein int := 0; n_camb int := 0; n_bajas int := 0; n_mant int := 0;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol, nombre into v_rol, v_unombre from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh') then raise exception 'SIN_PERMISO'; end if;
  if v_fecha < v_hoy - 7 or v_fecha > v_hoy then raise exception 'FECHA_FUERA_DE_RANGO'; end if;
  if p_activos is null or jsonb_typeof(p_activos) <> 'array' or jsonb_array_length(p_activos) = 0 or jsonb_array_length(p_activos) > 5000 then
    raise exception 'DATOS_INCOMPLETOS';
  end if;
  p_bajas := coalesce(p_bajas, '[]'::jsonb);
  p_mantener := coalesce(p_mantener, '[]'::jsonb);
  if jsonb_typeof(p_bajas) <> 'array' or jsonb_array_length(p_bajas) > 3000 or jsonb_typeof(p_mantener) <> 'array' or jsonb_array_length(p_mantener) > 3000 then
    raise exception 'DATOS_INCOMPLETOS';
  end if;

  insert into public.asis_importaciones (fecha, archivo, usuario_id, usuario_nombre)
  values (v_fecha, left(coalesce(p_archivo, ''), 200), v_user_id, v_unombre) returning id into v_imp;

  -- 1) Personas del Excel: quedan ACTIVAS con los datos del archivo.
  for a in select * from jsonb_array_elements(p_activos) loop
    v_dni := trim(coalesce(a->>'dni', ''));
    continue when v_dni = '';
    select * into prev from public.b2c_asistencia where dni = v_dni and fecha <= v_fecha order by fecha desc limit 1;
    v_hay := found;
    v_rein := v_hay and upper(trim(coalesce(prev.estado, ''))) <> 'ACTIVO';
    v_nom    := coalesce(nullif(trim(prev.nombre), ''), nullif(trim(a->>'nombre'), ''), v_dni);
    v_area   := coalesce(nullif(trim(a->>'area'), ''), prev.area);
    v_puesto := coalesce(nullif(trim(a->>'puesto'), ''), prev.puesto);
    v_turno  := coalesce(nullif(trim(a->>'turno'), ''), prev.turno);
    v_sup    := coalesce(nullif(trim(a->>'supervisor'), ''), prev.supervisor);
    -- La fecha de ingreso es un hecho historico: solo se toma del Excel si no hay una o si la persona reingresa.
    v_fing   := case when v_hay and not v_rein and prev.f_ingreso is not null
                     then prev.f_ingreso else coalesce(nullif(a->>'f_ingreso', '')::date, prev.f_ingreso) end;
    n_act := n_act + 1;

    if not v_hay then
      n_nuevos := n_nuevos + 1;
      insert into public.asis_movimientos (importacion_id, fecha, dni, nombre, tipo, valor_nuevo, usuario_nombre)
      values (v_imp, v_fecha, v_dni, v_nom, 'ALTA', concat_ws(' · ', v_area, v_turno, v_sup), v_unombre);
    elsif v_rein then
      n_rein := n_rein + 1;
      insert into public.asis_movimientos (importacion_id, fecha, dni, nombre, tipo, valor_anterior, valor_nuevo, motivo, usuario_nombre)
      values (v_imp, v_fecha, v_dni, v_nom, 'REINGRESO', concat_ws(' · ', prev.area, prev.turno, prev.supervisor), concat_ws(' · ', v_area, v_turno, v_sup), prev.motivo_cese, v_unombre);
    else
      -- Cambios de turno / area / puesto / supervisor (solo si el Excel trae un valor distinto y no vacio).
      if upper(trim(coalesce(prev.turno, ''))) <> upper(trim(coalesce(v_turno, ''))) then
        n_camb := n_camb + 1;
        insert into public.asis_movimientos (importacion_id, fecha, dni, nombre, tipo, campo, valor_anterior, valor_nuevo, usuario_nombre)
        values (v_imp, v_fecha, v_dni, v_nom, 'CAMBIO', 'turno', prev.turno, v_turno, v_unombre);
      end if;
      if upper(trim(coalesce(prev.area, ''))) <> upper(trim(coalesce(v_area, ''))) then
        n_camb := n_camb + 1;
        insert into public.asis_movimientos (importacion_id, fecha, dni, nombre, tipo, campo, valor_anterior, valor_nuevo, usuario_nombre)
        values (v_imp, v_fecha, v_dni, v_nom, 'CAMBIO', 'area', prev.area, v_area, v_unombre);
      end if;
      if upper(trim(coalesce(prev.puesto, ''))) <> upper(trim(coalesce(v_puesto, ''))) then
        n_camb := n_camb + 1;
        insert into public.asis_movimientos (importacion_id, fecha, dni, nombre, tipo, campo, valor_anterior, valor_nuevo, usuario_nombre)
        values (v_imp, v_fecha, v_dni, v_nom, 'CAMBIO', 'puesto', prev.puesto, v_puesto, v_unombre);
      end if;
      if upper(trim(coalesce(prev.supervisor, ''))) <> upper(trim(coalesce(v_sup, ''))) then
        n_camb := n_camb + 1;
        insert into public.asis_movimientos (importacion_id, fecha, dni, nombre, tipo, campo, valor_anterior, valor_nuevo, usuario_nombre)
        values (v_imp, v_fecha, v_dni, v_nom, 'CAMBIO', 'supervisor', prev.supervisor, v_sup, v_unombre);
      end if;
    end if;

    insert into public.b2c_asistencia (dni, nombre, estado, fecha, area, puesto, turno, supervisor, f_ingreso, f_cese, motivo_cese, estado_antiguedad, sexo)
    values (v_dni, v_nom, 'ACTIVO', v_fecha, v_area, v_puesto, v_turno, v_sup, v_fing, null, null,
            case when v_rein then null else prev.estado_antiguedad end, prev.sexo)
    on conflict (dni, fecha) do update set
      nombre = excluded.nombre, estado = 'ACTIVO', area = excluded.area, puesto = excluded.puesto, turno = excluded.turno,
      supervisor = excluded.supervisor, f_ingreso = excluded.f_ingreso, f_cese = null, motivo_cese = null;
      -- (la columna "asistencia" del dia, si RR.HH. ya la cargo, no se toca)
  end loop;

  -- 2) Bajas confirmadas: pasan a CESADO con su motivo y fecha de cese. Quien viene en el Excel nunca se da de baja.
  select coalesce(array_agg(trim(coalesce(x->>'dni', ''))), '{}') into v_dnis_act from jsonb_array_elements(p_activos) x;
  for b in select * from jsonb_array_elements(p_bajas) loop
    v_dni := trim(coalesce(b->>'dni', ''));
    continue when v_dni = '' or v_dni = any(v_dnis_act);
    select * into prev from public.b2c_asistencia where dni = v_dni and fecha <= v_fecha order by fecha desc limit 1;
    continue when not found or upper(trim(coalesce(prev.estado, ''))) <> 'ACTIVO';
    v_motivo := coalesce(nullif(trim(b->>'motivo'), ''), 'No figura en el listado de activos');
    v_fcese  := coalesce(nullif(b->>'f_cese', '')::date, v_fecha);
    n_bajas := n_bajas + 1;
    insert into public.b2c_asistencia (dni, nombre, estado, fecha, area, puesto, turno, supervisor, f_ingreso, f_cese, motivo_cese, estado_antiguedad, sexo)
    values (v_dni, prev.nombre, 'CESADO', v_fecha, prev.area, prev.puesto, prev.turno, prev.supervisor, prev.f_ingreso, v_fcese, v_motivo, prev.estado_antiguedad, prev.sexo)
    on conflict (dni, fecha) do update set estado = 'CESADO', f_cese = excluded.f_cese, motivo_cese = excluded.motivo_cese;
    insert into public.asis_movimientos (importacion_id, fecha, dni, nombre, tipo, valor_anterior, motivo, usuario_nombre)
    values (v_imp, v_fcese, v_dni, prev.nombre, 'BAJA', concat_ws(' · ', prev.area, prev.turno, prev.supervisor), v_motivo, v_unombre);
  end loop;

  -- 3) Activos que no venian en el Excel y se conservan: se copian al censo del dia tal cual.
  for m in select * from jsonb_array_elements(p_mantener) loop
    v_dni := trim(coalesce(m #>> '{}', ''));
    continue when v_dni = '';
    select * into prev from public.b2c_asistencia where dni = v_dni and fecha <= v_fecha order by fecha desc limit 1;
    continue when not found or upper(trim(coalesce(prev.estado, ''))) <> 'ACTIVO' or prev.fecha = v_fecha;
    n_mant := n_mant + 1;
    insert into public.b2c_asistencia (dni, nombre, estado, fecha, area, puesto, turno, supervisor, f_ingreso, f_cese, motivo_cese, estado_antiguedad, sexo)
    values (v_dni, prev.nombre, 'ACTIVO', v_fecha, prev.area, prev.puesto, prev.turno, prev.supervisor, prev.f_ingreso, null, null, prev.estado_antiguedad, prev.sexo)
    on conflict (dni, fecha) do nothing;
  end loop;

  update public.asis_importaciones
     set activos = n_act, nuevos = n_nuevos, reingresos = n_rein, cambios = n_camb, bajas = n_bajas, mantenidos = n_mant
   where id = v_imp;

  return json_build_object('importacion_id', v_imp, 'fecha', v_fecha, 'activos', n_act, 'nuevos', n_nuevos,
                           'reingresos', n_rein, 'cambios', n_camb, 'bajas', n_bajas, 'mantenidos', n_mant);
end; $$;

-- ------------------------------------------------------------
-- Historial de movimientos (por rango de fechas del movimiento).
-- ------------------------------------------------------------
create or replace function public.asis_movimientos_listar(p_token text, p_desde date, p_hasta date)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh', 'coordinador', 'gerencia') then raise exception 'SIN_PERMISO'; end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 400 then raise exception 'DATOS_INCOMPLETOS'; end if;
  return coalesce((
    select json_agg(json_build_object(
      'id', id, 'importacion_id', importacion_id, 'fecha', fecha, 'dni', dni, 'nombre', nombre, 'tipo', tipo, 'campo', campo,
      'valor_anterior', valor_anterior, 'valor_nuevo', valor_nuevo, 'motivo', motivo, 'usuario', usuario_nombre, 'creado', created_at)
      order by fecha desc, id desc)
    from (select * from public.asis_movimientos where fecha between p_desde and p_hasta order by fecha desc, id desc limit 8000) x
  ), '[]'::json);
end; $$;

create or replace function public.asis_importaciones_listar(p_token text)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh', 'coordinador', 'gerencia') then raise exception 'SIN_PERMISO'; end if;
  return coalesce((
    select json_agg(json_build_object(
      'id', id, 'fecha', fecha, 'archivo', archivo, 'usuario', usuario_nombre, 'activos', activos, 'nuevos', nuevos,
      'reingresos', reingresos, 'cambios', cambios, 'bajas', bajas, 'mantenidos', mantenidos, 'creado', created_at)
      order by id desc)
    from (select * from public.asis_importaciones order by id desc limit 40) x
  ), '[]'::json);
end; $$;

-- ------------------------------------------------------------
-- Alta / edicion / baja manual (reemplaza la de 0009). Mejoras:
--  * al crear la fila del dia copia supervisor, fecha de ingreso, sexo y antiguedad de la fila anterior
--    (antes quedaban vacios y la persona desaparecia de la lista de su supervisor);
--  * al dar de baja guarda fecha y motivo de cese;
--  * deja registrado el movimiento (alta, baja, reingreso o cambio de turno / area / puesto).
-- ------------------------------------------------------------
create or replace function public.asis_personal_guardar(
  p_token text, p_dni text, p_nombre text, p_puesto text default null, p_area text default null,
  p_turno text default null, p_estado text default 'ACTIVO', p_fecha date default null)
returns json language plpgsql security definer set search_path to 'public' as $$
declare
  v_user_id bigint; v_rol varchar; v_unombre varchar;
  v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Lima')::date);
  v_dni text := trim(coalesce(p_dni, ''));
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_estado text := coalesce(nullif(trim(upper(p_estado)), ''), 'ACTIVO');
  v_puesto text := nullif(trim(p_puesto), ''); v_area text := nullif(trim(p_area), ''); v_turno text := nullif(trim(p_turno), '');
  prev public.b2c_asistencia%rowtype;
  v_hay boolean;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol, nombre into v_rol, v_unombre from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh') then raise exception 'SIN_PERMISO'; end if;
  if v_dni = '' or v_nombre = '' then raise exception 'DATOS_INCOMPLETOS'; end if;

  select * into prev from public.b2c_asistencia where dni = v_dni and fecha <= v_fecha order by fecha desc limit 1;
  v_hay := found;

  insert into public.b2c_asistencia (dni, nombre, puesto, area, turno, estado, fecha, supervisor, f_ingreso, f_cese, motivo_cese, estado_antiguedad, sexo)
  values (v_dni, v_nombre, v_puesto, v_area, v_turno, v_estado, v_fecha, prev.supervisor, prev.f_ingreso,
          case when v_estado = 'ACTIVO' then null else coalesce(prev.f_cese, v_fecha) end,
          case when v_estado = 'ACTIVO' then null else coalesce(prev.motivo_cese, 'Baja registrada desde el panel') end,
          prev.estado_antiguedad, prev.sexo)
  on conflict (dni, fecha) do update set
    nombre = excluded.nombre, puesto = excluded.puesto, area = excluded.area, turno = excluded.turno, estado = excluded.estado,
    f_cese = case when excluded.estado = 'ACTIVO' then null else coalesce(public.b2c_asistencia.f_cese, excluded.f_cese) end,
    motivo_cese = case when excluded.estado = 'ACTIVO' then null else coalesce(public.b2c_asistencia.motivo_cese, excluded.motivo_cese) end;

  -- Registro del movimiento
  if not v_hay then
    insert into public.asis_movimientos (fecha, dni, nombre, tipo, valor_nuevo, motivo, usuario_nombre)
    values (v_fecha, v_dni, v_nombre, case when v_estado = 'ACTIVO' then 'ALTA' else 'BAJA' end, concat_ws(' · ', v_area, v_turno), 'Registro manual desde el panel', v_unombre);
  elsif upper(trim(coalesce(prev.estado, ''))) = 'ACTIVO' and v_estado <> 'ACTIVO' then
    insert into public.asis_movimientos (fecha, dni, nombre, tipo, valor_anterior, motivo, usuario_nombre)
    values (v_fecha, v_dni, v_nombre, 'BAJA', concat_ws(' · ', prev.area, prev.turno, prev.supervisor), 'Baja registrada desde el panel', v_unombre);
  elsif upper(trim(coalesce(prev.estado, ''))) <> 'ACTIVO' and v_estado = 'ACTIVO' then
    insert into public.asis_movimientos (fecha, dni, nombre, tipo, valor_anterior, valor_nuevo, motivo, usuario_nombre)
    values (v_fecha, v_dni, v_nombre, 'REINGRESO', concat_ws(' · ', prev.area, prev.turno, prev.supervisor), concat_ws(' · ', v_area, v_turno, prev.supervisor), prev.motivo_cese, v_unombre);
  else
    if v_turno is not null and upper(trim(coalesce(prev.turno, ''))) <> upper(v_turno) then
      insert into public.asis_movimientos (fecha, dni, nombre, tipo, campo, valor_anterior, valor_nuevo, usuario_nombre)
      values (v_fecha, v_dni, v_nombre, 'CAMBIO', 'turno', prev.turno, v_turno, v_unombre);
    end if;
    if v_area is not null and upper(trim(coalesce(prev.area, ''))) <> upper(v_area) then
      insert into public.asis_movimientos (fecha, dni, nombre, tipo, campo, valor_anterior, valor_nuevo, usuario_nombre)
      values (v_fecha, v_dni, v_nombre, 'CAMBIO', 'area', prev.area, v_area, v_unombre);
    end if;
    if v_puesto is not null and upper(trim(coalesce(prev.puesto, ''))) <> upper(v_puesto) then
      insert into public.asis_movimientos (fecha, dni, nombre, tipo, campo, valor_anterior, valor_nuevo, usuario_nombre)
      values (v_fecha, v_dni, v_nombre, 'CAMBIO', 'puesto', prev.puesto, v_puesto, v_unombre);
    end if;
  end if;

  return json_build_object('dni', v_dni, 'nombre', v_nombre, 'fecha', v_fecha, 'estado', v_estado);
end; $$;

grant execute on function public.asis_personal_actual(text) to anon, authenticated;
grant execute on function public.asis_importar_aplicar(text, date, text, jsonb, jsonb, jsonb) to anon, authenticated;
grant execute on function public.asis_movimientos_listar(text, date, date) to anon, authenticated;
grant execute on function public.asis_importaciones_listar(text) to anon, authenticated;
grant execute on function public.asis_personal_guardar(text, text, text, text, text, text, text, date) to anon, authenticated;
