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
        if (messages.any { it.optString("id") == id }) return null

        val received = JSONObject(message.toString())
        received.put("received", true)
        val forwarded = if (remainingHops > 1) {
            JSONObject(received.toString()).put("remainingHops", remainingHops - 1)
        } else {
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
        return StoredBleMessage(
            forwardedPayload = forwarded?.toString(),
            text = text,
        )
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
    fun clearMessages() {
        val committed = preferences.edit().remove(MESSAGES_KEY).commit()
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
        private const val TIMESTAMP_PATTERN = "yyyy-MM-dd'T'HH:mm:ss"
        private const val MAX_MESSAGE_BYTES = 6_144
        private const val MAX_TEXT_LENGTH = 280
        private const val MAX_HOPS = 8
        private const val MAX_STORED_MESSAGES = 500
        private const val MAX_MESSAGE_AGE_MS = 24 * 60 * 60 * 1000L
        private const val MAX_FUTURE_SKEW_MS = 5 * 60 * 1000L
        private val MESSAGE_ID = Regex("^[a-f0-9]{32}$")
    }
}
