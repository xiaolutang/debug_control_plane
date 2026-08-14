package com.pantas.debug.controlplane

/**
 * Per-request context handed to a [Capability] handler — Kotlin mirror of
 * Dart `capability.dart` `RouteContext`.
 *
 * [request] is the opaque protocol handle (e.g. NanoHTTPD `IHTTPSession`);
 * the framework never inspects it, capabilities may downcast when needed.
 */
data class RouteContext(
    /** Path parameters extracted from `{name}` placeholders. */
    val pathParams: Map<String, String> = emptyMap(),
    /** Parsed JSON body (empty map for bodyless / GET requests). */
    val body: Map<String, Any?> = emptyMap(),
    /** Opaque protocol handle. May be null. */
    val request: Any? = null,
)
