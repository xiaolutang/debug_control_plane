package com.pantas.debug.controlplane

/**
 * A controlled routing failure raised by a [Capability] handler or the
 * control plane itself — Kotlin mirror of Dart `route_failure.dart`.
 *
 * NOTE (deviation from tasks.md sketch): the sketch proposed a sealed
 * NotFound/BadRequest/HandlerError hierarchy, but PROTOCOL.md §4.2 requires
 * open statusCode/code/message so business capabilities can raise custom
 * errors (e.g. 409 `real_controller_active`). The exception form matches the
 * protocol truth source; convenience constructors below cover the framework
 * built-ins.
 */
class RouteFailure(
    /** HTTP status code to emit, e.g. 404, 409, 400. */
    val statusCode: Int,
    /** Stable machine-readable error code, e.g. `not_found`. */
    val code: String,
    message: String,
) : Exception(message) {

    override fun toString(): String = "RouteFailure($statusCode, $code: $message)"

    companion object {
        /** Framework built-in: 404 `not_found` (PROTOCOL.md §4.2). */
        fun notFound(message: String = "Endpoint was not found."): RouteFailure =
            RouteFailure(404, "not_found", message)

        /** Framework built-in: 400 `invalid_request`. */
        fun badRequest(message: String): RouteFailure =
            RouteFailure(400, "invalid_request", message)
    }
}
