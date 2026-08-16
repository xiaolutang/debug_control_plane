package com.pantas.debug.controlplane

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.BindException
import java.net.URI

/**
 * R026-BF001-1: start-once semantics (ownership model — the Service owns the
 * server lifecycle; `plane.start` = first call really binds, later calls join
 * the cached result).
 *
 * Design hard rules under test (design §1.1):
 *  - sequential double start returns the SAME uri and binds once;
 *  - concurrent starts join the first bind while it is genuinely in flight;
 *  - failure is cached and rethrown (Dart sees the same failure for the R024
 *    degradation) until stop() clears it;
 *  - stop() clears start state, restart is allowed;
 *  - restart after stop has no stale bus->transport collector (a leaked old
 *    pipe would double-deliver every broadcast).
 */
class ControlPlaneStartOnceTest {

    private lateinit var scope: CoroutineScope
    private lateinit var transport: BindCountingFakeTransport
    private lateinit var plane: ControlPlane

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        transport = BindCountingFakeTransport()
        plane = ControlPlane(transport = transport, scope = scope)
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun hello(): Map<String, Any?> = runBlocking {
        val result = plane.dispatch(RouteRequest(method = "GET", segments = listOf("hello")))
        (result as RouteResult.Ok).body
    }

    @Test
    fun `start twice sequentially returns same uri and binds once`() = runBlocking {
        val first = plane.start(18080)
        val second = plane.start(18080)

        assertEquals(first, second)
        assertEquals(1, transport.bindCount)
    }

    @Test
    fun `concurrent starts join the first bind`() = runBlocking {
        // Hold the first bind genuinely in flight so the second start sees
        // the in-flight job (not a completed cache).
        transport.bindGate = CompletableDeferred()
        val a = scope.async { plane.start(18080) }
        withTimeout(2000) { while (transport.bindCount < 1) delay(10) }

        val b = scope.async { plane.start(18080) }
        delay(50) // give B time to (wrongly) attempt its own bind, if buggy
        assertEquals("second start must not bind while first is in flight", 1, transport.bindCount)

        transport.bindGate!!.complete(Unit)
        assertEquals(a.await(), b.await())
        assertEquals(1, transport.bindCount)
    }

    @Test
    fun `start failure is cached and rethrown`() = runBlocking {
        transport.bindError = BindException("addr in use")

        try {
            plane.start(18080)
            throw AssertionError("expected BindException")
        } catch (_: BindException) {}

        // Second caller sees the SAME failure instance (Dart join path ->
        // R024 degradation), and no second bind was attempted.
        try {
            plane.start(18080)
            throw AssertionError("expected cached BindException rethrow")
        } catch (e: BindException) {
            assertSame("failure must be the cached instance", transport.bindError, e)
        }
        assertEquals(1, transport.bindCount)
    }

    @Test
    fun `stop clears state and allows restart`() = runBlocking {
        val first = plane.start(18080)
        plane.stop()

        transport.bindError = null
        val second = plane.start(18080)

        assertEquals(first, second)
        assertEquals(2, transport.bindCount)
        assertTrue(transport.closed) // first cycle closed before the restart
    }

    @Test
    fun `updateAppMeta is reflected in hello`() {
        // Initially no appMeta (constructed with none).
        assertTrue("no app key before injection", !hello().containsKey("app"))

        plane.updateAppMeta { mapOf("app" to "pantas", "deviceId" to "d1") }
        val body = hello()
        assertEquals("pantas", body["app"])
        assertEquals("d1", body["deviceId"])
    }

    @Test
    fun `stop during an in-flight bind rejects the stale cache write`() = runBlocking {
        // The startAttempt-token race (design hard rule 3): stop() lands while
        // a bind is genuinely in flight; the cancelled bind may still run to
        // completion (cancellation is cooperative — a real NanoHTTPD start()
        // ignores it), and its outcome MUST be rejected as stale: no cached
        // success for a torn-down server, no cached failure either.
        transport.bindGate = CompletableDeferred()
        val startJob = scope.async { plane.start(18080) }
        withTimeout(2000) { while (transport.bindCount < 1) delay(10) }

        plane.stop()
        transport.bindGate!!.complete(Unit) // the "cancelled" bind finishes anyway

        try {
            startJob.await()
            throw AssertionError("in-flight start must fail after stop cancelled it")
        } catch (_: Throwable) {
            // cancelled first caller — either CancellationException or the
            // bind outcome racing the cancel; the cache is what matters:
        }

        // A later caller must NOT see the stale outcome: this start performs
        // a fresh bind (attempt #2), not a join of the dead attempt #1.
        transport.bindError = null
        val second = plane.start(18080)
        assertEquals("stale in-flight result must not be joined", 2, transport.bindCount)
        assertEquals(URI("http://0.0.0.0:18080/"), second)
    }

    @Test
    fun `stop during an in-flight bind failure does not cache the stale failure`() = runBlocking {
        // The failure branch of the same guard: a bind that fails AFTER stop
        // must not poison the next cycle with a cached failure.
        transport.bindGate = CompletableDeferred()
        val startJob = scope.async { plane.start(18080) }
        withTimeout(2000) { while (transport.bindCount < 1) delay(10) }

        plane.stop()
        transport.bindError = BindException("stale failure from a torn-down cycle")
        transport.bindGate!!.complete(Unit)
        try { startJob.await() } catch (_: Throwable) {}
        transport.bindError = null // the fresh cycle's bind succeeds

        // Fresh cycle succeeds — the stale failure was rejected by the rotated
        // startAttempt token, not cached for this caller to rethrow.
        val second = plane.start(18080)
        assertEquals(2, transport.bindCount)
        assertEquals(URI("http://0.0.0.0:18080/"), second)
    }

    @Test
    fun `restart after stop binds a fresh pipe`() = runBlocking {
        plane.start(18080)
        plane.stop()
        plane.start(18080)

        // A stale (uncancelled) pipe from the first cycle would collect the
        // SAME hot bus and double-deliver every event to the transport.
        val cap = FakeCapability("probe")
        plane.register(cap)
        cap.emit(DebugEvent("restart.probe", 0, mapOf("n" to 1)))
        assertEquals(
            "exactly one live bus->transport pipe after restart",
            1,
            transport.broadcasts.count { it.type == "restart.probe" },
        )
    }

    /**
     * FakeTransport + bind counting + programmable failure/gate. Local to
     * this suite because the shared [FakeTransport] (Fakes.kt) exposes
     * neither a bind counter nor bind failure control.
     */
    private class BindCountingFakeTransport : Transport {
        var bindCount = 0
            private set
        var bindError: BindException? = null

        /** When set, bind() suspends on it before returning (join test). */
        var bindGate: CompletableDeferred<Unit>? = null

        val broadcasts = mutableListOf<DebugEvent>()
        var handler: (suspend (RouteRequest) -> RouteResult)? = null
        var closed = false
            private set

        override suspend fun bind(port: Int): URI {
            bindCount += 1
            // A real NanoHTTPD start() is a blocking call that ignores
            // coroutine cancellation — model that: the gate (and the post-gate
            // failure) resolve even when the caller's job was cancelled
            // mid-bind, so a stop-during-bind race genuinely completes.
            withContext(NonCancellable) { bindGate?.await() }
            bindError?.let { throw it }
            return URI("http://0.0.0.0:$port/")
        }

        override fun listen(handler: suspend (RouteRequest) -> RouteResult) {
            this.handler = handler
        }

        override suspend fun serverInfo(request: Any?): Map<String, Any?> = emptyMap()
        override fun broadcast(event: DebugEvent) {
            broadcasts += event
        }

        override suspend fun close() {
            closed = true
        }
    }
}
