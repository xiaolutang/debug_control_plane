package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.Capability
import com.pantas.debug.controlplane.CapabilityScope
import com.pantas.debug.controlplane.CapabilityScopeType
import com.pantas.debug.controlplane.DebugEvent
import com.pantas.debug.controlplane.Resource
import com.pantas.debug.controlplane.RouteContext
import com.pantas.debug.controlplane.Command
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * R003-FF002 KD-1: three-field scoped registry key, field-for-field
 * isomorphic with FF001 Dart `_ScopedCapabilityKey(scopeType, pageId?, capId)`
 * and the R003-BF005 Kotlin-core `ScopedCapabilityKey(scope, pageId?,
 * capabilityId)`. App key = `(app, null, id)`, page key = `(page, pageId, id)`.
 *
 * ONLY these three fields participate in equality/hash — `pageName` and any
 * other [CapabilityScope] metadata are structurally excluded from the
 * identity (display metadata lives on [CapabilityScope], see KD-2).
 */
data class BridgeCapabilityIdentity(
    val type: CapabilityScopeType,
    val pageId: String?,
    val capId: String,
) {
    companion object {
        fun app(capId: String) = BridgeCapabilityIdentity(CapabilityScopeType.APP, null, capId)

        fun page(pageId: String?, capId: String) =
            BridgeCapabilityIdentity(CapabilityScopeType.PAGE, pageId, capId)
    }
}

/**
 * FF001-2: holder for capabilities registered from the Dart side.
 *
 * Each `capability.register` call deserializes the Decl payload (path is a
 * JSON **array**, PROTOCOL.md §2.3) into a [BridgeCapability] — declarations
 * are pure data (no closures cross the channel); dispatch calls back into
 * [BridgeCapability.handleResource] / [handleCommand], which reverse-invoke
 * the Dart handler over the MethodChannel (routeIndex-located).
 *
 * R003-FF002 KD-1: capabilities are indexed by [BridgeCapabilityIdentity] —
 * an app entry and page entries sharing a capId coexist, and duplicates are
 * detected per scoped key (mirrors `ControlPlane.register`, which derives its
 * own `ScopedCapabilityKey` from [Capability.scope]).
 */
class DartCapabilityRegistry(
    private val reverseInvoker: DartReverseInvoker,
) {
    private val caps = LinkedHashMap<BridgeCapabilityIdentity, BridgeCapability>()

    /** All registered **app** capability ids, in registration order (legacy app-only debug view — KD-2; page ids never enter). */
    val registeredIds: Set<String> get() = synchronized(caps) {
        caps.keys.filter { it.type == CapabilityScopeType.APP }.map { it.capId }.toSet()
    }

    /**
     * Register a capability from a channel Decl payload under [scope]
     * (default app for the legacy call shape). Throws
     * [IllegalArgumentException] on duplicate **scoped** key (mapped to
     * error code `duplicate` upstream).
     */
    fun register(
        capId: String,
        decl: CapabilityDecl,
        scope: CapabilityScope = CapabilityScope.app(),
    ): Capability {
        val identity = BridgeCapabilityIdentity(scope.type, scope.pageId, capId)
        val cap = BridgeCapability(
            id = capId,
            scope = scope,
            resources = decl.resources,
            commands = decl.commands,
            events = reverseInvoker.eventFlow(identity),
            stateProvider = { reverseInvoker.pullState(identity) },
            invokeDart = { routeKind, routeIndex, ctx ->
                reverseInvoker.invokeHandler(identity, routeKind, routeIndex, ctx)
            },
        )
        synchronized(caps) {
            require(!caps.containsKey(identity)) { "Capability already registered: $identity" }
            caps[identity] = cap
        }
        return cap
    }

    /** Remove the `(scope, capId)` entry; returns the removed capability (null when absent). */
    fun remove(scope: CapabilityScope, capId: String): Capability? =
        synchronized(caps) { caps.remove(BridgeCapabilityIdentity(scope.type, scope.pageId, capId)) }

    /** The capability registered under the scoped key (null when absent). */
    fun get(scope: CapabilityScope, capId: String): Capability? =
        synchronized(caps) { caps[BridgeCapabilityIdentity(scope.type, scope.pageId, capId)] }

    /**
     * Resolve the registration-time identity for [capId] — the native mirror
     * of FF001 Dart `_scopeFor`: app entries win over page entries, falling
     * back to the first page key when only page registrations exist.
     * Returns `null` for an unregistered capId (R003-FF002 KD-3).
     */
    fun scopeFor(capId: String): BridgeCapabilityIdentity? = synchronized(caps) {
        for ((identity, cap) in caps) {
            if (cap.id == capId && identity.type == CapabilityScopeType.APP) return@synchronized identity
        }
        for ((identity, cap) in caps) {
            if (cap.id == capId) return@synchronized identity
        }
        null
    }

    /**
     * Default-emit routing (KD-3, mirrors FF001 `_scopeFor` fallback):
     * resolved [scopeFor] key or the app key when nothing is registered.
     */
    fun resolveEmitTarget(capId: String): BridgeCapabilityIdentity =
        scopeFor(capId) ?: BridgeCapabilityIdentity.app(capId)

    /** All scoped identities currently held, in registration order (tests/introspection). */
    val identities: Set<BridgeCapabilityIdentity> get() = synchronized(caps) { caps.keys.toSet() }
}

/**
 * Parsed `capability.register` payload: declaration data only.
 *
 * @param resources GET declarations in registration order (routeIndex source).
 * @param commands POST declarations in registration order (routeIndex source).
 * @param scope Registration-time scope identity (KD-2: defaults to app; for a
 *   page capability carries the validated pageId and the optional pageName
 *   display metadata — never part of [BridgeCapabilityIdentity]).
 */
data class CapabilityDecl(
    val resources: List<Resource>,
    val commands: List<Command>,
    val scope: CapabilityScope = CapabilityScope.app(),
)

/**
 * FF001-2: the Kotlin-core-shaped [Capability] whose handlers reverse-invoke
 * the Dart side over the MethodChannel (handlers live on Dart — closures
 * don't cross the channel, design §3.2.3).
 *
 * - `events()` is the MethodChannel-driven hot source: `events.emit` frames
 *   from Dart land in a per-scoped-key [MutableSharedFlow]; the plane
 *   collects it exactly once (D2 single-subscription consumer side).
 * - `state()` returns the last Dart-pushed snapshot (§3.2.4 cache + push —
 *   no runBlocking pull; a rare pull fallback consults Dart via a
 *   reverse invoke when no snapshot was pushed yet).
 *
 * R003-FF002 KD-2: [scope] carries the registration-time [CapabilityScope] so
 * `ControlPlane.register(cap)` derives the correct `ScopedCapabilityKey`.
 */
class BridgeCapability(
    override val id: String,
    override val scope: CapabilityScope = CapabilityScope.app(),
    private val resources: List<Resource>,
    private val commands: List<Command>,
    private val events: Flow<DebugEvent>,
    private val stateProvider: suspend () -> Map<String, Any?>,
    private val invokeDart: suspend (routeKind: String, routeIndex: Int, RouteContext) -> Map<String, Any?>,
) : Capability {

    override fun resources(): List<Resource> = resources

    override fun commands(): List<Command> = commands

    override fun events(): Flow<DebugEvent> = events

    override suspend fun state(): Map<String, Any?> = stateProvider()

    override suspend fun handleResource(resource: Resource, context: RouteContext): Map<String, Any?> =
        invokeDart(ChannelProtocol.ROUTE_KIND_RESOURCE, resources.indexOf(resource), context)

    override suspend fun handleCommand(command: Command, context: RouteContext): Map<String, Any?> =
        invokeDart(ChannelProtocol.ROUTE_KIND_COMMAND, commands.indexOf(command), context)
}
