package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.CapabilityScope
import com.pantas.debug.controlplane.CapabilityScopeType
import com.pantas.debug.controlplane.Command
import com.pantas.debug.controlplane.ControlPlane
import com.pantas.debug.controlplane.Resource
import com.pantas.debug.controlplane.RouteContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * FF001-2 unit tests: Decl deserialization + BridgeCapability wiring —
 * register populates the native plane registry, dispatch reaches the
 * reverse invoke with the right routeIndex.
 *
 * R003-FF002: scoped-identity indexing (KD-1) — app/page keys coexist,
 * duplicates are per scoped key, and teardown-scope semantics stay exact.
 */
class DartCapabilityRegistryTest {

    private class RecordingInvoker : DartReverseInvoker {
        val invokes = mutableListOf<Triple<String, String, Int>>() // (capId, kind, index)
        val flows = mutableMapOf<BridgeCapabilityIdentity, MutableSharedFlow<com.pantas.debug.controlplane.DebugEvent>>()

        override fun eventFlow(identity: BridgeCapabilityIdentity): MutableSharedFlow<com.pantas.debug.controlplane.DebugEvent> =
            flows.getOrPut(identity) { MutableSharedFlow(extraBufferCapacity = 64) }

        override suspend fun invokeHandler(
            identity: BridgeCapabilityIdentity,
            routeKind: String,
            routeIndex: Int,
            context: RouteContext,
        ): Map<String, Any?> {
            invokes += Triple(identity.capId, routeKind, routeIndex)
            return mapOf("ok" to true, "kind" to routeKind, "index" to routeIndex)
        }

        override suspend fun pullState(identity: BridgeCapabilityIdentity): Map<String, Any?> =
            mapOf("capId" to identity.capId)
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

    // ---- R003-FF002 KD-1/KD-2: scoped identity indexing ---------------------

    @Test
    fun `register without scope defaults to app key`() {
        val invoker = RecordingInvoker()
        val registry = DartCapabilityRegistry(invoker)

        val cap = registry.register("gamepad", CapabilityDecl(emptyList(), emptyList()))

        assertEquals(CapabilityScope.app(), cap.scope)
        assertEquals(setOf(BridgeCapabilityIdentity.app("gamepad")), registry.identities)
    }

    @Test
    fun `register page scope stores scope metadata and page key`() {
        val invoker = RecordingInvoker()
        val registry = DartCapabilityRegistry(invoker)

        val cap = registry.register(
            "gamepad",
            CapabilityDecl(emptyList(), emptyList()),
            CapabilityScope.page(pageId = "page-battle", pageName = "Battle"),
        )

        assertEquals(CapabilityScopeType.PAGE, cap.scope.type)
        assertEquals("page-battle", cap.scope.pageId)
        assertEquals("Battle", cap.scope.pageName)
        assertEquals(
            setOf(BridgeCapabilityIdentity.page("page-battle", "gamepad")),
            registry.identities,
        )
        // KD-2: legacy app-only debug view excludes page ids.
        assertTrue(registry.registeredIds.isEmpty())
    }

    @Test
    fun `same scoped key duplicate throws but app and page coexist with same capId`() {
        val registry = DartCapabilityRegistry(RecordingInvoker())
        registry.register("gamepad", CapabilityDecl(emptyList(), emptyList()))
        registry.register(
            "gamepad",
            CapabilityDecl(emptyList(), emptyList()),
            CapabilityScope.page(pageId = "p1"),
        )
        registry.register(
            "gamepad",
            CapabilityDecl(emptyList(), emptyList()),
            CapabilityScope.page(pageId = "p2"),
        )
        assertEquals(3, registry.identities.size)

        // Same scoped key (page p1, gamepad) again -> duplicate.
        assertThrows(IllegalArgumentException::class.java) {
            registry.register(
                "gamepad",
                CapabilityDecl(emptyList(), emptyList()),
                CapabilityScope.page(pageId = "p1"),
            )
        }
        // Different pageName on an identical three-field key is STILL a
        // duplicate — pageName must not leak into identity (KD-1).
        assertThrows(IllegalArgumentException::class.java) {
            registry.register(
                "gamepad",
                CapabilityDecl(emptyList(), emptyList()),
                CapabilityScope.page(pageId = "p1", pageName = "Other"),
            )
        }
    }

    @Test
    fun `remove defaults are scoped - app removal keeps page entries`() {
        val registry = DartCapabilityRegistry(RecordingInvoker())
        registry.register("gamepad", CapabilityDecl(emptyList(), emptyList()))
        registry.register(
            "gamepad",
            CapabilityDecl(emptyList(), emptyList()),
            CapabilityScope.page(pageId = "p1"),
        )

        // Legacy app-only remove.
        registry.remove(CapabilityScope.app(), "gamepad")
        assertNull(registry.get(CapabilityScope.app(), "gamepad"))
        assertTrue("page entry sharing the capId survives", registry.contains(CapabilityScope.page(pageId = "p1"), "gamepad"))

        // Scoped remove takes exactly that key.
        registry.remove(CapabilityScope.page(pageId = "p1"), "gamepad")
        assertNull(registry.get(CapabilityScope.page(pageId = "p1"), "gamepad"))
        assertTrue(registry.identities.isEmpty())
    }

    private fun DartCapabilityRegistry.contains(scope: CapabilityScope, capId: String): Boolean =
        get(scope, capId) != null

    @Test
    fun `resolveEmitTarget mirrors Dart _scopeFor - app first then first registered key`() {
        val registry = DartCapabilityRegistry(RecordingInvoker())

        // Unregistered -> app key fallback (reject upstream as not_started).
        assertEquals(BridgeCapabilityIdentity.app("ghost"), registry.resolveEmitTarget("ghost"))

        // Page-only capId falls back to its page key.
        registry.register(
            "gamepad",
            CapabilityDecl(emptyList(), emptyList()),
            CapabilityScope.page(pageId = "p1"),
        )
        assertEquals(BridgeCapabilityIdentity.page("p1", "gamepad"), registry.resolveEmitTarget("gamepad"))

        // App entry wins when both exist (KD-3).
        registry.register("gamepad", CapabilityDecl(emptyList(), emptyList()))
        assertEquals(BridgeCapabilityIdentity.app("gamepad"), registry.resolveEmitTarget("gamepad"))
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

    /**
     * KD-5 (BF005 leftover fix): BF005 made `ControlPlane.register` broadcast
     * a `capability_scope_changed` bus event, so asserting the raw broadcast
     * count (`broadcasts.size == 1`) failed on clean HEAD (was 2). The fixed
     * assertion filters by event type instead. This was a BF005 leftover
     * failure, not an FF002 regression.
     */
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
        val flow = invoker.flows.getValue(BridgeCapabilityIdentity.app("gamepad"))
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
            while (transport.broadcasts.none { it.type == "pressed" }) kotlinx.coroutines.delay(10)
        }

        // Filter by type: the BF005 `capability_scope_changed` broadcast also
        // lands here, so raw size assertions over-count (KD-5).
        val pressed = transport.broadcasts.filter { it.type == "pressed" }
        assertEquals(1, pressed.size)
        // Native-assigned: the Dart-side 42 was discarded. The BF005
        // capability_scope_changed broadcast consumed sequence 0 first, so
        // this frame got the next monotonic value (> 0 proves reassignment).
        assertTrue(
            "native-assigned sequence expected, got ${pressed[0].sequence}",
            pressed[0].sequence in 1..41,
        )
    }
}
