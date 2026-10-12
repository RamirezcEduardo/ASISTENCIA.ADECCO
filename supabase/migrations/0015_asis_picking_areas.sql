-- ============================================================
-- Picking: que areas del censo entran al modulo Picking.
-- Si la tabla esta vacia se usan por defecto las zonas de picking
-- (Mezzanine, Estanteria, Knapp); si tiene filas, manda esta lista.
-- Quien tenga una zona de picking asignada a mano entra siempre.
-- Se administra desde la pestaña Configuracion.
-- ============================================================

create table if not exists public.asis_picking_areas (
  area       varchar(80) primary key,
  created_at timestamptz not null default now()
);
alter table public.asis_picking_areas enable row level security;
-- Sin policies: acceso solo via funciones SECURITY DEFINER.

create or replace function public.asis_picking_areas_listar(p_token text)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if not exists (select 1 from public.b2c_permisos where rol = v_rol and permiso = 'view.asistencia') then
    raise exception 'SIN_PERMISO';
  end if;
  return coalesce((select json_agg(area order by area) from public.asis_picking_areas), '[]'::json);
end; $$;

-- Reemplaza la lista completa (lista vacia = volver al valor por defecto).
create or replace function public.asis_picking_areas_guardar(p_token text, p_areas text[])
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar; v_n int;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if v_rol not in ('admin', 'rrhh', 'coordinador') then raise exception 'SIN_PERMISO'; end if;
  delete from public.asis_picking_areas where true;
  insert into public.asis_picking_areas (area)
  select distinct left(regexp_replace(upper(trim(a)), '\s+', ' ', 'g'), 80)
  from unnest(coalesce(p_areas, '{}'::text[])) as a
  where length(trim(coalesce(a, ''))) > 0;
  get diagnostics v_n = row_count;
  return json_build_object('areas', v_n);
end; $$;

grant execute on function public.asis_picking_areas_listar(text) to anon, authenticated;
grant execute on function public.asis_picking_areas_guardar(text, text[]) to anon, authenticated;
