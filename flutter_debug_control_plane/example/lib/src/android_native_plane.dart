import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart'
    show AuthPolicy, BridgeCapability, NativeControlPlaneBridge;

import 'acceptance_plane.dart';
import 'acceptance_plane_host.dart';

/// [PlaneHost] running the debug plane in the Android native process via
/// the plugin's [NativeControlPlaneBridge] (R002-FF003).
///
/// Ownership & mode semantics (contract decisions):
///  - Capabilities: registers the acceptance plane's fixed 4-capability set
///    as native declarations. Each register wraps the Dart [Capability] in a
///    FRESH [BridgeCapability] (single-subscription `events`, D2) and the
///    wrapped handlers stay active on the Dart side — native reverse-invokes
///    them over the channel, so the real capability HTTP behavior (including
///    request-log emission through the plane's auth manager) keeps working.
///    The Dart plane itself is never started in this mode.
///  - Request log: capability HTTP logs flow through [AcceptancePlane]'s
///    auth manager as usual; additionally the auth lifecycle observed on
///    the channel (native pending callback, approve/deny/revoke outcomes)
///    is synthesized into entries with route/statusCode/authResult fields
///    (Q2) and pushed through the same single sink.
///  - Token: `tokenPresent` is true once the last approve produced a claim
///    and no revoke happened since (Q1/Q3 semantics).
///  - `clearToken` maps onto `bridge.revokeAuthorization(all: true)`;
///    `canExpireToken` is false (PluginDebugAuth has no TTL injection API).
///  - No retry/auto-reconnect logic. A pending callback arriving after stop
///    is dropped with a synthesized log entry (no dialog churn).
class AndroidNativePlane implements PlaneHost {
  /// Creates a native host over [bridge] owning a fresh acceptance plane
  /// (capability declarations + Dart-side handlers). The plane's Dart
  /// HTTP server is never started in this mode; its log sink relays into
  /// the sink installed via [setOnRequestLog].
  AndroidNativePlane({NativeControlPlaneBridge? bridge})
      : _bridge = bridge ?? NativeControlPlaneBridge() {
    plane = AcceptancePlane(onRequestLog: (entry) => _planeSink?.call(entry));
  }

  final NativeControlPlaneBridge _bridge;

  /// R003-FB002 (contract Q1): the demo pages must attach their page
  /// capabilities to THE SAME bridge the host attached — creating a second
  /// bridge over the one channel would steal the native reverse-invoke
  /// handler. Read-only exposure; ownership stays with this plane
  /// (`stop()` still disposes it).
  NativeControlPlaneBridge get bridge => _bridge;

  @override
  late final AcceptancePlane plane;

  AcceptanceRequestLogSink? _sink;
  AcceptanceRequestLogSink? _planeSink;
  bool _planeRunning = false;
  int _logSequence = 0;

  @override
  int get capabilityCount => plane.buildCapabilities().length;

  @override
  bool get tokenPresent => _claimTokenId != null;

  String? _claimTokenId;

  @override
  void setOnRequestLog(AcceptanceRequestLogSink? sink) {
    _sink = sink;
    // Native -> Dart pending authorization callback: synthesized into a
    // pending log entry (single channel into the controller).
    _bridge.setAuthorizationHandler(sink == null
        ? null
        : (request) async {
            _emit(
              method: 'POST',
              route: '/auth/request',
              statusCode: 202,
              authResult: 'pending',
              requestId: request.requestId,
              clientLabel: request.clientLabel ?? 'unknown client',
            );
            return;
          });
    // The plane's constructor-time sink (capability handler logs) relays
    // into the same single controller entry point.
    _planeSink = sink;
  }

  /// Test-only hook: re-attach must surface the bridge's StateError
  /// (attach is not idempotent; one channel, one handler).
  void attachAgain() => _bridge.attach();

  @override
  Future<Uri?> start() async {
    _bridge.attach();
    final uri = await _bridge.start(
      address: '0.0.0.0',
      port: 0,
      appMeta: _appMeta,
      // R006 e2e 注入点（opt-in 编译常量）：--dart-define=R006_AUTH_POLICY=
      // auto|none 时声明策略；缺席/其他值 = 不传（default，字节级现状，
      // 既有宿主零感知）。仅真机验收脚本使用，产品接入面在
      // NativeControlPlaneBridge.start(authPolicy:)（见 GETTING_STARTED）。
      authPolicy: switch (const String.fromEnvironment('R006_AUTH_POLICY')) {
        'auto' => AuthPolicy.auto,
        'none' => AuthPolicy.none,
        _ => null,
      },
    );
    for (final capability in plane.buildCapabilities()) {
      // Fresh BridgeCapability per registration (D2 single-subscription).
      await _bridge.register(BridgeCapability(capability));
    }
    _planeRunning = true;
    return uri;
  }

  @override
  Future<void> stop() async {
    _bridge.setAuthorizationHandler(null);
    try {
      for (final capId in _bridge.registeredIds.toList().reversed) {
        await _bridge.unregister(capId);
      }
      await _bridge.stop();
    } finally {
      await _bridge.dispose();
      _planeRunning = false;
      _claimTokenId = null;
    }
  }

  Map<String, Object?> _appMeta() => <String, Object?>{
        'app': 'flutter-auth-acceptance-app',
        'deviceId': 'acceptance-android-device',
        'deviceName': 'Android Native Plane',
        'platform': 'android',
      };

  @override
  Future<void> approvePending(String requestId) async {
    final claim = await _bridge.approveAuthorization(requestId);
    if (claim == null) return;
    _claimTokenId = claim.tokenId;
    _emit(
      method: 'POST',
      route: '/auth/claim',
      statusCode: 200,
      authResult: 'claimed',
      requestId: requestId,
      message: claim.tokenId,
    );
  }

  @override
  Future<void> denyPending(String requestId) async {
    await _bridge.denyAuthorization(requestId);
    _emit(
      method: 'POST',
      route: '/auth/status',
      statusCode: 403,
      authResult: 'denied',
      requestId: requestId,
    );
  }

  @override
  Future<void> clearToken() async {
    await _bridge.revokeAuthorization(all: true);
    _claimTokenId = null;
    _emit(
      method: 'SYSTEM',
      route: '/auth/token',
      statusCode: 200,
      authResult: 'cleared',
    );
  }

  @override
  bool get canExpireToken => false;

  @override
  void expireToken() {
    throw UnsupportedError(
      'expire_token is disabled in native mode (PluginDebugAuth has no '
      'TTL injection API; R002-FF003 contract Q3).',
    );
  }

  void _emit({
    required String method,
    required String route,
    required int statusCode,
    required String authResult,
    String? requestId,
    String? clientLabel,
    String? message,
  }) {
    if (!_planeRunning && authResult == 'pending') {
      // Pending arriving after stop: drop (contract degradation path).
      return;
    }
    _sink?.call(AcceptanceRequestLogEntry(
      sequence: _logSequence++,
      timestamp: DateTime.now(),
      method: method,
      route: route,
      authResult: authResult,
      statusCode: statusCode,
      requestId: requestId,
      clientLabel: clientLabel,
      message: message,
    ));
  }
}
