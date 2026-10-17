package org.comunidad.telefonos_mesh

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import org.json.JSONException
import java.nio.charset.StandardCharsets

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.comunidad.enlace/ble",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidSdk" -> result.success(android.os.Build.VERSION.SDK_INT)
                "getAutoStartDiagnostics" -> {
                    result.success(AutoStartDiagnostics.read(this))
                }
                "setSeismicAlarmEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled")
                    if (enabled == null) {
                        result.error(
                            "seismic_alarm_invalid",
                            "Falta indicar si la alarma experimental está activada.",
                            null,
                        )
                    } else {
                        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                            .edit()
                            .putBoolean("flutter.seismic_alarm_enabled", enabled)
                            .apply()
                        if (BleNodeRuntime.controller != null) {
                            startService(
                                Intent(this, BleNodeForegroundService::class.java)
                                    .setAction(
                                        BleNodeForegroundService.ACTION_SET_SEISMIC_ALARM,
                                    )
                                    .putExtra(
                                        BleNodeForegroundService.EXTRA_ENABLED,
                                        enabled,
                                    ),
                            )
                        }
                        result.success(null)
                    }
                }
                "getCurrentGpsLocation" -> getCurrentGpsLocation(result)
                "setNodeName" -> {
                    val name = call.argument<String>("name")?.trim()
                    if (name.isNullOrEmpty() ||
                        name.toByteArray(StandardCharsets.UTF_8).size > BleNodeController.MAX_NODE_NAME_BYTES
                    ) {
                        result.error(
                            "ble_invalid_node_name",
                            "El nombre debe ocupar entre 1 y 12 bytes UTF-8.",
                            null,
                        )
                    } else {
                        getSharedPreferences(
                            BleNodeController.NODE_IDENTITY_PREFERENCES,
                            MODE_PRIVATE,
                        )
                            .edit()
                            .putString(BleNodeController.NODE_NAME_KEY, name)
                            .apply()
                        BleNodeRuntime.controller?.setNodeName(name)
                        result.success(null)
                    }
                }
                "startNode" -> {
                    try {
                        val serviceIntent = Intent(
                            this,
                            BleNodeForegroundService::class.java,
                        ).setAction(BleNodeForegroundService.ACTION_START)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        result.success(null)
                    } catch (error: SecurityException) {
                        result.error("ble_permission_denied", error.message, null)
                    } catch (error: IllegalStateException) {
                        result.error(
                            "ble_service_start_failed",
                            error.message ?: "Android no permitió iniciar el servicio BLE.",
                            null,
                        )
                    }
                }
                "stopNode" -> {
                    stopService(Intent(this, BleNodeForegroundService::class.java))
                    result.success(null)
                }
                "getBackgroundMessages" -> {
                    try {
                        result.success(BleStoredMessageStore(this).loadPayloads())
                    } catch (error: JSONException) {
                        result.error(
                            "ble_message_store_invalid",
                            error.message ?: "No se pudieron leer los avisos BLE guardados.",
                            null,
                        )
                    }
                }
                "clearAllMessages" -> {
                    try {
                        BleStoredMessageStore(this).clearMessages()
                        BleNodeForegroundService.clearMessageNotifications(this)
                        result.success(null)
                    } catch (error: IllegalStateException) {
                        result.error(
                            "ble_message_store_clear_failed",
                            error.message ?: "No se pudo borrar el historial de mensajes.",
                            null,
                        )
                    }
                }
                "broadcastMessage" -> {
                    val payload = call.argument<String>("payload")
                    if (payload == null) {
                        result.error(
                            "ble_invalid_message",
                            "Falta el contenido del mensaje.",
                            null,
                        )
                    } else {
                        val controller = BleNodeRuntime.controller
                        if (controller == null) {
                            result.error(
                                "ble_node_inactive",
                                "El servicio de nodo BLE no está activo.",
                                null,
                            )
                        } else {
                            controller.broadcast(
                                payload,
                                call.argument<String>("excludedAddress"),
                                result,
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.comunidad.enlace/ble-events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                BleNodeRuntime.setEventSink(events)
            }

            override fun onCancel(arguments: Any?) {
                BleNodeRuntime.setEventSink(null)
            }
        })
    }

    private fun getCurrentGpsLocation(result: MethodChannel.Result) {
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            result.error(
                "location_precise_permission_denied",
                "Concede permiso de ubicación precisa para obtener coordenadas GPS.",
                null,
            )
            return
        }
        val manager = getSystemService(LOCATION_SERVICE) as LocationManager
        if (!manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            result.error(
                "location_gps_disabled",
                "Activa la ubicación/GPS del teléfono e inténtalo de nuevo.",
                null,
            )
            return
        }

        val handler = Handler(Looper.getMainLooper())
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val cancellation = CancellationSignal()
                var completed = false
                val timeout = Runnable {
                    if (completed) return@Runnable
                    completed = true
                    cancellation.cancel()
                    result.error(
                        "location_timeout",
                        "No se obtuvo una posición GPS a tiempo. Intenta cerca de una ventana o al aire libre.",
                        null,
                    )
                }
                handler.postDelayed(timeout, GPS_LOCATION_TIMEOUT_MS)
                manager.getCurrentLocation(
                    LocationManager.GPS_PROVIDER,
                    cancellation,
                    mainExecutor,
                ) { location ->
                    handler.removeCallbacks(timeout)
                    if (completed) return@getCurrentLocation
                    completed = true
                    if (location == null) {
                        result.error(
                            "location_unavailable",
                            "No se pudo obtener una posición GPS actual.",
                            null,
                        )
                    } else {
                        result.success(location.toResultMap())
                    }
                }
            } else {
                var completed = false
                lateinit var listener: LocationListener
                val timeout = Runnable {
                    if (completed) return@Runnable
                    completed = true
                    manager.removeUpdates(listener)
                    result.error(
                        "location_timeout",
                        "No se obtuvo una posición GPS a tiempo. Intenta cerca de una ventana o al aire libre.",
                        null,
                    )
                }
                listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        if (completed) return
                        completed = true
                        handler.removeCallbacks(timeout)
                        manager.removeUpdates(this)
                        result.success(location.toResultMap())
                    }

                    override fun onStatusChanged(
                        provider: String?,
                        status: Int,
                        extras: Bundle?,
                    ) = Unit

                    override fun onProviderEnabled(provider: String) = Unit

                    override fun onProviderDisabled(provider: String) {
                        if (completed) return
                        completed = true
                        handler.removeCallbacks(timeout)
                        manager.removeUpdates(this)
                        result.error(
                            "location_gps_disabled",
                            "El GPS se desactivó antes de obtener la posición.",
                            null,
                        )
                    }
                }
                handler.postDelayed(timeout, GPS_LOCATION_TIMEOUT_MS)
                manager.requestSingleUpdate(
                    LocationManager.GPS_PROVIDER,
                    listener,
                    Looper.getMainLooper(),
                )
            }
        } catch (error: SecurityException) {
            result.error(
                "location_permission_denied",
                error.message ?: "Android denegó el permiso de ubicación precisa.",
                null,
            )
        } catch (error: IllegalArgumentException) {
            result.error(
                "location_gps_unavailable",
                error.message ?: "El GPS no está disponible en este teléfono.",
                null,
            )
        }
    }

    private fun Location.toResultMap(): Map<String, Double> = mapOf(
        "latitude" to latitude,
        "longitude" to longitude,
        "accuracyMeters" to accuracy.toDouble(),
    )

    companion object {
        private const val GPS_LOCATION_TIMEOUT_MS = 30_000L
    }
}
