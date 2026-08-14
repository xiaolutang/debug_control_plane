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
}
