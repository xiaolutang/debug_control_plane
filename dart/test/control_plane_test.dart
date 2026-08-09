import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';

// -----------------------------------------------------------------------------
// Fakes
// -----------------------------------------------------------------------------

class _FakeTransport implements Transport {
  _FakeTransport();

  Uri? boundUri;
  bool closed = false;
  bool listenInstalled = false;
  final List<DebugEvent> broadcasts = <DebugEvent>[];
  Map<String, Object?> serverInfoValue = const <String, Object?>{
    'serverHost': '127.0.0.1',
    'serverPort': 0,
    'localIps': <String>[],
  };

  @override
  Future<Uri?> bind({required Object address, required int port}) async {
    boundUri = Uri(scheme: 'http', host: '$address', port: port);
    return boundUri;
  }

  @override
  void listen(Future<RouteResult> Function(RouteRequest req) handler) {
    listenInstalled = true;
  }

  @override
  void broadcast(DebugEvent event) {
    broadcasts.add(event);
  }

  @override
  Future<Map<String, Object?>> serverInfo(Object? request) async {
    return Map<String, Object?>.from(serverInfoValue);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeCapability implements Capability {
  _FakeCapability({
    required this.id,
    this.resources = const <Resource>[],
    this.commands = const <Command>[],
    this.initialState = const <String, Object?>{},
  });

  @override
  final String id;

  @override
  final List<Resource> resources;

  @override
  final List<Command> commands;

  final Map<String, Object?> initialState;

  final StreamController<DebugEvent> _eventSink =
      StreamController<DebugEvent>.broadcast(sync: true);

  void emit(DebugEvent event) => _eventSink.add(event);

  @override
  Stream<DebugEvent> get events => _eventSink.stream;

  @override
  Map<String, Object?> state() => Map<String, Object?>.from(initialState);
}

RouteRequest _get(List<String> segments, {Object? request}) => RouteRequest(
      method: 'GET',
      segments: segments,
      body: const <String, Object?>{},
      request: request,
    );

RouteRequest _post(List<String> segments, Map<String, Object?> body) =>
    RouteRequest(
      method: 'POST',
      segments: segments,
      body: body,
      request: null,
    );

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

void main() {
  group('ControlPlane register/unregister', () {
    test('duplicate register same id throws StateError', () {
      final plane = ControlPlane(transport: _FakeTransport());
      final cap = _FakeCapability(id: 'cap-a');
      plane.register(cap);
      expect(
        () => plane.register(_FakeCapability(id: 'cap-a')),
        throwsA(isA<StateError>()),
      );
    });

    test('register then unregister removes routes', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      final cap = _FakeCapability(
        id: 'cap-a',
        resources: [
          Resource(
            method: 'GET',
            path: const ['foo'],
            handler: (ctx) async => <String, Object?>{'ok': true, 'r': 'foo'},
          ),
        ],
      );
      plane.register(cap);

      final before = await plane.dispatch(_get(const ['foo']));
      expect(before.statusCode, 200);

      plane.unregister('cap-a');

      final after = await plane.dispatch(_get(const ['foo']));
      expect(after.statusCode, 404);
      expect(after.body['code'], 'not_found');
      expect(after.body['ok'], false);
    });
  });

  group('ControlPlane capability dispatch', () {
    test('GET declared resource returns 200 + handler body', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(
        id: 'cap-a',
        resources: [
          Resource(
            method: 'GET',
            path: const ['foo'],
            handler: (ctx) async => <String, Object?>{'ok': true, 'r': 'foo'},
          ),
        ],
      ));

      final result = await plane.dispatch(_get(const ['foo']));
      expect(result.statusCode, 200);
      expect(result.body, {'ok': true, 'r': 'foo'});
    });

    test('GET declared resource with {id} captures path param', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      Map<String, String>? captured;
      plane.register(_FakeCapability(
        id: 'cap-a',
        resources: [
          Resource(
            method: 'GET',
            path: const ['profiles', '{id}'],
            handler: (ctx) async {
              captured = ctx.pathParams;
              return <String, Object?>{'ok': true, 'id': ctx.pathParams['id']};
            },
          ),
        ],
      ));

      final result = await plane.dispatch(_get(const ['profiles', 'abc']));
      expect(result.statusCode, 200);
      expect(result.body, {'ok': true, 'id': 'abc'});
      expect(captured, {'id': 'abc'});
    });

    test('POST declared command returns 200 + handler body', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(
        id: 'cap-a',
        commands: [
          Command(
            method: 'POST',
            path: const ['bar'],
            handler: (ctx) async => <String, Object?>{
              'ok': true,
              'echo': ctx.body['v'],
            },
          ),
        ],
      ));

      final result = await plane
          .dispatch(_post(const ['bar'], <String, Object?>{'v': 42}));
      expect(result.statusCode, 200);
      expect(result.body, {'ok': true, 'echo': 42});
    });

    test('undeclared path returns 404 {ok:false, code:not_found}', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);

      final result = await plane.dispatch(_get(const ['nope']));
      expect(result.statusCode, 404);
      expect(result.body['ok'], false);
      expect(result.body['code'], 'not_found');
      expect(result.body['message'], isA<String>());
    });

    test('method mismatch on same path returns 404', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(
        id: 'cap-a',
        resources: [
          Resource(
            method: 'GET',
            path: const ['foo'],
            handler: (ctx) async => <String, Object?>{'ok': true},
          ),
        ],
      ));

      final result = await plane
          .dispatch(_post(const ['foo'], const <String, Object?>{}));
      expect(result.statusCode, 404);
      expect(result.body['code'], 'not_found');
    });

    test('handler throwing RouteFailure maps to its statusCode/code/message',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(
        id: 'cap-a',
        commands: [
          Command(
            method: 'POST',
            path: const ['boom'],
            handler: (ctx) async {
              throw const RouteFailure(409, 'real_controller_active',
                  'Real controller is active.');
            },
          ),
        ],
      ));

      final result = await plane
          .dispatch(_post(const ['boom'], const <String, Object?>{}));
      expect(result.statusCode, 409);
      expect(result.body['ok'], false);
      expect(result.body['code'], 'real_controller_active');
      expect(result.body['message'], 'Real controller is active.');
    });

    test('handler throwing plain Exception maps to 500 internal_error',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(
        id: 'cap-a',
        resources: [
          Resource(
            method: 'GET',
            path: const ['kaboom'],
            handler: (ctx) async {
              throw StateError('boom');
            },
          ),
        ],
      ));

      final result = await plane.dispatch(_get(const ['kaboom']));
      expect(result.statusCode, 500);
      expect(result.body['ok'], false);
      expect(result.body['code'], 'internal_error');
      expect(result.body['message'], contains('Bad state: boom'));
    });
  });

  group('ControlPlane event bus', () {
    test('capability emit propagates type/sequence/payload to the bus',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      final cap = _FakeCapability(id: 'cap-a');
      plane.register(cap);

      final received = <DebugEvent>[];
      final sub = plane.eventBus.listen(received.add);

      cap.emit(const DebugEvent(
        type: 'controller_state_changed',
        sequence: -1, // capability-side pre-sequence; plane assigns the real one
        payload: <String, Object?>{'activeSource': 'virtual'},
      ));
      await Future<void>.delayed(Duration.zero);

      expect(received.length, 1);
      expect(received.first.type, 'controller_state_changed');
      expect(received.first.sequence, 0); // monotonic from 0
      expect(received.first.payload, {'activeSource': 'virtual'});
      // Broadcast to transport also fired.
      expect(transport.broadcasts.length, 1);
      expect(transport.broadcasts.first.type, 'controller_state_changed');
      expect(transport.broadcasts.first.sequence, 0);

      await sub.cancel();
    });

    test('multiple emits produce monotonic sequences', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      final cap = _FakeCapability(id: 'cap-a');
      plane.register(cap);

      final received = <DebugEvent>[];
      final sub = plane.eventBus.listen(received.add);

      cap.emit(const DebugEvent(
        type: 'a',
        sequence: -1,
        payload: <String, Object?>{},
      ));
      cap.emit(const DebugEvent(
        type: 'b',
        sequence: -1,
        payload: <String, Object?>{},
      ));
      await Future<void>.delayed(Duration.zero);

      expect(received.map((e) => e.sequence), [0, 1]);
      await sub.cancel();
    });

    test('DebugEvent.toJson spreads payload after type/sequence', () {
      const event = DebugEvent(
        type: 'controller_state_changed',
        sequence: 5,
        payload: <String, Object?>{'activeSource': 'virtual', 'profileId': 'p'},
      );
      expect(event.toJson(), {
        'type': 'controller_state_changed',
        'sequence': 5,
        'activeSource': 'virtual',
        'profileId': 'p',
      });
    });

    test('DebugEvent.toString includes type/sequence', () {
      const event = DebugEvent(
        type: 'error',
        sequence: 7,
        payload: <String, Object?>{'k': 'v'},
      );
      final s = event.toString();
      expect(s, contains('error'));
      expect(s, contains('7'));
    });
  });

  group('ControlPlane system routes', () {
    test('/hello aggregates appMeta + serverInfo + protocolVersion',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(
        transport: transport,
        appMeta: () => <String, Object?>{
          'app': 'example-app',
          'deviceId': 'dev-x',
          'deviceName': 'Virtual Debug',
          'platform': 'ios',
          'capabilities': <String>[
            'virtual_input',
            'profiles',
            'sse',
            'protocol_events',
          ],
        },
      );
      transport.serverInfoValue = const <String, Object?>{
        'serverHost': '127.0.0.1',
        'serverPort': 18080,
        'localIps': <String>['192.168.1.5'],
      };
      plane.register(_FakeCapability(
        id: 'gamepad',
        resources: [
          Resource(
            method: 'GET',
            path: const ['profiles'],
            handler: (ctx) async => <String, Object?>{'ok': true},
          ),
        ],
        commands: [
          Command(
            method: 'POST',
            path: const ['input'],
            handler: (ctx) async => <String, Object?>{'ok': true},
          ),
        ],
        initialState: const <String, Object?>{'activeSource': 'none'},
      ));

      final result = await plane.dispatch(_get(const ['hello']));
      expect(result.statusCode, 200);
      // appMeta spread (capabilities come from appMeta, not from registry).
      expect(result.body['app'], 'example-app');
      expect(result.body['deviceId'], 'dev-x');
      expect(result.body['deviceName'], 'Virtual Debug');
      expect(result.body['platform'], 'ios');
      expect(result.body['protocolVersion'],
          kDebugControlPlaneProtocolVersion);
      expect(result.body['capabilities'], <String>[
        'virtual_input',
        'profiles',
        'sse',
        'protocol_events',
      ]);
      // serverInfo spread (transport-provided discovery fields).
      expect(result.body['serverHost'], '127.0.0.1');
      expect(result.body['serverPort'], 18080);
      expect(result.body['localIps'], ['192.168.1.5']);
      expect(result.body['eventsEndpoint'], '/events');
      expect(result.body['profileRevision'], 1);
      // No introspection of declared routes (byte contract: no declared*).
      expect(result.body.containsKey('declaredResources'), isFalse);
      expect(result.body.containsKey('declaredCommands'), isFalse);
      // State aggregation spread into /hello.
      expect(result.body['activeSource'], 'none');
    });

    test('/hello without appMeta emits protocolVersion + serverInfo only',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(id: 'cap-a'));

      final result = await plane.dispatch(_get(const ['hello']));
      expect(result.statusCode, 200);
      expect(result.body['protocolVersion'],
          kDebugControlPlaneProtocolVersion);
      // serverInfo is always spread (transport owns it).
      expect(result.body['serverHost'], '127.0.0.1');
      expect(result.body['serverPort'], 0);
      expect(result.body['localIps'], <String>[]);
      // Without appMeta, app/capabilities are absent.
      expect(result.body.containsKey('app'), isFalse);
      expect(result.body.containsKey('capabilities'), isFalse);
      expect(result.body['eventsEndpoint'], '/events');
    });

    test('/state aggregates every capability state() fields', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      plane.register(_FakeCapability(
        id: 'cap-a',
        initialState: const <String, Object?>{
          'activeSource': 'virtual',
          'profileRevision': 1,
        },
      ));
      plane.register(_FakeCapability(
        id: 'cap-b',
        initialState: const <String, Object?>{'lastError': null},
      ));

      final result = await plane.dispatch(_get(const ['state']));
      expect(result.statusCode, 200);
      // `/state` mirrors the legacy flat aggregate (no top-level `ok`) — see
      // ControlPlane._handleState contract-alignment note.
      expect(result.body.containsKey('ok'), isFalse);
      expect(result.body['activeSource'], 'virtual');
      expect(result.body['profileRevision'], 1);
      expect(result.body['lastError'], null);
    });

    test('/events (without transport hijack) returns 200 introspection',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);

      final result = await plane.dispatch(_get(const ['events']));
      expect(result.statusCode, 200);
      expect(result.body['ok'], true);
      expect(result.body['eventsEndpoint'], '/events');
    });
  });

  group('ControlPlane lifecycle', () {
    test('start wires handler and binds; stop closes transport', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);

      final uri = await plane.start(address: '0.0.0.0', port: 18080);
      expect(uri, isNotNull);
      expect(uri!.port, 18080);
      expect(transport.closed, isFalse);

      // start() installs the transport handler + binds the URI.
      expect(transport.listenInstalled, isTrue);

      plane.register(_FakeCapability(
        id: 'cap-a',
        resources: [
          Resource(
            method: 'GET',
            path: const ['foo'],
            handler: (ctx) async => <String, Object?>{'ok': true},
          ),
        ],
      ));
      final result = await plane.dispatch(_get(const ['foo']));
      expect(result.statusCode, 200);

      await plane.stop();
      expect(transport.closed, isTrue);
    });
  });

  group('RouteFailure', () {
    test('implements Exception and stringifies', () {
      const f = RouteFailure(404, 'not_found', 'x');
      expect(f, isA<Exception>());
      expect(f.statusCode, 404);
      expect(f.code, 'not_found');
      expect(f.message, 'x');
      expect(f.toString(), contains('not_found'));
    });
  });

  group('RouteResult factories', () {
    test('ok wraps body with 200', () {
      final r = RouteResult.ok({'ok': true, 'x': 1});
      expect(r.statusCode, 200);
      expect(r.body, {'ok': true, 'x': 1});
    });

    test('error builds {ok:false, code, message} + extra', () {
      final r = RouteResult.error(409, 'real_controller_active', 'boom',
          extra: const <String, Object?>{'activeSource': 'real'});
      expect(r.statusCode, 409);
      expect(r.body, {
        'ok': false,
        'code': 'real_controller_active',
        'message': 'boom',
        'activeSource': 'real',
      });
    });
  });
}
