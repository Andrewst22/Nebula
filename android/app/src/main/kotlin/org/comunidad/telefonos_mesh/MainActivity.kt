package org.comunidad.telefonos_mesh

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.provider.Settings
import org.json.JSONException
import java.nio.charset.StandardCharsets

class MainActivity : FlutterActivity() {
    private var pendingPhotoPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.comunidad.enlace/ble",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidSdk" -> result.success(android.os.Build.VERSION.SDK_INT)
                "hasWifiDirectPermission" -> {
                    val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        android.Manifest.permission.NEARBY_WIFI_DEVICES
                    } else {
                        android.Manifest.permission.ACCESS_FINE_LOCATION
                    }
                    result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                            checkSelfPermission(permission) ==
                            android.content.pm.PackageManager.PERMISSION_GRANTED,
                    )
                }
                "startPhotoTransport" -> {
                    try {
                        val serviceIntent = Intent(
                            this,
                            BleNodeForegroundService::class.java,
                        ).setAction(BleNodeForegroundService.ACTION_START_WIFI_PHOTOS)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        result.success(null)
                    } catch (error: SecurityException) {
                        result.error(
                            "wifi_direct_start_failed",
                            error.message ?: "Android no permitió iniciar Wi-Fi Direct.",
                            null,
                        )
                    }
                }
                "openWifiSettings" -> {
                    try {
                        val settingsIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            Intent(Settings.Panel.ACTION_WIFI)
                        } else {
                            Intent(Settings.ACTION_WIFI_SETTINGS)
                        }
                        startActivity(settingsIntent)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error(
                            "wifi_settings_unavailable",
                            error.message ?: "No se pudieron abrir los ajustes de Wi-Fi.",
                            null,
                        )
                    }
                }
                "pickPhoto" -> {
                    if (pendingPhotoPick != null) {
                        result.error(
                            "photo_picker_busy",
                            "Ya hay una selección de foto abierta.",
                            null,
                        )
                    } else {
                        pendingPhotoPick = result
                        try {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "image/*"
                                putExtra(
                                    Intent.EXTRA_MIME_TYPES,
                                    arrayOf("image/jpeg", "image/png", "image/webp"),
                                )
                            }
                            startActivityForResult(intent, PICK_PHOTO_REQUEST)
                        } catch (error: Exception) {
                            pendingPhotoPick = null
                            result.error(
                                "photo_picker_unavailable",
                                error.message ?: "No se pudo abrir el selector de fotos.",
                                null,
                            )
                        }
                    }
                }
                "enqueuePhoto" -> {
                    val id = call.argument<String>("id")
                    val reportPayload = call.argument<String>("reportPayload")
                    if (id == null || reportPayload == null) {
                        result.error("photo_data_missing", "Faltan los datos del reporte con foto.", null)
                    } else {
                        try {
                            val store = NebulaPhotoStore(this)
                            store.enqueue(id, reportPayload)
                            WifiDirectPhotoRuntime.transport?.enqueuePhoto()
                            result.success(null)
                        } catch (error: Exception) {
                            result.error(
                                "photo_enqueue_failed",
                                error.message ?: "No se pudo poner la foto en la cola de envío.",
                                null,
                            )
                        }
                    }
                }
                "getPhotoPath" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("photo_id_missing", "Falta el identificador de la foto.", null)
                    } else {
                        result.success(NebulaPhotoStore(this).photoPath(id))
                    }
                }
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
                "refreshBleScan" -> {
                    try {
                        val controller = BleNodeRuntime.controller
                            ?: throw BleNodeException(
                                "ble_node_inactive",
                                "El nodo BLE no está activo para buscar mensajes.",
                            )
                        controller.refreshScan()
                        result.success(null)
                    } catch (error: BleNodeException) {
                        result.error(error.code, error.message, null)
                    }
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
                        NebulaPhotoStore(this).clearAll()
                        BleStoredMessageStore(this).clearMessages()
                        BleNodeRuntime.controller?.clearPendingSends()
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
                            try {
                                BleStoredMessageStore(this).enqueueOutbound(payload)
                                controller.broadcast(
                                    payload,
                                    call.argument<String>("excludedAddress"),
                                    result,
                                )
                            } catch (error: org.json.JSONException) {
                                result.error(
                                    "ble_invalid_message",
                                    error.message ?: "El aviso no cumple el formato permitido.",
                                    null,
                                )
                            } catch (error: IllegalStateException) {
                                result.error(
                                    "ble_message_queue_failed",
                                    error.message ?: "No se pudo guardar el aviso para reintento.",
                                    null,
                                )
                            }
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

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_PHOTO_REQUEST) return
        val result = pendingPhotoPick ?: return
        pendingPhotoPick = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }
        val uri: Uri = data?.data ?: run {
            result.error("photo_uri_missing", "El selector no devolvió una foto.", null)
            return
        }
        try {
            val photo = NebulaPhotoStore(this).importPhoto(contentResolver, uri)
            result.success(
                mapOf(
                    "id" to photo.id,
                    "path" to photo.file.absolutePath,
                    "bytes" to photo.bytes.toInt(),
                    "mimeType" to photo.mimeType,
                ),
            )
        } catch (error: Exception) {
            result.error(
                "photo_import_failed",
                error.message ?: "No se pudo guardar la foto seleccionada.",
                null,
            )
        }
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
        private const val PICK_PHOTO_REQUEST = 7401
        private const val GPS_LOCATION_TIMEOUT_MS = 30_000L
    }
}
