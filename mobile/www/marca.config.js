/* ==========================================================================
   Identidad de ESTA instalación (white-label)

   Es lo único que se edita para entregar la plataforma a otra empresa:
   todas las pantallas (Centro de Control, marcación y kiosco) leen estos
   datos y se re-tiñen solas. No hay que tocar el resto del código.

     producto : nombre de la plataforma (barra lateral, login, pestaña del navegador)
     empresa  : nombre del cliente. Opcional; si se llena aparece bajo el nombre y en el título
     lema     : frase corta de la pantalla de ingreso
     color    : color principal de la interfaz, en hex (#RRGGBB). Se derivan solos los tonos
                claros, el hover, el modo noche y el color del texto sobre botones
     logo     : ruta o URL de una imagen (PNG/SVG/WebP) con el logo del cliente.
                Vacío = se usa la marca genérica de la plataforma, que toma el color principal

   Los íconos de la app instalable (carpeta icons/) y el manifest.json son archivos
   estáticos: para una instalación con marca propia se reemplazan por los del cliente.
   ========================================================================== */
window.MARCA_CONFIG = {
  producto: "Control de Asistencia",
  empresa:  "",
  lema:     "Asistencia biométrica, picking y control de personal en un solo lugar.",
  color:    "#4F46E5",
  logo:     "",
};
