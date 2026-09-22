package dev.continuum.chat

import android.accessibilityservice.AccessibilityService
import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import java.io.ByteArrayOutputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/// 无障碍服务（权限中心授权项 + 手机工具 v0.2.128）：
/// - 前台应用识别（当前包名/应用名/Activity/停留时长，移植自 Nudge NudgeAccessibilityService.kt）
/// - 步数计数（TYPE_STEP_COUNTER 累计值，get_steps 工具读它算今日步数）
/// - 截屏（Android 14+ takeScreenshot，screenshot_analyze 工具用）
/// - 读屏（read_screen 工具遍历可见文字）
/// - 全局按键（返回/桌面/锁屏）与打开应用（open_app / 切回Continuum Chat）
class PermissionAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "ContinuumAccessibility"
        private const val PROBE_DEBOUNCE_MS = 320L

        // 3 秒把连续滚动时的重型截图/OCR 限制在每包每分钟最多约 20 次，
        // 同时仍能覆盖正常翻页节奏；320ms debounce 继续吸收同一轮 UI 事件突发。
        private const val PROBE_MIN_CAPTURE_INTERVAL_MS = 3_000L
        private const val CHANGPEI_PROBE_POLL_INTERVAL_MS = 4_000L
        private const val USAGE_EVENTS_LOOKBACK_MS = 24L * 60L * 60L * 1_000L
        private const val CHANGPEI_PACKAGE = "net.cpwxx.cpfiction"
        private const val PROBE_SOURCE_EVENT = "event"
        private const val PROBE_SOURCE_POLL = "poll"
        private val READING_PROBE_PACKAGES = setOf(
            "com.jjwxc.reader",
            "net.cpwxx.cpfiction",
        )

        /// 不参与前台应用追踪的系统/输入法/自己。
        val IGNORED_PACKAGES = setOf(
            "com.android.systemui",
            "com.miui.home",
            "com.sohu.inputmethod.sogou",
            "com.baidu.input",
            "com.iflytek.inputmethod",
            "com.google.android.inputmethod.latin",
            "com.miui.notes",
            "com.android.settings",
            "com.miui.globalsearch",
            "com.miui.personalassistant",
            "com.tencent.wetype",
        )

        @Volatile var currentPackage: String = ""
        @Volatile var currentAppName: String = ""
        @Volatile var currentActivity: String = ""
        @Volatile var currentSince: Long = 0L
        @Volatile var isRunning: Boolean = false
        @Volatile var instance: PermissionAccessibilityService? = null
        /// STEP_COUNTER 传感器累计步数（开机起算，get_steps 按日减基准）。
        @Volatile var steps: Long = 0

        private val labelCache = ConcurrentHashMap<String, String>()

        /// 应用包名 → 中文名（缓存，失败回退包名末段）。
        fun appLabel(pkg: String): String {
            labelCache[pkg]?.let { return it }
            val inst = instance
            val label = try {
                if (inst == null) return pkg.substringAfterLast('.')
                val ai = inst.packageManager.getApplicationInfo(pkg, 0)
                val l = ai.loadLabel(inst.packageManager).toString()
                if (l.isNotBlank()) l else null
            } catch (_: Exception) { null }
            val result = label ?: pkg.substringAfterLast('.')
            labelCache[pkg] = result
            return result
        }
    }

    private var stepSensorManager: android.hardware.SensorManager? = null
    private var stepListener: android.hardware.SensorEventListener? = null

    private val probeHandler = Handler(Looper.getMainLooper())
    private var pendingProbeRunnable: Runnable? = null
    private var pendingChangpeiPollRunnable: Runnable? = null
    private val pendingProbeCallbacks = mutableSetOf<Runnable>()
    private var probeCaptureInFlight = false
    private var probeCaptureToken = 0L
    private val lastProbeTextsByPackage = mutableMapOf<String, List<String>>()
    private val lastProbeCaptureStartedAtByPackage = mutableMapOf<String, Long>()
    private val lastValidScreenshotFingerprintByPackage = mutableMapOf<String, String>()
    private var lastUsageEventsQueryAtMillis = 0L
    private var lastUsageForegroundPackage = ""

    override fun onServiceConnected() {
        super.onServiceConnected()
        isRunning = true
        instance = this
        startStepCounter()
        refreshReadingProbeMode()
        Log.d(TAG, "accessibility service connected")
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        instance = null
        resetReadingProbeSession()
        try { stepSensorManager?.unregisterListener(stepListener) } catch (_: Exception) {}
        stepSensorManager = null
        stepListener = null
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val ev = event ?: return
        val pkg = ev.packageName?.toString().orEmpty()
        if (ev.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            pkg.isNotBlank() && pkg !in IGNORED_PACKAGES
        ) {
            currentPackage = pkg
            currentAppName = appLabel(pkg)
            currentActivity = ev.className?.toString() ?: ""
            currentSince = System.currentTimeMillis()
        }
        if (ReadingProbeStore.isEnabled(this)) {
            scheduleReadingProbeCapture(ev)
        }
    }

    override fun onInterrupt() {}

    /**
     * 探针开启时临时订阅正文变化/滚动事件；关闭后恢复原来的窗口切换事件。
     * 这样普通使用Continuum Chat时不会因为技术探针增加无障碍事件负担。
     */
    fun refreshReadingProbeMode() {
        val enabled = ReadingProbeStore.isEnabled(this)
        if (!enabled) resetReadingProbeSession()
        val info = serviceInfo ?: return
        info.eventTypes = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
            if (enabled) {
                AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
                    AccessibilityEvent.TYPE_VIEW_SCROLLED
            } else 0
        info.notificationTimeout = if (enabled) 120L else 100L
        serviceInfo = info
        if (enabled) {
            scheduleChangpeiProbePoll()
        }
    }

    fun resetReadingProbeSession() {
        pendingProbeCallbacks.forEach { probeHandler.removeCallbacks(it) }
        pendingProbeCallbacks.clear()
        pendingProbeRunnable = null
        pendingChangpeiPollRunnable = null
        probeCaptureToken++
        probeCaptureInFlight = false
        lastProbeTextsByPackage.clear()
        lastProbeCaptureStartedAtByPackage.clear()
        lastValidScreenshotFingerprintByPackage.clear()
        lastUsageEventsQueryAtMillis = 0L
        lastUsageForegroundPackage = ""
        ReadingProbeStore.clearDiagnostic(this)
        if (isRunning && instance === this && ReadingProbeStore.isEnabled(this)) {
            scheduleChangpeiProbePoll()
        }
    }

    private fun scheduleChangpeiProbePoll() {
        if (pendingChangpeiPollRunnable != null || !ReadingProbeStore.isEnabled(this)) return
        lateinit var task: Runnable
        task = Runnable {
            pendingProbeCallbacks.remove(task)
            if (pendingChangpeiPollRunnable !== task) return@Runnable
            pendingChangpeiPollRunnable = null
            if (!ReadingProbeStore.isEnabled(this)) return@Runnable
            pollChangpeiReadingProbe()
            scheduleChangpeiProbePoll()
        }
        pendingChangpeiPollRunnable = task
        pendingProbeCallbacks.add(task)
        probeHandler.postDelayed(task, CHANGPEI_PROBE_POLL_INTERVAL_MS)
    }

    private fun pollChangpeiReadingProbe() {
        val sessionId = ReadingProbeStore.sessionId(this)
        if (!ReadingProbeStore.isActiveSession(this, sessionId)) return

        val foreground = recentForegroundPackage()
        ReadingProbeStore.recordPollDiagnostic(
            this,
            sessionId,
            foreground.diagnostic,
            foreground.packageName,
        )
        if (probeCaptureInFlight) return
        if (foreground.packageName != CHANGPEI_PACKAGE) return

        val now = SystemClock.elapsedRealtime()
        val lastCaptureStartedAt = lastProbeCaptureStartedAtByPackage[CHANGPEI_PACKAGE]
        if (lastCaptureStartedAt != null &&
            now - lastCaptureStartedAt < PROBE_MIN_CAPTURE_INTERVAL_MS
        ) return
        lastProbeCaptureStartedAtByPackage[CHANGPEI_PACKAGE] = now

        captureReadingProbeScreenshot(
            sessionId = sessionId,
            eventType = 0,
            eventPackage = CHANGPEI_PACKAGE,
            verifiedRootPackage = CHANGPEI_PACKAGE,
            className = PROBE_SOURCE_POLL,
            attempt = 0,
            elements = org.json.JSONArray(),
            texts = emptyList(),
            stats = ProbeNodeStats(),
            added = emptyList(),
            removed = emptyList(),
            sourceLabel = PROBE_SOURCE_POLL,
            verifyRootBeforeScreenshot = false,
        )
    }

    private fun scheduleReadingProbeCapture(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString().orEmpty()
        if (pkg !in READING_PROBE_PACKAGES) return
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_VIEW_SCROLLED
        ) return

        val eventType = event.eventType
        val className = event.className?.toString().orEmpty()
        val sessionId = ReadingProbeStore.sessionId(this)
        pendingProbeRunnable?.let {
            probeHandler.removeCallbacks(it)
            pendingProbeCallbacks.remove(it)
        }
        val now = SystemClock.elapsedRealtime()
        val cooldownRemaining = lastProbeCaptureStartedAtByPackage[pkg]
            ?.let { (it + PROBE_MIN_CAPTURE_INTERVAL_MS - now).coerceAtLeast(0L) }
            ?: 0L
        pendingProbeRunnable = postProbeCallback(maxOf(PROBE_DEBOUNCE_MS, cooldownRemaining)) {
            captureReadingProbeSnapshot(
                sessionId,
                eventType,
                pkg,
                className,
                0,
            )
        }
    }

    private fun captureReadingProbeSnapshot(
        sessionId: Long,
        eventType: Int,
        eventPackage: String,
        className: String,
        attempt: Int,
    ) {
        if (!ReadingProbeStore.isActiveSession(this, sessionId) ||
            eventPackage !in READING_PROBE_PACKAGES
        ) return
        if (probeCaptureInFlight) return
        if (attempt == 0) {
            val now = SystemClock.elapsedRealtime()
            val remaining = lastProbeCaptureStartedAtByPackage[eventPackage]
                ?.let { (it + PROBE_MIN_CAPTURE_INTERVAL_MS - now).coerceAtLeast(0L) }
                ?: 0L
            if (remaining > 0L) {
                postProbeCallback(remaining) {
                    captureReadingProbeSnapshot(
                        sessionId,
                        eventType,
                        eventPackage,
                        className,
                        attempt,
                    )
                }
                return
            }
            lastProbeCaptureStartedAtByPackage[eventPackage] = now
        }
        val root = rootInActiveWindow
        if (root == null) {
            retryOrRecordProbeFailure(
                sessionId,
                eventType,
                eventPackage,
                "",
                className,
                attempt,
                "root",
                "root_unavailable",
            )
            return
        }

        val elements = org.json.JSONArray()
        val texts = mutableListOf<String>()
        val stats = ProbeNodeStats()
        var rootPackage = ""
        try {
            rootPackage = root.packageName?.toString().orEmpty()
            if (rootPackage == eventPackage) {
                collectProbeElements(root, elements, texts, stats)
            }
        } catch (_: Exception) {
            // 技术探针允许保留已收集到的部分节点。
        } finally {
            try { root.recycle() } catch (_: Exception) {}
        }

        if (rootPackage != eventPackage) {
            retryOrRecordProbeFailure(
                sessionId,
                eventType,
                eventPackage,
                rootPackage,
                className,
                attempt,
                "root",
                "event_root_mismatch",
            )
            return
        }

        val previous = lastProbeTextsByPackage[eventPackage].orEmpty().toSet()
        val current = texts.toSet()
        val added = (current - previous).take(20)
        val removed = (previous - current).take(20)
        captureReadingProbeScreenshot(
            sessionId,
            eventType,
            eventPackage,
            rootPackage,
            className,
            attempt,
            elements,
            texts,
            stats,
            added,
            removed,
        )
    }

    private data class ProbeNodeStats(
        var nodeCount: Int = 0,
        var textNodeCount: Int = 0,
        var visibleTextCount: Int = 0,
        var capturedChars: Int = 0,
        var truncated: Boolean = false,
    )

    private fun collectProbeElements(
        node: AccessibilityNodeInfo,
        elements: org.json.JSONArray,
        texts: MutableList<String>,
        stats: ProbeNodeStats,
    ) {
        if (stats.nodeCount >= 600) {
            stats.truncated = true
            return
        }
        stats.nodeCount++
        val text = try { node.text?.toString()?.trim().orEmpty() } catch (_: Exception) { "" }
        val desc = try { node.contentDescription?.toString()?.trim().orEmpty() } catch (_: Exception) { "" }
        val value = listOf(text, desc).filter { it.isNotBlank() }.distinct().joinToString(" | ")
        if (value.isNotBlank()) {
            stats.textNodeCount++
            val visible = try { node.isVisibleToUser } catch (_: Exception) { false }
            if (visible) stats.visibleTextCount++
            if (elements.length() < 220 && stats.capturedChars < 12_000) {
                val clipped = value.take(800)
                stats.capturedChars += clipped.length
                val rect = Rect()
                try { node.getBoundsInScreen(rect) } catch (_: Exception) {}
                elements.put(org.json.JSONObject().apply {
                    put("index", elements.length())
                    put("text", clipped)
                    put("visible", visible)
                    put("class", try { node.className?.toString().orEmpty() } catch (_: Exception) { "" })
                    put("view_id", try { node.viewIdResourceName.orEmpty() } catch (_: Exception) { "" })
                    put("bounds", "${rect.left},${rect.top},${rect.right},${rect.bottom}")
                })
                texts.add(clipped)
            } else {
                stats.truncated = true
            }
        }

        val childCount = try { node.childCount } catch (_: Exception) { 0 }
        for (i in 0 until childCount) {
            if (stats.nodeCount >= 600) {
                stats.truncated = true
                break
            }
            val child = try { node.getChild(i) } catch (_: Exception) { null } ?: continue
            try {
                collectProbeElements(child, elements, texts, stats)
            } catch (_: Exception) {
                // 单个子树异常不影响剩余节点。
            } finally {
                try { child.recycle() } catch (_: Exception) {}
            }
        }
    }

    private fun captureReadingProbeScreenshot(
        sessionId: Long,
        eventType: Int,
        eventPackage: String,
        verifiedRootPackage: String,
        className: String,
        attempt: Int,
        elements: org.json.JSONArray,
        texts: List<String>,
        stats: ProbeNodeStats,
        added: List<String>,
        removed: List<String>,
        sourceLabel: String = PROBE_SOURCE_EVENT,
        verifyRootBeforeScreenshot: Boolean = true,
    ) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ReadingProbeStore.recordFailure(
                this,
                sessionId,
                eventPackage,
                verifiedRootPackage,
                eventType,
                className,
                "screenshot",
                "android_lt_14",
                probeSourceExtra(sourceLabel),
            )
            return
        }
        val requestRootPackage = if (verifyRootBeforeScreenshot) activeRootPackage() else verifiedRootPackage
        if (verifyRootBeforeScreenshot && requestRootPackage != verifiedRootPackage) {
            retryOrRecordProbeFailure(
                sessionId,
                eventType,
                eventPackage,
                requestRootPackage,
                className,
                attempt,
                "screenshot",
                "root_changed_before_screenshot",
            )
            return
        }
        val captureToken = beginProbeCapture()
        try {
            takeScreenshot(
                0,
                mainExecutor,
                object : TakeScreenshotCallback {
                    override fun onSuccess(result: ScreenshotResult) {
                        handleReadingProbeScreenshot(
                            result,
                            sessionId,
                            eventType,
                            eventPackage,
                            verifiedRootPackage,
                            className,
                            attempt,
                            elements,
                            texts,
                            stats,
                            added,
                            removed,
                            captureToken,
                            sourceLabel,
                        )
                    }

                    override fun onFailure(errorCode: Int) {
                        finishProbeCapture(captureToken)
                        ReadingProbeStore.recordFailure(
                            this@PermissionAccessibilityService,
                            sessionId,
                            eventPackage,
                            verifiedRootPackage,
                            eventType,
                            className,
                            "screenshot",
                            "error_code:$errorCode",
                            probeSourceExtra(sourceLabel),
                        )
                    }
                },
            )
        } catch (e: Exception) {
            finishProbeCapture(captureToken)
            ReadingProbeStore.recordFailure(
                this,
                sessionId,
                eventPackage,
                verifiedRootPackage,
                eventType,
                className,
                "screenshot",
                "exception:${e.javaClass.simpleName}:${e.message.orEmpty()}",
                probeSourceExtra(sourceLabel),
            )
        }
    }

    private fun handleReadingProbeScreenshot(
        result: ScreenshotResult,
        sessionId: Long,
        eventType: Int,
        eventPackage: String,
        verifiedRootPackage: String,
        className: String,
        attempt: Int,
        elements: org.json.JSONArray,
        texts: List<String>,
        stats: ProbeNodeStats,
        added: List<String>,
        removed: List<String>,
        captureToken: Long,
        sourceLabel: String,
    ) {
        val bitmap = copyScreenshotBitmap(result)
        if (bitmap == null) {
            finishProbeCapture(captureToken)
            ReadingProbeStore.recordFailure(
                this,
                sessionId,
                eventPackage,
                verifiedRootPackage,
                eventType,
                className,
                "screenshot",
                "bitmap_copy_failed",
                probeSourceExtra(sourceLabel),
            )
            return
        }
        if (!ReadingProbeStore.isActiveSession(this, sessionId)) {
            bitmap.recycle()
            finishProbeCapture(captureToken)
            return
        }
        val callbackPackage = if (sourceLabel == PROBE_SOURCE_POLL) {
            val foreground = recentForegroundPackage()
            ReadingProbeStore.recordPollDiagnostic(
                this,
                sessionId,
                foreground.diagnostic,
                foreground.packageName,
            )
            foreground.packageName
        } else {
            activeRootPackage()
        }
        if (callbackPackage != verifiedRootPackage) {
            bitmap.recycle()
            finishProbeCapture(captureToken)
            if (sourceLabel == PROBE_SOURCE_EVENT) {
                retryOrRecordProbeFailure(
                    sessionId,
                    eventType,
                    eventPackage,
                    callbackPackage,
                    className,
                    attempt,
                    "screenshot",
                    "root_changed_during_screenshot",
                )
            }
            return
        }

        val changpeiScreenshotFingerprint = try {
            if (eventPackage == CHANGPEI_PACKAGE) screenshotFingerprint(bitmap) else null
        } catch (e: Exception) {
            null.also {
                ReadingProbeStore.recordFailure(
                    this,
                    sessionId,
                    eventPackage,
                    verifiedRootPackage,
                    eventType,
                    className,
                    "fingerprint",
                    "${e.javaClass.simpleName}:${e.message.orEmpty()}",
                    probeSourceExtra(sourceLabel),
                )
            }
        }
        if (sourceLabel == PROBE_SOURCE_POLL && changpeiScreenshotFingerprint == null) {
            bitmap.recycle()
            finishProbeCapture(captureToken)
            return
        }
        if (sourceLabel == PROBE_SOURCE_POLL &&
            lastValidScreenshotFingerprintByPackage[eventPackage] == changpeiScreenshotFingerprint
        ) {
            bitmap.recycle()
            finishProbeCapture(captureToken)
            return
        }

        val preview = try {
            if (sourceLabel == PROBE_SOURCE_EVENT) saveReadingProbePreview(eventPackage, bitmap) else null
        } catch (e: Exception) {
            null.also {
                ReadingProbeStore.recordFailure(
                    this,
                    sessionId,
                    eventPackage,
                    verifiedRootPackage,
                    eventType,
                    className,
                    "preview",
                    "${e.javaClass.simpleName}:${e.message.orEmpty()}",
                    probeSourceExtra(sourceLabel),
                )
            }
        }
        if (sourceLabel == PROBE_SOURCE_EVENT && preview == null) {
            bitmap.recycle()
            finishProbeCapture(captureToken)
            return
        }

        val recognizer = try {
            TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
        } catch (e: Exception) {
            bitmap.recycle()
            finishProbeCapture(captureToken)
            ReadingProbeStore.recordFailure(
                this,
                sessionId,
                eventPackage,
                verifiedRootPackage,
                eventType,
                className,
                "ocr",
                "recognizer_create:${e.javaClass.simpleName}:${e.message.orEmpty()}",
                probeSourceExtra(sourceLabel),
            )
            return
        }
        try {
            recognizer.process(InputImage.fromBitmap(bitmap, 0))
                .addOnSuccessListener { resultText ->
                    if (!ReadingProbeStore.isActiveSession(this, sessionId)) return@addOnSuccessListener
                    val completedPreview = preview ?: try {
                        saveReadingProbePreview(eventPackage, bitmap)
                    } catch (e: Exception) {
                        ReadingProbeStore.recordFailure(
                            this,
                            sessionId,
                            eventPackage,
                            verifiedRootPackage,
                            eventType,
                            className,
                            "preview",
                            "${e.javaClass.simpleName}:${e.message.orEmpty()}",
                            probeSourceExtra(sourceLabel),
                        )
                        return@addOnSuccessListener
                    }
                    val fullText = resultText.text.trim()
                    val capturedText = fullText.take(12_000)
                    val normalizedText = fullText.replace(Regex("\\s+"), " ").trim()
                    val pageFingerprint = if (normalizedText.isNotEmpty()) {
                        "text:${sha256(normalizedText.toByteArray(Charsets.UTF_8))}"
                    } else {
                        "image:${completedPreview.fingerprint}"
                    }
                    ReadingProbeStore.recordCapture(this, sessionId, org.json.JSONObject().apply {
                        put("ts", System.currentTimeMillis())
                        put("event_type", eventType)
                        put(
                            "event_name",
                            if (sourceLabel == PROBE_SOURCE_POLL) PROBE_SOURCE_POLL else probeEventName(eventType),
                        )
                        put("capture_source", sourceLabel)
                        put("event_package", eventPackage)
                        put("root_package", verifiedRootPackage)
                        put("package_match", true)
                        put("package", eventPackage)
                        put("app", appLabel(eventPackage))
                        put("class_name", className)
                        put("activity", currentActivity)
                        put("node_count", stats.nodeCount)
                        put("text_node_count", stats.textNodeCount)
                        put("visible_text_count", stats.visibleTextCount)
                        put("truncated", stats.truncated)
                        put("added", org.json.JSONArray(added))
                        put("removed", org.json.JSONArray(removed))
                        put("elements", elements)
                        put("screenshot_ok", true)
                        put("preview_path", completedPreview.path)
                        put("screenshot_fingerprint", completedPreview.fingerprint)
                        put("ocr_engine", "mlkit_chinese_bundled")
                        put("ocr_text", capturedText)
                        put("ocr_char_count", capturedText.length)
                        put("ocr_total_char_count", fullText.length)
                        put("ocr_truncated", fullText.length > capturedText.length)
                        put("ocr_error", "")
                        put("page_fingerprint", pageFingerprint)
                        put("fingerprint", pageFingerprint)
                        put("status", if (fullText.isEmpty()) "ocr_empty" else "ocr_ok")
                    })
                    lastProbeTextsByPackage[eventPackage] = texts
                    if (changpeiScreenshotFingerprint != null) {
                        lastValidScreenshotFingerprintByPackage[eventPackage] =
                            changpeiScreenshotFingerprint
                    }
                }
                .addOnFailureListener { error ->
                    ReadingProbeStore.recordFailure(
                        this,
                        sessionId,
                        eventPackage,
                        verifiedRootPackage,
                        eventType,
                        className,
                        "ocr",
                        "${error.javaClass.simpleName}:${error.message.orEmpty()}",
                        org.json.JSONObject().apply {
                            put("screenshot_ok", true)
                            put("capture_source", sourceLabel)
                            put("event_name", sourceLabel)
                            if (preview != null) put("preview_path", preview.path)
                            put(
                                "screenshot_fingerprint",
                                preview?.fingerprint ?: changpeiScreenshotFingerprint.orEmpty(),
                            )
                            put("ocr_engine", "mlkit_chinese_bundled")
                            put("ocr_text", "")
                            put("ocr_char_count", 0)
                            put("ocr_error", error.message.orEmpty())
                        },
                    )
                }
                .addOnCompleteListener {
                    try {
                        recognizer.close()
                    } catch (_: Exception) {
                    } finally {
                        bitmap.recycle()
                        finishProbeCapture(captureToken)
                    }
                }
        } catch (e: Exception) {
            try { recognizer.close() } catch (_: Exception) {}
            bitmap.recycle()
            finishProbeCapture(captureToken)
            ReadingProbeStore.recordFailure(
                this,
                sessionId,
                eventPackage,
                verifiedRootPackage,
                eventType,
                className,
                "ocr",
                "${e.javaClass.simpleName}:${e.message.orEmpty()}",
                org.json.JSONObject().apply {
                    put("screenshot_ok", true)
                    put("capture_source", sourceLabel)
                    put("event_name", sourceLabel)
                    if (preview != null) put("preview_path", preview.path)
                    put(
                        "screenshot_fingerprint",
                        preview?.fingerprint ?: changpeiScreenshotFingerprint.orEmpty(),
                    )
                    put("ocr_engine", "mlkit_chinese_bundled")
                    put("ocr_text", "")
                    put("ocr_char_count", 0)
                    put("ocr_error", e.message.orEmpty())
                },
            )
        }
    }

    private fun beginProbeCapture(): Long {
        probeCaptureToken++
        probeCaptureInFlight = true
        return probeCaptureToken
    }

    private fun finishProbeCapture(captureToken: Long) {
        if (captureToken == probeCaptureToken) {
            probeCaptureInFlight = false
        }
    }

    private fun postProbeCallback(delayMillis: Long, action: () -> Unit): Runnable {
        lateinit var task: Runnable
        task = Runnable {
            pendingProbeCallbacks.remove(task)
            if (pendingProbeRunnable === task) pendingProbeRunnable = null
            action()
        }
        pendingProbeCallbacks.add(task)
        probeHandler.postDelayed(task, delayMillis)
        return task
    }

    private data class SavedPreview(val path: String, val fingerprint: String)

    private fun saveReadingProbePreview(packageName: String, bitmap: Bitmap): SavedPreview {
        val stream = ByteArrayOutputStream()
        check(bitmap.compress(Bitmap.CompressFormat.JPEG, 88, stream)) { "jpeg_compress_failed" }
        val bytes = stream.toByteArray()
        check(bytes.isNotEmpty()) { "jpeg_empty" }
        val file = ReadingProbeStore.previewFile(this, packageName)
        file.parentFile?.mkdirs()
        val temporary = java.io.File(file.parentFile, "${file.name}.tmp")
        FileOutputStream(temporary).use { it.write(bytes) }
        if (!temporary.renameTo(file)) {
            temporary.copyTo(file, overwrite = true)
            temporary.delete()
        }
        return SavedPreview(file.absolutePath, sha256(bytes))
    }

    private fun screenshotFingerprint(bitmap: Bitmap): String {
        val thumbnail = Bitmap.createScaledBitmap(bitmap, 96, 96, false)
        return try {
            val pixels = IntArray(thumbnail.width * thumbnail.height)
            thumbnail.getPixels(
                pixels,
                0,
                thumbnail.width,
                0,
                0,
                thumbnail.width,
                thumbnail.height,
            )
            val bytes = java.nio.ByteBuffer.allocate((pixels.size + 2) * Int.SIZE_BYTES)
                .putInt(bitmap.width)
                .putInt(bitmap.height)
            pixels.forEach(bytes::putInt)
            sha256(bytes.array())
        } finally {
            if (thumbnail !== bitmap) thumbnail.recycle()
        }
    }

    private fun probeSourceExtra(sourceLabel: String): org.json.JSONObject? =
        if (sourceLabel == PROBE_SOURCE_POLL) {
            org.json.JSONObject().apply {
                put("event_name", PROBE_SOURCE_POLL)
                put("capture_source", PROBE_SOURCE_POLL)
            }
        } else {
            null
        }

    private fun copyScreenshotBitmap(result: ScreenshotResult): Bitmap? {
        val buffer = result.hardwareBuffer ?: return null
        return try {
            val colorSpace = result.colorSpace ?: ColorSpace.get(ColorSpace.Named.SRGB)
            Bitmap.wrapHardwareBuffer(buffer, colorSpace)
                ?.copy(Bitmap.Config.ARGB_8888, false)
        } catch (_: Exception) {
            null
        } finally {
            try { buffer.close() } catch (_: Exception) {}
        }
    }

    private fun activeRootPackage(): String {
        val root = rootInActiveWindow ?: return ""
        return try {
            root.packageName?.toString().orEmpty()
        } catch (_: Exception) {
            ""
        } finally {
            try { root.recycle() } catch (_: Exception) {}
        }
    }

    private data class UsageForegroundResult(
        val packageName: String = "",
        val diagnostic: String,
    )

    private fun recentForegroundPackage(): UsageForegroundResult {
        return try {
            if (!hasUsageStatsAccess()) {
                lastUsageForegroundPackage = ""
                return UsageForegroundResult(diagnostic = "usage_stats_denied")
            }
            val manager = getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                ?: return UsageForegroundResult(diagnostic = "usage_stats_unavailable")
            val endTime = System.currentTimeMillis()
            val beginTime = if (lastUsageEventsQueryAtMillis > 0L) {
                (lastUsageEventsQueryAtMillis - 1_000L).coerceAtLeast(endTime - USAGE_EVENTS_LOOKBACK_MS)
            } else {
                endTime - USAGE_EVENTS_LOOKBACK_MS
            }
            val events = manager.queryEvents(beginTime, endTime)
            val event = UsageEvents.Event()
            var latestTimestamp = Long.MIN_VALUE
            var latestPackage = ""
            var latestEventIsForeground: Boolean? = null
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val isForeground = event.eventType == UsageEvents.Event.ACTIVITY_RESUMED ||
                    event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND
                val isBackground = event.eventType == UsageEvents.Event.ACTIVITY_PAUSED ||
                    event.eventType == UsageEvents.Event.MOVE_TO_BACKGROUND
                if ((isForeground || isBackground) && event.timeStamp >= latestTimestamp) {
                    latestPackage = event.packageName.orEmpty()
                    latestTimestamp = event.timeStamp
                    latestEventIsForeground = isForeground
                }
            }
            lastUsageEventsQueryAtMillis = endTime
            if (latestEventIsForeground == true && latestPackage.isNotBlank()) {
                lastUsageForegroundPackage = latestPackage
            } else if (latestEventIsForeground == false) {
                lastUsageForegroundPackage = ""
            }
            if (lastUsageForegroundPackage.isNotBlank()) {
                UsageForegroundResult(lastUsageForegroundPackage, "usage_stats_ok")
            } else {
                UsageForegroundResult(diagnostic = "usage_stats_no_result")
            }
        } catch (_: SecurityException) {
            lastUsageForegroundPackage = ""
            UsageForegroundResult(diagnostic = "usage_stats_denied")
        } catch (error: Exception) {
            UsageForegroundResult(
                diagnostic = "usage_stats_error:${error.javaClass.simpleName}",
            )
        }
    }

    private fun hasUsageStatsAccess(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager ?: return false
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName,
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName,
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun retryOrRecordProbeFailure(
        sessionId: Long,
        eventType: Int,
        eventPackage: String,
        rootPackage: String,
        className: String,
        attempt: Int,
        stage: String,
        error: String,
    ) {
        if (attempt < 2 && ReadingProbeStore.isActiveSession(this, sessionId)) {
            postProbeCallback(220L * (attempt + 1)) {
                captureReadingProbeSnapshot(
                    sessionId,
                    eventType,
                    eventPackage,
                    className,
                    attempt + 1,
                )
            }
            return
        }
        ReadingProbeStore.recordFailure(
            this,
            sessionId,
            eventPackage,
            rootPackage,
            eventType,
            className,
            stage,
            error,
        )
    }

    private fun probeEventName(type: Int): String = when (type) {
        AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> "window_state_changed"
        AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> "window_content_changed"
        AccessibilityEvent.TYPE_VIEW_SCROLLED -> "view_scrolled"
        else -> "event_$type"
    }

    private fun sha256(bytes: ByteArray): String = try {
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
            .take(20)
    } catch (_: Exception) {
        bytes.contentHashCode().toString(16)
    }

    /// 步数计数：STEP_COUNTER 累计值直接进 steps（参考 Nudge NudgeAccessibilityService.startStepCounter）。
    private fun startStepCounter() {
        stepSensorManager = getSystemService(SENSOR_SERVICE) as android.hardware.SensorManager
        val sensor = stepSensorManager?.getDefaultSensor(android.hardware.Sensor.TYPE_STEP_COUNTER) ?: return
        stepListener = object : android.hardware.SensorEventListener {
            override fun onSensorChanged(event: android.hardware.SensorEvent?) {
                if (event != null && event.values.isNotEmpty()) {
                    steps = event.values[0].toLong()
                }
            }
            override fun onAccuracyChanged(sensor: android.hardware.Sensor?, accuracy: Int) {}
        }
        try {
            stepSensorManager?.registerListener(stepListener, sensor, android.hardware.SensorManager.SENSOR_DELAY_NORMAL)
        } catch (_: SecurityException) {
            // 未授权 ACTIVITY_RECOGNITION：步数保持 0，get_steps 返回未授权提示
        }
    }

    // ── 截屏（Android 14+，参考 Nudge takeScreenshotAndAnalyze 的截屏部分） ──

    fun takeScreenshotBase64(callback: (String) -> Unit) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            callback("{\"error\":\"需要Android 14+才能截屏（当前 ${android.os.Build.VERSION.SDK_INT}）\"}")
            return
        }
        try {
            takeScreenshot(
                0,
                java.util.concurrent.Executors.newSingleThreadExecutor(),
                object : TakeScreenshotCallback {
                    override fun onSuccess(result: ScreenshotResult) {
                        try {
                            val hb = result.hardwareBuffer
                            if (hb == null) {
                                callback("{\"error\":\"hardwareBuffer为null\"}")
                                return
                            }
                            val cs = android.graphics.ColorSpace.get(android.graphics.ColorSpace.Named.SRGB)
                            val bitmap = android.graphics.Bitmap.wrapHardwareBuffer(hb, cs)
                                ?: run { hb.close(); callback("{\"error\":\"Bitmap转换失败\"}"); return }
                            val stream = java.io.ByteArrayOutputStream()
                            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, stream)
                            val bytes = stream.toByteArray()
                            if (bytes.isEmpty()) {
                                hb.close()
                                callback("{\"error\":\"压缩后数据为空\"}")
                                return
                            }
                            val base64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
                            callback(base64)
                            hb.close()
                        } catch (e: Exception) {
                            callback("{\"error\":\"${e.message}\"}")
                        }
                    }
                    override fun onFailure(errorCode: Int) {
                        callback("{\"error\":\"截屏失败，错误码: $errorCode\"}")
                    }
                }
            )
        } catch (e: Exception) {
            callback("{\"error\":\"${e.message}\"}")
        }
    }

    // ── 读屏（参考 Nudge readScreen / collectTexts） ──
    // v0.2.130：遍历全程 try-catch（节点被系统并发回收/安全字段等异常不中断整棵树），
    // root 为空 / 一个文字都没读到都返回明确中文提示，不再静默返回空结果。
    // v0.2.131：root 拿不到 / 收集文字为空时自动重试（最多 3 次，间隔 400ms，
    // 总重试 <2s，给无障碍服务时间拿活跃窗口 / 等界面稳定），重试仍失败才报错，
    // 并区分"无障碍未就绪"与"当前界面确实无文字"。调用方 NudgeTools 在后台线程执行，sleep 安全。

    fun readScreen(): String {
        val maxAttempts = 3
        val retryDelayMs = 400L
        var lastAttemptRootMissing = false
        for (attempt in 1..maxAttempts) {
            val root = rootInActiveWindow
            if (root == null) {
                lastAttemptRootMissing = true
                if (attempt < maxAttempts) {
                    try { Thread.sleep(retryDelayMs) } catch (_: InterruptedException) {}
                }
                continue
            }
            lastAttemptRootMissing = false
            val texts = mutableListOf<String>()
            try {
                collectTexts(root, texts)
            } catch (_: Exception) {
                // 个别分支异常不影响已收集内容
            } finally {
                try { root.recycle() } catch (_: Exception) {}
            }
            if (texts.isNotEmpty()) {
                val arr = org.json.JSONArray()
                val seen = HashSet<String>()
                for (t in texts) {
                    if (t.isNotBlank() && seen.add(t)) arr.put(t)
                }
                return org.json.JSONObject().apply {
                    put("elements", arr)
                    put("count", arr.length())
                }.toString()
            }
            // 本轮没读到文字：给界面一点时间稳定后再试
            if (attempt < maxAttempts) {
                try { Thread.sleep(retryDelayMs) } catch (_: InterruptedException) {}
            }
        }
        return if (lastAttemptRootMissing) {
            """{"error":"无法获取屏幕内容：无障碍未就绪，请到权限中心开启Continuum Chat无障碍后再试（已自动重试）"}"""
        } else {
            """{"error":"当前界面确实没有文字内容（已自动重试，无障碍服务正常但界面没有可读文字）"}"""
        }
    }

    private fun collectTexts(node: AccessibilityNodeInfo, collector: MutableList<String>) {
        try {
            val text = node.text?.toString()?.trim()
            val desc = node.contentDescription?.toString()?.trim()
            if (!text.isNullOrEmpty()) collector.add(text)
            if (!desc.isNullOrEmpty() && desc != text) collector.add(desc)
        } catch (_: Exception) {
            // 单个节点读不到（已被回收/安全字段）就跳过，不中断
        }
        val childCount = try { node.childCount } catch (_: Exception) { 0 }
        for (i in 0 until childCount) {
            val child = try { node.getChild(i) } catch (_: Exception) { null } ?: continue
            try {
                collectTexts(child, collector)
            } catch (_: Exception) {
                // 子树异常不影响兄弟节点
            } finally {
                try { child.recycle() } catch (_: Exception) {}
            }
        }
    }

    // ── 打开应用（参考 Nudge openApp / findAndClickApp） ──

    fun openApp(pkg: String): String {
        // 1. 直接拉起（QUERY_ALL_PACKAGES 已声明，大部分应用能直启）
        try {
            val intent = packageManager.getLaunchIntentForPackage(pkg)
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return "{\"success\":true,\"package\":\"$pkg\",\"method\":\"direct\"}"
            }
        } catch (_: Exception) {}

        // 2. 包名 → 应用名（桌面图标文本）
        var appName = ""
        try {
            val ai = packageManager.getApplicationInfo(pkg, 0)
            val label = ai.loadLabel(packageManager).toString()
            if (label.isNotBlank()) appName = label
        } catch (_: Exception) {}
        if (appName.isEmpty()) return "{\"error\":\"未找到应用 $pkg\"}"

        // 3. 回桌面按应用名找图标点开
        return if (findAndClickApp(appName)) {
            "{\"success\":true,\"package\":\"$pkg\",\"app_name\":\"$appName\",\"method\":\"desktop\"}"
        } else {
            "{\"error\":\"桌面未找到: $appName\"}"
        }
    }

    /// 切回Continuum Chat（switch_to_continuum）：直接拉起自己 App 到前台（REORDER_TO_FRONT）。
    fun switchToContinuum(): Boolean {
        return try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent == null) return false
            intent.addFlags(
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK
            )
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /// 回桌面按应用名找图标点击（最多翻 3 页桌面）。
    private fun findAndClickApp(appName: String): Boolean {
        performGlobalAction(GLOBAL_ACTION_HOME)
        Thread.sleep(700)
        for (page in 0 until 3) {
            val root = rootInActiveWindow ?: continue
            try {
                val nodes = root.findAccessibilityNodeInfosByText(appName)
                for (node in nodes) {
                    try {
                        if (node.isClickable) {
                            node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                            return true
                        }
                        var p = node.parent
                        var depth = 0
                        while (p != null && depth < 5) {
                            if (p.isClickable) {
                                p.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                                p.recycle()
                                return true
                            }
                            val next = p.parent
                            p.recycle()
                            p = next
                            depth++
                        }
                    } finally {
                        try { node.recycle() } catch (_: Exception) {}
                    }
                }
            } finally {
                try { root.recycle() } catch (_: Exception) {}
            }
            // 左滑翻页
            val path = android.graphics.Path().apply {
                moveTo(900f, 1000f)
                lineTo(200f, 1000f)
            }
            val stroke = android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, 300)
            val builder = android.accessibilityservice.GestureDescription.Builder().addStroke(stroke)
            val latch = java.util.concurrent.CountDownLatch(1)
            dispatchGesture(builder.build(), object : GestureResultCallback() {
                override fun onCompleted(gd: android.accessibilityservice.GestureDescription?) { latch.countDown() }
                override fun onCancelled(gd: android.accessibilityservice.GestureDescription?) { latch.countDown() }
            }, null)
            latch.await(300, java.util.concurrent.TimeUnit.MILLISECONDS)
            Thread.sleep(400)
        }
        return false
    }

}
