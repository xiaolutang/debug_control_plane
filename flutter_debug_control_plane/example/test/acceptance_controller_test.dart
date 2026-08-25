import 'package:debug_control_plane_acceptance_example/src/acceptance_controller.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('1. start() sets planeStatus=running and endpoint non-null',
        () async {
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
      expect(controller.pendingRequestIds, contains(controller.pendingRequestId));
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

    test('clearToken without an issued token still reports cleared',
        () async {
      expect(controller.tokenPresent, isFalse);
      await controller.clearToken();
      expect(controller.authState, AcceptanceAuthState.cleared);
      expect(controller.tokenPresent, isFalse);
    });

    test('toAcceptanceSnapshot exposes interaction_assertion states', () async {
      await controller.simulateAuthRequest(clientLabel: 'desktop-cli');
      await Future<void>.delayed(Duration.zero);
      final snapshot = controller.toAcceptanceSnapshot();
      expect(snapshot['planeRunning'], isTrue);
      expect(snapshot['authStatus'], 'pending');
      expect(snapshot['tokenPresent'], isFalse);
      expect(snapshot['endpoint'], isNotNull);
      expect(snapshot['pendingClientLabel'], 'desktop-cli');
    });
  });
}
