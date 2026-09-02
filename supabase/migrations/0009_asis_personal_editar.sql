-- ============================================================
-- Alta / edicion / baja manual de un colaborador desde el panel
--
-- b2c_asistencia es un censo diario RE-IMPORTADO desde el Excel de
-- RR.HH. (un proceso externo a este proyecto, ver ingest_asistencia.py
-- en PLATAFORMA ADECCO B2C). Esta funcion no reemplaza esa fuente de
-- verdad: escribe/corrige la fila de HOY (o la fecha indicada) para
-- que el kiosko y el panel reflejen el cambio de inmediato (ej. dar
-- de baja a alguien para que deje de poder marcar hoy mismo, agregar
-- a un ingreso nuevo antes de que llegue el proximo censo importado,
-- corregir un cargo/area mal tipeado). Si RR.HH. reimporta el Excel
-- despues sin reflejar el mismo cambio, ese reimport puede pisar esta
-- correccion -- por eso el panel avisa que es una correccion del dia,
-- no un reemplazo del proceso de RR.HH.
-- ============================================================

create or replace function public.asis_personal_guardar(
  p_token text,
  p_dni text,
  p_nombre text,
  p_puesto text default null,
  p_area text default null,
  p_turno text default null,
  p_estado text default 'ACTIVO',
  p_fecha date default null
)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id bigint;
  v_rol varchar;
  v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Lima')::date);
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh') then
    raise exception 'SIN_PERMISO';
  end if;
  if p_dni is null or trim(p_dni) = '' or p_nombre is null or trim(p_nombre) = '' then
    raise exception 'DATOS_INCOMPLETOS';
  end if;

  insert into public.b2c_asistencia (dni, nombre, puesto, area, turno, estado, fecha)
  values (
    trim(p_dni), trim(p_nombre),
    nullif(trim(p_puesto), ''), nullif(trim(p_area), ''), nullif(trim(p_turno), ''),
    coalesce(nullif(trim(upper(p_estado)), ''), 'ACTIVO'),
    v_fecha
  )
  on conflict (dni, fecha) do update set
    nombre = excluded.nombre,
    puesto = excluded.puesto,
    area = excluded.area,
    turno = excluded.turno,
    estado = excluded.estado;

  return json_build_object('dni', trim(p_dni), 'nombre', trim(p_nombre), 'fecha', v_fecha, 'estado', coalesce(nullif(trim(upper(p_estado)), ''), 'ACTIVO'));
end;
$$;

grant execute on function public.asis_personal_guardar(text, text, text, text, text, text, text, date) to anon, authenticated;
