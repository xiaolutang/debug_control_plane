package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.Command
import com.pantas.debug.controlplane.ControlPlane
import com.pantas.debug.controlplane.Resource
import com.pantas.debug.controlplane.RouteContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * FF001-2 unit tests: Decl deserialization + BridgeCapability wiring —
 * register populates the native plane registry, dispatch reaches the
 * reverse invoke with the right routeIndex.
 */
class DartCapabilityRegistryTest {

    private class RecordingInvoker : DartReverseInvoker {
        val invokes = mutableListOf<Triple<String, String, Int>>() // (capId, kind, index)
        val flows = mutableMapOf<String, MutableSharedFlow<com.pantas.debug.controlplane.DebugEvent>>()

        override fun eventFlow(capId: String): MutableSharedFlow<com.pantas.debug.controlplane.DebugEvent> =
            flows.getOrPut(capId) { MutableSharedFlow(extraBufferCapacity = 64) }

        override suspend fun invokeHandler(
            capId: String,
            routeKind: String,
            routeIndex: Int,
            context: RouteContext,
        ): Map<String, Any?> {
            invokes += Triple(capId, routeKind, routeIndex)
            return mapOf("ok" to true, "kind" to routeKind, "index" to routeIndex)
        }

        override suspend fun pullState(capId: String): Map<String, Any?> = mapOf("capId" to capId)
    }

    @Test
    fun `register deserializes decls with path as JSON array`() {
        val invoker = RecordingInvoker()
        val registry = DartCapabilityRegistry(invoker)
        val decl = CapabilityDecl(
            resources = listOf(
                Resource(method = "GET", path = listOf("virtual", "{id}"), description = "state"),
                Resource(method = "GET", path = listOf("profiles")),
            ),
            commands = listOf(
                Command(method = "POST", path = listOf("virtual", "press")),
            ),
        )

        val cap = registry.register("gamepad", decl)

        assertEquals("gamepad", cap.id)
        assertEquals(2, cap.resources().size)
        assertEquals(listOf("virtual", "{id}"), cap.resources()[0].path)
        assertEquals("state", cap.resources()[0].description)
        assertEquals(1, cap.commands().size)
        assertEquals(setOf("gamepad"), registry.registeredIds)
    }

    @Test
    fun `duplicate register throws IllegalArgumentException`() {
        val registry = DartCapabilityRegistry(RecordingInvoker())
        registry.register("gamepad", CapabilityDecl(emptyList(), emptyList()))
        assertThrows(IllegalArgumentException::class.java) {
            registry.register("gamepad", CapabilityDecl(emptyList(), emptyList()))
        }
    }

    @Test
    fun `handleResource reverse invokes with the matching routeIndex`() = runBlocking {
        val invoker = RecordingInvoker()
        val registry = DartCapabilityRegistry(invoker)
        val cap = registry.register(
            "gamepad",
            CapabilityDecl(
                resources = listOf(
                    Resource(path = listOf("virtual", "state")),
                    Resource(path = listOf("profiles")),
                ),
                commands = listOf(Command(path = listOf("virtual", "press"))),
            ),
        )

        val result = cap.handleResource(cap.resources()[1], RouteContext())
        assertEquals(mapOf("ok" to true, "kind" to "resource", "index" to 1), result)
        assertEquals(listOf(Triple("gamepad", "resource", 1)), invoker.invokes)

        val cmdResult = cap.handleCommand(cap.commands()[0], RouteContext())
        assertEquals(mapOf("ok" to true, "kind" to "command", "index" to 0), cmdResult)
    }

    @Test
    fun `registered capability integrates with the native plane dispatch`() = runBlocking {
        val invoker = RecordingInvoker()
        val registry = DartCapabilityRegistry(invoker)
        val transport = FakeTransport()
        val plane = ControlPlane(transport, FakeMethodChannel.scope)
        plane.register(
            registry.register(
                "gamepad",
                CapabilityDecl(
                    resources = listOf(Resource(path = listOf("virtual", "state"))),
                    commands = emptyList(),
                ),
            ),
        )

        assertTrue("gamepad" in plane.registeredIds)

        // Drive the plane dispatch as the transport would (GET virtual/state).
        val result = plane.dispatch(
            com.pantas.debug.controlplane.RouteRequest(
                method = "GET",
                segments = listOf("virtual", "state"),
            ),
        )
        assertTrue(result is com.pantas.debug.controlplane.RouteResult.Ok)
        assertEquals(listOf(Triple("gamepad", "resource", 0)), invoker.invokes)
    }

    @Test
    fun `events emit reaches the plane event bus with native sequence assignment`() = runBlocking {
        val invoker = RecordingInvoker()
        val registry = DartCapabilityRegistry(invoker)
        val transport = FakeTransport()
        val plane = ControlPlane(transport, FakeMethodChannel.scope)
        plane.start(0) // installs the bus -> transport.broadcast pipe
        plane.register(
            registry.register(
                "gamepad",
                CapabilityDecl(resources = emptyList(), commands = emptyList()),
            ),
        )
        val flow = invoker.flows.getValue("gamepad")
        kotlinx.coroutines.withTimeout(2000) {
            while (flow.subscriptionCount.value == 0) kotlinx.coroutines.delay(10)
        }

        // events.emit path: plugin feeds the per-cap flow; the plane's
        // collection job re-emits onto the bus with a fresh sequence.
        flow.tryEmit(
            com.pantas.debug.controlplane.DebugEvent(
                type = "pressed",
                sequence = 42L, // Dart-side value — must be discarded (§3.1)
                payload = mapOf("key" to "A"),
            ),
        )
        kotlinx.coroutines.withTimeout(2000) {
            while (transport.broadcasts.isEmpty()) kotlinx.coroutines.delay(10)
        }

        assertEquals(1, transport.broadcasts.size)
        assertEquals("pressed", transport.broadcasts[0].type)
        assertEquals(0L, transport.broadcasts[0].sequence) // native-assigned
    }
}
