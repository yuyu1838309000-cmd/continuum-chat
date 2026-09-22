package dev.continuum.chat

import android.content.ComponentName
import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.view.Surface
import androidx.annotation.Keep
import java.io.InputStream
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject

/** Narrow shell-side launcher and package/task routing verifier. */
@Keep
class ShizukuLaunchUserService : IShizukuLaunchService.Stub {
    private var serviceContext: Context? = null
    private var serviceContextError: String? = null
    private val trustedDisplays = linkedMapOf<Int, VirtualDisplay>()

    constructor() : super()

    @Keep
    constructor(context: Context) : super() {
        // Shizuku UserService runs as shell (uid 2000), while the injected base
        // Context still names our app package. DisplayManager validates that the
        // package name belongs to the calling uid, so use com.android.shell's
        // package context for privileged virtual-display creation.
        serviceContext = try {
            context.createPackageContext(SHELL_PACKAGE, Context.CONTEXT_IGNORE_SECURITY)
                .takeIf { it.packageName == SHELL_PACKAGE }
        } catch (exception: Exception) {
            serviceContextError = exception.message ?: "无法创建 shell package Context"
            null
        }
        if (serviceContext == null && serviceContextError == null) {
            serviceContextError = "shell package Context 不可用"
        }
    }

    override fun createTrustedDisplay(
        surface: Surface?,
        width: Int,
        height: Int,
        densityDpi: Int,
    ): String {
        if (surface == null || !surface.isValid) return trustedDisplayFailure("第二屏 Surface 无效")
        if (width !in MIN_DISPLAY_EDGE..MAX_DISPLAY_EDGE ||
            height !in MIN_DISPLAY_EDGE..MAX_DISPLAY_EDGE ||
            densityDpi !in MIN_DENSITY_DPI..MAX_DENSITY_DPI
        ) {
            return trustedDisplayFailure("第二屏尺寸或 density 无效")
        }
        val context = serviceContext
            ?: return trustedDisplayFailure(serviceContextError ?: "Shizuku UserService Context 不可用")
        val manager = context.getSystemService(DisplayManager::class.java)
            ?: return trustedDisplayFailure("DisplayManager 不可用")
        val display = try {
            manager.createVirtualDisplay(
                TRUSTED_DISPLAY_NAME,
                width,
                height,
                densityDpi,
                surface,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC or
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY or
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION or
                    VIRTUAL_DISPLAY_FLAG_TRUSTED,
            )
        } catch (exception: Exception) {
            return trustedDisplayFailure(exception.message ?: "创建 trusted virtual display 失败")
        } ?: return trustedDisplayFailure("系统未能创建 trusted virtual display")

        val displayId = display.display.displayId
        trustedDisplays.put(displayId, display)?.release()
        return JSONObject().put("displayId", displayId).toString()
    }

    override fun releaseTrustedDisplay(displayId: Int) {
        trustedDisplays.remove(displayId)?.release()
    }

    override fun launchActivity(component: String?, displayId: Int): String {
        val target = component?.let(ComponentName::unflattenFromString)
            ?: return failure("目标 Activity component 无效")
        if (target.flattenToString() != component || displayId !in 1..MAX_DISPLAY_ID) {
            return failure("目标 Activity 或 displayId 无效")
        }

        val before = captureSnapshot(target.packageName)
        if (before.error != null) return failure(before.error)

        val launch = runBoundedCommand(
            listOf(
                ACTIVITY_MANAGER,
                "start",
                "-W",
                "--display",
                displayId.toString(),
                "-f",
                NEW_ISOLATED_TASK_FLAGS,
                "-n",
                target.flattenToString(),
            ),
            LAUNCH_TIMEOUT_SECONDS,
        )
        if (launch.error != null) return failure(launch.error, before.snapshot)
        if (launch.exitCode != 0 || FAILURE_MARKERS.any(launch.output::contains)) {
            return failure(
                sanitizeError(launch.output).ifEmpty { "系统拒绝启动目标 Activity" },
                before.snapshot,
            )
        }

        Thread.sleep(STABILIZATION_WINDOW_MS)
        var after = captureSnapshot(target.packageName)
        if (after.error != null) return failure(after.error, before.snapshot)

        val beforeSnapshot = before.snapshot!!
        val afterSnapshot = after.snapshot!!
        val beforeTaskIds = beforeSnapshot.targetTasks.mapTo(mutableSetOf()) { it.taskId }
        val escapedNewTasks = afterSnapshot.targetTasks.filter {
            it.displayId == MAIN_DISPLAY_ID && it.taskId !in beforeTaskIds
        }
        var relocation = "not_needed"
        var relocationDetail: String? = null

        if (escapedNewTasks.isNotEmpty()) {
            val roots = escapedNewTasks.map { it.rootTaskId }.distinct()
            val unsafeRoot = roots.firstOrNull { rootId ->
                val members = afterSnapshot.allTasksByRoot[rootId].orEmpty()
                members.isEmpty() || members.any {
                    ActivityDisplayParser.packageForComponent(it.component) != target.packageName ||
                        it.taskId in beforeTaskIds
                }
            }
            if (unsafeRoot != null) {
                relocation = "unsafe"
                relocationDetail = "新任务所在 rootTask $unsafeRoot 还包含既有或其他包任务，未迁移"
            } else if (!supportsMoveRootTaskToDisplay()) {
                relocation = "unsupported"
                relocationDetail = "设备未提供 am display move-stack，无法安全迁移新任务"
            } else {
                relocation = "attempted"
                for (rootId in roots) {
                    val moved = runBoundedCommand(
                        listOf(
                            ACTIVITY_MANAGER,
                            "display",
                            "move-stack",
                            rootId.toString(),
                            displayId.toString(),
                        ),
                        MOVE_TIMEOUT_SECONDS,
                    )
                    if (moved.error != null || moved.exitCode != 0 || FAILURE_MARKERS.any(moved.output::contains)) {
                        relocation = "failed"
                        relocationDetail = moved.error ?: sanitizeError(moved.output)
                            .ifEmpty { "系统拒绝迁移 rootTask $rootId" }
                        break
                    }
                }
                Thread.sleep(POST_MOVE_STABILIZATION_MS)
                after = captureSnapshot(target.packageName)
                if (after.error != null) return failure(after.error, before.snapshot)
                if (relocation == "attempted") relocation = "moved"
            }
        }

        val finalSnapshot = after.snapshot!!
        val activeOnRequestedDisplay = finalSnapshot.targetTasks.any {
            it.displayId == displayId && it.active
        }
        val mainDisplayStolen = finalSnapshot.mainDisplayHasPackage(target.packageName)
        val routingVerified = activeOnRequestedDisplay && !mainDisplayStolen
        val error = when {
            routingVerified -> null
            relocationDetail != null -> relocationDetail
            mainDisplayStolen -> "目标包在稳定期后占用了物理 display 0"
            finalSnapshot.targetTasks.none { it.displayId == displayId } ->
                "稳定期后未发现目标包任务位于请求的 display $displayId"
            else -> "请求的 display $displayId 上没有目标包的活跃 task/activity"
        }
        return resultJson(
            routingVerified = routingVerified,
            requestedDisplayId = displayId,
            before = before.snapshot,
            after = finalSnapshot,
            mainDisplayStolen = mainDisplayStolen,
            relocation = relocation,
            relocationDetail = relocationDetail,
            error = error,
        ).toString()
    }

    override fun destroy() {
        trustedDisplays.values.forEach { display ->
            try {
                display.release()
            } catch (_: RuntimeException) {
                // Process teardown remains authoritative if a display already vanished.
            }
        }
        trustedDisplays.clear()
        System.exit(0)
    }

    private fun trustedDisplayFailure(error: String): String =
        JSONObject().put("error", sanitizeError(error)).toString()

    private fun captureSnapshot(packageName: String): SnapshotResult {
        val stacks = runBoundedCommand(
            listOf(ACTIVITY_MANAGER, "stack", "list"),
            DISPLAY_QUERY_TIMEOUT_SECONDS,
        )
        if (stacks.error != null) return SnapshotResult(error = stacks.error)
        if (stacks.exitCode != 0) {
            return SnapshotResult(error = sanitizeError(stacks.output).ifEmpty { "无法查询 task/display 状态" })
        }
        val activities = runBoundedCommand(
            listOf(DUMPSYS, "activity", "activities"),
            DISPLAY_QUERY_TIMEOUT_SECONDS,
        )
        if (activities.error != null) return SnapshotResult(error = activities.error)
        if (activities.exitCode != 0) {
            return SnapshotResult(error = sanitizeError(activities.output).ifEmpty { "无法查询 activity/display 状态" })
        }
        return SnapshotResult(
            snapshot = ActivityDisplayParser.parse(stacks.output, activities.output, packageName),
        )
    }

    private fun supportsMoveRootTaskToDisplay(): Boolean {
        val help = runBoundedCommand(listOf(ACTIVITY_MANAGER, "help"), DISPLAY_QUERY_TIMEOUT_SECONDS)
        return help.error == null && help.exitCode == 0 &&
            help.output.contains("display [COMMAND]") && help.output.contains("move-stack")
    }

    private fun failure(error: String, before: ActivityRoutingSnapshot? = null): String =
        resultJson(
            routingVerified = false,
            requestedDisplayId = null,
            before = before,
            after = null,
            mainDisplayStolen = false,
            relocation = "not_attempted",
            relocationDetail = null,
            error = error,
        ).toString()

    private fun resultJson(
        routingVerified: Boolean,
        requestedDisplayId: Int?,
        before: ActivityRoutingSnapshot?,
        after: ActivityRoutingSnapshot?,
        mainDisplayStolen: Boolean,
        relocation: String,
        relocationDetail: String?,
        error: String?,
    ): JSONObject = JSONObject().apply {
        put("protocolVersion", RESULT_PROTOCOL_VERSION)
        put("routingVerified", routingVerified)
        put("requestedDisplayId", requestedDisplayId ?: JSONObject.NULL)
        put("preMainTopActivity", before?.mainTopActivity ?: JSONObject.NULL)
        put("preMainResumedActivity", before?.mainResumedActivity ?: JSONObject.NULL)
        put("preMainFocusedActivity", before?.mainFocusedActivity ?: JSONObject.NULL)
        put("postMainTopActivity", after?.mainTopActivity ?: JSONObject.NULL)
        put("postMainResumedActivity", after?.mainResumedActivity ?: JSONObject.NULL)
        put("postMainFocusedActivity", after?.mainFocusedActivity ?: JSONObject.NULL)
        put("mainDisplayStolen", mainDisplayStolen)
        put("targetTasks", JSONArray().apply {
            after?.targetTasks?.sortedWith(compareBy(ActivityTaskRecord::displayId, ActivityTaskRecord::taskId))
                ?.forEach { task ->
                    put(JSONObject().apply {
                        put("taskId", task.taskId)
                        put("rootTaskId", task.rootTaskId)
                        put("displayId", task.displayId)
                        put("component", task.component)
                        put("active", task.active)
                    })
                }
        })
        put("relocation", relocation)
        put("relocationDetail", relocationDetail ?: JSONObject.NULL)
        put("error", error ?: JSONObject.NULL)
    }

    private fun sanitizeError(output: String): String =
        output.replace(Regex("\\s+"), " ").trim().take(MAX_ERROR_LENGTH)

    private fun runBoundedCommand(command: List<String>, timeoutSeconds: Long): CommandResult {
        val process = try {
            ProcessBuilder(command).redirectErrorStream(true).start()
        } catch (exception: Exception) {
            return CommandResult(error = exception.message ?: "无法执行受限 ActivityManager 命令")
        }
        var output = ""
        var readError: String? = null
        val reader = Thread {
            try {
                output = readBounded(process.inputStream)
            } catch (exception: Exception) {
                readError = exception.message ?: "读取 ActivityManager 状态失败"
            }
        }.apply {
            isDaemon = true
            start()
        }
        if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            reader.join(READER_JOIN_TIMEOUT_MS)
            return CommandResult(error = "ActivityManager 命令超时")
        }
        reader.join(READER_JOIN_TIMEOUT_MS)
        return CommandResult(process.exitValue(), output, readError)
    }

    private fun readBounded(input: InputStream): String = input.bufferedReader().use { reader ->
        val output = StringBuilder()
        val buffer = CharArray(OUTPUT_BUFFER_SIZE)
        while (true) {
            val count = reader.read(buffer)
            if (count < 0) break
            val remaining = MAX_DUMP_LENGTH - output.length
            if (remaining > 0) output.append(buffer, 0, minOf(count, remaining))
        }
        output.toString()
    }

    private data class SnapshotResult(
        val snapshot: ActivityRoutingSnapshot? = null,
        val error: String? = null,
    )

    private data class CommandResult(
        val exitCode: Int = -1,
        val output: String = "",
        val error: String? = null,
    )

    private companion object {
        const val ACTIVITY_MANAGER = "/system/bin/am"
        const val DUMPSYS = "/system/bin/dumpsys"
        const val NEW_ISOLATED_TASK_FLAGS = "0x18000000"
        const val MAIN_DISPLAY_ID = 0
        const val TRUSTED_DISPLAY_NAME = "Continuum Trusted Executor"
        const val SHELL_PACKAGE = "com.android.shell"
        const val VIRTUAL_DISPLAY_FLAG_TRUSTED = 1 shl 10
        const val MIN_DISPLAY_EDGE = 64
        const val MAX_DISPLAY_EDGE = 4096
        const val MIN_DENSITY_DPI = 72
        const val MAX_DENSITY_DPI = 1000
        const val MAX_DISPLAY_ID = 10_000
        const val LAUNCH_TIMEOUT_SECONDS = 10L
        const val DISPLAY_QUERY_TIMEOUT_SECONDS = 5L
        const val MOVE_TIMEOUT_SECONDS = 5L
        const val STABILIZATION_WINDOW_MS = 1_500L
        const val POST_MOVE_STABILIZATION_MS = 800L
        const val READER_JOIN_TIMEOUT_MS = 1_000L
        const val OUTPUT_BUFFER_SIZE = 4_096
        const val MAX_DUMP_LENGTH = 256 * 1_024
        const val MAX_ERROR_LENGTH = 500
        const val RESULT_PROTOCOL_VERSION = 1
        val FAILURE_MARKERS = listOf("Error:", "Exception", "Permission Denial")
    }
}
