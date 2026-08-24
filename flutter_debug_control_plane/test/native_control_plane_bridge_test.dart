import 'dart:async';

import 'package:debug_control_plane/debug_control_plane.dart';
import 'package:flutter/services.dart';
import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('registration serialization (FF001-1 Decl schema)', () {
    test('register serializes decls with path as JSON array (List<String>)',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge();
      await bridge.register(BridgeCapability(_FakeCap('gamepad')));

      final call =
          sent.firstWhere((c) => c.method == kMethodCapabilityRegister);
      final args = (call.arguments as Map).cast<String, Object?>();
      expect(args['capId'], 'gamepad');

      final resources = args['resources'] as List;
      expect(resources, hasLength(1));
      final resource = resources.first as Map;
      expect(resource['method'], 'GET');
      // Codec-decoded lists are List<Object?> — the wire requirement is
      // array-of-strings (PROTOCOL.md §2.3), NOT a '/virtual/state' string.
      expect(resource['path'], isA<List<dynamic>>());
      expect(resource['path'], everyElement(isA<String>()));
      expect(resource['path'], ['virtual', '{id}']);
      expect(resource['description'], 'virtual state');

      final commands = args['commands'] as List;
      final command = commands.first as Map;
      expect(command['method'], 'POST');
      expect(command['path'], ['virtual', 'press']);

      await bridge.dispose();
    });

    test('duplicate register throws StateError locally, channel untouched',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge();
      await bridge.register(BridgeCapability(_FakeCap('gamepad')));
      await expectLater(
        bridge.register(BridgeCapability(_FakeCap('gamepad'))),
        throwsA(isA<StateError>()),
      );

      final registerCalls =
          sent.where((c) => c.method == kMethodCapabilityRegister).toList();
      expect(registerCalls, hasLength(1));
      await bridge.dispose();
    });

    test('register also pushes the eager state snapshot', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge();
      await bridge.register(BridgeCapability(_FakeCap('gamepad')));

      final push = sent.firstWhere(
        (c) => c.method == kMethodCapabilityStateUpdate,
      );
      final args = (push.arguments as Map).cast<String, Object?>();
      expect(args['capId'], 'gamepad');
      expect(args['state'], {'connected': true});
      await bridge.dispose();
    });

    test('unregister sends capId and updates registeredIds', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge();
      await bridge.register(BridgeCapability(_FakeCap('gamepad')));
      expect(bridge.registeredIds, {'gamepad'});

      await bridge.unregister('gamepad');
      expect(bridge.registeredIds, isEmpty);

      final call =
          sent.firstWhere((c) => c.method == kMethodCapabilityUnregister);
      expect((call.arguments as Map)['capId'], 'gamepad');
      await bridge.dispose();
    });
  });

  group('events upstream', () {
    test('emitEvent forwards {capId, event:{type, payload}}, no sequence',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge();
      await bridge.emitEvent(
          'gamepad',
          const DebugEvent(
              type: 'pressed', sequence: 99, payload: {'key': 'A'}));

      final call = sent.singleWhere((c) => c.method == kMethodEventsEmit);
      final args = (call.arguments as Map).cast<String, Object?>();
      expect(args['capId'], 'gamepad');
      final event = args['event'] as Map;
      expect(event['type'], 'pressed');
      expect(event['payload'], {'key': 'A'});
      // Sequence is native-assigned (§3.1): Dart-side value must NOT cross.
      expect(event.containsKey('sequence'), isFalse);
      await bridge.dispose();
    });

    test('register collects cap.events once and forwards each frame', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final cap = _FakeCap('gamepad');
      final bridge = NativeControlPlaneBridge();
      await bridge.register(BridgeCapability(cap));

      cap.emitEvent('pressed', {'key': 'A'});
      await Future<void>.delayed(Duration.zero);

      final emits = sent.where((c) => c.method == kMethodEventsEmit).toList();
      expect(emits, hasLength(1));
      final args = (emits.single.arguments as Map).cast<String, Object?>();
      expect(args['event'], {
        'type': 'pressed',
        'payload': {'key': 'A'}
      });
      await bridge.dispose();
    });
  });

  group('reverse invoke (native -> Dart capability.invoke)', () {
    test('routeIndex resource hit: handler runs, result filled by reqId',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final cap = _FakeCap('gamepad');
      final bridge = NativeControlPlaneBridge()..attach();
      await bridge.register(BridgeCapability(cap));

      await BindingHelper.deliverNativeCall(
          messenger, kMethodCapabilityInvoke, {
        'reqId': 7,
        'capId': 'gamepad',
        'routeKind': kRouteKindResource,
        'routeIndex': 0,
        'pathParams': {'id': 'left'},
        'body': <String, Object?>{},
      });
      await Future<void>.delayed(Duration.zero);

      expect(cap.resourceCalls, [
        {'id': 'left'}
      ]);
      final fill = sent
          .singleWhere((c) => c.method == kMethodCapabilityInvokeResult)
          .arguments as Map;
      expect(fill['reqId'], 7);
      expect(fill['result'], {
        'ok': true,
        'params': {'id': 'left'},
      });
      await bridge.dispose();
    });

    test('routeIndex command hit: handler receives body', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final cap = _FakeCap('gamepad');
      final bridge = NativeControlPlaneBridge()..attach();
      await bridge.register(BridgeCapability(cap));

      await BindingHelper.deliverNativeCall(
          messenger, kMethodCapabilityInvoke, {
        'reqId': 8,
        'capId': 'gamepad',
        'routeKind': kRouteKindCommand,
        'routeIndex': 0,
        'pathParams': <String, String>{},
        'body': {'button': 'A'},
      });
      await Future<void>.delayed(Duration.zero);

      expect(cap.commandCalls, [
        {'button': 'A'}
      ]);
      final fill = sent
          .singleWhere((c) => c.method == kMethodCapabilityInvokeResult)
          .arguments as Map;
      expect(fill['reqId'], 8);
      expect(fill['result'], {
        'ok': true,
        'body': {'button': 'A'},
      });
      await bridge.dispose();
    });

    test('handler RouteFailure fills error {statusCode, code, message}',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final cap = _FailingCap('bad');
      final bridge = NativeControlPlaneBridge()..attach();
      await bridge.register(BridgeCapability(cap));

      await BindingHelper.deliverNativeCall(
          messenger, kMethodCapabilityInvoke, {
        'reqId': 9,
        'capId': 'bad',
        'routeKind': kRouteKindResource,
        'routeIndex': 0,
        'pathParams': <String, String>{},
        'body': <String, Object?>{},
      });
      await Future<void>.delayed(Duration.zero);

      final fill = sent
          .singleWhere((c) => c.method == kMethodCapabilityInvokeResult)
          .arguments as Map;
      expect(fill['reqId'], 9);
      final error = fill['error'] as Map;
      expect(error['statusCode'], 409);
      expect(error['code'], 'real_controller_active');
      expect(error['message'], 'busy');
      await bridge.dispose();
    });

    test('unknown routeIndex fills 500 internal_error', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge()..attach();
      await bridge.register(BridgeCapability(_FakeCap('gamepad')));

      await BindingHelper.deliverNativeCall(
          messenger, kMethodCapabilityInvoke, {
        'reqId': 10,
        'capId': 'gamepad',
        'routeKind': kRouteKindResource,
        'routeIndex': 42,
        'pathParams': <String, String>{},
        'body': <String, Object?>{},
      });
      await Future<void>.delayed(Duration.zero);

      final fill = sent
          .singleWhere((c) => c.method == kMethodCapabilityInvokeResult)
          .arguments as Map;
      final error = fill['error'] as Map;
      expect(error['statusCode'], 500);
      expect(error['code'], 'internal_error');
      await bridge.dispose();
    });

    test('unknown capId fills 404 not_registered (kErrorCodeNotRegistered)',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge()..attach();

      await BindingHelper.deliverNativeCall(
          messenger, kMethodCapabilityInvoke, {
        'reqId': 12,
        'capId': 'ghost',
        'routeKind': kRouteKindResource,
        'routeIndex': 0,
        'pathParams': <String, String>{},
        'body': <String, Object?>{},
      });
      await Future<void>.delayed(Duration.zero);

      final fill = sent
          .singleWhere((c) => c.method == kMethodCapabilityInvokeResult)
          .arguments as Map;
      final error = fill['error'] as Map;
      expect(error['statusCode'], 404);
      expect(error['code'], kErrorCodeNotRegistered);
      await bridge.dispose();
    });

    test('unknown routeKind fills 500 internal_error', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge()..attach();
      await bridge.register(BridgeCapability(_FakeCap('gamepad')));

      await BindingHelper.deliverNativeCall(
          messenger, kMethodCapabilityInvoke, {
        'reqId': 13,
        'capId': 'gamepad',
        'routeKind': 'websocket',
        'routeIndex': 0,
        'pathParams': <String, String>{},
        'body': <String, Object?>{},
      });
      await Future<void>.delayed(Duration.zero);

      final fill = sent
          .singleWhere((c) => c.method == kMethodCapabilityInvokeResult)
          .arguments as Map;
      final error = fill['error'] as Map;
      expect(error['statusCode'], 500);
      expect(error['code'], 'internal_error');
      expect(error['message'], contains('websocket'));
      await bridge.dispose();
    });
    test('state pull fills capability.state.result with current state',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge()..attach();
      await bridge.register(BridgeCapability(_FakeCap('gamepad')));

      await BindingHelper.deliverNativeCall(
          messenger, kMethodCapabilityStatePull, {
        'reqId': 11,
        'capId': 'gamepad',
      });
      await Future<void>.delayed(Duration.zero);

      final fill = sent
          .singleWhere((c) => c.method == kMethodCapabilityStateResult)
          .arguments as Map;
      expect(fill['reqId'], 11);
      expect(fill['state'], {'connected': true});
      await bridge.dispose();
    });
  });

  group('attach contract', () {
    test('second attach throws StateError; dispose re-allows attach', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      BindingHelper.captureOutgoing(messenger, (_) {});

      final bridge = NativeControlPlaneBridge()..attach();
      expect(() => bridge.attach(), throwsA(isA<StateError>()));
      bridge.dispose();
      bridge.attach();
      bridge.dispose();
    });

    test('invoke before attach (no handler installed) is not answered',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      // No attach() -> setMethodCallHandler was never installed, so the
      // engine drops the native invoke; assert no fill-in crosses back.
      final bridge = NativeControlPlaneBridge();
      await BindingHelper.deliverNativeCall(
          messenger, kMethodCapabilityInvoke, {
        'reqId': 14,
        'capId': 'gamepad',
        'routeKind': kRouteKindResource,
        'routeIndex': 0,
        'pathParams': <String, String>{},
        'body': <String, Object?>{},
      });

      expect(
        sent.where((c) => c.method == kMethodCapabilityInvokeResult),
        isEmpty,
      );
      await bridge.dispose();
    });
  });

  group('authorization bridge', () {
    test('auth.request reaches auth handler without capability result fill',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      DebugAuthRequest? received;
      final bridge = NativeControlPlaneBridge()..attach();
      bridge.setAuthorizationHandler((request) async {
        received = request;
      });

      await BindingHelper.deliverNativeCall(messenger, kMethodAuthRequest, {
        'reqId': 21,
        'requestId': 'auth-1',
        'clientLabel': 'devtool',
        'endpoint': '/mcp',
        'method': 'POST',
        'createdAt': '2026-08-24T08:20:00Z',
      });

      expect(received?.requestId, 'auth-1');
      expect(received?.reqId, 21);
      expect(received?.clientLabel, 'devtool');
      expect(received?.endpoint, '/mcp');
      expect(received?.method, 'POST');
      expect(received?.createdAt, DateTime.parse('2026-08-24T08:20:00Z'));
      expect(
        sent.where((c) => c.method == kMethodCapabilityInvokeResult),
        isEmpty,
      );
      await bridge.dispose();
    });

    test('clearing auth handler makes later auth.request a no-op', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      var calls = 0;
      final bridge = NativeControlPlaneBridge()..attach();
      bridge.setAuthorizationHandler((_) async {
        calls += 1;
      });
      bridge.setAuthorizationHandler(null);

      await BindingHelper.deliverNativeCall(messenger, kMethodAuthRequest, {
        'requestId': 'auth-2',
      });

      expect(calls, 0);
      expect(
        sent.where((c) => c.method == kMethodCapabilityInvokeResult),
        isEmpty,
      );
      await bridge.dispose();
    });

    test('auth handler failures are contained', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final bridge = NativeControlPlaneBridge()..attach();
      bridge.setAuthorizationHandler((_) async {
        throw StateError('host UI failed');
      });

      await BindingHelper.deliverNativeCall(messenger, kMethodAuthRequest, {
        'requestId': 'auth-3',
      });

      expect(
        sent.where((c) => c.method == kMethodCapabilityInvokeResult),
        isEmpty,
      );
      await bridge.dispose();
    });

    test('malformed auth.request is ignored with no capability fill', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      var calls = 0;
      final bridge = NativeControlPlaneBridge()..attach();
      bridge.setAuthorizationHandler((_) async {
        calls += 1;
      });

      await BindingHelper.deliverNativeCall(messenger, kMethodAuthRequest, {
        'clientLabel': 'missing request id',
      });

      expect(calls, 0);
      expect(
        sent.where((c) => c.method == kMethodCapabilityInvokeResult),
        isEmpty,
      );
      await bridge.dispose();
    });

    test('DTOs parse optional fields and keep status token-free', () {
      final request = DebugAuthRequest.fromChannel({
        'requestId': 'auth-4',
        'createdAt': 1787559600000,
      });
      expect(request.requestId, 'auth-4');
      expect(request.reqId, isNull);
      expect(request.clientLabel, isNull);
      expect(
          request.createdAt,
          DateTime.fromMillisecondsSinceEpoch(
            1787559600000,
            isUtc: true,
          ));

      expect(
        () => DebugAuthRequest.fromChannel({'reqId': 22}),
        throwsA(isA<ArgumentError>()),
      );

      final status = DebugAuthStatus.fromChannel({
        'status': 'authorized',
        'requestId': 'auth-5',
        'expiresAt': '2026-08-24T09:20:00Z',
        'clientLabel': 'devtool',
        'token': 'must-not-be-exposed',
      });
      expect(status.status, 'authorized');
      expect(status.requestId, 'auth-5');
      expect(status.expiresAt, DateTime.parse('2026-08-24T09:20:00Z'));
      expect(status.clientLabel, 'devtool');
      expect(status, isNot(isA<DebugAuthClaim>()));

      final claim = DebugAuthClaim.fromChannel({
        'token': 'plain-token',
        'tokenId': 'tok-1',
        'expiresAt': '2026-08-24T10:20:00Z',
        'status': 'authorized',
      });
      expect(claim.token, 'plain-token');
      expect(claim.tokenId, 'tok-1');
      expect(claim.expiresAt, DateTime.parse('2026-08-24T10:20:00Z'));
      expect(claim.status, 'authorized');
    });

    test('approve sends payload and maps non-null/null claims', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(
        messenger,
        sent.add,
        reply: (call) {
          if (call.method == kMethodAuthApprove) {
            return {
              'token': 'plain-token',
              'tokenId': 'tok-1',
              'expiresAt': '2026-08-24T10:20:00Z',
              'status': 'authorized',
            };
          }
          return null;
        },
      );

      final bridge = NativeControlPlaneBridge();
      final claim = await bridge.approveAuthorization(
        'auth-6',
        ttl: const Duration(minutes: 5),
        clientLabel: 'devtool',
      );

      final approve = sent.singleWhere((c) => c.method == kMethodAuthApprove);
      expect(approve.arguments, {
        'requestId': 'auth-6',
        'ttlSeconds': 300,
        'clientLabel': 'devtool',
      });
      expect(claim?.token, 'plain-token');
      expect(claim?.tokenId, 'tok-1');

      BindingHelper.captureOutgoing(messenger, sent.add);
      expect(await bridge.approveAuthorization('auth-7'), isNull);
      await bridge.dispose();
    });

    test('deny revoke and status use auth methods with typed status reply',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(
        messenger,
        sent.add,
        reply: (call) {
          if (call.method == kMethodAuthStatus) {
            return {
              'status': 'pending',
              'requestId': 'auth-8',
              'expiresAt': '2026-08-24T09:20:00Z',
              'clientLabel': 'devtool',
            };
          }
          return null;
        },
      );

      final bridge = NativeControlPlaneBridge();
      await bridge.denyAuthorization('auth-8', reason: 'cancelled');
      await bridge.revokeAuthorization(tokenId: 'tok-2');
      await bridge.revokeAuthorization(all: true);
      final status = await bridge.authorizationStatus(requestId: 'auth-8');

      expect(
        sent.singleWhere((c) => c.method == kMethodAuthDeny).arguments,
        {'requestId': 'auth-8', 'reason': 'cancelled'},
      );
      expect(
        sent
            .firstWhere((c) =>
                c.method == kMethodAuthRevoke &&
                (c.arguments as Map)['tokenId'] == 'tok-2')
            .arguments,
        {'tokenId': 'tok-2'},
      );
      expect(
        sent
            .firstWhere((c) =>
                c.method == kMethodAuthRevoke &&
                (c.arguments as Map)['all'] == true)
            .arguments,
        {'all': true},
      );
      expect(
        sent.singleWhere((c) => c.method == kMethodAuthStatus).arguments,
        {'requestId': 'auth-8'},
      );
      expect(status.status, 'pending');
      expect(status.requestId, 'auth-8');
      expect(status.expiresAt, DateTime.parse('2026-08-24T09:20:00Z'));

      expect(
        () => bridge.revokeAuthorization(),
        throwsA(isA<ArgumentError>()),
      );
      await bridge.dispose();
    });
  });

  group('event pump lifecycle', () {
    test('unregister stops the events upstream pump', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final cap = _FakeCap('gamepad');
      final bridge = NativeControlPlaneBridge();
      await bridge.register(BridgeCapability(cap));
      cap.emitEvent('pressed', {'key': 'A'});
      await Future<void>.delayed(Duration.zero);
      expect(
        sent.where((c) => c.method == kMethodEventsEmit).length,
        1,
        reason: 'pump forwards frames while registered',
      );

      await bridge.unregister('gamepad');
      cap.emitEvent('pressed', {'key': 'B'});
      await Future<void>.delayed(Duration.zero);
      expect(
        sent.where((c) => c.method == kMethodEventsEmit).length,
        1,
        reason: 'unregister cancels the pump — no frame leaks upstream',
      );
      await bridge.dispose();
    });

    test('dispose stops all event pumps', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <MethodCall>[];
      BindingHelper.captureOutgoing(messenger, sent.add);

      final cap = _FakeCap('gamepad');
      final bridge = NativeControlPlaneBridge();
      await bridge.register(BridgeCapability(cap));
      await bridge.dispose();

      cap.emitEvent('pressed', {'key': 'A'});
      await Future<void>.delayed(Duration.zero);
      expect(
        sent.where((c) => c.method == kMethodEventsEmit),
        isEmpty,
        reason: 'dispose cancels the pump',
      );
    });
  });
}

/// Test helpers around the mock binary messenger.
class BindingHelper {
  /// Route all outgoing platform messages on [kMethodChannel] into [sink]
  /// (default reply null). Replaces the mock handler on each call.
  static void captureOutgoing(
    TestDefaultBinaryMessenger messenger,
    void Function(MethodCall) sink, {
    FutureOr<Object?> Function(MethodCall call)? reply,
  }) {
    messenger.setMockMethodCallHandler(
      const MethodChannel(kMethodChannel),
      (call) async {
        sink(call);
        return reply?.call(call);
      },
    );
  }

  /// Deliver a native -> Dart reverse invoke on [kMethodChannel].
  static Future<void> deliverNativeCall(
    TestDefaultBinaryMessenger messenger,
    String method,
    Map<String, Object?> args,
  ) async {
    final data =
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
    await messenger.handlePlatformMessage(
      kMethodChannel,
      data,
      (ByteData? _) {},
    );
    // Let the async handler (result fill via invokeMethod) run to completion.
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeCap implements Capability {
  _FakeCap(this.id);

  @override
  final String id;

  final StreamController<DebugEvent> _events =
      StreamController<DebugEvent>.broadcast();

  final List<Object?> resourceCalls = [];
  final List<Object?> commandCalls = [];

  void emitEvent(String type, Map<String, Object?> payload) {
    _events.add(DebugEvent(type: type, sequence: 0, payload: payload));
  }

  @override
  List<Resource> get resources => [
        Resource(
          method: 'GET',
          path: const ['virtual', '{id}'],
          description: 'virtual state',
          handler: (ctx) async {
            resourceCalls.add(ctx.pathParams);
            return {'ok': true, 'params': ctx.pathParams};
          },
        ),
      ];

  @override
  List<Command> get commands => [
        Command(
          method: 'POST',
          path: const ['virtual', 'press'],
          handler: (ctx) async {
            commandCalls.add(ctx.body);
            return {'ok': true, 'body': ctx.body};
          },
        ),
      ];

  @override
  Map<String, Object?> state() => {'connected': true};

  @override
  Stream<DebugEvent> get events => _events.stream;
}

class _FailingCap implements Capability {
  _FailingCap(this.id);

  @override
  final String id;

  @override
  List<Resource> get resources => [
        Resource(
          method: 'GET',
          path: const ['boom'],
          handler: (ctx) async =>
              throw const RouteFailure(409, 'real_controller_active', 'busy'),
        ),
      ];

  @override
  List<Command> get commands => [];

  @override
  Map<String, Object?> state() => const {};

  @override
  Stream<DebugEvent> get events => const Stream.empty();
}
