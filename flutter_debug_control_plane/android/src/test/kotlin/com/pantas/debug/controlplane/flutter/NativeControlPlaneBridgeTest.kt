package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.RouteContext
import com.pantas.debug.controlplane.RouteFailure
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * FF001-2 unit tests: reverse invoke over a fake channel — reqId
 * correlation, 30s-timeout -> 500 internal_error (B4), event flow wiring.
 */
class NativeControlPlaneBridgeTest {

    private fun newBridge(channel: FakeMethodChannel): NativeControlPlaneBridge =
        NativeControlPlaneBridge(channel, FakeMethodChannel.scope)

    @Test
    fun `reverse invoke carries reqId capId routeKind routeIndex pathParams body`() = runBlocking {
        val channel = FakeMethodChannel()
        val bridge = newBridge(channel)
        channel.dartAnswer = { record ->
            if (record.method == ChannelProtocol.CAPABILITY_INVOKE) {
                bridge.completeInvoke(
                    record.reqId,
                    mapOf("result" to mapOf("ok" to true)),
                )
            }
        }

        val result = bridge.invokeHandler(
            "gamepad",
            ChannelProtocol.ROUTE_KIND_COMMAND,
            3,
            RouteContext(pathParams = mapOf("id" to "left"), body = mapOf("button" to "A")),
        )

        assertEquals(mapOf("ok" to true), result)
        val invoke = channel.invokes.single()
        assertEquals(ChannelProtocol.CAPABILITY_INVOKE, invoke.method)
        assertEquals("gamepad", invoke.capId)
        assertEquals("command", invoke.arguments["routeKind"])
        assertEquals(3, invoke.arguments["routeIndex"])
        assertEquals(mapOf("id" to "left"), invoke.arguments["pathParams"])
        assertEquals(mapOf("button" to "A"), invoke.arguments["body"])
        assertTrue(invoke.reqId > 0)
        assertTrue(bridge.pending.isEmpty()) // cleaned up after completion
    }

    @Test
    fun `timeout resolves 500 internal_error`() = runBlocking {
        val channel = FakeMethodChannel()
        val bridge = newBridge(channel).apply { invokeTimeoutMs = 50 }
        channel.dartAnswer = { /* Dart never fills in */ }

        try {
            bridge.invokeHandler("gamepad", ChannelProtocol.ROUTE_KIND_RESOURCE, 0, RouteContext())
            fail("expected RouteFailure")
        } catch (e: RouteFailure) {
            assertEquals(500, e.statusCode)
            assertEquals("internal_error", e.code)
            assertTrue(e.message!!.contains("timed out"))
        }
        assertTrue(bridge.pending.isEmpty())
    }

    @Test
    fun `fill-in with error envelope maps to RouteFailure`() = runBlocking {
        val channel = FakeMethodChannel()
        val bridge = newBridge(channel)
        channel.dartAnswer = { record ->
            bridge.completeInvoke(
                record.reqId,
                mapOf(
                    "error" to mapOf(
                        "statusCode" to 409,
                        "code" to "real_controller_active",
                        "message" to "busy",
                    ),
                ),
            )
        }

        try {
            bridge.invokeHandler("gamepad", ChannelProtocol.ROUTE_KIND_RESOURCE, 0, RouteContext())
            fail("expected RouteFailure")
        } catch (e: RouteFailure) {
            assertEquals(409, e.statusCode)
            assertEquals("real_controller_active", e.code)
            assertEquals("busy", e.message)
        }
    }

    @Test
    fun `fill-in with unknown reqId is rejected`() = runBlocking {
        val channel = FakeMethodChannel()
        val bridge = newBridge(channel)
        channel.dartAnswer = { }

        val job = async {
            try {
                bridge.invokeHandler("gamepad", ChannelProtocol.ROUTE_KIND_RESOURCE, 0, RouteContext())
            } catch (e: RouteFailure) {
                // timeout path (50ms below)
            }
        }
        // unknown reqId -> false, does not throw
        assertTrue(!bridge.completeInvoke(9999L, mapOf("result" to mapOf("ok" to true))))
        bridge.invokeTimeoutMs = 50
        job.join()
    }

    @Test
    fun `events emit feeds the per-capability flow and Dart sequence is discarded`() = runBlocking {
        val channel = FakeMethodChannel()
        val bridge = newBridge(channel)

        val flow = bridge.eventFlow("gamepad")
        val collected = mutableListOf<Long>()
        val collector = FakeMethodChannel.scope.launch {
            flow.collect { collected += it.sequence }
        }
        delay(50) // let the collector subscribe

        // Plugin EVENTS_EMIT path logic: type + payload, sequence forced 0.
        bridge.eventFlow("gamepad").tryEmit(
            com.pantas.debug.controlplane.DebugEvent(
                type = "pressed",
                sequence = 0L,
                payload = mapOf("key" to "A"),
            ),
        )
        delay(50)
        collector.cancel()

        assertEquals(listOf(0L), collected)
    }

    @Test
    fun `state pull reverse invoke correlates via capability state result`() = runBlocking {        val channel = FakeMethodChannel()
        val bridge = newBridge(channel)
        channel.dartAnswer = { record ->
            if (record.method == ChannelProtocol.CAPABILITY_STATE_PULL) {
                bridge.completeState(record.reqId, mapOf("connected" to true))
            }
        }

        val state = bridge.pullState("gamepad")
        assertEquals(mapOf("connected" to true), state)
        assertEquals(ChannelProtocol.CAPABILITY_STATE_PULL, channel.invokes.single().method)
    }

    @Test
    fun `auth request invokes Dart without capability pending entry`() {
        val channel = FakeMethodChannel()
        val bridge = newBridge(channel)

        bridge.requestAuthorization(
            mapOf(
                "requestId" to "auth-1",
                "pairingCode" to "123456",
                "status" to "pending",
                "clientLabel" to "devtool",
                "method" to "GET",
                "endpoint" to "/state",
            ),
        )

        assertEquals(ChannelProtocol.AUTH_REQUEST, channel.invokes.single().method)
        assertEquals("auth-1", channel.invokes.single().arguments["requestId"])
        assertFalse(channel.invokes.single().arguments.containsKey("capId"))
        assertTrue("auth pending must not share capability pending map", bridge.pending.isEmpty())
    }

    @Test
    fun `auth request tolerates executor rejection`() {
        val channel = FakeMethodChannel()
        val rejecting = java.util.concurrent.Executor { throw java.util.concurrent.RejectedExecutionException("closed") }
        val bridge = NativeControlPlaneBridge(channel, FakeMethodChannel.scope, rejecting)

        bridge.requestAuthorization(mapOf("requestId" to "auth-2", "status" to "pending"))

        assertTrue(channel.invokes.isEmpty())
        assertTrue(bridge.pending.isEmpty())
    }

    @Test
    fun `auth request tolerates invokeMethod throwing inside executor command`() {
        val channel = FakeMethodChannel().apply {
            invokeFailure = IllegalStateException("detached")
        }
        val bridge = newBridge(channel)

        bridge.requestAuthorization(mapOf("requestId" to "auth-3", "status" to "pending"))

        assertTrue(channel.invokes.isEmpty())
        assertTrue(bridge.pending.isEmpty())
    }

    // ---- R026 e2e fix: reverse invoke must hop to the main executor ---------
    // Real-device /hello hit "@UiThread methods must be executed on the main
    // thread" — reverseInvoke ran channel.invokeMethod on the NanoHTTPD
    // worker. The bridge now posts it to an injectable mainExecutor (JVM
    // tests: direct passthrough; production: main-thread Handler).

    /** Executor that records submissions and the threads that ran them. */
    private class RecordingExecutor : java.util.concurrent.Executor {
        val submitted = java.util.concurrent.atomic.AtomicInteger()
        val executedOn = mutableListOf<Thread>()

        override fun execute(command: Runnable) {
            submitted.incrementAndGet()
            synchronized(executedOn) { executedOn += Thread.currentThread() }
            command.run()
        }
    }

    @Test
    fun `reverse invoke executes invokeMethod on the injected main executor`() = runBlocking {
        val channel = FakeMethodChannel()
        val executor = RecordingExecutor()
        val bridge = NativeControlPlaneBridge(channel, FakeMethodChannel.scope, executor)
        channel.dartAnswer = { record ->
            bridge.completeInvoke(record.reqId, mapOf("result" to mapOf("ok" to true)))
        }

        // Simulate the production caller: a non-main worker thread (the
        // NanoHTTPD request processor) issues the reverse invoke.
        val result = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            bridge.invokeHandler("gamepad", ChannelProtocol.ROUTE_KIND_RESOURCE, 0, RouteContext())
        }
        assertEquals(mapOf("ok" to true), result)

        // The invokeMethod hop actually went through the executor (thread
        // mark proves it did NOT run on the caller's thread).
        assertEquals(1, executor.submitted.get())
        val callerThread = Thread.currentThread()
        val executedThread = synchronized(executor.executedOn) { executor.executedOn.single() }
        assertTrue(
            "invokeMethod must run on the injected executor, not the caller thread",
            executedThread !== callerThread,
        )
        // Exactly one reverse invoke reached the "Dart" side, via the hop.
        assertEquals(1, channel.invokes.size)
    }

    @Test
    fun `pending entry is registered before the invokeMethod post`() = runBlocking {
        val channel = FakeMethodChannel()
        // The executor observes pending state at run time (i.e. AFTER the
        // post was made): the deferred must already be registered when
        // invokeMethod runs, or a fast Dart reply would race the
        // registration and get "unknown reqId".
        lateinit var bridgeRef: NativeControlPlaneBridge
        val pendingSizesAtExecution = mutableListOf<Int>()
        val executor = java.util.concurrent.Executor { command ->
            synchronized(pendingSizesAtExecution) {
                pendingSizesAtExecution += bridgeRef.pending.size
            }
            command.run()
        }
        val bridge = NativeControlPlaneBridge(channel, FakeMethodChannel.scope, executor)
        bridgeRef = bridge
        channel.dartAnswer = { record ->
            bridge.completeState(record.reqId, mapOf("connected" to true))
        }

        val state = bridge.pullState("gamepad")
        assertEquals(mapOf("connected" to true), state)
        // At executor-run time (post already dispatched) the reqId was
        // registered — and the fill-in above answered from `pending` (the
        // pullState returned instead of timing out), proving registration
        // precedes the post.
        assertEquals(listOf(1), synchronized(pendingSizesAtExecution) { pendingSizesAtExecution })
    }

    @Test
    fun `executor rejection does not leak the pending entry`() = runBlocking {
        val channel = FakeMethodChannel()
        // An executor that rejects (production never does — Handler never
        // throws — but the contract must hold): the pending reqId must be
        // cleaned by the finally block, not sit until a timeout that never
        // fires for it.
        val rejectingExecutor = java.util.concurrent.Executor {
            throw java.util.concurrent.RejectedExecutionException("test rejection")
        }
        val bridge = NativeControlPlaneBridge(channel, FakeMethodChannel.scope, rejectingExecutor)

        val thrown = runCatching {
            bridge.pullState("gamepad")
        }.exceptionOrNull()
        assertTrue(thrown is java.util.concurrent.RejectedExecutionException)
        // The whole point: no orphaned pending entry.
        assertTrue("pending must be empty after executor rejection", bridge.pending.isEmpty())
    }

    // ---- R026 e2e defect #2: org.json types must not cross the boundary ----
    // Real-device POST /input with a nested body crashed the app:
    // StandardMessageCodec.writeValue threw IllegalArgumentException on
    // org.json.JSONObject (the Kotlin core parses POST bodies with org.json,
    // so nested values inside RouteContext.body are JSONObject/JSONArray).
    // The reverse-invoke args must carry only codec-safe plain types.

    /** Recursive assertion: no JSONObject/JSONArray anywhere in the args. */
    private fun assertNoOrgJson(value: Any?) {
        when (value) {
            is org.json.JSONObject -> throw AssertionError("JSONObject leaked at $value")
            is org.json.JSONArray -> throw AssertionError("JSONArray leaked at $value")
            is Map<*, *> -> value.values.forEach { assertNoOrgJson(it) }
            is List<*> -> value.forEach { assertNoOrgJson(it) }
        }
    }

    @Test
    fun `reverse invoke args carry no org json types for nested body`() = runBlocking {
        val channel = FakeMethodChannel()
        val bridge = newBridge(channel)
        channel.dartAnswer = { record ->
            bridge.completeInvoke(record.reqId, mapOf("result" to mapOf("ok" to true)))
        }

        // RouteContext.body the way the Kotlin core hands it over after
        // org.json parsing: nested JSONObject/JSONArray + JSONObject.NULL.
        val body = linkedMapOf<String, Any?>(
            "action" to "dpad_down",
            "frame" to org.json.JSONObject(
                """{"keys":["down"],"dur":1.5,"n":JSONObject.NULL}""".replace(
                    "JSONObject.NULL",
                    "null",
                ),
            ),
            "tags" to org.json.JSONArray("""["a",{"b":[1,2]}]"""),
        )
        bridge.invokeHandler(
            "gamepad",
            ChannelProtocol.ROUTE_KIND_COMMAND,
            0,
            RouteContext(pathParams = mapOf("id" to "left"), body = body),
        )

        val args = channel.invokes.single().arguments
        assertNoOrgJson(args)
        val wireBody = args["body"] as Map<*, *>
        assertEquals(listOf("down"), (wireBody["frame"] as Map<*, *>)["keys"])
        // org.json integers decode as Integer on the JVM stub (and on
        // Android) — pass-through, no Long coercion.
        assertEquals(listOf("a", mapOf("b" to listOf(1, 2))), wireBody["tags"])
        assertEquals(mapOf("id" to "left"), args["pathParams"]) // untouched sibling field
    }

    @Test
    fun `teardown fails only the torn-down capability's pending invokes`() = runBlocking {
        val channel = FakeMethodChannel()
        val bridge = newBridge(channel).apply { invokeTimeoutMs = 5_000 }
        // Two in-flight invokes for two different caps; neither fills in.
        channel.dartAnswer = { }
        val doomed = async {
            try {
                bridge.invokeHandler("gamepad", ChannelProtocol.ROUTE_KIND_RESOURCE, 0, RouteContext())
            } catch (e: RouteFailure) {
                e // expected: torn down
            }
        }
        val survivor = async {
            bridge.invokeHandler("other", ChannelProtocol.ROUTE_KIND_RESOURCE, 0, RouteContext())
        }
        channel.awaitInvokeCount(2)

        bridge.teardownCapability("gamepad")

        val failure = doomed.await() as RouteFailure
        assertEquals(500, failure.statusCode)
        assertEquals("internal_error", failure.code)
        assertTrue(failure.message!!.contains("gamepad"))

        // The unrelated cap's invoke survives the teardown.
        bridge.completeInvoke(
            channel.invokes.single { it.capId == "other" }.reqId,
            mapOf("result" to mapOf("ok" to true)),
        )
        assertEquals(mapOf("ok" to true), survivor.await())
    }
}
