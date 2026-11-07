package org.comunidad.telefonos_mesh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.plugin.common.EventChannel
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.sqrt

internal object BleNodeRuntime {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var seismicAlarmState: Map<String, Any?> = mapOf(
        "seismicAlarmMonitoring" to false,
        "seismicAlarmTriggered" to false,
    )
    private var wifiTransferState: Map<String, Any?> = emptyMap()
    var controller: BleNodeController? = null
        private set

    fun attachController(value: BleNodeController?) {
        controller = value
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        if (sink != null) {
            publishEvent(seismicAlarmState)
            if (wifiTransferState.isNotEmpty()) publishEvent(wifiTransferState)
            controller?.onUiAttached()
        }
    }

    fun publishSeismicAlarmState(
        monitoring: Boolean,
        triggered: Boolean,
        error: String? = null,
    ) {
        seismicAlarmState = buildMap {
            put("seismicAlarmMonitoring", monitoring)
            put("seismicAlarmTriggered", triggered)
            if (error != null) put("seismicAlarmError", error)
        }
        publishEvent(seismicAlarmState)
    }

    fun publishEvent(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }

    fun publishWifiTransferStatus(message: String) {
        wifiTransferState = mapOf("wifiTransferStatus" to message)
        publishEvent(wifiTransferState)
    }
}

internal object WifiDirectPhotoRuntime {
    @Volatile
    var transport: WifiDirectPhotoTransport? = null
}

class BleNodeForegroundService : Service(), SensorEventListener {
    private lateinit var notificationManager: NotificationManager
    private lateinit var storedMessageStore: BleStoredMessageStore
    private lateinit var photoStore: NebulaPhotoStore
    private var nodeController: BleNodeController? = null
    private var photoTransport: WifiDirectPhotoTransport? = null
    private var foregroundStarted = false
    private var retryAttempt = 0
    private var sensorManager: SensorManager? = null
    private var motionSensor: Sensor? = null
    private var vibrationStartedAt = 0L
    private var seismicAlarmActive = false
    private var alarmPlayer: MediaPlayer? = null
    private var alarmVibrator: Vibrator? = null
    private val serviceHandler = Handler(Looper.getMainLooper())
    private val retryNodeStart = object : Runnable {
        override fun run() {
            if (!foregroundStarted || nodeController == null) return
            startNode()
        }
    }

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        storedMessageStore = BleStoredMessageStore(this)
        photoStore = NebulaPhotoStore(this)
        photoTransport = if (getSystemService(Context.WIFI_P2P_SERVICE) is WifiP2pManager) {
            WifiDirectPhotoTransport(this, photoStore) { payload ->
                val event = mapOf("payload" to payload)
                val forwardedPayload = processIncomingMessage(event, payload)
                PhotoReportRelay(accepted = true, forwardPayload = forwardedPayload)
            }.also {
                WifiDirectPhotoRuntime.transport = it
            }
        } else {
            BleNodeRuntime.publishWifiTransferStatus(
                "Este teléfono no ofrece Wi-Fi Direct; los avisos BLE siguen disponibles.",
            )
            null
        }
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        createNotificationChannels()
        val controller = BleNodeController(
            this,
            ::onNodeEvent,
            storedMessageStore::pendingForPeer,
            storedMessageStore::markDelivered,
        )
        nodeController = controller
        BleNodeRuntime.attachController(controller)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SET_SEISMIC_ALARM -> {
                val enabled = intent.getBooleanExtra(EXTRA_ENABLED, false)
                if (enabled) {
                    if (!foregroundStarted) {
                        enterForeground()
                        startNode()
                        photoTransport?.start()
                    }
                    startSeismicMonitoring()
                } else {
                    stopSeismicMonitoring()
                }
                return START_STICKY
            }
            ACTION_SILENCE_SEISMIC_ALARM -> {
                silenceSeismicAlarm()
                return START_STICKY
            }
            ACTION_STOP -> {
                stopNode()
                return START_NOT_STICKY
            }
            ACTION_START_WIFI_PHOTOS -> {
                enterForeground()
                photoTransport?.start()
                return START_STICKY
            }
            ACTION_START, null -> {
                if (intent == null && !shouldAutoStartAfterBoot(this)) {
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                enterForeground()
                startNode()
                photoTransport?.start()
                if (isSeismicAlarmEnabled()) startSeismicMonitoring()
                return START_STICKY
            }
            else -> {
                stopSelf(startId)
                return START_NOT_STICKY
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        serviceHandler.removeCallbacks(retryNodeStart)
        stopSeismicMonitoring()
        silenceSeismicAlarm()
        photoTransport?.stop()
        photoTransport = null
        WifiDirectPhotoRuntime.transport = null
        nodeController?.stop()
        nodeController = null
        BleNodeRuntime.attachController(null)
        if (foregroundStarted) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            foregroundStarted = false
        }
        super.onDestroy()
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (!isSeismicAlarmEnabled() || seismicAlarmActive ||
            event.sensor.type != Sensor.TYPE_LINEAR_ACCELERATION
        ) {
            return
        }
        val x = event.values[0].toDouble()
        val y = event.values[1].toDouble()
        val z = event.values[2].toDouble()
        val magnitude = sqrt(x * x + y * y + z * z)
        val now = System.currentTimeMillis()
        if (magnitude >= SEISMIC_ACCELERATION_THRESHOLD) {
            if (vibrationStartedAt == 0L) vibrationStartedAt = now
            if (now - vibrationStartedAt >= SEISMIC_CONFIRMATION_MS) {
                triggerSeismicAlarm()
            }
        } else {
            vibrationStartedAt = 0L
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun startSeismicMonitoring() {
        if (!isSeismicAlarmEnabled()) return
        val manager = sensorManager ?: return
        val sensor = manager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
        if (sensor == null) {
            BleNodeRuntime.publishSeismicAlarmState(
                monitoring = false,
                triggered = false,
                error = "Este teléfono no ofrece acelerómetro lineal para la alarma experimental.",
            )
            return
        }
        if (motionSensor === sensor) return
        stopSeismicMonitoring()
        motionSensor = sensor
        val registered = manager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME)
        if (!registered) {
            motionSensor = null
            BleNodeRuntime.publishSeismicAlarmState(
                monitoring = false,
                triggered = false,
                error = "Android no pudo activar el sensor de movimiento.",
            )
            return
        }
        BleNodeRuntime.publishSeismicAlarmState(monitoring = true, triggered = false)
    }

    private fun stopSeismicMonitoring() {
        sensorManager?.unregisterListener(this)
        motionSensor = null
        vibrationStartedAt = 0L
        silenceSeismicAlarm()
        BleNodeRuntime.publishSeismicAlarmState(monitoring = false, triggered = false)
    }

    private fun triggerSeismicAlarm() {
        if (seismicAlarmActive) return
        seismicAlarmActive = true
        val soundError = playAlarmSound()
        vibrateForAlarm()
        notificationManager.notify(SEISMIC_ALARM_NOTIFICATION_ID, buildSeismicAlarmNotification())
        BleNodeRuntime.publishSeismicAlarmState(
            monitoring = true,
            triggered = true,
            error = soundError,
        )
    }

    private fun silenceSeismicAlarm() {
        alarmPlayer?.let { player ->
            player.stop()
            player.release()
        }
        alarmPlayer = null
        alarmVibrator?.cancel()
        alarmVibrator = null
        if (seismicAlarmActive) {
            seismicAlarmActive = false
            notificationManager.cancel(SEISMIC_ALARM_NOTIFICATION_ID)
            BleNodeRuntime.publishSeismicAlarmState(
                monitoring = motionSensor != null,
                triggered = false,
            )
        }
    }

    private fun playAlarmSound(): String? {
        val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: return "Android no tiene un sonido de alarma configurado."
        val player = MediaPlayer()
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            player.setDataSource(this, alarmUri)
            player.isLooping = true
            player.prepare()
            player.start()
            alarmPlayer = player
            return null
        } catch (error: java.io.IOException) {
            player.release()
            return "No se pudo cargar el sonido de alarma: ${error.message}"
        } catch (error: IllegalArgumentException) {
            player.release()
            return "El sonido de alarma del sistema no es compatible."
        } catch (error: IllegalStateException) {
            player.release()
            return "Android no pudo reproducir el sonido de alarma."
        }
    }

    private fun vibrateForAlarm() {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager)
                .defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (!vibrator.hasVibrator()) return
        alarmVibrator = vibrator
        val pattern = longArrayOf(0, 700, 350, 700)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(pattern, 0))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(pattern, 0)
        }
    }

    private fun buildSeismicAlarmNotification(): Notification {
        val silenceIntent = PendingIntent.getService(
            this,
            SEISMIC_ALARM_REQUEST_CODE,
            Intent(this, BleNodeForegroundService::class.java)
                .setAction(ACTION_SILENCE_SEISMIC_ALARM),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return newNotificationBuilder(SEISMIC_ALARM_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Movimiento sostenido detectado")
            .setContentText("Alarma experimental; verifica la situación y sigue indicaciones oficiales.")
            .setStyle(
                Notification.BigTextStyle().bigText(
                    "El sensor detectó vibración sostenida. No confirma un sismo ni predice peligro.",
                ),
            )
            .setCategory(Notification.CATEGORY_ALARM)
            .setPriority(Notification.PRIORITY_MAX)
            .setOngoing(true)
            .setContentIntent(openAppIntent())
            .addAction(
                android.R.drawable.ic_media_pause,
                "Silenciar alarma",
                silenceIntent,
            )
            .build()
    }

    private fun isSeismicAlarmEnabled(): Boolean =
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.seismic_alarm_enabled", false)

    private fun startNode() {
        try {
            nodeController?.start()
            retryAttempt = 0
            AutoStartDiagnostics.record(this, "Servicio BLE iniciado.")
        } catch (error: BleNodeException) {
            handleStartFailure(error.message, error.code in RETRYABLE_BLE_ERRORS)
        } catch (error: SecurityException) {
            handleStartFailure(error.message ?: "Permiso Bluetooth denegado.", false)
        } catch (error: IllegalStateException) {
            handleStartFailure(error.message ?: "No se pudo iniciar el nodo BLE.", true)
        }
    }

    private fun handleStartFailure(message: String, retryable: Boolean) {
        publishError(message)
        AutoStartDiagnostics.record(this, "Fallo al iniciar BLE: $message")
        if (retryable && retryAttempt < MAX_START_RETRIES) {
            retryAttempt += 1
            notificationManager.notify(
                SERVICE_NOTIFICATION_ID,
                buildServiceNotification(
                    "Bluetooth no listo; reintento $retryAttempt/$MAX_START_RETRIES.",
                ),
            )
            serviceHandler.removeCallbacks(retryNodeStart)
            serviceHandler.postDelayed(retryNodeStart, START_RETRY_DELAY_MS)
        } else {
            stopSelf()
        }
    }

    private fun stopNode() {
        serviceHandler.removeCallbacks(retryNodeStart)
        stopSeismicMonitoring()
        nodeController?.stop()
        if (foregroundStarted) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            foregroundStarted = false
        }
        stopSelf()
    }

    private fun enterForeground() {
        val notification = buildServiceNotification("Iniciando nodo Bluetooth…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                SERVICE_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(SERVICE_NOTIFICATION_ID, notification)
        }
        foregroundStarted = true
    }

    private fun onNodeEvent(event: Map<String, Any?>) {
        val payload = event["payload"] as? String
        if (payload != null) {
            processIncomingMessage(event, payload)
            return
        }

        BleNodeRuntime.publishEvent(event)
        val error = event["error"] as? String
        if (error != null) {
            notificationManager.notify(
                SERVICE_NOTIFICATION_ID,
                buildServiceNotification("Error del nodo: $error"),
            )
            return
        }
        val active = event["active"] as? Boolean ?: false
        val peers = event["peers"] as? List<*>
        if (active) {
            AutoStartDiagnostics.record(
                this,
                "BLE activo; ${peers?.size ?: 0} teléfonos cercanos detectados.",
            )
            notificationManager.notify(
                SERVICE_NOTIFICATION_ID,
                buildServiceNotification(
                    "Nodo activo · ${peers?.size ?: 0} teléfonos cercanos",
                ),
            )
        }
    }

    private fun processIncomingMessage(
        event: Map<String, Any?>,
        payload: String,
    ): String? {
        val stored = try {
            storedMessageStore.accept(payload)
        } catch (error: JSONException) {
            publishInvalidMessage(event, error.message ?: "El aviso recibido no es válido.")
            return null
        } catch (error: IllegalStateException) {
            publishInvalidMessage(
                event,
                error.message ?: "No se pudo guardar el aviso recibido.",
            )
            return null
        }
        if (stored == null) {
            return try {
                storedMessageStore.forwardingPayload(JSONObject(payload).optString("id"))
                    ?.also { forwarded ->
                        (event["sourceAddress"] as? String)?.let { source ->
                            storedMessageStore.markDelivered(forwarded, source)
                        }
                    }
            } catch (error: JSONException) {
                publishInvalidMessage(
                    event,
                    error.message ?: "No se pudo confirmar el reenvío del aviso.",
                )
                null
            } catch (error: IllegalStateException) {
                publishInvalidMessage(
                    event,
                    error.message ?: "No se pudo confirmar el reenvío del aviso.",
                )
                null
            }
        }

        BleNodeRuntime.publishEvent(event)
        val summary = summarizeMessage(payload)
        val messageNotification = newNotificationBuilder(MESSAGE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle("Aviso recibido por NEBULA")
            .setContentText(summary)
            .setStyle(Notification.BigTextStyle().bigText(summary))
            .setContentIntent(openAppIntent())
            .setAutoCancel(true)
            .build()
        notificationManager.notify(nextMessageNotificationId(), messageNotification)
        val sourceAddress = event["sourceAddress"] as? String
        stored.forwardedPayload?.let { forwarded ->
            try {
                if (sourceAddress != null) {
                    storedMessageStore.markDelivered(forwarded, sourceAddress)
                }
            } catch (error: JSONException) {
                publishInvalidMessage(
                    event,
                    error.message ?: "No se pudo confirmar el reenvío del aviso.",
                )
                return null
            } catch (error: IllegalStateException) {
                publishInvalidMessage(
                    event,
                    error.message ?: "No se pudo confirmar el reenvío del aviso.",
                )
                return null
            }
            nodeController?.broadcastForward(forwarded, sourceAddress)
        }
        return stored.forwardedPayload
    }

    private fun publishInvalidMessage(event: Map<String, Any?>, message: String) {
        BleNodeRuntime.publishEvent(
            event.toMutableMap().apply {
                remove("payload")
                put("error", message)
            },
        )
    }

    private fun publishError(message: String) {
        notificationManager.notify(
            SERVICE_NOTIFICATION_ID,
            buildServiceNotification("Error del nodo: $message"),
        )
        BleNodeRuntime.publishEvent(
            mapOf(
                "active" to false,
                "peers" to emptyList<Map<String, Any>>(),
                "error" to message,
            ),
        )
    }

    private fun buildServiceNotification(text: String): Notification =
        newNotificationBuilder(SERVICE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("NEBULA · nodo fijo")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent())
            .build()

    private fun newNotificationBuilder(channelId: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            Notification.Builder(this)
        }

    private fun openAppIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        notificationManager.createNotificationChannel(
            NotificationChannel(
                SERVICE_CHANNEL_ID,
                "Estado de la red NEBULA",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Indica que este teléfono está funcionando como nodo fijo."
                setShowBadge(false)
            },
        )
        notificationManager.createNotificationChannel(
            NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "Avisos recibidos",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Notifica los avisos recibidos por la red BLE."
            },
        )
        notificationManager.createNotificationChannel(
            NotificationChannel(
                SEISMIC_ALARM_CHANNEL_ID,
                "Alarma experimental de movimiento",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Alerta si el sensor registra vibración sostenida."
                setSound(null, null)
                enableVibration(false)
            },
        )
    }

    private fun summarizeMessage(payload: String): String {
        return try {
            JSONObject(payload).optString("text", "Hay un nuevo mensaje en la red.")
                .replace('\n', ' ')
                .take(MAX_NOTIFICATION_TEXT)
        } catch (_: JSONException) {
            "Hay un nuevo mensaje en la red."
        }
    }

    private fun nextMessageNotificationId(): Int =
        MESSAGE_NOTIFICATION_ID_BASE + notificationSequence.incrementAndGet() % 10_000

    companion object {
        const val ACTION_START = "org.comunidad.telefonos_mesh.START_NODE"
        const val ACTION_STOP = "org.comunidad.telefonos_mesh.STOP_NODE"
        const val ACTION_START_WIFI_PHOTOS = "org.comunidad.telefonos_mesh.START_WIFI_PHOTOS"
        const val ACTION_SET_SEISMIC_ALARM = "org.comunidad.telefonos_mesh.SET_SEISMIC_ALARM"
        const val ACTION_SILENCE_SEISMIC_ALARM =
            "org.comunidad.telefonos_mesh.SILENCE_SEISMIC_ALARM"
        const val EXTRA_ENABLED = "enabled"
        private const val SERVICE_CHANNEL_ID = "enlace_node_status"
        private const val MESSAGE_CHANNEL_ID = "enlace_incoming_messages"
        private const val SEISMIC_ALARM_CHANNEL_ID = "enlace_seismic_alarm"
        private const val SERVICE_NOTIFICATION_ID = 701
        private const val SEISMIC_ALARM_NOTIFICATION_ID = 702
        private const val SEISMIC_ALARM_REQUEST_CODE = 703
        private const val MESSAGE_NOTIFICATION_ID_BASE = 1000
        private const val FIRST_MESSAGE_NOTIFICATION_ID = MESSAGE_NOTIFICATION_ID_BASE + 1
        private const val LAST_MESSAGE_NOTIFICATION_ID = MESSAGE_NOTIFICATION_ID_BASE + 9_999
        private const val MAX_NOTIFICATION_TEXT = 180
        private const val SEISMIC_ACCELERATION_THRESHOLD = 1.2
        private const val SEISMIC_CONFIRMATION_MS = 2_000L
        private const val MAX_START_RETRIES = 12
        private const val START_RETRY_DELAY_MS = 10_000L
        private val RETRYABLE_BLE_ERRORS = setOf(
            "ble_disabled",
            "ble_start_failed",
            "ble_advertising_unavailable",
            "ble_scanning_unavailable",
        )
        private val notificationSequence = AtomicInteger()

        fun clearMessageNotifications(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            manager.activeNotifications
                .filter { it.id in FIRST_MESSAGE_NOTIFICATION_ID..LAST_MESSAGE_NOTIFICATION_ID }
                .forEach { manager.cancel(it.id) }
        }

        fun shouldAutoStartAfterBoot(context: Context): Boolean =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .let { preferences ->
                    preferences.getBoolean("flutter.auto_start_fixed_node", false) &&
                        preferences.getString("flutter.node_mode", "fixed") == "fixed"
                }
    }
}
