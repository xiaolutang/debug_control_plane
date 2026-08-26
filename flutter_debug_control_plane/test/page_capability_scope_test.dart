import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';
import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;
  late List<MethodCall> sent;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    sent = <MethodCall>[];
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(const MethodChannel(kMethodChannel),
        (call) async {
      throw MissingPluginException(call.method);
    });
  });

  /// Route all outgoing messages on [kMethodChannel] into [sink] (default
  /// reply null). [reply] may inject platform errors to simulate native
  /// failures in the send phase.
  void capture(
    void Function(MethodCall) sink, {
    FutureOr<Object?> Function(MethodCall)? reply,
  }) {
    messenger.setMockMethodCallHandler(const MethodChannel(kMethodChannel),
        (call) async {
      sink(call);
      return await reply?.call(call);
    });
  }

  Map<String, Object?> argsOf(MethodCall call) =>
      (call.arguments as Map).cast<String, Object?>();

  List<MethodCall> calls(String method) =>
      sent.where((c) => c.method == method).toList();

  group('PageCapabilityScope construction', () {
    test('blank pageId throws ArgumentError before any channel traffic', () {
      final cases = ['', '   ', '\t\n'];
      for (final pageId in cases) {
        expect(
          () => PageCapabilityScope(
            bridge: NativeControlPlaneBridge(),
            pageId: pageId,
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'pageId="$pageId" must be rejected',
        );
      }
      expect(sent, isEmpty);
    });

    test('valid pageId exposes identity and initial state getters', () {
      final scope = PageCapabilityScope(
        bridge: NativeControlPlaneBridge(),
        pageId: 'checkout',
        pageName: 'Checkout',
      );
      expect(scope.pageId, 'checkout');
      expect(scope.registeredCount, 0);
      expect(scope.isDisposed, isFalse);
      expect(sent, isEmpty);
    });
  });

  group('registerAll payloads', () {
    test('sends capability.register with scope=page/pageId/pageName per cap',
        () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = PageCapabilityScope(
        bridge: bridge,
        pageId: 'checkout',
        pageName: 'Checkout',
      );
      await scope.registerAll([
        BridgeCapability(_FakeCap('cart')),
        BridgeCapability(_FakeCap('pay')),
      ]);

      final registers = calls(kMethodCapabilityRegister);
      expect(registers, hasLength(2));
      final ids = registers.map((c) => argsOf(c)['capId']).toList();
      expect(ids, ['cart', 'pay']);
      for (final call in registers) {
        final args = argsOf(call);
        expect(args['scope'], 'page');
        expect(args['pageId'], 'checkout');
        expect(args['pageName'], 'Checkout');
      }
      expect(scope.registeredCount, 2);
      expect(scope.isDisposed, isFalse);
      await scope.dispose();
      await bridge.dispose();
    });

    test('omits pageName payload field when null', () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = PageCapabilityScope(bridge: bridge, pageId: 'checkout');
      await scope.registerAll([BridgeCapability(_FakeCap('cart'))]);

      final args = argsOf(calls(kMethodCapabilityRegister).single);
      expect(args.containsKey('pageName'), isFalse);
      expect(args['scope'], 'page');
      expect(args['pageId'], 'checkout');
      await scope.dispose();
      await bridge.dispose();
    });

    test('eager state push carries the same page identity', () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = PageCapabilityScope(
        bridge: bridge,
        pageId: 'checkout',
        pageName: 'Checkout',
      );
      await scope.registerAll([BridgeCapability(_FakeCap('cart'))]);

      final push = calls(kMethodCapabilityStateUpdate);
      expect(push, hasLength(1));
      final args = argsOf(push.single);
      expect(args['capId'], 'cart');
      expect(args['scope'], 'page');
      expect(args['pageId'], 'checkout');
      // pageName is registry metadata only — never part of state keys.
      expect(args['state'], {'connected': true});
      await scope.dispose();
      await bridge.dispose();
    });
  });

  group('dispose payloads and cross-scope isolation', () {
    test('unregisters each capId with {capId, scope=page, pageId}', () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = PageCapabilityScope(
        bridge: bridge,
        pageId: 'checkout',
        pageName: 'Checkout',
      );
      await scope.registerAll([
        BridgeCapability(_FakeCap('cart')),
        BridgeCapability(_FakeCap('pay')),
      ]);
      sent.clear();

      await scope.dispose();

      final unregisters = calls(kMethodCapabilityUnregister);
      expect(unregisters.map((c) => argsOf(c)), [
        {'capId': 'cart', 'scope': 'page', 'pageId': 'checkout'},
        {'capId': 'pay', 'scope': 'page', 'pageId': 'checkout'},
      ]);
      expect(scope.registeredCount, 0);
      expect(scope.isDisposed, isTrue);

      // Terminal-adjacent registerAll attempt AFTER dispose → StateError.
      // (covered separately below)
      await bridge.dispose();
    });

    test('disposing page A leaves page B (same capIds) and app entries intact',
        () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final appOnly = PageCapabilityScope(bridge: bridge, pageId: '__probe__');

      final pageA = PageCapabilityScope(bridge: bridge, pageId: 'A');
      final pageB = PageCapabilityScope(bridge: bridge, pageId: 'B');
      await pageA.registerAll([BridgeCapability(_FakeCap('shared'))]);
      await pageB.registerAll([BridgeCapability(_FakeCap('shared'))]);
      // App registration of the same capId coexists with both pages.
      await bridge.register(BridgeCapability(_FakeCap('shared')));
      sent.clear();

      await pageA.dispose();

      final unregisters = calls(kMethodCapabilityUnregister);
      expect(unregisters, hasLength(1));
      final args = argsOf(unregisters.single);
      expect(args, {'capId': 'shared', 'scope': 'page', 'pageId': 'A'});

      // Page B still serves its own scoped key; the page B entry is not
      // touched by A's dispose — re-registering into B would fail as
      // duplicate (its key remains), proving survival.
      expect(pageB.registeredCount, 1);
      expect(pageB.isDisposed, isFalse);
      // Probe B's scoped key directly on the bridge: re-registering the same
      // (page='B', 'shared') key must be rejected as a duplicate.
      sent.clear();
      await expectLater(
        bridge.register(
          BridgeCapability(_FakeCap('shared', replayable: true)),
          scope: CapabilityScope.page(pageId: 'B'),
        ),
        throwsA(isA<StateError>()),
        reason: 'B key survives A dispose',
      );
      // App entry survives too.
      expect(bridge.registeredIds, contains('shared'));
      expect(appOnly.isDisposed, isFalse);

      await pageB.dispose();
      await bridge.unregister('shared'); // app entry cleanup
      await bridge.dispose();
    });

    test('multiple page scopes coexist independently across full lifecycle',
        () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final pageA = PageCapabilityScope(bridge: bridge, pageId: 'A');
      final pageB = PageCapabilityScope(
        bridge: bridge,
        pageId: 'B',
        pageName: 'Page B',
      );
      await pageA.registerAll([BridgeCapability(_FakeCap('cart'))]);
      await pageB.registerAll([BridgeCapability(_FakeCap('wishlist'))]);
      expect(pageA.registeredCount, 1);
      expect(pageB.registeredCount, 1);

      await pageA.dispose();
      expect(pageB.isDisposed, isFalse);
      expect(pageB.registeredCount, 1);

      // A new cycle on A works again after dispose (fresh scope instance).
      final pageA2 = PageCapabilityScope(bridge: bridge, pageId: 'A');
      await pageA2
          .registerAll([BridgeCapability(_FakeCap('cart', replayable: true))]);
      expect(pageA2.registeredCount, 1);
      expect(pageA2.pageId, 'A');

      await pageA2.dispose();
      await pageB.dispose();
      await bridge.dispose();
    });
  });

  group('idempotence and pre-check errors (KD-2)', () {
    Future<PageCapabilityScope> seed(NativeControlPlaneBridge bridge) async {
      final scope = PageCapabilityScope(
        bridge: bridge,
        pageId: 'checkout',
        pageName: 'Checkout',
      );
      await scope.registerAll([
        BridgeCapability(_FakeCap('cart')),
        BridgeCapability(_FakeCap('pay')),
      ]);
      sent.clear();
      return scope;
    }

    test('identical capId sequence replay is a no-op (zero messages)',
        () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = await seed(bridge);

      // Fresh list objects, deep-equal capId sequence — still idempotent.
      await scope.registerAll([
        BridgeCapability(_FakeCap('cart')),
        BridgeCapability(_FakeCap('pay')),
      ]);
      expect(sent, isEmpty, reason: 'replay must send nothing');
      expect(scope.registeredCount, 2);
      await scope.dispose();
      await bridge.dispose();
    });

    test('reordered or extended sequences throw StateError with zero messages',
        () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = await seed(bridge);

      await expectLater(
        scope.registerAll([
          BridgeCapability(_FakeCap('pay')),
          BridgeCapability(_FakeCap('cart')),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(sent, isEmpty);

      await expectLater(
        scope.registerAll([
          BridgeCapability(_FakeCap('cart')),
          BridgeCapability(_FakeCap('pay')),
          BridgeCapability(_FakeCap('extra')),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(sent, isEmpty);
      expect(scope.registeredCount, 2);
      await scope.dispose();
      await bridge.dispose();
    });

    test('duplicate capId inside the input list throws in pre-check '
        '(zero messages)', () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = PageCapabilityScope(bridge: bridge, pageId: 'checkout');

      await expectLater(
        scope.registerAll([
          BridgeCapability(_FakeCap('cart')),
          BridgeCapability(_FakeCap('cart')),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(sent, isEmpty);
      expect(scope.registeredCount, 0);
      await scope.dispose();
      await bridge.dispose();
    });

    test('input overlapping registered list throws in pre-check '
        '(zero messages)', () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = await seed(bridge); // cart + pay

      await expectLater(
        scope.registerAll([
          BridgeCapability(_FakeCap('newcomer')),
          BridgeCapability(_FakeCap('cart')),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(sent, isEmpty);
      expect(scope.registeredCount, 2);
      await scope.dispose();
      await bridge.dispose();
    });

    test('registerAll after dispose throws StateError (zero messages)',
        () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = PageCapabilityScope(bridge: bridge, pageId: 'checkout');
      await scope.dispose();

      await expectLater(
        scope.registerAll([BridgeCapability(_FakeCap('cart'))]),
        throwsA(isA<StateError>()),
      );
      expect(sent, isEmpty);
      await bridge.dispose();
    });

    test('second dispose is a no-op with zero messages', () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = await seed(bridge);

      await scope.dispose();
      expect(scope.isDisposed, isTrue);
      sent.clear();
      await scope.dispose();
      expect(sent, isEmpty);
      expect(scope.registeredCount, 0);
      expect(scope.isDisposed, isTrue);
      await bridge.dispose();
    });
  });

  group('send-phase bridge failure (partial registration accepted)', () {
    test('failure on second cap wraps StateError listing registered capIds; '
        'list stays consistent', () async {
      capture(
        sent.add,
        reply: (call) async {
          if (call.method == kMethodCapabilityRegister &&
              argsOf(call)['capId'] == 'pay') {
            throw PlatformException(code: 'native_error', message: 'boom');
          }
          return null;
        },
      );
      final bridge = NativeControlPlaneBridge();
      final scope = PageCapabilityScope(
        bridge: bridge,
        pageId: 'checkout',
        pageName: 'Checkout',
      );

      Object? caught;
      try {
        await scope.registerAll([
          BridgeCapability(_FakeCap('cart')),
          BridgeCapability(_FakeCap('pay')),
          BridgeCapability(_FakeCap('extra')),
        ]);
        fail('registerAll should have thrown');
      } on StateError catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
      expect(
        '$caught',
        allOf(contains('cart'), contains('Failed')),
        reason: 'error message lists already-registered capIds',
      );

      // Partial registration is real: helper list matches what actually
      // landed on the bridge.
      expect(scope.registeredCount, 1);
      expect(scope.isDisposed, isFalse);

      // Dispose only removes what was actually registered.
      sent.clear();
      await scope.dispose();
      final unregisters = calls(kMethodCapabilityUnregister);
      expect(unregisters, hasLength(1));
      expect(argsOf(unregisters.single), {
        'capId': 'cart',
        'scope': 'page',
        'pageId': 'checkout',
      });
      await bridge.dispose();
    });
  });

  group('registeredCount / isDisposed consistency (KD-5 data source)', () {
    test('tracks full lifecycle step by step', () async {
      capture(sent.add);
      final bridge = NativeControlPlaneBridge();
      final scope = PageCapabilityScope(bridge: bridge, pageId: 'checkout');

      expect(scope.registeredCount, 0);
      expect(scope.isDisposed, isFalse);
      await scope.registerAll([BridgeCapability(_FakeCap('cart'))]);
      expect(scope.registeredCount, 1);
      await scope.registerAll([BridgeCapability(_FakeCap('cart'))]); // replay
      expect(scope.registeredCount, 1);
      await scope.dispose();
      expect(scope.registeredCount, 0);
      expect(scope.isDisposed, isTrue);
      await bridge.dispose();
    });
  });
}

/// Fake page capability. With [replayable] (default false) it owns a
/// broadcast stream like a real capability; with `replayable: true` its
/// events stream is `Stream.empty()`, used where a fresh BridgeCapability is
/// needed for an id whose events were already collected once
/// ([BridgeCapability] is single-subscription, D2).
class _FakeCap implements Capability {
  _FakeCap(this.id, {bool replayable = false})
      : _events = replayable ? null : StreamController<DebugEvent>.broadcast();

  @override
  final String id;

  /// Non-null only when the capability owns a live broadcast stream.
  final StreamController<DebugEvent>? _events;

  @override
  List<Resource> get resources => [
        Resource(
          method: 'GET',
          path: ['pages', id],
          description: 'page state',
          handler: (ctx) async => {'ok': true},
        ),
      ];

  @override
  List<Command> get commands => [];

  @override
  Map<String, Object?> state() => {'connected': true};

  @override
  Stream<DebugEvent> get events =>
      _events?.stream ?? const Stream<DebugEvent>.empty();
}
