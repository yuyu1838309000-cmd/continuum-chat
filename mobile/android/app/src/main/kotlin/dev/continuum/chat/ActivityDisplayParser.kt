package dev.continuum.chat

internal data class ActivityTaskRecord(
    val taskId: Int,
    val rootTaskId: Int,
    val displayId: Int,
    val component: String,
    val active: Boolean,
)

internal data class ActivityRoutingSnapshot(
    val mainTopActivity: String?,
    val mainResumedActivity: String?,
    val mainFocusedActivity: String?,
    val targetTasks: List<ActivityTaskRecord>,
    val allTasksByRoot: Map<Int, List<ActivityTaskRecord>>,
) {
    fun mainDisplayHasPackage(packageName: String): Boolean =
        listOf(mainTopActivity, mainResumedActivity, mainFocusedActivity)
            .filterNotNull()
            .any { ActivityDisplayParser.packageForComponent(it) == packageName }
}

/** Parses bounded `am stack list` and `dumpsys activity activities` snapshots. */
internal object ActivityDisplayParser {
    private val rootTaskLine = Regex("""^RootTask id=(\d+).*\bdisplayId=(\d+)\b""")
    private val childTaskLine = Regex("""^\s*taskId=(\d+):\s+(\S+).*""")
    private val topActivity = Regex("""\btopActivity=(?:ComponentInfo\{)?([^\s}]+/[^\s}]+)\}?""")
    private val taskVisible = Regex("""\bvisible=(true|false)\b""")
    private val displayHeader = Regex("""^\s*Display #(\d+)""")
    private val dumpRootTask = Regex("""^\s*RootTask #(\d+)""")
    private val dumpTask = Regex("""^\s*\* Task\{.*\s#(\d+)\b""")
    private val activityRecord = Regex("""ActivityRecord\{.*\su\d+\s+([^\s}]+/[^\s}]+)\s+t(\d+)""")
    private val activityLine = Regex("""^\s*ACTIVITY\s+(\S+).*?\bdisplayId=(\d+)(?:\D|$)""")

    fun parse(
        stackOutput: String,
        activitiesOutput: String,
        targetPackage: String,
    ): ActivityRoutingSnapshot {
        val records = linkedMapOf<Int, MutableTask>()
        var rootTaskId: Int? = null
        var displayId: Int? = null
        var mainTop: String? = null

        stackOutput.lineSequence().forEach { line ->
            rootTaskLine.find(line)?.let { match ->
                rootTaskId = match.groupValues[1].toInt()
                displayId = match.groupValues[2].toInt()
                return@forEach
            }
            val child = childTaskLine.find(line) ?: return@forEach
            val currentRoot = rootTaskId ?: return@forEach
            val currentDisplay = displayId ?: return@forEach
            val taskId = child.groupValues[1].toInt()
            // Keep even unrecognized child names so relocation fails closed when a
            // root task contains a member whose package cannot be proven.
            val component = normalizeComponent(child.groupValues[2]) ?: child.groupValues[2]
            val rootTop = topActivity.find(line)?.groupValues?.get(1)?.let(::normalizeComponent)
            val active = taskVisible.find(line)?.groupValues?.get(1) == "true" || rootTop == component
            records[taskId] = MutableTask(taskId, currentRoot, currentDisplay, component, active)
            if (currentDisplay == MAIN_DISPLAY_ID && mainTop == null && rootTop != null && active) {
                mainTop = rootTop
            }
        }

        var currentDisplay: Int? = null
        var currentRoot: Int? = null
        var currentTask: Int? = null
        var mainResumed: String? = null
        var mainFocused: String? = null
        var supervisorSection = false
        activitiesOutput.lineSequence().forEach { line ->
            // Everything after this heading is a global ActivityTaskSupervisor dump,
            // not part of the last explicit `Display #N` section. Keeping the prior
            // display id here misattributes global mFocusedApp / task summaries to
            // whichever display happened to be listed last (often the virtual one).
            if (line.startsWith("ActivityTaskSupervisor state:")) supervisorSection = true
            if (supervisorSection) return@forEach

            // HyperOS emits one global `ResumedActivity:` summary after all per-display
            // sections. It is not nested under the last `Display #N`, even though it
            // appears before `ActivityTaskSupervisor state:`. Treating it as part of
            // the last display can move a correctly routed virtual-display task onto
            // the phone's physical secondary display in our parsed snapshot.
            if (line.trimStart().startsWith("ResumedActivity:")) return@forEach

            displayHeader.find(line)?.let { match ->
                currentDisplay = match.groupValues[1].toInt()
                currentRoot = null
                currentTask = null
                return@forEach
            }
            dumpRootTask.find(line)?.let { match ->
                currentRoot = match.groupValues[1].toInt()
                return@forEach
            }
            dumpTask.find(line)?.let { match ->
                currentTask = match.groupValues[1].toInt()
                return@forEach
            }
            activityLine.find(line)?.let { match ->
                val component = normalizeComponent(match.groupValues[1]) ?: return@let
                val explicitDisplay = match.groupValues[2].toInt()
                val taskId = currentTask ?: return@let
                mergeRecord(
                    records,
                    taskId,
                    currentRoot ?: taskId,
                    explicitDisplay,
                    component,
                    false,
                    preferNewLocation = true,
                )
            }
            activityRecord.find(line)?.let { match ->
                val component = normalizeComponent(match.groupValues[1]) ?: return@let
                val taskId = match.groupValues[2].toInt()
                val active = line.contains("ResumedActivity") ||
                    line.contains("topResumedActivity") ||
                    line.contains("mFocusedApp")
                val recordDisplay = currentDisplay ?: records[taskId]?.displayId ?: return@let
                mergeRecord(
                    records,
                    taskId,
                    currentRoot ?: records[taskId]?.rootTaskId ?: taskId,
                    recordDisplay,
                    component,
                    active,
                    preferNewLocation = true,
                )
                if (recordDisplay == MAIN_DISPLAY_ID) {
                    if (line.contains("ResumedActivity") || line.contains("topResumedActivity")) {
                        mainResumed = component
                    }
                    if (line.contains("mFocusedApp")) mainFocused = component
                }
            }
        }

        val immutable = records.values.map(MutableTask::toRecord)
        return ActivityRoutingSnapshot(
            mainTopActivity = mainTop,
            mainResumedActivity = mainResumed,
            mainFocusedActivity = mainFocused,
            targetTasks = immutable.filter { packageForComponent(it.component) == targetPackage },
            allTasksByRoot = immutable.groupBy(ActivityTaskRecord::rootTaskId),
        )
    }

    fun packageForComponent(component: String): String? =
        normalizeComponent(component)?.substringBefore('/')

    private fun mergeRecord(
        records: MutableMap<Int, MutableTask>,
        taskId: Int,
        rootTaskId: Int,
        displayId: Int,
        component: String,
        active: Boolean,
        preferNewLocation: Boolean = false,
    ) {
        val existing = records[taskId]
        if (existing == null) {
            records[taskId] = MutableTask(taskId, rootTaskId, displayId, component, active)
            return
        }

        // `am stack list` and `dumpsys activity activities` are captured back-to-back.
        // MIUI/HyperOS can move a task between those two snapshots. Once we are
        // parsing the later dumpsys output, its display/root membership must win
        // even if the earlier stack record was already marked active. Otherwise a
        // task that escaped to display 0 can be falsely retained on the virtual display.
        if (preferNewLocation || active || !existing.active) {
            existing.rootTaskId = rootTaskId
            existing.displayId = displayId
            existing.component = component
        }
        existing.active = existing.active || active
    }

    private fun normalizeComponent(component: String): String? {
        val separator = component.indexOf('/')
        if (separator <= 0 || separator == component.lastIndex) return null
        val packageName = component.substring(0, separator)
        val rawClassName = component.substring(separator + 1)
        val className = if (rawClassName.startsWith('.')) packageName + rawClassName else rawClassName
        return "$packageName/$className"
    }

    private data class MutableTask(
        val taskId: Int,
        var rootTaskId: Int,
        var displayId: Int,
        var component: String,
        var active: Boolean,
    ) {
        fun toRecord() = ActivityTaskRecord(taskId, rootTaskId, displayId, component, active)
    }

    private const val MAIN_DISPLAY_ID = 0
}
