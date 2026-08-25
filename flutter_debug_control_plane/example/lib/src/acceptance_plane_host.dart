import 'acceptance_plane.dart';

/// Minimal plane-host abstraction consumed by [AcceptanceController]
/// (R002-FF003 contract option a).
///
/// Two implementations:
///  - [DartPlaneHost]: thin wrapper around the existing [AcceptancePlane]
///    (FB001/BF006 behavior, zero regression);
///  - `AndroidNativePlane`: orchestrates the plugin/native bridge.
///
/// The controller must not branch on the running mode; every mode difference
/// (pending notification, token semantics, expire support) is encapsulated
/// here. Pending authorization is communicated exclusively through
/// [AcceptanceRequestLogEntry]s pushed into the request-log sink
/// (`authResult: 'pending'`, `route: '/auth/request'`) — the same single
/// entry point the controller already uses for the Dart plane.
abstract class PlaneHost {
  /// The acceptance plane providing the fixed 4-capability set
  /// (`buildCapabilities()`). Native mode uses it only as the capability
  /// declaration source; its Dart auth manager stays idle there.
  AcceptancePlane get plane;

  /// Starts the plane and returns the bound endpoint Uri (null when the
  /// transport is connection-less).
  Future<Uri?> start();

  /// Stops the plane and releases registrations.
  Future<void> stop();

  /// Number of capabilities the host registers (both modes: 4).
  int get capabilityCount;

  /// Installs (or clears) the request-log sink. Every log entry — including
  /// the native-mode synthesized auth lifecycle entries — must flow through
  /// this single channel into the controller.
  void setOnRequestLog(AcceptanceRequestLogSink? sink);

  /// Approves the pending authorization request with [requestId].
  Future<void> approvePending(String requestId);

  /// Denies the pending authorization request with [requestId].
  Future<void> denyPending(String requestId);

  /// Whether a token is currently present.
  ///
  /// Native mode: true once the last approve produced a claim and no revoke
  /// happened since. Dart mode: delegates to the plane auth manager.
  bool get tokenPresent;

  /// Clears the issued token(s).
  ///
  /// Native mode maps this onto `revokeAuthorization(all: true)` (Q3).
  Future<void> clearToken();

  /// Whether the expire-token control is available in this mode.
  ///
  /// Native mode: false (PluginDebugAuth has no TTL injection API, Q3).
  bool get canExpireToken;

  /// Expires the active token (Dart mode only; unsupported in native mode).
  void expireToken();
}

/// Thin [PlaneHost] adapter over the existing [AcceptancePlane].
///
/// Pure delegation: the six-state controller semantics of FB001 are driven
/// by the plane's request-log entries exactly as before.
class DartPlaneHost implements PlaneHost {
  /// Creates a host owning a fresh plane whose log entries relay to the
  /// sink installed via [setOnRequestLog].
  DartPlaneHost() {
    plane = AcceptancePlane(onRequestLog: (entry) => _sink?.call(entry));
  }

  AcceptanceRequestLogSink? _sink;

  @override
  late final AcceptancePlane plane;

  @override
  Future<Uri?> start() => plane.startDartPlane();

  @override
  Future<void> stop() => plane.stop();

  @override
  int get capabilityCount => plane.buildCapabilities().length;

  @override
  void setOnRequestLog(AcceptanceRequestLogSink? sink) {
    _sink = sink;
  }

  @override
  Future<void> approvePending(String requestId) =>
      plane.authManager.approvePending(requestId);

  @override
  Future<void> denyPending(String requestId) =>
      plane.authManager.denyPending(requestId);

  @override
  bool get tokenPresent => plane.authManager.tokenPresent;

  @override
  Future<void> clearToken() async {
    plane.authManager.clearToken();
  }

  @override
  bool get canExpireToken => true;

  @override
  void expireToken() => plane.authManager.expireToken();
}
