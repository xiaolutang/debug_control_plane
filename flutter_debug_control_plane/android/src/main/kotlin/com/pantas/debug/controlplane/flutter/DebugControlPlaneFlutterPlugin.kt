package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.Command
import com.pantas.debug.controlplane.ControlPlane
import com.pantas.debug.controlplane.DebugEvent
import com.pantas.debug.controlplane.HttpSseTransport
import com.pantas.debug.controlplane.Resource
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * FF001-2: Android FlutterPlugin — the MethodChannel bridge between Dart
 * capabilities and the native Kotlin [ControlPlane] core.
 *
 * Channel: `debug_control_plane/method` (see [ChannelProtocol], FF001-1).
 *
 * Composition (design §3.2):
 *  - [NativeControlPlaneBridge]: reqId-correlated reverse invokes with the
 *    B4 30s timeout -> 500 internal_error, plus the per-capability event
 *    hot flows fed by `events.emit`.
 *  - [DartCapabilityRegistry]: Decl deserialization (path is a JSON array,
 *    PROTOCOL.md §2.3) into [BridgeCapability] instances registered on the
 *    native plane.
 *  - Plane lifecycle: the plane itself is mounted by the FF002-2 Service
 *    carrier via [PlaneCarrier.mount]; this plugin's `plane.start`/`stop`
 *    drive [ControlPlane.start]/[stop] on it. A fallback self-mount (JVM /
 *    no-carrier environments) builds an [HttpSseTransport] here.
 *
 * attach/detach pairing: [onAttachedToEngine] creates the channel + handler,
 * [onDetachedFromEngine] clears the handler, cancels the scope and unmounts
 * the fallback plane — no channel leak.
 */
class DebugControlPlaneFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var bridge: NativeControlPlaneBridge? = null
    private var registry: DartCapabilityRegistry? = null
    private var scope: CoroutineScope? = null
    private var ownsPlane = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val methodChannel = MethodChannel(binding.binaryMessenger, ChannelProtocol.METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pluginBridge = NativeControlPlaneBridge(methodChannel, pluginScope)
        channel = methodChannel
        scope = pluginScope
        bridge = pluginBridge
        registry = DartCapabilityRegistry(pluginBridge)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        registry = null
        bridge = null
        if (ownsPlane) {
            PlaneCarrier.unmount()
            ownsPlane = false
        }
        scope?.cancel()
        scope = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val pluginBridge = bridge
        val pluginRegistry = registry
        val pluginScope = scope
        if (pluginBridge == null || pluginRegistry == null || pluginScope == null) {
            result.error("not_attached", "plugin detached", null)
            return
        }
        when (call.method) {
            ChannelProtocol.PLANE_START -> {
                val address = call.argument<String>("address")
                val port = call.argument<Int>("port") ?: 0
                @Suppress("UNCHECKED_CAST")
                val appMeta = call.argument<Map<String, Any?>>("appMeta")
                pluginScope.launch {
                    try {
                        val plane = ensurePlane(pluginScope, port, appMeta)
                        // Start-once join (R026): the Kotlin core guarantees the
                        // first call really binds and later calls join the
                        // cached result/failure — a carrier plane the Service
                        // already bound is never re-bound here.
                        val uri = plane.start(port)
                        result.success(mapOf("uri" to uri?.toString()))
                    } catch (e: java.net.BindException) {
                        // FF002-3 maps this to Dart SocketException(errorCode=98)
                        // for the R024 degradation catch to reuse unchanged.
                        result.error(ChannelProtocol.ERROR_BIND_FAILED, e.message, null)
                    } catch (e: Throwable) {
                        result.error("internal_error", e.toString(), null)
                    }
                }
            }

            ChannelProtocol.PLANE_STOP -> {
                pluginScope.launch {
                    try {
                        // R026 ownership (design §1.3): only a plane this
                        // plugin mounted (fallback) is stopped+unmounted here.
                        // A Service-mounted carrier plane outlives a Dart
                        // dispose — its lifecycle belongs to the Service's
                        // onDestroy.
                        if (ownsPlane) {
                            PlaneCarrier.plane?.stop()
                            PlaneCarrier.unmount()
                            ownsPlane = false
                        }
                        result.success(null)
                    } catch (e: Throwable) {
                        result.error("internal_error", e.toString(), null)
                    }
                }
            }

            ChannelProtocol.CAPABILITY_REGISTER -> {
                val capId = call.argument<String>("capId")
                if (capId == null) {
                    result.error("invalid_request", "missing capId", null)
                    return
                }
                val decl = try {
                    parseDecl(call)
                } catch (e: IllegalArgumentException) {
                    result.error("invalid_request", e.message, null)
                    return
                }
                val plane = PlaneCarrier.plane
                if (plane == null) {
                    result.error("not_started", "plane not started", null)
                    return
                }
                try {
                    val cap = pluginRegistry.register(capId, decl)
                    plane.register(cap)
                    result.success(null)
                } catch (e: IllegalArgumentException) {
                    result.error(ChannelProtocol.ERROR_DUPLICATE, e.message, null)
                }
            }

            ChannelProtocol.CAPABILITY_UNREGISTER -> {
                val capId = call.argument<String>("capId")
                if (capId == null) {
                    result.error("invalid_request", "missing capId", null)
                    return
                }
                pluginRegistry.remove(capId)?.let { cap ->
                    PlaneCarrier.plane?.unregister(cap.id)
                    pluginBridge.teardownCapability(capId)
                }
                result.success(null)
            }

            ChannelProtocol.EVENTS_EMIT -> {
                val capId = call.argument<String>("capId")
                @Suppress("UNCHECKED_CAST")
                val event = call.argument<Map<String, Any?>>("event")
                if (capId == null || event == null) {
                    result.error("invalid_request", "missing capId/event", null)
                    return
                }
                @Suppress("UNCHECKED_CAST")
                val payload = (event["payload"] as? Map<String, Any?>) ?: emptyMap<String, Any?>()
                pluginBridge.eventFlow(capId).tryEmit(
                    DebugEvent(
                        type = event["type"] as? String ?: "unknown",
                        // Dart-side sequence is discarded (§3.1); the plane
                        // assigns the global monotonic sequence.
                        sequence = 0L,
                        payload = payload,
                    ),
                )
                result.success(null)
            }

            ChannelProtocol.CAPABILITY_STATE_UPDATE -> {
                // Accepted no-op (implementer deviation 1, kept): design
                // §3.2.4 planned a native cached-state aggregate updated by
                // this push, but the Kotlin core's Capability.state() is a
                // suspend fun — the per-cap BridgeCapability pulls live state
                // over the reverse invoke instead, so there is no cache to
                // update. The method stays in the protocol for completeness.
                result.success(null)
            }

            ChannelProtocol.CAPABILITY_INVOKE_RESULT -> {
                val reqId = call.argument<Int>("reqId")
                if (reqId == null) {
                    result.error("invalid_request", "missing reqId", null)
                    return
                }
                @Suppress("UNCHECKED_CAST")
                val payload = call.arguments as? Map<String, Any?>
                    ?: emptyMap<String, Any?>()
                if (pluginBridge.completeInvoke(reqId.toLong(), payload)) {
                    result.success(null)
                } else {
                    result.error("invalid_request", "unknown reqId $reqId", null)
                }
            }

            ChannelProtocol.CAPABILITY_STATE_RESULT -> {
                val reqId = call.argument<Int>("reqId")
                @Suppress("UNCHECKED_CAST")
                val state = call.argument<Map<String, Any?>>("state") ?: emptyMap()
                if (reqId == null) {
                    result.error("invalid_request", "missing reqId", null)
                    return
                }
                if (pluginBridge.completeState(reqId.toLong(), state)) {
                    result.success(null)
                } else {
                    result.error("invalid_request", "unknown reqId $reqId", null)
                }
            }

            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    private suspend fun ensurePlane(
        pluginScope: CoroutineScope,
        port: Int,
        appMeta: Map<String, Any?>?,
    ): ControlPlane {
        // R026 (design §1.2): a Service-mounted carrier plane is JOINED, not
        // replaced — but the Dart-side identity fields are post-injected via
        // updateAppMeta so /hello carries them (C2). A null appMeta keeps the
        // plane's existing one (a late join without identity must not wipe
        // what the Service set).
        PlaneCarrier.plane?.let {
            it.updateAppMeta(appMeta?.let { meta -> { meta } })
            return it
        }
        // Fallback self-mount (JVM / no-carrier). The Dart-requested port is
        // passed through to the transport (C4): port=0 keeps the OS-pick
        // semantics, an explicit port pins the bind.
        val transport = HttpSseTransport(pluginScope, port)
        val plane = PlaneCarrier.mount(transport, pluginScope) { appMeta ?: emptyMap() }
        ownsPlane = true
        return plane
    }

    /** Deserialize the register Decl payload (path is a JSON array, §2.3). */
    private fun parseDecl(call: MethodCall): CapabilityDecl {
        @Suppress("UNCHECKED_CAST")
        val resourcesRaw = call.argument<List<Map<String, Any?>>>("resources") ?: emptyList()
        @Suppress("UNCHECKED_CAST")
        val commandsRaw = call.argument<List<Map<String, Any?>>>("commands") ?: emptyList()
        val resources = resourcesRaw.mapIndexed { index, raw ->
            Resource(
                method = raw["method"] as? String ?: "GET",
                path = parsePath(raw["path"], "resources[$index]"),
                description = raw["description"] as? String,
            )
        }
        val commands = commandsRaw.mapIndexed { index, raw ->
            Command(
                method = raw["method"] as? String ?: "POST",
                path = parsePath(raw["path"], "commands[$index]"),
                description = raw["description"] as? String,
            )
        }
        return CapabilityDecl(resources, commands)
    }

    private fun parsePath(raw: Any?, where: String): List<String> {
        if (raw is List<*>) {
            return raw.map { it?.toString() ?: throw IllegalArgumentException("$where path segment null") }
        }
        throw IllegalArgumentException(
            "$where.path must be a JSON array of strings (PROTOCOL.md §2.3), got: $raw",
        )
    }
}
