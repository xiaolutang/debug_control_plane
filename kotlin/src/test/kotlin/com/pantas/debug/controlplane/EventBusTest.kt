package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * BF002-4 tests: SharedFlow event bus semantics (multi-subscriber fan-out,
 * replay=0, DROP_OLDEST non-blocking producer) + ControlPlane.register
 * wiring (capability events -> bus -> transport.broadcast, sequence
 * assignment, unregister cancels collection).
 */
class EventBusTest {

    private lateinit var scope: CoroutineScope

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    // ---- SharedFlow semantics -------------------------------------------------

    @Test
    fun `multiple subscribers each receive every event`() = runBlocking {
        val bus = EventBus()
        val got1 = CopyOnWriteArrayList<DebugEvent>()
        val got2 = CopyOnWriteArrayList<DebugEvent>()
        val j1 = scope.launch { bus.shared.collect { got1 += it } }
        val j2 = scope.launch { bus.shared.collect { got2 += it } }
        emitUntilObserved(bus, got1, got2) // ensure both collectors attached

        bus.emit(DebugEvent("a", 0))
        withTimeout(2000) { while (got1.size < 1 || got2.size < 1) kotlinx.coroutines.delay(10) }
        assertEquals(listOf("a"), got1.map { it.type })
        assertEquals(listOf("a"), got2.map { it.type })

        j1.cancel(); j2.cancel()
    }

    @Test
    fun `replay is zero - new subscriber misses earlier events`() = runBlocking {
        val bus = EventBus()
        bus.emit(DebugEvent("before", 0))
        val got = CopyOnWriteArrayList<DebugEvent>()
        val job = scope.launch { bus.shared.collect { got += it } }
        kotlinx.coroutines.delay(100) // let the collector attach; no replay should arrive
        assertTrue("replay=0: subscriber must not receive pre-subscribe events", got.isEmpty())
        bus.emit(DebugEvent("after", 1))
        withTimeout(2000) { while (got.size < 1) kotlinx.coroutines.delay(10) }
        assertEquals(listOf("after"), got.map { it.type })
        job.cancel()
    }

    @Test
    fun `cancelled subscriber stops receiving, others unaffected`() = runBlocking {
        val bus = EventBus()
        val got1 = CopyOnWriteArrayList<DebugEvent>()
        val got2 = CopyOnWriteArrayList<DebugEvent>()
        val j1 = scope.launch { bus.shared.collect { got1 += it } }
        val j2 = scope.launch { bus.shared.collect { got2 += it } }
        kotlinx.coroutines.delay(100)

        j1.cancel()
        kotlinx.coroutines.delay(100) // cancellation settled
        bus.emit(DebugEvent("post-cancel", 0))
        withTimeout(2000) { while (got2.size < 1) kotlinx.coroutines.delay(10) }
        assertTrue("cancelled subscriber must receive nothing", got1.isEmpty())
        assertEquals(listOf("post-cancel"), got2.map { it.type })
        j2.cancel()
    }

    @Test
    fun `high-frequency emit over buffer does not block the producer`() = runBlocking {
        // No subscribers attached: DROP_OLDEST + tryEmit must absorb any rate.
        val bus = EventBus()
        val start = System.nanoTime()
        repeat(10_000) { bus.emit(DebugEvent("flood", it.toLong())) }
        val elapsedMs = (System.nanoTime() - start) / 1_000_000
        assertTrue("emit must never block (took ${elapsedMs}ms for 10k)", elapsedMs < 2000)
    }

    // ---- ControlPlane wiring ---------------------------------------------------

    @Test
    fun `capability event reaches transport broadcast with plane sequence`() = runBlocking {
        val transport = FakeTransport()
        val plane = ControlPlane(transport = transport, scope = scope)
        kotlinx.coroutines.runBlocking { plane.start(0) }   // installs dispatcher + bus pipe
        val cap = FakeCapability("alpha")
        plane.register(cap)
        // Ensure the per-capability collector attached (Unconfined launch
        // starts eagerly but the SharedFlow subscription needs a dispatch).
        kotlinx.coroutines.yield()

        cap.emit(DebugEvent("controller_state_changed", payload = mapOf("aKey1" to "value1")))
        withTimeout(2000) { while (transport.broadcasts.isEmpty()) kotlinx.coroutines.delay(10) }

        val event = transport.broadcasts.first()
        // §3.1: the plane assigns the global sequence; the raw value (0 default
        // here, but 99 below proves discard) is discarded.
        assertEquals("controller_state_changed", event.type)
        assertEquals(0L, event.sequence)
        assertEquals(mapOf<String, Any?>("aKey1" to "value1"), event.payload)
    }

    @Test
    fun `capability-provided sequence is discarded and globally renumbered`() = runBlocking {
        val transport = FakeTransport()
        val plane = ControlPlane(transport = transport, scope = scope)
        kotlinx.coroutines.runBlocking { plane.start(0) }   // installs dispatcher + bus pipe
        val a = FakeCapability("a")
        val b = FakeCapability("b")
        plane.register(a)
        plane.register(b)
        kotlinx.coroutines.yield()

        a.emit(DebugEvent("e1", sequence = 99))
        b.emit(DebugEvent("e2", sequence = 12345))
        withTimeout(2000) { while (transport.broadcasts.size < 2) kotlinx.coroutines.delay(10) }

        // Process-wide monotonic counter shared across capabilities, from 0.
        assertEquals(0L, transport.broadcasts[0].sequence)
        assertEquals(1L, transport.broadcasts[1].sequence)
    }

    @Test
    fun `unregister cancels the collection job - no leak`() = runBlocking {
        val transport = FakeTransport()
        val plane = ControlPlane(transport = transport, scope = scope)
        val cap = FakeCapability("alpha")
        plane.register(cap)
        // Let the collector attach.
        kotlinx.coroutines.delay(100)

        plane.unregister("alpha")
        kotlinx.coroutines.delay(100) // let cancellation settle
        val before = transport.broadcasts.size
        cap.emit(DebugEvent("after-unregister"))
        kotlinx.coroutines.delay(200)
        assertEquals("no events after unregister", before, transport.broadcasts.size)
    }

    @Test
    fun `bus fans out to both transport broadcast and bus collectors`() = runBlocking {
        val transport = FakeTransport()
        val plane = ControlPlane(transport = transport, scope = scope)
        val busSeen = CopyOnWriteArrayList<DebugEvent>()
        val collector = scope.launch { plane.eventBus.collect { busSeen += it } }
        kotlinx.coroutines.delay(100)

        kotlinx.coroutines.runBlocking { plane.start(0) }   // installs dispatcher + bus pipe
        val cap = FakeCapability("alpha")
        plane.register(cap)
        kotlinx.coroutines.yield()
        cap.emit(DebugEvent("fanout"))
        withTimeout(2000) {
            while (transport.broadcasts.isEmpty() || busSeen.isEmpty()) kotlinx.coroutines.delay(10)
        }
        assertEquals("transport.broadcast saw it", 1, transport.broadcasts.size)
        assertEquals("bus collector saw it", listOf("fanout"), busSeen.map { it.type })
        collector.cancel()
    }

    // ---- helper ---------------------------------------------------------------

    /** Emit a probe event repeatedly until both collector lists are non-empty. */
    private suspend fun emitUntilObserved(bus: EventBus, vararg lists: CopyOnWriteArrayList<DebugEvent>) {
        withTimeout(2000) {
            while (true) {
                bus.emit(DebugEvent("probe-${System.nanoTime()}", -1))
                kotlinx.coroutines.delay(20)
                if (lists.all { it.isNotEmpty() }) return@withTimeout
            }
        }
        // Strip probes.
        lists.forEach { it.clear() }
    }
}
