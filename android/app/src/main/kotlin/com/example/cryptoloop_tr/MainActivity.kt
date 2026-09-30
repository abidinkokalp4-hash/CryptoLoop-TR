package com.example.cryptoloop_tr

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {
    var visible = false
        private set
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        BotRuntime.activity = WeakReference(this)
        return BotRuntime.getEngine(context)
    }
    override fun shouldDestroyEngineWithHost() = false
    override fun onStart() { super.onStart(); visible = true; BotRuntime.activity = WeakReference(this) }
    override fun onStop() { visible = false; super.onStop() }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == BotRuntime.PERMISSION_REQUEST) BotRuntime.permissionResponse(this)
    }
}
