package ch.micheljung.shutterlink

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        AppEngine.attach(this)
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine = AppEngine.obtain(context)

    override fun shouldDestroyEngineWithHost(): Boolean = !LiveTransferService.isRunning

    override fun onDestroy() {
        val engineDestroyed = shouldDestroyEngineWithHost()
        super.onDestroy()
        AppEngine.detach(this)
        if (engineDestroyed) AppEngine.forget()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        AppEngine.mediaSaver?.onActivityResult(requestCode, resultCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        AppEngine.liveService?.onRequestPermissionsResult(requestCode, grantResults)
    }
}
