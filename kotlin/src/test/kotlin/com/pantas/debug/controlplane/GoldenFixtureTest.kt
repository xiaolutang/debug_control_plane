package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

/**
 * R025-BF003-1: Kotlin-side golden fixture assertions.
 *
 * `../fixtures/` (relative to the kotlin module) is the language-agnostic
 * source of truth (PROTOCOL.md's executable projection). The Kotlin
 * ControlPlane + HttpSseTransport must produce wire output that matches the
 * fixtures — content-level for `.json` (parsed-field comparison with
 * `$$unstable:<reason>` normalization) and byte-level for `.bin`.
 *
 * Dart mirror: `dart/test/golden_fixture_test.dart` (same scenarios, same
 * fixtures). Fixture is the truth: tweaking a fixture field must turn BOTH
 * suites red.
 */
class GoldenFixtureTest {

    private lateinit var scope: CoroutineScope
    private lateinit var transport: HttpSseTransport
    private lateinit var plane: ControlPlane
    private var port: Int = 0

    private val fixturesDir: File =
        File(System.getProperty("user.dir")!!).resolve("../fixtures")

    @Before
    fun setUp() {
        assertTrue("fixtures dir must exist at ${fixturesDir.absolutePath}", fixturesDir.isDirectory)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        // appMeta supplies exactly the $$unstable:app-injected keys hello.json marks.
        val (p, t) = ControlPlaneServer.create(
            scope = scope,
            appMeta = {
                mapOf(
                    "app" to "kotlin-golden-test",
                    "deviceId" to "kotlin-jvm-test",
                    "deviceName" to "Kotlin JVM golden",
                    "platform" to "jvm",
                    "capabilities" to listOf("golden"),
                    "hardwareName" to "JVM Test Machine",
                    "machineId" to "jvm-test-1",
                )
            },
        )
        plane = p
        transport = t

        // State keys + registeredCapabilities exactly as hello.json /
        // state-with-cap.json declare (neutral placeholders, zero business deps).
        plane.register(object : FakeCapability(
            id = "cap-alpha",
            resources = listOf(
                Resource("GET", listOf("items"), "示例资源（中性占位，非业务语义约束）"),
                Resource("GET", listOf("items", "{id}"), "含 {id} 单段占位符的资源"),
            ),
            commands = listOf(
                Command("POST", listOf("invoke"), "示例命令（占位）"),
            ),
            stateMap = mapOf("aKey1" to "value1", "aKey2" to true),
        ) {})
        plane.register(object : FakeCapability(
            id = "cap-beta-no-description",
            resources = listOf(Resource("GET", listOf("nested", "{leaf}"))),
            commands = listOf(Command("POST", listOf("nested", "submit"))),
        ) {})
        // cap-gamma never registers — see state_with_cap test for the extra key overlay.

        kotlinx.coroutines.runBlocking { plane.start(0) }
        port = transport.listeningPort
    }

    @After
    fun tearDown() {
        kotlinx.coroutines.runBlocking { plane.stop() }
        scope.cancel()
    }

    // =========================================================================
    // Fixture loading helpers
    // =========================================================================

    private fun loadFixtureJson(name: String): JSONObject =
        JSONObject(fixturesDir.resolve(name).readText(Charsets.UTF_8))

    private fun loadFixtureBytes(name: String): ByteArray =
        fixturesDir.resolve(name).readBytes()

    // =========================================================================
    // /hello — fixtures/hello.json (semantic level)
    // =========================================================================

    @Test
    fun hello_matchesGoldenFixture() {
        val (_, bodyText) = httpGet("/hello")
        val expected = loadFixtureJson("hello.json")
        val actual = JSONObject(bodyText)

        // Hard contract first (acceptance criteria): protocolVersion=1,
        // eventsEndpoint, profileRevision, path is a JSON array.
        assertEquals(1, actual.getInt("protocolVersion"))
        assertEquals("/events", actual.getString("eventsEndpoint"))
        assertEquals(1, actual.getInt("profileRevision"))
        val alphaRes = actual.getJSONArray("registeredCapabilities").getJSONObject(0)
            .getJSONArray("resources")
        assertEquals(listOf("items", "{id}"), alphaRes.getJSONObject(1).getJSONArray("path").toList())

        assertTrue(
            "hello body must match fixtures/hello.json (normalized)",
            FixtureNormalize.normalizedEquals(
                FixtureNormalize.normalize(expected),
                FixtureNormalize.normalize(actual),
            ),
        )
    }

    @Test
    fun hello_unstableReasonsAreFromClosedSet() {
        val expected = loadFixtureJson("hello.json")
        collectUnstableReasons(expected).forEach { reason ->
            assertTrue(
                "reason '$reason' must be in the closed set",
                reason in FixtureNormalize.UNSTABLE_REASONS,
            )
        }
    }

    // =========================================================================
    // /state — fixtures/state-empty.json + state-with-cap.json (semantic)
    // =========================================================================

    @Test
    fun state_emptyPlaneMatchesGoldenFixture() {
        // A fresh plane with zero capabilities must emit exactly `{}` —
        // fixtures/state-empty.json carries no comparable keys beyond
        // `_fixture_meta`; the shape contract IS the assertion (empty object,
        // no top-level ok).
        val scope2 = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val (plane2, _) = ControlPlaneServer.create(scope = scope2, appMeta = null)
        val result = kotlinx.coroutines.runBlocking {
            plane2.dispatch(RouteRequest("GET", listOf("state"), emptyMap(), null))
        }
        scope2.cancel()
        assertTrue(result is RouteResult.Ok)
        val body = (result as RouteResult.Ok).body
        assertEquals("state must be an empty object with no ok wrapper", emptyMap<String, Any?>(), body)
    }

    @Test
    fun state_withCapabilityMatchesGoldenFixture() {
        // Extra capability state keys (aKey3/aKey4) + later-registration wins.
        plane.register(object : FakeCapability(
            id = "cap-gamma-overlay",
            stateMap = mapOf("aKey2" to 1, "aKey3" to true, "aKey4" to null),
        ) {})
        val (_, bodyText) = httpGet("/state")
        val expected = loadFixtureJson("state-with-cap.json")
        val actual = JSONObject(bodyText)

        // Hard constraint: no top-level ok (§1.3).
        assertTrue("state must not carry ok", !actual.has("ok"))
        assertEquals("value1", actual.getString("aKey1"))
        assertEquals(1, actual.getInt("aKey2"))
        assertEquals(true, actual.getBoolean("aKey3"))

        assertTrue(
            FixtureNormalize.normalizedEquals(
                FixtureNormalize.normalize(expected),
                FixtureNormalize.normalize(actual),
            ),
        )
    }

    // =========================================================================
    // SSE — fixtures/sse-connected.bin + sse-event-frame.bin (byte level)
    // =========================================================================

    @Test
    fun sse_connectedFrameIsByteExactPerFixture() {
        val expected = loadFixtureBytes("sse-connected.bin")
        val conn = openSse("/events")
        try {
            val actual = ByteArray(expected.size)
            var read = 0
            while (read < actual.size) {
                val n = conn.inputStream.read(actual, read, actual.size - read)
                if (n < 0) break
                read += n
            }
            assertArrayEquals("SSE first frame must be byte-identical to sse-connected.bin", expected, actual.copyOf(read))
        } finally {
            conn.disconnect()
        }
    }

    @Test
    fun sse_eventFrameIsByteExactPerFixture() {
        val expected = loadFixtureBytes("sse-event-frame.bin")
        val reader = openSseReader("/events")
        try {
            waitForSubscriberCount(1, 3000)
            // sequence=0 assumption documented by the fixture README: this is
            // the plane's FIRST event (counter starts at 0).
            val flow = kotlinx.coroutines.flow.flowOf(DebugEvent("sample_state_changed", payload = mapOf("aKey1" to "value1")))
            // Emit through a capability so the bus assigns sequence 0.
            plane.register(object : Capability {
                override val id = "golden-event-source"
                override fun resources() = emptyList<Resource>()
                override fun commands() = emptyList<Command>()
                override fun events() = flow
                override suspend fun handleResource(resource: Resource, context: RouteContext) = emptyMap<String, Any?>()
                override suspend fun handleCommand(command: Command, context: RouteContext) = emptyMap<String, Any?>()
                override suspend fun state() = emptyMap<String, Any?>()
            })
            val actualText = reader.nextFrame(3000) ?: throw AssertionError("no event frame received")
            // The wire path chunks bytes; accumulate until the frame terminator.
            var frameText = actualText
            while (!frameText.endsWith("\n\n")) {
                frameText += reader.nextFrame(3000) ?: break
            }
            val actual = frameText.toByteArray(Charsets.UTF_8)
            assertArrayEquals(
                "SSE event frame must be byte-identical to sse-event-frame.bin",
                expected,
                actual,
            )
        } finally {
            reader.disconnect()
        }
    }

    // =========================================================================
    // Error contract — fixtures/error-404/400/500.json (semantic)
    // =========================================================================

    @Test
    fun error404_matchesGoldenFixture() {
        val (status, bodyText) = httpGet("/nope")
        assertEquals(404, status)
        val expected = loadFixtureJson("error-404.json")
        val actual = JSONObject(bodyText)
        assertTrue(FixtureNormalize.normalizedEquals(expected, actual))
    }

    @Test
    fun error400_matchesGoldenFixture() {
        plane.register(object : FakeCapability(id = "golden-post", commands = listOf(Command("POST", listOf("submit")))) {})
        val (status, bodyText) = httpPostRaw("/submit", "not-json{{")
        assertEquals(400, status)
        val expected = loadFixtureJson("error-400.json")
        val actual = JSONObject(bodyText)
        // The fixture takes the readObject failure path; all three message
        // variants are legal (fixture _fixture_meta.message_variants).
        val variants = expected.getJSONObject("_fixture_meta").getJSONArray("message_variants")
        val accepted = (0 until variants.length()).map { variants.getString(it) }
        assertTrue(
            "400 message must be one of $accepted but was ${actual.getString("message")}",
            actual.getString("message") in accepted,
        )
        assertTrue(FixtureNormalize.normalizedEquals(expected, actual))
    }

    @Test
    fun error500_matchesGoldenFixtureWithUnstableNormalization() {
        plane.register(object : FakeCapability(
            id = "golden-boom",
            commands = listOf(Command("POST", listOf("boom500"))),
        ) {
            override suspend fun handleCommand(command: Command, context: RouteContext): Map<String, Any?> =
                throw IllegalStateException("boom for golden test")
        })
        val (status, bodyText) = httpPost("/boom500", "{}")
        assertEquals(500, status)
        val expected = loadFixtureJson("error-500.json")
        val actual = JSONObject(bodyText)
        // message is $$unstable:exception-toString — normalized comparison.
        assertTrue(
            FixtureNormalize.normalizedEquals(
                FixtureNormalize.normalize(expected),
                FixtureNormalize.normalize(actual),
            ),
        )
    }

    // =========================================================================
    // route-decl.json — capability declaration projection (semantic)
    // =========================================================================

    @Test
    fun routeDecl_matchesGoldenFixture() {
        // Build a plane whose single capability declares exactly route-decl.json.
        val scope2 = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val (plane2, _) = ControlPlaneServer.create(scope = scope2, appMeta = null)
        plane2.register(object : FakeCapability(
            id = "sample-capability",
            resources = listOf(
                Resource("GET", listOf("items"), "无占位符的静态路径（单段）"),
                Resource("GET", listOf("items", "{id}"), "含 {id} 单段占位符（matchPath 捕获 pathParams.id）"),
                Resource("GET", listOf("nested", "deep", "{leaf}")),
            ),
            commands = listOf(
                Command("POST", listOf("invoke")),
                Command("POST", listOf("items", "{id}", "submit"), "POST 也可带占位符（与 resources 同语义）"),
            ),
        ) {})
        val result = kotlinx.coroutines.runBlocking {
            plane2.dispatch(RouteRequest("GET", listOf("hello"), emptyMap(), null))
        }
        scope2.cancel()
        val caps = (result as RouteResult.Ok).body["registeredCapabilities"] as List<*>
        assertEquals(1, caps.size)
        // Re-encode through the wire adapter so nested values carry org.json types.
        val actual = AnyToJson.convert(caps[0]) as JSONObject
        val expected = loadFixtureJson("route-decl.json")
        // Hard constraint: path is a JSON array (§2.3 cross-language pitfall).
        assertEquals(
            listOf("items", "{id}"),
            actual.getJSONArray("resources").getJSONObject(1).getJSONArray("path").toList(),
        )
        assertTrue(FixtureNormalize.normalizedEquals(FixtureNormalize.normalize(expected), actual))
    }

    // =========================================================================
    // discovery-python.json — python client constants vs python source (drift guard)
    // =========================================================================

    @Test
    fun discoveryPython_constantsMatchPythonSource() {
        val fixture = loadFixtureJson("discovery-python.json")
        assertEquals(18080, fixture.getJSONObject("lan_scan").getInt("port"))
        assertEquals(2.5, fixture.getJSONObject("lan_scan").getDouble("timeout_seconds"), 1e-9)
        assertEquals(64, fixture.getJSONObject("lan_scan").getInt("concurrency"))

        // Cross-check the python source so fixture and code cannot drift apart.
        val pythonRoot: File = File(System.getProperty("user.dir")!!).resolve("../python")
        val lanScan = pythonRoot.resolve("debug_control_plane/device_discovery/discovery/lan_scan.py").readText()
        val endpoint = pythonRoot.resolve("debug_control_plane/device_discovery/endpoint.py").readText()
        assertTrue("lan_scan.py must hard-code DEFAULT_PORT = 18080", "DEFAULT_PORT = 18080" in lanScan)
        assertTrue("lan_scan.py must hard-code DEFAULT_PROBE_TIMEOUT = 2.5", "DEFAULT_PROBE_TIMEOUT = 2.5" in lanScan)
        assertTrue("lan_scan.py must hard-code DEFAULT_MAX_WORKERS = 64", "DEFAULT_MAX_WORKERS = 64" in lanScan)
        assertTrue("endpoint.py default port must be 18080", "default_port: int = 18080" in endpoint)

        // Handshake hard constraints (§5).
        val handshake = fixture.getJSONObject("hello_handshake")
        assertEquals(1, handshake.getInt("protocolVersion"))
        assertEquals("/events", handshake.getString("eventsEndpoint"))
    }

    // =========================================================================
    // Normalizer unit tests (parity contract with dart/test/fixtures/normalize.dart)
    // =========================================================================

    @Test
    fun normalize_skipsUnderscoreKeys() {
        val expected = JSONObject("""{"_fixture_meta":{"x":1},"ok":false}""")
        val actual = JSONObject("""{"ok":false,"_other":"skip me"}""")
        assertTrue(FixtureNormalize.normalizedEquals(expected, actual))
    }

    @Test
    fun normalize_replacesUnstableMarkersWithTypeGuards() {
        val expected = JSONObject("{\"serverPort\":\"\$\$unstable:bound-port\"}")
        assertTrue(FixtureNormalize.normalizedEquals(expected, JSONObject("""{"serverPort":18123}""")))
        assertTrue(!FixtureNormalize.normalizedEquals(expected, JSONObject("""{"serverPort":"18123"}""")))
        assertTrue(!FixtureNormalize.normalizedEquals(expected, JSONObject("""{}""")))
    }

    @Test
    fun normalize_rejectsUnknownReason() {
        val expected = JSONObject("{\"x\":\"\$\$unstable:no-such-reason\"}")
        try {
            FixtureNormalize.normalizedEquals(expected, JSONObject("""{"x":1}"""))
            throw AssertionError("expected IllegalStateException for unknown reason")
        } catch (_: IllegalStateException) {
        }
    }

    @Test
    fun normalize_detectsRealDrift() {
        // Fixture-is-truth guard: a changed field value must fail comparison.
        val expected = JSONObject("""{"code":"not_found","message":"Endpoint was not found."}""")
        val actual = JSONObject("""{"code":"not_found","message":"Different message."}""")
        assertTrue(!FixtureNormalize.normalizedEquals(expected, actual))
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private fun collectUnstableReasons(value: Any?): List<String> {
        val out = mutableListOf<String>()
        fun walk(v: Any?) {
            when (v) {
                is JSONObject -> for (k in v.keys()) walk(v.get(k))
                is JSONArray -> for (i in 0 until v.length()) walk(v.get(i))
                is String -> if (v.startsWith("\$\$unstable:")) {
                    out.add(v.removePrefix("\$\$unstable:"))
                }
            }
        }
        walk(value)
        return out
    }

    private fun httpGet(path: String): Pair<Int, String> = httpRequest("GET", path, null)

    private fun httpPost(path: String, jsonBody: String): Pair<Int, String> = httpRequest("POST", path, jsonBody)

    private fun httpPostRaw(path: String, rawBody: String): Pair<Int, String> = httpRequest("POST", path, rawBody)

    private fun httpRequest(method: String, path: String, body: String?): Pair<Int, String> {
        val conn = URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 3000
        conn.readTimeout = 5000
        if (body != null) {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        }
        try {
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            return code to text
        } finally {
            conn.disconnect()
        }
    }

    private fun openSse(path: String): HttpURLConnection {
        val conn = URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection
        conn.setRequestProperty("Accept", "text/event-stream")
        conn.connectTimeout = 3000
        conn.readTimeout = 0
        conn.inputStream
        return conn
    }

    private fun openSseReader(path: String): SseReader {
        val conn = openSse(path)
        val reader = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8))
        // First frame `: connected\n\n`.
        assertEquals(": connected", reader.readLine())
        assertEquals("", reader.readLine())
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
        throw AssertionError("timed out waiting for $target subscribers")
    }
}
