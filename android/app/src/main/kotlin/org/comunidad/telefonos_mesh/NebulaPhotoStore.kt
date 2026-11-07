package org.comunidad.telefonos_mesh

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

internal data class NebulaPhoto(
    val id: String,
    val file: File,
    val bytes: Long,
    val mimeType: String,
    val sha256: String,
    val expiresAt: Long,
    val reportPayload: String?,
)

internal data class PhotoReportRelay(
    val accepted: Boolean,
    val forwardPayload: String?,
)

internal class NebulaPhotoStore(private val context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val directory = File(context.filesDir, PHOTO_DIRECTORY).apply { mkdirs() }

    @Synchronized
    @Throws(Exception::class)
    fun importPhoto(resolver: ContentResolver, uri: Uri): NebulaPhoto {
        prune()
        val sourceMimeType = resolver.getType(uri)?.lowercase()
            ?: throw IllegalArgumentException("No se pudo identificar el formato de la foto.")
        if (sourceMimeType !in ALLOWED_MIME_TYPES) {
            throw IllegalArgumentException("Solo se admiten imágenes JPEG, PNG o WebP.")
        }
        val id = UUID.randomUUID().toString().replace("-", "")
        val source = File(directory, "$id.source")
        val target = File(directory, "$id.jpg")
        try {
            val input = resolver.openInputStream(uri)
                ?: throw IllegalArgumentException("No se pudo abrir la foto seleccionada.")
            input.use { stream ->
                BufferedOutputStream(FileOutputStream(target)).use { output ->
                    val buffer = ByteArray(32 * 1024)
                    var total = 0L
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_SOURCE_PHOTO_BYTES) {
                            throw IllegalArgumentException(
                                "La foto original supera el límite de 20 MB.",
                            )
                        }
                        output.write(buffer, 0, count)
                    }
                }
            }
            if (!target.renameTo(source)) {
                throw IllegalStateException("No se pudo preparar la foto para comprimir.")
            }
            if (source.length() == 0L) throw IllegalArgumentException("La foto está vacía.")

            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(source.absolutePath, bounds)
            validateImageBounds(bounds, sourceMimeType)
            val orientation = ExifInterface(source).let {
                PhotoOrientation(it.rotationDegrees, it.isFlipped)
            }
            val bitmap = decodeForTransfer(source, bounds)
            val transferBitmap = orientAndScale(bitmap, orientation)
            if (transferBitmap !== bitmap) bitmap.recycle()
            val compressed = try {
                BufferedOutputStream(FileOutputStream(target)).use { output ->
                    if (!transferBitmap.compress(
                            Bitmap.CompressFormat.JPEG,
                            JPEG_QUALITY,
                            output,
                        )
                    ) {
                        throw IllegalStateException("No se pudo comprimir la foto.")
                    }
                }
                target.length()
            } finally {
                transferBitmap.recycle()
            }
            if (compressed !in 1..MAX_PHOTO_BYTES) {
                throw IllegalArgumentException(
                    "La foto comprimida supera el límite de 5 MB.",
                )
            }
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(target).use { inputStream ->
                val buffer = ByteArray(32 * 1024)
                while (true) {
                    val count = inputStream.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            if (!source.delete()) {
                throw IllegalStateException("No se pudo limpiar la foto original temporal.")
            }
            ensureCapacity(id, compressed)
            val photo = NebulaPhoto(
                id = id,
                file = target,
                bytes = compressed,
                mimeType = JPEG_MIME_TYPE,
                sha256 = digest.digest().toHex(),
                expiresAt = System.currentTimeMillis() + PHOTO_TTL_MS,
                reportPayload = null,
            )
            save(photo, shareable = false)
            return photo
        } catch (error: Exception) {
            source.delete()
            target.delete()
            throw error
        }
    }

    @Synchronized
    @Throws(JSONException::class)
    fun enqueue(id: String, reportPayload: String): NebulaPhoto {
        val photo = find(id) ?: throw IllegalArgumentException("No se encontró la foto.")
        if (!photo.file.isFile) throw IllegalStateException("El archivo de la foto ya no está disponible.")
        val linkedReport = validateReportPayload(id, reportPayload)
        save(
            photo.copy(
                expiresAt = System.currentTimeMillis() + PHOTO_TTL_MS,
                reportPayload = linkedReport,
            ),
            shareable = true,
        )
        return find(id) ?: throw IllegalStateException("No se pudo poner la foto en cola.")
    }

    @Synchronized
    fun find(id: String): NebulaPhoto? {
        if (!PHOTO_ID.matches(id)) return null
        val record = readRecords().firstOrNull { it.optString("id") == id } ?: return null
        val expiry = record.optLong("expiresAt", 0L)
        val mime = record.optString("mimeType")
        val bytes = record.optLong("bytes", 0L)
        val digest = record.optString("sha256")
        val reportPayload = record.optString("reportPayload").takeIf { it.isNotEmpty() }
        val extension = MIME_EXTENSIONS[mime] ?: return null
        val file = File(directory, "$id.$extension")
        if (expiry <= System.currentTimeMillis() || bytes !in 1..MAX_PHOTO_BYTES ||
            !SHA256.matches(digest) || !file.isFile || file.length() != bytes
        ) return null
        val validReport = if (record.optBoolean("shareable", false)) {
            try {
                validateReportPayload(id, reportPayload ?: return null)
            } catch (_: Exception) {
                return null
            }
        } else {
            reportPayload
        }
        return NebulaPhoto(id, file, bytes, mime, digest, expiry, validReport)
    }

    @Synchronized
    fun photoPath(id: String): String? = find(id)?.file?.absolutePath

    @Synchronized
    fun clearAll() {
        directory.listFiles()?.forEach { file ->
            if (!file.delete()) {
                throw IllegalStateException("No se pudo borrar un archivo de foto del historial.")
            }
        }
        if (!preferences.edit().remove(PHOTOS_KEY).commit()) {
            throw IllegalStateException("No se pudo borrar la cola de fotos.")
        }
    }

    @Synchronized
    fun shareablePhotos(): List<NebulaPhoto> {
        prune()
        return readRecords()
            .filter { it.optBoolean("shareable", false) }
            .mapNotNull { find(it.optString("id"))?.takeIf { photo -> photo.reportPayload != null } }
            .take(MAX_PHOTOS_PER_SYNC)
    }

    @Synchronized
    @Throws(Exception::class)
    fun acceptReceived(
        id: String,
        mimeType: String,
        bytes: Long,
        sha256: String,
        expiresAt: Long,
        reportPayload: String,
        forwardPayload: String?,
        input: java.io.InputStream,
    ): NebulaPhoto {
        if (!PHOTO_ID.matches(id) || mimeType !in ALLOWED_MIME_TYPES ||
            bytes !in 1..MAX_PHOTO_BYTES || expiresAt <= System.currentTimeMillis() ||
            expiresAt - System.currentTimeMillis() > PHOTO_TTL_MS ||
            !SHA256.matches(sha256)
        ) {
            throw IllegalArgumentException("Los metadatos de la foto no son válidos.")
        }
        val receivedReport = validateReportPayload(id, reportPayload)
        val relayReport = forwardPayload?.let { validateReportPayload(id, it) }
        prune()
        ensureCapacity(id, bytes)
        val target = File(directory, "$id.${MIME_EXTENSIONS.getValue(mimeType)}")
        val digest = MessageDigest.getInstance("SHA-256")
        var received = 0L
        try {
            BufferedOutputStream(FileOutputStream(target)).use { output ->
                val buffer = ByteArray(32 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    received += count
                    if (received > bytes || received > MAX_PHOTO_BYTES) {
                        throw IllegalArgumentException("La foto recibida excede el tamaño anunciado.")
                    }
                    digest.update(buffer, 0, count)
                    output.write(buffer, 0, count)
                }
            }
            if (received != bytes || digest.digest().toHex() != sha256) {
                throw IllegalArgumentException("La foto recibida está incompleta o dañada.")
            }
            validateImage(target, mimeType)
            val photo = NebulaPhoto(
                id,
                target,
                bytes,
                mimeType,
                sha256,
                expiresAt,
                relayReport ?: receivedReport,
            )
            save(photo, shareable = relayReport != null)
            return photo
        } catch (error: Exception) {
            target.delete()
            throw error
        }
    }

    @Synchronized
    fun prune() {
        val now = System.currentTimeMillis()
        val records = readRecords()
        val retained = JSONArray()
        val retainedIds = mutableSetOf<String>()
        records.forEach { record ->
            val id = record.optString("id")
            val expiry = record.optLong("expiresAt", 0L)
            val mime = record.optString("mimeType")
            val file = MIME_EXTENSIONS[mime]?.let { File(directory, "$id.$it") }
            if (expiry > now && file?.isFile == true && file.length() == record.optLong("bytes")) {
                retained.put(record)
                retainedIds += id
            } else {
                file?.delete()
            }
        }
        directory.listFiles()?.forEach { file ->
            val id = file.nameWithoutExtension
            if (PHOTO_ID.matches(id) && id !in retainedIds) file.delete()
        }
        commit(retained)
    }

    private fun save(photo: NebulaPhoto, shareable: Boolean) {
        val records = readRecords()
        val updated = JSONArray()
        records.filterNot { it.optString("id") == photo.id }.forEach(updated::put)
        updated.put(
            JSONObject()
                .put("id", photo.id)
                .put("bytes", photo.bytes)
                .put("mimeType", photo.mimeType)
                .put("sha256", photo.sha256)
                .put("expiresAt", photo.expiresAt)
                .put("reportPayload", photo.reportPayload)
                .put("shareable", shareable),
        )
        commit(updated)
    }

    private fun ensureCapacity(id: String, bytes: Long) {
        val existing = find(id)
        val records = readRecords()
            .filterNot { it.optString("id") == id }
            .filter { it.optLong("expiresAt", 0L) > System.currentTimeMillis() }
        val storedBytes = records.sumOf { it.optLong("bytes", 0L) }
        if (records.size >= MAX_STORED_PHOTOS ||
            storedBytes + bytes > MAX_STORED_PHOTO_BYTES
        ) {
            if (existing == null) {
                throw IllegalStateException(
                    "La cola de fotos alcanzó el límite de 10 imágenes o 50 MB. "
                        + "Espera a que venzan y vuelve a intentarlo.",
                )
            }
        }
    }

    private fun readRecords(): List<JSONObject> {
        val encoded = preferences.getString(PHOTOS_KEY, null) ?: return emptyList()
        val json = JSONArray(encoded)
        return (0 until json.length()).mapNotNull(json::optJSONObject)
    }

    private fun commit(records: JSONArray) {
        if (!preferences.edit().putString(PHOTOS_KEY, records.toString()).commit()) {
            throw IllegalStateException("No se pudo guardar la cola de fotos.")
        }
    }

    private fun validateImageBounds(
        options: BitmapFactory.Options,
        expectedMimeType: String,
    ) {
        val pixels = options.outWidth.toLong() * options.outHeight.toLong()
        if (options.outMimeType != expectedMimeType ||
            options.outWidth !in 1..MAX_IMAGE_DIMENSION ||
            options.outHeight !in 1..MAX_IMAGE_DIMENSION ||
            pixels > MAX_IMAGE_PIXELS
        ) {
            throw IllegalArgumentException(
                "La foto está dañada, no coincide con su formato o tiene dimensiones excesivas.",
            )
        }
    }

    private fun validateImage(file: File, expectedMimeType: String) {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, options)
        validateImageBounds(options, expectedMimeType)
    }

    private fun decodeForTransfer(
        source: File,
        bounds: BitmapFactory.Options,
    ): Bitmap {
        var sampleSize = 1
        while (
            maxOf(bounds.outWidth, bounds.outHeight) / (sampleSize * 2) >=
                MAX_TRANSFER_IMAGE_DIMENSION
        ) {
            sampleSize *= 2
        }
        return BitmapFactory.decodeFile(
            source.absolutePath,
            BitmapFactory.Options().apply { inSampleSize = sampleSize },
        ) ?: throw IllegalArgumentException("La imagen no se pudo decodificar.")
    }

    private fun orientAndScale(bitmap: Bitmap, orientation: PhotoOrientation): Bitmap {
        val scale = minOf(
            1f,
            MAX_TRANSFER_IMAGE_DIMENSION.toFloat() /
                maxOf(bitmap.width, bitmap.height),
        )
        val matrix = Matrix().apply {
            if (scale < 1f) postScale(scale, scale)
            if (orientation.flipped) postScale(-1f, 1f)
            if (orientation.rotationDegrees != 0) postRotate(orientation.rotationDegrees.toFloat())
        }
        if (matrix.isIdentity) return bitmap
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    private data class PhotoOrientation(
        val rotationDegrees: Int,
        val flipped: Boolean,
    )

    private fun validateReportPayload(id: String, payload: String): String {
        if (payload.toByteArray(Charsets.UTF_8).size > MAX_REPORT_BYTES) {
            throw IllegalArgumentException("El aviso asociado a la foto excede el tamaño permitido.")
        }
        val report = JSONObject(payload)
        if (report.optString("photoId") != id ||
            !MESSAGE_ID.matches(report.optString("id")) ||
            report.optString("text").isBlank() ||
            report.optString("priority") != "urgent" ||
            report.optInt("remainingHops", -1) !in 0..MAX_HOPS
        ) {
            throw IllegalArgumentException("El reporte asociado a la foto no es válido.")
        }
        return report.toString()
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02x".format(it.toInt() and 0xff) }

    companion object {
        const val MAX_PHOTO_BYTES = 5L * 1024 * 1024
        private const val MAX_SOURCE_PHOTO_BYTES = 20L * 1024 * 1024
        private const val MAX_TRANSFER_IMAGE_DIMENSION = 1_600
        private const val JPEG_QUALITY = 82
        private const val JPEG_MIME_TYPE = "image/jpeg"
        private const val PREFERENCES_NAME = "nebula_wifi_direct_photos"
        private const val PHOTOS_KEY = "photos"
        private const val PHOTO_DIRECTORY = "nebula-photos"
        private const val MAX_PHOTOS_PER_SYNC = 20
        private const val MAX_STORED_PHOTOS = 10
        private const val MAX_STORED_PHOTO_BYTES = 50L * 1024 * 1024
        private const val MAX_IMAGE_DIMENSION = 8_192
        private const val MAX_IMAGE_PIXELS = 24L * 1024 * 1024
        private const val MAX_REPORT_BYTES = 6_144
        private const val MAX_HOPS = 8
        private const val PHOTO_TTL_MS = 24 * 60 * 60 * 1000L
        private val PHOTO_ID = Regex("^[a-f0-9]{32}$")
        private val SHA256 = Regex("^[a-f0-9]{64}$")
        private val MESSAGE_ID = Regex("^[a-f0-9]{32}$")
        private val ALLOWED_MIME_TYPES = setOf("image/jpeg", "image/png", "image/webp")
        private val MIME_EXTENSIONS = mapOf(
            "image/jpeg" to "jpg",
            "image/png" to "png",
            "image/webp" to "webp",
        )
    }
}
