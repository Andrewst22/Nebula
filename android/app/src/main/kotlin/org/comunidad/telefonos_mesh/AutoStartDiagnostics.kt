package org.comunidad.telefonos_mesh

import android.content.Context

internal object AutoStartDiagnostics {
    private const val PREFERENCES = "enlace_auto_start_diagnostics"
    private const val LAST_STATUS = "last_status"
    private const val LAST_TIME = "last_time"

    fun record(context: Context, status: String) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putString(LAST_STATUS, status)
            .putLong(LAST_TIME, System.currentTimeMillis())
            .apply()
    }

    fun read(context: Context): Map<String, Any> {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        return mapOf(
            "status" to (preferences.getString(LAST_STATUS, "Sin evento de arranque registrado.")
                ?: "Sin evento de arranque registrado."),
            "timestamp" to preferences.getLong(LAST_TIME, 0L),
            "autoStartEnabled" to BleNodeForegroundService.shouldAutoStartAfterBoot(context),
        )
    }
}
