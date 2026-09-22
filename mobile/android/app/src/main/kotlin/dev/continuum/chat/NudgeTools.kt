package dev.continuum.chat

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

/// 手机工具：提供一组 Android 设备能力入口。
/// 原生实现集中在当前公开客户端内，并通过 MethodChannel "nudge" 调用。
/// 返回 JSON 字符串，供上层工具桥统一处理。
/// 每个工具先做权限检查，未授权返回明确提示，不阻塞其他工具。
object NudgeTools {

    /** 统一入口：tool 名 + 参数 → JSON 字符串结果。在后台线程调用。 */
    fun call(context: Context, tool: String, args: Map<*, *>): String {
        return try {
            when (tool) {
                "ping" -> ping()
                "get_foreground_app" -> getForegroundApp(context)
                "screenshot_analyze" -> screenshotAndAnalyze(context, args)
                "sensor_data" -> sensorData(context)
                "device_status" -> deviceStatus(context)
                "get_location" -> getLocation(context)
                "get_notifications" -> getNotifications(context, args.toInt("count", 10))
                "get_steps" -> getSteps(context)
                "calendar_query" -> getCalendar(context, args.toInt("days", 7))
                "calendar_create" -> createCalendar(context, args)
                "set_alarm" -> setAlarm(
                    context,
                    args.toInt("hour", 0),
                    args.toInt("minute", 0),
                    args.toString("message", "闹钟"),
                    args.toString("repeat", "once"),
                    args.toString("title", args.toString("message", "闹钟")),
                    args.toString("note", "")
                )
                "lock_screen" -> performGlobalAction(
                    android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN,
                    "锁屏。你可以做出任何行为进行下一步"
                )
                "media_play_pause" -> sendMediaKey(context, android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, "播放/暂停")
                "media_next" -> sendMediaKey(context, android.view.KeyEvent.KEYCODE_MEDIA_NEXT, "下一首")
                "media_previous" -> sendMediaKey(context, android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS, "上一首")
                "press_back" -> performGlobalAction(
                    android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK,
                    "返回"
                )
                "press_home" -> performGlobalAction(
                    android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME,
                    "桌面"
                )
                "open_app" -> openApp(context, args.toString("package", ""))
                "wake_up" -> wakeUp(context)
                "read_screen" -> readScreen(context)
                "switch_to_continuum" -> switchToContinuum(context)
                else -> "{\"error\":\"未知工具: $tool\"}"
            }
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 1. ping（测试连通性） ──
    private fun ping(): String = "{\"success\":true,\"pong\":true}"

    // ── 2. get_foreground_app（前台应用/锁屏/电量） ──
    private fun getForegroundApp(context: Context): String {
        val km = context.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
        val locked = km.isKeyguardLocked
        val battery = batteryText(bm)
        if (locked) {
            return "锁屏状态：是；电量：$battery。你可以做出任何行为进行下一步"
        }
        val pkg = PermissionAccessibilityService.currentPackage
        if (pkg.isEmpty()) {
            return "{\"error\":\"未授权：无障碍服务未开启或未检测到前台应用，请到权限中心开启Continuum Chat无障碍服务，然后切换一次应用\"}"
        }
        val name = PermissionAccessibilityService.currentAppName
        val app = name.ifBlank { pkg }
        return "前台应用：$app（$pkg）；锁屏：否；电量：$battery。你可以做出任何行为进行下一步"
    }

    // ── 3. screenshot_analyze（截屏分析，Android 14+ 无障碍截屏 + 服务器识别） ──
    // v0.2.129：识别从 App 端挪到 Runtime /screenshot-analyze，key 在服务器
    // ~/.gen_image_config.json，App 只发截图 base64、收描述，不持有 key。
    private fun screenshotAndAnalyze(context: Context, args: Map<*, *>): String {
        // 权限检测（v0.2.129 修正）：先查 Android 14+，再查无障碍设置里是否真开启
        // （Settings.Secure 与权限中心同款判断，避免已授权却误报），最后看服务实例是否连着——
        // 已开但被系统回收时给准确提示（去重连而不是去授权），未开才提示去权限中心。
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return "{\"error\":\"需要Android 14+才能截屏（当前 ${android.os.Build.VERSION.SDK_INT}）\"}"
        }
        if (!isAccessibilityEnabled(context)) {
            return "{\"error\":\"未授权：无障碍服务未开启，请到权限中心开启Continuum Chat无障碍权限\"}"
        }
        val service = PermissionAccessibilityService.instance
            ?: return "{\"error\":\"无障碍服务已开启但当前未连接（可能被系统回收），请打开Continuum Chat App 稍等重连后重试\"}"
        val latch = java.util.concurrent.CountDownLatch(1)
        var result = ""
        try {
            service.takeScreenshotBase64 { base64 ->
                if (base64.startsWith("{\"error\"}")) {
                    result = base64
                } else {
                    result = analyzeOnServer(base64, args)
                }
                latch.countDown()
            }
            val ok = latch.await(100, java.util.concurrent.TimeUnit.SECONDS)
            if (!ok) return "{\"error\":\"截图或识别超时(100s)\"}"
            return result.ifEmpty { "{\"error\":\"截图或识别超时(100s)\"}" }
        } catch (e: Exception) {
            return "{\"error\":\"${e.message}\"}"
        }
    }

    /// 无障碍设置里是否已开启Continuum Chat无障碍服务（Settings.Secure 已启用列表包含本组件）。
    private fun isAccessibilityEnabled(context: Context): Boolean {
        val component = android.content.ComponentName(context, PermissionAccessibilityService::class.java)
            .flattenToString()
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabled.split(':').any { it == component }
    }

    /// 截图交给 Runtime 识别（带 X-Token；server_base_url/token 由 Dart 注入）。
    private fun analyzeOnServer(base64: String, args: Map<*, *>): String {
        try {
            val serverBaseUrl = args.toString("server_base_url", "").trim().trimEnd('/')
            if (serverBaseUrl.isEmpty()) return "{\"error\":\"服务器地址未配置，请到配置中心设置服务器地址\"}"
            val token = args.toString("token", "")
            val payload = JSONObject().apply { put("image_base64", base64) }
            val conn = java.net.URL("$serverBaseUrl/screenshot-analyze")
                .openConnection() as java.net.HttpURLConnection
            try {
                conn.requestMethod = "POST"
                conn.connectTimeout = 15000
                conn.readTimeout = 90000
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-Token", token)
                conn.doOutput = true
                val body = payload.toString().toByteArray(Charsets.UTF_8)
                conn.outputStream.use { it.write(body) }
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val respBody = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                val respJson = try { JSONObject(respBody) } catch (_: Exception) { JSONObject() }
                if (code in 200..299 && respJson.optBoolean("ok", false)) {
                    val text = respJson.optString("text", "")
                    if (text.isNotBlank()) {
                        return JSONObject().apply { put("description", text) }.toString()
                    }
                    return "{\"error\":\"服务器返回空描述\"}"
                }
                val err = respJson.optString("error", "")
                return if (err.isNotBlank()) "{\"error\":\"服务器识别失败: $err\"}"
                else "{\"error\":\"服务器返回异常: HTTP $code\"}"
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            return "{\"error\":\"服务器识别失败: ${e.message}\"}"
        }
    }

    // ── 4. sensor_data（传感器判她是否在玩手机） ──
    private fun sensorData(context: Context): String {
        return try {
            val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as android.hardware.SensorManager
            val types = listOf(
                android.hardware.Sensor.TYPE_ACCELEROMETER to "accelerometer",
                android.hardware.Sensor.TYPE_LIGHT to "light",
                android.hardware.Sensor.TYPE_GYROSCOPE to "gyroscope",
                android.hardware.Sensor.TYPE_PROXIMITY to "proximity",
                android.hardware.Sensor.TYPE_GRAVITY to "gravity",
                android.hardware.Sensor.TYPE_MAGNETIC_FIELD to "magnetic"
            )
            val result = JSONObject()
            val latches = mutableListOf<java.util.concurrent.CountDownLatch>()
            val mainHandler = Handler(Looper.getMainLooper())

            for ((type, name) in types) {
                val sensor = sensorManager.getDefaultSensor(type)
                if (sensor != null) {
                    val latch = java.util.concurrent.CountDownLatch(1)
                    latches.add(latch)
                    val listener = object : android.hardware.SensorEventListener {
                        override fun onSensorChanged(event: android.hardware.SensorEvent?) {
                            if (event != null) {
                                val values = JSONArray()
                                for (v in event.values) values.put(String.format("%.2f", v))
                                result.put(name, values)
                            }
                            try { sensorManager.unregisterListener(this) } catch (_: Exception) {}
                            latch.countDown()
                        }
                        override fun onAccuracyChanged(sensor: android.hardware.Sensor?, accuracy: Int) {}
                    }
                    mainHandler.post {
                        try {
                            sensorManager.registerListener(listener, sensor, android.hardware.SensorManager.SENSOR_DELAY_NORMAL)
                        } catch (_: Exception) {
                            latch.countDown()
                        }
                    }
                }
            }
            for (latch in latches) latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
            result.toString()
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 5. device_status（锁屏/电量/充电） ──
    private fun deviceStatus(context: Context): String {
        return try {
            val km = context.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
            val bm = context.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager

            val locked = km.isKeyguardLocked
            val battery = batteryText(bm)
            val charging = isCharging(bm)
            "锁屏状态：${if (locked) "是" else "否"}；电量：$battery；充电：${if (charging) "是" else "否"}。你可以做出任何行为进行下一步"
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 6. get_location（GPS 定位 + 地址） ──
    private fun getLocation(context: Context): String {
        return try {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                return "{\"error\":\"未授权定位权限，请到权限中心开启定位\"}"
            }
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as android.location.LocationManager
            var best: android.location.Location? = null
            for (provider in listOf(android.location.LocationManager.GPS_PROVIDER, android.location.LocationManager.NETWORK_PROVIDER)) {
                try {
                    val loc = lm.getLastKnownLocation(provider)
                    if (loc != null && (best == null || loc.accuracy < best.accuracy)) {
                        best = loc
                    }
                } catch (_: SecurityException) {
                } catch (_: Exception) {}
            }
            if (best != null) {
                val json = JSONObject().apply {
                    put("latitude", best.latitude)
                    put("longitude", best.longitude)
                    put("accuracy", best.accuracy.toDouble())
                    put("provider", best.provider ?: "unknown")
                    if (best.hasAltitude()) put("altitude", String.format("%.1f", best.altitude))
                }
                try {
                    val geocoder = android.location.Geocoder(context, java.util.Locale.CHINA)
                    val addresses = geocoder.getFromLocation(best.latitude, best.longitude, 1)
                    if (addresses != null && addresses.isNotEmpty()) {
                        val addr = addresses[0]
                        val line = addr.getAddressLine(0)
                        if (!line.isNullOrEmpty()) {
                            json.put("address", line)
                        } else {
                            val parts = listOf(addr.adminArea, addr.locality, addr.subLocality, addr.thoroughfare)
                                .filter { !it.isNullOrEmpty() }
                            if (parts.isNotEmpty()) json.put("address", parts.joinToString(""))
                        }
                    }
                } catch (_: Exception) {}
                json.toString()
            } else {
                "{\"error\":\"无法获取位置，请确保GPS已开启\"}"
            }
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 7. get_notifications（看她有没有回你消息） ──
    private fun getNotifications(context: Context, count: Int): String {
        if (!PermissionNotificationListenerService.isRunning) {
            return "{\"error\":\"通知监听服务未开启，请在系统设置→通知使用权中开启Continuum Chat\"}"
        }
        val arr = JSONArray()
        for (item in PermissionNotificationListenerService.getActiveNotificationsJson(count)) arr.put(item)
        return JSONObject().apply { put("notifications", arr); put("count", arr.length()) }.toString()
    }

    // ── 8. get_steps（今日步数，步数传感器累计值按日减基准） ──
    private fun getSteps(context: Context): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED) {
            return "{\"error\":\"未授权活动识别权限，请到权限中心开启（步数统计需要）\"}"
        }
        val total = PermissionAccessibilityService.steps
        if (total <= 0) return "{\"steps\":0,\"note\":\"传感器未激活，请走几步后再试（需无障碍服务开启）\"}"
        val prefs = context.getSharedPreferences("continuum_tools", Context.MODE_PRIVATE)
        val today = java.text.SimpleDateFormat("yyyyMMdd", java.util.Locale.US).format(java.util.Date())
        val baseKey = "step_base_$today"
        var base = prefs.getLong(baseKey, -1L)
        if (base < 0 || total < base) {
            base = total
            prefs.edit().putLong(baseKey, base).apply()
        }
        return "{\"steps\":${total - base}}"
    }

    // ── 9. calendar_query（查日程） ──
    private fun getCalendar(context: Context, days: Int): String {
        return try {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) != PackageManager.PERMISSION_GRANTED) {
                return "{\"error\":\"未授权日历权限，请到权限中心开启\"}"
            }
            val now = System.currentTimeMillis()
            val end = now + days * 86400000L
            val uri = android.provider.CalendarContract.Events.CONTENT_URI
            val projection = arrayOf(
                android.provider.CalendarContract.Events.TITLE,
                android.provider.CalendarContract.Events.DTSTART,
                android.provider.CalendarContract.Events.DTEND,
                android.provider.CalendarContract.Events.ALL_DAY,
                android.provider.CalendarContract.Events.RRULE
            )
            val selection = "dtstart >= ? AND dtstart <= ?"
            val args = arrayOf(now.toString(), end.toString())
            val cursor = context.contentResolver.query(uri, projection, selection, args, "dtstart ASC")
            val events = JSONArray()
            cursor?.use {
                while (it.moveToNext()) {
                    events.put(JSONObject().apply {
                        put("title", it.getString(0) ?: "")
                        put("start", it.getLong(1))
                        put("end", it.getLong(2))
                        put("all_day", it.getInt(3) == 1)
                        put("rrule", it.getString(4) ?: "")
                    })
                }
            }
            JSONObject().apply { put("events", events); put("count", events.length()) }.toString()
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 9.1 calendar_create（建日程，写进系统日历） ──
    // 字段按小米 HyperOS 支持范围：TITLE / DTSTART / DTEND / ALL_DAY / DESCRIPTION / RRULE。
    // 不做事件颜色、地点、指定账户（小米写入暂不支持）。
    private fun createCalendar(context: Context, args: Map<*, *>): String {
        return try {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) != PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CALENDAR) != PackageManager.PERMISSION_GRANTED) {
                return "{\"error\":\"未授权日历读写权限，请到权限中心开启\"}"
            }
            val title = args.toString("title", "").trim().take(1000)
            if (title.isEmpty()) return "{\"error\":\"日程标题不能为空\"}"
            val start = args.toLong("start", 0L)
            if (start <= 0L) return "{\"error\":\"开始时间(start)不能为空\"}"
            val end = args.toLong("end", start + 3600000L)
            val allDay = args.toBoolean("all_day", false)
            val description = args.toString("description", "").trim().take(1000)
            val rrule = args.toString("rrule", "").trim().take(1000)
            val calId = defaultCalendarId(context)
                ?: return "{\"error\":\"未找到可写的系统日历账户\"}"
            val values = android.content.ContentValues().apply {
                put(android.provider.CalendarContract.Events.CALENDAR_ID, calId)
                put(android.provider.CalendarContract.Events.TITLE, title)
                put(android.provider.CalendarContract.Events.DTSTART, start)
                put(android.provider.CalendarContract.Events.DTEND, if (allDay) start + 86400000L else if (end > start) end else start + 3600000L)
                put(android.provider.CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)
                put(android.provider.CalendarContract.Events.DESCRIPTION, description)
                put(
                    android.provider.CalendarContract.Events.EVENT_TIMEZONE,
                    java.util.TimeZone.getTimeZone("UTC").id
                )
                if (rrule.isNotEmpty()) put(android.provider.CalendarContract.Events.RRULE, rrule)
            }
            val uri = context.contentResolver.insert(android.provider.CalendarContract.Events.CONTENT_URI, values)
                ?: return "{\"error\":\"写入系统日历失败\"}"
            val id = uri.lastPathSegment?.toLongOrNull() ?: 0L
            JSONObject().apply {
                put("success", true)
                put("id", id)
                put("title", title)
                put("start", start)
                put("end", values.getAsLong(android.provider.CalendarContract.Events.DTEND))
                put("all_day", allDay)
                put("rrule", rrule)
            }.toString()
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    /// 取第一个可写的系统日历 id（小米日历通常只有一个可见账户）。
    private fun defaultCalendarId(context: Context): Long? {
        val projection = arrayOf(
            android.provider.CalendarContract.Calendars._ID,
            android.provider.CalendarContract.Calendars.IS_PRIMARY
        )
        context.contentResolver.query(
            android.provider.CalendarContract.Calendars.CONTENT_URI,
            projection,
            null,
            null,
            null
        )?.use { c ->
            var fallback: Long? = null
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val primary = c.getInt(1) == 1
                if (primary) return id
                if (fallback == null) fallback = id
            }
            return fallback
        }
        return null
    }

    // ── 10. set_alarm（设置系统闹钟） ──
    private fun setAlarm(context: Context, hour: Int, minute: Int, message: String, repeat: String, title: String, note: String): String {
        return try {
            val weekdays = if (repeat == "weekly") listOf(1, 2, 3, 4, 5) else emptyList()
            val item = AlarmStore.add(context, "alarm", hour, minute,
                title.ifBlank { message }, note, repeat, weekdays, 0)
            "{\"success\":true,\"time\":\"${hour}:${String.format("%02d", minute)}\",\"repeat\":\"$repeat\",\"title\":\"${item.title}\"}"
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 11/15/16. 全局按键（锁屏/返回/桌面，走无障碍） ──
    private fun performGlobalAction(action: Int, name: String): String {
        val service = PermissionAccessibilityService.instance
            ?: return "{\"error\":\"无障碍服务未运行，请到权限中心开启Continuum Chat无障碍\"}"
        return try {
            val ok = service.performGlobalAction(action)
            if (ok) "{\"success\":true,\"action\":\"$name\"}" else "{\"error\":\"${name}失败\"}"
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 12/13/14. 媒体键（播放/下一首/上一首） ──
    private fun sendMediaKey(context: Context, keyCode: Int, name: String): String {
        return try {
            val latch = java.util.concurrent.CountDownLatch(1)
            var result = ""
            Handler(Looper.getMainLooper()).post {
                try {
                    val am = context.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                    val down = android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, keyCode)
                    am.dispatchMediaKeyEvent(down)
                    val up = android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, keyCode)
                    am.dispatchMediaKeyEvent(up)
                    result = "{\"success\":true,\"action\":\"$name\"}"
                } catch (e: Exception) {
                    result = "{\"error\":\"${e.message}\"}"
                }
                latch.countDown()
            }
            latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
            result.ifEmpty { "{\"error\":\"超时\"}" }
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 17. open_app（强制打开指定应用） ──
    private fun openApp(context: Context, pkg: String): String {
        if (pkg.isBlank()) return "{\"error\":\"请传入 package 参数（应用包名）\"}"
        val service = PermissionAccessibilityService.instance
            ?: return "{\"error\":\"无障碍服务未运行，请到权限中心开启Continuum Chat无障碍\"}"
        return try {
            service.openApp(pkg.trim())
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 18. wake_up（亮屏唤醒别装睡） ──
    private fun wakeUp(context: Context): String {
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            @Suppress("DEPRECATION")
            val wl = pm.newWakeLock(
                android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP or
                android.os.PowerManager.ON_AFTER_RELEASE,
                "continuum:wake"
            )
            try {
                wl.acquire(500)
            } finally {
                try { wl.release() } catch (_: Exception) {}
            }
            "{\"success\":true,\"action\":\"唤醒屏幕\"}"
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 19. read_screen（读取当前屏幕文字） ──
    // v0.2.130：权限检测与截屏一致——先按 Settings.Secure 真查无障碍开关，
    // 再查服务实例：已开但被系统回收提示重连（不再误报未授权），未开才提示去权限中心。
    private fun readScreen(context: Context): String {
        if (!isAccessibilityEnabled(context)) {
            return "{\"error\":\"未授权：无障碍服务未开启，请到权限中心开启Continuum Chat无障碍权限\"}"
        }
        val service = PermissionAccessibilityService.instance
            ?: return "{\"error\":\"无障碍服务已开启但当前未连接（可能被系统回收），请打开Continuum Chat App 稍等重连后重试\"}"
        return try {
            service.readScreen()
        } catch (e: Exception) {
            "{\"error\":\"${e.message}\"}"
        }
    }

    // ── 20. switch_to_continuum（切回Continuum Chat） ──
    private fun switchToContinuum(context: Context): String {
        // 优先走无障碍服务实例（服务上下文里 startActivity 更稳）
        val svc = PermissionAccessibilityService.instance
        val ok = if (svc != null) {
            svc.switchToContinuum()
        } else {
            try {
                val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                if (intent == null) false else {
                    intent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    true
                }
            } catch (_: Exception) { false }
        }
        return if (ok) {
            "{\"success\":true,\"action\":\"切换到Continuum Chat\"}"
        } else {
            "{\"error\":\"切换失败，请手动切回Continuum Chat\"}"
        }
    }

    private fun batteryText(bm: android.os.BatteryManager): String {
        val battery = bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return if (battery in 0..100) "$battery%" else "未知"
    }

    private fun isCharging(bm: android.os.BatteryManager): Boolean {
        return when (bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_STATUS)) {
            android.os.BatteryManager.BATTERY_STATUS_CHARGING,
            android.os.BatteryManager.BATTERY_STATUS_FULL -> true
            else -> false
        }
    }

    // ── 参数助手（MethodChannel 数字可能是 Int/Double/Long） ──
    private fun Map<*, *>.toInt(key: String, default: Int): Int {
        val v = this[key] ?: return default
        return when (v) {
            is Int -> v
            is Long -> v.toInt()
            is Double -> v.toInt()
            is Number -> v.toInt()
            is String -> v.toIntOrNull() ?: default
            else -> default
        }
    }

    private fun Map<*, *>.toString(key: String, default: String): String {
        val v = this[key] ?: return default
        return v.toString().ifBlank { default }
    }

    private fun Map<*, *>.toLong(key: String, default: Long): Long {
        val v = this[key] ?: return default
        return when (v) {
            is Long -> v
            is Int -> v.toLong()
            is Double -> v.toLong()
            is Number -> v.toLong()
            is String -> v.toLongOrNull() ?: default
            else -> default
        }
    }

    private fun Map<*, *>.toBoolean(key: String, default: Boolean): Boolean {
        val v = this[key] ?: return default
        return when (v) {
            is Boolean -> v
            is Int -> v != 0
            is Long -> v != 0L
            is String -> v.equals("true", ignoreCase = true) || v == "1"
            else -> default
        }
    }
}
