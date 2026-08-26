package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.HttpSseTransport
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        val pluginBridge = NativeControlPlaneBridge(channel, FakeMethodChannel.scope)
        val bridgeField = DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("bridge")
        bridgeField.isAccessible = true
        bridgeField.set(plugin, pluginBridge)
        val authStore = InMemoryPluginDebugAuthStore()
        val authManager = PluginDebugAuthManager(pluginBridge, authStore)
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
        val bridge = bridgeOf()

        val collected = mutableListOf<String>()
        val collector = FakeMethodChannel.scope.launch {
            bridge.eventFlow(BridgeCapabilityIdentity.app("gamepad")).collect { collected += it.type }
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
        val bridge = bridgeOf()

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
        assertNull(
            "no permanent flow entry for an unknown capId",
            bridge.eventFlows[BridgeCapabilityIdentity.app("ghost")],
        )
    }

    @Test
    fun `invoke result fill-in completes the pending reverse call`() = runBlocking {
        val bridge = bridgeOf()
        var recordRef: FakeMethodChannel.RecordedInvoke? = null
        channel.dartAnswer = { record ->
            recordRef = record
            // Defer the fill-in until the test observed the reverse call.
        }

        val waiter = FakeMethodChannel.scope.async {
            bridge.invokeHandler(BridgeCapabilityIdentity.app("gamepad"), ChannelProtocol.ROUTE_KIND_COMMAND, 0, com.pantas.debug.controlplane.RouteContext())
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

    // ---- R003-FF002: scope-aware payload handling (KD-2/KD-3) ----------------

    private fun bridgeOf(): NativeControlPlaneBridge =
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("bridge").let {
            it.isAccessible = true
            it.get(plugin) as NativeControlPlaneBridge
        }

    private fun regArgs(scope: Map<String, Any?> = emptyMap()) = mapOf<String, Any?>(
        "capId" to "gamepad",
        "resources" to emptyList<Map<String, Any?>>(),
        "commands" to emptyList<Map<String, Any?>>(),
    ) + scope

    private suspend fun registerScope(args: Map<String, Any?>): RecordingResult {
        val result = RecordingResult()
        plugin.onMethodCall(methodCall(ChannelProtocol.CAPABILITY_REGISTER, args), result)
        delay(50) // async handler on the plugin scope
        return result
    }

    /**
     * Read the plane's private scoped registry
     * (`LinkedHashMap<ScopedCapabilityKey, CapabilityEntry> _capabilities`)
     * via reflection — the mirror state this task feeds (BF005/BF006 source).
     * Returns pairs of (scope wire value, pageId).
     */
    @Suppress("UNCHECKED_CAST")
    private fun planeScopedKeys(): List<Pair<String, String?>> {
        val field = Class.forName("com.pantas.debug.controlplane.ControlPlane")
            .getDeclaredField("_capabilities")
        field.isAccessible = true
        val map = field.get(PlaneCarrier.plane) as Map<Any?, Any?>
        return map.keys.map { key ->
            checkNotNull(key)
            val type = key.javaClass.getDeclaredField("scope").let { it.isAccessible = true; it.get(key) }
                as com.pantas.debug.controlplane.CapabilityScopeType
            val pageId = key.javaClass.getDeclaredField("pageId").let { it.isAccessible = true; it.get(key) } as String?
            Pair(type.name, pageId)
        }
    }

    /** Read each registered capability's [com.pantas.debug.controlplane.Capability.scope] off the plane. */
    @Suppress("UNCHECKED_CAST")
    private fun planeCapabilityScopes(): Map<String, com.pantas.debug.controlplane.CapabilityScope> {
        val field = Class.forName("com.pantas.debug.controlplane.ControlPlane")
            .getDeclaredField("_capabilities")
        field.isAccessible = true
        val map = field.get(PlaneCarrier.plane) as Map<Any?, Any?>
        return map.values.associate { entry ->
            checkNotNull(entry)
            val cap = entry.javaClass.getDeclaredField("capability").let { it.isAccessible = true; it.get(entry) }
                as com.pantas.debug.controlplane.Capability
            Pair(cap.id, cap.scope)
        }
    }

    @Test
    fun `register without scope defaults to app key on plane and bridge`() = runBlocking {
        val result = registerScope(regArgs())

        assertNull(result.errorCode)
        assertTrue(PlaneCarrier.plane!!.registeredIds.contains("gamepad"))
        // ScopedCapabilityKey.from(app scope, gamepad): type APP + null pageId.
        assertEquals(listOf(Pair("APP", null)), planeScopedKeys())
        assertTrue(bridgeOf().eventFlows.containsKey(BridgeCapabilityIdentity.app("gamepad")))
    }

    @Test
    fun `register page scope parses pageId pageName into the scoped key`() = runBlocking {
        val result = registerScope(
            regArgs(mapOf("scope" to "page", "pageId" to "page-battle", "pageName" to "Battle")),
        )

        assertNull(result.errorCode)
        assertTrue(bridgeOf().eventFlows.containsKey(BridgeCapabilityIdentity.page("page-battle", "gamepad")))
        // The plane side mirrors the page scope metadata (BF006 consumers).
        val mirrored = planeCapabilityScopes().getValue("gamepad")
        assertEquals(com.pantas.debug.controlplane.CapabilityScopeType.PAGE, mirrored.type)
        assertEquals("page-battle", mirrored.pageId)
        assertEquals("Battle", mirrored.pageName)
    }

    @Test
    fun `page scope without pageId replies invalid_request`() = runBlocking {
        val result = registerScope(regArgs(mapOf("scope" to "page")))

        assertEquals("invalid_request", result.errorCode)
        assertTrue(result.errorMessage!!.contains("pageId"))
    }

    @Test
    fun `unknown scope value replies invalid_request`() = runBlocking {
        val result = registerScope(regArgs(mapOf("scope" to "galaxy")))

        assertEquals("invalid_request", result.errorCode)
        assertTrue(result.errorMessage!!.contains("scope"))
    }

    @Test
    fun `same scoped key duplicate replies duplicate`() = runBlocking {
        registerScope(regArgs(mapOf("scope" to "page", "pageId" to "p1")))

        val dup = registerScope(regArgs(mapOf("scope" to "page", "pageId" to "p1")))
        assertEquals(ChannelProtocol.ERROR_DUPLICATE, dup.errorCode)

        // Same three-field key with a different pageName is STILL a duplicate.
        val dupName = registerScope(
            regArgs(mapOf("scope" to "page", "pageId" to "p1", "pageName" to "Other")),
        )
        assertEquals(ChannelProtocol.ERROR_DUPLICATE, dupName.errorCode)
    }

    @Test
    fun `app and page entries sharing a capId coexist`() = runBlocking {
        assertNull(registerScope(regArgs()).errorCode)
        assertNull(registerScope(regArgs(mapOf("scope" to "page", "pageId" to "p1"))).errorCode)

        val bridge = bridgeOf()
        assertTrue(bridge.eventFlows.containsKey(BridgeCapabilityIdentity.app("gamepad")))
        assertTrue(bridge.eventFlows.containsKey(BridgeCapabilityIdentity.page("p1", "gamepad")))
    }

    @Test
    fun `unregister defaults to app-only and keeps same-capId page entry`() = runBlocking {
        registerScope(regArgs())
        registerScope(regArgs(mapOf("scope" to "page", "pageId" to "p1")))
        val bridge = bridgeOf()

        // Legacy payload: no scope fields.
        val legacy = RecordingResult()
        plugin.onMethodCall(methodCall(ChannelProtocol.CAPABILITY_UNREGISTER, mapOf("capId" to "gamepad")), legacy)
        delay(50)

        assertNull(legacy.errorCode)
        assertFalse(bridge.eventFlows.containsKey(BridgeCapabilityIdentity.app("gamepad")))
        assertTrue("page entry must survive app-only unregister", bridge.eventFlows.containsKey(BridgeCapabilityIdentity.page("p1", "gamepad")))
    }

    @Test
    fun `scoped unregister removes exactly that key`() = runBlocking {
        registerScope(regArgs())
        registerScope(regArgs(mapOf("scope" to "page", "pageId" to "p1")))
        registerScope(regArgs(mapOf("scope" to "page", "pageId" to "p2")))
        val bridge = bridgeOf()

        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.CAPABILITY_UNREGISTER,
                mapOf("capId" to "gamepad", "scope" to "page", "pageId" to "p1"),
            ),
            result,
        )
        delay(50)

        assertNull(result.errorCode)
        assertFalse(bridge.eventFlows.containsKey(BridgeCapabilityIdentity.page("p1", "gamepad")))
        assertTrue(bridge.eventFlows.containsKey(BridgeCapabilityIdentity.app("gamepad")))
        assertTrue(bridge.eventFlows.containsKey(BridgeCapabilityIdentity.page("p2", "gamepad")))
        // Plane-side mirror also dropped only that key (state_consistency):
        // exactly the app key and the page-p2 key remain.
        assertEquals(
            setOf(Pair("APP", null), Pair("PAGE", "p2")),
            planeScopedKeys().toSet(),
        )
    }

    @Test
    fun `unregister of an absent scoped key is a no-op success`() {
        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.CAPABILITY_UNREGISTER,
                mapOf("capId" to "ghost", "scope" to "page", "pageId" to "nowhere"),
            ),
            result,
        )
        assertNull(result.errorCode)
    }

    @Test
    fun `events emit routes by explicit scope pageId`() = runBlocking {
        registerScope(regArgs())
        registerScope(regArgs(mapOf("scope" to "page", "pageId" to "p1")))
        val bridge = bridgeOf()

        val collected = mutableListOf<String>()
        val collector = FakeMethodChannel.scope.launch {
            bridge.eventFlow(BridgeCapabilityIdentity.page("p1", "gamepad")).collect { collected += it.type }
        }
        delay(50)
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.EVENTS_EMIT,
                mapOf(
                    "capId" to "gamepad",
                    "scope" to "page",
                    "pageId" to "p1",
                    "event" to mapOf("type" to "pressed", "payload" to emptyMap<String, Any?>()),
                ),
            ),
            RecordingResult(),
        )
        delay(100)
        collector.cancel()

        assertEquals(listOf("pressed"), collected)
    }

    @Test
    fun `events emit without scope routes the app entry when both exist`() = runBlocking {
        registerScope(regArgs())
        registerScope(regArgs(mapOf("scope" to "page", "pageId" to "p1")))
        val bridge = bridgeOf()

        val collected = mutableListOf<String>()
        val collector = FakeMethodChannel.scope.launch {
            bridge.eventFlow(BridgeCapabilityIdentity.app("gamepad")).collect { collected += it.type }
        }
        delay(50)
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.EVENTS_EMIT,
                mapOf(
                    "capId" to "gamepad",
                    "event" to mapOf("type" to "tapped", "payload" to emptyMap<String, Any?>()),
                ),
            ),
            RecordingResult(),
        )
        delay(100)
        collector.cancel()

        assertEquals(listOf("tapped"), collected)
    }

    @Test
    fun `events emit for unregistered scoped key replies not_started creating no flow`() = runBlocking {
        val bridge = bridgeOf()
        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.EVENTS_EMIT,
                mapOf(
                    "capId" to "gamepad",
                    "scope" to "page",
                    "pageId" to "never-registered",
                    "event" to mapOf("type" to "pressed", "payload" to emptyMap<String, Any?>()),
                ),
            ),
            result,
        )
        delay(50)

        assertEquals("not_started", result.errorCode)
        assertNull(bridge.eventFlows[BridgeCapabilityIdentity.page("never-registered", "gamepad")])
    }

    @Test
    fun `reverse invoke reaches Dart with scope and pageId payload fields`() = runBlocking {
        val channel = channelField()
        var invokeRecord: FakeMethodChannel.RecordedInvoke? = null
        var pullRecord: FakeMethodChannel.RecordedInvoke? = null
        channel.dartAnswer = { record ->
            if (record.method == ChannelProtocol.CAPABILITY_INVOKE && record.arguments["pageId"] == "p9") {
                invokeRecord = record
                bridgeOf().completeInvoke(record.reqId, mapOf("result" to mapOf("ok" to true)))
            } else if (record.method == ChannelProtocol.CAPABILITY_STATE_PULL && record.arguments["pageId"] == "p7") {
                pullRecord = record
                bridgeOf().completeState(record.reqId, mapOf("connected" to true))
            }
        }
        // Drive reverse invokes straight through the bridge (KD-4 assertions).
        FakeMethodChannel.scope.async {}
        kotlinx.coroutines.runBlocking {
            bridgeOf().invokeHandler(
                BridgeCapabilityIdentity(com.pantas.debug.controlplane.CapabilityScopeType.PAGE, "p9", "gamepad"),
                ChannelProtocol.ROUTE_KIND_COMMAND,
                0,
                com.pantas.debug.controlplane.RouteContext(),
            )
            bridgeOf().pullState(
                BridgeCapabilityIdentity(com.pantas.debug.controlplane.CapabilityScopeType.PAGE, "p7", "gamepad"),
            )
        }

        val invoke = invokeRecord!!
        assertEquals("gamepad", invoke.arguments["capId"])
        assertEquals("page", invoke.arguments["scope"])
        assertEquals("p9", invoke.arguments["pageId"])
        val pull = pullRecord!!
        assertEquals("gamepad", pull.arguments["capId"])
        assertEquals("page", pull.arguments["scope"])
        assertEquals("p7", pull.arguments["pageId"])
    }

    private fun channelField(): FakeMethodChannel =
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("channel").let {
            it.isAccessible = true
            it.get(plugin) as FakeMethodChannel
        }
}
