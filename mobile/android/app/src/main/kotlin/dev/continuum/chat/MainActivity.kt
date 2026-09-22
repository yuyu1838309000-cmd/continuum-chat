package dev.continuum.chat

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.AppOpsManager
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Process
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.UUID

/// 权限中心原生侧（MethodChannel continuum/permission_center）：
/// - checkRuntime / requestRuntime：运行时权限检查与申请（checkSelfPermission / requestPermissions）
/// - mediaPermissions：存储权限按 SDK 分级（13+ 媒体三分，12 及以下 READ_EXTERNAL_STORAGE）
/// - checkSpecial：系统特殊权限状态（通知使用权 / 无障碍 / 使用情况统计 / 精确闹钟）
/// - openSettings：跳转对应系统设置页
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 防白屏④：Android 12+ 关掉系统启动屏自带的淡出动画，直接切走，防止淡出瞬间露白
        if (Build.VERSION.SDK_INT >= 31) {
            splashScreen.setOnExitAnimationListener { view -> view.remove() }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkRuntime" -> {
                    val perms = (call.arguments as? List<*>)?.map { it.toString() } ?: emptyList()
                    result.success(perms.associateWith { isGranted(it) })
                }
                "requestRuntime" -> {
                    val perms = (call.arguments as? List<*>)?.map { it.toString() } ?: emptyList()
                    requestRuntime(perms).whenComplete { map, _ ->
                        runOnUiThread { result.success(map) }
                    }
                }
                "mediaPermissions" -> result.success(mediaPermissions())
                "checkSpecial" -> {
                    val type = call.arguments as? String ?: ""
                    result.success(when (type) {
                        TYPE_NOTIF_LISTENER -> isNotificationListenerEnabled()
                        TYPE_ACCESSIBILITY -> isAccessibilityEnabled()
                        TYPE_USAGE_STATS -> hasUsageStatsAccess()
                        TYPE_EXACT_ALARM -> canScheduleExactAlarms()
                        TYPE_INSTALL_UNKNOWN -> canRequestPackageInstalls()
                        TYPE_OVERLAY -> Settings.canDrawOverlays(this)
                        TYPE_BLUETOOTH -> bluetoothConnectGranted()
                        else -> false
                    })
                }
                "openSettings" -> {
                    val type = call.arguments as? String ?: ""
                    result.success(openSettings(type))
                }
                "installApk" -> {
                    val path = call.arguments as? String ?: ""
                    result.success(installApk(path))
                }
                else -> result.notImplemented()
            }
        }
        // Both UI and foreground-task engines use the same process-wide durable
        // execution authority. NudgeChannel itself is registered on each engine.
        nudgeChannel?.dispose()
        deviceExecutionChannel?.dispose()
        shizukuExecutorChannel?.dispose()
        nudgeChannel = NudgeChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        deviceExecutionChannel = DeviceExecutionChannel(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        shizukuExecutorChannel = ShizukuExecutorChannel(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        // 共读技术探针：只控制本机 Accessibility 采样与读取本地结果，不联网。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, READING_PROBE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getState" -> result.success(ReadingProbeStore.state(this).toString())
                "setEnabled" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
                    val enabled = args["enabled"] as? Boolean ?: false
                    ReadingProbeStore.setEnabled(this, enabled)
                    result.success(ReadingProbeStore.state(this).toString())
                }
                "clear" -> {
                    ReadingProbeStore.clear(this)
                    result.success(ReadingProbeStore.state(this).toString())
                }
                else -> result.notImplemented()
            }
        }
        // 文件选择（v0.2.164 聊天"加号"发文件）：MethodChannel "continuum/file_picker"。
        // file_picker 插件两轮编译失败，改 Android 原生 ACTION_OPEN_DOCUMENT：
        // 零新插件依赖、零 Gradle 改动。所选文件拷到 App 缓存目录，回传本地路径。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFile" -> pickFile(result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GALLERY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImage" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
                    fun runSave() {
                        galleryExecutor.execute {
                            val saved = try {
                                saveImageToGallery(args)
                            } catch (e: Exception) {
                                runOnUiThread { result.error("save_failed", e.message ?: "保存失败", null) }
                                return@execute
                            }
                            runOnUiThread { result.success(saved) }
                        }
                    }
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                        !isGranted(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                    ) {
                        requestRuntime(listOf(Manifest.permission.WRITE_EXTERNAL_STORAGE)).whenComplete { map, error ->
                            if (error == null && map?.get(Manifest.permission.WRITE_EXTERNAL_STORAGE) == true) {
                                runSave()
                            } else {
                                runOnUiThread { result.error("permission_denied", "需要存储写入权限", null) }
                            }
                        }
                    } else {
                        runSave()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        shizukuExecutorChannel?.dispose()
        shizukuExecutorChannel = null
        deviceExecutionChannel?.dispose()
        deviceExecutionChannel = null
        nudgeChannel?.dispose()
        nudgeChannel = null
        super.onDestroy()
    }

    /// 打开系统文件选择器（文档/音频/原图白名单），结果经 onActivityResult 回传。
    private fun pickFile(result: MethodChannel.Result) {
        if (pendingFileResult != null) {
            result.error("busy", "已有文件选择进行中", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, ALLOWED_MIME_TYPES)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pendingFileResult = result
        try {
            startActivityForResult(intent, REQ_CODE_PICK_FILE)
        } catch (e: Exception) {
            pendingFileResult = null
            result.error("no_activity", "没有可用的文件选择器", null)
        }
    }

    /// 文件选择回调：校验扩展名/大小 → 流式拷到缓存目录 → 回传本地路径。
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_CODE_PICK_FILE) return
        val result = pendingFileResult ?: return
        pendingFileResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data!!.data!!
        // 校验 + 拷贝放后台线程（50MB 大文件拷贝不卡主线程），结果回主线程
        fileExecutor.execute {
            try {
                val name = queryDisplayName(uri) ?: "file"
                val size = querySize(uri)
                val ext = name.substringAfterLast('.', "").lowercase()
                if (ext !in ALLOWED_EXTS) {
                    runOnUiThread {
                        result.error("bad_type", "不支持的文件类型 .$ext", null)
                    }
                    return@execute
                }
                val limit = if (ext in IMAGE_EXTS) 10L * 1024 * 1024 else 50L * 1024 * 1024
                if (size > limit) {
                    runOnUiThread { result.error("too_large", "文件超过大小上限", null) }
                    return@execute
                }
                // 拷到缓存目录（64KB 分块流式，不整文件进内存）；顺带清 1 小时前的旧临时文件
                val dir = File(cacheDir, "file_pick").apply { mkdirs() }
                dir.listFiles()
                    ?.filter { it.isFile && System.currentTimeMillis() - it.lastModified() > 3_600_000L }
                    ?.forEach { it.delete() }
                val out = File(dir, "${System.currentTimeMillis()}-${UUID.randomUUID()}.$ext")
                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("无法读取所选文件")
                input.use { ins ->
                    out.outputStream().use { o -> ins.copyTo(o, 64 * 1024) }
                }
                val copiedSize = out.length()
                runOnUiThread {
                    result.success(
                        mapOf("path" to out.absolutePath, "name" to name, "size" to copiedSize)
                    )
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("read_failed", e.message ?: "读取文件失败", null) }
            }
        }
    }

    /// SAF 文件名（OpenableColumns.DISPLAY_NAME），查不到回退 URI 最后一段。
    private fun queryDisplayName(uri: Uri): String? {
        var name: String? = null
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) name = c.getString(idx)
            }
        }
        return name ?: uri.lastPathSegment
    }

    /// SAF 文件大小（OpenableColumns.SIZE），查不到返回 -1（App 端用本地文件重算）。
    private fun querySize(uri: Uri): Long {
        var size = -1L
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val idx = c.getColumnIndex(OpenableColumns.SIZE)
                if (idx >= 0 && !c.isNull(idx)) size = c.getLong(idx)
            }
        }
        return size
    }

    private fun saveImageToGallery(args: Map<*, *>): Boolean {
        val bytes = args["bytes"] as? ByteArray ?: throw IllegalArgumentException("图片数据为空")
        val mime = args["mimeType"]?.toString()?.takeIf { it.startsWith("image/") } ?: "image/jpeg"
        val name = sanitizeImageName(args["displayName"]?.toString(), mime)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Continuum")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("无法创建相册文件")
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IllegalStateException("无法写入相册文件")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return true
        }
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("需要存储写入权限")
        }
        @Suppress("DEPRECATION")
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            "Continuum"
        ).apply { mkdirs() }
        val file = File(dir, name)
        file.writeBytes(bytes)
        MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf(mime), null)
        return true
    }

    private fun sanitizeImageName(raw: String?, mime: String): String {
        val fallbackExt = when (mime) {
            "image/png" -> "png"
            "image/gif" -> "gif"
            else -> "jpg"
        }
        val base = raw.orEmpty()
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .ifBlank { "continuum_${System.currentTimeMillis()}.$fallbackExt" }
        return if (base.contains(".")) base else "$base.$fallbackExt"
    }

    /// checkSelfPermission：运行时权限检查。
    private fun isGranted(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /// requestPermissions：一次性申请多个运行时权限，返回每个权限的授权结果。
    private fun requestRuntime(permissions: List<String>): CompletableFuture<Map<String, Boolean>> {
        val future = CompletableFuture<Map<String, Boolean>>()
        if (permissions.isEmpty()) {
            future.complete(emptyMap())
            return future
        }
        pendingPermissionFuture = future
        requestPermissions(permissions.toTypedArray(), REQ_CODE_PERMISSIONS)
        return future
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val future = pendingPermissionFuture ?: return
        if (requestCode != REQ_CODE_PERMISSIONS) return
        pendingPermissionFuture = null
        val map = permissions.mapIndexed { i, p ->
            p to (grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED)
        }.toMap()
        future.complete(map)
    }

    /// 存储权限按 SDK 分级：13+ READ_MEDIA_IMAGES/AUDIO/VIDEO，12 及以下 READ_EXTERNAL_STORAGE。
    private fun mediaPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_AUDIO,
                Manifest.permission.READ_MEDIA_VIDEO
            )
        } else {
            listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    /// 通知使用权：Settings.Secure 里已启用监听列表包含本组件。
    private fun isNotificationListenerEnabled(): Boolean {
        val component = ComponentName(this, PermissionNotificationListenerService::class.java).flattenToString()
        val enabled = Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        return enabled.split(':').any { it == component }
    }

    /// 无障碍服务：Settings.Secure 里已启用服务列表包含本组件。
    private fun isAccessibilityEnabled(): Boolean {
        val component = ComponentName(this, PermissionAccessibilityService::class.java).flattenToString()
        val enabled = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabled.split(':').any { it == component }
    }

    /// 使用情况统计：AppOps OPSTR_GET_USAGE_STATS == MODE_ALLOWED。
    private fun hasUsageStatsAccess(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /// 安装未知应用：Android 8+ 需要用户授权（ACTION_MANAGE_UNKNOWN_APP_SOURCES），8 以下默认允许。
    private fun canRequestPackageInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else true

    /// 蓝牙连接：Android 12+ 运行时权限；11 及以下 BLUETOOTH 普通权限，视为已内置。
    private fun bluetoothConnectGranted(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            isGranted(Manifest.permission.BLUETOOTH_CONNECT)
        } else true

    /// 安装 APK（应用内更新 v0.2.104）：FileProvider 授权 + ACTION_VIEW 唤起系统安装器。
    private fun installApk(path: String): Boolean {
        return try {
            val file = java.io.File(path)
            if (!file.exists()) return false
            val uri = androidx.core.content.FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /// 精确闹钟：Android 12+ 为特殊权限（USE_EXACT_ALARM 安装即授 / SCHEDULE_EXACT_ALARM 需用户授权）。
    private fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return alarmManager.canScheduleExactAlarms()
    }

    /// 跳转系统设置页。返回是否成功拉起（某些 ROM 无对应页面时 false，App 端兜底提示）。
    private fun openSettings(type: String): Boolean {
        val intent = when (type) {
            TYPE_NOTIF_LISTENER -> Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            TYPE_ACCESSIBILITY -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            TYPE_USAGE_STATS -> Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            TYPE_EXACT_ALARM -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
                Intent(
                    Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    Uri.parse("package:$packageName")
                )
            }
            TYPE_APP_DETAILS -> Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            )
            TYPE_INSTALL_UNKNOWN -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            }
            TYPE_OVERLAY -> Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            )
            else -> return false
        }
        return try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private var pendingPermissionFuture: CompletableFuture<Map<String, Boolean>>? = null
    private var pendingFileResult: MethodChannel.Result? = null
    private var nudgeChannel: NudgeChannel? = null
    private var deviceExecutionChannel: DeviceExecutionChannel? = null
    private var shizukuExecutorChannel: ShizukuExecutorChannel? = null

    companion object {
        private const val CHANNEL = "continuum/permission_center"
        private const val READING_PROBE_CHANNEL = "continuum/reading_probe"
        private const val FILE_CHANNEL = "continuum/file_picker"
        private const val GALLERY_CHANNEL = "continuum/gallery"
        private const val REQ_CODE_PERMISSIONS = 0x4E49
        private const val REQ_CODE_PICK_FILE = 0x4E50
        private const val TYPE_NOTIF_LISTENER = "notification_listener"
        private const val TYPE_ACCESSIBILITY = "accessibility"
        private const val TYPE_USAGE_STATS = "usage_stats"
        private const val TYPE_EXACT_ALARM = "exact_alarm"
        private const val TYPE_APP_DETAILS = "app_details"
        private const val TYPE_INSTALL_UNKNOWN = "install_unknown"
        private const val TYPE_OVERLAY = "overlay"
        private const val TYPE_BLUETOOTH = "bluetooth"
        private val ALLOWED_EXTS = setOf(
            "pdf", "doc", "docx", "txt", "md", "xlsx",
            "mp3", "m4a", "wav", "flac",
            "png", "jpg", "jpeg", "gif"
        )
        private val IMAGE_EXTS = setOf("png", "jpg", "jpeg", "gif")
        private val ALLOWED_MIME_TYPES = arrayOf(
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "text/plain",
            "text/markdown",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "audio/mpeg", "audio/mp4", "audio/x-m4a",
            "audio/wav", "audio/x-wav", "audio/flac", "audio/x-flac",
            "image/png", "image/jpeg", "image/gif"
        )
        private val fileExecutor = Executors.newSingleThreadExecutor()
        private val galleryExecutor = Executors.newSingleThreadExecutor()
    }
}
