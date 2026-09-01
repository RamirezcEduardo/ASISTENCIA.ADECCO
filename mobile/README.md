# App móvil (ADECCO Asistencia)

Empaqueta la misma app web (`../index.html`) como app Android nativa usando
[Capacitor](https://capacitorjs.com), para instalarla directo en las tablets
de las entradas (sin depender del navegador ni de que alguien la abra a mano
cada vez).

## Compilar el APK

GitHub Actions lo compila solo en cada push a `main` que toque `mobile/**` o
`index.html` (ver `.github/workflows/build-apk.yml`). El `.apk` queda como
artefacto descargable en la pestaña **Actions** del run correspondiente
(`asistencia-adecco-debug`).

También se puede compilar localmente (requiere Android Studio / Android SDK):

```
cd mobile
npm install
cp ../index.html www/index.html   # sincroniza la app web más reciente
cp ../manifest.json www/manifest.json
cp -r ../icons www/icons
npx cap sync android
npx cap open android              # abre en Android Studio, o:
cd android && ./gradlew assembleDebug
```

## Cámara y ubicación en el WebView

La pantalla de marcación usa `getUserMedia` (cámara) y `navigator.geolocation`
directo en el navegador — no plugins nativos de Capacitor. El
`BridgeWebChromeClient` que trae Capacitor por defecto ya sabe pedir esos
permisos en tiempo de ejecución; solo hacía falta declarar
`android.permission.CAMERA`, `ACCESS_FINE_LOCATION` y `ACCESS_COARSE_LOCATION`
en `AndroidManifest.xml` (ya está). No se tocó `MainActivity.java`.

## Firma de debug fija

`mobile/android/keystores/debug.keystore` está commiteado a propósito, con la
firma de debug estándar de Android (usuario/contraseña "android" — no es un
secreto real, nunca sirve para publicar en Play Store). Sin esto, cada build
de GitHub Actions corre en una máquina nueva y Gradle generaría una firma
distinta cada vez, así que instalar la versión nueva encima de la anterior
fallaría y habría que desinstalar la app en cada actualización. Con la firma
fija, actualizar es simplemente instalar el `.apk` nuevo encima.

## Instalar el APK en una tablet

1. Descarga el `.apk` desde el artefacto del run de Actions (o desde
   `mobile/android/app/build/outputs/apk/debug/app-debug.apk` si lo compilaste
   local).
2. Pásalo a la tablet (USB, Drive, correo, etc.) y ábrelo — Android va a pedir
   habilitar "Instalar apps de fuentes desconocidas" la primera vez.
3. Dale los permisos de Cámara y Ubicación cuando los pida (ubicación es
   opcional, cámara es obligatoria para marcar Ingreso/Salida).
