-- ============================================================
-- Reporte enriquecido para exportar a Excel con el formato de
-- RR.HH. (mismos encabezados que su maestro b2c_asistencia), más
-- las 4 horas de marcación capturadas por el kiosko.
--
-- Se deja aparte de asis_reporte (que sigue alimentando la tabla
-- en pantalla, liviana) porque este trae columnas de RR.HH. que
-- no hacen falta en el panel — solo al exportar.
--
-- El cruce con b2c_asistencia es por (dni, fecha) exacto; si ese
-- día no tiene fila importada todavía, cae a la más reciente
-- anterior para ese DNI (lateral + order by coincidencia exacta
-- primero, luego fecha desc).
-- ============================================================

create or replace function public.asis_reporte_rrhh(p_token text, p_desde date, p_hasta date, p_area text default null)
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
      select
        m.dni,
        m.nombre,
        m.puesto,
        m.area,
        m.turno,
        m.fecha,
        max(m.registrado_en) filter (where m.tipo = 'ingreso')         as ingreso,
        max(m.registrado_en) filter (where m.tipo = 'almuerzo_inicio') as almuerzo_inicio,
        max(m.registrado_en) filter (where m.tipo = 'almuerzo_fin')    as almuerzo_fin,
        max(m.registrado_en) filter (where m.tipo = 'salida')          as salida,
        r.estado, r.motivo_cese, r.f_ingreso, r.f_cese, r.asistencia, r.supervisor,
        r.antiguedad_dias, r.antiguedad_semanas, r.estado_antiguedad, r.sexo
      from public.asis_marcaciones m
      left join lateral (
        select b.*
        from public.b2c_asistencia b
        where b.dni = m.dni and b.fecha <= m.fecha
        order by (b.fecha = m.fecha) desc, b.fecha desc
        limit 1
      ) r on true
      where m.fecha between p_desde and p_hasta
        and (p_area is null or p_area = '' or m.area = p_area)
      group by m.dni, m.nombre, m.puesto, m.area, m.turno, m.fecha,
        r.estado, r.motivo_cese, r.f_ingreso, r.f_cese, r.asistencia, r.supervisor,
        r.antiguedad_dias, r.antiguedad_semanas, r.estado_antiguedad, r.sexo
      order by m.fecha desc, m.nombre
    ) t
  ), '[]'::json);
end;
$$;

grant execute on function public.asis_reporte_rrhh(text, date, date, text) to anon, authenticated;
