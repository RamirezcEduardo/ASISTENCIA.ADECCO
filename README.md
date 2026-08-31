# ADECCO · Control de Asistencia

PWA sin build step (un solo `index.html`) para marcar **Ingreso**, **Inicio de
Almuerzo**, **Fin de Almuerzo** y **Salida**. Usa el mismo proyecto Supabase
que SSOMA y el dashboard Adecco KPI (`marlon220901's Project`).

## Cómo funciona

- **Pantalla de marcación (kiosko)**: sin login, pensada para un tablet/celular
  fijo en la entrada. El colaborador ingresa su DNI, el sistema lo busca en el
  roster diario (`b2c_asistencia`, la misma tabla que alimenta el reporte de
  RR.HH.) y muestra los 4 botones de marcación, resaltando el siguiente que
  corresponde según lo ya marcado en el día. La hora que se guarda es la del
  servidor (`now()` en Postgres), no la del dispositivo.
- **Panel administrativo**: mismo login que SSOMA / Adecco KPI (`b2c_login`).
  Solo lo ven los roles con el permiso `view.asistencia` (admin, gerencia,
  coordinador, rrhh, supervisor). Permite filtrar por fecha/área, ver horas
  trabajadas, corregir o eliminar una marcación, y exportar a Excel.

## Base de datos

Todo el esquema vive en `supabase/migrations/0001_asis_marcaciones.sql` y ya
está aplicado al proyecto Supabase compartido:

- Tabla `asis_marcaciones` (una fila por marcación), con RLS activado y **sin**
  políticas para `anon`/`authenticated` — todo el acceso pasa por funciones
  `SECURITY DEFINER` (mismo patrón que `b2c_users`/`b2c_sessions`).
- RPCs: `asis_buscar_dni`, `asis_marcar` (kiosko, públicas), `asis_reporte`,
  `asis_areas`, `asis_editar`, `asis_eliminar` (panel admin, requieren sesión
  + permiso `view.asistencia`).
- Se agregó el permiso `view.asistencia` a `b2c_permisos_catalogo` y se otorgó
  a los roles `admin`, `gerencia`, `coordinador`, `rrhh`, `supervisor`.

## Desarrollo

No hay build step. Sirve `index.html` con cualquier servidor estático, por
ejemplo:

```bash
python3 -m http.server 8080
```

Las credenciales de Supabase (`SUPABASE_URL` / clave `anon`/publishable) están
incrustadas en el HTML — es seguro exponerlas en el cliente, nunca uses ahí la
`service_key`.
