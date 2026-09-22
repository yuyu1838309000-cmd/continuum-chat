package dev.continuum.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceExecutionStateMachineTest {
    private val fingerprint = "a".repeat(64)

    @Test
    fun `concurrent claim never grants the physical action twice`() {
        val store = MemoryStore()
        val machine = DeviceExecutionStateMachine(store) { 10L }

        assertEquals(
            DeviceExecutionClaimStatus.ACQUIRED,
            machine.claim("key", "gen", "call", fingerprint).status,
        )
        assertEquals(
            DeviceExecutionClaimStatus.IN_FLIGHT,
            machine.claim("key", "gen", "call", fingerprint).status,
        )
        assertTrue(
            machine.storeResult(
                "key",
                "gen",
                "call",
                fingerprint,
                "{\"ok\":true}",
            ),
        )
        val replay = machine.claim("key", "gen", "call", fingerprint)
        assertEquals(DeviceExecutionClaimStatus.EXECUTED, replay.status)
        assertEquals("{\"ok\":true}", replay.resultJson)
    }

    @Test
    fun `restart after claim fails closed instead of acquiring again`() {
        val store = MemoryStore()
        val first = DeviceExecutionStateMachine(store) { 10L }
        assertEquals(
            DeviceExecutionClaimStatus.ACQUIRED,
            first.claim("key", "gen", "call", fingerprint).status,
        )

        val restarted = DeviceExecutionStateMachine(store) { 20L }
        val recovered = restarted.claim("key", "gen", "call", fingerprint)

        assertEquals(DeviceExecutionClaimStatus.EXECUTED, recovered.status)
        assertEquals(
            DeviceExecutionStateMachine.UNCERTAIN_RESULT_JSON,
            recovered.resultJson,
        )
        assertEquals(DeviceExecutionState.EXECUTED, store.records["key"]?.state)
    }

    @Test
    fun `fingerprint conflict and premature completion fail closed`() {
        val store = MemoryStore()
        val machine = DeviceExecutionStateMachine(store)
        assertEquals(
            DeviceExecutionClaimStatus.ACQUIRED,
            machine.claim("key", "gen", "call", fingerprint).status,
        )

        assertFalse(machine.complete("key", "gen", "call", fingerprint))
        assertEquals(
            DeviceExecutionClaimStatus.CONFLICT,
            machine.claim("key", "gen", "call", "b".repeat(64)).status,
        )
    }

    @Test
    fun `completed tombstone remains replay safe`() {
        val store = MemoryStore()
        val machine = DeviceExecutionStateMachine(store)
        assertEquals(
            DeviceExecutionClaimStatus.ACQUIRED,
            machine.claim("key", "gen", "call", fingerprint).status,
        )
        assertTrue(
            machine.storeResult(
                "key",
                "gen",
                "call",
                fingerprint,
                "{\"ok\":true}",
            ),
        )
        assertTrue(machine.complete("key", "gen", "call", fingerprint))

        assertEquals(
            DeviceExecutionClaimStatus.COMPLETED,
            machine.claim("key", "gen", "call", fingerprint).status,
        )
    }

    private class MemoryStore : DeviceExecutionStore {
        val records = mutableMapOf<String, DeviceExecutionRecord>()

        override fun read(key: String): DeviceExecutionRecord? = records[key]

        override fun write(key: String, record: DeviceExecutionRecord): Boolean {
            records[key] = record
            return true
        }
    }
}
