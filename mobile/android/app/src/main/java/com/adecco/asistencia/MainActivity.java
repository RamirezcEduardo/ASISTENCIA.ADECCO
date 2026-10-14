package com.adecco.asistencia;

import android.app.AlertDialog;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.widget.EditText;
import android.widget.Toast;
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

    /**
     * Android 15+ dibuja la app DEBAJO de la barra de estado y de la barra de navegacion (borde a borde), y el
     * WebView de muchas tablets no informa esos margenes a la pagina: el texto del pie y los botones de abajo
     * quedaban tapados por los botones de Atras/Inicio. Aqui se deja el contenido DENTRO del area libre.
     */
    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        View contenido = findViewById(android.R.id.content);
        ViewCompat.setOnApplyWindowInsetsListener(contenido, (v, insets) -> {
            Insets barras = insets.getInsets(WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.displayCutout());
            v.setPadding(barras.left, barras.top, barras.right, barras.bottom);
            return WindowInsetsCompat.CONSUMED;
        });
        ViewCompat.requestApplyInsets(contenido);
    }

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
