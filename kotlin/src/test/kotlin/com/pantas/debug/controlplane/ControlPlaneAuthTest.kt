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

class ControlPlaneAuthTest {
    private lateinit var scope: CoroutineScope
    private lateinit var transport: FakeTransport

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        transport = FakeTransport()
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    @Test
    fun authDisabledKeepsBareControlPlaneBehavior() {
        val plane = newPlane(auth = null)
        plane.register(FakeCapability("alpha", stateMap = mapOf("aKey1" to "value1")))

        val hello = dispatch(plane, get("/hello")) as RouteResult.Ok
        assertEquals("value1", hello.body["aKey1"])
        assertTrue(hello.body["registeredCapabilities"] is List<*>)

        val state = dispatch(plane, get("/state")) as RouteResult.Ok
        assertEquals("value1", state.body["aKey1"])
    }

    @Test
    fun helloWithoutValidTokenReturnsMinimalBootstrap() {
        val auth = RecordingAuthManager(
            authorizeDecision = DebugAuth.authorizationRequired(),
        )
        val plane = newPlane(auth)
        plane.register(FakeCapability("alpha", stateMap = mapOf("aKey1" to "value1")))

        val hello = dispatch(plane, get("/hello")) as RouteResult.Ok

        assertEquals(200, hello.status)
        assertEquals(1, hello.body["protocolVersion"])
        assertEquals("test-app", hello.body["app"])
        assertEquals("test-device", hello.body["deviceId"])
        assertEquals("/events", hello.body["eventsEndpoint"])
        assertEquals(true, hello.body["authRequired"])
        assertEquals("authorization_required", hello.body["authStatus"])
        assertEquals(
            mapOf("request" to "/auth/request", "status" to "/auth/status", "claim" to "/auth/claim"),
            hello.body["authEndpoints"],
        )
        assertFalse(hello.body.containsKey("registeredCapabilities"))
        assertFalse(hello.body.containsKey("aKey1"))
        assertFalse(hello.body.containsKey("capabilities"))
        assertFalse(hello.body.containsKey("token"))
    }

    @Test
    fun helloWithValidTokenReturnsFullHelloWithAuthState() {
        val auth = RecordingAuthManager(authorizeDecision = DebugAuthDecision.Authorized)
        val plane = newPlane(auth)
        plane.register(FakeCapability("alpha", stateMap = mapOf("aKey1" to "value1")))

        val hello = dispatch(plane, get("/hello", "Authorization" to "Bearer test-token-not-real")) as RouteResult.Ok

        assertEquals("value1", hello.body["aKey1"])
        assertTrue(hello.body["registeredCapabilities"] is List<*>)
        assertEquals(true, hello.body["authRequired"])
        assertEquals("authorized", hello.body["authStatus"])
        assertFalse(hello.body.containsKey("token"))
        assertEquals("test-token-not-real", auth.authorizeRequests.single().bearerToken)
    }

    @Test
    fun stateDeniedShortCircuitsBeforeAggregation() {
        val auth = RecordingAuthManager(authorizeDecision = DebugAuth.tokenExpired())
        val stateCapability = CountingCapability("stateful", stateMap = mapOf("aKey1" to "value1"))
        val plane = newPlane(auth)
        plane.register(stateCapability)

        val result = dispatch(plane, get("/state")) as RouteResult.Error

        assertEquals(401, result.statusCode)
        assertEquals("token_expired", result.code)
        assertEquals(0, stateCapability.stateCalls)
        assertEquals(listOf("state"), auth.authorizeRequests.single().segments)
    }

    @Test
    fun capabilityDeniedShortCircuitsBeforeHandler() {
        val auth = RecordingAuthManager(authorizeDecision = DebugAuth.invalidToken())
        val capability = CountingCapability(
            "alpha",
            resources = listOf(Resource("GET", listOf("items"))),
            commands = listOf(Command("POST", listOf("invoke"))),
        )
        val plane = newPlane(auth)
        plane.register(capability)

        val resource = dispatch(plane, get("/items", "Authorization" to "Bearer bad-token")) as RouteResult.Error
        val command = dispatch(plane, post("/invoke", mapOf("x" to 1), "Authorization" to "Bearer bad-token")) as RouteResult.Error

        assertEquals("invalid_token", resource.code)
        assertEquals("invalid_token", command.code)
        assertEquals(0, capability.resourceCalls)
        assertEquals(0, capability.commandCalls)
        assertEquals("bad-token", auth.authorizeRequests.first().bearerToken)
        assertEquals(mapOf<String, Any?>("x" to 1), auth.authorizeRequests.last().body)
    }

    @Test
    fun capabilityAuthorizedDispatchesHandler() {
        val auth = RecordingAuthManager(authorizeDecision = DebugAuthDecision.Authorized)
        val capability = CountingCapability(
            "alpha",
            resources = listOf(Resource("GET", listOf("items"))),
        )
        val plane = newPlane(auth)
        plane.register(capability)

        val result = dispatch(plane, get("/items", "Authorization" to "Bearer test-token-not-real")) as RouteResult.Ok

        assertEquals(true, result.body["ok"])
        assertEquals(1, capability.resourceCalls)
        assertEquals(DebugAuthRouteClass.SENSITIVE, auth.authorizeRequests.single().routeClass)
    }

    @Test
    fun authBootstrapRoutesUseManagerResultsAndWinOverCapabilities() {
        val auth = RecordingAuthManager()
        val plane = newPlane(auth)
        val shadow = CountingCapability(
            "shadow",
            commands = listOf(Command("POST", listOf("auth", "request"))),
        )
        plane.register(shadow)

        val request = dispatch(plane, post("/auth/request", mapOf("clientNonce" to "nonce"))) as RouteResult.Ok
        val status = dispatch(plane, post("/auth/status", mapOf("requestId" to "req-1"))) as RouteResult.Ok
        val claim = dispatch(plane, post("/auth/claim", mapOf("requestId" to "req-1"))) as RouteResult.Ok

        assertEquals(202, request.status)
        assertEquals("pending", request.body["status"])
        assertEquals(200, status.status)
        assertEquals("approved", status.body["status"])
        assertEquals(200, claim.status)
        assertEquals("test-token-not-real", claim.body["token"])
        assertEquals(0, shadow.commandCalls)
    }

    @Test
    fun authBootstrapRoutesMapDeniedResultsToErrors() {
        val auth = RecordingAuthManager(
            statusResult = DebugAuthRouteResult.Denied(
                403,
                "authorization_denied",
                "Debug authorization was denied.",
            ),
            claimResult = DebugAuthRouteResult.Denied(
                401,
                "token_expired",
                "Debug authorization token expired.",
            ),
        )
        val plane = newPlane(auth)

        val denied = dispatch(plane, post("/auth/status")) as RouteResult.Error
        val expired = dispatch(plane, post("/auth/claim")) as RouteResult.Error

        assertEquals(403, denied.statusCode)
        assertEquals("authorization_denied", denied.code)
        assertEquals(401, expired.statusCode)
        assertEquals("token_expired", expired.code)
    }

    private fun newPlane(auth: DebugAuthManager?): ControlPlane =
        ControlPlane(
            transport = transport,
            scope = scope,
            appMeta = {
                mapOf(
                    "app" to "test-app",
                    "deviceId" to "test-device",
                    "deviceName" to "Test Device",
                    "platform" to "jvm",
                    "capabilities" to listOf("must-not-leak"),
                )
            },
            authManager = auth,
        )

    private fun dispatch(plane: ControlPlane, request: RouteRequest): RouteResult =
        kotlinx.coroutines.runBlocking { plane.dispatch(request) }

    private fun get(path: String, vararg headers: Pair<String, String>): RouteRequest =
        RouteRequest(
            method = "GET",
            segments = path.trim('/').split('/').filter { it.isNotEmpty() },
            headers = mapOf(*headers),
        )

    private fun post(
        path: String,
        body: Map<String, Any?> = emptyMap(),
        vararg headers: Pair<String, String>,
    ): RouteRequest =
        RouteRequest(
            method = "POST",
            segments = path.trim('/').split('/').filter { it.isNotEmpty() },
            body = body,
            headers = mapOf(*headers),
        )

    private class RecordingAuthManager(
        private val authorizeDecision: DebugAuthDecision = DebugAuthDecision.Authorized,
        private val requestResult: DebugAuthRouteResult = DebugAuthRouteResult.Ok(
            linkedMapOf(
                "ok" to true,
                "requestId" to "req-1",
                "status" to "pending",
                "pairingCode" to "123456",
                "expiresAt" to "2026-08-20T10:05:00Z",
            ),
            statusCode = 202,
        ),
        private val statusResult: DebugAuthRouteResult = DebugAuthRouteResult.Ok(
            linkedMapOf(
                "ok" to true,
                "requestId" to "req-1",
                "status" to "approved",
                "expiresAt" to "2026-08-20T11:00:00Z",
            ),
        ),
        private val claimResult: DebugAuthRouteResult = DebugAuthRouteResult.Ok(
            linkedMapOf(
                "ok" to true,
                "token" to "test-token-not-real",
                "tokenId" to "test-token-id-not-real",
                "expiresAt" to "2026-08-20T11:00:00Z",
            ),
        ),
    ) : DebugAuthManager {
        val authorizeRequests = mutableListOf<DebugAuthRequest>()

        override suspend fun authorize(request: DebugAuthRequest): DebugAuthDecision {
            authorizeRequests += request
            return authorizeDecision
        }

        override suspend fun helloAuthState(token: String?): Map<String, Any?> =
            mapOf(
                "authRequired" to true,
                "authStatus" to "authorized",
            )

        override suspend fun requestAuthorization(body: Map<String, Any?>): DebugAuthRouteResult =
            requestResult

        override suspend fun authorizationStatus(body: Map<String, Any?>): DebugAuthRouteResult =
            statusResult

        override suspend fun claimAuthorization(body: Map<String, Any?>): DebugAuthRouteResult =
            claimResult
    }

    private class CountingCapability(
        override val id: String,
        private val resources: List<Resource> = emptyList(),
        private val commands: List<Command> = emptyList(),
        private val stateMap: Map<String, Any?> = emptyMap(),
    ) : Capability {
        var stateCalls = 0
        var resourceCalls = 0
        var commandCalls = 0

        override fun resources(): List<Resource> = resources

        override fun commands(): List<Command> = commands

        override fun events(): kotlinx.coroutines.flow.Flow<DebugEvent> =
            kotlinx.coroutines.flow.emptyFlow()

        override suspend fun state(): Map<String, Any?> {
            stateCalls += 1
            return stateMap
        }

        override suspend fun handleResource(resource: Resource, context: RouteContext): Map<String, Any?> {
            resourceCalls += 1
            return mapOf("ok" to true, "resource" to resource.path, "pathParams" to context.pathParams)
        }

        override suspend fun handleCommand(command: Command, context: RouteContext): Map<String, Any?> {
            commandCalls += 1
            return mapOf("ok" to true, "command" to command.path, "body" to context.body)
        }
    }
}
