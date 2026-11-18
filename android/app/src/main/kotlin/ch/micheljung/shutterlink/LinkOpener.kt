package ch.micheljung.shutterlink

import android.content.Context
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Opens a web page in the user's browser. */
class LinkOpener(private val context: Context) {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            val url = call.argument<String>("url")
            if (call.method != "open" || url == null) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                (AppEngine.activity ?: context).startActivity(intent)
                result.success(true)
            } catch (_: Exception) {
                // No browser, or one the app may not start.
                result.success(false)
            }
        }
    }

    private companion object {
        const val CHANNEL = "ch.micheljung.shutterlink/browser"
    }
}
