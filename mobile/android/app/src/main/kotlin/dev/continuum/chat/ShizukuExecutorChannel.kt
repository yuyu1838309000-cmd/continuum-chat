package dev.continuum.chat

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.graphics.PixelFormat
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import rikka.shizuku.Shizuku

/**
 * UI-only Phase 1 bridge for Shizuku state and an app-owned virtual display.
 *
 * The app owns only the ImageReader. A narrow Shizuku UserService creates the
 * trusted virtual display as shell, launches the resolved Activity, and owns the
 * display lifecycle; no arbitrary shell command surface is exposed to Dart.
 */
class ShizukuExecutorChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val frameThread = HandlerThread("continuum-virtual-display-probe").apply { start() }
    private val frameHandler = Handler(frameThread.looper)
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionTimeout: Runnable? = null
    private var pendingProbeResult: MethodChannel.Result? = null
    private var activeProbe: ActiveProbe? = null
    private var launchService: IShizukuLaunchService? = null
    private var launchServiceBinding = false
    private var pendingPrivilegedLaunch: PendingPrivilegedLaunch? = null

    private val userServiceArgs = Shizuku.UserServiceArgs(
        ComponentName(context, ShizukuLaunchUserService::class.java),
    ).daemon(false)
        .tag(USER_SERVICE_TAG)
        .version(USER_SERVICE_VERSION)
        .processNameSuffix("shizuku_launch")
    private val userServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            launchServiceBinding = false
            launchService = IShizukuLaunchService.Stub.asInterface(binder)
            executePendingPrivilegedLaunch()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            launchServiceBinding = false
            launchService = null
            failPendingPrivilegedLaunch("Shizuku UserService 已断开")
        }
    }

    private val binderReceivedListener = Shizuku.OnBinderReceivedListener {
        completePermissionIfGranted()
    }
    private val binderDeadListener = Shizuku.OnBinderDeadListener {
        completePendingPermission("Shizuku binder 已断开")
        launchServiceBinding = false
        launchService = null
        failPendingPrivilegedLaunch("Shizuku binder 已断开")
    }
    private val permissionResultListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, _ ->
            if (requestCode == PERMISSION_REQUEST_CODE) {
                completePendingPermission()
            }
        }

    init {
        Shizuku.addBinderReceivedListenerSticky(binderReceivedListener)
        Shizuku.addBinderDeadListener(binderDeadListener)
        Shizuku.addRequestPermissionResultListener(permissionResultListener)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "requestPermission" -> requestPermission(result)
                "probeVirtualDisplay" -> {
                    val arguments = call.arguments as? Map<*, *>
                    probeVirtualDisplay(arguments?.get("package")?.toString(), result)
                }
                "closeProbe" -> closeProbe(result)
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        Shizuku.removeBinderReceivedListener(binderReceivedListener)
        Shizuku.removeBinderDeadListener(binderDeadListener)
        Shizuku.removeRequestPermissionResultListener(permissionResultListener)
        completePendingPermission("原生通道已关闭")
        activeProbe?.let { probe ->
            pendingProbeResult?.success(probeResult(probe, "原生通道已关闭"))
            pendingProbeResult = null
            releaseProbe(probe)
        }
        unbindLaunchService()
        frameThread.quitSafely()
    }

    private fun status(error: String? = null): Map<String, Any?> {
        val binderAvailable = try {
            Shizuku.pingBinder()
        } catch (_: RuntimeException) {
            false
        }
        var authorized = false
        var permissionBlocked = false
        var serverUid: Int? = null
        var apiVersion: Int? = null
        var statusError = error
        if (binderAvailable) {
            try {
                authorized = Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                permissionBlocked = !authorized && Shizuku.shouldShowRequestPermissionRationale()
                serverUid = Shizuku.getUid().takeIf { it >= 0 }
                apiVersion = Shizuku.getVersion().takeIf { it >= 0 }
            } catch (exception: RuntimeException) {
                statusError = statusError ?: exception.message ?: "读取 Shizuku 状态失败"
            }
        }
        val serverMode = when (serverUid) {
            0 -> "root"
            2000 -> "shell"
            null -> "unknown"
            else -> "uid:$serverUid"
        }
        return linkedMapOf(
            "binderAvailable" to binderAvailable,
            "authorized" to authorized,
            "canRequestPermission" to
                (binderAvailable && !authorized && !permissionBlocked && !Shizuku.isPreV11()),
            "permissionBlocked" to permissionBlocked,
            "serverUid" to serverUid,
            "serverMode" to serverMode,
            "apiVersion" to apiVersion,
            "probeActive" to (activeProbe != null),
            "error" to statusError,
        )
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val current = status()
        if (current["binderAvailable"] != true) {
            result.success(status("Shizuku 未运行或 binder 尚未连接"))
            return
        }
        if (current["authorized"] == true) {
            result.success(current)
            return
        }
        if (current["canRequestPermission"] != true) {
            result.success(status("授权请求已被拒绝，请在 Shizuku 中重新允许Continuum Chat"))
            return
        }
        if (pendingPermissionResult != null) {
            result.success(status("已有一次 Shizuku 授权请求等待处理"))
            return
        }
        pendingPermissionResult = result
        val timeout = Runnable { completePendingPermission("等待 Shizuku 授权结果超时") }
        pendingPermissionTimeout = timeout
        mainHandler.postDelayed(timeout, PERMISSION_TIMEOUT_MS)
        try {
            Shizuku.requestPermission(PERMISSION_REQUEST_CODE)
        } catch (exception: RuntimeException) {
            completePendingPermission(exception.message ?: "无法发起 Shizuku 授权")
        }
    }

    private fun completePermissionIfGranted() {
        if (pendingPermissionResult == null) return
        val current = status()
        if (current["authorized"] == true) completePendingPermission()
    }

    private fun completePendingPermission(error: String? = null) {
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        pendingPermissionTimeout?.let(mainHandler::removeCallbacks)
        pendingPermissionTimeout = null
        result.success(status(error))
    }

    private fun probeVirtualDisplay(requestedPackage: String?, result: MethodChannel.Result) {
        val packageName = requestedPackage?.trim().orEmpty().ifEmpty { DEFAULT_TARGET_PACKAGE }
        if (!PACKAGE_NAME.matches(packageName)) {
            result.success(emptyProbeResult(packageName, "目标包名格式无效"))
            return
        }
        val currentStatus = status()
        if (currentStatus["binderAvailable"] != true || currentStatus["authorized"] != true) {
            result.success(emptyProbeResult(packageName, "需要先连接并授权 Shizuku"))
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(emptyProbeResult(packageName, "第二屏启动需要 Android 8.0 或更高版本"))
            return
        }
        if (!context.packageManager.hasSystemFeature(
                PackageManager.FEATURE_ACTIVITIES_ON_SECONDARY_DISPLAYS,
            )
        ) {
            result.success(emptyProbeResult(packageName, "系统未声明支持在第二屏运行 Activity"))
            return
        }
        if (activeProbe != null) {
            result.success(probeResult(activeProbe!!, "已有第二屏探针，请先关闭"))
            return
        }

        val launchIntent = resolveLaunchIntent(packageName)
        val targetActivity = launchIntent?.resolveActivity(context.packageManager)
        if (targetActivity == null) {
            result.success(emptyProbeResult(packageName, "未找到可启动的目标 App"))
            return
        }

        var imageReader: ImageReader? = null
        try {
            imageReader = ImageReader.newInstance(
                PROBE_WIDTH,
                PROBE_HEIGHT,
                PixelFormat.RGBA_8888,
                MAX_IMAGES,
            )
            val probe = ActiveProbe(packageName, imageReader)
            activeProbe = probe
            pendingProbeResult = result
            imageReader.setOnImageAvailableListener(
                { reader ->
                    val image = try {
                        reader.acquireLatestImage()
                    } catch (_: IllegalStateException) {
                        null
                    }
                    if (image != null) {
                        val width = image.width
                        val height = image.height
                        image.close()
                        mainHandler.post { onFrame(probe, width, height) }
                    }
                },
                frameHandler,
            )
            launchPrivileged(targetActivity, probe)
        } catch (exception: Exception) {
            val probe = activeProbe
            if (probe != null) {
                finishProbe(
                    probe,
                    exception.message ?: "虚拟第二屏启动失败",
                    releaseAfter = true,
                )
            } else {
                try {
                    imageReader?.close()
                } catch (_: RuntimeException) {
                    // Nothing else remains allocated by this failed attempt.
                }
                result.success(
                    emptyProbeResult(
                        packageName,
                        exception.message ?: "虚拟第二屏启动失败",
                    ),
                )
            }
        }
    }

    private fun onFrame(probe: ActiveProbe, width: Int, height: Int) {
        if (activeProbe !== probe) return
        probe.frameReceived = true
        probe.frameWidth = width
        probe.frameHeight = height
        if (pendingProbeResult != null && probe.routingVerified) {
            finishProbe(probe, null, releaseAfter = false)
        }
    }

    private fun finishProbe(probe: ActiveProbe, error: String?, releaseAfter: Boolean) {
        if (activeProbe !== probe) return
        val result = pendingProbeResult
        pendingProbeResult = null
        probe.timeout?.let(mainHandler::removeCallbacks)
        probe.timeout = null
        if (pendingPrivilegedLaunch?.probe === probe) pendingPrivilegedLaunch = null
        result?.success(probeResult(probe, error))
        if (releaseAfter) releaseProbe(probe)
    }

    private fun closeProbe(result: MethodChannel.Result) {
        val probe = activeProbe
        if (probe == null) {
            result.success(mapOf("closed" to false, "error" to null))
            return
        }
        if (pendingProbeResult != null) {
            finishProbe(probe, "探针已手动关闭", releaseAfter = false)
        }
        releaseProbe(probe)
        result.success(mapOf("closed" to true, "error" to null))
    }

    private fun releaseProbe(probe: ActiveProbe) {
        if (activeProbe === probe) activeProbe = null
        probe.timeout?.let(mainHandler::removeCallbacks)
        probe.timeout = null
        if (pendingPrivilegedLaunch?.probe === probe) pendingPrivilegedLaunch = null
        probe.displayId?.let { displayId ->
            try {
                launchService?.releaseTrustedDisplay(displayId)
            } catch (_: Exception) {
                // UserService/process teardown will release any remaining shell-owned display.
            }
        }
        probe.displayId = null
        try {
            probe.imageReader.setOnImageAvailableListener(null, null)
        } catch (_: RuntimeException) {
            // The reader may already be closing.
        }
        try {
            probe.imageReader.close()
        } catch (_: RuntimeException) {
            // Cleanup is best-effort after ownership has been cleared above.
        }
    }

    private fun resolveLaunchIntent(packageName: String): Intent? =
        if (packageName == DEFAULT_TARGET_PACKAGE) {
            Intent(Settings.ACTION_SETTINGS).setPackage(DEFAULT_TARGET_PACKAGE)
        } else {
            context.packageManager.getLaunchIntentForPackage(packageName)
        }

    private fun launchPrivileged(component: ComponentName, probe: ActiveProbe) {
        val timeout = Runnable {
            if (pendingPrivilegedLaunch?.probe !== probe) return@Runnable
            finishProbe(probe, "等待 Shizuku UserService 启动超时", releaseAfter = true)
        }
        probe.timeout = timeout
        pendingPrivilegedLaunch = PendingPrivilegedLaunch(component, probe)
        mainHandler.postDelayed(timeout, USER_SERVICE_TIMEOUT_MS)

        if (launchService != null) {
            executePendingPrivilegedLaunch()
            return
        }
        if (launchServiceBinding) return
        launchServiceBinding = true
        try {
            Shizuku.bindUserService(userServiceArgs, userServiceConnection)
        } catch (exception: RuntimeException) {
            launchServiceBinding = false
            failPendingPrivilegedLaunch(exception.message ?: "无法绑定 Shizuku UserService")
        }
    }

    private fun executePendingPrivilegedLaunch() {
        val pending = pendingPrivilegedLaunch ?: return
        val service = launchService ?: run {
            failPendingPrivilegedLaunch("Shizuku UserService binder 为空")
            return
        }
        frameHandler.post {
            var displayId: Int? = null
            val launchResult = try {
                val createRaw = service.createTrustedDisplay(
                    pending.probe.imageReader.surface,
                    PROBE_WIDTH,
                    PROBE_HEIGHT,
                    context.resources.displayMetrics.densityDpi,
                ).orEmpty()
                val createJson = JSONObject(createRaw)
                val createError = if (createJson.isNull("error")) {
                    null
                } else {
                    createJson.optString("error").trim().takeIf(String::isNotEmpty)
                }
                if (createError != null) {
                    JSONObject().put("error", createError).toString()
                } else {
                    displayId = createJson.optInt("displayId", -1).takeIf { it > 0 }
                    if (displayId == null) {
                        JSONObject().put("error", "trusted virtual display 未返回有效 displayId").toString()
                    } else {
                        service.launchActivity(pending.component.flattenToString(), displayId!!).orEmpty()
                    }
                }
            } catch (exception: Exception) {
                JSONObject().put("error", exception.message ?: "Shizuku privileged launch 失败").toString()
            }
            mainHandler.post {
                if (displayId != null && activeProbe === pending.probe) pending.probe.displayId = displayId
                completePrivilegedLaunch(pending, launchResult)
            }
        }
    }

    private fun completePrivilegedLaunch(pending: PendingPrivilegedLaunch, rawResult: String) {
        if (pendingPrivilegedLaunch !== pending || activeProbe !== pending.probe) return
        pendingPrivilegedLaunch = null
        pending.probe.timeout?.let(mainHandler::removeCallbacks)
        pending.probe.timeout = null
        val routing = PrivilegedRoutingResult.parse(rawResult)
        pending.probe.applyRouting(routing)
        if (!routing.routingVerified) {
            finishProbe(
                pending.probe,
                routing.error ?: "目标包 task/activity 路由核验失败",
                releaseAfter = true,
            )
            return
        }

        pending.probe.launchRequested = true
        pending.probe.routingVerified = true
        if (pending.probe.frameReceived) {
            finishProbe(pending.probe, null, releaseAfter = false)
            return
        }
        val timeout = Runnable {
            if (activeProbe !== pending.probe || pendingProbeResult == null) return@Runnable
            finishProbe(
                pending.probe,
                "privileged launch 已成功，但超时前未收到第二屏 frame",
                releaseAfter = true,
            )
        }
        pending.probe.timeout = timeout
        mainHandler.postDelayed(timeout, FRAME_TIMEOUT_MS)
    }

    private fun failPendingPrivilegedLaunch(error: String) {
        val pending = pendingPrivilegedLaunch ?: return
        pendingPrivilegedLaunch = null
        if (activeProbe === pending.probe) {
            finishProbe(pending.probe, error, releaseAfter = true)
        }
    }

    private fun unbindLaunchService() {
        if (!launchServiceBinding && launchService == null) return
        launchServiceBinding = false
        launchService = null
        try {
            Shizuku.unbindUserService(userServiceArgs, userServiceConnection, true)
        } catch (_: RuntimeException) {
            // Shizuku may already be dead; non-daemon mode still bounds service lifetime.
        }
    }

    private fun emptyProbeResult(packageName: String, error: String): Map<String, Any?> =
        linkedMapOf(
            "displayId" to null,
            "targetPackage" to packageName,
            "launchRequested" to false,
            "frameReceived" to false,
            "frameWidth" to 0,
            "frameHeight" to 0,
            "routingVerified" to false,
            "mainDisplayStolen" to false,
            "preMainTopActivity" to null,
            "preMainResumedActivity" to null,
            "preMainFocusedActivity" to null,
            "postMainTopActivity" to null,
            "postMainResumedActivity" to null,
            "postMainFocusedActivity" to null,
            "targetTasks" to emptyList<Map<String, Any?>>(),
            "relocation" to "not_attempted",
            "relocationDetail" to null,
            "error" to error,
        )

    private fun probeResult(probe: ActiveProbe, error: String?): Map<String, Any?> =
        linkedMapOf(
            "displayId" to probe.displayId,
            "targetPackage" to probe.packageName,
            "launchRequested" to probe.launchRequested,
            "frameReceived" to probe.frameReceived,
            "frameWidth" to probe.frameWidth,
            "frameHeight" to probe.frameHeight,
            "routingVerified" to probe.routingVerified,
            "mainDisplayStolen" to probe.mainDisplayStolen,
            "preMainTopActivity" to probe.preMainTopActivity,
            "preMainResumedActivity" to probe.preMainResumedActivity,
            "preMainFocusedActivity" to probe.preMainFocusedActivity,
            "postMainTopActivity" to probe.postMainTopActivity,
            "postMainResumedActivity" to probe.postMainResumedActivity,
            "postMainFocusedActivity" to probe.postMainFocusedActivity,
            "targetTasks" to probe.targetTasks,
            "relocation" to probe.relocation,
            "relocationDetail" to probe.relocationDetail,
            "error" to error,
        )

    private class ActiveProbe(
        val packageName: String,
        val imageReader: ImageReader,
        var displayId: Int? = null,
        var launchRequested: Boolean = false,
        var frameReceived: Boolean = false,
        var frameWidth: Int = 0,
        var frameHeight: Int = 0,
        var routingVerified: Boolean = false,
        var mainDisplayStolen: Boolean = false,
        var preMainTopActivity: String? = null,
        var preMainResumedActivity: String? = null,
        var preMainFocusedActivity: String? = null,
        var postMainTopActivity: String? = null,
        var postMainResumedActivity: String? = null,
        var postMainFocusedActivity: String? = null,
        var targetTasks: List<Map<String, Any?>> = emptyList(),
        var relocation: String = "not_attempted",
        var relocationDetail: String? = null,
        var timeout: Runnable? = null,
    ) {
        fun applyRouting(result: PrivilegedRoutingResult) {
            routingVerified = result.routingVerified
            mainDisplayStolen = result.mainDisplayStolen
            preMainTopActivity = result.preMainTopActivity
            preMainResumedActivity = result.preMainResumedActivity
            preMainFocusedActivity = result.preMainFocusedActivity
            postMainTopActivity = result.postMainTopActivity
            postMainResumedActivity = result.postMainResumedActivity
            postMainFocusedActivity = result.postMainFocusedActivity
            targetTasks = result.targetTasks
            relocation = result.relocation
            relocationDetail = result.relocationDetail
        }
    }

    private data class PrivilegedRoutingResult(
        val routingVerified: Boolean,
        val mainDisplayStolen: Boolean,
        val preMainTopActivity: String?,
        val preMainResumedActivity: String?,
        val preMainFocusedActivity: String?,
        val postMainTopActivity: String?,
        val postMainResumedActivity: String?,
        val postMainFocusedActivity: String?,
        val targetTasks: List<Map<String, Any?>>,
        val relocation: String,
        val relocationDetail: String?,
        val error: String?,
    ) {
        companion object {
            fun parse(raw: String): PrivilegedRoutingResult = try {
                val json = JSONObject(raw)
                val tasks = json.optJSONArray("targetTasks")
                PrivilegedRoutingResult(
                    routingVerified = json.optBoolean("routingVerified", false),
                    mainDisplayStolen = json.optBoolean("mainDisplayStolen", false),
                    preMainTopActivity = json.optionalString("preMainTopActivity"),
                    preMainResumedActivity = json.optionalString("preMainResumedActivity"),
                    preMainFocusedActivity = json.optionalString("preMainFocusedActivity"),
                    postMainTopActivity = json.optionalString("postMainTopActivity"),
                    postMainResumedActivity = json.optionalString("postMainResumedActivity"),
                    postMainFocusedActivity = json.optionalString("postMainFocusedActivity"),
                    targetTasks = buildList {
                        if (tasks != null) {
                            repeat(tasks.length()) { index ->
                                val task = tasks.optJSONObject(index) ?: return@repeat
                                add(
                                    linkedMapOf(
                                        "taskId" to task.optInt("taskId"),
                                        "rootTaskId" to task.optInt("rootTaskId"),
                                        "displayId" to task.optInt("displayId"),
                                        "component" to task.optionalString("component"),
                                        "active" to task.optBoolean("active", false),
                                    ),
                                )
                            }
                        }
                    },
                    relocation = json.optionalString("relocation") ?: "not_attempted",
                    relocationDetail = json.optionalString("relocationDetail"),
                    error = json.optionalString("error"),
                )
            } catch (_: Exception) {
                PrivilegedRoutingResult(
                    routingVerified = false,
                    mainDisplayStolen = false,
                    preMainTopActivity = null,
                    preMainResumedActivity = null,
                    preMainFocusedActivity = null,
                    postMainTopActivity = null,
                    postMainResumedActivity = null,
                    postMainFocusedActivity = null,
                    targetTasks = emptyList(),
                    relocation = "not_attempted",
                    relocationDetail = null,
                    error = raw.ifEmpty { "Shizuku 路由核验返回为空" }.take(500),
                )
            }

            private fun JSONObject.optionalString(key: String): String? =
                if (isNull(key)) null else optString(key).trim().takeIf(String::isNotEmpty)
        }
    }

    private class PendingPrivilegedLaunch(
        val component: ComponentName,
        val probe: ActiveProbe,
    )

    companion object {
        private const val CHANNEL = "continuum/shizuku_executor"
        private const val DEFAULT_TARGET_PACKAGE = "com.android.settings"
        private const val DISPLAY_NAME = "Continuum Phase 1 Probe"
        private const val PROBE_WIDTH = 720
        private const val PROBE_HEIGHT = 1280
        private const val MAX_IMAGES = 2
        private const val PERMISSION_REQUEST_CODE = 9151
        private const val PERMISSION_TIMEOUT_MS = 30_000L
        private const val USER_SERVICE_TIMEOUT_MS = 15_000L
        private const val FRAME_TIMEOUT_MS = 4_000L
        private const val USER_SERVICE_TAG = "continuum_phase_1b_launch"
        private const val USER_SERVICE_VERSION = 1
        private val PACKAGE_NAME = Regex("^[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+$")
    }
}
