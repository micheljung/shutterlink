package ch.micheljung.shutterlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the process and the cached Flutter engine alive while Live runs, so
 * Dart keeps transferring with the screen off or the app swiped away.
 */
class LiveTransferService : Service() {
    data class Status(val count: Int, val uploaded: Int, val pending: Int, val text: String)

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, LOCK_TAG)
            .apply {
                setReferenceCounted(false)
                acquire()
            }
        wifiLock = runCatching {
            getSystemService(WifiManager::class.java)
                .createWifiLock(wifiLockMode(), LOCK_TAG)
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }.getOrNull()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification(this, status)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (intent?.action == ACTION_STOP && AppEngine.liveService?.notifyStopRequested() != true) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
        if (AppEngine.activity == null) AppEngine.destroy()
    }

    @Suppress("DEPRECATION")
    private fun wifiLockMode() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        WifiManager.WIFI_MODE_FULL_LOW_LATENCY
    } else {
        WifiManager.WIFI_MODE_FULL_HIGH_PERF
    }

    companion object {
        private const val CHANNEL_ID = "live_transfer"
        private const val CHANNEL_NAME = "Live transfer"
        private const val NOTIFICATION_ID = 1
        private const val STOP_REQUEST_CODE = 1
        private const val OPEN_REQUEST_CODE = 2
        private const val ACTION_STOP = "ch.micheljung.shutterlink.action.STOP_LIVE"
        private const val LOCK_TAG = "shutterlink:live"

        @Volatile
        var isRunning = false
            private set

        @Volatile
        var status = Status(count = 0, uploaded = 0, pending = 0, text = "")

        fun update(context: Context, status: Status) {
            this.status = status
            if (!isRunning) return
            context.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, buildNotification(context, status))
        }

        private fun buildNotification(context: Context, status: Status): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW),
                )
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val stop = PendingIntent.getService(
                context,
                STOP_REQUEST_CODE,
                Intent(context, LiveTransferService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                PendingIntent.getActivity(
                    context,
                    OPEN_REQUEST_CODE,
                    it,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            }
            return builder
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle(status.text.ifEmpty { CHANNEL_NAME })
                .setContentText(
                    "${status.count} photos · ${status.uploaded} uploaded · ${status.pending} pending",
                )
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .addAction(
                    Notification.Action.Builder(null, "Stop", stop).build(),
                )
                .build()
        }
    }
}
