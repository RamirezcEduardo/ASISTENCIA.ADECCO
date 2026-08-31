-- ============================================================
-- La foto deja de ser opcional en Ingreso/Salida.
--
-- La app ya no ofrece "continuar sin foto" (decisión del usuario:
-- no se quieren registros de asistencia sin evidencia). Esto lo
-- refuerza también a nivel de base de datos: aunque alguien llame
-- a asis_marcar directo (la anon key es pública, está en el HTML),
-- no puede crear un Ingreso/Salida sin foto_path.
-- ============================================================

create or replace function public.asis_marcar(
  p_dni text,
  p_tipo text,
  p_lat double precision default null,
  p_lng double precision default null,
  p_dispositivo text default null,
  p_foto_path text default null
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

  if p_tipo in ('ingreso','salida') and (p_foto_path is null or p_foto_path = '') then
    raise exception 'FOTO_REQUERIDA';
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

  insert into public.asis_marcaciones (dni, nombre, puesto, area, turno, tipo, fecha, lat, lng, dispositivo, foto_path)
  values (v_roster.dni, v_roster.nombre, v_roster.puesto, v_roster.area, v_roster.turno, p_tipo, v_fecha, p_lat, p_lng, p_dispositivo, p_foto_path)
  on conflict (dni, fecha, tipo) do nothing
  returning id, registrado_en into v_id, v_registrado_en;

  if v_id is null then
    raise exception 'YA_REGISTRADO';
  end if;

  return json_build_object('id', v_id, 'dni', v_roster.dni, 'nombre', v_roster.nombre, 'tipo', p_tipo, 'registrado_en', v_registrado_en, 'foto_path', p_foto_path);
end;
$$;

comment on column public.asis_marcaciones.foto_path is 'Ruta del archivo en el bucket público "asis-fotos". Obligatoria para tipo ingreso/salida (asis_marcar la rechaza si falta); siempre null en almuerzo_inicio/almuerzo_fin.';
