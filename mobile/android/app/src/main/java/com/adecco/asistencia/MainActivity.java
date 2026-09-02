package com.adecco.asistencia;

import android.app.AlertDialog;
import android.text.InputType;
import android.widget.EditText;
import android.widget.Toast;
import com.getcapacitor.BridgeActivity;

/**
 * Modo kiosko: la app se fija sola en pantalla (bloquea Inicio y Recientes,
 * lo maneja Android) y el botón Atrás pide una clave antes de dejar salir,
 * en vez de cerrar la app directo.
 */
public class MainActivity extends BridgeActivity {

    private static final String CLAVE_SALIDA = "adecco2026";

    @Override
    public void onResume() {
        super.onResume();
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
        final EditText input = new EditText(this);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        input.setHint("Clave");

        new AlertDialog.Builder(this)
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
