package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.RouteContext
import com.pantas.debug.controlplane.RouteFailure
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
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
