package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch

/**
 * SharedFlow event bus — Kotlin counterpart of the Dart plane's broadcast
 * `StreamController<DebugEvent>` (decision D5, PROTOCOL.md §3.1).
 *
 * Semantics aligned with Dart broadcast semantics:
 *  - `replay = 0`: a new subscriber never sees events emitted before it
 *    subscribed (Dart broadcast streams are likewise no-replay).
 *  - `extraBufferCapacity = 64` + `DROP_OLDEST`: slow subscribers never
 *    block the producer (`emit` is non-suspending, best-effort) — matches
 *    Dart's unbounded broadcast controller where emitters never await.
 *  - Multiple independent collectors: every active subscriber receives every
 *    event (fan-out), cancelling one does not affect the others.
 *
 * The [CoroutineScope] is injected by the caller (FF002-2's Service carrier
 * owns the lifecycle); the bus never creates its own scope.
 *
 * D2 note: this class is the *consumer side* of hot sources —
 * [ControlPlane.register] collects each capability's `events()` flow into
 * the bus. FF001's BridgeCapability is the *producer side* (callbackFlow /
 * single-subscription contract lives there).
 */
class EventBus {

    private val _flow = MutableSharedFlow<DebugEvent>(
        replay = 0,
        extraBufferCapacity = DEFAULT_BUFFER_CAPACITY,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Read-only hot stream for transports / introspection. */
    val shared: SharedFlow<DebugEvent> = _flow.asSharedFlow()

    /** Non-suspending, best-effort emit (never blocks the caller). */
    fun emit(event: DebugEvent) {
        _flow.tryEmit(event)
    }

    /**
     * Bridge the bus onto a transport: collect [shared] once and forward to
     * [transport.broadcast]. Returns the collector [Job] so the owner scope
     * can cancel it (transport close path).
     */
    fun pipeTo(scope: CoroutineScope, transport: Transport): Job =
        scope.launch {
            shared.collect { transport.broadcast(it) }
        }

    companion object {
        const val DEFAULT_BUFFER_CAPACITY = 64
    }
}
