package org.comunidad.telefonos_mesh

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.NetworkInfo
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.FilterInputStream
import java.io.FileInputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

internal class WifiDirectPhotoTransport(
    private val context: Context,
    private val photoStore: NebulaPhotoStore,
    private val onReportReceived: (String) -> PhotoReportRelay,
) {
    private class LimitedInputStream(
        input: InputStream,
        private var remaining: Long,
    ) : FilterInputStream(input) {
        override fun read(): Int {
            if (remaining == 0L) return -1
            val value = super.read()
            if (value >= 0) remaining--
            return value
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (remaining == 0L) return -1
            val count = super.read(
                buffer,
                offset,
                minOf(length.toLong(), remaining).toInt(),
            )
            if (count > 0) remaining -= count
            return count
        }
    }

    private val manager = context.getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
    private val channel = manager.initialize(context, Looper.getMainLooper(), null)
    private val handler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val nodeId = UUID.randomUUID().toString().replace("-", "")
    private val discoveredNebulaNodes = linkedMapOf<String, String>()
    private val completedPeers = ConcurrentHashMap<String, Long>()
    @Volatile private var started = false
    @Volatile private var connecting = false
    private var receiverRegistered = false
    private var localServiceRegistered = false
    private var serverSocket: ServerSocket? = null

    private val serviceResponseListener =
        WifiP2pManager.DnsSdServiceResponseListener { _, _, _ -> Unit }

    private val txtRecordListener =
        WifiP2pManager.DnsSdTxtRecordListener { _, record, device ->
            if (record["app"] == APP_MARKER && record["node"]?.matches(NODE_ID) == true) {
                discoveredNebulaNodes[device.deviceAddress] = record.getValue("node")
                connectToNextPeer()
            }
        }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                    if (state == WifiP2pManager.WIFI_P2P_STATE_ENABLED) activateWifiDirect()
                    else publishStatus("Activa Wi-Fi para transferir fotos por Wi-Fi Direct.")
                }
                WifiManager.WIFI_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(
                        WifiManager.EXTRA_WIFI_STATE,
                        WifiManager.WIFI_STATE_UNKNOWN,
                    )
                    if (state == WifiManager.WIFI_STATE_ENABLED) activateWifiDirect()
                    else publishStatus("Activa Wi-Fi; NEBULA iniciará Wi-Fi Direct automáticamente.")
                }
                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> Unit
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    val network = intent.getParcelableExtra<NetworkInfo>(
                        WifiP2pManager.EXTRA_NETWORK_INFO,
                    )
                    if (network?.isConnected == true) requestConnectionInfo()
                    else {
                        connecting = false
                        closeServer()
                        if (started) scheduleDiscovery(DISCOVERY_RETRY_MS)
                    }
                }
                WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> Unit
            }
        }
    }

    private val discoverAgain = object : Runnable {
        override fun run() {
            discoverServices()
        }
    }

    @SuppressLint("MissingPermission")
    fun start() {
        if (started) {
            activateWifiDirect()
            return
        }
        started = true
        photoStore.prune()
        val filter = IntentFilter().apply {
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
        activateWifiDirect()
    }

    @SuppressLint("MissingPermission")
    private fun activateWifiDirect() {
        if (!started) return
        val requiredPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            android.Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            android.Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            context.checkSelfPermission(requiredPermission) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            publishStatus(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    "Permite \"Dispositivos Wi-Fi cercanos\" a NEBULA para recibir y reenviar fotos."
                } else {
                    "Permite ubicación mientras se usa NEBULA para descubrir nodos Wi-Fi Direct."
                },
            )
            return
        }
        val wifiManager = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (!wifiManager.isWifiEnabled) {
            publishStatus("Activa Wi-Fi; NEBULA iniciará Wi-Fi Direct automáticamente.")
            return
        }
        try {
            if (!localServiceRegistered) {
                val serviceInfo = WifiP2pDnsSdServiceInfo.newInstance(
                    SERVICE_INSTANCE,
                    SERVICE_TYPE,
                    mapOf("app" to APP_MARKER, "node" to nodeId),
                )
                manager.addLocalService(
                    channel,
                    serviceInfo,
                    object : WifiP2pManager.ActionListener {
                        override fun onSuccess() {
                            localServiceRegistered = true
                            scheduleDiscovery(0L)
                            publishStatus("Wi-Fi Direct activo; buscando nodos NEBULA para fotos.")
                        }

                        override fun onFailure(reason: Int) {
                            publishStatus(
                                "No se pudo anunciar NEBULA por Wi-Fi Direct (código $reason).",
                            )
                            scheduleDiscovery(DISCOVERY_RETRY_MS)
                        }
                    },
                )
            } else {
                discoverServices()
            }
        } catch (error: SecurityException) {
            publishStatus("Android denegó el acceso Wi-Fi Direct: ${error.message}")
        }
    }

    fun stop() {
        if (!started) return
        started = false
        handler.removeCallbacks(discoverAgain)
        if (receiverRegistered) {
            try {
                context.unregisterReceiver(receiver)
            } catch (_: IllegalArgumentException) {
                receiverRegistered = false
            }
            receiverRegistered = false
        }
        closeServer()
        localServiceRegistered = false
        try {
            manager.clearServiceRequests(channel, action("No se pudo detener la búsqueda Wi-Fi Direct."))
            manager.clearLocalServices(channel, action("No se pudo retirar el servicio NEBULA."))
            manager.removeGroup(channel, null)
        } catch (error: SecurityException) {
            publishStatus("Android bloqueó el cierre de Wi-Fi Direct: ${error.message}")
        }
        executor.shutdownNow()
    }

    fun enqueuePhoto() {
        completedPeers.clear()
        if (started) discoverServices()
    }

    @SuppressLint("MissingPermission")
    private fun discoverServices() {
        if (!started || connecting) return
        if (!localServiceRegistered) {
            activateWifiDirect()
            return
        }
        try {
            manager.clearServiceRequests(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    val request = WifiP2pDnsSdServiceRequest.newInstance()
                    manager.addServiceRequest(channel, request, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() {
                            manager.setDnsSdResponseListeners(
                                channel,
                                serviceResponseListener,
                                txtRecordListener,
                            )
                            manager.discoverServices(channel, object : WifiP2pManager.ActionListener {
                                override fun onSuccess() {
                                    handler.removeCallbacks(discoverAgain)
                                    handler.postDelayed(discoverAgain, DISCOVERY_INTERVAL_MS)
                                }

                                override fun onFailure(reason: Int) {
                                    publishStatus("Falló la búsqueda Wi-Fi Direct (código $reason).")
                                    scheduleDiscovery(DISCOVERY_RETRY_MS)
                                }
                            })
                        }

                        override fun onFailure(reason: Int) {
                            publishStatus("No se pudo registrar la búsqueda Wi-Fi Direct (código $reason).")
                            scheduleDiscovery(DISCOVERY_RETRY_MS)
                        }
                    })
                }

                override fun onFailure(reason: Int) {
                    publishStatus("No se pudo preparar la búsqueda Wi-Fi Direct (código $reason).")
                    scheduleDiscovery(DISCOVERY_RETRY_MS)
                }
            })
        } catch (error: SecurityException) {
            publishStatus("Concede el permiso de dispositivos Wi-Fi cercanos: ${error.message}")
        }
    }

    @SuppressLint("MissingPermission")
    private fun connectToNextPeer() {
        if (!started || connecting) return
        val now = System.currentTimeMillis()
        completedPeers.entries.removeAll { now - it.value > PEER_COOLDOWN_MS }
        val candidate = discoveredNebulaNodes.entries.firstOrNull { (address, peerId) ->
            address.isNotBlank() && nodeId < peerId && !completedPeers.containsKey(peerId)
        } ?: return
        connecting = true
        val config = WifiP2pConfig().apply {
            deviceAddress = candidate.key
            groupOwnerIntent = 0
        }
        manager.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                publishStatus("Conectando por Wi-Fi Direct con un nodo NEBULA…")
                handler.postDelayed({
                    if (connecting) {
                        connecting = false
                        scheduleDiscovery(DISCOVERY_RETRY_MS)
                    }
                }, CONNECTION_TIMEOUT_MS)
            }

            override fun onFailure(reason: Int) {
                connecting = false
                publishStatus("No se pudo conectar por Wi-Fi Direct (código $reason).")
                scheduleDiscovery(DISCOVERY_RETRY_MS)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun requestConnectionInfo() {
        try {
            manager.requestConnectionInfo(channel) { info ->
                if (info?.groupFormed != true) return@requestConnectionInfo
                connecting = true
                if (info.isGroupOwner) startServer()
                else connectToGroupOwner(info)
            }
        } catch (error: SecurityException) {
            connecting = false
            publishStatus("Android denegó la conexión Wi-Fi Direct: ${error.message}")
        }
    }

    private fun startServer() {
        if (serverSocket != null) return
        executor.execute {
            try {
                val server = ServerSocket(PORT).apply { soTimeout = SERVER_ACCEPT_TIMEOUT_MS }
                serverSocket = server
                publishStatus("Nodo Wi-Fi Direct listo para recibir una foto.")
                while (started && !server.isClosed) {
                    try {
                        server.accept().use { socket -> synchronize(socket, isGroupOwner = true) }
                    } catch (_: java.net.SocketTimeoutException) {
                        if (!started) break
                    }
                }
            } catch (error: Exception) {
                if (started) publishStatus("Falló la recepción Wi-Fi Direct: ${error.message}")
            } finally {
                closeServer()
                connecting = false
                if (started) scheduleDiscovery(DISCOVERY_RETRY_MS)
            }
        }
    }

    private fun connectToGroupOwner(info: WifiP2pInfo) {
        executor.execute {
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(info.groupOwnerAddress, PORT), SOCKET_TIMEOUT_MS)
                    socket.soTimeout = SOCKET_TIMEOUT_MS
                    synchronize(socket, isGroupOwner = false)
                }
            } catch (error: Exception) {
                publishStatus("No se pudo transferir la foto por Wi-Fi Direct: ${error.message}")
            } finally {
                removeGroup()
                connecting = false
                scheduleDiscovery(DISCOVERY_RETRY_MS)
            }
        }
    }

    private fun synchronize(socket: Socket, isGroupOwner: Boolean) {
        socket.soTimeout = SOCKET_TIMEOUT_MS
        val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
        val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
        output.writeUTF(PROTOCOL_MAGIC)
        output.writeUTF(nodeId)
        val localPhotos = photoStore.shareablePhotos()
        output.writeInt(localPhotos.size)
        localPhotos.forEach { output.writeUTF(it.id) }
        output.flush()

        if (input.readUTF() != PROTOCOL_MAGIC) throw IllegalArgumentException("Protocolo NEBULA no válido.")
        val remoteNodeId = input.readUTF()
        if (!NODE_ID.matches(remoteNodeId) || remoteNodeId == nodeId) {
            throw IllegalArgumentException("Identidad del nodo no válida.")
        }
        val remoteCount = input.readInt()
        if (remoteCount !in 0..MAX_INVENTORY_ITEMS) {
            throw IllegalArgumentException("Inventario de fotos no válido.")
        }
        val remoteIds = buildSet {
            repeat(remoteCount) {
                val id = input.readUTF()
                if (!PHOTO_ID.matches(id)) throw IllegalArgumentException("Identificador de foto no válido.")
                add(id)
            }
        }
        val newPhotos = localPhotos.filterNot { it.id in remoteIds }
        var receivedPhotos = false
        if (nodeId < remoteNodeId) {
            sendPhotos(output, input, newPhotos)
            receivedPhotos = receivePhotos(input, output)
        } else {
            receivedPhotos = receivePhotos(input, output)
            sendPhotos(output, input, newPhotos)
        }
        output.flush()
        if (receivedPhotos) completedPeers.clear()
        completedPeers[remoteNodeId] = System.currentTimeMillis()
        publishStatus(
            if (newPhotos.isEmpty()) "Nodos NEBULA sincronizados; no había fotos nuevas."
            else "Foto(s) compartida(s) por Wi-Fi Direct con un nodo NEBULA.",
        )
        if (isGroupOwner) connecting = false
    }

    private fun sendPhotos(
        output: DataOutputStream,
        input: DataInputStream,
        photos: List<NebulaPhoto>,
    ) {
        output.writeInt(photos.size)
        photos.forEach { photo ->
            publishStatus("Enviando foto por Wi-Fi Direct (${photo.bytes / 1024} KB)…")
            output.writeUTF(photo.id)
            output.writeLong(photo.bytes)
            output.writeUTF(photo.mimeType)
            output.writeUTF(photo.sha256)
            output.writeLong(photo.expiresAt)
            output.writeUTF(
                photo.reportPayload
                    ?: throw IllegalStateException("La foto no tiene un reporte asociado."),
            )
            FileInputStream(photo.file).use { file ->
                val buffer = ByteArray(32 * 1024)
                var sent = 0L
                while (true) {
                    val count = file.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    sent += count
                }
                if (sent != photo.bytes) {
                    throw IllegalStateException("El archivo local cambió durante la transferencia.")
                }
            }
            output.flush()
            if (!input.readBoolean()) {
                throw IllegalStateException("El otro nodo no pudo guardar la foto.")
            }
            publishStatus("Foto guardada por el nodo vecino.")
        }
    }

    private fun receivePhotos(
        input: DataInputStream,
        output: DataOutputStream,
    ): Boolean {
        val count = input.readInt()
        if (count !in 0..MAX_PHOTOS_PER_TRANSFER) {
            throw IllegalArgumentException("Cantidad de fotos no válida.")
        }
        var receivedAny = false
        repeat(count) {
            val id = input.readUTF()
            val bytes = input.readLong()
            val mime = input.readUTF()
            val sha256 = input.readUTF()
            val expiresAt = input.readLong()
            val reportPayload = input.readUTF()
            if (!PHOTO_ID.matches(id) || bytes !in 1..NebulaPhotoStore.MAX_PHOTO_BYTES ||
                mime !in ALLOWED_MIME_TYPES || !SHA256.matches(sha256)
            ) {
                throw IllegalArgumentException("Metadatos de foto no válidos.")
            }
            publishStatus("Recibiendo foto por Wi-Fi Direct (${bytes / 1024} KB)…")
            val relay = onReportReceived(reportPayload)
            if (!relay.accepted) {
                output.writeBoolean(false)
                output.flush()
                throw IllegalArgumentException("El aviso asociado a la foto no es válido.")
            }
            try {
                photoStore.acceptReceived(
                    id = id,
                    mimeType = mime,
                    bytes = bytes,
                    sha256 = sha256,
                    expiresAt = expiresAt,
                    reportPayload = reportPayload,
                    forwardPayload = relay.forwardPayload,
                    input = LimitedInputStream(input, bytes),
                )
            } catch (error: Exception) {
                output.writeBoolean(false)
                output.flush()
                throw error
            }
            output.writeBoolean(true)
            output.flush()
            receivedAny = true
        }
        return receivedAny
    }

    private fun removeGroup() {
        try {
            manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    connecting = false
                    scheduleDiscovery(DISCOVERY_RETRY_MS)
                }

                override fun onFailure(reason: Int) {
                    connecting = false
                    scheduleDiscovery(DISCOVERY_RETRY_MS)
                }
            })
        } catch (error: SecurityException) {
            connecting = false
            publishStatus("No se pudo cerrar el grupo Wi-Fi Direct: ${error.message}")
        }
    }

    private fun closeServer() {
        try {
            serverSocket?.close()
        } catch (_: Exception) {
            // The accept loop is already terminating.
        }
        serverSocket = null
    }

    private fun scheduleDiscovery(delay: Long) {
        handler.removeCallbacks(discoverAgain)
        if (started) handler.postDelayed(discoverAgain, delay)
    }

    private fun action(failure: String) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() = Unit

        override fun onFailure(reason: Int) {
            publishStatus("$failure (código $reason).")
        }
    }

    private fun publishStatus(message: String) {
        BleNodeRuntime.publishWifiTransferStatus(message)
    }

    companion object {
        private const val APP_MARKER = "NEBULA"
        private const val SERVICE_INSTANCE = "nebula-files"
        private const val SERVICE_TYPE = "_nebula._tcp"
        private const val PROTOCOL_MAGIC = "NEBULA-P2P-2"
        private const val PORT = 8988
        private const val MAX_INVENTORY_ITEMS = 100
        private const val MAX_PHOTOS_PER_TRANSFER = 20
        private const val SOCKET_TIMEOUT_MS = 60_000
        private const val CONNECTION_TIMEOUT_MS = 30_000L
        private const val SERVER_ACCEPT_TIMEOUT_MS = 10_000
        private const val DISCOVERY_INTERVAL_MS = 20_000L
        private const val DISCOVERY_RETRY_MS = 8_000L
        private const val PEER_COOLDOWN_MS = 20_000L
        private val NODE_ID = Regex("^[a-f0-9]{32}$")
        private val PHOTO_ID = Regex("^[a-f0-9]{32}$")
        private val SHA256 = Regex("^[a-f0-9]{64}$")
        private val ALLOWED_MIME_TYPES = setOf("image/jpeg", "image/png", "image/webp")
    }
}
