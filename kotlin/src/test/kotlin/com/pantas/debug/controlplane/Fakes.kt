package com.pantas.debug.controlplane

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** Shared test doubles for the BF002 test suite (zero business deps). */

/** In-memory Transport fake: records requests, replays programmable results. */
class FakeTransport : Transport {
    val requests = mutableListOf<RouteRequest>()
    var handler: (suspend (RouteRequest) -> RouteResult)? = null
    val broadcasts = mutableListOf<DebugEvent>()
    var serverInfo: Map<String, Any?> = emptyMap()
    var closed = false
        private set

    override suspend fun bind(port: Int): java.net.URI = java.net.URI("http://0.0.0.0:$port/")
    override fun listen(handler: suspend (RouteRequest) -> RouteResult) {
        this.handler = handler
    }
    override suspend fun serverInfo(request: Any?): Map<String, Any?> = serverInfo
    override fun broadcast(event: DebugEvent) {
        broadcasts += event
    }
    override suspend fun close() {
        closed = true
    }

    /** Drive the plane directly (bypassing the wire). */
    suspend fun dispatch(req: RouteRequest): RouteResult {
        requests += req
        return handler?.invoke(req) ?: error("no handler installed")
    }
}

/**
 * Configurable capability fake. [stateMap] is returned by state(); resource /
 * command handlers are overridable lambdas; events is a hot SharedFlow so
 * tests can emit after registration (mirrors real producer semantics).
 */
open class FakeCapability(
    override val id: String,
    private val resources: List<Resource> = emptyList(),
    private val commands: List<Command> = emptyList(),
    private val stateMap: Map<String, Any?> = emptyMap(),
) : Capability {

    private val _events = MutableSharedFlow<DebugEvent>(extraBufferCapacity = 64)
    val emitted: SharedFlow<DebugEvent> = _events.asSharedFlow()

    var onResource: suspend (Resource, RouteContext) -> Map<String, Any?> =
        { r, ctx -> mapOf("ok" to true, "resource" to r.path, "pathParams" to ctx.pathParams) }
    var onCommand: suspend (Command, RouteContext) -> Map<String, Any?> =
        { c, ctx -> mapOf("ok" to true, "command" to c.path, "body" to ctx.body) }

    override fun resources(): List<Resource> = resources
    override fun commands(): List<Command> = commands
    override fun events(): Flow<DebugEvent> = _events
    override suspend fun state(): Map<String, Any?> = stateMap

    override suspend fun handleResource(resource: Resource, context: RouteContext) = onResource(resource, context)
    override suspend fun handleCommand(command: Command, context: RouteContext) = onCommand(command, context)

    fun emit(event: DebugEvent) {
        _events.tryEmit(event)
    }
}
