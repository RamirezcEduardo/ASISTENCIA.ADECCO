-- ============================================================
-- Supervisores por turno y area: que supervisor le corresponde a cada combinacion (turno + area).
-- Se usa para detectar el personal "cruzado" (p. ej. gente de Mezzanine tarde con el supervisor de noche) y
-- corregirlo con un clic, y para que los cambios de turno / area y las cargas del Excel asignen al supervisor correcto.
--
-- - asis_supervisor_reglas_listar : reglas guardadas (cualquier usuario con acceso al Centro de Control).
-- - asis_supervisor_reglas_guardar: reemplaza todas las reglas (admin, rrhh, coordinador).
-- - asis_supervisor_corregir      : cambia el supervisor de personas puntuales y deja el movimiento registrado (admin, rrhh).
-- Requiere la migracion 0016 (tabla asis_movimientos).
-- ============================================================

create table if not exists public.asis_supervisor_reglas (
  id         bigint generated always as identity primary key,
  supervisor varchar(120) not null,
  turno      varchar(20)  not null,
  area       varchar(80)  not null,
  created_at timestamptz  not null default now(),
  unique (supervisor, turno, area)
);
alter table public.asis_supervisor_reglas enable row level security;
-- Sin policies: acceso solo via funciones SECURITY DEFINER.

create or replace function public.asis_supervisor_reglas_listar(p_token text)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh', 'coordinador', 'gerencia', 'supervisor') then raise exception 'SIN_PERMISO'; end if;
  return coalesce((
    select json_agg(json_build_object('supervisor', supervisor, 'turno', turno, 'area', area) order by supervisor, turno, area)
    from public.asis_supervisor_reglas
  ), '[]'::json);
end; $$;

create or replace function public.asis_supervisor_reglas_guardar(p_token text, p_reglas jsonb)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar; r jsonb; n int := 0; v_sup text; v_turno text; v_area text;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh', 'coordinador') then raise exception 'SIN_PERMISO'; end if;
  if p_reglas is null or jsonb_typeof(p_reglas) <> 'array' or jsonb_array_length(p_reglas) > 400 then raise exception 'DATOS_INCOMPLETOS'; end if;

  delete from public.asis_supervisor_reglas where true;
  for r in select * from jsonb_array_elements(p_reglas) loop
    v_sup   := left(trim(coalesce(r->>'supervisor', '')), 120);
    v_turno := left(upper(trim(coalesce(r->>'turno', ''))), 20);
    v_area  := left(upper(trim(coalesce(r->>'area', ''))), 80);
    continue when v_sup = '' or v_turno = '' or v_area = '';
    insert into public.asis_supervisor_reglas (supervisor, turno, area) values (v_sup, v_turno, v_area) on conflict do nothing;
    n := n + 1;
  end loop;
  return json_build_object('guardadas', n);
end; $$;

-- p_cambios = [{dni, supervisor}]: cambia el supervisor vigente de cada persona ACTIVA (ultima fila y dias recientes con el mismo valor).
create or replace function public.asis_supervisor_corregir(p_token text, p_cambios jsonb)
returns json language plpgsql security definer set search_path to 'public' as $$
declare
  v_user_id bigint; v_rol varchar; v_unombre varchar;
  v_hoy date := (now() at time zone 'America/Lima')::date;
  c jsonb; prev public.b2c_asistencia%rowtype; v_dni text; v_sup text; n int := 0;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol, nombre into v_rol, v_unombre from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh') then raise exception 'SIN_PERMISO'; end if;
  if p_cambios is null or jsonb_typeof(p_cambios) <> 'array' or jsonb_array_length(p_cambios) = 0 or jsonb_array_length(p_cambios) > 1500 then
    raise exception 'DATOS_INCOMPLETOS';
  end if;

  for c in select * from jsonb_array_elements(p_cambios) loop
    v_dni := trim(coalesce(c->>'dni', ''));
    v_sup := left(trim(coalesce(c->>'supervisor', '')), 120);
    continue when v_dni = '' or v_sup = '';
    select * into prev from public.b2c_asistencia where dni = v_dni order by fecha desc limit 1;
    continue when not found or upper(trim(coalesce(prev.estado, ''))) <> 'ACTIVO'
               or upper(trim(coalesce(prev.supervisor, ''))) = upper(v_sup);
    -- Se corrige la ultima fila y tambien los dias recientes (30) que tenian ese mismo supervisor equivocado: asi el historial
    -- de Picking no sigue mostrando al personal "cruzado" en los dias anteriores. Lo que tuvo otro supervisor no se toca.
    update public.b2c_asistencia set supervisor = v_sup
     where dni = v_dni and fecha >= prev.fecha - 30
       and upper(trim(coalesce(supervisor, ''))) = upper(trim(coalesce(prev.supervisor, '')));
    insert into public.asis_movimientos (fecha, dni, nombre, tipo, campo, valor_anterior, valor_nuevo, motivo, usuario_nombre)
    values (v_hoy, v_dni, prev.nombre, 'CAMBIO', 'supervisor', prev.supervisor, v_sup,
            'Cruce corregido segun la configuracion de supervisores', v_unombre);
    n := n + 1;
  end loop;
  return json_build_object('corregidos', n);
end; $$;

-- Reglas iniciales (solo si todavia no hay ninguna):
--   Mezzanine tarde -> Lavado | Knapp (picking) tarde -> Huere | Estanteria tarde -> Salas | noche (Mezzanine, Estanteria, Knapp) -> Suyon
insert into public.asis_supervisor_reglas (supervisor, turno, area)
select v.s, v.t, v.a
from (values
  ('LAVADO CASTRO JOSE LUIS',          'TARDE', 'MEZANINE'),
  ('HUERE CAJAHUANCA CLINTON LALO',    'TARDE', 'KNAPP'),
  ('SALAS VARGAS ANDRES ALBERTO',      'TARDE', 'ESTANTERIA'),
  ('SUYON PRADA LUIS',                 'NOCHE', 'MEZANINE'),
  ('SUYON PRADA LUIS',                 'NOCHE', 'ESTANTERIA'),
  ('SUYON PRADA LUIS',                 'NOCHE', 'KNAPP')
) as v(s, t, a)
where not exists (select 1 from public.asis_supervisor_reglas);

grant execute on function public.asis_supervisor_reglas_listar(text) to anon, authenticated;
grant execute on function public.asis_supervisor_reglas_guardar(text, jsonb) to anon, authenticated;
grant execute on function public.asis_supervisor_corregir(text, jsonb) to anon, authenticated;
