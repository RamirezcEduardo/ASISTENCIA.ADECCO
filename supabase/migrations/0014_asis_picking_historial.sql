-- ============================================================
-- Historial de Picking: cada asignacion trae tambien nombre, turno,
-- supervisor y area que tenia la persona ESE dia (ultimo registro del
-- censo con fecha <= la del dia). Asi el historial por dia, por turno y
-- por supervisor es fiel aunque despues la persona cambie de supervisor,
-- de turno o ya no este activa.
--
-- Reemplaza asis_picking_rango (misma firma, la respuesta solo agrega
-- campos: lo que ya existia sigue funcionando igual).
-- ============================================================

create or replace function public.asis_picking_rango(p_token text, p_desde date, p_hasta date)
returns json language plpgsql security definer set search_path to 'public' as $$
declare v_user_id bigint; v_rol varchar;
begin
  v_user_id := public.b2c_require_session(p_token);
  select rol into v_rol from public.b2c_users where id = v_user_id;
  if not exists (select 1 from public.b2c_permisos where rol = v_rol and permiso = 'view.asistencia') then
    raise exception 'SIN_PERMISO';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 92 then raise exception 'DATOS_INCOMPLETOS'; end if;
  return coalesce((
    select json_agg(json_build_object(
      'dni', a.dni, 'fecha', a.fecha, 'funcion', a.funcion,
      'nombre', r.nombre, 'turno', r.turno, 'supervisor', r.supervisor, 'area', r.area
    ) order by a.fecha, a.dni)
    from public.asis_picking_asignaciones a
    left join lateral (
      select b.nombre, b.turno, b.supervisor, b.area
      from public.b2c_asistencia b
      where b.dni = a.dni and b.fecha <= a.fecha
      order by b.fecha desc limit 1
    ) r on true
    where a.fecha between p_desde and p_hasta
  ), '[]'::json);
end; $$;

grant execute on function public.asis_picking_rango(text, date, date) to anon, authenticated;
