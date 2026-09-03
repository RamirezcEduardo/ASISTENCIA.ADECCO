-- ============================================================
-- Sueldos por PUESTO, no por persona
--
-- El sueldo es fijo por cargo (ej. "Montacarguista", "Supervisor"),
-- no negociado individualmente -- pedir un sueldo por cada uno de los
-- ~490 colaboradores activos era trabajo innecesario para RR.HH. y no
-- reflejaba como funciona la planilla real. Con esto basta con cargar
-- el sueldo de cada uno de los (pocos) puestos distintos que existen
-- en el roster para que TODOS los colaboradores de ese puesto queden
-- cubiertos en el calculo.
--
-- Nadie habia guardado un sueldo todavia con el esquema anterior
-- (asis_sueldos por DNI), asi que se reemplaza limpio, sin migrar datos.
-- ============================================================

drop function if exists public.asis_sueldos_listar(text);
drop function if exists public.asis_sueldos_guardar(text, text, numeric);
drop table if exists public.asis_sueldos;

create table public.asis_sueldos_puesto (
  puesto         varchar primary key,
  sueldo_mensual numeric(10,2) not null check (sueldo_mensual >= 0),
  updated_at     timestamptz not null default now()
);

comment on table public.asis_sueldos_puesto is 'Sueldo mensual base por puesto/cargo (fijo, no por persona), mantenido a mano en el panel de Pagos. Fuente de verdad para el calculo de planilla (asis_planilla_calcular).';

alter table public.asis_sueldos_puesto enable row level security;
-- Sin policies: acceso unicamente via funciones SECURITY DEFINER.

-- ------------------------------------------------------------
-- Listar los puestos distintos del roster activo + su sueldo (si ya
-- se cargo) + cuantos colaboradores tiene cada uno, para el panel.
-- ------------------------------------------------------------
create or replace function public.asis_sueldos_puesto_listar(p_token text)
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
      select distinct on (dni) dni, puesto, estado
      from public.b2c_asistencia
      order by dni, fecha desc
    ),
    puestos as (
      select puesto, count(*) as colaboradores
      from roster
      where estado = 'ACTIVO' and puesto is not null and trim(puesto) <> ''
      group by puesto
    )
    select json_agg(json_build_object(
      'puesto', p.puesto, 'colaboradores', p.colaboradores, 'sueldo_mensual', s.sueldo_mensual
    ) order by p.puesto)
    from puestos p
    left join public.asis_sueldos_puesto s on s.puesto = p.puesto
  ), '[]'::json);
end;
$$;

-- ------------------------------------------------------------
-- Registrar/actualizar el sueldo mensual de un puesto.
-- ------------------------------------------------------------
create or replace function public.asis_sueldos_puesto_guardar(p_token text, p_puesto text, p_sueldo_mensual numeric)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id bigint;
  v_rol varchar;
  v_puesto text := nullif(trim(p_puesto), '');
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh') then
    raise exception 'SIN_PERMISO';
  end if;
  if v_puesto is null then
    raise exception 'DATOS_INCOMPLETOS';
  end if;
  if p_sueldo_mensual is null or p_sueldo_mensual < 0 then
    raise exception 'SUELDO_INVALIDO';
  end if;

  insert into public.asis_sueldos_puesto (puesto, sueldo_mensual, updated_at)
  values (v_puesto, p_sueldo_mensual, now())
  on conflict (puesto) do update set sueldo_mensual = excluded.sueldo_mensual, updated_at = now();

  return json_build_object('puesto', v_puesto, 'sueldo_mensual', p_sueldo_mensual);
end;
$$;

-- ------------------------------------------------------------
-- Planilla: el sueldo ahora se busca por puesto, no por DNI.
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
    join public.asis_sueldos_puesto s on s.puesto = r.puesto
    left join faltas f on f.dni = r.dni
    left join tardanzas t on t.dni = r.dni
  ), '[]'::json);
end;
$$;

grant execute on function public.asis_sueldos_puesto_listar(text) to anon, authenticated;
grant execute on function public.asis_sueldos_puesto_guardar(text, text, numeric) to anon, authenticated;
grant execute on function public.asis_planilla_calcular(text, date, date, text) to anon, authenticated;
