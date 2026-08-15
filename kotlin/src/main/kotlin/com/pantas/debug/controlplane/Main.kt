package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking

/**
 * JVM smoke main: boot the Kotlin control plane on a port (default 18080,
 * the discovery contract port) with one demo capability. Useful for
 * BF003-2's Python cross-language verification (JVM mode) and manual curl.
 *
 * Not shipped to Android — production wiring lives in FF002-2's Service.
 */
fun main(args: Array<String>) {
    val port = args.firstOrNull()?.toIntOrNull() ?: 18080
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val (plane, transport) = ControlPlaneServer.create(
        scope = scope,
        // Pin the requested port (BF003-2: Python cross-verification probes a
        // fixed port; HttpSseTransport binds its constructor port verbatim).
        port = port,
        appMeta = {
            mapOf(
                "app" to "kotlin-smoke",
                "deviceId" to "kotlin-jvm",
                "deviceName" to "Kotlin JVM smoke",
                "platform" to "jvm",
            )
        },
    )
    plane.register(DemoCapability)
    val uri = runBlocking { plane.start(port) }
    println("[debug-control-plane] listening on $uri (pid=${ProcessHandle.current().pid()})")
    println("[debug-control-plane] try: curl $uri/hello ; curl $uri/state ; curl -N $uri/events")
    Runtime.getRuntime().addShutdownHook(Thread {
        runBlocking { plane.stop() }
    })
    // Keep the process alive until interrupted.
    Thread.currentThread().join()
}

/**
 * Neutral demo capability (no business semantics) for the JVM smoke main.
 *
 * `POST /emit` exists so BF003-2's Python cross-verification can observe a
 * REAL SSE event frame (`event:/data:` per PROTOCOL.md §3.3) without any
 * business producer: it pushes one event into the capability's hot flow,
 * the plane assigns the sequence and broadcasts to all `/events` subscribers.
 */
private object DemoCapability : Capability {
    private val events = kotlinx.coroutines.flow.MutableSharedFlow<DebugEvent>(extraBufferCapacity = 64)

    override val id: String = "demo"
    override fun resources(): List<Resource> = listOf(
        Resource(method = "GET", path = listOf("items"), description = "demo items"),
    )
    override fun commands(): List<Command> = listOf(
        Command(method = "POST", path = listOf("invoke")),
        Command(method = "POST", path = listOf("emit"), description = "emit one demo SSE event"),
    )
    override suspend fun handleResource(resource: Resource, context: RouteContext): Map<String, Any?> =
        mapOf("ok" to true, "resource" to resource.path)
    override suspend fun handleCommand(command: Command, context: RouteContext): Map<String, Any?> {
        if (command.path == listOf("emit")) {
            val type = (context.body["type"] as? String) ?: "demo_event"
            events.emit(DebugEvent(type = type, payload = mapOf("aKey1" to "value1")))
            return mapOf("ok" to true, "emitted" to type)
        }
        return mapOf("ok" to true, "command" to command.path, "body" to context.body)
    }
    override fun events(): kotlinx.coroutines.flow.Flow<DebugEvent> = events
    override suspend fun state(): Map<String, Any?> = mapOf("demoKey" to "demoValue")
}
