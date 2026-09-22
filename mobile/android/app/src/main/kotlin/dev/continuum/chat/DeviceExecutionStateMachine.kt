package dev.continuum.chat

internal enum class DeviceExecutionState {
    CLAIMED,
    EXECUTED,
    COMPLETED,
}

internal data class DeviceExecutionRecord(
    val generationId: String,
    val toolCallId: String,
    val fingerprint: String,
    val state: DeviceExecutionState,
    val resultJson: String? = null,
    val updatedAtMs: Long,
)

internal interface DeviceExecutionStore {
    fun read(key: String): DeviceExecutionRecord?

    fun write(key: String, record: DeviceExecutionRecord): Boolean
}

internal enum class DeviceExecutionClaimStatus {
    ACQUIRED,
    IN_FLIGHT,
    EXECUTED,
    COMPLETED,
    CONFLICT,
    STORAGE_ERROR,
}

internal data class DeviceExecutionClaim(
    val status: DeviceExecutionClaimStatus,
    val resultJson: String? = null,
)

/**
 * Process-wide, durable arbiter for physical device actions.
 *
 * Flutter's UI and foreground-task isolates have separate Dart heaps. This
 * state machine is therefore the final claim authority shared by both engines.
 * A durable CLAIMED record is committed before the caller may touch the phone.
 */
internal class DeviceExecutionStateMachine(
    private val store: DeviceExecutionStore,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    private val active = mutableSetOf<String>()

    @Synchronized
    fun claim(
        key: String,
        generationId: String,
        toolCallId: String,
        fingerprint: String,
    ): DeviceExecutionClaim {
        if (!validIdentity(generationId, toolCallId, fingerprint)) {
            return DeviceExecutionClaim(DeviceExecutionClaimStatus.CONFLICT)
        }
        return try {
            val existing = store.read(key)
            if (existing != null) {
                if (existing.generationId != generationId ||
                    existing.toolCallId != toolCallId ||
                    existing.fingerprint != fingerprint
                ) {
                    return DeviceExecutionClaim(DeviceExecutionClaimStatus.CONFLICT)
                }
                return when (existing.state) {
                    DeviceExecutionState.COMPLETED ->
                        DeviceExecutionClaim(DeviceExecutionClaimStatus.COMPLETED)
                    DeviceExecutionState.EXECUTED -> {
                        val result = existing.resultJson
                            ?: return DeviceExecutionClaim(DeviceExecutionClaimStatus.STORAGE_ERROR)
                        DeviceExecutionClaim(DeviceExecutionClaimStatus.EXECUTED, result)
                    }
                    DeviceExecutionState.CLAIMED -> {
                        if (key in active) {
                            DeviceExecutionClaim(DeviceExecutionClaimStatus.IN_FLIGHT)
                        } else {
                            // The process/engine died after its durable claim. Never run the
                            // physical action again; surface an explicit uncertain outcome.
                            val uncertain = UNCERTAIN_RESULT_JSON
                            val recovered = existing.copy(
                                state = DeviceExecutionState.EXECUTED,
                                resultJson = uncertain,
                                updatedAtMs = nowMs(),
                            )
                            if (store.write(key, recovered)) {
                                DeviceExecutionClaim(DeviceExecutionClaimStatus.EXECUTED, uncertain)
                            } else {
                                DeviceExecutionClaim(DeviceExecutionClaimStatus.STORAGE_ERROR)
                            }
                        }
                    }
                }
            }

            val claimed = DeviceExecutionRecord(
                generationId = generationId,
                toolCallId = toolCallId,
                fingerprint = fingerprint,
                state = DeviceExecutionState.CLAIMED,
                updatedAtMs = nowMs(),
            )
            if (!store.write(key, claimed)) {
                DeviceExecutionClaim(DeviceExecutionClaimStatus.STORAGE_ERROR)
            } else {
                active.add(key)
                DeviceExecutionClaim(DeviceExecutionClaimStatus.ACQUIRED)
            }
        } catch (_: Exception) {
            DeviceExecutionClaim(DeviceExecutionClaimStatus.STORAGE_ERROR)
        }
    }

    @Synchronized
    fun storeResult(
        key: String,
        generationId: String,
        toolCallId: String,
        fingerprint: String,
        resultJson: String,
    ): Boolean {
        return try {
            val existing = store.read(key) ?: return false
            if (existing.generationId != generationId ||
                existing.toolCallId != toolCallId ||
                existing.fingerprint != fingerprint ||
                existing.state != DeviceExecutionState.CLAIMED ||
                key !in active
            ) {
                return false
            }
            store.write(
                key,
                existing.copy(
                    state = DeviceExecutionState.EXECUTED,
                    resultJson = resultJson,
                    updatedAtMs = nowMs(),
                ),
            )
        } catch (_: Exception) {
            false
        } finally {
            active.remove(key)
        }
    }

    @Synchronized
    fun complete(
        key: String,
        generationId: String,
        toolCallId: String,
        fingerprint: String,
    ): Boolean {
        return try {
            val existing = store.read(key) ?: return false
            if (existing.generationId != generationId ||
                existing.toolCallId != toolCallId ||
                existing.fingerprint != fingerprint ||
                existing.state == DeviceExecutionState.CLAIMED
            ) {
                return false
            }
            if (existing.state == DeviceExecutionState.COMPLETED) return true
            store.write(
                key,
                existing.copy(
                    state = DeviceExecutionState.COMPLETED,
                    resultJson = null,
                    updatedAtMs = nowMs(),
                ),
            )
        } catch (_: Exception) {
            false
        }
    }

    private fun validIdentity(
        generationId: String,
        toolCallId: String,
        fingerprint: String,
    ): Boolean = generationId.isNotBlank() &&
        toolCallId.isNotBlank() &&
        SHA_256.matches(fingerprint)

    companion object {
        private val SHA_256 = Regex("^[0-9a-f]{64}$")
        const val UNCERTAIN_RESULT_JSON =
            "{\"ok\":false,\"error\":\"device_execution_uncertain\",\"message\":\"device action outcome unknown after app restart\"}"
    }
}
