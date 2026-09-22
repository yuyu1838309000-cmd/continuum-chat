package dev.continuum.chat

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Installs app-owned platform channels on the foreground-task FlutterEngine. */
class ContinuumApplication : Application() {
    private val taskLifecycleListener by lazy {
        ContinuumTaskLifecycleListener(applicationContext)
    }

    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(taskLifecycleListener)
    }
}

private class ContinuumTaskLifecycleListener(
    private val context: Context,
) : FlutterForegroundTaskLifecycleListener {
    private var nudgeChannel: NudgeChannel? = null
    private var executionChannel: DeviceExecutionChannel? = null
    private var permissionChannel: MethodChannel? = null

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        nudgeChannel = NudgeChannel(context, messenger)
        executionChannel = DeviceExecutionChannel(context, messenger)
        permissionChannel = MethodChannel(messenger, PERMISSION_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkRuntime", "requestRuntime" -> {
                        val permissions = (call.arguments as? List<*>)
                            ?.map { it.toString() }
                            .orEmpty()
                        // A background service cannot show a runtime permission dialog.
                        // Return the real current grants; already-authorized camera use
                        // can proceed and missing grants fail explicitly.
                        result.success(
                            permissions.associateWith {
                                context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
                            },
                        )
                    }
                    "mediaPermissions" -> result.success(mediaPermissions())
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) = Unit

    override fun onTaskRepeatEvent() = Unit

    override fun onTaskDestroy() = Unit

    override fun onEngineWillDestroy() {
        permissionChannel?.setMethodCallHandler(null)
        permissionChannel = null
        executionChannel?.dispose()
        executionChannel = null
        nudgeChannel?.dispose()
        nudgeChannel = null
    }

    private fun mediaPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_AUDIO,
                Manifest.permission.READ_MEDIA_VIDEO,
            )
        } else {
            listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    companion object {
        private const val PERMISSION_CHANNEL = "continuum/permission_center"
    }
}
