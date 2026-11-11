package ch.micheljung.eos_transfer

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

class RawFileSaver(private val context: Context) {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "saveRaw") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("raw")
            if (path == null) {
                result.error(INVALID_ARGUMENTS, "Missing raw file path", null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val savedName = save(File(path))
                    mainThread.post { result.success(savedName) }
                } catch (e: Exception) {
                    mainThread.post { result.error(SAVE_FAILED, e.message, null) }
                }
            }
        }
    }

    private fun save(source: File): String {
        if (!source.isFile) throw IOException("Missing source file ${source.path}")
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveToMediaStore(source)
        } else {
            saveToPublicDirectory(source)
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun saveToMediaStore(source: File): String {
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val name = uniqueName(source.name) { existsInMediaStore(collection, it) }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, RAW_MIME_TYPE)
            put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IOException("MediaStore refused ${source.name}")
        try {
            val output = resolver.openOutputStream(uri)
                ?: throw IOException("Cannot write ${source.name}")
            output.use { sink -> source.inputStream().use { it.copyTo(sink) } }
            val published = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, published, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return displayName(uri) ?: name
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun existsInMediaStore(collection: Uri, name: String): Boolean {
        val selection =
            "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME}=?"
        context.contentResolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            selection,
            arrayOf(RELATIVE_PATH, name),
            null,
        ).use { cursor -> return cursor != null && cursor.count > 0 }
    }

    private fun displayName(uri: Uri): String? =
        context.contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

    @Suppress("DEPRECATION")
    private fun saveToPublicDirectory(source: File): String {
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            ALBUM,
        )
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw IOException("Cannot create ${directory.path}")
        }
        val name = uniqueName(source.name) { File(directory, it).exists() }
        val target = source.copyTo(File(directory, name), overwrite = false)
        MediaScannerConnection.scanFile(context, arrayOf(target.path), null, null)
        return name
    }

    private fun uniqueName(name: String, exists: (String) -> Boolean): String {
        if (!exists(name)) return name
        val stem = name.substringBeforeLast('.')
        val extension = name.substringAfterLast('.', "")
        val suffix = if (extension.isEmpty()) "" else ".$extension"
        return generateSequence(1) { it + 1 }
            .map { "$stem-$it$suffix" }
            .first { !exists(it) }
    }

    private companion object {
        const val CHANNEL = "ch.micheljung.eos_transfer/photos"
        const val ALBUM = "EOS R"
        const val RELATIVE_PATH = "Download/EOS R/"
        const val RAW_MIME_TYPE = "image/x-canon-cr3"
        const val INVALID_ARGUMENTS = "invalid_arguments"
        const val SAVE_FAILED = "save_failed"
    }
}
