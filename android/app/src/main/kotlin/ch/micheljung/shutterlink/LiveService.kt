package ch.micheljung.shutterlink

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart's handle on [LiveTransferService]. */
class LiveService(private val context: Context) {
    private var channel: MethodChannel? = null
    private var pendingPermission: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).apply { setMethodCallHandler(::handle) }
    }

    fun dispose() {
        channel = null
        pendingPermission = null
    }

    fun notifyStopRequested(): Boolean {
        val channel = channel ?: return false
        channel.invokeMethod(STOP_REQUESTED, null)
        return true
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST_CODE) return
        pendingPermission?.success(
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED,
        )
        pendingPermission = null
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                LiveTransferService.start(context, statusOf(call))
                result.success(null)
            }
            "updateStatus" -> {
                LiveTransferService.update(context, statusOf(call))
                result.success(null)
            }
            "stop" -> {
                LiveTransferService.stop(context)
                result.success(null)
            }
            "requestNotificationPermission" -> requestNotificationPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        val activity = AppEngine.activity
        if (activity == null || pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST_CODE,
        )
    }

    private fun statusOf(call: MethodCall) =
        LiveTransferService.Status(text = call.argument<String>("text").orEmpty())

    private companion object {
        const val CHANNEL = "ch.micheljung.shutterlink/live"
        const val STOP_REQUESTED = "stopRequested"
        const val PERMISSION_REQUEST_CODE = 0x5d2
    }
}
