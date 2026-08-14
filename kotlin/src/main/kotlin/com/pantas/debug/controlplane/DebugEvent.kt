package com.pantas.debug.controlplane

/**
 * A debug event flowing through the control plane event bus.
 *
 * Kotlin mirror of Dart `debug_event.dart`. Serialized shape (PROTOCOL.md
 * §3.2, byte-level per fixtures/sse-event-frame.bin):
 *
 * ```json
 * {"type": "controller_state_changed", "sequence": 12, ...payload}
 * ```
 *
 * `sequence` is assigned by the plane's global counter when the event enters
 * the bus (capability-emitted values are discarded). No timestamp — SSE
 * carries no `id:`/retry, ordering is client-side by receive order.
 */
data class DebugEvent(
    /** Event type, e.g. `controller_state_changed`. */
    val type: String,
    /** Monotonic sequence assigned by the control plane bus (starts at 0). */
    val sequence: Long = 0L,
    /** Payload, spread flat into [toJson] after `type` / `sequence`. */
    val payload: Map<String, Any?> = emptyMap(),
) {
    /** Serialize to a JSON-compatible map: `{type, sequence, ...payload}`. */
    fun toJson(): Map<String, Any?> = buildMap {
        put("type", type)
        put("sequence", sequence)
        putAll(payload)
    }
}
