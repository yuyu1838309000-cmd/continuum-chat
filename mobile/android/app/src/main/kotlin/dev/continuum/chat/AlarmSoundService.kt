package dev.continuum.chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.core.app.NotificationCompat

/// 闹钟铃声播放服务（v0.2.128 移植 Nudge AlarmSoundService.kt）。
/// MediaPlayer 直接播系统闹钟铃声（USAGE_ALARM 走闹钟音量）+ 震动 + 全屏响铃页，
/// 不依赖通知渠道声音，避免被渠道静音/替换。
class AlarmSoundService : Service() {

    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var ringId: Long = -1L

    companion object {
        private const val RING_DURATION_MS = 60_000L // 最长响60秒

        fun start(context: Context, id: Long, title: String, note: String) {
            val intent = Intent(context, AlarmSoundService::class.java).apply {
                putExtra("id", id)
                putExtra("title", title)
                putExtra("note", note)
            }
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, AlarmReceiver::class.java).apply {
                action = AlarmReceiver.ACTION_STOP
            }
            context.sendBroadcast(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == AlarmReceiver.ACTION_STOP) {
            stopRinging()
            return START_NOT_STICKY
        }
        ringId = intent?.getLongExtra("id", -1L) ?: -1L
        val title = intent?.getStringExtra("title") ?: "闹钟"
        val note = intent?.getStringExtra("note") ?: ""

        startForeground(notifyId(), buildNotification(title, note))
        startRinging()

        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ stopRinging() }, RING_DURATION_MS)
        return START_NOT_STICKY
    }

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    private fun notifyId(): Int {
        val base = (ringId % 90000).toInt()
        return if (base < 0) 1000 else base + 1000
    }

    private fun buildNotification(title: String, note: String): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.deleteNotificationChannel("continuum_alarm")
        nm.deleteNotificationChannel("continuum_alarm_v2")
        val channelId = "continuum_alarm_v3"
        // 声音由服务播放, 渠道本身静音避免双响
        val channel = NotificationChannel(channelId, "Continuum Chat 闹钟", NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(null, null)
            enableVibration(false)
        }
        nm.createNotificationChannel(channel)

        val contentIntent = Intent(this, RingingActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("title", title)
            putExtra("note", note)
        }
        val contentPi = PendingIntent.getActivity(
            this, notifyId(), contentIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val stopIntent = Intent(this, AlarmReceiver::class.java).apply { action = AlarmReceiver.ACTION_STOP }
        val stopPi = PendingIntent.getBroadcast(
            this, notifyId() + 1, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val text = if (note.isNotBlank()) note else "时间到啦"
        val builder = NotificationCompat.Builder(this, channelId)
            .setContentTitle("⏰ $title")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setContentIntent(contentPi)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", stopPi)

        if (Build.VERSION.SDK_INT >= 29) {
            val fullPi = PendingIntent.getActivity(
                this, notifyId() + 2, contentIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            builder.setFullScreenIntent(fullPi, true)
        }
        return builder.build()
    }

    private fun startRinging() {
        try {
            // 系统闹钟铃声（没有就退回通知音）
            var uri: Uri? = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            if (uri == null) uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val p = MediaPlayer()
            p.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            p.setDataSource(this, uri)
            p.isLooping = true
            p.setVolume(0.8f, 0.8f)
            p.prepare()
            p.start()
            player = p
        } catch (e: Exception) {
            // 播放失败静默，至少还有全屏页
            try { player?.release() } catch (_: Exception) {}
            player = null
        }

        try {
            vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (vibrator?.hasVibrator() == true) {
                if (Build.VERSION.SDK_INT >= 26) {
                    vibrator?.vibrate(
                        VibrationEffect.createWaveform(longArrayOf(0, 600, 400, 600, 400, 600), 0)
                    )
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(longArrayOf(0, 600, 400, 600, 400, 600), 0)
                }
            }
        } catch (_: Exception) {}
    }

    private fun stopRinging() {
        try { player?.stop() } catch (_: Exception) {}
        try { player?.release() } catch (_: Exception) {}
        player = null
        try { vibrator?.cancel() } catch (_: Exception) {}
        vibrator = null
        handler.removeCallbacksAndMessages(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        try { player?.stop() } catch (_: Exception) {}
        try { player?.release() } catch (_: Exception) {}
        player = null
        try { vibrator?.cancel() } catch (_: Exception) {}
        vibrator = null
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
