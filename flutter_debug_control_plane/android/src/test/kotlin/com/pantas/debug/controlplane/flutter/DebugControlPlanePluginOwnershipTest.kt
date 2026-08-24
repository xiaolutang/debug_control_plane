package com.pantas.debug.controlplane.flutter

import kotlinx.coroutines.runBlocking
import com.pantas.debug.controlplane.RouteRequest
import com.pantas.debug.controlplane.RouteResult
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * R026-BF001-2/3: plane start/stop ownership semantics over the plugin's
 * MethodChannel surface.
 *
 * Ownership model (design §1.2/§1.3): the Service owns the server lifecycle;
 * the plugin's PLANE_START is a JOIN (start-once in the Kotlin core) plus a
 * Dart appMeta post-injection; PLANE_STOP only stops a plane the plugin
 * itself mounted (fallback) — a Service-mounted carrier plane must survive a
 * Dart dispose.
 */
class DebugControlPlanePluginOwnershipTest {

    private lateinit var plugin: DebugControlPlaneFlutterPlugin
    private lateinit var channel: FakeMethodChannel
    private lateinit var carrierTransport: FakeTransport

    @Before
    fun setUp() {
        plugin = DebugControlPlaneFlutterPlugin()
        channel = FakeMethodChannel()
        // Wire the fake channel the way onAttachedToEngine would.
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("channel").apply {
            isAccessible = true; set(plugin, channel)
        }
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("scope").apply {
            isAccessible = true; set(plugin, FakeMethodChannel.scope)
        }
        val bridge = NativeControlPlaneBridge(channel, FakeMethodChannel.scope)
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("bridge").apply {
            isAccessible = true; set(plugin, bridge)
        }
        val authStore = InMemoryPluginDebugAuthStore()
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("authStore").apply {
            isAccessible = true; set(plugin, authStore)
        }
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("authManager").apply {
            isAccessible = true; set(plugin, PluginDebugAuthManager(bridge, authStore))
        }
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("registry").apply {
            isAccessible = true; set(plugin, DartCapabilityRegistry(bridge))
        }

        // A Service-mounted carrier plane (the R025 production layout).
        carrierTransport = FakeTransport()
        PlaneCarrier.mount(carrierTransport, FakeMethodChannel.scope)
    }

    @After
    fun tearDown() {
        PlaneCarrier.unmount()
    }

    private fun resetOwnsPlaneToFalse() {
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("ownsPlane").apply {
            isAccessible = true; setBoolean(plugin, false)
        }
    }

    /** Await the recorded reply through the fake channel's own observer. */
    private fun awaitReply(result: RecordingResult) {
        kotlinx.coroutines.runBlocking {
            kotlinx.coroutines.withTimeout(2000) {
                while (!result.done) kotlinx.coroutines.delay(10)
            }
        }
    }

    // ---- PLANE_START on a carrier plane (join + appMeta injection) ---------

    @Test
    fun `plane start on carrier plane joins without rebinding and injects appMeta`() = runBlocking {
        // The Service already bound the carrier plane (first bind).
        PlaneCarrier.plane!!.start(18080)
        assertEquals(1, carrierTransport.bindCount)

        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.PLANE_START,
                mapOf(
                    "address" to "0.0.0.0",
                    "port" to 18080,
                    "appMeta" to mapOf("app" to "pantas", "deviceId" to "d1"),
                ),
            ),
            result,
        )
        awaitReply(result)

        assertNull(result.errorCode)
        // Join semantics: no second bind against the same transport.
        assertEquals("carrier plane must not be re-bound", 1, carrierTransport.bindCount)
        assertEquals(
            mapOf("uri" to "http://0.0.0.0:18080/"),
            result.successValue,
        )
        // appMeta post-injection: /hello on the carrier plane now carries the
        // Dart identity fields.
        val hello = PlaneCarrier.plane!!.dispatch(
            com.pantas.debug.controlplane.RouteRequest(method = "GET", segments = listOf("hello")),
        ) as com.pantas.debug.controlplane.RouteResult.Ok
        assertEquals("pantas", hello.body["app"])
        assertEquals("d1", hello.body["deviceId"])
    }

    @Test
    fun `plane start appMeta null keeps the existing appMeta`() = runBlocking {
        // The Service mounted the carrier WITH identity fields; a later Dart
        // join that sends no appMeta must not wipe them (null-keeps semantics).
        PlaneCarrier.unmount()
        val transport = FakeTransport()
        PlaneCarrier.mount(transport, FakeMethodChannel.scope) {
            mapOf("app" to "service-owner", "deviceId" to "svc")
        }

        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.PLANE_START,
                mapOf("address" to "0.0.0.0", "port" to 18080),
            ),
            result,
        )
        awaitReply(result)

        assertNull(result.errorCode)
        val hello = PlaneCarrier.plane!!.dispatch(
            com.pantas.debug.controlplane.RouteRequest(method = "GET", segments = listOf("hello")),
        ) as com.pantas.debug.controlplane.RouteResult.Ok
        assertEquals("Service-set appMeta must survive a null appMeta join", "service-owner", hello.body["app"])
        assertEquals("svc", hello.body["deviceId"])
    }

    // ---- PLANE_STOP ownership -------------------------------------------------

    @Test
    fun `plane stop on carrier plane does not stop or unmount`() = runBlocking {
        PlaneCarrier.plane!!.start(18080)
        resetOwnsPlaneToFalse() // carrier plane: the plugin does NOT own it

        val result = RecordingResult()
        plugin.onMethodCall(methodCall(ChannelProtocol.PLANE_STOP, emptyMap<String, Any?>()), result)
        awaitReply(result)

        assertNull(result.errorCode)
        // Ownership: the Service-mounted plane survives a Dart dispose.
        assertFalse("carrier transport must NOT be closed", carrierTransport.closed)
        assertNotNull("carrier plane must stay mounted", PlaneCarrier.plane)
    }

    @Test
    fun `plane stop on fallback plane stops and unmounts`() = runBlocking {
        // Dismount the carrier plane so PLANE_START takes the fallback path.
        PlaneCarrier.unmount()
        val start = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.PLANE_START,
                mapOf("address" to "0.0.0.0", "port" to 0),
            ),
            start,
        )
        awaitReply(start)
        assertNull(start.errorCode)
        assertTrue("fallback must have mounted a plane", PlaneCarrier.plane != null)

        val stop = RecordingResult()
        plugin.onMethodCall(methodCall(ChannelProtocol.PLANE_STOP, emptyMap<String, Any?>()), stop)
        awaitReply(stop)

        assertNull(stop.errorCode)
        assertNull("fallback plane must be unmounted", PlaneCarrier.plane)
    }

    // ---- fallback explicit port passthrough (C4) ------------------------------

    @Test
    fun `fallback plane start passes the explicit port to the transport`() = runBlocking {
        PlaneCarrier.unmount()
        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.PLANE_START,
                mapOf("address" to "0.0.0.0", "port" to 18099),
            ),
            result,
        )
        awaitReply(result)

        // C4: an explicit port must reach the fallback transport. A real
        // HttpSseTransport would reject a mismatched bind (require(port ==
        // requestedPort)) — success here proves the port was passed through.
        assertNull("explicit port must not fail: ${result.errorMessage}", result.errorCode)
        val uri = (result.successValue as Map<*, *>)["uri"] as String
        assertTrue("uri must carry the explicit port: $uri", uri.endsWith(":18099/"))
        // Cleanup: stop + unmount the fallback plane (no carrier to keep it).
        val cleanup = RecordingResult()
        plugin.onMethodCall(methodCall(ChannelProtocol.PLANE_STOP, emptyMap<String, Any?>()), cleanup)
        awaitReply(cleanup)
    }

    @Test
    fun `carrier plane can be mounted with plugin auth manager`() = runBlocking {
        PlaneCarrier.unmount()
        val authChannel = FakeMethodChannel()
        val authBridge = NativeControlPlaneBridge(authChannel, FakeMethodChannel.scope)
        val authManager = PluginDebugAuthManager(authBridge, InMemoryPluginDebugAuthStore())
        val transport = FakeTransport()
        PlaneCarrier.mount(transport, FakeMethodChannel.scope, authManager)

        val result = PlaneCarrier.plane!!.dispatch(
            RouteRequest(
                method = "POST",
                segments = listOf("auth", "request"),
                body = mapOf("clientNonce" to "nonce-carrier", "clientLabel" to "devtool"),
            ),
        )

        assertTrue(result is RouteResult.Ok)
        assertEquals(ChannelProtocol.AUTH_REQUEST, authChannel.invokes.single().method)
        assertEquals("devtool", authChannel.invokes.single().arguments["clientLabel"])
    }
}
