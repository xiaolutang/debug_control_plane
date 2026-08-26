package com.pantas.debug.controlplane

import kotlinx.coroutines.flow.Flow

// NOTE (R1): package name `com.pantas.debug.controlplane` 沿用 spike-a 遗留骨架；
// design 文档中的 `com.xlfoundry.*` 仅为示意命名。

/** Scope kind for a [Capability], with stable wire values for PROTOCOL.md §3.2. */
enum class CapabilityScopeType(val wireValue: String) {
    /** Application-wide capability. */
    APP("app"),

    /** Page-scoped capability. */
    PAGE("page");

    companion object {
        fun fromWire(value: String): CapabilityScopeType = entries.firstOrNull { it.wireValue == value }
            ?: throw IllegalArgumentException("Unknown capability scope type: $value")
    }
}

/** Immutable scope identity for a [Capability]. */
data class CapabilityScope(
    val type: CapabilityScopeType = CapabilityScopeType.APP,
    val pageId: String? = null,
    val pageName: String? = null,
    val revision: Long? = null,
) {
    init {
        if (type == CapabilityScopeType.PAGE) {
            require(!pageId.isNullOrBlank()) {
                "pageId must be a non-blank string for page capability scope"
            }
        }
    }

    companion object {
        fun app(): CapabilityScope = CapabilityScope()

        fun page(
            pageId: String?,
            pageName: String? = null,
            revision: Long? = null,
        ): CapabilityScope = CapabilityScope(
            type = CapabilityScopeType.PAGE,
            pageId = pageId,
            pageName = pageName,
            revision = revision,
        )
    }
}

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

    /** Scope identity for this capability. Existing implementations default to app scope. */
    val scope: CapabilityScope
        get() = CapabilityScope.app()

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
