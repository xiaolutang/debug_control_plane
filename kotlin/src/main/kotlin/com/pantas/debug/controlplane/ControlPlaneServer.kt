package com.pantas.debug.controlplane

import kotlinx.coroutines.CoroutineScope

/**
 * Convenience facade: wire [HttpSseTransport] + [ControlPlane] together in
 * one call (Dart apps do this at the runtime assembly site; FF002-2's
 * Service carrier does it on Android).
 *
 * NOTE: the spike-a standalone `ControlPlaneServer` (flat route list, echo
 * hello) was superseded by the production [ControlPlane] + [HttpSseTransport]
 * split in BF002-2/BF002-3; the spike's SSE mechanism, path matcher and
 * tests were migrated (see HttpSseTransport / RoutePath).
 *
 * R1 note: package name `com.pantas.debug.controlplane` is carried over from
 * the spike-a skeleton; design's `com.xlfoundry.*` was illustrative only.
 */
object ControlPlaneServer {

    /** Create a [ControlPlane] bound to a fresh [HttpSseTransport]. */
    fun create(
        scope: CoroutineScope,
        appMeta: (suspend () -> Map<String, Any?>)? = null,
    ): Pair<ControlPlane, HttpSseTransport> {
        val transport = HttpSseTransport(scope)
        val plane = ControlPlane(transport = transport, scope = scope, appMeta = appMeta)
        return plane to transport
    }
}
