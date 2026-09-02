-- ============================================================
-- Enrolamiento facial (kiosko con reconocimiento de rostro)
--
-- Los descriptores de face-api.js son vectores de 128 numeros de
-- punto flotante -- no son la foto en si (no se puede reconstruir
-- el rostro exacto a partir de ellos), pero igual son datos
-- biometricos y se tratan como tales: tabla propia, sin policies
-- para anon/authenticated, acceso solo via funciones SECURITY
-- DEFINER (mismo patron que asis_marcaciones).
--
-- El matching (comparar el rostro en vivo contra los enrolados)
-- se hace en el propio kiosko (cliente), no en la base de datos:
-- el kiosko trae todos los descriptores una vez al cargar via
-- asis_rostros_listar y corre faceapi.FaceMatcher localmente. Por
-- eso esa funcion es publica igual que asis_buscar_dni/asis_marcar.
-- ============================================================

create table if not exists public.asis_rostros (
  dni         varchar primary key,
  nombre      text not null,
  embedding   double precision[] not null,
  updated_at  timestamptz not null default now()
);

comment on table public.asis_rostros is 'Descriptor facial de referencia (128 floats, face-api.js) por colaborador, para el reconocimiento en el kiosko de asistencia.';

alter table public.asis_rostros enable row level security;
-- Sin policies: acceso unicamente via funciones SECURITY DEFINER.

-- ------------------------------------------------------------
-- Traer todos los rostros enrolados (el kiosko los carga una vez
-- al iniciar y corre el matching localmente).
-- ------------------------------------------------------------
create or replace function public.asis_rostros_listar()
returns json
language sql
security definer
set search_path to 'public'
as $$
  select coalesce(json_agg(json_build_object('dni', dni, 'nombre', nombre, 'embedding', embedding)), '[]'::json)
  from public.asis_rostros;
$$;

-- ------------------------------------------------------------
-- Enrolar/actualizar el rostro de un colaborador. Publica (como
-- asis_marcar) porque el kiosko no tiene login; valida que el DNI
-- exista y este activo en el roster antes de guardar.
-- ------------------------------------------------------------
create or replace function public.asis_rostros_enrolar(p_dni text, p_nombre text, p_embedding double precision[])
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_roster record;
begin
  select dni, nombre, estado
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
  if array_length(p_embedding, 1) is distinct from 128 then
    raise exception 'EMBEDDING_INVALIDO';
  end if;

  insert into public.asis_rostros (dni, nombre, embedding, updated_at)
  values (v_roster.dni, coalesce(nullif(trim(p_nombre), ''), v_roster.nombre), p_embedding, now())
  on conflict (dni) do update set nombre = excluded.nombre, embedding = excluded.embedding, updated_at = now();

  return json_build_object('dni', v_roster.dni, 'nombre', v_roster.nombre);
end;
$$;

-- ------------------------------------------------------------
-- Quitar el enrolamiento de un colaborador (panel admin).
-- ------------------------------------------------------------
create or replace function public.asis_rostros_eliminar(p_token text, p_dni text)
returns void
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
  delete from public.asis_rostros where dni = p_dni;
end;
$$;

grant execute on function public.asis_rostros_listar() to anon, authenticated;
grant execute on function public.asis_rostros_enrolar(text, text, double precision[]) to anon, authenticated;
grant execute on function public.asis_rostros_eliminar(text, text) to anon, authenticated;
