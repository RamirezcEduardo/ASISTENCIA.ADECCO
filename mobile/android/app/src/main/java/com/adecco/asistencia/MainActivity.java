package com.adecco.asistencia;

import android.Manifest;
import android.app.AlertDialog;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.widget.EditText;
import android.widget.Toast;
import androidx.activity.OnBackPressedCallback;
import androidx.annotation.NonNull;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import com.getcapacitor.BridgeActivity;

/**
 * Modo kiosko: la app se fija sola en pantalla (bloquea Inicio y Recientes,
 * lo maneja Android) y el botón Atrás pide una clave antes de dejar salir,
 * en vez de cerrar la app directo.
 */
public class MainActivity extends BridgeActivity {

    private static final String CLAVE_SALIDA = "adecco2026";

    private static final int PEDIDO_CAMARA = 4711;

    private AlertDialog dialogoClave = null;
    // El permiso de camara se pide ANTES de fijar la pantalla: con la app fijada Android no deja mostrar el cuadro de
    // permisos, y sin permiso la camara se quedaba en negro (por ejemplo tras reinstalar la app).
    private boolean esperandoPermiso = false;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // Android 15+ dibuja la app DEBAJO de la barra de estado y de la barra de navegación (borde a borde), y el
        // WebView de muchas tablets no informa esos márgenes a la página: el texto del pie y los botones de abajo
        // quedaban tapados por los botones de Atrás/Inicio. Aquí se deja el contenido DENTRO del área libre,
        // y también por encima del teclado en pantalla (si no, tapa el campo de DNI del registro biométrico).
        View contenido = findViewById(android.R.id.content);
        ViewCompat.setOnApplyWindowInsetsListener(contenido, (v, insets) -> {
            Insets libre = insets.getInsets(
                WindowInsetsCompat.Type.systemBars()
                    | WindowInsetsCompat.Type.displayCutout()
                    | WindowInsetsCompat.Type.ime());
            v.setPadding(libre.left, libre.top, libre.right, libre.bottom);
            return WindowInsetsCompat.CONSUMED;
        });
        ViewCompat.requestApplyInsets(contenido);

        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            esperandoPermiso = true;
            requestPermissions(new String[] { Manifest.permission.CAMERA }, PEDIDO_CAMARA);
        }

        // Con Android 16 (targetSdk 36) el gesto/botón Atrás ya no llama a onBackPressed(): se atiende por el
        // despachador de Atrás, así la clave de salida se pide en cualquier versión de Android.
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                pedirClaveParaSalir();
            }
        });
    }

    @Override
    public void onResume() {
        super.onResume();
        if (!esperandoPermiso) fijarPantalla();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == PEDIDO_CAMARA) {
            esperandoPermiso = false;
            fijarPantalla();
        }
    }

    private void fijarPantalla() {
        try {
            startLockTask();
        } catch (Exception e) {
            // Si el dispositivo no lo permite (poco común), la app sigue
            // funcionando normal, solo sin quedar fijada en pantalla.
        }
    }

    @Override
    public void onBackPressed() {
        pedirClaveParaSalir();
    }

    private void pedirClaveParaSalir() {
        // Si ya está el cuadro de clave abierto no se apila otro al volver a tocar Atrás.
        if (dialogoClave != null && dialogoClave.isShowing()) return;

        final EditText input = new EditText(this);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        input.setHint("Clave");

        dialogoClave = new AlertDialog.Builder(this)
            .setTitle("Salir de la app")
            .setMessage("Ingresa la clave para salir del modo kiosko.")
            .setView(input)
            .setCancelable(false)
            .setPositiveButton("Salir", (dialog, which) -> {
                if (CLAVE_SALIDA.contentEquals(input.getText())) {
                    try {
                        stopLockTask();
                    } catch (Exception e) {
                        // no estaba fijada, no pasa nada
                    }
                    MainActivity.this.finish();
                } else {
                    Toast.makeText(MainActivity.this, "Clave incorrecta", Toast.LENGTH_SHORT).show();
                }
            })
            .setNegativeButton("Cancelar", (dialog, which) -> dialog.dismiss())
            .show();
    }
}
