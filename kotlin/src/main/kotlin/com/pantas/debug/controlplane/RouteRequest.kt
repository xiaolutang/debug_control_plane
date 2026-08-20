package com.pantas.debug.controlplane

/**
 * A request handed to the control plane by a [Transport] — Kotlin mirror of
 * Dart `transport.dart` `RouteRequest`.
 *
 * Protocol-agnostic: [request] is the opaque protocol handle; the framework
 * never inspects it.
 */
data class RouteRequest(
    /** HTTP method, upper-cased (`GET`, `POST`, ...). */
    val method: String,
    /** Path segments, e.g. `/profiles/abc` -> `["profiles", "abc"]`. */
    val segments: List<String>,
    /** Parsed JSON body (empty map for bodyless requests). */
    val body: Map<String, Any?> = emptyMap(),
    /** Opaque protocol handle. May be null. */
    val request: Any? = null,
    /** HTTP headers with transport-provided casing; auth helpers match case-insensitively. */
    val headers: Map<String, String> = emptyMap(),
)
