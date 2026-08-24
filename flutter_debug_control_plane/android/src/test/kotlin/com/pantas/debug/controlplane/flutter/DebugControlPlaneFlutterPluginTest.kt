package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.HttpSseTransport
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * FF001-2 unit tests: the plugin's forward MethodCall handling over a fake
 * channel — register (Decl -> plane registry), events.emit, invoke result
 * fill-in, attach/detach pairing.
 */
class DebugControlPlaneFlutterPluginTest {

    private lateinit var plugin: DebugControlPlaneFlutterPlugin
    private lateinit var channel: FakeMethodChannel

    @Before
    fun setUp() {
        plugin = DebugControlPlaneFlutterPlugin()
        channel = FakeMethodChannel()
        // Inject the fake channel without a Flutter engine: recreate the
        // plugin's wiring the way onAttachedToEngine would.
        val field = DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("channel")
        field.isAccessible = true
        field.set(plugin, channel)
        val scopeField = DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("scope")
        scopeField.isAccessible = true
        scopeField.set(plugin, FakeMethodChannel.scope)
        val bridgeField = DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("bridge")
        bridgeField.isAccessible = true
        bridgeField.set(plugin, NativeControlPlaneBridge(channel, FakeMethodChannel.scope))
        val authStore = InMemoryPluginDebugAuthStore()
        val authManager = PluginDebugAuthManager(bridgeField.get(plugin) as NativeControlPlaneBridge, authStore)
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("authStore").apply {
            isAccessible = true
            set(plugin, authStore)
        }
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("authManager").apply {
            isAccessible = true
            set(plugin, authManager)
        }
        val registryField = DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("registry")
        registryField.isAccessible = true
        registryField.set(plugin, DartCapabilityRegistry(bridgeField.get(plugin) as NativeControlPlaneBridge))

        // Mount a plane over a fake transport so CAPABILITY_REGISTER has a target.
        PlaneCarrier.mount(FakeTransport(), FakeMethodChannel.scope)
    }

    @After
    fun tearDown() {
        PlaneCarrier.unmount()
    }

    @Test
    fun `capability register populates the native plane`() = runBlocking {
        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.CAPABILITY_REGISTER,
                mapOf(
                    "capId" to "gamepad",
                    "resources" to listOf(
                        mapOf(
                            "method" to "GET",
                            "path" to listOf("virtual", "{id}"),
                            "description" to "state",
                        ),
                    ),
                    "commands" to listOf(
                        mapOf("method" to "POST", "path" to listOf("virtual", "press")),
                    ),
                ),
            ),
            result,
        )
        delay(50) // async handler on the plugin scope

        assertNull(result.errorCode)
        assertTrue("gamepad" in PlaneCarrier.plane!!.registeredIds)
    }

    @Test
    fun `duplicate register replies error duplicate`() = runBlocking {
        val args = mapOf(
            "capId" to "gamepad",
            "resources" to emptyList<Map<String, Any?>>(),
            "commands" to emptyList<Map<String, Any?>>(),
        )
        plugin.onMethodCall(methodCall(ChannelProtocol.CAPABILITY_REGISTER, args), RecordingResult())
        delay(50)

        val dup = RecordingResult()
        plugin.onMethodCall(methodCall(ChannelProtocol.CAPABILITY_REGISTER, args), dup)
        delay(50)
        assertEquals(ChannelProtocol.ERROR_DUPLICATE, dup.errorCode)
    }

    @Test
    fun `register with slash-joined path string replies invalid_request`() = runBlocking {
        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.CAPABILITY_REGISTER,
                mapOf(
                    "capId" to "gamepad",
                    "resources" to listOf(
                        mapOf("method" to "GET", "path" to "/virtual/state"),
                    ),
                    "commands" to emptyList<Map<String, Any?>>(),
                ),
            ),
            result,
        )
        delay(50)
        assertEquals("invalid_request", result.errorCode)
        assertTrue(result.errorMessage!!.contains("JSON array"))
    }

    @Test
    fun `events emit delivers the frame into the reverse-invoker flow`() = runBlocking {
        val bridgeField = DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("bridge")
        bridgeField.isAccessible = true
        val bridge = bridgeField.get(plugin) as NativeControlPlaneBridge

        val collected = mutableListOf<String>()
        val collector = FakeMethodChannel.scope.launch {
            bridge.eventFlow("gamepad").collect { collected += it.type }
        }
        delay(50)

        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.EVENTS_EMIT,
                mapOf(
                    "capId" to "gamepad",
                    "event" to mapOf(
                        "type" to "pressed",
                        "payload" to mapOf("key" to "A", "sequence" to 99),
                    ),
                ),
            ),
            RecordingResult(),
        )
        delay(100)
        collector.cancel()

        assertEquals(listOf("pressed"), collected)
    }

    @Test
    fun `events emit for unregistered capId replies not_started and creates no flow`() = runBlocking {
        // M3: an events.emit before capability.register must not getOrPut a
        // permanent eventFlows entry (unbounded growth), it is rejected.
        val bridgeField = DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("bridge")
        bridgeField.isAccessible = true
        val bridge = bridgeField.get(plugin) as NativeControlPlaneBridge

        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.EVENTS_EMIT,
                mapOf(
                    "capId" to "ghost",
                    "event" to mapOf("type" to "pressed", "payload" to emptyMap<String, Any?>()),
                ),
            ),
            result,
        )
        delay(50)

        assertEquals("not_started", result.errorCode)
        assertNull("no permanent flow entry for an unknown capId", bridge.eventFlows["ghost"])
    }

    @Test
    fun `invoke result fill-in completes the pending reverse call`() = runBlocking {
        val bridgeField = DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("bridge")
        bridgeField.isAccessible = true
        val bridge = bridgeField.get(plugin) as NativeControlPlaneBridge
        var recordRef: FakeMethodChannel.RecordedInvoke? = null
        channel.dartAnswer = { record ->
            recordRef = record
            // Defer the fill-in until the test observed the reverse call.
        }

        val waiter = FakeMethodChannel.scope.async {
            bridge.invokeHandler("gamepad", ChannelProtocol.ROUTE_KIND_COMMAND, 0, com.pantas.debug.controlplane.RouteContext())
        }
        kotlinx.coroutines.withTimeout(2000) {
            while (recordRef == null) delay(10)
        }
        val reqId = recordRef!!.reqId
        bridge.invokeTimeoutMs = 2000

        // Simulate the Dart fill-in through the plugin handler.
        val fill = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.CAPABILITY_INVOKE_RESULT,
                mapOf("reqId" to reqId.toInt(), "result" to mapOf("ok" to true)),
            ),
            fill,
        )

        assertEquals(mapOf("ok" to true), waiter.await())
        assertNull(fill.errorCode)
    }

    @Test
    fun `unknown method replies notImplemented`() {
        val result = RecordingResult()
        plugin.onMethodCall(methodCall("bogus", emptyMap<String, Any?>()), result)
        assertTrue(result.notImplementedFlag)
    }

    @Test
    fun `auth dispatcher approves denies revokes and reports status`() = runBlocking {
        val authManager = DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("authManager").let {
            it.isAccessible = true
            it.get(plugin) as PluginDebugAuthManager
        }
        authManager.requestAuthorization(
            mapOf(
                "clientNonce" to "nonce-1",
                "clientLabel" to "devtool",
                "requestedMethod" to "GET",
                "requestedPath" to "/state",
            ),
        )
        val requestId = (channel.invokes.single().arguments["requestId"] as String)

        val approve = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.AUTH_APPROVE,
                mapOf("requestId" to requestId, "ttlSeconds" to 60, "clientLabel" to "host"),
            ),
            approve,
        )
        @Suppress("UNCHECKED_CAST")
        val claim = approve.successValue as Map<String, Any?>
        assertEquals("authorized", claim["status"])
        assertNotNull(claim["token"])
        assertNotNull(claim["tokenId"])

        val status = RecordingResult()
        plugin.onMethodCall(methodCall(ChannelProtocol.AUTH_STATUS, mapOf("requestId" to requestId)), status)
        @Suppress("UNCHECKED_CAST")
        val statusMap = status.successValue as Map<String, Any?>
        assertEquals("approved", statusMap["status"])
        assertNull("status must not leak token plaintext", statusMap["token"])

        val revoke = RecordingResult()
        plugin.onMethodCall(
            methodCall(ChannelProtocol.AUTH_REVOKE, mapOf("tokenId" to claim["tokenId"])),
            revoke,
        )
        assertNull(revoke.errorCode)

        val deniedRequest = authManager.requestAuthorization(mapOf("clientNonce" to "nonce-2"))
            as com.pantas.debug.controlplane.DebugAuthRouteResult.Ok
        val deniedId = deniedRequest.body["requestId"] as String
        val deny = RecordingResult()
        plugin.onMethodCall(
            methodCall(ChannelProtocol.AUTH_DENY, mapOf("requestId" to deniedId, "reason" to "cancelled")),
            deny,
        )
        assertNull(deny.errorCode)
        assertEquals("denied", authManager.status(deniedId)["status"])
    }

    @Test
    fun `auth dispatcher validates missing request id and revoke target`() {
        val approve = RecordingResult()
        plugin.onMethodCall(methodCall(ChannelProtocol.AUTH_APPROVE, emptyMap()), approve)
        assertEquals("invalid_request", approve.errorCode)

        val revoke = RecordingResult()
        plugin.onMethodCall(methodCall(ChannelProtocol.AUTH_REVOKE, emptyMap()), revoke)
        assertEquals("invalid_request", revoke.errorCode)
    }
}
