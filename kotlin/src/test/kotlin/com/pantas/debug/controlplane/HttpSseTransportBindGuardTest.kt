package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.BindException

/**
 * R026-BF001-3 (F4 transport guard): bind re-entry protection + boundPort
 * reset on close — the backstop beneath the plane's start-once, so a
 * stop->start reuse of the same transport instance cannot hit NanoHTTPD's
 * broken second-bind behavior (new socket overwrites the old field, dead
 * accept loop hot-spins, old LISTEN silently dies on GC).
 */
class HttpSseTransportBindGuardTest {

    private lateinit var scope: CoroutineScope
    private lateinit var transport: HttpSseTransport

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        transport = HttpSseTransport(scope, port = 0)
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    @Test
    fun `second bind throws BindException`() = runBlocking {
        transport.bind(0)

        try {
            transport.bind(0)
            throw AssertionError("expected BindException on re-bind")
        } catch (e: BindException) {
            assertTrue(
                "guard message must name the bound port: ${e.message}",
                e.message!!.contains("already bound"),
            )
        }
    }

    @Test
    fun `close resets boundPort and allows rebinding`() = runBlocking {
        val first = transport.bind(0)
        transport.close()

        val second = transport.bind(0)
        // OS-picked ports may differ; what matters is that the re-bind is
        // allowed (no BindException from the guard) and serves a live port,
        // with boundPort tracking the NEW bind (not the stale first one).
        assertNotEquals(0, second.port)
        assertEquals(second.port, transport.listeningPort)
        transport.close()
    }
}
