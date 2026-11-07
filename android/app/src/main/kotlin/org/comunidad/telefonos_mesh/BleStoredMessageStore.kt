package org.comunidad.telefonos_mesh

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

internal data class StoredBleMessage(
    val forwardedPayload: String?,
    val text: String,
)

internal class BleStoredMessageStore(context: Context) {
    private val preferences: SharedPreferences = context.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    @Synchronized
    @Throws(JSONException::class)
    fun accept(payload: String): StoredBleMessage? {
        if (payload.toByteArray(Charsets.UTF_8).size > MAX_MESSAGE_BYTES) {
            throw JSONException("El aviso recibido excede el tamaño permitido.")
        }
        val message = JSONObject(payload)
        val id = message.optString("id")
        val text = message.optString("text")
        val priority = message.optString("priority")
        val remainingHops = message.optInt("remainingHops", -1)
        val createdAt = parseTimestamp(message.optString("createdAt"))
        val expiresAt = parseTimestamp(message.optString("expiresAt"))
        val now = System.currentTimeMillis()

        if (!MESSAGE_ID.matches(id) ||
            text.isBlank() ||
            text.length > MAX_TEXT_LENGTH ||
            (priority != "normal" && priority != "urgent") ||
            remainingHops !in 0..MAX_HOPS ||
            createdAt == null ||
            expiresAt == null ||
            expiresAt <= now ||
            expiresAt <= createdAt ||
            expiresAt - createdAt > MAX_MESSAGE_AGE_MS ||
            createdAt > now + MAX_FUTURE_SKEW_MS
        ) {
            throw JSONException("El aviso recibido no cumple el formato permitido.")
        }

        val messages = readMessages()
        messages.firstOrNull { it.optString("id") == id }?.let { existing ->
            if (existing.optBoolean("forwardable", false)) {
                enqueueOutbound(existing.toString())
            }
            return null
        }

        val received = JSONObject(message.toString())
        received.put("received", true)
        val forwarded = if (remainingHops > 1) {
            JSONObject(received.toString())
                .put("remainingHops", remainingHops - 1)
                .put("forwardable", true)
        } else {
            received.put("forwardable", false)
            null
        }
        val stored = forwarded ?: received
        val retained = messages
            .filter { parseTimestamp(it.optString("expiresAt"))?.let { expiry -> expiry > now } == true }
            .take(MAX_STORED_MESSAGES - 1)
        val updated = JSONArray().put(stored)
        retained.forEach(updated::put)
        val committed = preferences.edit()
            .putString(MESSAGES_KEY, updated.toString())
            .commit()
        if (!committed) {
            throw IllegalStateException("No se pudo guardar el aviso recibido.")
        }
        if (forwarded != null) enqueueOutbound(forwarded.toString())
        return StoredBleMessage(
            forwardedPayload = forwarded?.toString(),
            text = text,
        )
    }

    @Synchronized
    @Throws(JSONException::class)
    fun enqueueOutbound(payload: String) {
        if (payload.toByteArray(Charsets.UTF_8).size > MAX_MESSAGE_BYTES) {
            throw JSONException("El aviso excede el tamaño permitido.")
        }
        val message = JSONObject(payload)
        val id = message.optString("id")
        val text = message.optString("text")
        val priority = message.optString("priority")
        val createdAt = parseTimestamp(message.optString("createdAt"))
        val expiry = parseTimestamp(message.optString("expiresAt"))
        val hops = message.optInt("remainingHops", -1)
        val now = System.currentTimeMillis()
        if (!MESSAGE_ID.matches(id) || text.isBlank() || text.length > MAX_TEXT_LENGTH ||
            (priority != "normal" && priority != "urgent") ||
            createdAt == null || expiry == null ||
            expiry <= now || expiry <= createdAt ||
            expiry - createdAt > MAX_MESSAGE_AGE_MS ||
            createdAt > now + MAX_FUTURE_SKEW_MS ||
            hops !in 1..MAX_HOPS
        ) {
            throw JSONException("El aviso pendiente no cumple el formato permitido.")
        }
        val records = readOutbox().filter {
            (parseTimestamp(it.optString("expiresAt")) ?: 0L) > System.currentTimeMillis()
        }
        if (records.any { it.optString("id") == id }) return
        val retained = records.takeLast(MAX_OUTBOX_MESSAGES - 1)
        val updated = JSONArray()
        retained.forEach(updated::put)
        updated.put(
            JSONObject()
                .put("id", id)
                .put("payload", payload)
                .put("expiresAt", message.optString("expiresAt"))
                .put("deliveredTo", JSONArray()),
        )
        commitOutbox(updated)
    }

    @Synchronized
    @Throws(JSONException::class)
    fun pendingForPeer(address: String): List<String> {
        val now = System.currentTimeMillis()
        return readOutbox()
            .filter { (parseTimestamp(it.optString("expiresAt")) ?: 0L) > now }
            .filterNot { record ->
                val peers = record.optJSONArray("deliveredTo") ?: JSONArray()
                (0 until peers.length()).any { peers.optString(it) == address }
            }
            .map { it.optString("payload") }
    }

    @Synchronized
    @Throws(JSONException::class)
    fun markDelivered(payload: String, address: String) {
        val id = JSONObject(payload).optString("id")
        if (!MESSAGE_ID.matches(id)) return
        val updated = JSONArray()
        readOutbox().forEach { record ->
            if (record.optString("id") == id) {
                val peers = record.optJSONArray("deliveredTo") ?: JSONArray()
                if ((0 until peers.length()).none { peers.optString(it) == address }) {
                    peers.put(address)
                }
                record.put("deliveredTo", peers)
            }
            updated.put(record)
        }
        commitOutbox(updated)
    }

    @Synchronized
    @Throws(JSONException::class)
    fun loadPayloads(): List<String> {
        val now = System.currentTimeMillis()
        return readMessages()
            .filter { parseTimestamp(it.optString("expiresAt"))?.let { expiry -> expiry > now } == true }
            .map(JSONObject::toString)
    }

    @Synchronized
    @Throws(JSONException::class)
    fun forwardingPayload(id: String): String? {
        if (!MESSAGE_ID.matches(id)) return null
        return readMessages().firstOrNull { it.optString("id") == id }
            ?.takeIf {
                it.optBoolean("forwardable", false) &&
                    (parseTimestamp(it.optString("expiresAt")) ?: 0L) > System.currentTimeMillis()
            }
            ?.toString()
    }

    @Synchronized
    fun clearMessages() {
        val committed = preferences.edit()
            .remove(MESSAGES_KEY)
            .remove(OUTBOX_KEY)
            .commit()
        if (!committed) {
            throw IllegalStateException("No se pudo borrar el historial de mensajes.")
        }
    }

    private fun readMessages(): List<JSONObject> {
        val encoded = preferences.getString(MESSAGES_KEY, null) ?: return emptyList()
        val json = JSONArray(encoded)
        return (0 until json.length()).map { index ->
            json.optJSONObject(index)
                ?: throw JSONException("La lista de avisos guardados está dañada.")
        }
    }

    private fun readOutbox(): List<JSONObject> {
        val encoded = preferences.getString(OUTBOX_KEY, null) ?: return emptyList()
        val json = JSONArray(encoded)
        return (0 until json.length()).map { index ->
            json.optJSONObject(index)
                ?: throw JSONException("La cola de avisos está dañada.")
        }
    }

    private fun commitOutbox(records: JSONArray) {
        if (!preferences.edit().putString(OUTBOX_KEY, records.toString()).commit()) {
            throw IllegalStateException("No se pudo guardar la cola de reenvío BLE.")
        }
    }

    private fun parseTimestamp(value: String): Long? {
        if (value.length < TIMESTAMP_PATTERN.length) return null
        val formatter = SimpleDateFormat(TIMESTAMP_PATTERN, Locale.US).apply {
            isLenient = false
            if (value.endsWith("Z")) timeZone = TimeZone.getTimeZone("UTC")
        }
        val position = ParsePosition(0)
        val parsed: Date = formatter.parse(value.take(TIMESTAMP_PATTERN.length), position)
            ?: return null
        return parsed.time
    }

    companion object {
        private const val PREFERENCES_NAME = "enlace_ble_messages"
        private const val MESSAGES_KEY = "messages"
        private const val OUTBOX_KEY = "outbox"
        private const val TIMESTAMP_PATTERN = "yyyy-MM-dd'T'HH:mm:ss"
        private const val MAX_MESSAGE_BYTES = 6_144
        private const val MAX_TEXT_LENGTH = 280
        private const val MAX_HOPS = 8
        private const val MAX_STORED_MESSAGES = 500
        private const val MAX_OUTBOX_MESSAGES = 500
        private const val MAX_MESSAGE_AGE_MS = 24 * 60 * 60 * 1000L
        private const val MAX_FUTURE_SKEW_MS = 5 * 60 * 1000L
        private val MESSAGE_ID = Regex("^[a-f0-9]{32}$")
    }
}
