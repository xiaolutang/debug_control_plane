package com.pantas.debug.controlplane

import kotlinx.coroutines.flow.Flow

// NOTE (R1): package name `com.pantas.debug.controlplane` 沿用 spike-a 遗留骨架；
// design 文档中的 `com.xlfoundry.*` 仅为示意命名。

/**
 * Plugin contract — Kotlin mirror of Dart `capability.dart` `Capability`.
 *
 * A capability declares the routes it owns ([resources] for GET, [commands]
 * for POST), an event stream, and a state snapshot. All payloads are
 * `Map<String, Any?>` (decision D3) — the framework never sees business
 * types. Zero business dependencies (no io.flutter / androidx / com.host4).
 *
 * Declaration/handler split: [Resource] / [Command] are pure declaration
 * data (no handler closures) so they can cross the FF001 MethodChannel as a
 * Decl; when the plane dispatches a matched declaration it calls back into
 * [handleResource] / [handleCommand] with the declaration that matched.
 */
interface Capability {

    /** Unique capability identifier (used as the registry key). */
    val id: String

    /** GET resources owned by this capability. */
    fun resources(): List<Resource>

    /** POST commands owned by this capability. */
    fun commands(): List<Command>

    /**
     * Handle a matched resource declaration. [context.pathParams] carries the
     * `{name}` captures. Throws [RouteFailure] for controlled errors; any
     * other exception maps to 500 `internal_error` (PROTOCOL.md §4.2).
     */
    suspend fun handleResource(resource: Resource, context: RouteContext): Map<String, Any?>

    /**
     * Handle a matched command declaration. [context.body] is the parsed
     * JSON object body (transport guarantees a top-level object, §2.4).
     */
    suspend fun handleCommand(command: Command, context: RouteContext): Map<String, Any?>

    /**
     * Event stream. The control plane subscribes exactly once per
     * registration and re-emits onto the global event bus with a sequence
     * number assigned (the capability's own sequence is discarded,
     * PROTOCOL.md §3.1).
     *
     * D2 note: FF001's BridgeCapability wraps a MethodChannel-driven hot
     * source with a single-subscription contract; this side (the plane) is
     * the *consumer* of the hot source — one collection job per capability.
     */
    fun events(): Flow<DebugEvent>

    /** State snapshot, aggregated flat into `/state` and `/hello`. */
    suspend fun state(): Map<String, Any?>
}
