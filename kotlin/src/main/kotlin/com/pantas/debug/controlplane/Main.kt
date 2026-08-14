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

/** Neutral demo capability (no business semantics) for the JVM smoke main. */
private object DemoCapability : Capability {
    override val id: String = "demo"
    override fun resources(): List<Resource> = listOf(
        Resource(method = "GET", path = listOf("items"), description = "demo items"),
    )
    override fun commands(): List<Command> = listOf(
        Command(method = "POST", path = listOf("invoke")),
    )
    override suspend fun handleResource(resource: Resource, context: RouteContext): Map<String, Any?> =
        mapOf("ok" to true, "resource" to resource.path)
    override suspend fun handleCommand(command: Command, context: RouteContext): Map<String, Any?> =
        mapOf("ok" to true, "command" to command.path, "body" to context.body)
    override fun events(): kotlinx.coroutines.flow.Flow<DebugEvent> =
        kotlinx.coroutines.flow.emptyFlow()
    override suspend fun state(): Map<String, Any?> = mapOf("demoKey" to "demoValue")
}
