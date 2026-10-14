# Control de Asistencia

Plataforma de asistencia biométrica con Centro de Control, pensada para entregarse
como servicio a distintas empresas: marcación por rostro o DNI (**Ingreso**, **Inicio
de Almuerzo**, **Fin de Almuerzo**, **Salida**), seguimiento en vivo, picking diario,
ausentismo, rotación, planilla y carga masiva del personal. Sin build step: HTML +
JavaScript sobre Supabase.

## Pantallas

| Archivo | Para quién | Qué es |
| --- | --- | --- |
| `centro-control.html` | Supervisores, RR.HH., gerencia | Centro de Control (menú lateral): En Vivo, Picking, Ausentismo, Rotación, Asistencia General, Personal, Pagos, Movimientos, Configuración |
| `kiosco-biometrico.html` | Tablet en la entrada | Marcación por reconocimiento facial y registro biométrico (es lo que empaqueta el APK de `mobile/`) |
| `index.html` | Celular / respaldo | Marcación por DNI y panel administrativo básico |

## Marca blanca (una instalación por cliente)

Toda la identidad visual sale de **un solo archivo**, `marca.config.js`:

```js
window.MARCA_CONFIG = {
  producto: "Control de Asistencia",   // nombre de la plataforma
  empresa:  "",                         // nombre del cliente (opcional)
  lema:     "Asistencia biométrica, picking y control de personal en un solo lugar.",
  color:    "#4F46E5",                  // color principal
  logo:     "",                         // ruta/URL del logo del cliente; vacío = marca genérica
};
```

- `marca.js` calcula la paleta a partir de `color` (tonos claros, hover, modo noche y el
  color del texto sobre botones, siempre con contraste legible) y rellena nombre y logo en
  las tres pantallas. `marca.css` guarda los valores de respaldo.
- Los íconos de la app instalable (`icons/`) y `manifest.json` son archivos estáticos: para
  una instalación con marca propia se reemplazan por los del cliente. En el APK, el nombre
  visible está en `mobile/capacitor.config.json` y `mobile/android/app/src/main/res/values/strings.xml`.
- Colores de estado (verde presente, ámbar justificado, rojo falta/tardanza) son fijos y no
  dependen de la marca, para que los indicadores se lean igual en cualquier cliente.

## Cómo funciona

- **Marcación (kiosko)**: sin login, pensada para un tablet/celular fijo en la entrada. El
  colaborador se identifica por rostro o DNI contra el censo diario (`b2c_asistencia`) y marca el
  siguiente paso que corresponde. La hora que se guarda es la del servidor (`now()` en
  Postgres), no la del dispositivo.
- **Centro de Control**: mismo login `b2c_login`. Lo ven los roles con el permiso
  `view.asistencia` (admin, gerencia, coordinador, rrhh, supervisor). Filtra por fecha, área
  y zona, y exporta a Excel.

## Base de datos

El esquema vive en `supabase/migrations/` (ver la numeración `0001…0016`) y se aplica en el
SQL Editor de Supabase:

- Tabla `asis_marcaciones` (una fila por marcación), con RLS activado y **sin** políticas para
  `anon`/`authenticated`: todo el acceso pasa por funciones `SECURITY DEFINER` (mismo patrón que
  `b2c_users`/`b2c_sessions`).
- RPCs del kiosko (`asis_buscar_dni`, `asis_marcar`, …, públicas) y del panel (`asis_reporte`,
  `asis_censo`, `asis_picking_*`, `asis_importar_aplicar`, …, requieren sesión y permiso).
- Permiso `view.asistencia` en `b2c_permisos_catalogo`, otorgado a admin, gerencia, coordinador,
  rrhh y supervisor.

## Desarrollo

No hay build step. Sirve la carpeta con cualquier servidor estático, por ejemplo:

```bash
python3 -m http.server 8080
```

Las credenciales de Supabase (`SUPABASE_URL` / clave `anon`/publishable) están incrustadas en el
HTML: es seguro exponerlas en el cliente, nunca uses ahí la `service_key`.
