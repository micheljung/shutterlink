package ch.micheljung.shutterlink

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Saves into the gallery in two steps (reserve, then write and publish), so a
 * save interrupted by a crash can be resumed or discarded. Before Android 10
 * a reference is the target file path; an empty file marks a reservation.
 */
class MediaSaver(private val context: Context) {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())
    private val resolver get() = context.contentResolver
    private var pendingDeleteRequest: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, PHOTOS_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "saveRaw") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("raw")
                ?: return@setMethodCallHandler invalidArguments(result)
            runAsync(result) { saveRaw(File(path)) }
        }
        MethodChannel(messenger, MEDIA_CHANNEL).setMethodCallHandler(::handle)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int) {
        if (requestCode != DELETE_REQUEST_CODE) return
        pendingDeleteRequest?.success(resultCode == Activity.RESULT_OK)
        pendingDeleteRequest = null
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")
        val kind = call.argument<String>("kind")?.let { Kind.valueOf(it.uppercase()) }
        when (call.method) {
            "beginSave" -> {
                val name = call.argument<String>("name")
                if (name == null || kind == null) return invalidArguments(result)
                runAsync(result) { beginSave(name, kind) }
            }
            "finishSave" -> {
                val path = call.argument<String>("path")
                if (uri == null || path == null || kind == null) return invalidArguments(result)
                runAsync(result) { finishSave(uri, File(path)) }
            }
            "queryMedia" -> {
                if (uri == null) return invalidArguments(result)
                runAsync(result) { query(uri) }
            }
            "deleteMedia" -> {
                if (uri == null) return invalidArguments(result)
                runAsync(result) { delete(uri) }
            }
            "requestDelete" -> {
                val uris = call.argument<List<String>>("uris")
                    ?: return invalidArguments(result)
                requestDelete(uris, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun runAsync(result: MethodChannel.Result, action: () -> Any?) {
        executor.execute {
            try {
                val value = action()
                mainThread.post { result.success(value) }
            } catch (e: OwnershipLostException) {
                mainThread.post { result.error(OWNERSHIP_LOST, e.message, null) }
            } catch (e: Exception) {
                mainThread.post { result.error(SAVE_FAILED, e.message, null) }
            }
        }
    }

    private fun invalidArguments(result: MethodChannel.Result) =
        result.error(INVALID_ARGUMENTS, "Missing arguments", null)

    private fun saveRaw(source: File): String {
        if (!source.isFile) throw IOException("Missing source file ${source.path}")
        val ref = beginSave(source.name, Kind.RAW)
        try {
            finishSave(ref, source)
        } catch (e: Exception) {
            runCatching { delete(ref) }
            throw e
        }
        return if (isContentRef(ref)) displayName(Uri.parse(ref)) ?: source.name else File(ref).name
    }

    private fun beginSave(name: String, kind: Kind): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            insertPending(name, kind)
        } else {
            reserveFile(name, kind)
        }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun insertPending(name: String, kind: Kind): String {
        val collection = kind.collection()
        val unique = uniqueName(name) { existsInMediaStore(collection, kind, it) }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, unique)
            put(MediaStore.MediaColumns.MIME_TYPE, kind.mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, kind.relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        return resolver.insert(collection, values)?.toString()
            ?: throw IOException("MediaStore refused $name")
    }

    @Suppress("DEPRECATION")
    private fun reserveFile(name: String, kind: Kind): String {
        val directory = File(Environment.getExternalStoragePublicDirectory(kind.directory), ALBUM)
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw IOException("Cannot create ${directory.path}")
        }
        val unique = uniqueName(name) { File(directory, it).exists() }
        val target = File(directory, unique)
        if (!target.createNewFile()) throw IOException("Cannot reserve ${target.path}")
        return target.path
    }

    private fun finishSave(ref: String, source: File): String {
        if (!source.isFile) throw IOException("Missing source file ${source.path}")
        if (isContentRef(ref)) {
            val uri = Uri.parse(ref)
            val output = resolver.openOutputStream(uri, WRITE_TRUNCATE)
                ?: throw IOException("Cannot write $ref")
            output.use { sink -> source.inputStream().use { it.copyTo(sink) } }
            val published = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, published, null, null)
        } else {
            val target = File(ref)
            val partial = File(target.parentFile, ".${target.name}$PARTIAL_SUFFIX")
            source.copyTo(partial, overwrite = true)
            if (!partial.renameTo(target)) {
                partial.delete()
                throw IOException("Cannot publish ${target.path}")
            }
            MediaScannerConnection.scanFile(context, arrayOf(target.path), null, null)
        }
        return ref
    }

    private fun query(ref: String): String {
        if (!isContentRef(ref)) {
            val file = File(ref)
            return when {
                !file.isFile -> MISSING
                file.length() == 0L -> PENDING
                else -> PUBLISHED
            }
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return MISSING
        val projection = arrayOf(MediaStore.MediaColumns.IS_PENDING)
        val uri = Uri.parse(ref)
        val cursor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val args = Bundle().apply {
                putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
            }
            resolver.query(uri, projection, args, null)
        } else {
            @Suppress("DEPRECATION")
            resolver.query(MediaStore.setIncludePending(uri), projection, null, null, null)
        }
        return cursor?.use {
            when {
                !it.moveToFirst() -> MISSING
                it.getInt(0) == 1 -> PENDING
                else -> PUBLISHED
            }
        } ?: MISSING
    }

    private fun delete(ref: String): Any? {
        if (!isContentRef(ref)) {
            val file = File(ref)
            if (file.exists() && !file.delete()) throw IOException("Cannot delete $ref")
            MediaScannerConnection.scanFile(context, arrayOf(ref), null, null)
            return null
        }
        try {
            resolver.delete(Uri.parse(ref), null, null)
        } catch (e: SecurityException) {
            throw OwnershipLostException(ref)
        }
        return null
    }

    private fun requestDelete(refs: List<String>, result: MethodChannel.Result) {
        val activity = AppEngine.activity
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || activity == null) {
            runAsync(result) { refs.all { runCatching { delete(it) }.isSuccess } }
            return
        }
        if (pendingDeleteRequest != null) {
            result.error(BUSY, "A delete request is already shown", null)
            return
        }
        try {
            val request = MediaStore.createDeleteRequest(resolver, refs.map(Uri::parse))
            pendingDeleteRequest = result
            activity.startIntentSenderForResult(
                request.intentSender,
                DELETE_REQUEST_CODE,
                null,
                0,
                0,
                0,
            )
        } catch (e: Exception) {
            pendingDeleteRequest = null
            result.error(SAVE_FAILED, e.message, null)
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun existsInMediaStore(collection: Uri, kind: Kind, name: String): Boolean {
        val selection =
            "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME}=?"
        resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            selection,
            arrayOf(kind.relativePath, name),
            null,
        ).use { cursor -> return cursor != null && cursor.count > 0 }
    }

    private fun displayName(uri: Uri): String? =
        resolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

    private fun uniqueName(name: String, exists: (String) -> Boolean): String {
        if (!exists(name)) return name
        val stem = name.substringBeforeLast('.')
        val extension = name.substringAfterLast('.', "")
        val suffix = if (extension.isEmpty()) "" else ".$extension"
        return generateSequence(1) { it + 1 }
            .map { "$stem-$it$suffix" }
            .first { !exists(it) }
    }

    private fun isContentRef(ref: String) = ref.startsWith("content:")

    private enum class Kind(val mimeType: String, val directory: String) {
        JPEG("image/jpeg", Environment.DIRECTORY_PICTURES),
        RAW("image/x-canon-cr3", Environment.DIRECTORY_DOWNLOADS);

        val relativePath get() = "$directory/$ALBUM/"

        @RequiresApi(Build.VERSION_CODES.Q)
        fun collection(): Uri = when (this) {
            JPEG -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            RAW -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
    }

    private class OwnershipLostException(ref: String) : IOException("Not owned: $ref")

    private companion object {
        const val PHOTOS_CHANNEL = "ch.micheljung.shutterlink/photos"
        const val MEDIA_CHANNEL = "ch.micheljung.shutterlink/media"
        const val ALBUM = "Shutterlink"
        const val WRITE_TRUNCATE = "wt"
        const val PARTIAL_SUFFIX = ".partial"
        const val DELETE_REQUEST_CODE = 0x5d1
        const val PENDING = "pending"
        const val PUBLISHED = "published"
        const val MISSING = "missing"
        const val INVALID_ARGUMENTS = "invalid_arguments"
        const val SAVE_FAILED = "save_failed"
        const val OWNERSHIP_LOST = "ownership_lost"
        const val BUSY = "busy"
    }
}
