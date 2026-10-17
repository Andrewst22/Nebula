package org.comunidad.telefonos_mesh

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.UUID
import kotlin.random.Random

internal class BleNodeException(val code: String, override val message: String) :
    Exception(message)

internal class BleNodeController(
    context: Context,
    private val publishEvent: (Map<String, Any?>) -> Unit,
) {
    private data class Peer(
        val id: String,
        val name: String,
        val address: String,
        val rssi: Int,
        val lastSeen: Long,
    )

    private data class Assembly(
        val chunks: Array<ByteArray?>,
        var receivedBytes: Int = 0,
        var receivedChunks: Int = 0,
        val createdAt: Long = System.currentTimeMillis(),
    )

    private data class OutgoingTransfer(
        val gatt: BluetoothGatt,
        val characteristic: BluetoothGattCharacteristic,
        val payload: ByteArray,
        var frames: List<ByteArray> = emptyList(),
        var nextFrame: Int = 0,
    )

    private data class PendingSend(val address: String, val payload: ByteArray)

    private val appContext = context.applicationContext
    private val bluetoothManager =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val peers = mutableMapOf<String, Peer>()
    private val assemblies = mutableMapOf<String, Assembly>()
    private val outgoingTransfers = mutableMapOf<String, OutgoingTransfer>()
    private val clientConnections = mutableMapOf<String, BluetoothGatt>()
    private val pendingSends = ArrayDeque<PendingSend>()
    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var gattServer: BluetoothGattServer? = null
    private var isRunning = false
    private var activeTransferAddress: String? = null
    private var nextPeerId = 1
    private var advertisingRestart: Runnable? = null
    private var nodeName: String = appContext.getSharedPreferences(
        NODE_IDENTITY_PREFERENCES,
        Context.MODE_PRIVATE,
    ).getString(NODE_NAME_KEY, DEFAULT_NODE_NAME) ?: DEFAULT_NODE_NAME
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null

    private val expirePeers = object : Runnable {
        override fun run() {
            synchronized(this@BleNodeController) {
                if (!isRunning) return
                val cutoff = System.currentTimeMillis() - PEER_TIMEOUT_MS
                val changed = peers.entries.removeAll { it.value.lastSeen < cutoff }
                assemblies.entries.removeAll {
                    System.currentTimeMillis() - it.value.createdAt > ASSEMBLY_TIMEOUT_MS
                }
                if (changed) emitState()
                mainHandler.postDelayed(this, PEER_REFRESH_MS)
            }
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (characteristic.uuid != MESSAGE_CHARACTERISTIC_UUID ||
                preparedWrite ||
                offset != 0
            ) {
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED,
                        0,
                        null,
                    )
                }
                return
            }

            val result = acceptFrame(device.address, value)
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        if (result) {
                            BluetoothGatt.GATT_SUCCESS
                        } else {
                            BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH
                        },
                        0,
                        null,
                    )
                } catch (error: SecurityException) {
                    emitFailure(error.message ?: "Falta permiso para responder por GATT.")
                }
            }
        }

        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emitFailure("No se pudo registrar el servicio BLE (código $status).")
            }
        }
    }

    fun onUiAttached() {
        emitState()
    }

    @SuppressLint("MissingPermission")
    @Synchronized
    fun start() {
        if (isRunning) return
        val adapter = bluetoothManager.adapter
            ?: throw BleNodeException("ble_unavailable", "Este teléfono no tiene Bluetooth.")
        if (!appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            throw BleNodeException("ble_unavailable", "Este teléfono no admite Bluetooth LE.")
        }
        if (!hasRequiredPermissions()) {
            throw BleNodeException("ble_permission_denied", "Faltan permisos de Bluetooth.")
        }
        if (!adapter.isEnabled) {
            throw BleNodeException("ble_disabled", "Activa Bluetooth para iniciar el nodo.")
        }
        val nodeAdvertiser = adapter.bluetoothLeAdvertiser
            ?: throw BleNodeException(
                "ble_advertising_unavailable",
                "Este teléfono no permite anunciarse por Bluetooth LE.",
            )
        val nodeScanner = adapter.bluetoothLeScanner
            ?: throw BleNodeException(
                "ble_scanning_unavailable",
                "Este teléfono no permite buscar dispositivos Bluetooth LE.",
            )
        val server = bluetoothManager.openGattServer(appContext, gattServerCallback)
            ?: throw BleNodeException(
                "ble_server_unavailable",
                "No se pudo abrir el servidor GATT de este teléfono.",
            )

        advertiser = nodeAdvertiser
        scanner = nodeScanner
        gattServer = server
        peers.clear()
        assemblies.clear()
        nextPeerId = 1
        isRunning = true

        val service = BluetoothGattService(
            SERVICE_UUID.uuid,
            BluetoothGattService.SERVICE_TYPE_PRIMARY,
        )
        val characteristic = BluetoothGattCharacteristic(
            MESSAGE_CHARACTERISTIC_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        service.addCharacteristic(characteristic)
        try {
            if (!server.addService(service)) {
                throw BleNodeException(
                    "ble_service_registration_failed",
                    "Android rechazó el servicio de mensajes BLE.",
                )
            }

            advertiseCallback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    emitState()
                }

                override fun onStartFailure(errorCode: Int) {
                    stop()
                    emitFailure("No se pudo iniciar el anuncio BLE (código $errorCode).")
                }
            }
            startAdvertising(nodeAdvertiser, createAdvertiseSettings())
            scanCallback = createScanCallback()
            nodeScanner.startScan(
                listOf(ScanFilter.Builder().setServiceUuid(SERVICE_UUID).build()),
                ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                    .build(),
                scanCallback,
            )
            mainHandler.post(expirePeers)
            emitState()
        } catch (error: SecurityException) {
            stop()
            throw error
        } catch (error: IllegalStateException) {
            stop()
            throw BleNodeException(
                "ble_start_failed",
                error.message ?: "Bluetooth LE no pudo iniciar.",
            )
        } catch (error: BleNodeException) {
            stop()
            throw error
        }
    }

    @SuppressLint("MissingPermission")
    @Synchronized
    fun setNodeName(name: String) {
        nodeName = truncateUtf8(name.trim(), MAX_NODE_NAME_BYTES)
            .ifEmpty { DEFAULT_NODE_NAME }
        if (isRunning) {
            advertiser?.let { nodeAdvertiser ->
                advertiseCallback?.let { callback ->
                    try {
                        nodeAdvertiser.stopAdvertising(callback)
                        advertisingRestart?.let(mainHandler::removeCallbacks)
                        val restart = Runnable {
                            synchronized(this@BleNodeController) {
                                advertisingRestart = null
                                if (!isRunning ||
                                    advertiser !== nodeAdvertiser ||
                                    advertiseCallback !== callback
                                ) {
                                    return@synchronized
                                }
                                try {
                                    startAdvertising(
                                        nodeAdvertiser,
                                        createAdvertiseSettings(),
                                    )
                                } catch (error: SecurityException) {
                                    emitFailure(
                                        error.message ?: "No se pudo actualizar el nombre BLE.",
                                    )
                                } catch (error: IllegalStateException) {
                                    emitFailure(
                                        error.message ?: "No se pudo actualizar el anuncio BLE.",
                                    )
                                }
                            }
                        }
                        advertisingRestart = restart
                        mainHandler.postDelayed(restart, ADVERTISE_RESTART_DELAY_MS)
                    } catch (error: SecurityException) {
                        emitFailure(error.message ?: "No se pudo actualizar el nombre BLE.")
                    } catch (error: IllegalStateException) {
                        emitFailure(error.message ?: "No se pudo actualizar el anuncio BLE.")
                    }
                }
            }
        }
    }

    private fun createAdvertiseSettings(): AdvertiseSettings =
        AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    setConnectable(true)
                }
            }
            .build()

    private fun cancelAdvertisingRestart() {
        advertisingRestart?.let(mainHandler::removeCallbacks)
        advertisingRestart = null
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising(
        nodeAdvertiser: BluetoothLeAdvertiser,
        settings: AdvertiseSettings,
    ) {
        val advertiseData = AdvertiseData.Builder()
            .addServiceUuid(SERVICE_UUID)
            .setIncludeDeviceName(false)
            .build()
        val scanResponse = AdvertiseData.Builder()
            .addServiceData(SERVICE_UUID, nodeName.toByteArray(StandardCharsets.UTF_8))
            .build()
        nodeAdvertiser.startAdvertising(
            settings,
            advertiseData,
            scanResponse,
            advertiseCallback,
        )
    }

    @SuppressLint("MissingPermission")
    @Synchronized
    fun stop() {
        if (!isRunning && advertiser == null && scanner == null && gattServer == null) return
        isRunning = false
        mainHandler.removeCallbacks(expirePeers)
        cancelAdvertisingRestart()
        advertiseCallback?.let { callback ->
            try {
                advertiser?.stopAdvertising(callback)
            } catch (_: IllegalStateException) {
                // Bluetooth may be disabled while the node is stopping.
            } catch (error: SecurityException) {
                emitFailure(error.message ?: "Falta permiso para detener el anuncio BLE.")
            }
        }
        scanCallback?.let { callback ->
            try {
                scanner?.stopScan(callback)
            } catch (_: IllegalStateException) {
                // Bluetooth may be disabled while the node is stopping.
            } catch (error: SecurityException) {
                emitFailure(error.message ?: "Falta permiso para detener la búsqueda BLE.")
            }
        }
        clientConnections.values.forEach { gatt ->
            try {
                gatt.disconnect()
                gatt.close()
            } catch (error: SecurityException) {
                emitFailure(error.message ?: "Falta permiso para cerrar GATT.")
            }
        }
        clientConnections.clear()
        outgoingTransfers.clear()
        pendingSends.clear()
        activeTransferAddress = null
        advertiseCallback = null
        scanCallback = null
        advertiser = null
        scanner = null
        peers.clear()
        assemblies.clear()
        try {
            gattServer?.close()
        } catch (error: SecurityException) {
            emitFailure(error.message ?: "Falta permiso para cerrar el servidor GATT.")
        }
        gattServer = null
        emitState()
    }

    @SuppressLint("MissingPermission")
    @Synchronized
    fun broadcast(payload: String, excludedAddress: String?, result: MethodChannel.Result) {
        try {
            result.success(enqueueBroadcast(payload, excludedAddress))
        } catch (error: BleNodeException) {
            result.error(error.code, error.message, null)
        }
    }

    @Synchronized
    fun broadcastForward(payload: String, excludedAddress: String?) {
        try {
            enqueueBroadcast(payload, excludedAddress)
        } catch (error: BleNodeException) {
            emitFailure(error.message)
        }
    }

    @SuppressLint("MissingPermission")
    private fun enqueueBroadcast(payload: String, excludedAddress: String?): Int {
        if (!isRunning) {
            throw BleNodeException("ble_node_inactive", "El nodo BLE ya no está activo.")
        }
        val bytes = payload.toByteArray(StandardCharsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > MAX_MESSAGE_BYTES) {
            throw BleNodeException(
                "ble_message_too_large",
                "El aviso excede el límite de $MAX_MESSAGE_BYTES bytes.",
            )
        }
        val recipients = peers.values
            .filter { it.address != excludedAddress }
            .map { it.address }
        val newRecipients = recipients.filter { address ->
            address != activeTransferAddress &&
                pendingSends.none { it.address == address }
        }
        if (newRecipients.isEmpty()) {
            return 0
        }
        if (pendingSends.size + newRecipients.size > MAX_PENDING_SENDS) {
            throw BleNodeException(
                "ble_queue_full",
                "Hay demasiadas transferencias pendientes; inténtalo de nuevo.",
            )
        }
        newRecipients.forEach { address ->
            pendingSends.add(PendingSend(address, bytes))
        }
        startNextTransfer()
        return newRecipients.size
    }

    @Synchronized
    private fun startNextTransfer() {
        if (!isRunning || activeTransferAddress != null) return
        val next = pendingSends.pollFirst() ?: return
        activeTransferAddress = next.address
        connectAndSend(next.address, next.payload)
    }

    @SuppressLint("MissingPermission")
    private fun connectAndSend(address: String, payload: ByteArray) {
        val device = try {
            bluetoothManager.adapter.getRemoteDevice(address)
        } catch (_: IllegalArgumentException) {
            completeQueuedTransfer(address, "No se pudo identificar un nodo BLE cercano.")
            return
        }
        val callback = createClientCallback(address, payload)
        try {
            val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(appContext, false, callback)
            }
            if (gatt == null) {
                completeQueuedTransfer(
                    address,
                    "No se pudo iniciar la conexión GATT con $address.",
                )
            } else {
                clientConnections[address] = gatt
                mainHandler.postDelayed({
                    if (clientConnections[address] === gatt) {
                        finishTransfer(address, gatt, "La conexión GATT agotó el tiempo.")
                    }
                }, TRANSFER_TIMEOUT_MS)
            }
        } catch (error: SecurityException) {
            completeQueuedTransfer(
                address,
                error.message ?: "Falta permiso para conectar por BLE.",
            )
        } catch (error: IllegalStateException) {
            completeQueuedTransfer(
                address,
                error.message ?: "Android no pudo iniciar la conexión GATT.",
            )
        }
    }

    @SuppressLint("MissingPermission")
    private fun createClientCallback(
        address: String,
        payload: ByteArray,
    ) = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                finishTransfer(address, gatt, "Falló la conexión GATT (código $status).")
                return
            }
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                try {
                    if (!gatt.discoverServices()) {
                        finishTransfer(address, gatt, "No se pudieron buscar servicios GATT.")
                    }
                } catch (error: SecurityException) {
                    finishTransfer(address, gatt, error.message ?: "Permiso BLE denegado.")
                } catch (error: IllegalStateException) {
                    finishTransfer(
                        address,
                        gatt,
                        error.message ?: "No se pudieron buscar servicios GATT.",
                    )
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (clientConnections[address] === gatt) {
                    finishTransfer(address, gatt, "El nodo se desconectó antes de terminar.")
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                finishTransfer(address, gatt, "No se pudieron leer los servicios GATT.")
                return
            }
            val service = gatt.getService(SERVICE_UUID.uuid)
            val characteristic = service?.getCharacteristic(MESSAGE_CHARACTERISTIC_UUID)
            if (characteristic == null) {
                finishTransfer(address, gatt, "El nodo no ofrece el servicio de mensajes.")
                return
            }
            val transfer = OutgoingTransfer(
                gatt = gatt,
                characteristic = characteristic,
                payload = payload,
            )
            outgoingTransfers[address] = transfer
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP &&
                    gatt.requestMtu(PREFERRED_MTU)
                ) {
                    return
                } else {
                    prepareAndWrite(address, transfer, DEFAULT_MTU)
                }
            } catch (error: SecurityException) {
                finishTransfer(address, gatt, error.message ?: "Permiso BLE denegado.")
            } catch (error: IllegalStateException) {
                finishTransfer(
                    address,
                    gatt,
                    error.message ?: "No se pudo negociar el MTU BLE.",
                )
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            val transfer = outgoingTransfers[address] ?: return
            prepareAndWrite(
                address,
                transfer,
                if (status == BluetoothGatt.GATT_SUCCESS) mtu else DEFAULT_MTU,
            )
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                finishTransfer(address, gatt, "Falló la escritura del aviso BLE (código $status).")
                return
            }
            val transfer = outgoingTransfers[address] ?: return
            writeNextFrame(address, transfer)
        }
    }

    private val negotiatedMtu = mutableMapOf<String, Int>()

    private fun prepareAndWrite(
        address: String,
        transfer: OutgoingTransfer,
        mtu: Int,
    ) {
        try {
            transfer.frames = createFrames(transfer.payload, mtu)
            negotiatedMtu[address] = mtu
            writeNextFrame(address, transfer)
        } catch (error: BleNodeException) {
            finishTransfer(address, transfer.gatt, error.message)
        }
    }

    @SuppressLint("MissingPermission")
    private fun writeNextFrame(
        address: String,
        transfer: OutgoingTransfer,
    ) {
        if (clientConnections[address] !== transfer.gatt) return
        if (transfer.nextFrame >= transfer.frames.size) {
            emitTransferStatus(
                "Escritura GATT completada; el nodo vecino no confirmó el guardado.",
            )
            finishTransfer(address, transfer.gatt, null)
            return
        }
        val frame = transfer.frames[transfer.nextFrame]
        val started = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                transfer.gatt.writeCharacteristic(
                    transfer.characteristic,
                    frame,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothGatt.GATT_SUCCESS
            } else {
                transfer.characteristic.writeType =
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                transfer.characteristic.value = frame
                transfer.gatt.writeCharacteristic(transfer.characteristic)
            }
        } catch (error: SecurityException) {
            finishTransfer(address, transfer.gatt, error.message ?: "Permiso BLE denegado.")
            false
        } catch (error: IllegalStateException) {
            finishTransfer(
                address,
                transfer.gatt,
                error.message ?: "Android no pudo escribir el paquete BLE.",
            )
            false
        }
        if (!started) {
            finishTransfer(address, transfer.gatt, "Android rechazó una parte del aviso BLE.")
            return
        }
        transfer.nextFrame += 1
    }

    @SuppressLint("MissingPermission")
    @Synchronized
    private fun finishTransfer(address: String, gatt: BluetoothGatt, error: String?) {
        if (clientConnections[address] !== gatt) return
        clientConnections.remove(address)
        outgoingTransfers.remove(address)
        negotiatedMtu.remove(address)
        try {
            gatt.disconnect()
            gatt.close()
        } catch (closeError: SecurityException) {
            emitFailure(closeError.message ?: "No se pudo cerrar una conexión GATT.")
        }
        if (error != null) emitFailure(error)
        if (activeTransferAddress == address) activeTransferAddress = null
        startNextTransfer()
    }

    @Synchronized
    private fun completeQueuedTransfer(address: String, error: String) {
        if (activeTransferAddress != address) return
        activeTransferAddress = null
        emitFailure(error)
        startNextTransfer()
    }

    @Synchronized
    private fun acceptFrame(address: String, frame: ByteArray): Boolean {
        if (frame.size <= FRAME_HEADER_BYTES) return false
        val buffer = ByteBuffer.wrap(frame).order(ByteOrder.BIG_ENDIAN)
        val transferId = buffer.int
        val sequence = buffer.short.toInt() and 0xffff
        val total = buffer.short.toInt() and 0xffff
        if (total == 0 || total > MAX_FRAME_COUNT || sequence >= total) return false

        val key = "$address:$transferId"
        val assembly = assemblies[key] ?: run {
            if (assemblies.size >= MAX_ASSEMBLIES) return false
            Assembly(arrayOfNulls(total)).also { assemblies[key] = it }
        }
        if (assembly.chunks.size != total) {
            assemblies.remove(key)
            return false
        }
        val chunk = ByteArray(buffer.remaining())
        buffer.get(chunk)
        val previousChunk = assembly.chunks[sequence]
        if (previousChunk == null) {
            assembly.chunks[sequence] = chunk
            assembly.receivedBytes += chunk.size
            assembly.receivedChunks += 1
        } else if (!previousChunk.contentEquals(chunk)) {
            assemblies.remove(key)
            return false
        }
        if (assembly.receivedBytes > MAX_MESSAGE_BYTES) {
            assemblies.remove(key)
            return false
        }
        if (assembly.receivedChunks == total) {
            assemblies.remove(key)
            val output = ByteArrayOutputStream(assembly.receivedBytes)
            assembly.chunks.forEach { part -> output.write(part!!) }
            val payload = output.toByteArray().toString(StandardCharsets.UTF_8)
            emitIncomingMessage(payload, address)
        }
        return true
    }

    private fun createFrames(payload: ByteArray, mtu: Int): List<ByteArray> {
        val transferId = Random.nextInt()
        val maxChunkBytes = mtu - 3 - FRAME_HEADER_BYTES
        if (maxChunkBytes <= 0) {
            throw BleNodeException(
                "ble_mtu_too_small",
                "El tamaño de paquete BLE negociado es demasiado pequeño.",
            )
        }
        val total = (payload.size + maxChunkBytes - 1) / maxChunkBytes
        if (total > MAX_FRAME_COUNT) {
            throw BleNodeException("ble_message_too_large", "El aviso no cabe en una transferencia BLE.")
        }
        return (0 until total).map { sequence ->
            val start = sequence * maxChunkBytes
            val end = minOf(start + maxChunkBytes, payload.size)
            val buffer = ByteBuffer.allocate(FRAME_HEADER_BYTES + end - start)
                .order(ByteOrder.BIG_ENDIAN)
            buffer.putInt(transferId)
            buffer.putShort(sequence.toShort())
            buffer.putShort(total.toShort())
            buffer.put(payload, start, end - start)
            buffer.array()
        }
    }

    private fun hasRequiredPermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED &&
                appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) ==
                PackageManager.PERMISSION_GRANTED &&
                appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
        }
        return appContext.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }

    @SuppressLint("MissingPermission")
    private fun createScanCallback() = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            synchronized(this@BleNodeController) {
                if (!isRunning) return
                val deviceAddress = result.device.address ?: return
                val existingPeer = peers[deviceAddress]
                val advertisedName = result.scanRecord
                    ?.getServiceData(SERVICE_UUID)
                    ?.toString(StandardCharsets.UTF_8)
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                peers[deviceAddress] = Peer(
                    id = existingPeer?.id ?: "Nodo ${nextPeerId++}",
                    name = advertisedName ?: existingPeer?.name ?: "Enlace nodo",
                    address = deviceAddress,
                    rssi = result.rssi,
                    lastSeen = System.currentTimeMillis(),
                )
            }
            emitState()
        }

        @Synchronized
        override fun onScanFailed(errorCode: Int) {
            stop()
            emitFailure("Falló la búsqueda Bluetooth LE (código $errorCode).")
        }
    }

    private fun emitState() = emitEvent()

    private fun emitIncomingMessage(payload: String, sourceAddress: String) {
        emitEvent(mapOf("payload" to payload, "sourceAddress" to sourceAddress))
    }

    private fun emitFailure(message: String) {
        emitEvent(mapOf("error" to message))
    }

    private fun emitTransferStatus(message: String) {
        emitEvent(mapOf("transferStatus" to message))
    }

    private fun emitEvent(extra: Map<String, Any?> = emptyMap()) {
        val snapshot = synchronized(this) {
            mapOf(
                "active" to isRunning,
                "peers" to peers.values.map { peer ->
                    mapOf(
                        "id" to peer.id,
                        "name" to peer.name,
                        "rssi" to peer.rssi,
                    )
                },
            ) + extra
        }
        mainHandler.post { publishEvent(snapshot) }
    }

    companion object {
        internal const val NODE_IDENTITY_PREFERENCES = "enlace_node_identity"
        internal const val NODE_NAME_KEY = "display_name"
        private const val DEFAULT_NODE_NAME = "Enlace nodo"
        internal const val MAX_NODE_NAME_BYTES = 12
        private const val ADVERTISE_RESTART_DELAY_MS = 300L
        private const val PEER_TIMEOUT_MS = 15_000L
        private const val PEER_REFRESH_MS = 5_000L
        private const val ASSEMBLY_TIMEOUT_MS = 30_000L
        private const val TRANSFER_TIMEOUT_MS = 45_000L
        private const val MAX_MESSAGE_BYTES = 6_144
        private const val FRAME_HEADER_BYTES = 8
        private const val MAX_FRAME_COUNT = 512
        private const val MAX_ASSEMBLIES = 8
        private const val MAX_PENDING_SENDS = 64
        private const val PREFERRED_MTU = 247
        private const val DEFAULT_MTU = 23
        private val SERVICE_UUID = ParcelUuid(
            UUID.fromString("7a1b4b20-6e2d-4f41-9d61-454e4c414345"),
        )
        private val MESSAGE_CHARACTERISTIC_UUID =
            UUID.fromString("7a1b4b21-6e2d-4f41-9d61-454e4c414345")

        private fun truncateUtf8(value: String, maxBytes: Int): String {
            val result = StringBuilder()
            var usedBytes = 0
            var index = 0
            while (index < value.length) {
                val codePoint = value.codePointAt(index)
                val character = String(Character.toChars(codePoint))
                val byteCount = character.toByteArray(StandardCharsets.UTF_8).size
                if (usedBytes + byteCount > maxBytes) break
                result.append(character)
                usedBytes += byteCount
                index += Character.charCount(codePoint)
            }
            return result.toString()
        }
    }
}
