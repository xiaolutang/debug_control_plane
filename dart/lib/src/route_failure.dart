/// A controlled routing failure raised by a [Capability] handler or the
/// control plane itself.
///
/// Promoted from the legacy private `_RouteFailure`. The control plane
/// catches [RouteFailure] and emits an HTTP error response with
/// `{ok:false, code, message}`. Any other exception becomes a 500
/// `internal_error`.
final class RouteFailure implements Exception {
  /// Create a routing failure.
  const RouteFailure(this.statusCode, this.code, this.message);

  /// HTTP status code to emit, e.g. 404, 409, 400.
  final int statusCode;

  /// Stable machine-readable error code, e.g. `not_found`,
  /// `real_controller_active`.
  final String code;

  /// Human-readable error message.
  final String message;

  @override
  String toString() => 'RouteFailure($statusCode, $code: $message)';
}
