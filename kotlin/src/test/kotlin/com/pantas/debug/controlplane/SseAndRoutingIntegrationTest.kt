package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.URL

/**
 * BF002-3 integration tests: drive a REAL NanoHTTPD-backed
 * [HttpSseTransport] + [ControlPlane] over loopback HTTP.
 *
 * Migrated from the spike-a `SseAndRoutingIntegrationTest` (all SSE/path
 * stability scenarios preserved) and extended with the production
 * ControlPlane wiring: /hello protocolVersion=1, /state flat aggregation,
 * 404/400/500 error literals, bind-failure BindException.
 *
 * Wire contract under test (PROTOCOL.md):
 *   - First frame MUST be exactly `: connected\n\n` (byte-level, §3.4,
 *     fixtures/sse-connected.bin).
 *   - Event frames: `event: <type>\ndata: <json>\n\n` (§3.3,
 *     fixtures/sse-event-frame.bin).
 *   - No heartbeat, no `id:`, no resume.
 */
class SseAndRoutingIntegrationTest {

    private lateinit var scope: CoroutineScope
    private lateinit var transport: HttpSseTransport
    private lateinit var plane: ControlPlane
    private var port: Int = 0
    private var authManager: RecordingAuthManager? = null

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        startPlane()
    }

    private fun startPlane(auth: RecordingAuthManager? = null) {
        authManager = auth
        val (createdPlane, createdTransport) = ControlPlaneServer.create(
            scope = scope,
            appMeta = { mapOf("app" to "kotlin-test", "deviceId" to "kt", "platform" to "jvm") },
            authManager = auth,
        )
        plane = createdPlane
        transport = createdTransport
        kotlinx.coroutines.runBlocking { plane.start(0) }
        port = transport.listeningPort
        assertTrue("server listening port must be > 0", port > 0)
        registerDemoCapability()
    }

    private fun restartPlane(auth: RecordingAuthManager?) {
        kotlinx.coroutines.runBlocking { plane.stop() }
        startPlane(auth)
    }

    private fun registerDemoCapability() {
        plane.register(object : FakeCapability(
            id = "demo",
            resources = listOf(
                Resource("GET", listOf("profiles"), "list profiles"),
                Resource("GET", listOf("profiles", "{id}"), "get profile"),
                Resource("GET", listOf("devices", "{deviceId}", "state")),
            ),
            commands = listOf(Command("POST", listOf("boom500"))),
        ) {
            override suspend fun handleResource(resource: Resource, context: RouteContext): Map<String, Any?> =
                when (resource.path.size) {
                    1 -> mapOf("ok" to true, "route" to "profiles.list")
                    2 -> mapOf("ok" to true, "route" to "profiles.get", "id" to context.pathParams["id"])
                    else -> mapOf(
                        "ok" to true,
                        "route" to "device.state",
                        "deviceId" to context.pathParams["deviceId"],
                    )
                }

            override suspend fun handleCommand(command: Command, context: RouteContext): Map<String, Any?> =
                throw IllegalStateException("boom for test")
        })
    }

    @After
    fun tearDown() {
        kotlinx.coroutines.runBlocking { plane.stop() }
        scope.cancel()
    }

    // =========================================================================
    // SSE long-lived connection stability (spike-a migrated)
    // =========================================================================

    @Test
    fun sse_firstFrameIsConnectedComment() {
        val conn = openSse("/events")
        val reader = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8))
        assertEquals(": connected", reader.readLine())
        assertEquals("", reader.readLine())
        conn.disconnect()
    }

    @Test
    fun sse_firstFrameIsByteExactPerFixture() {
        // fixtures/sse-connected.bin = ": connected\n\n" (13 bytes).
        val conn = openSse("/events")
        val bytes = ByteArray(13)
        var read = 0
        while (read < bytes.size) {
            val n = conn.inputStream.read(bytes, read, bytes.size - read)
            if (n < 0) break
            read += n
        }
        assertEquals(": connected\n\n", String(bytes, 0, read, Charsets.UTF_8))
        conn.disconnect()
    }

    @Test
    fun sse_headersMatchContract() {
        val conn = openSse("/events")
        assertEquals("text/event-stream", conn.getHeaderField("Content-Type")?.substringBefore(";"))
        assertEquals("no-cache", conn.getHeaderField("Cache-Control"))
        assertNotNull("Connection header must be present", conn.getHeaderField("Connection"))
        BufferedReader(InputStreamReader(conn.inputStream)).use { it.readLine(); it.readLine() }
        conn.disconnect()
    }

    @Test
    fun sse_multipleClientsBothReceiveBroadcast() {
        val c1 = openSseBlocking("/events")
        val c2 = openSseBlocking("/events")
        try {
            waitForSubscriberCount(2, timeoutMs = 3000)
            transport.broadcast(DebugEvent("test.event", 0, mapOf("hello" to "world")))
            val f1 = c1.nextFrame(timeoutMs = 3000)
            val f2 = c2.nextFrame(timeoutMs = 3000)
            assertNotNull(f1); assertNotNull(f2)
            val expected = "event: test.event\ndata: {\"type\":\"test.event\",\"sequence\":0,\"hello\":\"world\"}\n\n"
            assertEquals(expected, f1)
            assertEquals(expected, f2)
        } finally {
            c1.disconnect(); c2.disconnect()
        }
    }

    @Test
    fun sse_eventFrameMatchesFixtureShape() {
        // fixtures/sse-event-frame.bin:
        //   event: sample_state_changed\ndata: {"type":"sample_state_changed","sequence":0,"aKey1":"value1"}\n\n
        val c1 = openSseBlocking("/events")
        try {
            waitForSubscriberCount(1, timeoutMs = 3000)
            transport.broadcast(DebugEvent("sample_state_changed", 0, mapOf("aKey1" to "value1")))
            val frame = c1.nextFrame(timeoutMs = 3000)
            val expected = "event: sample_state_changed\n" +
                "data: {\"type\":\"sample_state_changed\",\"sequence\":0,\"aKey1\":\"value1\"}\n\n"
            assertEquals(expected, frame)
        } finally {
            c1.disconnect()
        }
    }

    @Test
    fun sse_connectionPersistsAcrossBroadcasts() {
        val c1 = openSseBlocking("/events")
        try {
            waitForSubscriberCount(1, timeoutMs = 3000)
            transport.broadcast(DebugEvent("first", 0, mapOf("n" to 1)))
            val f1 = c1.nextFrame(timeoutMs = 3000)
            assertTrue(f1?.startsWith("event: first\ndata: ") == true)
            transport.broadcast(DebugEvent("second", 1, mapOf("n" to 2)))
            val f2 = c1.nextFrame(timeoutMs = 3000)
            assertTrue(f2?.startsWith("event: second\ndata: ") == true)
        } finally {
            c1.disconnect()
        }
    }

    @Test
    fun sse_droppingOneClientDoesNotAffectOthers() {
        val c1 = openSseBlocking("/events")
        val c2 = openSseBlocking("/events")
        try {
            waitForSubscriberCount(2, timeoutMs = 3000)
            c1.disconnect()
            Thread.sleep(200)
            transport.broadcast(DebugEvent("survivor", 0, mapOf("ok" to true)))
            assertNotNull("surviving client must still receive after peer drop", c2.nextFrame(timeoutMs = 3000))
            transport.broadcast(DebugEvent("survivor2", 1, mapOf("ok" to true)))
            assertNotNull(c2.nextFrame(timeoutMs = 3000))
        } finally {
            c2.disconnect()
        }
    }

    @Test
    fun sse_broadcastWithNoSubscribersIsNoOp() {
        assertEquals(0, transport.subscriberCount())
        transport.broadcast(DebugEvent("orphan", 0))   // must not throw
    }

    @Test
    fun sse_authDeniedReturnsJsonBeforeFirstFrameAndSubscriberRegistration() {
        val auth = RecordingAuthManager(DebugAuth.invalidToken())
        restartPlane(auth)

        val (status, body, contentType) = httpGetWithHeaders(
            "/events",
            "Authorization" to "Bearer bad-token",
        )

        assertEquals(401, status)
        assertEquals("application/json", contentType?.substringBefore(";"))
        assertEquals("""{"ok":false,"code":"invalid_token","message":"Debug authorization token is invalid."}""", body)
        assertFalse("denied response must not contain SSE first frame", body.contains(": connected"))
        assertEquals(0, transport.subscriberCount())
        val request = auth.authorizeRequests.single()
        assertEquals("GET", request.method)
        assertEquals(listOf("events"), request.segments)
        assertEquals(DebugAuthRouteClass.SENSITIVE, request.routeClass)
        assertEquals("bad-token", request.bearerToken)
    }

    @Test
    fun sse_authMalformedBearerReturnsAuthorizationRequiredJson() {
        val auth = RecordingAuthManager(DebugAuth.authorizationRequired())
        restartPlane(auth)

        val (status, body, contentType) = httpGetWithHeaders(
            "/events",
            "Authorization" to "Bearer token with spaces",
        )

        assertEquals(401, status)
        assertEquals("application/json", contentType?.substringBefore(";"))
        assertEquals(
            """{"ok":false,"code":"authorization_required","message":"Debug authorization is required."}""",
            body,
        )
        assertEquals(0, transport.subscriberCount())
        assertEquals(null, auth.authorizeRequests.single().bearerToken)
    }

    @Test
    fun sse_authForbiddenReturnsJsonAndDoesNotSubscribe() {
        restartPlane(
            RecordingAuthManager(
                DebugAuthDecision.Denied(
                    403,
                    "authorization_denied",
                    "Debug authorization was denied.",
                ),
            ),
        )

        val (status, body, contentType) = httpGetWithHeaders("/events")

        assertEquals(403, status)
        assertEquals("application/json", contentType?.substringBefore(";"))
        assertEquals("""{"ok":false,"code":"authorization_denied","message":"Debug authorization was denied."}""", body)
        assertFalse(body.contains(": connected"))
        assertEquals(0, transport.subscriberCount())
    }

    @Test
    fun sse_authAuthorizedKeepsByteExactFirstFrame() {
        restartPlane(RecordingAuthManager(DebugAuthDecision.Authorized))

        val conn = openSse("/events", "Authorization" to "Bearer good-token")
        val bytes = ByteArray(13)
        var read = 0
        while (read < bytes.size) {
            val n = conn.inputStream.read(bytes, read, bytes.size - read)
            if (n < 0) break
            read += n
        }

        assertEquals(": connected\n\n", String(bytes, 0, read, Charsets.UTF_8))
        waitForSubscriberCount(1, timeoutMs = 3000)
        assertEquals("good-token", authManager?.authorizeRequests?.single()?.bearerToken)
        conn.disconnect()
    }

    @Test
    fun sse_authDisabledStillAllowsBareEvents() {
        restartPlane(auth = null)

        val conn = openSse("/events")
        val reader = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8))

        assertEquals(": connected", reader.readLine())
        assertEquals("", reader.readLine())
        conn.disconnect()
    }

    @Test
    fun sse_scopedUnregisterCleansOnlyTargetSubscriptionAndEmitsScopeChanged() {
        val reader = openSseBlocking("/events")
        val app = FakeCapability("scoped-events")
        val pageA = FakeCapability("scoped-events", scope = CapabilityScope.page("page-a", "Page A"))
        val pageB = FakeCapability("scoped-events", scope = CapabilityScope.page("page-b", "Page B"))
        try {
            waitForSubscriberCount(1, timeoutMs = 3000)
            plane.register(app)
            plane.register(pageA)
            plane.register(pageB)

            val registeredFrames = listOf(
                reader.nextFrame(timeoutMs = 3000),
                reader.nextFrame(timeoutMs = 3000),
                reader.nextFrame(timeoutMs = 3000),
            )
            assertTrue(registeredFrames.all { it?.startsWith("event: capability_scope_changed\n") == true })
            assertTrue(registeredFrames[1]?.contains("\"scope\":\"page\"") == true)
            assertTrue(registeredFrames[1]?.contains("\"pageId\":\"page-a\"") == true)
            assertTrue(registeredFrames[1]?.contains("\"pageName\":\"Page A\"") == true)

            plane.unregisterScoped(CapabilityScope.page("page-a", "Page A"), "scoped-events")
            val unregistered = reader.nextFrame(timeoutMs = 3000)
            assertTrue(unregistered?.startsWith("event: capability_scope_changed\n") == true)
            assertTrue(unregistered?.contains("\"change\":\"unregistered\"") == true)
            assertTrue(unregistered?.contains("\"pageId\":\"page-a\"") == true)

            pageA.emit(DebugEvent("page-a.event", 0, mapOf("source" to "page-a")))
            pageB.emit(DebugEvent("page-b.event", 0, mapOf("source" to "page-b")))
            app.emit(DebugEvent("app.event", 0, mapOf("source" to "app")))

            val remainingFrames = listOf(
                reader.nextFrame(timeoutMs = 3000),
                reader.nextFrame(timeoutMs = 3000),
            )
            assertTrue(remainingFrames.any { it?.startsWith("event: page-b.event\n") == true })
            assertTrue(remainingFrames.any { it?.startsWith("event: app.event\n") == true })
            assertFalse(remainingFrames.any { it?.startsWith("event: page-a.event\n") == true })
            assertEquals(null, reader.nextFrame(timeoutMs = 300))
        } finally {
            reader.disconnect()
        }
    }

    // =========================================================================
    // System routes through the production ControlPlane
    // =========================================================================

    @Test
    fun hello_returnsProtocolVersionAndRegisteredCapabilities() {
        val (status, body) = httpGet("/hello")
        assertEquals(200, status)
        assertTrue(body.contains("\"protocolVersion\":1"))
        assertTrue(body.contains("\"eventsEndpoint\":\"/events\""))
        assertTrue(body.contains("\"registeredCapabilities\""))
        assertTrue(body.contains("\"path\":[\"profiles\",\"{id}\"]"))   // path JSON array (§2.3)
    }

    @Test
    fun hello_trailingSlashEquivalent() {
        val (status, body) = httpGet("/hello/")
        assertEquals(200, status)
        assertTrue(body.contains("\"protocolVersion\":1"))
    }

    @Test
    fun state_returnsFlatAggregationNoOk() {
        val (status, body) = httpGet("/state")
        assertEquals(200, status)
        // Demo capability state defaults to emptyMap -> plane adds none here;
        // assert the hard constraint: no top-level ok key (§1.3).
        assertFalse("state must not carry top-level ok", body.contains("\"ok\""))
    }

    @Test
    fun events_overHttpIsSseNotIntrospectionFallback() {
        val conn = openSse("/events")
        assertEquals("text/event-stream", conn.getHeaderField("Content-Type")?.substringBefore(";"))
        BufferedReader(InputStreamReader(conn.inputStream)).use { it.readLine(); it.readLine() }
        conn.disconnect()
    }

    // =========================================================================
    // Capability routing + error contract
    // =========================================================================

    @Test
    fun routing_literalProfileList() {
        val (status, body) = httpGet("/profiles")
        assertEquals(200, status)
        assertTrue(body.contains("\"route\":\"profiles.list\""))
    }

    @Test
    fun routing_singleSegmentPlaceholderExtractsId() {
        val (status, body) = httpGet("/profiles/abc")
        assertEquals(200, status)
        assertTrue(body.contains("\"id\":\"abc\""))
    }

    @Test
    fun routing_multiSegmentWithTwoPlaceholders() {
        val (status, body) = httpGet("/devices/devX/state")
        assertEquals(200, status)
        assertTrue(body.contains("\"deviceId\":\"devX\""))
    }

    @Test
    fun routing_unknownEndpointIs404WithFixtureLiteral() {
        val (status, body) = httpGet("/nope")
        assertEquals(404, status)
        // fixtures/error-404.json literal.
        assertEquals("""{"ok":false,"code":"not_found","message":"Endpoint was not found."}""", body)
    }

    @Test
    fun routing_handlerExceptionIs500InternalError() {
        val (status, body) = httpPost("/boom500", "{}")
        assertEquals(500, status)
        assertTrue(body.contains("\"ok\":false"))
        assertTrue(body.contains("\"code\":\"internal_error\""))
    }

    @Test
    fun routing_postInvalidBodyIs400InvalidRequest() {
        val (status, body) = httpPostRaw("/boom500", "not-json{{")
        assertEquals(400, status)
        // fixtures/error-400.json literal (readObject failure path).
        assertEquals("""{"ok":false,"code":"invalid_request","message":"Request body must be valid JSON object."}""", body)
    }

    @Test
    fun routing_postArrayBodyIs400() {
        val (status, _) = httpPostRaw("/boom500", "[1,2,3]")
        assertEquals(400, status)
    }

    @Test
    fun bind_occupiedPortThrowsBindException() {
        ServerSocket(0).use { blocker ->
            val occupied = blocker.localPort
            val scope2 = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val t = HttpSseTransport(scope2, port = occupied)
            try {
                kotlinx.coroutines.runBlocking { t.bind(occupied) }
                throw AssertionError("expected BindException")
            } catch (_: java.net.BindException) {
                // FF002-3 maps this to Dart SocketException(errorCode=98).
            } finally {
                scope2.cancel()
            }
        }
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private fun openSse(path: String, vararg headers: Pair<String, String>): HttpURLConnection {
        val conn = URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection
        conn.setRequestProperty("Accept", "text/event-stream")
        for ((key, value) in headers) conn.setRequestProperty(key, value)
        conn.connectTimeout = 3000
        conn.readTimeout = 0
        conn.inputStream
        return conn
    }

    private fun openSseBlocking(path: String): SseReader {
        val conn = openSse(path)
        val reader = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8))
        val line1 = reader.readLine()
        val line2 = reader.readLine()
        if (line1 != ": connected" || line2 != "") {
            throw AssertionError("bad SSE first frame: line1=[$line1] line2=[$line2]")
        }
        return SseReader(conn, reader)
    }

    private class SseReader(
        val conn: HttpURLConnection,
        private val reader: BufferedReader,
    ) {
        fun nextFrame(timeoutMs: Long): String? {
            val sb = StringBuilder()
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline) {
                if (!reader.ready()) {
                    Thread.sleep(20)
                    continue
                }
                val line = reader.readLine() ?: return if (sb.isNotEmpty()) sb.toString() else null
                sb.append(line).append('\n')
                if (line.isEmpty()) return sb.toString()
            }
            return null
        }

        fun disconnect() {
            try { conn.disconnect() } catch (_: Exception) {}
            try { reader.close() } catch (_: Exception) {}
        }
    }

    private fun waitForSubscriberCount(target: Int, timeoutMs: Long) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (transport.subscriberCount() >= target) return
            Thread.sleep(20)
        }
        throw AssertionError("timed out waiting for $target subscribers; have ${transport.subscriberCount()}")
    }

    private fun httpGet(path: String): Pair<Int, String> {
        val (status, body, _) = httpRequest("GET", path, null)
        return status to body
    }

    private fun httpGetWithHeaders(path: String, vararg headers: Pair<String, String>): Triple<Int, String, String?> =
        httpRequest("GET", path, null, *headers)

    private fun httpPost(path: String, jsonBody: String): Pair<Int, String> {
        val (status, body, _) = httpRequest("POST", path, jsonBody)
        return status to body
    }

    private fun httpPostRaw(path: String, rawBody: String): Pair<Int, String> {
        val (status, body, _) = httpRequest("POST", path, rawBody)
        return status to body
    }

    private fun httpRequest(
        method: String,
        path: String,
        body: String?,
        vararg headers: Pair<String, String>,
    ): Triple<Int, String, String?> {
        val conn = URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 3000
        conn.readTimeout = 5000
        for ((key, value) in headers) conn.setRequestProperty(key, value)
        if (body != null) {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        }
        try {
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            return Triple(code, text, conn.getHeaderField("Content-Type"))
        } finally {
            conn.disconnect()
        }
    }

    private class RecordingAuthManager(
        private val decision: DebugAuthDecision,
    ) : DebugAuthManager {
        val authorizeRequests = mutableListOf<DebugAuthRequest>()

        override suspend fun authorize(request: DebugAuthRequest): DebugAuthDecision {
            authorizeRequests += request
            return decision
        }

        override suspend fun helloAuthState(token: String?): Map<String, Any?> =
            mapOf("authRequired" to true, "authStatus" to "authorized")
    }
}
