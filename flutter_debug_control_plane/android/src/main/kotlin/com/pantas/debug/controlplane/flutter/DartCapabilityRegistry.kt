package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.Capability
import com.pantas.debug.controlplane.DebugEvent
import com.pantas.debug.controlplane.Resource
import com.pantas.debug.controlplane.RouteContext
import com.pantas.debug.controlplane.Command
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * FF001-2: holder for capabilities registered from the Dart side.
 *
 * Each `capability.register` call deserializes the Decl payload (path is a
 * JSON **array**, PROTOCOL.md §2.3) into a [BridgeCapability] — declarations
 * are pure data (no closures cross the channel); dispatch calls back into
 * [BridgeCapability.handleResource] / [handleCommand], which reverse-invoke
 * the Dart handler over the MethodChannel (routeIndex-located).
 */
class DartCapabilityRegistry(
    private val reverseInvoker: DartReverseInvoker,
) {
    private val caps = LinkedHashMap<String, BridgeCapability>()

    /** All registered capability ids, in registration order. */
    val registeredIds: Set<String> get() = synchronized(caps) { caps.keys.toSet() }

    /**
     * Register a capability from a channel Decl payload.
     * Throws [IllegalArgumentException] on duplicate id (mirrors
     * `ControlPlane.register`, mapped to error code `duplicate` upstream).
     */
    fun register(capId: String, decl: CapabilityDecl): Capability {
        val cap = BridgeCapability(
            id = capId,
            resources = decl.resources,
            commands = decl.commands,
            events = reverseInvoker.eventFlow(capId),
            stateProvider = { reverseInvoker.pullState(capId) },
            invokeDart = { routeKind, routeIndex, ctx ->
                reverseInvoker.invokeHandler(capId, routeKind, routeIndex, ctx)
            },
        )
        synchronized(caps) {
            require(!caps.containsKey(capId)) { "Capability already registered: $capId" }
            caps[capId] = cap
        }
        return cap
    }

    /** Remove [capId]; returns the removed capability (null when absent). */
    fun remove(capId: String): Capability? = synchronized(caps) { caps.remove(capId) }

    /** The capability registered under [capId] (null when absent). */
    fun get(capId: String): Capability? = synchronized(caps) { caps[capId] }
}

/**
 * Parsed `capability.register` payload: declaration data only.
 *
 * @param resources GET declarations in registration order (routeIndex source).
 * @param commands POST declarations in registration order (routeIndex source).
 */
data class CapabilityDecl(
    val resources: List<Resource>,
    val commands: List<Command>,
)

/**
 * FF001-2: the Kotlin-core-shaped [Capability] whose handlers reverse-invoke
 * the Dart side over the MethodChannel (handlers live on Dart — closures
 * don't cross the channel, design §3.2.3).
 *
 * - `events()` is the MethodChannel-driven hot source: `events.emit` frames
 *   from Dart land in a per-capability [MutableSharedFlow]; the plane
 *   collects it exactly once (D2 single-subscription consumer side).
 * - `state()` returns the last Dart-pushed snapshot (§3.2.4 cache + push —
 *   no runBlocking pull; a rare pull fallback consults Dart via a
 *   reverse invoke when no snapshot was pushed yet).
 */
class BridgeCapability(
    override val id: String,
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
