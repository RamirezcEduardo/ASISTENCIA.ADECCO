-- ============================================================
-- Zonas de picking por colaborador (Mezzanine / Estanteria / Knapp)
--
-- El "area" de b2c_asistencia viene del censo diario de RR.HH. y es
-- gruesa (ej. 3PL OUTBOUND, ALMACEN); la zona de picking donde
-- realmente trabaja alguien es un dato operativo que RR.HH. no
-- maneja y que puede cambiar. Por eso vive en una tabla propia:
-- asi el re-import diario del Excel no la pisa (a diferencia de lo
-- que se edita directo sobre b2c_asistencia).
--
-- Una persona puede tener mas de una zona (rota entre ellas), por
-- eso es (dni, zona) y no una columna unica. Las zonas validas las
-- define el panel (ZONAS_PICKING en centro-control.html): aca solo se
-- normaliza a MAYUSCULAS sin espacios extremos, asi sumar una zona
-- nueva no requiere migracion.
-- ============================================================

create table if not exists public.asis_zonas_picking (
  dni        varchar not null,
  zona       varchar(30) not null,
  updated_at timestamptz not null default now(),
  primary key (dni, zona)
);

comment on table public.asis_zonas_picking is 'Zonas de picking asignadas a cada colaborador (puede tener varias). Independiente del censo diario b2c_asistencia, no la pisa el re-import.';

alter table public.asis_zonas_picking enable row level security;
-- Sin policies: acceso unicamente via funciones SECURITY DEFINER.

-- ------------------------------------------------------------
-- Listado completo dni -> zonas (el panel lo cruza en el cliente
-- con censo / marcaciones). Solo requiere poder ver asistencia.
-- ------------------------------------------------------------
create or replace function public.asis_zonas_listar(p_token text)
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
    select json_agg(json_build_object('dni', dni, 'zonas', zonas) order by dni)
    from (
      select dni, array_agg(zona order by zona) as zonas
      from public.asis_zonas_picking
      group by dni
    ) t
  ), '[]'::json);
end;
$$;

-- ------------------------------------------------------------
-- Reemplaza el conjunto de zonas de un colaborador (lista vacia =
-- quitarle todas). Mismo nivel de permiso que editar personal.
-- ------------------------------------------------------------
create or replace function public.asis_zonas_guardar(p_token text, p_dni text, p_zonas text[] default '{}')
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id bigint;
  v_rol varchar;
  v_dni text := trim(p_dni);
  v_zonas text[];
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh') then
    raise exception 'SIN_PERMISO';
  end if;
  if v_dni is null or v_dni = '' then
    raise exception 'DATOS_INCOMPLETOS';
  end if;
  if not exists (select 1 from public.b2c_asistencia where dni = v_dni) then
    raise exception 'DNI_NO_ENCONTRADO';
  end if;

  select coalesce(array_agg(distinct upper(trim(z))), '{}')
  into v_zonas
  from unnest(coalesce(p_zonas, '{}')) as z
  where trim(z) <> '' and length(trim(z)) <= 30;

  delete from public.asis_zonas_picking where dni = v_dni and not (zona = any(v_zonas));
  insert into public.asis_zonas_picking (dni, zona)
  select v_dni, z from unnest(v_zonas) as z
  on conflict (dni, zona) do nothing;

  return json_build_object('dni', v_dni, 'zonas', v_zonas);
end;
$$;

grant execute on function public.asis_zonas_listar(text) to anon, authenticated;
grant execute on function public.asis_zonas_guardar(text, text, text[]) to anon, authenticated;
