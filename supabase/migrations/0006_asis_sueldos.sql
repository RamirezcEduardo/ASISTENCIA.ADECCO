-- ============================================================
-- Sueldos por colaborador (base para el calculo de planilla)
--
-- No existia ningun dato de sueldo/tarifa en el ecosistema Adecco
-- KPI -- b2c_asistencia es un censo diario re-importado desde Excel
-- (DNI, puesto, area, turno, asistencia...) sin columna de sueldo.
-- Esta tabla es la fuente de verdad nueva, mantenida a mano desde el
-- panel (pestaña Pagos), no se re-importa con el censo diario.
--
-- Convencion de Peru para pasar sueldo mensual a valores diarios/por
-- hora: /30 dias y /240 horas (30 dias x 8 horas). Se documenta aqui
-- porque asis_planilla_calcular (siguiente migracion) depende de ella.
-- ============================================================

create table if not exists public.asis_sueldos (
  dni            varchar primary key,
  sueldo_mensual numeric(10,2) not null check (sueldo_mensual >= 0),
  updated_at     timestamptz not null default now()
);

comment on table public.asis_sueldos is 'Sueldo mensual base por DNI, mantenido a mano en el panel de Pagos. Fuente de verdad para el calculo de planilla (asis_planilla_calcular).';

alter table public.asis_sueldos enable row level security;
-- Sin policies: acceso unicamente via funciones SECURITY DEFINER.

-- ------------------------------------------------------------
-- Listar sueldos registrados + datos del roster mas reciente
-- (nombre/area/puesto) para mostrarlos juntos en el panel.
-- Restringido a admin/rrhh -- el sueldo es mas sensible que ver
-- marcaciones, no basta con el permiso general view.asistencia.
-- ------------------------------------------------------------
create or replace function public.asis_sueldos_listar(p_token text)
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
      select distinct on (dni) dni, nombre, area, puesto, estado
      from public.b2c_asistencia
      order by dni, fecha desc
    )
    select json_agg(json_build_object(
      'dni', r.dni, 'nombre', r.nombre, 'area', r.area, 'puesto', r.puesto,
      'estado', r.estado, 'sueldo_mensual', s.sueldo_mensual
    ) order by r.nombre)
    from roster r
    left join public.asis_sueldos s on s.dni = r.dni
    where r.estado = 'ACTIVO'
  ), '[]'::json);
end;
$$;

-- ------------------------------------------------------------
-- Registrar/actualizar el sueldo mensual de un colaborador.
-- ------------------------------------------------------------
create or replace function public.asis_sueldos_guardar(p_token text, p_dni text, p_sueldo_mensual numeric)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id bigint;
  v_rol varchar;
  v_roster record;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh') then
    raise exception 'SIN_PERMISO';
  end if;

  select dni, nombre into v_roster from public.b2c_asistencia where dni = trim(p_dni) order by fecha desc limit 1;
  if v_roster.dni is null then
    raise exception 'DNI_NO_ENCONTRADO';
  end if;
  if p_sueldo_mensual is null or p_sueldo_mensual < 0 then
    raise exception 'SUELDO_INVALIDO';
  end if;

  insert into public.asis_sueldos (dni, sueldo_mensual, updated_at)
  values (v_roster.dni, p_sueldo_mensual, now())
  on conflict (dni) do update set sueldo_mensual = excluded.sueldo_mensual, updated_at = now();

  return json_build_object('dni', v_roster.dni, 'nombre', v_roster.nombre, 'sueldo_mensual', p_sueldo_mensual);
end;
$$;

grant execute on function public.asis_sueldos_listar(text) to anon, authenticated;
grant execute on function public.asis_sueldos_guardar(text, text, numeric) to anon, authenticated;
