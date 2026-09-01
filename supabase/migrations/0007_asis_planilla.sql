-- ============================================================
-- Analitica (censo crudo) + calculo de planilla
--
-- asis_censo expone las mismas columnas del censo diario que ya usa
-- el modulo "Asistencia y Rotacion" de Adecco KPI (b2c_asistencia:
-- asistencia con codigos A/V/F/AM/DF/DM/DT/FRD/LCGH/LSGH/P/S,
-- f_ingreso/f_cese/motivo_cese para rotacion). El bucketing de
-- codigos (F.J. = todo lo que no es A/V/F) se hace en el cliente,
-- igual que en asistencia.js, para no duplicar esa regla de negocio
-- en dos lugares que se puedan desincronizar.
--
-- asis_planilla_calcular es el unico calculo de pagos del sistema:
--   - dias_falta:  dias con asistencia = 'F' (falta NO justificada;
--                  las justificadas -F.J.- no descuentan sueldo).
--   - minutos_tardanza: minutos de la marcacion de Ingreso despues
--                  de la hora de inicio de su turno (mismas 3
--                  ventanas que el kiosko: Mañana 6:00, Tarde 12:00,
--                  Noche 20:00 -- si cambian alla, cambiar aqui).
--   - deduccion_faltas    = dias_falta * (sueldo_mensual / 30)
--   - deduccion_tardanzas = (minutos_tardanza / 60) * (sueldo_mensual / 240)
--   - sueldo_neto = sueldo_mensual - deduccion_faltas - deduccion_tardanzas
-- Solo incluye a quien ya tiene un sueldo cargado en asis_sueldos.
-- ============================================================

create or replace function public.asis_censo(p_token text, p_desde date, p_hasta date, p_area text default null)
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
    select json_agg(json_build_object(
      'dni', dni, 'nombre', nombre, 'area', area, 'puesto', puesto, 'turno', turno, 'fecha', fecha,
      'asistencia', asistencia, 'estado', estado, 'f_ingreso', f_ingreso, 'f_cese', f_cese,
      'motivo_cese', motivo_cese, 'estado_antiguedad', estado_antiguedad, 'sexo', sexo
    ))
    from public.b2c_asistencia
    where fecha between p_desde and p_hasta
      and (p_area is null or p_area = '' or area = p_area)
  ), '[]'::json);
end;
$$;

create or replace function public.asis_planilla_calcular(p_token text, p_desde date, p_hasta date, p_area text default null)
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
  if v_rol not in ('admin', 'rrhh') then
    raise exception 'SIN_PERMISO';
  end if;

  return coalesce((
    with roster as (
      select distinct on (dni) dni, nombre, area, puesto
      from public.b2c_asistencia
      where fecha between p_desde and p_hasta
        and (p_area is null or p_area = '' or area = p_area)
      order by dni, fecha desc
    ),
    faltas as (
      select dni, count(*) as dias_falta
      from public.b2c_asistencia
      where fecha between p_desde and p_hasta and upper(trim(asistencia)) = 'F'
      group by dni
    ),
    tardanzas as (
      select dni,
        sum(greatest(0, extract(epoch from (
          (registrado_en at time zone 'America/Lima')::time -
          (case upper(trim(turno))
             when 'MAÑANA' then time '06:00'
             when 'TARDE'  then time '12:00'
             when 'NOCHE'  then time '20:00'
             else null
           end)
        )) / 60.0)) as minutos_tarde
      from public.asis_marcaciones
      where tipo = 'ingreso' and fecha between p_desde and p_hasta
      group by dni
    )
    select json_agg(json_build_object(
      'dni', r.dni, 'nombre', r.nombre, 'area', r.area, 'puesto', r.puesto,
      'sueldo_mensual', s.sueldo_mensual,
      'dias_falta', coalesce(f.dias_falta, 0),
      'minutos_tardanza', round(coalesce(t.minutos_tarde, 0)::numeric, 1),
      'deduccion_faltas', round((coalesce(f.dias_falta, 0) * (s.sueldo_mensual / 30))::numeric, 2),
      'deduccion_tardanzas', round(((coalesce(t.minutos_tarde, 0) / 60.0) * (s.sueldo_mensual / 240))::numeric, 2),
      'sueldo_neto', round((
        s.sueldo_mensual
        - coalesce(f.dias_falta, 0) * (s.sueldo_mensual / 30)
        - (coalesce(t.minutos_tarde, 0) / 60.0) * (s.sueldo_mensual / 240)
      )::numeric, 2)
    ) order by r.nombre)
    from roster r
    join public.asis_sueldos s on s.dni = r.dni
    left join faltas f on f.dni = r.dni
    left join tardanzas t on t.dni = r.dni
  ), '[]'::json);
end;
$$;

grant execute on function public.asis_censo(text, date, date, text) to anon, authenticated;
grant execute on function public.asis_planilla_calcular(text, date, date, text) to anon, authenticated;
