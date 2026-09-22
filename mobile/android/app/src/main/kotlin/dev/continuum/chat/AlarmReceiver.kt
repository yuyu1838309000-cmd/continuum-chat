package dev.continuum.chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// 闹钟广播接收（v0.2.128 移植 Nudge AlarmReceiver.kt）：
/// - 收到 ACTION_STOP 停止铃声服务
/// - 收到闹钟触发广播：处理重复/关闭逻辑 + 拉起响铃服务（铃声+震动+全屏页）
class AlarmReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_STOP = "dev.continuum.chat.ALARM_STOP"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_STOP) {
            context.stopService(Intent(context, AlarmSoundService::class.java))
            return
        }

        val id = intent.getLongExtra("id", -1L)
        val type = intent.getStringExtra("type") ?: "alarm"
        val title = intent.getStringExtra("title") ?: "闹钟"
        val note = intent.getStringExtra("note") ?: ""
        if (id > 0) {
            AlarmStore.onFired(context, id)
        }
        AlarmSoundService.start(context, id, title, if (type == "countdown") "倒计时结束 $note" else note)
    }
}
