import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';

// R020-FF001 / FF002 contract: `/hello.registeredCapabilities` aggregates the
// runtime capability registry (id + resources/commands schema), and
// `Resource`/`Command` accept an optional `description` (backward compatible).
//
// Covers mobile design §4.1/§4.3 + AC3/AC4/AC5:
//  * AC3 — `/hello` exposes `registeredCapabilities` as an array (new optional
//    field; existing R019 fields preserved).
//  * AC4 — register/unregister mutates `registeredCapabilities`.
//  * AC5 — old `Resource(method, path, handler)` (no description) compiles and
//    the schema omits the `description` key when null.

// -----------------------------------------------------------------------------
// Fakes (mirror control_plane_test.dart style; kept local to avoid leaking
// test helpers across files).
// -----------------------------------------------------------------------------

class _FakeTransport implements Transport {
  Map<String, Object?> serverInfoValue = const <String, Object?>{
    'serverHost': '127.0.0.1',
    'serverPort': 0,
    'localIps': <String>[],
  };

  @override
  Future<Uri?> bind({required Object address, required int port}) async {
    return Uri(scheme: 'http', host: '$address', port: port);
  }

  @override
  void listen(Future<RouteResult> Function(RouteRequest req) handler) {}

  @override
  void broadcast(DebugEvent event) {}

  @override
  Future<Map<String, Object?>> serverInfo(Object? request) async {
    return Map<String, Object?>.from(serverInfoValue);
  }

  @override
  Future<void> close() async {}
}

class _FakeCapability implements Capability {
  _FakeCapability({
    required this.id,
    this.resources = const <Resource>[],
    this.commands = const <Command>[],
  });

  @override
  final String id;

  @override
  final List<Resource> resources;

  @override
  final List<Command> commands;

  final StreamController<DebugEvent> _eventSink =
      StreamController<DebugEvent>.broadcast(sync: true);

  @override
  Stream<DebugEvent> get events => _eventSink.stream;

  @override
  Map<String, Object?> state() => const <String, Object?>{};
}

RouteRequest _get(List<String> segments) =>
    RouteRequest(method: 'GET', segments: segments, body: const {}, request: null);

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

void main() {
  group('registeredCapabilities (FF001/FF002)', () {
    test('AC3: /hello exposes registeredCapabilities as an array', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(id: 'cap-a'));

      final result = await plane.dispatch(_get(const ['hello']));

      expect(result.statusCode, 200);
      expect(result.body.containsKey('registeredCapabilities'), isTrue);
      expect(result.body['registeredCapabilities'], isA<List>());
    });

    test('AC3: R019 fields preserved (capabilities/deviceId/deviceName)',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(
        transport: transport,
        appMeta: () => <String, Object?>{
          'deviceId': 'dev-x',
          'deviceName': 'Virtual Debug',
          'capabilities': <String>['virtual_input', 'profiles'],
        },
      );
      plane.register(_FakeCapability(id: 'gamepad'));

      final result = await plane.dispatch(_get(const ['hello']));

      // R019 contract fields unchanged.
      expect(result.body['deviceId'], 'dev-x');
      expect(result.body['deviceName'], 'Virtual Debug');
      expect(result.body['capabilities'], <String>['virtual_input', 'profiles']);
      // New field coexists.
      expect(result.body['registeredCapabilities'], isA<List>());
    });

    test('AC4: register a capability -> its schema appears; unregister -> gone',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);

      // Before registration: empty array.
      var result = await plane.dispatch(_get(const ['hello']));
      expect(result.body['registeredCapabilities'], <Object?>[]);

      // Register a capability with declared resources + commands.
      plane.register(_FakeCapability(
        id: 'gamepad',
        resources: [
          Resource(
            method: 'GET',
            path: const ['profiles'],
            handler: (ctx) async => const <String, Object?>{},
            description: '列出可用手柄 profile',
          ),
        ],
        commands: [
          Command(
            method: 'POST',
            path: const ['virtual', 'connect'],
            handler: (ctx) async => const <String, Object?>{},
            description: '连接虚拟手柄',
          ),
        ],
      ));

      result = await plane.dispatch(_get(const ['hello']));
      final registered =
          result.body['registeredCapabilities'] as List<Object?>;
      expect(registered, hasLength(1));
      final gamepad = registered.single as Map<String, Object?>;
      expect(gamepad['id'], 'gamepad');
      // Resource schema.
      final resources = gamepad['resources'] as List<Object?>;
      expect(resources, hasLength(1));
      final res = resources.single as Map<String, Object?>;
      expect(res['method'], 'GET');
      expect(res['path'], <String>['profiles']);
      expect(res['description'], '列出可用手柄 profile');
      // Command schema.
      final commands = gamepad['commands'] as List<Object?>;
      expect(commands, hasLength(1));
      final cmd = commands.single as Map<String, Object?>;
      expect(cmd['method'], 'POST');
      expect(cmd['path'], <String>['virtual', 'connect']);
      expect(cmd['description'], '连接虚拟手柄');

      // Unregister -> schema gone, array empty again.
      plane.unregister('gamepad');
      result = await plane.dispatch(_get(const ['hello']));
      expect(result.body['registeredCapabilities'], <Object?>[]);
    });

    test(
        'AC5: old Resource(method, path, handler) (no description) compiles and '
        'the schema omits the description key', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(
        id: 'legacy',
        resources: [
          // Backward-compatible positional/named ctor without description.
          Resource(
            method: 'GET',
            path: const ['legacy', '{id}'],
            handler: (ctx) async => const <String, Object?>{},
          ),
        ],
        commands: [
          Command(
            method: 'POST',
            path: const ['legacy', 'invoke'],
            handler: (ctx) async => const <String, Object?>{},
          ),
        ],
      ));

      final result = await plane.dispatch(_get(const ['hello']));
      final registered =
          result.body['registeredCapabilities'] as List<Object?>;
      expect(registered, hasLength(1));
      final legacy = registered.single as Map<String, Object?>;
      // Resource schema: method/path present, description key omitted.
      final res = (legacy['resources'] as List<Object?>).single
          as Map<String, Object?>;
      expect(res['method'], 'GET');
      expect(res['path'], <String>['legacy', '{id}']);
      expect(res.containsKey('description'), isFalse);
      // Command schema: same.
      final cmd = (legacy['commands'] as List<Object?>).single
          as Map<String, Object?>;
      expect(cmd['method'], 'POST');
      expect(cmd['path'], <String>['legacy', 'invoke']);
      expect(cmd.containsKey('description'), isFalse);
    });

    test('multiple capabilities are all surfaced in registration order',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(id: 'cap-a'));
      plane.register(_FakeCapability(id: 'cap-b'));

      final result = await plane.dispatch(_get(const ['hello']));
      final registered =
          result.body['registeredCapabilities'] as List<Object?>;
      expect(registered, hasLength(2));
      final ids = registered
          .map((e) => (e as Map<String, Object?>)['id'])
          .toList();
      // LinkedHashMap iteration = insertion order.
      expect(ids, <String?>['cap-a', 'cap-b']);
    });
  });
}
