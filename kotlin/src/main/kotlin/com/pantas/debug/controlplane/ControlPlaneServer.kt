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

    /**
     * Create a [ControlPlane] bound to a fresh [HttpSseTransport].
     *
     * [port] fixes the transport's constructor port (0 = OS-picked on bind).
     * Passing a non-zero [port] pins the bind port — used by Main.kt's JVM
     * smoke (BF003-2 Python cross-verification) so a chosen port like 18099
     * can be probed, and later by FF002-2's Android Service (18080).
     */
    fun create(
        scope: CoroutineScope,
        appMeta: (suspend () -> Map<String, Any?>)? = null,
        port: Int = 0,
        authManager: DebugAuthManager? = null,
    ): Pair<ControlPlane, HttpSseTransport> {
        val transport = HttpSseTransport(scope, port)
        val plane = ControlPlane(
            transport = transport,
            scope = scope,
            appMeta = appMeta,
            authManager = authManager,
        )
        return plane to transport
    }
}
