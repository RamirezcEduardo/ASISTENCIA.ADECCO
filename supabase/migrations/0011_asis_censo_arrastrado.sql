-- ============================================================
-- asis_censo: arrastra el ultimo roster conocido por DNI, no exige
-- una fila exacta para cada fecha
--
-- b2c_asistencia se re-importa esporadicamente (a veces pasan varios
-- dias sin un import nuevo), pero el kiosko de marcacion ya asume esto
-- desde el dia uno: asis_buscar_dni/asis_marcar siempre usan "la fila
-- mas reciente por DNI" (order by fecha desc limit 1), sin exigir que
-- exista una fila exacta para HOY. asis_censo en cambio exigia
-- fecha = ese dia exacto, asi que Ausentismo/Rotacion/Personal/Pagos
-- quedaban practicamente vacios en cualquier dia sin import nuevo,
-- aunque el roster (area/puesto/turno/estado) siguiera siendo el
-- mismo -- eso no cambia todos los dias, solo cuando hay una novedad.
--
-- Ahora, para cada dia del rango pedido, se toma la fila mas reciente
-- de cada DNI con fecha <= ese dia (se "arrastra" hacia adelante hasta
-- el proximo import real). La columna "asistencia" (codigo A/V/F/...)
-- es la excepcion: es un hecho de ese dia puntual, no algo que persista,
-- asi que esa SI exige coincidencia exacta de fecha -- si RR.HH. no
-- cargo el codigo de ese dia especifico, queda null (tal como antes).
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
    with dias as (
      select generate_series(p_desde, p_hasta, interval '1 day')::date as dia
    ),
    dnis as (
      select distinct dni from public.b2c_asistencia where fecha <= p_hasta
    ),
    censo_por_dia as (
      select
        d.dia as fecha, n.dni,
        c.nombre, c.area, c.puesto, c.turno, c.estado,
        c.f_ingreso, c.f_cese, c.motivo_cese, c.estado_antiguedad, c.sexo,
        exacto.asistencia
      from dias d
      cross join dnis n
      cross join lateral (
        select nombre, area, puesto, turno, estado, f_ingreso, f_cese, motivo_cese, estado_antiguedad, sexo
        from public.b2c_asistencia b
        where b.dni = n.dni and b.fecha <= d.dia
        order by b.fecha desc
        limit 1
      ) c
      left join public.b2c_asistencia exacto on exacto.dni = n.dni and exacto.fecha = d.dia
    )
    select json_agg(json_build_object(
      'dni', dni, 'nombre', nombre, 'area', area, 'puesto', puesto, 'turno', turno, 'fecha', fecha,
      'asistencia', asistencia, 'estado', estado, 'f_ingreso', f_ingreso, 'f_cese', f_cese,
      'motivo_cese', motivo_cese, 'estado_antiguedad', estado_antiguedad, 'sexo', sexo
    ))
    from censo_por_dia
    where (p_area is null or p_area = '' or area = p_area)
  ), '[]'::json);
end;
$$;

grant execute on function public.asis_censo(text, date, date, text) to anon, authenticated;

-- ------------------------------------------------------------
-- asis_planilla_calcular tenia el mismo problema: su CTE "roster"
-- exigia "fecha between p_desde and p_hasta", asi que en un periodo
-- sin import nuevo la planilla salia vacia aunque el roster (y los
-- sueldos por puesto) siguieran siendo validos. Se cambia a "el
-- roster mas reciente conocido hasta el final del periodo"
-- (fecha <= p_hasta), igual que ya hacen asis_buscar_dni/asis_marcar.
-- ------------------------------------------------------------
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
      where fecha <= p_hasta
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
    join public.asis_sueldos_puesto s on s.puesto = r.puesto
    left join faltas f on f.dni = r.dni
    left join tardanzas t on t.dni = r.dni
  ), '[]'::json);
end;
$$;

grant execute on function public.asis_planilla_calcular(text, date, date, text) to anon, authenticated;
