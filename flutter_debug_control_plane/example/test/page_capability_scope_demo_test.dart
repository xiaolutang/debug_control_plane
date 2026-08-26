import 'package:debug_control_plane/debug_control_plane.dart'
    show Capability, Command, DebugEvent, Resource;
import 'package:debug_control_plane_acceptance_example/main.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_controller.dart';
import 'package:debug_control_plane_acceptance_example/src/android_native_plane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart';
import 'package:flutter_test/flutter_test.dart';

/// R003-FB002 widget tests (contract KD-4).
///
/// Channel outgoing messages are captured via
/// TestDefaultBinaryMessenger.setMockMethodCallHandler replying success
/// (FB001 helper-test precedent). App-level controller injection follows
/// acceptance_app_test.dart; plane endpoint is a placeholder — no real HTTP.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const demoChannel = MethodChannel('debug_control_plane/page_scope_demo');
  late TestDefaultBinaryMessenger messenger;
  late List<MethodCall> sent;

  /// Capture all outgoing messages on both channels, replying success.
  void captureAll(void Function(MethodCall) sink) {
    for (final channel in const [MethodChannel(kMethodChannel), demoChannel]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        sink(call);
        return null;
      });
    }
  }

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    sent = <MethodCall>[];
    captureAll(sent.add);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(const MethodChannel(kMethodChannel),
        (call) async => throw MissingPluginException(call.method));
    messenger.setMockMethodCallHandler(demoChannel,
        (call) async => throw MissingPluginException(call.method));
  });

  List<MethodCall> calls(String method) =>
      sent.where((c) => c.method == method).toList();

  Map<String, Object?> argsOf(MethodCall call) =>
      (call.arguments as Map).cast<String, Object?>();

  Future<AcceptanceController> pumpApp(WidgetTester tester) async {
    final controller = AcceptanceController();
    await tester.pumpWidget(AcceptanceApp(controller: controller));
    await tester.pump();
    return controller;
  }

  /// Drain pending microtasks/timers of the widget under test on the real
  /// event loop (the channel mocks reply synchronously, but _leave's
  /// await chain still needs real-loop turns to reach Navigator.pop).
  Future<void> drain(WidgetTester tester) async {
    // Two rounds are needed: the first runAsync turn completes the awaited
    // channel mock replies, the second lets _leave reach Navigator.pop.
    for (var i = 0; i < 2; i++) {
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
    }
  }

  void setPhoneViewport(WidgetTester tester) {
    // component_renders gate: render at phone size 390x844 (contract Hard
    // Gates mechanism — physical size + dpr, reset via addTearDown).
    const dpr = 3.0;
    tester.view.physicalSize = const Size(390 * dpr, 844 * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
  }

  Future<void> openPage(WidgetTester tester, String pageId) async {
    final entry = find.text(pageId == pageAId ? 'Open page A' : 'Open page B');
    await tester.ensureVisible(entry);
    await tester.pump();
    await tester.tap(entry, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  Finder idFinder(String identifier) =>
      find.byKey(ValueKey<String>(identifier));

  /// ensureVisible + tap — the acceptance home ListView keeps lower entries
  /// off-screen at the default test surface.
  Future<void> tapId(WidgetTester tester, String identifier) async {
    final finder = idFinder(identifier);
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder, warnIfMissed: false);
    await drain(tester);
  }

  group('stable identifiers', () {
    testWidgets('home exposes open_button / refresh_tools_button once each',
        (tester) async {
      final controller = await pumpApp(tester);

      expect(idFinder('acceptance.page_scope.open_button'), findsOneWidget);
      expect(
          idFinder('acceptance.page_scope.refresh_tools_button'),
          findsOneWidget);
      // Semantics twin channel carries the same identifier value.
      expect(find.bySemanticsLabel('acceptance.page_scope.open_button'),
          findsOneWidget);
      expect(
          find.bySemanticsLabel('acceptance.page_scope.refresh_tools_button'),
          findsOneWidget);

      await tester.runAsync(controller.stop);
      controller.dispose();
    });

    testWidgets(
        'demo page exposes close_button / page_id_text / '
        'registered_count_text once each with matching semantics labels',
        (tester) async {
      final controller = await pumpApp(tester);
      setPhoneViewport(tester);
      await openPage(tester, pageAId);

      // Scroll each anchor into view first — offscreen list children are
      // not built and expose no semantics node.
      for (final identifier in const [
        'acceptance.page_scope.registered_count_text',
        'acceptance.page_scope.close_button',
        'acceptance.page_scope.page_id_text',
      ]) {
        final finder = idFinder(identifier);
        await tester.ensureVisible(finder);
        await tester.pump();
        expect(finder, findsOneWidget, reason: 'Missing $identifier');
        // Semantics twin channel: the immediate Semantics wrapper of the
        // anchor carries the identifier as its label (bySemanticsLabel only
        // matches nodes whose raw label equals the identifier exactly; text
        // children append their content to the merged label).
        Element? found;
        finder.evaluate().first.visitAncestorElements((e) {
          if (e.widget is Semantics &&
              (e.widget as Semantics).properties.label == identifier) {
            found = e;
            return false;
          }
          return true;
        });
        expect(found, isNotNull,
            reason: 'Semantics label missing for $identifier');
      }

      await tester.runAsync(controller.stop);
      controller.dispose();
    });
  });

  group('scenario 1: page_register_on_open (structure layer)', () {
    testWidgets('page A registers its two capabilities and renders state',
        (tester) async {
      final controller = await pumpApp(tester);
      setPhoneViewport(tester);

      // Act per AcceptanceSpec steps: tap open_button → visible → expect_value.
      await tapId(tester, 'acceptance.page_scope.open_button');

      // expect_visible: page_id_text shows the business-passed pageId.
      expect(
        find.descendant(
          of: idFinder('acceptance.page_scope.page_id_text'),
          matching: find.text(pageAId),
        ),
        findsOneWidget,
      );

      final registers = calls('capability.register')
          .where((c) => argsOf(c)['pageId'] == pageAId)
          .toList();
      expect(registers.map((c) => argsOf(c)['capId']).toList(),
          pageCapabilityIds);
      for (final call in registers) {
        expect(argsOf(call)['scope'], 'page');
      }

      // expect_value: registered_count_text mirrors
      // PageCapabilityScope.registeredCount == 2.
      expect(
        find.descendant(
          of: idFinder('acceptance.page_scope.registered_count_text'),
          matching: find.text('2 registered'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.runAsync(controller.stop);
      controller.dispose();
    });

    testWidgets('page B likewise registers under its own scope',
        (tester) async {
      final controller = await pumpApp(tester);
      setPhoneViewport(tester);
      sent.clear();

      await openPage(tester, pageBId);

      expect(
        find.descendant(
          of: idFinder('acceptance.page_scope.page_id_text'),
          matching: find.text(pageBId),
        ),
        findsOneWidget,
      );
      final pageRegisters = calls('capability.register')
          .where((c) => argsOf(c)['scope'] == 'page');
      expect(pageRegisters.map((c) => argsOf(c)['pageId']),
          everyElement(pageBId));
      expect(pageRegisters, hasLength(pageCapabilityIds.length));
      expect(
        find.descendant(
          of: idFinder('acceptance.page_scope.registered_count_text'),
          matching: find.text('2 registered'),
        ),
        findsOneWidget,
      );

      await tester.runAsync(controller.stop);
      controller.dispose();
    });
  });

  group('scenario 2: page_unregister_on_close (structure layer)', () {
    testWidgets(
        'close_button sends scoped unregister payloads; re-entry re-registers '
        'with a fresh scope', (tester) async {
      final controller = await pumpApp(tester);
      setPhoneViewport(tester);
      await openPage(tester, pageAId);
      await tester.pumpAndSettle();

      // Tap close_button (AcceptanceSpec step) → back home.
      await tapId(tester, 'acceptance.page_scope.close_button');
      expect(find.text('Open page A'), findsOneWidget);

      // Exactly 2 unregister payloads, all scoped to page-a.
      var unregisters = calls('capability.unregister');
      expect(unregisters, hasLength(pageCapabilityIds.length));
      for (final call in unregisters) {
        expect(argsOf(call)['scope'], 'page');
        expect(argsOf(call)['pageId'], pageAId);
        expect(pageCapabilityIds.contains(argsOf(call)['capId']), isTrue);
      }

      // Second entry: fresh scope instance, full register list again.
      await openPage(tester, pageAId);
      await tester.pumpAndSettle();
      final pageRegisters = calls('capability.register')
          .where((c) => argsOf(c)['scope'] == 'page')
          .toList();
      expect(pageRegisters.map((c) => argsOf(c)['capId']),
          [...pageCapabilityIds, ...pageCapabilityIds]);
      expect(
        find.descendant(
          of: idFinder('acceptance.page_scope.registered_count_text'),
          matching: find.text('2 registered'),
        ),
        findsOneWidget,
      );

      // Leave again (also exercises system-pop convergence: _leave is the
      // single exit path bound to both PopScope and close_button).
      await tapId(tester, 'acceptance.page_scope.close_button');
      unregisters = calls('capability.unregister');
      expect(unregisters, hasLength(2 * pageCapabilityIds.length));
      expect(unregisters.map((c) => argsOf(c)['pageId']),
          everyElement(pageAId));

      await tester.runAsync(controller.stop);
      controller.dispose();
    });

    testWidgets(
        'refresh_tools_button lands a local request-log entry over the '
        'existing channel (no new protocol traffic)', (tester) async {
      final controller = await pumpApp(tester);

      final logSizeBefore = controller.requestLog.length;
      await tapId(tester, 'acceptance.page_scope.refresh_tools_button');

      expect(controller.requestLog.length, logSizeBefore + 1);
      expect(controller.requestLog.last.route, '/state');
      expect(controller.requestLog.last.message,
          contains('capabilityCount=${controller.capabilityCount}'));
      // Local semantics only: no extra outgoing traffic was triggered.
      expect(calls('capability.register') +
          calls('capability.unregister'), isEmpty);

      await tester.runAsync(controller.stop);
      controller.dispose();
    });
  });

  group('scenario 3: coexistence integrity', () {
    testWidgets(
        'a live page-b scope survives page A close: only page-a payloads '
        'emitted, app count intact, page-b disposed afterwards yields '
        'page-b payloads', (tester) async {
      final controller = await pumpApp(tester);
      setPhoneViewport(tester);
      final appCountBefore = controller.capabilityCount;

      // Pre-register page B through the SAME bridge/identity pathway the
      // demo uses (registry state: (page,page-b,*) entries live alongside
      // (app,*) ones — the intended BF001 multi-page demonstration).
      final sharedBridge = NativeControlPlaneBridge();
      final pageBScope = PageCapabilityScope(
        bridge: sharedBridge,
        pageId: pageBId,
        pageName: 'Page b pre-set',
      );
      await pageBScope.registerAll(pageCapabilityIds
          .map((id) => BridgeCapability(_TestPageCap(id)))
          .toList());
      sent.clear();
      await tester.pump();

      // Drive page A lifecycle through the real UI.
      await openPage(tester, pageAId);
      await tester.pumpAndSettle();
      expect(calls('capability.unregister'), isEmpty);

      await tapId(tester, 'acceptance.page_scope.close_button');

      // Only page-a scoped unregisters were emitted by closing A.
      final aUnregisters = calls('capability.unregister');
      expect(aUnregisters, hasLength(pageCapabilityIds.length));
      expect(aUnregisters.map((c) => argsOf(c)['pageId']),
          everyElement(pageAId));
      expect(aUnregisters.any((c) => argsOf(c)['scope'] == 'app'), isFalse,
          reason: 'closing a page must never emit an app-scope unregister');

      // Home app capability count untouched.
      expect(controller.capabilityCount, appCountBefore);

      // Page B scope fully alive: still reports both caps, dispose now emits
      // page-b payloads only.
      expect(pageBScope.isDisposed, isFalse);
      final bUnregisters0 = List<MethodCall>.of(calls('capability.unregister'));
      expect(
        bUnregisters0,
        hasLength(pageCapabilityIds.length),
      );
      // Teardown of the pre-set scope + shared bridge must run on the real
      // event loop: the bridge's unawaited eager state push leaves a pending
      // future that dead-locks the fake-async zone across dispose().
      await tester.runAsync(() async {
        await pageBScope.dispose();
        final bUnregisters = calls('capability.unregister');
        expect(bUnregisters, hasLength(2 * pageCapabilityIds.length));
        expect(bUnregisters.where((c) => argsOf(c)['pageId'] == pageBId),
            hasLength(pageCapabilityIds.length));
        expect(bUnregisters.where((c) => argsOf(c)['pageId'] == pageAId),
            hasLength(pageCapabilityIds.length));
        await sharedBridge.dispose();
      });
      await tester.runAsync(controller.stop);
      controller.dispose();
    });

    testWidgets(
        'open/close cycle renders without overflow or exception at 390x844',
        (tester) async {
      final controller = await pumpApp(tester);
      setPhoneViewport(tester);

      await openPage(tester, pageAId);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tapId(tester, 'acceptance.page_scope.close_button');
      expect(tester.takeException(), isNull);
      expect(find.text('Open page A'), findsOneWidget);

      await tester.runAsync(controller.stop);
      controller.dispose();
    });
  });

  group('degraded path (non-Android bridge)', () {
    testWidgets(
        'registration failure over the distinct demo channel surfaces error '
        'text, keeps count at 0 and does not crash', (tester) async {
      // Demo channel has no native peer in non-Android mode.
      messenger.setMockMethodCallHandler(demoChannel,
          (call) async => throw MissingPluginException(call.method));

      final controller = await pumpApp(tester);
      setPhoneViewport(tester);
      await openPage(tester, pageAId);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: idFinder('acceptance.page_scope.page_id_text'),
          matching: find.text(pageAId),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: idFinder('acceptance.page_scope.registered_count_text'),
          matching: find.text('0 registered'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Failed to register capability'),
          findsOneWidget);

      // Close still runs through dispose cleanly.
      await tapId(tester, 'acceptance.page_scope.close_button');
      expect(find.text('Open page A'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.runAsync(controller.stop);
      controller.dispose();
    });
  });

  group('production assembly (evaluate round-2 fix)', () {
    testWidgets(
        'AcceptanceApp wires resolveDemoBridge: an AndroidNativePlane-hosted '
        'controller hands the demo the host bridge instance, not the degraded '
        'demo-channel bridge', (tester) async {
      // Drive the REAL production construction path (_AcceptanceHomeHost.build
      // → AcceptanceHomePage(resolveDemoBridge: ...)) rather than injecting
      // AcceptanceHomePage directly — this is exactly the wiring the evaluate
      // round found broken on device.
      final sharedBridge = NativeControlPlaneBridge();
      final controller = AcceptanceController.withHost(
          AndroidNativePlane(bridge: sharedBridge));
      // Any attempt to fall back to the degraded demo-channel bridge would
      // throw here and surface as error text — making the wiring observable.
      messenger.setMockMethodCallHandler(demoChannel,
          (call) async => throw MissingPluginException(call.method));
      await tester.pumpWidget(AcceptanceApp(
        controller: controller,
        autoStart: false, // native attach is one-shot; no start in widget test
      ));
      await tester.pump();

      setPhoneViewport(tester);
      await openPage(tester, pageAId);
      await tester.pumpAndSettle();

      // Registers must travel over the HOST channel, proving the demo holds
      // the host's own bridge (the degraded fallback would have failed over
      // debug_control_plane/page_scope_demo instead).
      final hostChannelRegisters = calls('capability.register')
          .where((c) => argsOf(c)['scope'] == 'page')
          .toList();
      expect(hostChannelRegisters.map((c) => argsOf(c)['capId']),
          pageCapabilityIds);
      expect(hostChannelRegisters.map((c) => argsOf(c)['pageId']),
          everyElement(pageAId));

      // No error banner: the host path registered successfully.
      expect(find.textContaining('Failed to register capability'),
          findsNothing);
      expect(
        find.descendant(
          of: idFinder('acceptance.page_scope.registered_count_text'),
          matching: find.text('2 registered'),
        ),
        findsOneWidget,
      );

      await tapId(tester, 'acceptance.page_scope.close_button');
      expect(find.text('Open page A'), findsOneWidget);

      await tester.runAsync(() async {
        await sharedBridge.dispose();
      });
      controller.dispose();
    });
  });
}

/// Fake page capability mirroring a demo id for the pre-registered page-b
/// scope in the coexistence test (`Stream.empty()` events so fresh
/// BridgeCapability instances stay replay-safe under BridgeCapability D2).
class _TestPageCap implements Capability {
  const _TestPageCap(this.capId);

  final String capId;

  @override
  String get id => capId;

  String get _kind => capId.split('.').last;

  @override
  List<Resource> get resources => <Resource>[
        Resource(
          method: 'GET',
          path: ['pages', _kind],
          handler: (ctx) async => {'page': _kind},
        ),
      ];

  @override
  List<Command> get commands => <Command>[];

  @override
  Map<String, Object?> state() => <String, Object?>{_kind: true};

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();
}
