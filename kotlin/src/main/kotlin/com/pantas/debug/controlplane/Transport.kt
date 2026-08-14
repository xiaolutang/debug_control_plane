package com.pantas.debug.controlplane

import java.net.URI

/**
 * Protocol-agnostic transport contract — Kotlin mirror of Dart
 * `transport.dart` `Transport` (PROTOCOL.md §0: REST+SSE is the current
 * production transport; WS/MCP are future extensions).
 *
 * Only one production implementation exists: [HttpSseTransport]
 * (NanoHTTPD-backed). The abstraction is kept so FF002-2 (Service carrier)
 * and tests can swap fakes.
 */
interface Transport {

    /**
     * Bind to [port] (all interfaces, matching Dart
     * `HttpServer.bind(InternetAddress.anyIPv4, port)`). Returns the actual
     * bound URI (with the resolved port when [port] was 0).
     *
     * Throws [java.net.BindException] on port conflict (EADDRINUSE) —
     * FF002-3 maps this to Dart `SocketException(errorCode=98)` for the
     * R024 degradation catch to reuse unchanged.
     */
    suspend fun bind(port: Int): URI

    /**
     * Install the routing callback. The transport parses incoming wire
     * messages into [RouteRequest]s, hands them to [handler], and writes the
     * returned [RouteResult] back onto the wire. Must be callable before
     * [bind] (the plane's [ControlPlane.start] does exactly this order).
     */
    fun listen(handler: suspend (RouteRequest) -> RouteResult)

    /**
     * Supply server-side discovery metadata for the `/hello` handshake:
     * `{serverHost, serverPort, localIps}` (PROTOCOL.md §1.2). [request] is
     * the opaque protocol handle carried by [RouteRequest] — implementations
     * derive `serverHost` from it (e.g. the `Host` header) and may return an
     * empty map if they have no server-side identity.
     */
    suspend fun serverInfo(request: Any?): Map<String, Any?>

    /**
     * Broadcast a [DebugEvent] to all subscribers of the transport's event
     * stream (`/events` SSE clients). Best-effort: dead subscribers are
     * pruned silently, never throws (PROTOCOL.md §3.7).
     */
    fun broadcast(event: DebugEvent)

    /** Release all resources (server socket, subscribers). Idempotent. */
    suspend fun close()
}
