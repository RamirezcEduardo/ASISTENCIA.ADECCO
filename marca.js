/* ==========================================================================
   Motor de marca (white-label). Lee marca.config.js y:
     - calcula la paleta del color principal (claro y modo noche) y la deja en variables CSS;
     - rellena los elementos marcados:  data-marca="producto|empresa|modulo|lema",
       data-marca-logo (logo del cliente o marca genérica), <meta name="theme-color" data-marca>;
     - arma el título de la pestaña con <html data-modulo="…">.
   Se carga en <head>, antes de los estilos de la página, para que no haya parpadeo de color.
   ========================================================================== */
(function(){
  var POR_DEFECTO = { producto: "Control de Asistencia", empresa: "", lema: "", color: "#4F46E5", logo: "" };
  var cfg = window.MARCA_CONFIG || {};
  var M = {};
  Object.keys(POR_DEFECTO).forEach(function(k){ M[k] = (typeof cfg[k] === "string") ? cfg[k].trim() : POR_DEFECTO[k]; });
  if(!M.producto) M.producto = POR_DEFECTO.producto;

  /* ---------- color ---------- */
  function aRgb(hex){
    var h = String(hex || "").replace("#", "");
    if(h.length === 3) h = h.split("").map(function(c){ return c + c; }).join("");
    if(!/^[0-9a-f]{6}$/i.test(h)) return null;
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
  }
  function aHex(rgb){ return "#" + rgb.map(function(v){ return ("0" + Math.round(Math.max(0, Math.min(255, v))).toString(16)).slice(-2); }).join(""); }
  // mezcla: t = 0 → solo "base", t = 1 → solo "color"
  function mezcla(color, base, t){ return color.map(function(v, i){ return base[i] + (v - base[i]) * t; }); }
  function luminancia(rgb){
    var c = rgb.map(function(v){ v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  var BLANCO = [255, 255, 255], NEGRO = [0, 0, 0], FONDO_NOCHE = [18, 21, 28];
  var base = aRgb(M.color) || aRgb(POR_DEFECTO.color);
  M.color = aHex(base);
  function contraste(a, b){ var la = luminancia(a), lb = luminancia(b); return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05); }
  // texto sobre el color principal: el de mayor contraste (un amarillo lleva texto oscuro, un azul lleva texto blanco)
  var TINTA_OSCURA = [17, 24, 39];
  var tinta = function(rgb){ return contraste(rgb, BLANCO) >= contraste(rgb, TINTA_OSCURA) ? "#FFFFFF" : "#111827"; };
  // el color principal usado COMO TEXTO sobre su propio tono claro: se oscurece (o aclara, en modo noche) hasta leerse bien
  function legible(color, fondo, haciaNegro){
    var c = color;
    for(var i = 0; i < 30 && contraste(c, fondo) < 4.5; i++) c = mezcla(haciaNegro ? NEGRO : BLANCO, c, 0.1);
    return c;
  }

  var claro = base;
  var noche = luminancia(base) < 0.28 ? mezcla(BLANCO, base, 0.4) : base;   // un color oscuro se aclara para leerse sobre fondo oscuro
  var tintClaro = mezcla(claro, BLANCO, 0.09), tintNoche = mezcla(noche, FONDO_NOCHE, 0.16);
  var vars = {
    "--ac-l": aHex(claro), "--ac-strong-l": aHex(mezcla(NEGRO, claro, 0.18)),
    "--ac-tint-l": aHex(tintClaro), "--ac-dim-l": aHex(mezcla(claro, BLANCO, 0.18)),
    "--ac-text-l": aHex(legible(claro, tintClaro, true)),
    "--ac-ink-l": tinta(claro), "--ac-ring-l": "rgba(" + claro.map(Math.round).join(",") + ",.22)",
    "--ac-d": aHex(noche), "--ac-strong-d": aHex(mezcla(BLANCO, noche, 0.14)),
    "--ac-tint-d": aHex(tintNoche), "--ac-dim-d": aHex(mezcla(noche, FONDO_NOCHE, 0.28)),
    "--ac-text-d": aHex(legible(noche, tintNoche, false)),
    "--ac-ink-d": tinta(noche), "--ac-ring-d": "rgba(" + noche.map(Math.round).join(",") + ",.30)"
  };
  var raiz = document.documentElement;
  Object.keys(vars).forEach(function(k){ raiz.style.setProperty(k, vars[k]); });

  /* ---------- logo ---------- */
  // Marca genérica: aro con visto (asistencia verificada). Toma el color principal por CSS (.lg-bg / .lg-fg en marca.css).
  var MARCA_SVG = '<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><rect class="lg-bg" width="48" height="48" rx="12"/>' +
    '<circle class="lg-fg" cx="24" cy="24" r="12" fill="none" stroke-width="3.2"/>' +
    '<path class="lg-fg" d="M18.5 24.5l4 4 7.5-8" fill="none" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  function esc(s){ return String(s).replace(/[&<>"']/g, function(c){ return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function logoHtml(){ return M.logo ? '<img src="' + esc(M.logo) + '" alt="' + esc(M.empresa || M.producto) + '">' : MARCA_SVG; }

  /* ---------- aplicar a la página ---------- */
  function aplicar(){
    var modulo = raiz.getAttribute("data-modulo") || "";
    M.modulo = modulo;
    var textos = { producto: M.producto, empresa: M.empresa, lema: M.lema, modulo: modulo };
    Array.prototype.forEach.call(document.querySelectorAll("[data-marca]"), function(el){
      var v = textos[el.getAttribute("data-marca")] || "";
      el.textContent = v;
      el.hidden = !v;
    });
    Array.prototype.forEach.call(document.querySelectorAll("[data-marca-logo]"), function(el){
      el.classList.add("marca-logo");
      el.classList.toggle("con-imagen", !!M.logo);
      el.innerHTML = logoHtml();
    });
    Array.prototype.forEach.call(document.querySelectorAll('meta[name="theme-color"][data-marca]'), function(m){ m.setAttribute("content", M.color); });
    document.title = (M.empresa || M.producto) + (modulo ? " · " + modulo : "");
  }
  if(document.readyState === "loading") document.addEventListener("DOMContentLoaded", aplicar); else aplicar();
  M.aplicar = aplicar;
  window.MARCA = M;
})();
