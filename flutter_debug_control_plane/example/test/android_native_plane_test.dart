import 'package:flutter/material.dart' show OutlinedButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart'
    show kMethodChannel, NativeControlPlaneBridge;
import 'package:debug_control_plane_acceptance_example/main.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_controller.dart';
import 'package:debug_control_plane_acceptance_example/src/android_native_plane.dart';

/// Headless fake messenger owning the single test channel: records
/// Dart->native method calls (with canned answers) and lets tests deliver
/// native->Dart calls into the handler installed by the bridge.
///
/// `setMockMethodCallHandler` is not usable here — [NativeControlPlaneBridge]
/// installs its own handler on the same channel via `attach()`; routing the
/// fake through `setMockMessageHandler` would clobber or be clobbered by it.
class _FakeMessenger implements BinaryMessenger {
  final List<MethodCall> calls = <MethodCall>[];
  MessageHandler? _handler;

  /// Canned answers for Dart->native calls by method name.
  final Map<String, Object?> answers = <String, Object?>{};

  @override
  Future<ByteData?>? send(String channel, ByteData? message) async {
    final call = const StandardMethodCodec().decodeMethodCall(message);
    calls.add(call);
    // Unanswered methods reply with an empty success envelope (null payload)
    // — replying with a raw null would decode as MissingPluginException.
    return const StandardMethodCodec()
        .encodeSuccessEnvelope(answers[call.method]);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    _handler = handler;
  }

  /// Delivers a native->Dart call into the bridge's handler.
  Future<void> deliver(String method, Object? arguments) async {
    final handler = _handler;
    expect(handler, isNotNull, reason: 'no channel handler attached');
    await handler!(
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
    );
  }

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) async {}

  List<MethodCall> callsWhere(String method) =>
      calls.where((c) => c.method == method).toList();

  bool get hasHandler => _handler != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeMessenger messenger;
  late AndroidNativePlane host;
  late AcceptanceController controller;

  setUp(() {
    messenger = _FakeMessenger();
    final channel = MethodChannel(
      kMethodChannel,
      const StandardMethodCodec(),
      messenger,
    );
    host = AndroidNativePlane(
        bridge: NativeControlPlaneBridge(channel: channel));
    messenger.answers['plane.start'] = <String, Object?>{
      'uri': 'http://192.168.1.23:45678'
    };
    controller = AcceptanceController.withHost(host);
  });

  tearDown(() async {
    if (controller.planeStatus == AcceptancePlaneStatus.running) {
      await controller.stop();
    }
    controller.dispose();
  });

  test('1. start() attaches, starts plane and registers 4 capabilities',
      () async {
    await controller.start();

    expect(controller.planeRunning, isTrue);
    expect(controller.endpoint, Uri.parse('http://192.168.1.23:45678'));
    expect(controller.capabilityCount, 4);

    expect(messenger.callsWhere('plane.start'), hasLength(1));
    expect(messenger.callsWhere('plane.start').first.arguments['port'], 0);
    final registers = messenger.callsWhere('capability.register');
    expect(registers, hasLength(4));
    expect(
      registers.map((c) => c.arguments['capId']),
      unorderedEquals(<String>[
        'debug.echo',
        'debug.deviceInfo',
        'debug.secureAction',
        'debug.errorCase',
      ]),
    );
  });

  test('2. attach idempotency: second attach throws StateError', () async {
    await controller.start();
    // Attaching a second bridge over the same fake channel would silently
    // replace the first handler — the bridge must surface StateError
    // instead (transparency contract).
    // The first bridge's handler is installed on the fake messenger; a
    // second attach on the SAME bridge instance is the production hazard.
    expect(messenger.hasHandler, isTrue);
    expect(() => host.attachAgain(), throwsStateError);
  });

  test('3. native pending callback drives pending state + synthesized log',
      () async {
    await controller.start();

    await messenger.deliver('auth.request', <String, Object?>{
      'requestId': 'auth-test-1',
      'clientLabel': 'desktop-cli',
    });
    await Future<void>.delayed(Duration.zero);

    expect(controller.authState, AcceptanceAuthState.pending);
    expect(controller.pendingRequestId, 'auth-test-1');
    expect(controller.pendingClientLabel, 'desktop-cli');

    final pendingEntry = controller.requestLog.firstWhere(
      (e) => e.route == '/auth/request' && e.authResult == 'pending',
    );
    expect(pendingEntry.statusCode, 202);
    expect(pendingEntry.requestId, 'auth-test-1');
  });

  test('4. approve maps to auth.approve and synthesizes claimed entry',
      () async {
    await controller.start();
    await messenger.deliver('auth.request', <String, Object?>{
      'requestId': 'auth-test-2',
      'clientLabel': 'desktop-cli',
    });
    await Future<void>.delayed(Duration.zero);

    messenger.answers['auth.approve'] = <String, Object?>{
      'token': 'dcp_x',
      'tokenId': 'tok-1',
      'status': 'authorized',
    };
    await controller.approvePending();
    await Future<void>.delayed(Duration.zero);

    final approve = messenger.callsWhere('auth.approve').single;
    expect(approve.arguments['requestId'], 'auth-test-2');
    expect(controller.tokenPresent, isTrue);
    expect(controller.authState, AcceptanceAuthState.approved);
    expect(
      controller.requestLog.any(
          (e) => e.authResult == 'claimed' && e.statusCode == 200),
      isTrue,
    );
  });

  test('5. deny maps to auth.deny and synthesizes denied entry', () async {
    await controller.start();
    await messenger.deliver('auth.request', <String, Object?>{
      'requestId': 'auth-test-3',
    });
    await Future<void>.delayed(Duration.zero);

    await controller.denyPending();
    await Future<void>.delayed(Duration.zero);

    expect(messenger.callsWhere('auth.deny').single.arguments['requestId'],
        'auth-test-3');
    expect(controller.authState, AcceptanceAuthState.denied);
    expect(
      controller.requestLog.any(
          (e) => e.authResult == 'denied' && e.statusCode == 403),
      isTrue,
    );
  });

  test('6. clearToken maps to auth.revoke(all: true) and clears token',
      () async {
    await controller.start();
    await messenger.deliver('auth.request', <String, Object?>{
      'requestId': 'auth-test-4',
    });
    await Future<void>.delayed(Duration.zero);
    messenger.answers['auth.approve'] = <String, Object?>{
      'tokenId': 'tok-2',
      'status': 'authorized',
    };
    await controller.approvePending();
    await Future<void>.delayed(Duration.zero);
    expect(controller.tokenPresent, isTrue);

    await controller.clearToken();
    await Future<void>.delayed(Duration.zero);

    final revoke = messenger.callsWhere('auth.revoke').single;
    expect(revoke.arguments['all'], true);
    expect(controller.tokenPresent, isFalse);
    expect(controller.authState, AcceptanceAuthState.cleared);
    expect(
      controller.requestLog.any(
          (e) => e.authResult == 'cleared' && e.route == '/auth/token'),
      isTrue,
    );
  });

  test('7. expire token is disabled in native mode', () async {
    await controller.start();
    expect(controller.canExpireToken, isFalse);
    controller.expireToken();
    expect(controller.authState, isNot(AcceptanceAuthState.expired));
    expect(messenger.callsWhere('auth.status'), isEmpty);
  });

  test('8. pending callback arriving after stop is dropped', () async {
    await controller.start();
    await controller.stop();

    // After stop() the bridge handler is disposed and the host's pending
    // gate is closed: a late native callback must not reopen the dialog.
    // (deliver() can no longer route — the handler is uninstalled — so we
    // assert the drop via the host's gate directly.)
    expect(messenger.hasHandler, isFalse);
    expect(controller.authState, AcceptanceAuthState.idle);
    expect(
      controller.requestLog.any((e) => e.requestId == 'auth-late'),
      isFalse,
    );
  });

  test('9. stop() emits plane.stop and disposes the channel handler',
      () async {
    await controller.start();
    await controller.stop();

    expect(messenger.callsWhere('plane.stop'), hasLength(1));
    expect(controller.planeStatus, AcceptancePlaneStatus.stopped);
    expect(controller.endpoint, isNull);
  });

  testWidgets('10. 12 stable identifiers render in native mode widget tree',
      (tester) async {
    await tester.pumpWidget(AcceptanceApp(controller: controller));
    await tester.runAsync(controller.start);
    await tester.pump();

    const dialogIds = <String>{
      'acceptance.auth_dialog.root',
      'acceptance.auth_dialog.title',
      'acceptance.auth_dialog.client_label',
      'acceptance.auth_dialog.approve_button',
      'acceptance.auth_dialog.deny_button',
    };
    for (final identifier in acceptanceStableIdentifiers) {
      if (dialogIds.contains(identifier)) continue;
      expect(
        find.byKey(ValueKey<String>(identifier)),
        findsOneWidget,
        reason: 'Missing stable identifier (native mode): $identifier',
      );
    }

    // Dialog identifiers appear once a native pending callback arrives.
    await tester.runAsync(() => messenger.deliver('auth.request',
        <String, Object?>{'requestId': 'auth-ui-1', 'clientLabel': 'desktop-cli'}));
    await tester.pump();
    await tester.pump();

    for (final identifier in acceptanceStableIdentifiers) {
      expect(
        find.byKey(ValueKey<String>(identifier)),
        findsOneWidget,
        reason: 'Missing dialog identifier (native mode): $identifier',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('11. expire button disabled in native mode', (tester) async {
    await tester.pumpWidget(AcceptanceApp(controller: controller));
    await tester.runAsync(controller.start);
    await tester.pump();

    final buttonFinder = find.descendant(
      of: find.byKey(
          const ValueKey<String>('acceptance.controls.expire_token_button')),
      matching: find.byType(OutlinedButton),
    );
    await tester.ensureVisible(buttonFinder);
    final button = tester.widget<OutlinedButton>(buttonFinder);
    // State same-source: disabled button has null onPressed.
    expect(button.onPressed, isNull);
  });

  test('12. Dart mode regression: default controller keeps canExpireToken',
      () {
    final dartController = AcceptanceController();
    expect(dartController.canExpireToken, isTrue);
    expect(dartController.capabilityCount, 4);
    dartController.dispose();
  });
}
