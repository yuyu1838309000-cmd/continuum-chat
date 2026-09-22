package dev.continuum.chat

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Platform channel exposing the process-wide device execution claim authority. */
internal class DeviceExecutionChannel(
    context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        val stateMachine = stateMachine(context.applicationContext)
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
            val generationId = args["generation_id"]?.toString()?.trim().orEmpty()
            val toolCallId = args["tool_call_id"]?.toString()?.trim().orEmpty()
            val fingerprint = args["fingerprint"]?.toString()?.trim().orEmpty()
            val key = canonicalKey(generationId, toolCallId)
            when (call.method) {
                "claim" -> {
                    val claim = stateMachine.claim(
                        key,
                        generationId,
                        toolCallId,
                        fingerprint,
                    )
                    result.success(
                        mapOf(
                            "status" to claim.status.name.lowercase(),
                            "result_json" to claim.resultJson,
                        ),
                    )
                }
                "storeResult" -> {
                    val resultJson = args["result_json"]?.toString().orEmpty()
                    result.success(
                        stateMachine.storeResult(
                            key,
                            generationId,
                            toolCallId,
                            fingerprint,
                            resultJson,
                        ),
                    )
                }
                "complete" -> result.success(
                    stateMachine.complete(
                        key,
                        generationId,
                        toolCallId,
                        fingerprint,
                    ),
                )
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private class SharedPreferencesStore(context: Context) : DeviceExecutionStore {
        private val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        override fun read(key: String): DeviceExecutionRecord? {
            val raw = preferences.getString(RECORD_PREFIX + key, null) ?: return null
            val json = JSONObject(raw)
            val state = DeviceExecutionState.valueOf(json.getString("state"))
            val resultJson = if (json.has("result_json") && !json.isNull("result_json")) {
                json.getString("result_json")
            } else {
                null
            }
            return DeviceExecutionRecord(
                generationId = json.getString("generation_id"),
                toolCallId = json.getString("tool_call_id"),
                fingerprint = json.getString("fingerprint"),
                state = state,
                resultJson = resultJson,
                updatedAtMs = json.getLong("updated_at_ms"),
            )
        }

        override fun write(key: String, record: DeviceExecutionRecord): Boolean {
            val json = JSONObject()
                .put("generation_id", record.generationId)
                .put("tool_call_id", record.toolCallId)
                .put("fingerprint", record.fingerprint)
                .put("state", record.state.name)
                .put("updated_at_ms", record.updatedAtMs)
            if (record.resultJson != null) json.put("result_json", record.resultJson)
            // commit() is intentional: ACQUIRED must never be returned before the
            // durable CLAIMED record reaches disk.
            return preferences.edit().putString(RECORD_PREFIX + key, json.toString()).commit()
        }
    }

    companion object {
        private const val CHANNEL = "continuum/device_execution"
        private const val PREFS_NAME = "continuum_device_execution_v1"
        private const val RECORD_PREFIX = "record:"

        @Volatile
        private var singleton: DeviceExecutionStateMachine? = null

        private fun stateMachine(context: Context): DeviceExecutionStateMachine {
            singleton?.let { return it }
            return synchronized(this) {
                singleton ?: DeviceExecutionStateMachine(SharedPreferencesStore(context)).also {
                    singleton = it
                }
            }
        }

        private fun canonicalKey(generationId: String, toolCallId: String): String =
            "${generationId.length}:$generationId$toolCallId"
    }
}
