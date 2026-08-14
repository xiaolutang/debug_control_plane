package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong

/**
 * The debug control plane — Kotlin mirror of Dart `control_plane.dart`
 * (PROTOCOL.md is the authoritative spec).
 *
 * Composition:
 *  - capability registry (insertion-ordered; duplicate ids rejected),
 *  - system routes `/hello` `/state` `/events` (§1, plane-owned, GET-only,
 *    win over capability declarations),
 *  - flat prefix-less dispatch with `{name}` single-segment placeholders,
 *    first-match-wins in registration order (§2.4),
 *  - SharedFlow event bus with a global monotonic sequence (§3.1),
 *  - error funnel mapping [RouteFailure] and arbitrary exceptions to the
 *    `{ok:false, code, message}` contract (§4).
 *
 * All aggregation APIs are `suspend` — no `runBlocking` anywhere (Android
 * ANR guard, S3 §5). The [CoroutineScope] is injected; lifecycle belongs to
 * the caller (FF002-2 Service carrier).
 */
class ControlPlane(
    private val transport: Transport,
    private val scope: CoroutineScope,
    private val appMeta: (suspend () -> Map<String, Any?>)? = null,
) {

    private val lock = Any()

    /** Insertion-ordered registry (PROTOCOL.md §2.2: registeredCapabilities order = registration order). */
    private val _capabilities = LinkedHashMap<String, Capability>()

    /** Per-capability event collection jobs (unregister cancels cleanly). */
    private val _eventSubscriptions = LinkedHashMap<String, Job>()

    /** Global event bus (BF002-4). */
    private val bus = EventBus()

    /** Transport broadcast bridge: bus -> transport.broadcast. */
    private var pipeJob: Job? = null

    /** Process-wide monotonic sequence counter, shared across capabilities, starts at 0 (§3.1). */
    private val nextSequence = AtomicLong(0L)

    /** The global event bus hot stream (transports / tests collect). */
    val eventBus: kotlinx.coroutines.flow.SharedFlow<DebugEvent> get() = bus.shared

    /** All registered capability ids, in registration order. */
    val registeredIds: Set<String>
        get() = synchronized(lock) { _capabilities.keys.toSet() }

    // -------------------------------------------------------------------------
    // Registry
    // -------------------------------------------------------------------------

    /**
     * Register [cap]. Throws [IllegalArgumentException] if a capability with
     * the same id is already registered (Dart throws StateError; Kotlin
     * convention maps it to require/IlegalArgumentException — same startup-
     * time semantics, not an HTTP error).
     */
    fun register(cap: Capability) {
        // BF002-4: one collection job per capability, forwarding into the
        // bus (hot-source consumer side; the plane assigns the sequence).
        // Job created + stored inside the same lock as the registry insert,
        // so a concurrent unregister of the same id can never miss it (an
        // orphaned, uncancelled collection job would leak the capability).
        synchronized(lock) {
            require(!_capabilities.containsKey(cap.id)) {
                "Capability already registered: ${cap.id}"
            }
            _capabilities[cap.id] = cap
            _eventSubscriptions[cap.id] = scope.launch {
                cap.events().collect { raw ->
                    bus.emit(raw.copy(sequence = nextSequence.getAndIncrement()))
                }
            }
        }
    }

    /** Unregister the capability with [id]. No-op if not registered. */
    fun unregister(id: String) {
        synchronized(lock) {
            _capabilities.remove(id) ?: return
            _eventSubscriptions.remove(id)?.cancel()
        }
    }

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /**
     * Start the transport. Mirrors Dart `start()`: install the dispatcher
     * first, then bind. Returns the bound URI.
     */
    suspend fun start(port: Int): java.net.URI {
        // Cancel a stale pipe from an earlier start/stop cycle first —
        // otherwise a restart would leak the old bus->transport collector.
        pipeJob?.cancel()
        transport.listen(::dispatch)
        pipeJob = bus.pipeTo(scope, transport)
        return transport.bind(port)
    }

    /** Stop the transport and tear down event subscriptions. */
    suspend fun stop() {
        transport.close()
        pipeJob?.cancel()
        pipeJob = null
        synchronized(lock) {
            _eventSubscriptions.values.forEach { it.cancel() }
            _eventSubscriptions.clear()
            _capabilities.clear()
        }
    }

    // -------------------------------------------------------------------------
    // Routing
    // -------------------------------------------------------------------------

    /**
     * Route a parsed [req] to the matching system route or capability
     * declaration. Public so transports (and tests) can drive the plane
     * without going through [Transport.listen].
     */
    suspend fun dispatch(req: RouteRequest): RouteResult {
        return try {
            // System routes — handled by the plane itself, GET-only, exact
            // segment match, priority over capability routes (§1.1).
            matchSystemRoute(req.method, req.segments)?.let { return RouteResult.ok(it(req)) }

            // Capability routes — flat, prefix-less, first-match-wins in
            // registration order then declaration order (§2.4).
            val segments = req.segments
            val caps = synchronized(lock) { _capabilities.values.toList() }
            if (req.method == "GET") {
                for (cap in caps) {
                    for (decl in cap.resources()) {
                        if (decl.method != req.method) continue
                        // Fresh map per declaration (Dart control_plane.dart
                        // L150): a partially-matched earlier declaration must
                        // not leak its {name} captures into the next one.
                        val pathParams = mutableMapOf<String, String>()
                        if (RoutePath.match(decl.path, segments, pathParams)) {
                            val ctx = RouteContext(pathParams, req.body, req.request)
                            return RouteResult.ok(cap.handleResource(decl, ctx))
                        }
                    }
                }
            } else if (req.method == "POST") {
                for (cap in caps) {
                    for (decl in cap.commands()) {
                        if (decl.method != req.method) continue
                        val pathParams = mutableMapOf<String, String>()
                        if (RoutePath.match(decl.path, segments, pathParams)) {
                            val ctx = RouteContext(pathParams, req.body, req.request)
                            return RouteResult.ok(cap.handleCommand(decl, ctx))
                        }
                    }
                }
            }

            RouteResult.error(404, "not_found", "Endpoint was not found.")
        } catch (error: RouteFailure) {
            RouteResult.error(error.statusCode, error.code, error.message ?: "route failure")
        } catch (error: Throwable) {
            RouteResult.error(500, "internal_error", error.toString())
        }
    }

    private fun matchSystemRoute(
        method: String,
        segments: List<String>,
    ): (suspend (RouteRequest) -> Map<String, Any?>)? {
        if (method == "GET" && segments == listOf("hello")) return ::handleHello
        if (method == "GET" && segments == listOf("state")) return ::handleState
        if (method == "GET" && segments == listOf("events")) return ::handleEvents
        return null
    }

    // -------------------------------------------------------------------------
    // System route handlers
    // -------------------------------------------------------------------------

    /**
     * `/hello` — field merge order per PROTOCOL.md §1.2 (later spreads win
     * on key collision): protocolVersion -> appMeta -> serverInfo ->
     * eventsEndpoint/profileRevision -> aggregateState ->
     * registeredCapabilities (last, so business keys can't clobber it).
     */
    suspend fun handleHello(req: RouteRequest): Map<String, Any?> {
        val meta = appMeta?.invoke() ?: emptyMap()
        return buildMap {
            put("protocolVersion", PROTOCOL_VERSION)
            putAll(meta)
            putAll(transport.serverInfo(req.request))
            put("eventsEndpoint", "/events")
            put("profileRevision", 1)
            putAll(aggregateState())
            putAll(aggregateCapabilities())
        }
    }

    /**
     * `/state` — flat aggregate state with NO top-level `ok` field
     * (byte-level hard constraint, PROTOCOL.md §1.3 / fixtures/state-*.json).
     */
    suspend fun handleState(@Suppress("UNUSED_PARAMETER") req: RouteRequest): Map<String, Any?> =
        aggregateState()

    /**
     * `/events` introspection fallback — unreachable under the SSE transport
     * (hijacked before dispatch). Kept for contract completeness (§1.4, U4).
     */
    suspend fun handleEvents(@Suppress("UNUSED_PARAMETER") req: RouteRequest): Map<String, Any?> =
        mapOf(
            "ok" to true,
            "note" to "event_bus_is_stream",
            "eventsEndpoint" to "/events",
        )

    /**
     * Flat aggregate state: every capability's [Capability.state] entries
     * spread into the top level; later registrations win on key collision
     * (§1.3). Empty object when no capability is registered.
     * Private like Dart `_aggregateState` — reach it via `/state` / `/hello`.
     */
    private suspend fun aggregateState(): Map<String, Any?> {
        val state = LinkedHashMap<String, Any?>()
        val caps = synchronized(lock) { _capabilities.values.toList() }
        for (cap in caps) {
            for ((key, value) in cap.state()) {
                state[key] = value
            }
        }
        return state
    }

    /**
     * `/hello.registeredCapabilities` schema (§2.2): array in registration
     * order, each element `{id, resources:[{method, path, description?}],
     * commands:[...]}`; the `description` key is omitted when null; `path`
     * is a JSON array (§2.3 cross-language pitfall).
     */
    private fun aggregateCapabilities(): Map<String, Any?> {
        val caps = synchronized(lock) { _capabilities.values.toList() }
        return mapOf(
            "registeredCapabilities" to caps.map { cap ->
                mapOf(
                    "id" to cap.id,
                    "resources" to cap.resources().map { it.toDeclMap() },
                    "commands" to cap.commands().map { it.toDeclMap() },
                )
            },
        )
    }

    private fun RouteDecl.toDeclMap(): Map<String, Any?> = buildMap {
        put("method", method)
        put("path", path)
        if (description != null) put("description", description)
    }

    companion object {
        /**
         * Cross-language hard constant (PROTOCOL.md §6): `protocolVersion=1`,
         * independent of the package version (Dart 0.1.2 / Python 0.1.1 /
         * Kotlin 0.2.0). Only bumped on incompatible protocol breaks.
         */
        const val PROTOCOL_VERSION: Int = 1
    }
}
