package ch.micheljung.eos_transfer

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        NetworkBinder(applicationContext).register(messenger)
        RawFileSaver(applicationContext).register(messenger)
    }
}
