import 'dart:async';

import 'package:debug_control_plane/debug_control_plane.dart';
import 'package:flutter/foundation.dart';

import 'acceptance_plane.dart';

/// UI-layer six-state auth state for the acceptance app.
///
/// Distinct from BF006 wire enum [AcceptanceAuthStatus] (pending/approved/
/// denied); this controller maps wire/log events into these UI states.
enum AcceptanceAuthState { idle, pending, approved, denied, expired, cleared }

enum AcceptancePlaneStatus { stopped, starting, running, failed }

/// Single source of truth for the acceptance app UI.
///
/// Owns an [AcceptancePlane], subscribes to its request-log sink, derives
/// [authState]/[tokenPresent]/[endpoint]/[requestLog] from it and notifies
/// listeners. UI must not cache any of these locally.
class AcceptanceController extends ChangeNotifier {
  AcceptanceController._(this.plane);

  /// Creates a controller owning a fresh [AcceptancePlane] whose request-log
  /// sink feeds this controller's state machine.
  factory AcceptanceController() {
    AcceptanceController? controller;
    final plane = AcceptancePlane(onRequestLog: (entry) {
      final attached = controller;
      if (attached == null) return;
      attached._applyLog(entry);
      scheduleMicrotask(attached.notifyListeners);
    });
    controller = AcceptanceController._(plane);
    return controller;
  }

  final AcceptancePlane plane;

  final List<AcceptanceRequestLogEntry> _requestLog =
      <AcceptanceRequestLogEntry>[];

  AcceptancePlaneStatus planeStatus = AcceptancePlaneStatus.stopped;
  AcceptanceAuthState authState = AcceptanceAuthState.idle;
  Uri? endpoint;
  String? pendingRequestId;
  String? pendingClientLabel;

  /// Read-only views.
  bool get tokenPresent => plane.authManager.tokenPresent;

  List<AcceptanceRequestLogEntry> get requestLog =>
      List.unmodifiable(_requestLog);

  Iterable<String> get pendingRequestIds => plane.authManager.pendingRequestIds;

  String? get activeRequestId => pendingRequestId;

  String? get activeClientLabel => pendingClientLabel;

  int get capabilityCount => plane.buildCapabilities().length;

  bool get planeRunning => planeStatus == AcceptancePlaneStatus.running;

  /// Last log entry's authResult, or empty-state text when no requests yet.
  String get lastResultText =>
      _requestLog.isEmpty ? 'No requests yet' : _requestLog.last.authResult;

  /// Starts the Dart debug plane. On success updates [endpoint] and sets
  /// planeStatus=running; on failure sets planeStatus=failed without throwing.
  Future<void> start() async {
    if (planeStatus == AcceptancePlaneStatus.running) return;
    planeStatus = AcceptancePlaneStatus.starting;
    notifyListeners();
    try {
      endpoint = await plane.startDartPlane();
      planeStatus = AcceptancePlaneStatus.running;
    } catch (error) {
      planeStatus = AcceptancePlaneStatus.failed;
      _requestLog.add(AcceptanceRequestLogEntry(
        sequence: _requestLog.length,
        timestamp: DateTime.now(),
        method: 'SYSTEM',
        route: '/plane/start',
        authResult: 'failed',
        statusCode: 500,
        message: error.toString(),
      ));
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await plane.stop();
    planeStatus = AcceptancePlaneStatus.stopped;
    endpoint = null;
    notifyListeners();
  }

  /// Approves the currently pending authorization request (if any).
  Future<void> approvePending() async {
    final id = pendingRequestId;
    if (id == null) return;
    await plane.authManager.approvePending(id);
  }

  /// Denies the currently pending authorization request (if any).
  Future<void> denyPending() async {
    final id = pendingRequestId;
    if (id == null) return;
    await plane.authManager.denyPending(id);
  }

  void clearToken() {
    plane.authManager.clearToken();
    authState = AcceptanceAuthState.cleared;
    notifyListeners();
  }

  void expireToken() {
    plane.authManager.expireToken();
    authState = AcceptanceAuthState.expired;
    notifyListeners();
  }

  /// Drives an unauthorized authorization request through the auth manager
  /// (equivalent to a desktop-side client hitting /auth/request).
  Future<void> simulateAuthRequest({
    String clientLabel = 'desktop-cli',
    String? clientNonce,
  }) {
    return plane.authManager.requestAuthorization(<String, Object?>{
      'clientLabel': clientLabel,
      if (clientNonce != null) 'clientNonce': clientNonce,
    });
  }

  /// Simulates a sensitive request hitting [route] with the current token
  /// state, used to drive token_expired / authorization_required log paths.
  Future<void> simulateSensitiveRequest({
    String route = '/debug/secure-action',
    String? bearerToken,
  }) {
    return plane.authManager.authorize(AuthRequest(
      method: 'POST',
      segments: Uri.parse(route).pathSegments,
      routeClass: AuthRouteClass.sensitive,
      bearerToken: bearerToken ?? plane.authManager.activeToken,
    ));
  }

  /// Runtime state snapshot for acceptance collectors (DEC-002).
  Map<String, dynamic> toAcceptanceSnapshot() => <String, dynamic>{
        'planeRunning': planeRunning,
        'authStatus': authState.name,
        'tokenPresent': tokenPresent,
        'endpoint': endpoint?.toString(),
        'pendingRequestId': pendingRequestId,
        'pendingClientLabel': pendingClientLabel,
        'capabilityCount': capabilityCount,
        'lastResult': lastResultText,
        'requestLogSize': _requestLog.length,
      };

  void _applyLog(AcceptanceRequestLogEntry entry) {
    _requestLog.add(entry);
    switch (entry.authResult) {
      case 'pending':
        if (entry.route == '/auth/request') {
          authState = AcceptanceAuthState.pending;
          pendingRequestId = entry.requestId ?? pendingRequestId;
          pendingClientLabel = entry.clientLabel ?? pendingClientLabel;
        }
        break;
      case 'approved':
        authState = AcceptanceAuthState.approved;
        break;
      case 'denied':
        authState = AcceptanceAuthState.denied;
        _clearPending();
        break;
      case 'claimed':
        // Successful claim means the token has been issued.
        authState = AcceptanceAuthState.approved;
        _clearPending();
        break;
      case 'cleared':
        authState = AcceptanceAuthState.cleared;
        break;
      case 'expired':
      case 'token_expired':
        authState = AcceptanceAuthState.expired;
        break;
      default:
        break;
    }
  }

  void _clearPending() {
    pendingRequestId = null;
    pendingClientLabel = null;
  }
}
