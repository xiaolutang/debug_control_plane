package com.pantas.debug.controlplane

import fi.iki.elonen.NanoHTTPD
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.net.BindException
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketException
import java.net.URI

/**
 * REST + SSE transport on NanoHTTPD — Kotlin mirror of Dart
 * `http_sse_transport.dart` (PROTOCOL.md §1.4 / §3).
 *
 * Migrated from the spike-a `ControlPlaneServer` (SSE mechanism preserved:
 * `PipedInputStream`/`PipedOutputStream` pair per subscriber +
 * `newChunkedResponse`, because `IHTTPSession` exposes no output stream).
 *
 * Wire contract:
 *  - `GET /events` (exactly 1 segment) is hijacked into an SSE long-lived
 *    subscriber BEFORE dispatch (the plane's introspection fallback must
 *    never fire over HTTP, §1.4). First frame `: connected\n\n` is written
 *    immediately, byte-level (§3.4).
 *  - Event frames: `event: <type>\ndata: <json>\n\n` where data is the
 *    whole `DebugEvent.toJson()` single-line JSON (§3.3).
 *  - Headers: `text/event-stream`, `Cache-Control: no-cache`,
 *    `Connection: keep-alive`. No heartbeat, no `id:`, no resume (§3.5).
 *  - POST bodies must be JSON objects; anything else is 400
 *    `invalid_request` "Request body must be valid JSON object." (§2.4).
 *  - Bind failure (EADDRINUSE) is rethrown as [BindException] so FF002-3 can
 *    map it to Dart `SocketException(errorCode=98)` (R024 degradation).
 */
class HttpSseTransport(
    private val coroutineScope: kotlinx.coroutines.CoroutineScope,
    port: Int = 0,
) : Transport, NanoHTTPD("0.0.0.0", port) {

    /** The port fixed at construction (0 = OS-picked on bind). */
    private val requestedPort: Int = port

    private var dispatcher: (suspend (RouteRequest) -> RouteResult)? = null

    /** Active long-lived `/events` subscribers. */
    private val subscribers: MutableSet<SseSubscriber> =
        java.util.concurrent.ConcurrentHashMap.newKeySet()

    /** Set once [bind] succeeds; [serverInfo] uses it when no request handle. */
    @Volatile
    private var boundPort: Int = 0

    // -------------------------------------------------------------------------
    // Transport contract
    // -------------------------------------------------------------------------

    override fun listen(handler: suspend (RouteRequest) -> RouteResult) {
        dispatcher = handler
    }

    override suspend fun bind(port: Int): URI = withContext(Dispatchers.IO) {
        require(port == requestedPort) {
            "HttpSseTransport binds its constructor port ($requestedPort); requested $port"
        }
        try {
            // start(timeout, daemon) blocks until the server thread is bound
            // or throws IOException (EADDRINUSE included).
            start(SOCKET_READ_TIMEOUT, false)
        } catch (e: BindException) {
            throw e
        } catch (e: IOException) {
            // FF002-3 maps this to Dart SocketException(errorCode=98).
            throw BindException(e.message ?: "bind failed")
        }
        boundPort = listeningPort
        URI("http://0.0.0.0:$boundPort/")
    }

    override suspend fun serverInfo(request: Any?): Map<String, Any?> {
        val hostFromRequest = (request as? IHTTPSession)
            ?.headers?.get("host")
            ?.takeIf { it.isNotEmpty() }
            ?.substringBeforeLast(":")
        return mapOf(
            "serverHost" to (hostFromRequest ?: "0.0.0.0"),
            "serverPort" to (if (boundPort != 0) boundPort else 0),
            // Keep as List — AnyToJson (RouteResult wire adapter) encodes it
            // as a JSON string array, matching Dart localIPv4Addresses().
            "localIps" to localIPv4Addresses(),
        )
    }

    override fun broadcast(event: DebugEvent) {
        if (subscribers.isEmpty()) return
        val data = encodeEventJson(event)
        val frame = "event: ${event.type}\ndata: $data\n\n"
        // Iterate a snapshot — the set may mutate during writes (§3.7).
        for (sub in subscribers.toList()) {
            if (!sub.write(frame)) subscribers.remove(sub)
        }
    }

    override suspend fun close() {
        for (sub in subscribers.toList()) sub.close()
        subscribers.clear()
        withContext(Dispatchers.IO) { stop() }
    }

    /** Live subscriber count (tests + introspection). */
    fun subscriberCount(): Int = subscribers.count { it.alive }

    // -------------------------------------------------------------------------
    // NanoHTTPD serving
    // -------------------------------------------------------------------------

    /**
     * Never gzip — BF003-2 cross-language fix.
     *
     * NanoHTTPD's default gzips every text-typed response (including
     * `text/event-stream`) when the client advertises `Accept-Encoding: gzip`.
     * GZIP buffers output, so an SSE stream would never deliver frames until
     * the buffer fills — the python httpx client's `iter_lines()` blocks
     * indefinitely. Dart's HttpServer never applies content-encoding, so the
     * contract (PROTOCOL.md §3: frames flush immediately) requires this off.
     */
    override fun useGzipWhenAccepted(response: NanoHTTPD.Response): Boolean = false

    override fun serve(session: IHTTPSession): NanoHTTPD.Response {
        val method = session.method
        val segments = RoutePath.segments(session.uri)

        // Hijack GET /events BEFORE dispatch — the handler must NOT be
        // invoked (§1.4; the plane's introspection fallback would break the
        // SSE first-frame byte contract).
        if (method == Method.GET && segments == listOf("events")) {
            return hijackEvents()
        }

        val handler = dispatcher ?: return RouteResult
            .error(500, "internal_error", "transport not listening")
            .toNanoResponse()

        val body: Map<String, Any?> = if (method == Method.POST) {
            parseJsonObjectBody(session) ?: return RouteResult
                .error(400, "invalid_request", "Request body must be valid JSON object.")
                .toNanoResponse()
        } else {
            emptyMap()
        }

        val request = RouteRequest(
            method = method.name.uppercase(),
            segments = segments,
            body = body,
            request = session,
        )

        // runBlocking here is safe: NanoHTTPD runs `serve` on dedicated
        // blocking worker threads (never the Android main thread). It is
        // only the suspend-bridge for the dispatch handler — the plane's
        // aggregation APIs themselves are suspend (no runBlocking inside
        // ControlPlane; ANR guard, S3 §5).
        val result = kotlinx.coroutines.runBlocking { handler(request) }
        return result.toNanoResponse()
    }

    // -------------------------------------------------------------------------
    // SSE hijack (spike-a mechanism preserved)
    // -------------------------------------------------------------------------

    private fun hijackEvents(): NanoHTTPD.Response {
        val sub = SseSubscriber()
        subscribers.add(sub)

        // First frame MUST be `: connected\n\n` byte-for-byte, written before
        // handing the pipe to NanoHTTPD so it is first on the wire (§3.4).
        if (!sub.write(": connected\n\n")) {
            subscribers.remove(sub)
            return RouteResult
                .error(500, "sse_init_failed", "first frame write failed")
                .toNanoResponse()
        }

        val response = NanoHTTPD.newChunkedResponse(
            Response.Status.OK, "text/event-stream", sub.pipeIn
        )
        response.addHeader("Cache-Control", "no-cache")
        response.addHeader("Connection", "keep-alive")
        return response
    }

    /** A connected `/events` subscriber. Writes guarded; best-effort. */
    private inner class SseSubscriber {
        val pipeOut = PipedOutputStream()
        val pipeIn = PipedInputStream(pipeOut, BUFFER_SIZE)

        private val lock = Any()
        @Volatile
        var alive: Boolean = true
            private set

        /** Returns false when the client is gone (broken pipe) — caller prunes. */
        fun write(frame: String): Boolean {
            if (!alive) return false
            return synchronized(lock) {
                try {
                    pipeOut.write(frame.toByteArray(Charsets.UTF_8))
                    pipeOut.flush()
                    true
                } catch (_: IOException) {
                    alive = false
                    false
                }
            }
        }

        fun close() {
            alive = false
            try { pipeOut.close() } catch (_: IOException) {}
            try { pipeIn.close() } catch (_: IOException) {}
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /**
     * Order-preserving JSON encoding for the SSE `data:` line.
     *
     * Dart `jsonEncode` emits insertion order (`type` first, `sequence`
     * second, payload keys in declaration order — byte contract of
     * fixtures/sse-event-frame.bin and PROTOCOL.md §3.3), while org.json's
     * `JSONObject` is backed by an unordered `HashMap` on Android — encoding
     * [DebugEvent.toJson] through it risks key-order drift per device.
     * [AnyToJson.encodeOrdered] is the single order-preserving encoder
     * (also used by [RouteResult.Error]).
     */
    internal fun encodeEventJson(event: DebugEvent): String =
        AnyToJson.encodeOrdered(event.toJson())

    /** Parse the POST body as a top-level JSON object; null on any failure. */
    private fun parseJsonObjectBody(session: IHTTPSession): Map<String, Any?>? {
        return try {
            val contentLen = session.headers["content-length"]?.toIntOrNull() ?: 0
            if (contentLen <= 0) return null
            val buf = ByteArray(contentLen)
            var read = 0
            while (read < buf.size) {
                val n = session.inputStream.read(buf, read, buf.size - read)
                if (n < 0) break
                read += n
            }
            val raw = String(buf, 0, read, Charsets.UTF_8)
            val obj = JSONObject(raw) // throws unless top-level object
            val out = LinkedHashMap<String, Any?>()
            for (key in obj.keys()) out[key] = obj.get(key)
            out
        } catch (_: Exception) {
            null
        }
    }

    /** Non-loopback, non-link-local IPv4 addresses, sorted ascending (§1.2). */
    private fun localIPv4Addresses(): List<String> {
        return try {
            NetworkInterface.getNetworkInterfaces().asSequence()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.interfaceAddresses.asSequence() }
                .mapNotNull { it.address }
                .filterIsInstance<InetAddress>()
                .filter { it is java.net.Inet4Address && !it.isLoopbackAddress && !it.isLinkLocalAddress }
                .map { it.hostAddress }
                .toSortedSet()
                .toList()
        } catch (_: SocketException) {
            emptyList()
        }
    }

    companion object {
        private const val BUFFER_SIZE = 65536
    }
}
