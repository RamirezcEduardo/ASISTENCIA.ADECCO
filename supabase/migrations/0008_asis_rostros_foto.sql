-- ============================================================
-- Foto de referencia del enrolamiento + estado de cobertura
--
-- asis_rostros guardaba solo el descriptor (vector de 128 floats,
-- usado para el matching). Ahora se agrega foto_path: una foto de
-- evidencia tomada durante el enrolamiento (mismo bucket "asis-fotos"
-- que ya usan las marcaciones de Ingreso/Salida), solo para que el
-- panel administrativo pueda MOSTRAR quien es cada rostro enrolado.
-- El reconocimiento en el kiosko sigue usando unicamente el
-- descriptor via asis_rostros_listar -- esta foto nunca se manda ahi.
-- ============================================================

alter table public.asis_rostros add column if not exists foto_path text;
comment on column public.asis_rostros.foto_path is 'Foto de referencia (bucket publico "asis-fotos") tomada al enrolar, solo para mostrarla en el panel admin -- el matching del kiosko no la usa.';

-- Se agrega p_foto_path al final con default null (mismo patron que
-- asis_marcar en 0002_asis_fotos.sql) para no romper llamadas existentes.
create or replace function public.asis_rostros_enrolar(p_dni text, p_nombre text, p_embedding double precision[], p_foto_path text default null)
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

  insert into public.asis_rostros (dni, nombre, embedding, foto_path, updated_at)
  values (v_roster.dni, coalesce(nullif(trim(p_nombre), ''), v_roster.nombre), p_embedding, p_foto_path, now())
  on conflict (dni) do update set
    nombre = excluded.nombre,
    embedding = excluded.embedding,
    foto_path = coalesce(excluded.foto_path, public.asis_rostros.foto_path),
    updated_at = now();

  return json_build_object('dni', v_roster.dni, 'nombre', v_roster.nombre, 'foto_path', p_foto_path);
end;
$$;

-- ------------------------------------------------------------
-- Panel admin: estado de enrolamiento de todo el activo (quien
-- tiene rostro registrado y quien esta pendiente), con la foto.
-- ------------------------------------------------------------
create or replace function public.asis_rostros_estado(p_token text)
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
    with roster as (
      select distinct on (dni) dni, nombre, area, puesto, turno, estado
      from public.b2c_asistencia
      order by dni, fecha desc
    )
    select json_agg(json_build_object(
      'dni', r.dni, 'nombre', r.nombre, 'area', r.area, 'puesto', r.puesto, 'turno', r.turno,
      'enrolado', (fr.dni is not null),
      'foto_path', fr.foto_path,
      'actualizado_en', fr.updated_at
    ) order by r.nombre)
    from roster r
    left join public.asis_rostros fr on fr.dni = r.dni
    where r.estado = 'ACTIVO'
  ), '[]'::json);
end;
$$;

grant execute on function public.asis_rostros_enrolar(text, text, double precision[], text) to anon, authenticated;
grant execute on function public.asis_rostros_estado(text) to anon, authenticated;
