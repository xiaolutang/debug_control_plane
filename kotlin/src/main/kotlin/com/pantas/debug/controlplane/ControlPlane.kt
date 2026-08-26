package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong

/**
 * The debug control plane — Kotlin mirror of Dart `control_plane.dart`
 * (PROTOCOL.md is the authoritative spec).
 *
 * Composition:
 *  - capability registry (insertion-ordered; duplicate scoped ids rejected),
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
    appMeta: (suspend () -> Map<String, Any?>)? = null,
    private val authManager: DebugAuthManager? = null,
) {

    private val lock = Any()

    /**
     * The current `/hello` appMeta supplier. Replaceable after construction
     * via [updateAppMeta] (R026 ownership model: the Service mounts the plane
     * first, Dart injects its identity fields when it calls `plane.start` —
     * the next `/hello` picks them up).
     */
    @Volatile
    private var appMeta: (suspend () -> Map<String, Any?>)? = appMeta

    /** Insertion-ordered registry (PROTOCOL.md §2.2: registeredCapabilities order = registration order). */
    private val _capabilities = LinkedHashMap<ScopedCapabilityKey, CapabilityEntry>()

    /** Per-capability event collection jobs (unregister cancels cleanly). */
    private val _eventSubscriptions = LinkedHashMap<ScopedCapabilityKey, Job>()

    /** Global event bus (BF002-4). */
    private val bus = EventBus()

    /** Transport broadcast bridge: bus -> transport.broadcast. */
    private var pipeJob: Job? = null

    // -------------------------------------------------------------------------
    // Start-once lifecycle state (R026: the Service owns the server, other
    // callers join — design §1.1)
    // -------------------------------------------------------------------------

    /**
     * Guards ONLY the three plain fields below. Hard rule (design review
     * high#1): never suspend inside `synchronized(lifecycleLock)` — the lock
     * covers state reads/writes and job creation only; every await/join
     * happens outside.
     */
    private val lifecycleLock = Any()

    /** Cached successful bind result — later starts join this URI. */
    private var startResult: java.net.URI? = null

    /** Cached failure — rethrown to every later caller until [stop] clears. */
    private var startFailure: Throwable? = null

    /** The in-flight bind (concurrent callers await this Deferred). */
    private var startJob: Deferred<java.net.URI>? = null

    /**
     * Identity token of the current bind attempt. [stop] rotates it, so an
     * in-flight bind completing after a stop can detect it is stale and skip
     * the cache writes (never cache a result for a torn-down server).
     */
    private var startAttempt: Any = Any()

    /** Process-wide monotonic sequence counter, shared across capabilities, starts at 0 (§3.1). */
    private val nextSequence = AtomicLong(0L)

    /** Monotonic registry mirror revision for scope-aware capability metadata. */
    private var scopeRevision: Long = 0L

    /** The global event bus hot stream (transports / tests collect). */
    val eventBus: kotlinx.coroutines.flow.SharedFlow<DebugEvent> get() = bus.shared

    /** All registered capability ids, in registration order. Legacy/debug view only. */
    val registeredIds: Set<String>
        get() = synchronized(lock) { _capabilities.values.map { it.capability.id }.toSet() }

    // -------------------------------------------------------------------------
    // Registry
    // -------------------------------------------------------------------------

    /**
     * Register [cap]. Throws [IllegalArgumentException] if a capability with
     * the same scoped identity is already registered (Dart throws StateError;
     * Kotlin convention maps it to require/IllegalArgumentException — same
     * startup-time semantics, not an HTTP error).
     */
    fun register(cap: Capability) {
        // BF002-4: one collection job per capability, forwarding into the
        // bus (hot-source consumer side; the plane assigns the sequence).
        // Job created + stored inside the same lock as the registry insert,
        // so a concurrent unregister of the same id can never miss it (an
        // orphaned, uncancelled collection job would leak the capability).
        val entry = synchronized(lock) {
            val key = ScopedCapabilityKey.from(cap.scope, cap.id)
            require(!_capabilities.containsKey(key)) {
                "Capability already registered: ${key.describe()}"
            }
            val inserted = CapabilityEntry(
                capability = cap,
                scope = cap.scope,
                scopeRevision = ++scopeRevision,
            )
            _capabilities[key] = inserted
            _eventSubscriptions[key] = scope.launch {
                cap.events().collect { raw ->
                    bus.emit(raw.copy(sequence = nextSequence.getAndIncrement()))
                }
            }
            inserted
        }
        emitScopeChanged("registered", entry)
    }

    /** Unregister the app-scoped capability with [id]. No-op if not registered. */
    fun unregister(id: String) {
        unregisterScoped(CapabilityScope.app(), id)
    }

    /** Unregister one scoped capability. Missing scoped keys are a no-op. */
    fun unregisterScoped(scope: CapabilityScope, capabilityId: String) {
        val removed = synchronized(lock) {
            val key = ScopedCapabilityKey.from(scope, capabilityId)
            val entry = _capabilities.remove(key) ?: return
            _eventSubscriptions.remove(key)?.cancel()
            scopeRevision += 1
            entry to scopeRevision
        }
        emitScopeChanged("unregistered", removed.first, removed.second)
    }

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /**
     * Start the transport — **start-once with shared result** (R026).
     *
     * First call performs the real bind (dispatcher first, then
     * [Transport.bind], Dart `start()` order) and caches the outcome; later
     * calls join: the same URI is returned, the same cached failure is
     * rethrown, and a concurrent caller awaits the in-flight bind instead of
     * issuing a second one.
     *
     * Ownership model (design §1.1): the Service owns the server lifecycle;
     * `plane.start` from any other caller (e.g. the plugin's PLANE_START) is
     * a join, not a second bind — a double NanoHTTPD bind leaves a broken
     * accept loop (EADDRINUSE + hot-spinning dead socket).
     *
     * Concurrency: [lifecycleLock] never suspends. Bind results are cached by
     * the async body itself (try/catch/finally), so a cancelled first caller
     * cannot lose the cache for the joiners.
     */
    suspend fun start(port: Int): java.net.URI {
        // Two-phase read: decide under the lock — cache hits return/throw the
        // cached outcome right there (throwing inside `synchronized` still
        // releases the monitor; nothing suspended is held) — then await
        // outside it.
        val join: Deferred<java.net.URI> = synchronized(lifecycleLock) {
            startResult?.let { return it }    // joined success
            startFailure?.let { throw it }    // joined failure — callers see the original instance
            val attempt = startAttempt
                startJob ?: scope.async(start = CoroutineStart.UNDISPATCHED) {
                    // The async body owns the cache writes (design hard rule
                    // 2): even if the first caller is cancelled, joiners
                    // still see the outcome.
                    try {
                        doStart(port, attempt).also { uri ->
                            synchronized(lifecycleLock) {
                                // stop() during the bind wins:
                                // `startAttempt` was rotated, never cache a
                                // result for a server that has already been
                                // torn down (design hard rule 3).
                                if (startAttempt === attempt) startResult = uri
                            }
                        }
                    } catch (t: Throwable) {
                        synchronized(lifecycleLock) {
                            if (startAttempt === attempt) startFailure = t
                        }
                        throw t
                    }
                }.also { startJob = it }
            }
        // Await OUTSIDE the lock (design hard rule 1: never suspend holding
        // lifecycleLock). A CancellationException here is the caller's own
        // cancellation — the cache above survives it for the joiners.
        return join.await()
    }

    /**
     * The actual single bind (dispatcher install + pipe + transport bind).
     *
     * H2 orphan-server guard: a real NanoHTTPD `start()` blocks and ignores
     * coroutine cancellation, so a stop-during-bind race can land AFTER the
     * underlying server truly bound — while `stop()`'s `transport.close()`
     * already ran against the not-yet-bound transport (boundPort still 0),
     * leaving an orphan server holding the port until GC. When this attempt
     * turns out stale after a successful bind, it self-cleans (cancel only
     * THIS attempt's pipe, close the transport) and surfaces as a cancelled
     * start — same "no cache for a torn-down cycle" semantics as the stale
     * cache-write rejection above.
     */
    private suspend fun doStart(port: Int, attempt: Any): java.net.URI {
        // Cancel a stale pipe from an earlier start/stop cycle first —
        // otherwise a restart would leak the old bus->transport collector.
        pipeJob?.cancel()
        configureEventsPreflight()
        transport.listen(::dispatch)
        val pipe = bus.pipeTo(scope, transport)
        pipeJob = pipe
        val uri = transport.bind(port)
        val stale = synchronized(lifecycleLock) { startAttempt !== attempt }
        if (stale) {
            pipe.cancel()
            synchronized(lifecycleLock) { if (pipeJob === pipe) pipeJob = null }
            transport.close()
            throw kotlinx.coroutines.CancellationException("start superseded by stop")
        }
        return uri
    }

    /**
     * Replace the `/hello` appMeta supplier (post-injection, R026 C2). Takes
     * effect on the next `/hello` request. `null` keeps the current one
     * (a late Dart join with no identity fields must not wipe the Service's).
     */
    fun updateAppMeta(meta: (suspend () -> Map<String, Any?>)?) {
        if (meta != null) appMeta = meta
    }

    /** Stop the transport and tear down event subscriptions. */
    suspend fun stop() {
        synchronized(lifecycleLock) {
            // Design hard rule 3: cancel an in-flight bind BEFORE clearing —
            // otherwise the bind could complete after stop and cache a URI
            // for a server that was already torn down. The rotated
            // `startAttempt` is the backstop: even if the cancelled bind
            // still runs to completion (cancellation is cooperative), its
            // cache writes are rejected as stale.
            startJob?.cancel()
            startJob = null
            startAttempt = Any()
            startResult = null
            startFailure = null
        }
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
            val routeClass = DebugAuth.classifyRoute(req.method, req.segments)
            // System routes — handled by the plane itself, GET-only, exact
            // segment match, priority over capability routes (§1.1).
            matchSystemRoute(req.method, req.segments)?.let { return it(req) }

            if (routeClass == DebugAuthRouteClass.SENSITIVE) {
                authorize(req)?.let { denied ->
                    return RouteResult.error(denied.statusCode, denied.code, denied.message)
                }
            }

            val selector = CapabilitySelector.parse(req.headers)
            if (selector.isPresent) return dispatchSelected(req, selector)

            val flat = dispatchFlat(req, synchronized(lock) { _capabilities.values.toList() })
            if (flat != null) return flat

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
    ): (suspend (RouteRequest) -> RouteResult)? {
        if (method == "GET" && segments == listOf("hello")) return ::handleHello
        if (method == "POST" && segments == listOf("auth", "request")) return ::handleAuthRequest
        if (method == "POST" && segments == listOf("auth", "status")) return ::handleAuthStatus
        if (method == "POST" && segments == listOf("auth", "claim")) return ::handleAuthClaim
        if (method == "GET" && segments == listOf("state")) return handleSensitiveSystemRoute(::handleState)
        if (method == "GET" && segments == listOf("events")) return handleSensitiveSystemRoute(::handleEvents)
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
    suspend fun handleHello(req: RouteRequest): RouteResult {
        val auth = authManager
        if (auth != null) {
            when (val decision = auth.authorize(req.toAuthRequest())) {
                DebugAuthDecision.Authorized ->
                    return RouteResult.Ok(fullHello(req) + auth.helloAuthState(req.bearerToken()))
                is DebugAuthDecision.Denied ->
                    return RouteResult.Ok(minimalAuthHello(req, decision))
            }
        }
        return RouteResult.Ok(fullHello(req))
    }

    private suspend fun fullHello(req: RouteRequest): Map<String, Any?> {
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

    private suspend fun minimalAuthHello(
        req: RouteRequest,
        decision: DebugAuthDecision.Denied,
    ): Map<String, Any?> {
        val meta = appMeta?.invoke().orEmpty()
            .filterKeys { key -> key in HELLO_BOOTSTRAP_META_KEYS }
        return buildMap {
            put("protocolVersion", PROTOCOL_VERSION)
            putAll(meta)
            putAll(transport.serverInfo(req.request))
            put("eventsEndpoint", "/events")
            put("profileRevision", 1)
            put("authRequired", true)
            put("authStatus", decision.code)
            put("authEndpoints", AUTH_ENDPOINTS)
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

    private fun handleSensitiveSystemRoute(
        handler: suspend (RouteRequest) -> Map<String, Any?>,
    ): suspend (RouteRequest) -> RouteResult = { req ->
        authorize(req)?.let { denied ->
            RouteResult.error(denied.statusCode, denied.code, denied.message)
        } ?: RouteResult.Ok(handler(req))
    }

    private suspend fun handleAuthRequest(req: RouteRequest): RouteResult =
        authRouteResult(authManager?.requestAuthorization(req.body) ?: DebugAuthRouteResult.Denied(
            401,
            "authorization_required",
            "Debug authorization is required.",
        ))

    private suspend fun handleAuthStatus(req: RouteRequest): RouteResult =
        authRouteResult(authManager?.authorizationStatus(req.body) ?: DebugAuthRouteResult.Denied(
            401,
            "authorization_required",
            "Debug authorization is required.",
        ))

    private suspend fun handleAuthClaim(req: RouteRequest): RouteResult =
        authRouteResult(authManager?.claimAuthorization(req.body) ?: DebugAuthRouteResult.Denied(
            401,
            "authorization_required",
            "Debug authorization is required.",
        ))

    private fun authRouteResult(result: DebugAuthRouteResult): RouteResult =
        when (result) {
            is DebugAuthRouteResult.Ok -> RouteResult.Ok(result.body, result.statusCode)
            is DebugAuthRouteResult.Denied -> RouteResult.error(result.statusCode, result.code, result.message)
        }

    private fun configureEventsPreflight() {
        val sseTransport = transport as? HttpSseTransport ?: return
        val auth = authManager
        sseTransport.setEventsPreflight(
            if (auth == null) {
                null
            } else {
                { req ->
                    when (val decision = auth.authorize(req.toAuthRequest())) {
                        DebugAuthDecision.Authorized -> null
                        is DebugAuthDecision.Denied ->
                            RouteResult.error(decision.statusCode, decision.code, decision.message)
                    }
                }
            },
        )
    }

    private suspend fun authorize(req: RouteRequest): DebugAuthDecision.Denied? {
        val auth = authManager ?: return null
        return when (val decision = auth.authorize(req.toAuthRequest())) {
            DebugAuthDecision.Authorized -> null
            is DebugAuthDecision.Denied -> decision
        }
    }

    private fun RouteRequest.bearerToken(): String? = DebugAuth.bearerToken(headers)

    private fun RouteRequest.toAuthRequest(): DebugAuthRequest =
        DebugAuthRequest(
            method = method,
            segments = segments,
            routeClass = DebugAuth.classifyRoute(method, segments),
            bearerToken = bearerToken(),
            body = body,
            request = request,
        )

    /**
     * Flat aggregate state: every app capability's [Capability.state] entries
     * spread into the top level; later registrations win on key collision
     * (§1.3). Empty object when no capability is registered.
     * Private like Dart `_aggregateState` — reach it via `/state` / `/hello`.
     */
    private suspend fun aggregateState(): Map<String, Any?> {
        val state = LinkedHashMap<String, Any?>()
        val entries = synchronized(lock) { _capabilities.values.toList() }
        for (entry in entries) {
            if (entry.scope.type != CapabilityScopeType.APP) continue
            val cap = entry.capability
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
        val entries = synchronized(lock) { _capabilities.values.toList() }
        return mapOf(
            "registeredCapabilities" to entries.map { it.toCapabilityMap() },
        )
    }

    private fun CapabilityEntry.toCapabilityMap(): Map<String, Any?> = buildMap {
        put("id", capability.id)
        put("scope", scope.type.wireValue)
        if (scope.type == CapabilityScopeType.PAGE) put("pageId", scope.pageId)
        if (scope.pageName != null) put("pageName", scope.pageName)
        put("scopeRevision", scopeRevision)
        put("resources", capability.resources().map { it.toDeclMap() })
        put("commands", capability.commands().map { it.toDeclMap() })
    }

    private fun RouteDecl.toDeclMap(): Map<String, Any?> = buildMap {
        put("method", method)
        put("path", path)
        if (description != null) put("description", description)
    }

    private suspend fun dispatchSelected(req: RouteRequest, selector: CapabilitySelector): RouteResult {
        val key = selector.key
            ?: return RouteResult.error(404, "not_found", "Endpoint was not found.")

        val entry = synchronized(lock) { _capabilities[key] }
        if (entry == null && key.scope == CapabilityScopeType.PAGE) {
            return RouteResult.error(
                410,
                "page_capability_gone",
                "Page capability is no longer available. Refresh /hello before invoking tools.",
            )
        }
        if (entry == null) {
            return RouteResult.error(404, "not_found", "Endpoint was not found.")
        }

        val requestedRevision = selector.scopeRevision
        if (requestedRevision != null && requestedRevision != entry.scopeRevision) {
            return RouteResult.error(
                409,
                "capability_scope_expired",
                "Capability scope mirror expired. Refresh /hello before invoking tools.",
            )
        }

        val result = dispatchFlat(req, listOf(entry))
        return result ?: RouteResult.error(404, "not_found", "Endpoint was not found.")
    }

    private suspend fun dispatchFlat(req: RouteRequest, entries: List<CapabilityEntry>): RouteResult? {
        return when (req.method) {
            "GET" -> {
                for (entry in entries) {
                    dispatchResources(req, entry.capability)?.let { return it }
                }
                null
            }
            "POST" -> {
                for (entry in entries) {
                    dispatchCommands(req, entry.capability)?.let { return it }
                }
                null
            }
            else -> null
        }
    }

    private suspend fun dispatchResources(req: RouteRequest, cap: Capability): RouteResult? {
        for (decl in cap.resources()) {
            if (decl.method != req.method) continue
            val pathParams = mutableMapOf<String, String>()
            if (RoutePath.match(decl.path, req.segments, pathParams)) {
                val ctx = RouteContext(pathParams, req.body, req.request)
                return RouteResult.ok(cap.handleResource(decl, ctx))
            }
        }
        return null
    }

    private suspend fun dispatchCommands(req: RouteRequest, cap: Capability): RouteResult? {
        for (decl in cap.commands()) {
            if (decl.method != req.method) continue
            val pathParams = mutableMapOf<String, String>()
            if (RoutePath.match(decl.path, req.segments, pathParams)) {
                val ctx = RouteContext(pathParams, req.body, req.request)
                return RouteResult.ok(cap.handleCommand(decl, ctx))
            }
        }
        return null
    }

    private fun emitScopeChanged(
        change: String,
        entry: CapabilityEntry,
        scopeRevision: Long = entry.scopeRevision,
    ) {
        val scope = entry.scope
        bus.emit(
            DebugEvent(
                type = "capability_scope_changed",
                sequence = nextSequence.getAndIncrement(),
                payload = buildMap {
                    put("change", change)
                    put("scope", scope.type.wireValue)
                    put("capabilityId", entry.capability.id)
                    if (scope.type == CapabilityScopeType.PAGE) put("pageId", scope.pageId)
                    if (scope.pageName != null) put("pageName", scope.pageName)
                    put("scopeRevision", scopeRevision)
                },
            ),
        )
    }

    companion object {
        /**
         * Cross-language hard constant (PROTOCOL.md §6): `protocolVersion=1`,
         * independent of the package version (Dart 0.1.2 / Python 0.1.1 /
         * Kotlin 0.2.0). Only bumped on incompatible protocol breaks.
         */
        const val PROTOCOL_VERSION: Int = 1

        private val AUTH_ENDPOINTS = mapOf(
            "request" to "/auth/request",
            "status" to "/auth/status",
            "claim" to "/auth/claim",
        )

        private val HELLO_BOOTSTRAP_META_KEYS = setOf("app", "deviceId", "deviceName", "platform")
    }
}

private data class CapabilityEntry(
    val capability: Capability,
    val scope: CapabilityScope,
    val scopeRevision: Long,
)

private data class ScopedCapabilityKey(
    val scope: CapabilityScopeType,
    val pageId: String?,
    val capabilityId: String,
) {
    fun describe(): String =
        if (scope == CapabilityScopeType.APP) "app/$capabilityId" else "page/$pageId/$capabilityId"

    companion object {
        fun from(scope: CapabilityScope, capabilityId: String): ScopedCapabilityKey =
            ScopedCapabilityKey(
                scope = scope.type,
                pageId = if (scope.type == CapabilityScopeType.PAGE) scope.pageId else null,
                capabilityId = capabilityId,
            )
    }
}

private data class CapabilitySelector(
    val isPresent: Boolean,
    val key: ScopedCapabilityKey?,
    val scopeRevision: Long?,
) {
    companion object {
        fun parse(headers: Map<String, String>): CapabilitySelector {
            val capabilityId = header(headers, "X-DCP-Capability-Id")
            val scopeValue = header(headers, "X-DCP-Capability-Scope")
            val pageId = header(headers, "X-DCP-Page-Id")
            val revisionValue = header(headers, "X-DCP-Scope-Revision")
            val present = capabilityId != null || scopeValue != null || pageId != null || revisionValue != null
            if (!present) return CapabilitySelector(isPresent = false, key = null, scopeRevision = null)

            val scope = when (scopeValue) {
                CapabilityScopeType.APP.wireValue -> CapabilityScopeType.APP
                CapabilityScopeType.PAGE.wireValue -> CapabilityScopeType.PAGE
                else -> null
            }
            val complete = capabilityId != null &&
                capabilityId.isNotEmpty() &&
                scope != null &&
                (scope == CapabilityScopeType.APP || !pageId.isNullOrEmpty())

            return CapabilitySelector(
                isPresent = true,
                key = if (complete) {
                    ScopedCapabilityKey(
                        scope = scope,
                        pageId = if (scope == CapabilityScopeType.PAGE) pageId else null,
                        capabilityId = capabilityId,
                    )
                } else {
                    null
                },
                scopeRevision = revisionValue?.toLongOrNull(),
            )
        }

        private fun header(headers: Map<String, String>, name: String): String? {
            val lowerName = name.lowercase()
            for ((key, rawValue) in headers) {
                if (key.lowercase() != lowerName) continue
                val value = rawValue.trim()
                return value.ifEmpty { null }
            }
            return null
        }
    }
}
