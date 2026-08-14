package com.pantas.debug.controlplane

/**
 * Path matcher aligned byte-for-byte with Dart `ControlPlane._matchPath`
 * (control_plane.dart L294-311).
 *
 * Contract:
 *  - Flat, prefix-less routing (declaration segments compared 1:1 with actual segments).
 *  - Segment counts MUST be equal.
 *  - A `{name}` segment (single-segment placeholder, curly-brace delimited) captures
 *    the actual segment value into [pathParams].
 *  - Otherwise the declaration segment must equal the actual segment literally.
 *
 * This is a pure function — no HTTP coupling — so it can be unit-tested directly and
 * reused by any transport (NanoHTTPD now, future Ktor/Netty later).
 */
object RoutePath {
    /**
     * @return true if [actual] matches [declaration]; on match, captures are written
     *         into [pathParams] (caller-owned, mutated in place, matching Dart semantics).
     */
    fun match(
        declaration: List<String>,
        actual: List<String>,
        pathParams: MutableMap<String, String>,
    ): Boolean {
        if (declaration.size != actual.size) return false
        for (i in declaration.indices) {
            val decl = declaration[i]
            val act = actual[i]
            if (decl.startsWith("{") && decl.endsWith("}")) {
                val name = decl.substring(1, decl.length - 1)
                pathParams[name] = act
            } else if (decl != act) {
                return false
            }
        }
        return true
    }

    /** Convenience: split a declaration string like `/profiles/{id}` into segments. */
    fun segments(declaration: String): List<String> =
        declaration.trim('/').split('/').filter { it.isNotEmpty() }
}
