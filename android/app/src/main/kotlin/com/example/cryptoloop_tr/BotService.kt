package com.example.cryptoloop_tr

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/** User-started paper strategy, visible and stoppable; never boot/restart auto-trading. */
class BotService : Service() {
    companion object {
        const val STOP = "com.example.cryptoloop_tr.STOP_PAPER_BOT"
        private const val CHANNEL = "paper_bot_v1"
        private const val NOTIFICATION = 401
        var instance: BotService? = null
            private set
    }
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var stopping = false
    private var notifyDartOnDestroy = true
    private var title = "CryptoLoop TR · PAPER"
    private var text = "Piyasa izleniyor; gerçek para kullanılmaz."
    private val pulse = object : Runnable {
        override fun run() {
            if (stopping || instance !== this@BotService) return
            BotRuntime.heartbeat { alive ->
                if (!alive) stopSafely("Paper motor yanıt vermiyor; bot servisi durduruldu.")
                else {
                    wakeLock?.acquire(60000)
                    handler.postDelayed(this, 15000)
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "Paper bot", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Ekran kapalıyken paper stratejisinin durumu ve durdurma kontrolü"
                    setShowBadge(false)
                })
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            stopSafely("Bildirimden acil durdurma. Açık paper pozisyon satılmadı.")
            return START_NOT_STICKY
        }
        if (stopping || intent == null) { stopSelf(); return START_NOT_STICKY }
        if (instance === this) { BotRuntime.started(); return START_NOT_STICKY }
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else startForeground(NOTIFICATION, notification())
            wakeLock = getSystemService(PowerManager::class.java).newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "CryptoLoop:PaperBot").apply {
                setReferenceCounted(false)
                acquire(60000)
            }
            instance = this
            BotRuntime.started()
            handler.postDelayed(pulse, 15000)
        } catch (e: Exception) {
            BotRuntime.failed(e.message ?: "Android servisi başlatılamadı.")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 1,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 2,
            Intent(this, BotService::class.java).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else Notification.Builder(this)
        return builder.setSmallIcon(R.drawable.ic_cryptoloop)
            .setContentTitle(title).setContentText(text).setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "BOTU DURDUR", stop).build()).build()
    }

    fun updateText(symbol: String, state: String, connection: String) {
        if (stopping || instance !== this) return
        title = "CryptoLoop TR · PAPER · $symbol"
        text = "$state\n$connection"
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification())
    }

    fun hasWakeLock() = wakeLock?.isHeld == true

    fun prepareAppStop() {
        stopping = true
        notifyDartOnDestroy = false
        handler.removeCallbacks(pulse)
    }

    private fun stopSafely(reason: String) {
        if (stopping) return
        stopping = true
        handler.removeCallbacks(pulse)
        BotRuntime.requestStop(reason) {
            notifyDartOnDestroy = false
            stopSelf()
        }
    }

    override fun onDestroy() {
        stopping = true
        handler.removeCallbacksAndMessages(null)
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        if (instance === this) instance = null
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else { @Suppress("DEPRECATION") stopForeground(true) }
        BotRuntime.stopped(notifyDartOnDestroy)
        super.onDestroy()
    }
}
