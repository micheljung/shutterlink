package ch.micheljung.shutterlink

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * The single Flutter engine, kept beyond the Activity while Live runs. Its
 * channels are registered once at creation, so recreating the Activity does
 * not register them again.
 */
object AppEngine {
    private const val ENGINE_ID = "shutterlink"

    private var networkBinder: NetworkBinder? = null
    private var uploadTunnel: UploadTunnel? = null
    var mediaSaver: MediaSaver? = null
        private set
    var liveService: LiveService? = null
        private set
    var activity: Activity? = null
        private set

    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val appContext = context.applicationContext
        val engine = FlutterEngine(appContext)
        val messenger = engine.dartExecutor.binaryMessenger
        networkBinder = NetworkBinder(appContext).also { it.register(messenger) }
        uploadTunnel = UploadTunnel(appContext).also { it.register(messenger) }
        mediaSaver = MediaSaver(appContext).also { it.register(messenger) }
        liveService = LiveService(appContext).also { it.register(messenger) }
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    fun attach(activity: Activity) {
        this.activity = activity
    }

    fun detach(activity: Activity) {
        if (this.activity === activity) this.activity = null
    }

    /**
     * Uncaches the engine after its host destroyed it and releases what its
     * channels held, since destroying an engine does not cancel its streams.
     */
    fun forget() {
        FlutterEngineCache.getInstance().remove(ENGINE_ID)
        networkBinder?.dispose()
        uploadTunnel?.dispose()
        mediaSaver?.dispose()
        liveService?.dispose()
        networkBinder = null
        uploadTunnel = null
        mediaSaver = null
        liveService = null
    }

    fun destroy() {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.destroy()
        forget()
    }
}
