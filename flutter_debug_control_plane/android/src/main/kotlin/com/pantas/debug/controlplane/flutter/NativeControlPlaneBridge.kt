package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.ControlPlane
import com.pantas.debug.controlplane.DebugEvent
import com.pantas.debug.controlplane.HttpSseTransport
import com.pantas.debug.controlplane.RouteContext
import com.pantas.debug.controlplane.RouteFailure
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicLong

/**
 * FF001-2: reverse-invoke machinery — the native side of the Dart handlers.
 *
 * MethodChannel reverse invokes (native -> Dart):
 *  - `capability.invoke` `{reqId, capId, routeKind, routeIndex, pathParams,
 *    body}` — Dart runs the handler and fills `capability.invoke.result`.
 *  - `capability.state.pull` `{reqId, capId}` — Dart fills
 *    `capability.state.result`.
 *
 * reqId correlation: every reverse call registers a [CompletableDeferred]
 * (capId-tagged, see [OwnedDeferred]) in [pending] before invoking; the Dart
 * fill-in completes it. B4 timeout:
 * no fill-in within [ChannelProtocol.INVOKE_TIMEOUT_MS] (30s) resolves as a
 * 500 `internal_error` [RouteFailure].
 *
 * `events.emit` frames land in [eventFlows] — one [MutableSharedFlow] per
 * capId, feeding the matching [BridgeCapability.events] (the plane collects
 * it once and assigns the global sequence; Dart-side sequences are
 * discarded, PROTOCOL.md §3.1).
 *
 * Injectable [channel] + [scope] + [mainExecutor] keep this
 * JVM-unit-testable with a fake channel (no io.flutter engine).
 *
 * Threading (R026 e2e fix): Flutter requires native->Dart `invokeMethod` to
 * run on the Android main thread — real-device /hello hit
 * "Methods marked with @UiThread must be executed on the main thread" when
 * reverseInvoke ran it on the NanoHTTPD request processor. The post is now
 * dispatched through [mainExecutor] (production: the plugin injects a
 * main-looper Handler executor; JVM tests default to a direct passthrough,
 * preserving the fake-channel testability above). The `pending[reqId]`
 * registration happens BEFORE the post so a fast Dart fill-in never races
 * the registration.
 *
 * Wire types (R026 e2e defect #2): `RouteContext.body` can carry
 * org.json JSONObject/JSONArray (the Kotlin core parses POST bodies with
 * org.json). `StandardMessageCodec` rejects those with a FATAL
 * IllegalArgumentException, so args are converted to codec-safe plain
 * types at this outgoing boundary (see FlutterWire.kt); the Kotlin core
 * stays Flutter-agnostic and Dart sees the same plain Map/List shapes as
 * on iOS/macOS.
 */
open class NativeControlPlaneBridge(
    private val channel: MethodChannel,
    private val scope: CoroutineScope,
    /** Executor that must run the reverse `invokeMethod` (main thread in production). */
    private val mainExecutor: Executor = Executor { it.run() },
) : DartReverseInvoker {

    /** In-flight reverse invokes, keyed by reqId. */
    val pending = ConcurrentHashMap<Long, OwnedDeferred>()

    /** Per-capability hot event flows (Dart -> native upstream). */
    val eventFlows = ConcurrentHashMap<String, MutableSharedFlow<DebugEvent>>()

    /** Monotonic reqId allocator (starts at 1; 0 is never a valid reqId). */
    private val nextReqId = AtomicLong(1)

    /** Reverse-invoke timeout override for tests (default 30s, B4). */
    var invokeTimeoutMs: Long = ChannelProtocol.INVOKE_TIMEOUT_MS

    override fun eventFlow(capId: String): MutableSharedFlow<DebugEvent> =
        eventFlows.getOrPut(capId) {
            MutableSharedFlow(extraBufferCapacity = 64)
        }

    /** Drop a capability's event flow + fail **its own** pending invokes (unregister path). */
    fun teardownCapability(capId: String) {
        eventFlows.remove(capId)
        // Only the invokes belonging to [capId] fail — killing every pending
        // entry here would also abort in-flight reverse invokes of unrelated
        // capabilities. The plane's error funnel maps these to 500.
        val doomed = pending.entries.filter { it.value.ownerCapId == capId }
        doomed.forEach { (reqId, deferred) ->
            if (pending.remove(reqId, deferred) && !deferred.isCompleted) {
                deferred.completeExceptionally(
                    RouteFailure(500, "internal_error", "capability $capId torn down"),
                )
            }
        }
    }

    // -------------------------------------------------------------------------
    // Reverse invoke: handler
    // -------------------------------------------------------------------------

    override suspend fun invokeHandler(
        capId: String,
        routeKind: String,
        routeIndex: Int,
        context: RouteContext,
    ): Map<String, Any?> = reverseInvoke(
        ChannelProtocol.CAPABILITY_INVOKE,
        mapOf(
            "capId" to capId,
            "routeKind" to routeKind,
            "routeIndex" to routeIndex,
            "pathParams" to context.pathParams,
            "body" to context.body,
        ),
    )

    // -------------------------------------------------------------------------
    // Reverse invoke: state pull (rare — Dart pushes eagerly, §3.2.4)
    // -------------------------------------------------------------------------

    override suspend fun pullState(capId: String): Map<String, Any?> = reverseInvoke(
        ChannelProtocol.CAPABILITY_STATE_PULL,
        mapOf("capId" to capId),
    )

    private suspend fun reverseInvoke(method: String, args: Map<String, Any?>): Map<String, Any?> {
        val reqId = nextReqId.getAndIncrement()
        val capId = args["capId"] as? String ?: ""
        val deferred = OwnedDeferred(capId)
        // Register BEFORE the post: a fill-in racing back on the main thread
        // must already find its reqId here (never "unknown reqId").
        pending[reqId] = deferred
        val callback = object : MethodChannel.Result {
            override fun success(result: Any?) {
                // Dart replies null to the reverse call itself; the
                // payload arrives via capability.*.result fill-ins.
                // A non-null reply (error envelope) completes the waiter.
                if (result is Map<*, *> && result.containsKey("error") && !deferred.isCompleted) {
                    deferred.completeExceptionally(result["error"].asRouteFailure())
                }
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                if (!deferred.isCompleted) {
                    deferred.completeExceptionally(
                        RouteFailure(500, "internal_error", "channel error: $errorCode $errorMessage"),
                    )
                }
            }

            override fun notImplemented() {
                if (!deferred.isCompleted) {
                    deferred.completeExceptionally(
                        RouteFailure(500, "internal_error", "method $method not implemented"),
                    )
                }
            }
        }
        // Flutter: reverse invokeMethod is @UiThread — hop to the main
        // executor instead of running on the caller (NanoHTTPD worker / IO
        // coroutine). The timeout below still governs the whole exchange.
        // R026 e2e defect #2: RouteContext.body may carry org.json values
        // (the Kotlin core parses POST bodies with org.json) — the codec
        // rejects them with IllegalArgumentException (FATAL). Convert to
        // codec-safe plain types at this outgoing boundary (FlutterWire.kt).
        val wireArgs = args.toFlutterWire()
        return try {
            // Inside the try/finally so an executor rejection (rejected/closed
            // executor) still drops the pending entry — otherwise it would sit
            // there until the 30s timeout sweep that never fires for it.
            mainExecutor.execute {
                channel.invokeMethod(method, mapOf("reqId" to reqId) + wireArgs, callback)
            }
            withTimeout(invokeTimeoutMs) { deferred.await() }
        } catch (e: TimeoutCancellationException) {
            // B4: 30s no fill-in -> 500 internal_error.
            throw RouteFailure(500, "internal_error", "reverse invoke timed out after ${invokeTimeoutMs}ms")
        } finally {
            pending.remove(reqId)
        }
    }

    // -------------------------------------------------------------------------
    // Dart fill-ins (called from the plugin's onMethodCall)
    // -------------------------------------------------------------------------

    /** `capability.invoke.result` `{reqId, result | error}`. */
    fun completeInvoke(reqId: Long, payload: Map<String, Any?>): Boolean {
        val deferred = pending.remove(reqId) ?: return false
        val error = payload["error"]
        return if (error != null) {
            deferred.completeExceptionally(error.asRouteFailure())
        } else {
            @Suppress("UNCHECKED_CAST")
            deferred.complete(payload["result"] as? Map<String, Any?> ?: emptyMap())
        }
    }

    /** `capability.state.result` `{reqId, state}`. */
    fun completeState(reqId: Long, state: Map<String, Any?>): Boolean {
        val deferred = pending.remove(reqId) ?: return false
        return deferred.complete(state)
    }
}

/**
 * Pending reverse invoke tagged with its owning capId, so
 * [NativeControlPlaneBridge.teardownCapability] only fails the invokes that
 * belong to the unregistered capability (previously it killed every entry).
 */
class OwnedDeferred(
    /** The capId the reverse invoke was issued for ("" for unknown). */
    val ownerCapId: String,
) : CompletableDeferred<Map<String, Any?>> by CompletableDeferred()

/**
 * Decode an error envelope `{statusCode, code, message}` (the single
 * construction site of RouteFailure from channel payloads — previously two
 * near-identical copies in reverseInvoke/completeInvoke).
 */
private fun Any?.asRouteFailure(): RouteFailure {
    val err = this as? Map<*, *> ?: emptyMap<Any?, Any?>()
    return RouteFailure(
        (err["statusCode"] as? Number)?.toInt() ?: 500,
        (err["code"] as? String) ?: "internal_error",
        (err["message"] as? String) ?: "unknown error",
    )
}

/**
 * Reverse-invoke surface consumed by [DartCapabilityRegistry] /
 * [BridgeCapability] (kept interface-typed so the registry stays testable
 * without io.flutter).
 */
interface DartReverseInvoker {
    /** The per-capability hot event flow fed by `events.emit`. */
    fun eventFlow(capId: String): MutableSharedFlow<DebugEvent>

    /** Reverse-invoke a Dart resource/command handler by routeIndex. */
    suspend fun invokeHandler(
        capId: String,
        routeKind: String,
        routeIndex: Int,
        context: RouteContext,
    ): Map<String, Any?>

    /** Reverse-invoke a Dart state pull (rare fallback, §3.2.4). */
    suspend fun pullState(capId: String): Map<String, Any?>
}

/**
 * FF001-2: server carrier entry point.
 *
 * The plugin does NOT auto-start the plane on engine attach — per design
 * S5/S3 the carrier is FF002-2's foreground Service. This function wires a
 * [ControlPlane] with an [HttpSseTransport] and mounts the given [plane]
 * instance into the process-wide [PlaneCarrier] so the plugin's
 * `plane.start` / `capability.register` calls reach it. Callers own the
 * [scope] lifecycle (cancel on service destroy).
 */
object PlaneCarrier {
    @Volatile
    var plane: ControlPlane? = null

    /** Wire + expose a plane (returns it unstarted; `plane.start` starts it). */
    fun mount(
        transport: com.pantas.debug.controlplane.Transport,
        scope: CoroutineScope,
        appMeta: (suspend () -> Map<String, Any?>)? = null,
    ): ControlPlane {
        val plane = ControlPlane(transport, scope, appMeta)
        this.plane = plane
        return plane
    }

    /** Drop the mounted plane (service destroy path). */
    fun unmount() {
        plane = null
    }
}
