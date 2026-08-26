import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';

class _LegacyCapability implements Capability {
  @override
  String get id => 'legacy-capability';

  @override
  List<Resource> get resources => const <Resource>[];

  @override
  List<Command> get commands => const <Command>[];

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();

  @override
  Map<String, Object?> state() => const <String, Object?>{};
}

class _PageCapability extends _LegacyCapability implements ScopedCapability {
  _PageCapability(this.scope);

  @override
  final CapabilityScope scope;
}

void main() {
  group('CapabilityScope', () {
    test('legacy capability implementations default to app scope', () {
      final Capability capability = _LegacyCapability();

      expect(capability.scope, const CapabilityScope.app());
      expect(capability.scope.type, CapabilityScopeType.app);
      expect(capability.scope.pageId, isNull);
      expect(capability.scope.pageName, isNull);
      expect(capability.scope.revision, isNull);
    });

    test('scoped capability implementations expose explicit page scope', () {
      final scope = CapabilityScope.page(pageId: 'page-1');
      final Capability capability = _PageCapability(scope);

      expect(capability.scope, scope);
    });

    test('scope type wire names stay aligned with protocol values', () {
      expect(CapabilityScopeType.app.name, 'app');
      expect(CapabilityScopeType.page.name, 'page');
    });

    test('page scope preserves page identity metadata', () {
      final scope = CapabilityScope.page(
        pageId: 'page-1',
        pageName: 'Settings',
        revision: 7,
      );

      expect(scope.type, CapabilityScopeType.page);
      expect(scope.pageId, 'page-1');
      expect(scope.pageName, 'Settings');
      expect(scope.revision, 7);
    });

    test('page scope rejects missing pageId synchronously', () {
      expect(
        () => CapabilityScope.page(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('page scope rejects blank pageId synchronously', () {
      expect(
        () => CapabilityScope.page(pageId: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => CapabilityScope.page(pageId: '   '),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('public package entrypoint exports scope types', () {
      const appType = CapabilityScopeType.app;
      const appScope = CapabilityScope.app();
      final pageScope = CapabilityScope.page(pageId: 'page-public');

      expect(appType, CapabilityScopeType.app);
      expect(appScope.type, CapabilityScopeType.app);
      expect(pageScope.type, CapabilityScopeType.page);
    });
  });
}
