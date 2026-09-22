package dev.continuum.chat

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONObject

/// 通知使用权（权限中心授权项 + 手机工具 v0.2.128）：
/// - get_notifications 工具实时读系统当前活跃通知（过滤系统/常驻垃圾通知）
/// - 参考 Nudge NudgeNotificationService.kt（保留黑名单思路，适配Continuum Chat自己的常驻通知）
class PermissionNotificationListenerService : NotificationListenerService() {

    companion object {
        private const val TAG = "ContinuumNotifListener"

        @Volatile var isRunning: Boolean = false
        @Volatile var instance: PermissionNotificationListenerService? = null

        /// 从系统实时读取当前活跃通知（过滤黑名单），按时间倒序取 count 条。
        fun getActiveNotificationsJson(count: Int): List<JSONObject> {
            val inst = instance ?: return emptyList()
            return try {
                inst.activeNotifications
                    .filter {
                        val ex = it.notification.extras
                        !isBlocked(it.packageName, ex.getString("android.title"), ex.getString("android.text"))
                    }
                    .map { sbn ->
                        val extras = sbn.notification.extras
                        JSONObject().apply {
                            put("app", try {
                                inst.packageManager.getApplicationLabel(inst.packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
                            } catch (_: Exception) { sbn.packageName })
                            put("package", sbn.packageName)
                            put("title", extras.getString("android.title") ?: "")
                            put("text", extras.getString("android.text") ?: "")
                            put("time", sbn.postTime)
                        }
                    }
                    .sortedByDescending { it.optLong("time", 0L) }
                    .take(count)
            } catch (e: Exception) {
                Log.w(TAG, "getActiveNotificationsJson error: ${e.message}")
                emptyList()
            }
        }

        /// 小米系统服务/常驻垃圾通知，不进结果。
        private val BLOCKED_PACKAGES = setOf(
            "com.android.systemui",       // 系统界面
            "com.miui.securitycenter",    // 安全服务
            "com.milink.service",         // 设备互联
            "com.xiaomi.aicr",            // 小米澎湃AI引擎
            "com.miui.misound",           // 音质音效
            "com.miui.contentextension",  // 传送门
            "com.miui.translationservice", // 传送门-翻译
            "com.xiaomi.finddevice",       // 查找设备
            "com.xiaomi.smarthome",        // 米家
            "com.miui.tsmclient",          // 小米智能卡/钱包
            "com.xiaomi.mi_connect_service", // 小米互联通信服务
            "com.miui.voicetrigger",       // 语音唤醒
            "com.xiaomi.mirror",           // 跨屏协同服务
            "com.github.metacubex.clash.alpha", // Clash 常驻
            "com.termux",                  // Termux 常驻
            "dev.continuum.chat",    // Continuum Chat自己的常驻通知（前台服务）
        )

        /// 按 (包名, 标题) 过滤特定常驻通知，不影响该应用的其他消息。
        private val BLOCKED_TITLE_RULES = setOf(
            "me.rerere.rikkahub" to "Web服务器运行中"
        )

        fun isBlocked(pkg: String, title: String?, text: String?): Boolean {
            if (pkg in BLOCKED_PACKAGES) return true
            if (BLOCKED_TITLE_RULES.any { it.first == pkg && it.second == title }) return true
            if (pkg == "me.rerere.rikkahub" && title.isNullOrBlank() && text.isNullOrBlank()) return true
            return false
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        isRunning = true
        instance = this
        Log.d(TAG, "notification listener connected")
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        // 读取走 getActiveNotificationsJson 实时拉，这里只需保持服务存活
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
    }

}
