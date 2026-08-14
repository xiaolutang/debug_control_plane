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
import java.net.HttpURLConnection
import java.net.URL

/**
 * Path normalization tests (BF002-3): pin that [RoutePath.segments] +
 * NanoHTTPD's `session.uri` behavior together reproduce Dart
 * `Uri.pathSegments` semantics (PROTOCOL.md §1.1, U7) — trailing-slash
 * equivalence, query stripping, percent-decoding.
 *
 * Migrated from the spike-a UriProbeTest: the spike's `/__probe` echo
 * endpoint was removed with the standalone server, so the assertions now
 * drive the production plane's dispatch outcome instead of raw uri echoes
 * (trailing slash + query + encoded-segment dispatch equivalence).
 */
class UriProbeTest {

    private lateinit var scope: CoroutineScope
    private lateinit var plane: ControlPlane
    private lateinit var transport: HttpSseTransport
    private var port: Int = 0

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val (p, t) = ControlPlaneServer.create(scope)
        plane = p
        transport = t
        kotlinx.coroutines.runBlocking { plane.start(0) }
        port = transport.listeningPort
        plane.register(
            FakeCapability("probe", resources = listOf(Resource("GET", listOf("probe", "{value}"))))
        )
    }

    @After
    fun tearDown() {
        kotlinx.coroutines.runBlocking { plane.stop() }
        scope.cancel()
    }

    @Test
    fun trailingSlash_systemRouteEquivalent() {
        assertEquals(200, status("/hello/"))
        assertEquals(200, status("/hello"))
    }

    @Test
    fun trailingSlash_capabilityRouteEquivalent() {
        // /probe/abc/ must match ["probe","{value}"] like /probe/abc does
        // (empty trailing segments dropped, Dart pathSegments semantics).
        val (_, body) = request("/probe/abc/")
        assertTrue("trailing-slash route must match: $body", body.contains("\"pathParams\""))
    }

    @Test
    fun queryParameters_doNotPollutePathRouting() {
        // /probe/abc?x=1 must still match /probe/{value} with value=abc
        // (query stripped from path routing, not part of the segment).
        val (_, body) = request("/probe/abc?x=1")
        assertTrue("query must be stripped from path routing: $body", body.contains("abc"))
        assertFalse(body.contains("abc?x=1"))
    }

    @Test
    fun percentEncodedSegment_decodedBeforeMatch() {
        // NanoHTTPD percent-decodes session.uri; pathParams therefore carry
        // the decoded value, matching Dart Uri.pathSegments.
        val (_, body) = request("/probe/hello%20world")
        assertTrue("decoded value expected: $body", body.contains("hello world"))
    }

    private fun status(path: String): Int = request(path).first

    private fun request(path: String): Pair<Int, String> {
        val conn = URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection
        conn.connectTimeout = 3000
        conn.readTimeout = 5000
        try {
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            return code to (stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally {
            conn.disconnect()
        }
    }
}
