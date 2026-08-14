package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for [ControlPlane] — register/unregister/dispatch/state & hello
 * aggregation, aligned with PROTOCOL.md (§1.2/§1.3/§2.4/§4.2) and the
 * fixtures/ golden files (semantic-level; full golden loading lands in
 * BF003-1 GoldenFixtureTest).
 */
class ControlPlaneTest {

    private lateinit var scope: CoroutineScope
    private lateinit var transport: FakeTransport
    private lateinit var plane: ControlPlane

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        transport = FakeTransport()
        plane = ControlPlane(transport = transport, scope = scope)
        // Wire dispatcher immediately (in tests we drive dispatch directly).
        kotlinx.coroutines.runBlocking { transport.listen { req -> plane.dispatch(req) } }
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun get(path: String): RouteResult =
        kotlinx.coroutines.runBlocking {
            transport.dispatch(RouteRequest(method = "GET", segments = path.trim('/').split('/').filter { it.isNotEmpty() }))
        }

    private fun post(path: String, body: Map<String, Any?> = emptyMap()): RouteResult =
        kotlinx.coroutines.runBlocking {
            transport.dispatch(RouteRequest(method = "POST", segments = path.trim('/').split('/').filter { it.isNotEmpty() }, body = body))
        }

    // ---- Registry -----------------------------------------------------------

    @Test
    fun registerAddsId_unregisterRemoves() {
        plane.register(FakeCapability("alpha"))
        assertTrue(plane.registeredIds.contains("alpha"))
        plane.unregister("alpha")
        assertFalse(plane.registeredIds.contains("alpha"))
    }

    @Test
    fun duplicateRegisterThrows() {
        plane.register(FakeCapability("alpha"))
        try {
            plane.register(FakeCapability("alpha"))
            throw AssertionError("expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message!!.contains("Capability already registered: alpha"))
        }
    }

    @Test
    fun unregisterUnknownIsNoOp() {
        plane.unregister("nope") // must not throw
    }

    // ---- /state aggregation (fixtures/state-*.json semantics) ----------------

    @Test
    fun state_emptyRegistry_isEmptyObject_noOkField() {
        val result = get("/state")
        assertTrue(result is RouteResult.Ok)
        assertEquals(emptyMap<String, Any?>(), (result as RouteResult.Ok).body)
        // Byte-level hard constraint (§1.3): no top-level `ok` key.
        assertFalse(result.body.containsKey("ok"))
    }

    @Test
    fun state_flatSpreadAcrossCapabilities() {
        plane.register(FakeCapability("alpha", stateMap = mapOf("aKey1" to "value1", "aKey2" to 1)))
        plane.register(FakeCapability("beta", stateMap = mapOf("aKey3" to true, "aKey4" to null)))
        val body = get("/state") as RouteResult.Ok
        assertEquals(
            mapOf<String, Any?>("aKey1" to "value1", "aKey2" to 1, "aKey3" to true, "aKey4" to null),
            body.body,
        )
        assertFalse(body.body.containsKey("ok"))
    }

    @Test
    fun state_laterRegistrationWinsOnKeyCollision() {
        plane.register(FakeCapability("alpha", stateMap = mapOf("k" to "first")))
        plane.register(FakeCapability("beta", stateMap = mapOf("k" to "second")))
        val body = get("/state") as RouteResult.Ok
        assertEquals("second", body.body["k"])
    }

    // ---- /hello aggregation (fixtures/hello.json semantics) ------------------

    @Test
    fun hello_protocolVersionAndEndpoints() {
        transport.serverInfo = mapOf("serverHost" to "127.0.0.1", "serverPort" to 18080, "localIps" to listOf("192.168.1.5"))
        val body = get("/hello") as RouteResult.Ok
        assertEquals(1, body.body["protocolVersion"])           // §6 hard constant
        assertEquals("/events", body.body["eventsEndpoint"])
        assertEquals(1, body.body["profileRevision"])           // U5: legacy, always 1
        assertEquals("127.0.0.1", body.body["serverHost"])
        assertEquals(18080, body.body["serverPort"])
    }

    @Test
    fun hello_appMetaInjectedBetweenProtocolVersionAndServerInfo() {
        val planeWithMeta = ControlPlane(
            transport = transport, scope = scope,
            appMeta = { mapOf("app" to "x", "deviceName" to "D", "platform" to "jvm") },
        )
        kotlinx.coroutines.runBlocking {
            transport.listen { req -> planeWithMeta.dispatch(req) }
        }
        val body = get("/hello") as RouteResult.Ok
        assertEquals("x", body.body["app"])
        assertEquals("D", body.body["deviceName"])
    }

    @Test
    fun hello_mergeOrder_appMetaCannotClobberLaterFrameworkKeys() {
        // appMeta tries to override eventsEndpoint / registeredCapabilities —
        // the merge order (§1.2) must let the LATER framework layers win.
        // protocolVersion is NOT protected by merge order (appMeta is the
        // 2nd layer and may legitimately override it — Dart behaves the
        // same); only eventsEndpoint/profileRevision/state/registeredCapabilities
        // spread after appMeta.
        val planeWithMeta = ControlPlane(
            transport = transport, scope = scope,
            appMeta = {
                mapOf(
                    "eventsEndpoint" to "/hacked",
                    "registeredCapabilities" to "nope",
                    "profileRevision" to 42,
                )
            },
        )
        kotlinx.coroutines.runBlocking { transport.listen { req -> planeWithMeta.dispatch(req) } }
        val body = get("/hello") as RouteResult.Ok
        assertEquals("/events", body.body["eventsEndpoint"])
        assertEquals(1, body.body["profileRevision"])
        assertTrue(body.body["registeredCapabilities"] is List<*>)
    }

    @Test
    fun hello_stateKeysSpreadFlat() {
        plane.register(FakeCapability("alpha", stateMap = mapOf("aKey1" to "value1")))
        val body = get("/hello") as RouteResult.Ok
        assertEquals("value1", body.body["aKey1"])
    }

    @Test
    fun hello_registeredCapabilities_schemaAndOrder() {
        plane.register(
            FakeCapability(
                "cap-alpha",
                resources = listOf(
                    Resource("GET", listOf("items"), "示例资源"),
                    Resource("GET", listOf("items", "{id}"), "含 {id} 占位符"),
                ),
                commands = listOf(Command("POST", listOf("invoke"), "示例命令")),
            )
        )
        plane.register(
            FakeCapability(
                "cap-beta-no-description",
                resources = listOf(Resource("GET", listOf("nested", "{leaf}"))),
                commands = listOf(Command("POST", listOf("nested", "submit"))),
            )
        )
        val body = get("/hello") as RouteResult.Ok
        val caps = body.body["registeredCapabilities"] as List<*>
        assertEquals(2, caps.size)
        // Registration order preserved (§2.2).
        assertEquals("cap-alpha", (caps[0] as Map<*, *>)["id"])
        assertEquals("cap-beta-no-description", (caps[1] as Map<*, *>)["id"])

        val alpha = caps[0] as Map<*, *>
        val res = alpha["resources"] as List<*>
        // path is a JSON array (§2.3 cross-language pitfall).
        assertEquals(listOf("items"), (res[0] as Map<*, *>)["path"])
        assertEquals(listOf("items", "{id}"), (res[1] as Map<*, *>)["path"])
        assertEquals("GET", (res[0] as Map<*, *>)["method"])
        assertEquals("示例资源", (res[0] as Map<*, *>)["description"])

        val beta = caps[1] as Map<*, *>
        val betaRes = beta["resources"] as List<*>
        // description omitted when null (decision D3).
        assertFalse((betaRes[0] as Map<*, *>).containsKey("description"))
    }

    // ---- /events introspection fallback (unreachable over SSE transport) ------

    @Test
    fun events_introspectionFallbackShape() {
        val body = get("/events") as RouteResult.Ok
        assertEquals(true, body.body["ok"])
        assertEquals("event_bus_is_stream", body.body["note"])
        assertEquals("/events", body.body["eventsEndpoint"])
    }

    // ---- Capability dispatch (§2.4) -------------------------------------------

    @Test
    fun dispatch_getResourceWithPathParams() {
        plane.register(
            FakeCapability(
                "alpha",
                resources = listOf(Resource("GET", listOf("profiles", "{id}"))),
            )
        )
        val body = get("/profiles/abc") as RouteResult.Ok
        val pathParams = body.body["pathParams"] as Map<*, *>
        assertEquals("abc", pathParams["id"])
    }

    @Test
    fun dispatch_postCommandReceivesBody() {
        plane.register(
            FakeCapability("alpha", commands = listOf(Command("POST", listOf("invoke"))))
        )
        val body = post("/invoke", mapOf("x" to 1)) as RouteResult.Ok
        assertEquals(mapOf<String, Any?>("x" to 1), body.body["body"])
    }

    @Test
    fun dispatch_firstMatchWinsInRegistrationOrder() {
        val first = FakeCapability("first", resources = listOf(Resource("GET", listOf("same"))))
        first.onResource = { _, _ -> mapOf("winner" to "first") }
        val second = FakeCapability("second", resources = listOf(Resource("GET", listOf("same"))))
        second.onResource = { _, _ -> mapOf("winner" to "second") }
        plane.register(first)
        plane.register(second)
        val body = get("/same") as RouteResult.Ok
        assertEquals("first", body.body["winner"])
    }

    @Test
    fun dispatch_segmentCountMismatchIs404() {
        plane.register(
            FakeCapability("alpha", resources = listOf(Resource("GET", listOf("profiles", "{id}"))))
        )
        val result = get("/profiles")
        assertTrue("expected 404, got $result", result is RouteResult.Error)
        assertEquals(404, (result as RouteResult.Error).statusCode)
        assertEquals("not_found", result.code)
        assertEquals("Endpoint was not found.", result.message)   // fixture error-404.json literal
    }

    @Test
    fun dispatch_pathParamsNotLeakedAcrossDeclarations() {
        // Dart parity: each declaration matches against a FRESH pathParams
        // map. A partially-matched earlier declaration ({user} captured then
        // a later literal segment differing) must not leak its captures
        // into the declaration that finally matches.
        val cap = FakeCapability(
            "alpha",
            resources = listOf(
                Resource("GET", listOf("users", "{user}", "admin")),
                Resource("GET", listOf("users", "{user}")),
            ),
        )
        cap.onResource = { _, ctx -> mapOf("ok" to true, "pathParams" to ctx.pathParams) }
        plane.register(cap)
        val body = get("/users/bob") as RouteResult.Ok
        // Only the second declaration matches (1 extra segment kills the
        // first); its {user} capture must be present and nothing else.
        assertEquals(mapOf("user" to "bob"), body.body["pathParams"])
    }

    @Test
    fun dispatch_postDoesNotHitGetResources() {
        plane.register(
            FakeCapability("alpha", resources = listOf(Resource("GET", listOf("only-get"))))
        )
        val result = post("/only-get")
        assertTrue(result is RouteResult.Error)
        assertEquals(404, (result as RouteResult.Error).statusCode)
    }

    @Test
    fun dispatch_systemRoutesWinOverCapabilityDeclarations() {
        // A capability declaring GET /hello must NOT intercept the handshake.
        plane.register(
            FakeCapability("evil", resources = listOf(Resource("GET", listOf("hello"))))
        )
        val body = get("/hello") as RouteResult.Ok
        assertEquals(1, body.body["protocolVersion"])   // plane-owned shape, not the cap echo
        assertFalse(body.body.containsKey("winner"))
    }

    @Test
    fun dispatch_nonGetMethodOnSystemRouteFallsThroughTo404() {
        plane.register(FakeCapability("alpha"))
        val result = post("/hello")
        assertTrue(result is RouteResult.Error)
        assertEquals(404, (result as RouteResult.Error).statusCode)
    }

    // ---- Error funnel (§4.2) ---------------------------------------------------

    @Test
    fun dispatch_routeFailureMapsToItsStatusAndCode() {
        val cap = FakeCapability("alpha", commands = listOf(Command("POST", listOf("boom"))))
        cap.onCommand = { _, _ -> throw RouteFailure(409, "real_controller_active", "busy") }
        plane.register(cap)
        val result = post("/boom")
        val err = result as RouteResult.Error
        assertEquals(409, err.statusCode)
        assertEquals("real_controller_active", err.code)
        assertEquals("busy", err.message)
    }

    @Test
    fun dispatch_arbitraryExceptionMapsTo500InternalError() {
        val cap = FakeCapability("alpha", commands = listOf(Command("POST", listOf("boom"))))
        cap.onCommand = { _, _ -> throw IllegalStateException("kaboom") }
        plane.register(cap)
        val result = post("/boom")
        val err = result as RouteResult.Error
        assertEquals(500, err.statusCode)
        assertEquals("internal_error", err.code)   // fixture error-500.json code literal
        assertTrue(err.message!!.contains("kaboom"))
    }

    @Test
    fun dispatch_notFoundBodyShapeMatchesError404Fixture() {
        val result = get("/definitely-missing")
        val err = result as RouteResult.Error
        // fixtures/error-404.json: {ok:false, code:"not_found", message:"Endpoint was not found."}
        assertEquals("not_found", err.code)
        assertEquals("Endpoint was not found.", err.message)
    }
}
