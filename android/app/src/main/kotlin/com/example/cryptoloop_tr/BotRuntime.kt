package com.example.cryptoloop_tr

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** One cached engine owns both the UI and strategy. No duplicate background bot. */
object BotRuntime {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    var activity = WeakReference<MainActivity>(null)
    var startResult: MethodChannel.Result? = null
    var permissionResult: MethodChannel.Result? = null
    private var stopResult: MethodChannel.Result? = null
    private val handler = Handler(Looper.getMainLooper())
    const val PERMISSION_REQUEST = 817

    fun getEngine(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        val created = FlutterEngine(app)
        engine = created
        channel = MethodChannel(created.dartExecutor.binaryMessenger, "cryptoloop/bot_service")
        channel!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "requestNotifications" -> requestNotifications(app, result)
                    "start" -> {
                        if (stopResult != null) {
                            result.error("STOPPING", "Önceki bot servisi durduruluyor.", null)
                        } else if (BotService.instance != null) {
                            result.success(true)
                        } else if (startResult != null) {
                            result.error("BUSY", "Servis başlatılıyor.", null)
                        } else if (activity.get()?.visible != true || !notificationsAllowed(app)) {
                            result.error("NOT_READY", "Uygulamayı açın ve bildirim iznini kontrol edin.", null)
                        } else {
                            startResult = result
                            val intent = Intent(app, BotService::class.java)
                            if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent)
                            else app.startService(intent)
                            handler.postDelayed({
                                if (startResult === result) {
                                    result.error("TIMEOUT", "Bot servisi zamanında başlamadı.", null)
                                    startResult = null
                                    app.stopService(intent)
                                }
                            }, 4000)
                        }
                    }
                    "update" -> {
                        val args = call.arguments as? Map<*, *>
                        BotService.instance?.updateText(
                            args?.get("symbol")?.toString() ?: "BTC/TRY",
                            args?.get("state")?.toString() ?: "Piyasa izleniyor",
                            args?.get("connection")?.toString() ?: "")
                        result.success(null)
                    }
                    "stop" -> {
                        startResult?.error("CANCELLED", "Başlatma iptal edildi.", null)
                        startResult = null
                        val running = BotService.instance
                        if (running == null) {
                            app.stopService(Intent(app, BotService::class.java))
                            result.success(null)
                        } else {
                            stopResult = result
                            running.prepareAppStop()
                            app.stopService(Intent(app, BotService::class.java))
                        }
                    }
                    "status" -> result.success(mapOf(
                        "running" to (BotService.instance != null),
                        "wakeLock" to (BotService.instance?.hasWakeLock() == true),
                        "screenInteractive" to app.getSystemService(PowerManager::class.java).isInteractive,
                        "notifications" to notificationsAllowed(app)))
                    // Device test commands are rejected by release builds.
                    "testBackground", "testNotificationStop" -> {
                        if (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
                            result.notImplemented()
                        } else if (call.method == "testBackground") {
                            result.success(activity.get()?.moveTaskToBack(true) == true)
                        } else {
                            app.startService(Intent(app, BotService::class.java).setAction(BotService.STOP))
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                startResult = null
                if (stopResult === result) stopResult = null
                result.error("ANDROID_SERVICE", e.message ?: "Servis hatası", null)
            }
        }
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    private fun notificationsAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        return Build.VERSION.SDK_INT < 24 || context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
    }

    private fun requestNotifications(context: Context, result: MethodChannel.Result) {
        if (notificationsAllowed(context)) {
            result.success(true)
            return
        }
        val host = activity.get()
        if (Build.VERSION.SDK_INT < 33 || host == null || !host.visible) {
            result.success(false)
        } else if (permissionResult != null) {
            result.error("BUSY", "Bildirim onayı bekleniyor.", null)
        } else {
            permissionResult = result
            host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
        }
    }

    fun permissionResponse(context: Context) {
        permissionResult?.success(notificationsAllowed(context))
        permissionResult = null
    }

    fun started() {
        startResult?.success(true)
        startResult = null
    }

    fun failed(reason: String) {
        startResult?.error("START_FAILED", reason, null)
        startResult = null
    }

    fun requestStop(reason: String, complete: () -> Unit) {
        val c = channel
        if (c == null) { complete(); return }
        var finished = false
        fun done() { if (!finished) { finished = true; complete() } }
        handler.postDelayed({ done() }, 4000)
        c.invokeMethod("stopRequested", reason, object : MethodChannel.Result {
            override fun success(result: Any?) = done()
            override fun error(code: String, message: String?, details: Any?) = done()
            override fun notImplemented() = done()
        })
    }

    fun stopped(notify: Boolean) {
        stopResult?.success(null)
        stopResult = null
        if (notify) channel?.invokeMethod("serviceStopped", "Android bot servisi durduruldu.")
    }

    fun heartbeat(complete: (Boolean) -> Unit) {
        val c = channel
        if (c == null) { complete(false); return }
        var finished = false
        fun done(ok: Boolean) { if (!finished) { finished = true; complete(ok) } }
        handler.postDelayed({ done(false) }, 5000)
        c.invokeMethod("heartbeat", null, object : MethodChannel.Result {
            override fun success(result: Any?) = done((result as? Map<*, *>)?.get("paperRunning") == true)
            override fun error(code: String, message: String?, details: Any?) = done(false)
            override fun notImplemented() = done(false)
        })
    }
}
