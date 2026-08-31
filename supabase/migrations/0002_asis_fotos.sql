-- ============================================================
-- Foto de verificación en Ingreso y Salida
--
-- El colaborador se toma su propia foto (cámara frontal) al marcar
-- Ingreso o Salida — no en los almuerzos, para no duplicar el peso.
-- La foto se redimensiona/comprime en el navegador (~480px, JPEG
-- calidad 0.6, ~30-60 KB) ANTES de subirla, así que el costo real
-- de almacenamiento con los 416 colaboradores activos hoy es del
-- orden de ~30 MB/día (~1 GB/mes), no varios GB.
--
-- Se guarda en un bucket de Storage (no en la fila de la tabla,
-- a diferencia de como lo hace SSOMA con data URLs en jsonb — acá
-- el volumen es diario y constante, no esporádico, así que sí vale
-- la pena separar el archivo del registro desde el día uno).
--
-- El bucket es público (lectura sin políticas) porque no existe
-- Supabase Auth real en este proyecto — el panel admin usa el mismo
-- token custom (b2c_users/b2c_sessions) que no es visible para las
-- políticas de Storage. Igual que el resto del ecosistema (RLS
-- abierta en varias tablas ssoma_*/b2c_asistencia), el nombre de
-- archivo es un DNI+timestamp poco adivinable, pero esto NO es un
-- candado real de acceso — si más adelante se quiere endurecer,
-- hay que mover la lectura a una Edge Function con service_role
-- que valide el token antes de firmar la URL.
-- ============================================================

alter table public.asis_marcaciones add column if not exists foto_path text;
comment on column public.asis_marcaciones.foto_path is 'Ruta del archivo en el bucket público "asis-fotos" (solo se usa para tipo ingreso/salida). Null si no se pudo tomar la foto (ej. cámara no disponible) — nunca bloquea la marcación.';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('asis-fotos', 'asis-fotos', true, 2097152, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg'];

drop policy if exists asis_fotos_anon_insert on storage.objects;
create policy asis_fotos_anon_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'asis-fotos');

-- Registrar marcación con foto opcional (p_foto_path al final, con
-- default null, para no romper llamadas existentes sin foto).
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

-- Reporte admin: ahora incluye foto_path para mostrar/miniatura en el panel.
create or replace function public.asis_reporte(p_token text, p_desde date, p_hasta date, p_area text default null)
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
      select id, dni, nombre, puesto, area, turno, tipo, fecha, registrado_en, foto_path
      from public.asis_marcaciones
      where fecha between p_desde and p_hasta
        and (p_area is null or p_area = '' or area = p_area)
      order by fecha desc, nombre, registrado_en
    ) t
  ), '[]'::json);
end;
$$;

grant execute on function public.asis_marcar(text, text, double precision, double precision, text, text) to anon, authenticated;
grant execute on function public.asis_reporte(text, date, date, text) to anon, authenticated;
