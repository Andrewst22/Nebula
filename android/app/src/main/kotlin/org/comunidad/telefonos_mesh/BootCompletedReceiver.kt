package org.comunidad.telefonos_mesh

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        if (!BleNodeForegroundService.shouldAutoStartAfterBoot(context)) {
            AutoStartDiagnostics.record(
                context,
                "El inicio automático está desactivado para este teléfono.",
            )
            return
        }
        val serviceIntent = Intent(context, BleNodeForegroundService::class.java)
            .setAction(BleNodeForegroundService.ACTION_START)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            AutoStartDiagnostics.record(
                context,
                if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
                    "Arranque del teléfono detectado; iniciando servicio BLE."
                } else {
                    "Actualización de NEBULA detectada; iniciando servicio BLE."
                },
            )
        } catch (error: SecurityException) {
            AutoStartDiagnostics.record(
                context,
                "Android bloqueó el arranque automático: ${error.message}",
            )
        } catch (error: RuntimeException) {
            AutoStartDiagnostics.record(
                context,
                "No se pudo iniciar el servicio al arrancar: ${error.message}",
            )
        }
    }
}
