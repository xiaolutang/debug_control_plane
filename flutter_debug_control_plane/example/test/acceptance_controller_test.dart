import 'dart:async';

import 'package:debug_control_plane_acceptance_example/src/acceptance_controller.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_plane.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_plane_host.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake host emitting entries from two independent channel-scoped log
/// counters (simulating native mode: bridge channel + plane capability
/// HTTP channel, both starting at sequence 0).
class _DualChannelFakeHost implements PlaneHost {
  AcceptanceRequestLogSink? _sink;

  void emit(int channel, String route) {
    _sink?.call(AcceptanceRequestLogEntry(
      sequence: channel, // both channels replay their own counter from 0
      timestamp: DateTime.now(),
      method: 'GET',
      route: route,
      authResult: 'allowed',
      statusCode: 200,
    ));
  }

  @override
  late final AcceptancePlane plane = AcceptancePlane();

  @override
  Future<Uri?> start() async => null;

  @override
  Future<void> stop() async {}

  @override
  int get capabilityCount => 4;

  @override
  void setOnRequestLog(AcceptanceRequestLogSink? sink) {
    _sink = sink;
  }

  @override
  Future<void> approvePending(String requestId) async {}

  @override
  Future<void> denyPending(String requestId) async {}

  @override
  bool get tokenPresent => false;

  @override
  Future<void> clearToken() async {}

  @override
  bool get canExpireToken => false;

  @override
  void expireToken() {}
}

/// Host whose start() only completes when the test lets it, counting calls.
class _GatedFakeHost implements PlaneHost {
  int startCallCount = 0;
  final Completer<void> _gate = Completer<void>();

  void releaseStart() => _gate.complete();

  @override
  late final AcceptancePlane plane = AcceptancePlane();

  @override
  Future<Uri?> start() async {
    startCallCount++;
    await _gate.future;
    return Uri.parse('http://127.0.0.1:12345');
  }

  @override
  Future<void> stop() async {}

  @override
  int get capabilityCount => 4;

  @override
  void setOnRequestLog(AcceptanceRequestLogSink? sink) {}

  @override
  Future<void> approvePending(String requestId) async {}

  @override
  Future<void> denyPending(String requestId) async {}

  @override
  bool get tokenPresent => false;

  @override
  Future<void> clearToken() async {}

  @override
  bool get canExpireToken => false;

  @override
  void expireToken() {}
}

void main() {
  group('AcceptanceController state machine', () {
    late AcceptanceController controller;

    setUp(() async {
      controller = AcceptanceController();
      await controller.start();
    });

    tearDown(() async {
      await controller.stop();
      controller.dispose();
    });

    test('1. start() sets planeStatus=running and endpoint non-null', () async {
      expect(controller.planeStatus, AcceptancePlaneStatus.running);
      expect(controller.endpoint, isNotNull);
      expect(controller.endpoint!.port, greaterThan(0));
      expect(controller.planeRunning, isTrue);
    });

    test('2. unauthorized request drives pending with requestId/clientLabel',
        () async {
      await controller.simulateAuthRequest(clientLabel: 'desktop-cli');
      await Future<void>.delayed(Duration.zero);
      expect(controller.authState, AcceptanceAuthState.pending);
      expect(controller.pendingRequestId, isNotNull);
      expect(
          controller.pendingRequestIds, contains(controller.pendingRequestId));
      expect(controller.pendingClientLabel, 'desktop-cli');
    });

    test('3. idle -> pending -> approved', () async {
      expect(controller.authState, AcceptanceAuthState.idle);
      await controller.simulateAuthRequest();
      await Future<void>.delayed(Duration.zero);
      await controller.approvePending();
      await Future<void>.delayed(Duration.zero);
      expect(controller.authState, AcceptanceAuthState.approved);
    });

    test('4. pending -> denied', () async {
      await controller.simulateAuthRequest();
      await Future<void>.delayed(Duration.zero);
      await controller.denyPending();
      await Future<void>.delayed(Duration.zero);
      expect(controller.authState, AcceptanceAuthState.denied);
    });

    test('5. clearToken sets cleared and tokenPresent=false', () async {
      // Issue a token via approve + claim path.
      await controller.simulateAuthRequest();
      await Future<void>.delayed(Duration.zero);
      await controller.approvePending();
      await controller.plane.authManager.claimAuthorization(
        <String, Object?>{'requestId': controller.pendingRequestId},
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.tokenPresent, isTrue);

      controller.clearToken();
      expect(controller.authState, AcceptanceAuthState.cleared);
      expect(controller.tokenPresent, isFalse);
      expect(
        controller.requestLog.any((e) => e.authResult == 'cleared'),
        isTrue,
      );
    });

    test('6. expireToken then sensitive request yields token_expired',
        () async {
      await controller.simulateAuthRequest();
      await Future<void>.delayed(Duration.zero);
      await controller.approvePending();
      await controller.plane.authManager.claimAuthorization(
        <String, Object?>{'requestId': controller.pendingRequestId},
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.tokenPresent, isTrue);

      controller.expireToken();
      await controller.simulateSensitiveRequest();
      await Future<void>.delayed(Duration.zero);
      expect(controller.authState, AcceptanceAuthState.expired);
      expect(
        controller.requestLog.any(
          (e) => e.authResult == 'token_expired' && e.statusCode == 401,
        ),
        isTrue,
      );
    });

    test('7. requestLog appends entries with route/statusCode/authResult',
        () async {
      await controller.simulateAuthRequest();
      await controller.simulateSensitiveRequest();
      await Future<void>.delayed(Duration.zero);

      final pendingEntry = controller.requestLog.firstWhere(
        (e) => e.route == '/auth/request' && e.authResult == 'pending',
      );
      expect(pendingEntry.statusCode, 202);
      expect(pendingEntry.requestId, isNotNull);

      final sensitiveEntry = controller.requestLog.firstWhere(
        (e) => e.route == '/debug/secure-action',
      );
      expect(sensitiveEntry.statusCode, 401);
      expect(sensitiveEntry.authResult, 'authorization_required');
    });

    test('claim -> approved path leaves authState approved with token',
        () async {
      await controller.simulateAuthRequest();
      await Future<void>.delayed(Duration.zero);
      await controller.approvePending();
      await controller.plane.authManager.claimAuthorization(
        <String, Object?>{'requestId': controller.pendingRequestId},
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.authState, AcceptanceAuthState.approved);
      expect(controller.tokenPresent, isTrue);
      expect(controller.lastResultText, 'claimed');
    });

    test('capabilityCount reflects registered capabilities', () {
      expect(controller.capabilityCount, 4);
    });

    // R002-FF004 edge cases: no-op decisions and state re-entry.
    test('approve/deny without a pending request are no-ops', () async {
      expect(controller.pendingRequestId, isNull);
      await controller.approvePending();
      await controller.denyPending();
      await Future<void>.delayed(Duration.zero);
      expect(controller.authState, AcceptanceAuthState.idle);
      expect(controller.requestLog.where((e) => e.route == '/auth/status'),
          isEmpty);
    });

    test('deny then a new request re-enters pending', () async {
      await controller.simulateAuthRequest(clientLabel: 'first');
      await Future<void>.delayed(Duration.zero);
      await controller.denyPending();
      await Future<void>.delayed(Duration.zero);
      expect(controller.authState, AcceptanceAuthState.denied);
      expect(controller.pendingRequestId, isNull);

      await controller.simulateAuthRequest(clientLabel: 'second');
      await Future<void>.delayed(Duration.zero);
      expect(controller.authState, AcceptanceAuthState.pending);
      expect(controller.pendingClientLabel, 'second');
    });

    test('clearToken without an issued token still reports cleared', () async {
      expect(controller.tokenPresent, isFalse);
      await controller.clearToken();
      expect(controller.authState, AcceptanceAuthState.cleared);
      expect(controller.tokenPresent, isFalse);
    });
  });

  group('R002-FF003 fix: dual-channel sequence dedup', () {
    test(
        'entries with colliding channel sequences get unique controller sequences',
        () {
      final host = _DualChannelFakeHost();
      final controller = AcceptanceController.withHost(host);
      addTearDown(controller.dispose);

      // Both channels emit their first entry — both carry sequence=0.
      host.emit(0, '/native/bridge');
      host.emit(0, '/capability/http');

      expect(controller.requestLog.length, 2);
      expect(controller.requestLog.map((e) => e.sequence), [0, 1]);
      expect(
        controller.requestLog.map((e) => e.sequence).toSet().length,
        2,
        reason: 'sequences must be unique for ValueKey use in the UI',
      );
      // Payload fields survive the re-stamp.
      expect(controller.requestLog[0].route, '/native/bridge');
      expect(controller.requestLog[1].route, '/capability/http');
    });
  });

  group('R002-FF003 fix: start() re-entrancy', () {
    test('concurrent start() calls issue a single host.start() and join',
        () async {
      final host = _GatedFakeHost();
      final controller = AcceptanceController.withHost(host);
      addTearDown(controller.dispose);

      final first = controller.start();
      final second = controller.start();
      expect(host.startCallCount, 1,
          reason: 'second start must join the in-flight one, not re-issue');

      host.releaseStart();
      await Future.wait(<Future<void>>[first, second]);

      expect(controller.planeRunning, isTrue);
      expect(controller.endpoint, isNotNull);
    });
  });
}
