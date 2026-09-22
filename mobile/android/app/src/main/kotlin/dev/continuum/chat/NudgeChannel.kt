package dev.continuum.chat

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import org.json.JSONObject

/** Registers NudgeTools for either the UI or foreground-task Flutter engine. */
internal class NudgeChannel(
    context: Context,
    messenger: BinaryMessenger,
) {
    private val appContext = context.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "call" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
                    val tool = args["tool"]?.toString().orEmpty()
                    val toolArgs = args["arguments"] as? Map<*, *> ?: emptyMap<Any?, Any?>()
                    executor.execute {
                        val response = try {
                            NudgeTools.call(appContext, tool, toolArgs)
                        } catch (error: Exception) {
                            "{\"error\":${JSONObject.quote(error.message ?: "unknown error")}}"
                        }
                        mainHandler.post { result.success(response) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val CHANNEL = "nudge"
        private val executor = Executors.newSingleThreadExecutor()
    }
}
