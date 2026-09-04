package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.CapabilityScope
import com.pantas.debug.controlplane.CapabilityScopeType
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
    private var authStore: PluginDebugAuthStore = processAuthStore
    private var authManager: PluginDebugAuthManager? = null
    private var scope: CoroutineScope? = null
    private var ownsPlane = false
    private var authUpgraded = false

    companion object {
        private var processAuthStore: PluginDebugAuthStore = InMemoryPluginDebugAuthStore()

        /**
         * R004-FF001: lazily upgrade the process store to a FileBacked one.
         * Returns the current store unchanged unless it is still the untouched
         * initial InMemory working set (host injection via
         * [setAuthStoreForHost] or a prior upgrade disables the upgrade).
         */
        @Synchronized
        private fun upgradeProcessStore(context: android.content.Context): PluginDebugAuthStore {
            val current = processAuthStore
            if (current !is InMemoryPluginDebugAuthStore) return current
            val upgraded = FileBackedPluginDebugAuthStore(context, current)
            processAuthStore = upgraded
            return upgraded
        }
    }

    /** Host/test injection point. The default process store is used otherwise. */
    fun setAuthStoreForHost(store: PluginDebugAuthStore) {
        authStore = store
        authUpgraded = true
        val pluginBridge = bridge
        if (pluginBridge != null) {
            authManager = PluginDebugAuthManager(pluginBridge, authStore)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // R004-FF001 (design §3.1, plan A lazy upgrade): the first attach that
        // finds the process store still untouched (initial InMemory, no host
        // injection) swaps in a FileBacked decorator over the same working
        // set — tokens survive app restarts (overlay-install keeps filesDir),
        // pending stays memory-only. Idempotent: subsequent attaches and
        // post-injection attaches keep the current store.
        if (!authUpgraded) {
            authStore = upgradeProcessStore(binding.applicationContext)
            authUpgraded = true
            // Zero-copy migration: the FileBacked store wraps the pre-upgrade
            // InMemory working set as its delegate — flush it to disk once.
            (authStore as? FileBackedPluginDebugAuthStore)?.persistNow()
        } else {
            authStore = processAuthStore
        }
        val methodChannel = MethodChannel(binding.binaryMessenger, ChannelProtocol.METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        // Reverse invokeMethod is @UiThread — route it through the main
        // looper (R026 e2e: NanoHTTPD workers crashed with
        // "must be executed on the main thread").
        val pluginBridge = NativeControlPlaneBridge(
            methodChannel,
            pluginScope,
            java.util.concurrent.Executor { command ->
                android.os.Handler(android.os.Looper.getMainLooper()).post(command)
            },
        )
        channel = methodChannel
        scope = pluginScope
        bridge = pluginBridge
        authManager = PluginDebugAuthManager(pluginBridge, authStore)
        registry = DartCapabilityRegistry(pluginBridge)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        registry = null
        bridge = null
        authManager = null
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
        val pluginAuth = authManager
        val pluginScope = scope
        if (pluginBridge == null || pluginRegistry == null || pluginAuth == null || pluginScope == null) {
            result.error("not_attached", "plugin detached", null)
            return
        }
        when (call.method) {
            ChannelProtocol.PLANE_START -> {
                val address = call.argument<String>("address")
                val port = call.argument<Int>("port") ?: 0
                @Suppress("UNCHECKED_CAST")
                val appMeta = call.argument<Map<String, Any?>>("appMeta")
                // R006: optional authPolicy. Absent keeps the default policy
                // (byte-compatible with 0.5.1); an unknown value fails fast
                // BEFORE the plane is started — no silent fallback (D5).
                val authPolicy = call.argument<String>(ChannelProtocol.AUTH_POLICY)
                    ?: ChannelProtocol.AUTH_POLICY_DEFAULT
                if (authPolicy !in ChannelProtocol.AUTH_POLICY_VALUES) {
                    result.error(
                        ChannelProtocol.ERROR_INVALID_ARGUMENTS,
                        "unknown authPolicy: $authPolicy",
                        null,
                    )
                    return
                }
                pluginScope.launch {
                    try {
                        val plane = ensurePlane(pluginScope, port, appMeta, authPolicy)
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
                    val cap = pluginRegistry.register(capId, decl, decl.scope)
                    plane.register(cap) // derives ScopedCapabilityKey from cap.scope (BF005)
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
                // KD-3: scope/pageId default to app-only — a legacy
                // unregister(id) never touches page entries sharing the capId.
                val scope = try {
                    parseScope(call)
                } catch (e: IllegalArgumentException) {
                    result.error("invalid_request", e.message, null)
                    return
                }
                val identity = identityOf(scope, capId)
                pluginRegistry.remove(scope, capId)?.let { cap ->
                    PlaneCarrier.plane?.unregisterScoped(cap.scope, cap.id)
                    pluginBridge.teardownCapability(identity)
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
                // KD-3: explicit scope/pageId selects the scoped key directly;
                // omitted fields mirror FF001 Dart `_scopeFor` — the app entry
                // for capId wins, falling back to its first registered key.
                val hasExplicitScope =
                    call.argument<Any?>("scope") != null || call.argument<Any?>("pageId") != null
                val target = if (!hasExplicitScope) {
                    pluginRegistry.resolveEmitTarget(capId)
                } else {
                    try {
                        identityOf(parseScope(call), capId)
                    } catch (e: IllegalArgumentException) {
                        result.error("invalid_request", e.message, null)
                        return
                    }
                }
                // M3: an unregistered scoped key must not getOrPut a permanent
                // flow entry (unbounded eventFlows growth) — reject instead.
                val flow = pluginBridge.registeredEventFlow(target)
                if (flow == null) {
                    result.error("not_started", "capability $target not registered", null)
                    return
                }
                flow.tryEmit(
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

            ChannelProtocol.AUTH_APPROVE -> {
                val requestId = call.argument<String>("requestId")
                if (requestId == null) {
                    result.error("invalid_request", "missing requestId", null)
                    return
                }
                try {
                    result.success(
                        pluginAuth.approve(
                            requestId,
                            call.argument<Int>("ttlSeconds"),
                            call.argument<String>("clientLabel"),
                        ),
                    )
                } catch (e: IllegalArgumentException) {
                    result.error("invalid_request", e.message, null)
                }
            }

            ChannelProtocol.AUTH_DENY -> {
                val requestId = call.argument<String>("requestId")
                if (requestId == null) {
                    result.error("invalid_request", "missing requestId", null)
                    return
                }
                try {
                    pluginAuth.deny(requestId, call.argument<String>("reason"))
                    result.success(null)
                } catch (e: IllegalArgumentException) {
                    result.error("invalid_request", e.message, null)
                }
            }

            ChannelProtocol.AUTH_REVOKE -> {
                try {
                    pluginAuth.revoke(
                        call.argument<String>("tokenId"),
                        call.argument<Boolean>("all") ?: false,
                    )
                    result.success(null)
                } catch (e: IllegalArgumentException) {
                    result.error("invalid_request", e.message, null)
                }
            }

            ChannelProtocol.AUTH_STATUS -> {
                result.success(pluginAuth.status(call.argument<String>("requestId")))
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
        authPolicy: String,
    ): ControlPlane {
        // R026 (design §1.2): a Service-mounted carrier plane is JOINED, not
        // replaced — but the Dart-side identity fields are post-injected via
        // updateAppMeta so /hello carries them (C2). A null appMeta keeps the
        // plane's existing one (a late join without identity must not wipe
        // what the Service set).
        // R006: the policy of an already-mounted plane is immutable — a JOIN
        // never rebuilds its auth manager (start-time assembly semantics).
        PlaneCarrier.plane?.let {
            it.updateAppMeta(appMeta?.let { meta -> { meta } })
            return it
        }
        // Fallback self-mount (JVM / no-carrier). The Dart-requested port is
        // passed through to the transport (C4): port=0 keeps the OS-pick
        // semantics, an explicit port pins the bind.
        // R006 (design §4.2): three-policy assembly. `default` keeps the
        // attach-time authManager; `auto` rebuilds it over the same bridge/
        // store with autoApprove=true; `none` mounts with no auth gate.
        val manager = when (authPolicy) {
            ChannelProtocol.AUTH_POLICY_NONE -> null
            ChannelProtocol.AUTH_POLICY_AUTO -> {
                val pluginBridge = bridge
                    ?: throw IllegalStateException("bridge not attached for authPolicy=auto")
                PluginDebugAuthManager(pluginBridge, authStore, autoApprove = true)
            }
            else -> authManager
        }
        val transport = HttpSseTransport(pluginScope, port)
        val plane = PlaneCarrier.mount(transport, pluginScope, manager) { appMeta ?: emptyMap() }
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
        return CapabilityDecl(resources, commands, parseScope(call, validatePageId = true))
    }

    /**
     * KD-2: parse the optional `scope`/`pageId` channel fields. Missing
     * `scope` defaults to app (legacy Dart versions / hand-built payloads);
     * unknown wire values and page scopes without a non-blank pageId throw
     * IAE (mapped to `invalid_request` upstream). `pageName` is display
     * metadata only — never part of the identity.
     */
    private fun parseScope(call: MethodCall, validatePageId: Boolean = true): CapabilityScope {
        val rawScope = call.argument<Any?>("scope")
        val type = if (rawScope == null) {
            CapabilityScopeType.APP
        } else {
            CapabilityScopeType.fromWire(rawScope as String)
        }
        val pageId = call.argument<String>("pageId")?.trim()?.takeIf { it.isNotEmpty() }
        if (validatePageId && type == CapabilityScopeType.PAGE && pageId == null) {
            throw IllegalArgumentException("scope=page requires a non-blank pageId")
        }
        return when (type) {
            CapabilityScopeType.APP -> CapabilityScope.app()
            CapabilityScopeType.PAGE ->
                CapabilityScope.page(
                    pageId = pageId,
                    pageName = call.argument<String>("pageName"),
                )
        }
    }

    private fun identityOf(
        scope: CapabilityScope,
        capId: String,
    ): BridgeCapabilityIdentity = BridgeCapabilityIdentity(scope.type, scope.pageId, capId)

    private fun parsePath(raw: Any?, where: String): List<String> {
        if (raw is List<*>) {
            return raw.map { it?.toString() ?: throw IllegalArgumentException("$where path segment null") }
        }
        throw IllegalArgumentException(
            "$where.path must be a JSON array of strings (PROTOCOL.md §2.3), got: $raw",
        )
    }
}
