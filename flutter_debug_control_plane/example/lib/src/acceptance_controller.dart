import 'dart:async';

import 'package:debug_control_plane/debug_control_plane.dart';
import 'package:flutter/foundation.dart';

import 'acceptance_plane.dart';
import 'acceptance_plane_host.dart';

/// UI-layer six-state auth state for the acceptance app.
///
/// Distinct from BF006 wire enum [AcceptanceAuthStatus] (pending/approved/
/// denied); this controller maps wire/log events into these UI states.
enum AcceptanceAuthState { idle, pending, approved, denied, expired, cleared }

enum AcceptancePlaneStatus { stopped, starting, running, failed }

/// Single source of truth for the acceptance app UI.
///
/// Owns a [PlaneHost] (Dart plane or Android native plane — R002-FF003),
/// subscribes to its request-log sink, derives [authState]/[tokenPresent]/
/// [endpoint]/[requestLog] from it and notifies listeners. UI must not
/// cache any of these locally. Mode differences live inside the host; the
/// controller contains no mode branches.
class AcceptanceController extends ChangeNotifier {
  AcceptanceController._(this.host) {
    host.setOnRequestLog((entry) {
      _applyLog(entry);
      scheduleMicrotask(notifyListeners);
    });
  }

  /// Creates a controller owning a fresh Dart plane host (FB001 default).
  factory AcceptanceController() =>
      AcceptanceController.withHost(DartPlaneHost());

  /// Creates a controller over an explicit host (native mode injection).
  factory AcceptanceController.withHost(PlaneHost host) =>
      AcceptanceController._(host);

  final PlaneHost host;

  /// The acceptance plane behind the host (capability declarations source).
  AcceptancePlane get plane => host.plane;

  final List<AcceptanceRequestLogEntry> _requestLog =
      <AcceptanceRequestLogEntry>[];

  AcceptancePlaneStatus planeStatus = AcceptancePlaneStatus.stopped;
  AcceptanceAuthState authState = AcceptanceAuthState.idle;
  Uri? endpoint;
  String? pendingRequestId;
  String? pendingClientLabel;

  /// Read-only views.
  bool get tokenPresent => host.tokenPresent;

  /// Whether the expire-token control is available in the current mode.
  bool get canExpireToken => host.canExpireToken;

  List<AcceptanceRequestLogEntry> get requestLog =>
      List.unmodifiable(_requestLog);

  Iterable<String> get pendingRequestIds =>
      host.plane.authManager.pendingRequestIds;

  String? get activeRequestId => pendingRequestId;

  String? get activeClientLabel => pendingClientLabel;

  int get capabilityCount => host.capabilityCount;

  bool get planeRunning => planeStatus == AcceptancePlaneStatus.running;

  /// Last log entry's authResult, or empty-state text when no requests yet.
  String get lastResultText =>
      _requestLog.isEmpty ? 'No requests yet' : _requestLog.last.authResult;

  Future<void>? _startingFuture;

  /// Starts the debug plane. On success updates [endpoint] and sets
  /// planeStatus=running; on failure sets planeStatus=failed without throwing.
  ///
  /// Re-entrant safe (R002-FF003 fix): while a start is in flight a second
  /// call joins the in-flight future instead of issuing a second
  /// host.start() — the native bridge attach is one-shot and would throw
  /// `already attached` on double start.
  Future<void> start() {
    if (planeStatus == AcceptancePlaneStatus.running) {
      return Future<void>.value();
    }
    final inFlight = _startingFuture;
    if (inFlight != null) return inFlight;
    _startingFuture = _doStart();
    return _startingFuture!;
  }

  /// R005-FF001: attaches the plane's default file-backed token store before
  /// the plane starts (assembly-layer persistence, DEC-R005-006). No-op for
  /// hosts without a Dart-plane store (e.g. the Android native bridge).
  Future<void> ensurePersistentStore() async {
    final host = this.host;
    if (host is DartPlaneHost) {
      await host.plane.ensurePersistentStore();
    }
  }

  Future<void> _doStart() async {
    planeStatus = AcceptancePlaneStatus.starting;
    notifyListeners();
    try {
      endpoint = await host.start();
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
    _startingFuture = null;
    notifyListeners();
  }

  Future<void> stop() async {
    await host.stop();
    planeStatus = AcceptancePlaneStatus.stopped;
    endpoint = null;
    notifyListeners();
  }

  /// Approves the currently pending authorization request (if any).
  Future<void> approvePending() async {
    final id = pendingRequestId;
    if (id == null) return;
    await host.approvePending(id);
  }

  /// Denies the currently pending authorization request (if any).
  Future<void> denyPending() async {
    final id = pendingRequestId;
    if (id == null) return;
    await host.denyPending(id);
  }

  Future<void> clearToken() async {
    await host.clearToken();
    authState = AcceptanceAuthState.cleared;
    notifyListeners();
  }

  void expireToken() {
    if (!canExpireToken) return;
    host.expireToken();
    authState = AcceptanceAuthState.expired;
    notifyListeners();
  }

  /// R003-FB002: refresh_tools_button local semantics — re-reads the
  /// current controller state (capabilityCount) and drops one request-log
  /// entry over the EXISTING single log channel. No new protocol fields,
  /// no new MethodChannel traffic.
  void refreshToolList() {
    _requestLog.add(AcceptanceRequestLogEntry(
      sequence: _requestLog.length,
      timestamp: DateTime.now(),
      method: 'GET',
      route: '/state',
      authResult: 'ok',
      statusCode: 200,
      message: 'capabilityCount=$capabilityCount',
    ));
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
    final AuthRequest request = AuthRequest(
      method: 'POST',
      segments: Uri.parse(route).pathSegments,
      routeClass: AuthRouteClass.sensitive,
      bearerToken: bearerToken ?? plane.authManager.activeToken,
    );
    return plane.authManager.authorize(request);
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
    // Re-stamp the sequence with the controller-global counter: in native
    // mode two log channels (native bridge + plane capability HTTP) each
    // carry their own channel-scoped counter and both start at 0, which
    // produced duplicate ValueKeys in the request list (R002-FF003 fix).
    _requestLog.add(entry.copyWith(sequence: _requestLog.length));
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
