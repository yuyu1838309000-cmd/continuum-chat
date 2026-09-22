package dev.continuum.chat

import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 共读技术探针的本机存储。
 *
 * 正文、截图和 OCR 结果只保存在 App 私有目录；不联网、不上传。
 * [events] 只包含 event/root 已匹配且截图成功的有效页面，失败另存，避免污染样本。
 */
object ReadingProbeStore {
    private const val PREFS = "continuum_reading_probe"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_STARTED_AT = "started_at"
    private const val KEY_EVENTS = "events"
    private const val KEY_FAILURES = "failures"
    private const val KEY_CAPTURES = "captures"
    private const val KEY_ATTEMPTS = "attempts"
    private const val KEY_FINGERPRINTS = "fingerprints"
    private const val KEY_DIAGNOSTIC = "diagnostic"
    private const val MAX_EVENTS = 40
    private const val MAX_FAILURES = 24
    private const val PREVIEW_DIRECTORY = "reading_probe_previews"
    private val lock = Any()

    fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, false)

    fun sessionId(context: Context): Long =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(KEY_STARTED_AT, 0L)

    fun isActiveSession(context: Context, sessionId: Long): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_ENABLED, false) &&
            sessionId > 0L &&
            prefs.getLong(KEY_STARTED_AT, 0L) == sessionId
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        var startedNewSession = false
        synchronized(lock) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val wasEnabled = prefs.getBoolean(KEY_ENABLED, false)
            val edit = prefs.edit().putBoolean(KEY_ENABLED, enabled)
            if (enabled && !wasEnabled) {
                val nextSession = nextSessionId(prefs.getLong(KEY_STARTED_AT, 0L))
                edit.putLong(KEY_STARTED_AT, nextSession)
                    .remove(KEY_EVENTS)
                    .remove(KEY_FAILURES)
                    .remove(KEY_CAPTURES)
                    .remove(KEY_ATTEMPTS)
                    .remove(KEY_FINGERPRINTS)
                    .remove(KEY_DIAGNOSTIC)
                startedNewSession = true
            } else if (!enabled) {
                edit.remove(KEY_DIAGNOSTIC)
            }
            edit.apply()
        }
        if (startedNewSession) deletePreviews(context)
        PermissionAccessibilityService.instance?.refreshReadingProbeMode()
    }

    fun clear(context: Context) {
        synchronized(lock) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val edit = prefs.edit()
                .remove(KEY_EVENTS)
                .remove(KEY_FAILURES)
                .remove(KEY_CAPTURES)
                .remove(KEY_ATTEMPTS)
                .remove(KEY_FINGERPRINTS)
                .remove(KEY_DIAGNOSTIC)
            if (prefs.getBoolean(KEY_ENABLED, false)) {
                edit.putLong(KEY_STARTED_AT, nextSessionId(prefs.getLong(KEY_STARTED_AT, 0L)))
            }
            edit.apply()
        }
        deletePreviews(context)
        PermissionAccessibilityService.instance?.resetReadingProbeSession()
    }

    /** Overwrites the current poll diagnostic instead of growing failure history. */
    fun recordPollDiagnostic(
        context: Context,
        sessionId: Long,
        diagnostic: String,
        foregroundPackage: String,
    ) {
        if (!isActiveSession(context, sessionId)) return
        synchronized(lock) {
            if (!isActiveSession(context, sessionId)) return
            val value = JSONObject().apply {
                put("ts", System.currentTimeMillis())
                put("probe_diagnostic", diagnostic)
                put("poll_foreground_package", foregroundPackage)
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_DIAGNOSTIC, value.toString())
                .apply()
        }
    }

    fun clearDiagnostic(context: Context) {
        synchronized(lock) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .remove(KEY_DIAGNOSTIC)
                .apply()
        }
    }

    /** Records a failed attempt separately from valid page samples. */
    fun recordFailure(
        context: Context,
        sessionId: Long,
        eventPackage: String,
        rootPackage: String,
        eventType: Int,
        className: String,
        stage: String,
        error: String,
        extra: JSONObject? = null,
    ) {
        if (eventPackage.isBlank() || !isActiveSession(context, sessionId)) return
        synchronized(lock) {
            if (!isActiveSession(context, sessionId)) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val failure = JSONObject().apply {
                put("ts", System.currentTimeMillis())
                put("event_type", eventType)
                put("event_name", eventName(eventType))
                put("event_package", eventPackage)
                put("root_package", rootPackage)
                put("package_match", eventPackage == rootPackage && rootPackage.isNotBlank())
                put("package", eventPackage)
                put("app", PermissionAccessibilityService.appLabel(eventPackage))
                put("class_name", className)
                put("status", "failed")
                put("stage", stage)
                put("error", error)
                if (extra != null) {
                    val keys = extra.keys()
                    while (keys.hasNext()) {
                        val key = keys.next()
                        put(key, extra.opt(key))
                    }
                }
            }
            val failures = readArray(prefs.getString(KEY_FAILURES, null))
            failures.put(failure)
            trim(failures, MAX_FAILURES)
            val attempts = readObject(prefs.getString(KEY_ATTEMPTS, null))
            attempts.put(eventPackage, failure)
            prefs.edit()
                .putString(KEY_FAILURES, failures.toString())
                .putString(KEY_ATTEMPTS, attempts.toString())
                .apply()
        }
    }

    /**
     * Stores a matched screenshot/OCR page and suppresses repeated records for the same page.
     * The latest preview/result is still refreshed when a duplicate is observed.
     */
    fun recordCapture(
        context: Context,
        sessionId: Long,
        capture: JSONObject,
    ) {
        if (!isActiveSession(context, sessionId)) return
        val packageName = capture.optString("event_package")
        val rootPackage = capture.optString("root_package")
        val fingerprint = capture.optString("page_fingerprint")
        if (packageName.isBlank() || packageName != rootPackage || fingerprint.isBlank()) return
        synchronized(lock) {
            if (!isActiveSession(context, sessionId)) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val fingerprints = readObject(prefs.getString(KEY_FINGERPRINTS, null))
            val duplicate = fingerprints.optString(packageName) == fingerprint
            capture.put("duplicate", duplicate)
            capture.put("status", if (duplicate) "duplicate" else capture.optString("status", "ocr_ok"))

            val captures = readObject(prefs.getString(KEY_CAPTURES, null))
            captures.put(packageName, capture)
            val attempts = readObject(prefs.getString(KEY_ATTEMPTS, null))
            attempts.put(packageName, capture)
            val edit = prefs.edit()
                .putString(KEY_CAPTURES, captures.toString())
                .putString(KEY_ATTEMPTS, attempts.toString())
            if (!duplicate) {
                val events = readArray(prefs.getString(KEY_EVENTS, null))
                events.put(capture)
                trim(events, MAX_EVENTS)
                fingerprints.put(packageName, fingerprint)
                edit.putString(KEY_EVENTS, events.toString())
                    .putString(KEY_FINGERPRINTS, fingerprints.toString())
            }
            edit.apply()
        }
    }

    fun previewFile(context: Context, packageName: String): File {
        val safeName = packageName.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(File(context.cacheDir, PREVIEW_DIRECTORY), "$safeName.jpg")
    }

    fun state(context: Context): JSONObject {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val captures = readObject(prefs.getString(KEY_CAPTURES, null))
        val diagnostic = readObject(prefs.getString(KEY_DIAGNOSTIC, null))
        return JSONObject().apply {
            put("enabled", prefs.getBoolean(KEY_ENABLED, false))
            put("started_at", prefs.getLong(KEY_STARTED_AT, 0L))
            put("accessibility_running", PermissionAccessibilityService.isRunning)
            put("current_package", PermissionAccessibilityService.currentPackage)
            put("current_app", PermissionAccessibilityService.currentAppName)
            put("current_activity", PermissionAccessibilityService.currentActivity)
            put("current_since", PermissionAccessibilityService.currentSince)
            put("sdk_int", Build.VERSION.SDK_INT)
            put("screenshot_supported_by_sdk", Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
            put("captures", captures)
            put("attempts", readObject(prefs.getString(KEY_ATTEMPTS, null)))
            put("probe_diagnostic", diagnostic.optString("probe_diagnostic"))
            put("poll_foreground_package", diagnostic.optString("poll_foreground_package"))
            put("probe_diagnostic_ts", diagnostic.optLong("ts"))
            // Phase 1 字段保留为同一份本地结果，避免旧探针页/测试在升级瞬间失配。
            put("screenshots", captures)
            put("failures", readArray(prefs.getString(KEY_FAILURES, null)))
            put("events", readArray(prefs.getString(KEY_EVENTS, null)))
        }
    }

    private fun nextSessionId(previous: Long): Long =
        maxOf(System.currentTimeMillis(), previous + 1L)

    private fun eventName(type: Int): String = when (type) {
        android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> "window_state_changed"
        android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> "window_content_changed"
        android.view.accessibility.AccessibilityEvent.TYPE_VIEW_SCROLLED -> "view_scrolled"
        else -> "event_$type"
    }

    private fun trim(values: JSONArray, limit: Int) {
        while (values.length() > limit) values.remove(0)
    }

    private fun deletePreviews(context: Context) {
        val directory = File(context.cacheDir, PREVIEW_DIRECTORY)
        if (directory.exists()) directory.deleteRecursively()
    }

    private fun readArray(raw: String?): JSONArray {
        if (raw.isNullOrBlank()) return JSONArray()
        return try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    private fun readObject(raw: String?): JSONObject {
        if (raw.isNullOrBlank()) return JSONObject()
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            JSONObject()
        }
    }
}
