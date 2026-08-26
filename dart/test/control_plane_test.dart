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

class _RecordingAuthManager implements DebugAuthManager {
  _RecordingAuthManager({
    this.authorizeDecision = const AuthAuthorized(),
    this.requestResult = const AuthRouteOk(
      <String, Object?>{
        'ok': true,
        'requestId': 'req-1',
        'status': 'pending',
        'pairingCode': '123456',
        'expiresAt': '2026-08-20T10:05:00Z',
      },
      statusCode: 202,
    ),
    this.statusResult = const AuthRouteOk(<String, Object?>{
      'ok': true,
      'requestId': 'req-1',
      'status': 'approved',
      'expiresAt': '2026-08-20T11:00:00Z',
    }),
    this.claimResult = const AuthRouteOk(<String, Object?>{
      'ok': true,
      'token': 'test-token-not-real',
      'tokenId': 'test-token-id-not-real',
      'expiresAt': '2026-08-20T11:00:00Z',
    }),
  });

  AuthDecision authorizeDecision;
  AuthRouteResult requestResult;
  AuthRouteResult statusResult;
  AuthRouteResult claimResult;
  final List<AuthRequest> authorizeRequests = <AuthRequest>[];
  final List<Map<String, Object?>> requestBodies = <Map<String, Object?>>[];
  final List<Map<String, Object?>> statusBodies = <Map<String, Object?>>[];
  final List<Map<String, Object?>> claimBodies = <Map<String, Object?>>[];

  @override
  Future<AuthDecision> authorize(AuthRequest request) async {
    authorizeRequests.add(request);
    return authorizeDecision;
  }

  @override
  Future<Map<String, Object?>> helloAuthState(String? token) async =>
      const <String, Object?>{
        'authRequired': true,
        'authStatus': 'authorized',
      };

  @override
  Future<AuthRouteResult> requestAuthorization(
    Map<String, Object?> body,
  ) async {
    requestBodies.add(body);
    return requestResult;
  }

  @override
  Future<AuthRouteResult> authorizationStatus(
    Map<String, Object?> body,
  ) async {
    statusBodies.add(body);
    return statusResult;
  }

  @override
  Future<AuthRouteResult> claimAuthorization(
    Map<String, Object?> body,
  ) async {
    claimBodies.add(body);
    return claimResult;
  }
}

class _FakeCapability implements ScopedCapability {
  _FakeCapability({
    required this.id,
    this.resources = const <Resource>[],
    this.commands = const <Command>[],
    this.initialState = const <String, Object?>{},
    this.scope = const CapabilityScope.app(),
  });

  @override
  final String id;

  @override
  final List<Resource> resources;

  @override
  final List<Command> commands;

  final Map<String, Object?> initialState;

  @override
  final CapabilityScope scope;

  final StreamController<DebugEvent> _eventSink =
      StreamController<DebugEvent>.broadcast(sync: true);

  void emit(DebugEvent event) => _eventSink.add(event);

  @override
  Stream<DebugEvent> get events => _eventSink.stream;

  @override
  Map<String, Object?> state() => Map<String, Object?>.from(initialState);
}

RouteRequest _get(
  List<String> segments, {
  Object? request,
  Map<String, String> headers = const <String, String>{},
}) =>
    RouteRequest(
      method: 'GET',
      segments: segments,
      body: const <String, Object?>{},
      headers: headers,
      request: request,
    );

RouteRequest _post(
  List<String> segments,
  Map<String, Object?> body, {
  Map<String, String> headers = const <String, String>{},
}) =>
    RouteRequest(
      method: 'POST',
      segments: segments,
      body: body,
      headers: headers,
      request: null,
    );

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

void main() {
  group('ControlPlane register/unregister', () {
    test('duplicate register same app id throws StateError', () {
      final plane = ControlPlane(transport: _FakeTransport());
      final cap = _FakeCapability(id: 'cap-a');
      plane.register(cap);
      expect(
        () => plane.register(_FakeCapability(id: 'cap-a')),
        throwsA(isA<StateError>()),
      );
    });

    test('app and page capabilities with the same id can coexist', () async {
      final plane = ControlPlane(transport: _FakeTransport());
      plane.register(_FakeCapability(id: 'shared'));
      plane.register(_FakeCapability(
        id: 'shared',
        scope: CapabilityScope.page(pageId: 'page-a', pageName: 'Page A'),
      ));
      plane.register(_FakeCapability(
        id: 'panel',
        scope: CapabilityScope.page(pageId: 'page-a'),
      ));
      plane.register(_FakeCapability(
        id: 'panel',
        scope: CapabilityScope.page(pageId: 'page-b'),
      ));

      final result = await plane.dispatch(_get(const ['hello']));
      final caps = result.body['registeredCapabilities'] as List<Object?>;
      expect(caps, hasLength(4));
      expect(
        caps.map((e) => (e as Map<String, Object?>)['id']),
        <String>['shared', 'shared', 'panel', 'panel'],
      );
      expect((caps[0] as Map<String, Object?>)['scope'], 'app');
      expect((caps[1] as Map<String, Object?>)['scope'], 'page');
      expect((caps[1] as Map<String, Object?>)['pageId'], 'page-a');
      expect((caps[1] as Map<String, Object?>)['pageName'], 'Page A');
      expect((caps[1] as Map<String, Object?>)['scopeRevision'], 2);
    });

    test('duplicate page scoped key throws without replacing handler',
        () async {
      final plane = ControlPlane(transport: _FakeTransport());
      plane.register(_FakeCapability(
        id: 'panel',
        scope: CapabilityScope.page(pageId: 'page-a'),
        resources: [
          Resource(
            method: 'GET',
            path: const ['panel'],
            handler: (_) async => const <String, Object?>{'hit': 'first'},
          ),
        ],
      ));

      expect(
        () => plane.register(_FakeCapability(
          id: 'panel',
          scope: CapabilityScope.page(pageId: 'page-a'),
          resources: [
            Resource(
              method: 'GET',
              path: const ['panel'],
              handler: (_) async => const <String, Object?>{'hit': 'second'},
            ),
          ],
        )),
        throwsA(isA<StateError>()),
      );

      final result = await plane.dispatch(_get(
        const ['panel'],
        headers: const <String, String>{
          'X-DCP-Capability-Id': 'panel',
          'X-DCP-Capability-Scope': 'page',
          'X-DCP-Page-Id': 'page-a',
        },
      ));
      expect(result.statusCode, 200);
      expect(result.body['hit'], 'first');
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

    test('legacy unregister only removes app scoped capability', () async {
      final plane = ControlPlane(transport: _FakeTransport());
      plane.register(_FakeCapability(
        id: 'shared',
        resources: [
          Resource(
            method: 'GET',
            path: const ['shared'],
            handler: (_) async => const <String, Object?>{'scope': 'app'},
          ),
        ],
      ));
      plane.register(_FakeCapability(
        id: 'shared',
        scope: CapabilityScope.page(pageId: 'page-a'),
        resources: [
          Resource(
            method: 'GET',
            path: const ['shared'],
            handler: (_) async => const <String, Object?>{'scope': 'page-a'},
          ),
        ],
      ));

      plane.unregister('shared');

      final app = await plane.dispatch(_get(
        const ['shared'],
        headers: const <String, String>{
          'X-DCP-Capability-Id': 'shared',
          'X-DCP-Capability-Scope': 'app',
        },
      ));
      final page = await plane.dispatch(_get(
        const ['shared'],
        headers: const <String, String>{
          'X-DCP-Capability-Id': 'shared',
          'X-DCP-Capability-Scope': 'page',
          'X-DCP-Page-Id': 'page-a',
        },
      ));
      expect(app.statusCode, 404);
      expect(page.statusCode, 200);
      expect(page.body['scope'], 'page-a');
    });

    test('scoped unregister removes only matching page and subscription',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      final app = _FakeCapability(id: 'shared');
      final pageA = _FakeCapability(
        id: 'shared',
        scope: CapabilityScope.page(pageId: 'page-a'),
      );
      final pageB = _FakeCapability(
        id: 'shared',
        scope: CapabilityScope.page(pageId: 'page-b'),
      );
      plane.register(app);
      plane.register(pageA);
      plane.register(pageB);
      transport.broadcasts.clear();

      plane.unregisterScoped(
        scope: CapabilityScope.page(pageId: 'page-a'),
        capabilityId: 'shared',
      );
      pageA.emit(const DebugEvent(
        type: 'page-a-event',
        sequence: -1,
        payload: <String, Object?>{},
      ));
      pageB.emit(const DebugEvent(
        type: 'page-b-event',
        sequence: -1,
        payload: <String, Object?>{},
      ));
      app.emit(const DebugEvent(
        type: 'app-event',
        sequence: -1,
        payload: <String, Object?>{},
      ));
      await Future<void>.delayed(Duration.zero);

      final hello = await plane.dispatch(_get(const ['hello']));
      final caps = hello.body['registeredCapabilities'] as List<Object?>;
      expect(caps, hasLength(2));
      expect(
        caps.map((e) => (e as Map<String, Object?>)['pageId']).toList(),
        <Object?>[null, 'page-b'],
      );
      expect(transport.broadcasts.map((e) => e.type), contains('page-b-event'));
      expect(transport.broadcasts.map((e) => e.type), contains('app-event'));
      expect(
        transport.broadcasts.map((e) => e.type),
        isNot(contains('page-a-event')),
      );
    });
  });

  group('ControlPlane capability dispatch', () {
    test('legacy dispatch without selector remains first match wins', () async {
      final plane = ControlPlane(transport: _FakeTransport());
      plane.register(_FakeCapability(
        id: 'shared',
        resources: [
          Resource(
            method: 'GET',
            path: const ['same'],
            handler: (_) async => const <String, Object?>{'hit': 'app'},
          ),
        ],
      ));
      plane.register(_FakeCapability(
        id: 'shared',
        scope: CapabilityScope.page(pageId: 'page-a'),
        resources: [
          Resource(
            method: 'GET',
            path: const ['same'],
            handler: (_) async => const <String, Object?>{'hit': 'page-a'},
          ),
        ],
      ));

      final result = await plane.dispatch(_get(const ['same']));
      expect(result.statusCode, 200);
      expect(result.body['hit'], 'app');
    });

    test('selector headers dispatch to the requested page capability',
        () async {
      final plane = ControlPlane(transport: _FakeTransport());
      plane.register(_FakeCapability(
        id: 'panel',
        scope: CapabilityScope.page(pageId: 'page-a'),
        resources: [
          Resource(
            method: 'GET',
            path: const ['same'],
            handler: (_) async => const <String, Object?>{'hit': 'page-a'},
          ),
        ],
      ));
      plane.register(_FakeCapability(
        id: 'panel',
        scope: CapabilityScope.page(pageId: 'page-b'),
        resources: [
          Resource(
            method: 'GET',
            path: const ['same'],
            handler: (_) async => const <String, Object?>{'hit': 'page-b'},
          ),
        ],
      ));

      final result = await plane.dispatch(_get(
        const ['same'],
        headers: const <String, String>{
          'X-DCP-Capability-Id': 'panel',
          'X-DCP-Capability-Scope': 'page',
          'X-DCP-Page-Id': 'page-b',
        },
      ));

      expect(result.statusCode, 200);
      expect(result.body['hit'], 'page-b');
    });

    test(
        'selector returns gone for missing page and expired for stale revision',
        () async {
      final plane = ControlPlane(transport: _FakeTransport());
      plane.register(_FakeCapability(
        id: 'panel',
        scope: CapabilityScope.page(pageId: 'page-a'),
        resources: [
          Resource(
            method: 'GET',
            path: const ['same'],
            handler: (_) async => const <String, Object?>{'ok': true},
          ),
        ],
      ));

      final expired = await plane.dispatch(_get(
        const ['same'],
        headers: const <String, String>{
          'X-DCP-Capability-Id': 'panel',
          'X-DCP-Capability-Scope': 'page',
          'X-DCP-Page-Id': 'page-a',
          'X-DCP-Scope-Revision': '999',
        },
      ));
      final gone = await plane.dispatch(_get(
        const ['same'],
        headers: const <String, String>{
          'X-DCP-Capability-Id': 'panel',
          'X-DCP-Capability-Scope': 'page',
          'X-DCP-Page-Id': 'page-missing',
        },
      ));

      expect(expired.statusCode, 409);
      expect(expired.body['ok'], false);
      expect(expired.body['code'], 'capability_scope_expired');
      expect(
        expired.body['message'],
        'Capability scope mirror expired. Refresh /hello before invoking tools.',
      );
      expect(gone.statusCode, 410);
      expect(gone.body['ok'], false);
      expect(gone.body['code'], 'page_capability_gone');
      expect(
        gone.body['message'],
        'Page capability is no longer available. Refresh /hello before invoking tools.',
      );
    });

    test('selector target exists but path mismatch returns not_found',
        () async {
      final plane = ControlPlane(transport: _FakeTransport());
      plane.register(_FakeCapability(
        id: 'panel',
        scope: CapabilityScope.page(pageId: 'page-a'),
        resources: [
          Resource(
            method: 'GET',
            path: const ['exists'],
            handler: (_) async => const <String, Object?>{'ok': true},
          ),
        ],
      ));

      final result = await plane.dispatch(_get(
        const ['missing'],
        headers: const <String, String>{
          'X-DCP-Capability-Id': 'panel',
          'X-DCP-Capability-Scope': 'page',
          'X-DCP-Page-Id': 'page-a',
        },
      ));

      expect(result.statusCode, 404);
      expect(result.body['code'], 'not_found');
    });

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

      final result =
          await plane.dispatch(_post(const ['foo'], const <String, Object?>{}));
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
              throw const RouteFailure(
                  409, 'real_controller_active', 'Real controller is active.');
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

    test('auth denied beats selector gone and expired checks', () async {
      final auth = _RecordingAuthManager(
        authorizeDecision: DebugAuth.invalidToken(),
      );
      final plane = ControlPlane(
        transport: _FakeTransport(),
        authManager: auth,
      );
      plane.register(_FakeCapability(
        id: 'panel',
        scope: CapabilityScope.page(pageId: 'page-a'),
        resources: [
          Resource(
            method: 'GET',
            path: const ['same'],
            handler: (_) async => const <String, Object?>{'ok': true},
          ),
        ],
      ));

      final result = await plane.dispatch(_get(
        const ['same'],
        headers: const <String, String>{
          'Authorization': 'Bearer bad-token',
          'X-DCP-Capability-Id': 'panel',
          'X-DCP-Capability-Scope': 'page',
          'X-DCP-Page-Id': 'page-missing',
          'X-DCP-Scope-Revision': '999',
        },
      ));

      expect(result.statusCode, 401);
      expect(result.body['code'], 'invalid_token');
      expect(result.body['code'], isNot('page_capability_gone'));
      expect(result.body['code'], isNot('capability_scope_expired'));
      expect(auth.authorizeRequests.single.segments, const ['same']);
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
        sequence:
            -1, // capability-side pre-sequence; plane assigns the real one
        payload: <String, Object?>{'activeSource': 'virtual'},
      ));
      await Future<void>.delayed(Duration.zero);

      expect(received.length, 1);
      expect(received.first.type, 'controller_state_changed');
      expect(received.first.sequence, 1); // register emitted sequence 0
      expect(received.first.payload, {'activeSource': 'virtual'});
      // Broadcast to transport also fired.
      expect(transport.broadcasts.length, 2);
      expect(transport.broadcasts.last.type, 'controller_state_changed');
      expect(transport.broadcasts.last.sequence, 1);

      await sub.cancel();
    });

    test('register and unregister emit capability_scope_changed events',
        () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      final cap = _FakeCapability(
        id: 'panel',
        scope: CapabilityScope.page(pageId: 'page-a', pageName: 'Page A'),
      );
      plane.register(cap);

      expect(transport.broadcasts.single.type, 'capability_scope_changed');
      expect(transport.broadcasts.single.sequence, 0);
      expect(transport.broadcasts.single.payload, <String, Object?>{
        'change': 'registered',
        'scope': 'page',
        'capabilityId': 'panel',
        'pageId': 'page-a',
        'pageName': 'Page A',
        'scopeRevision': 1,
      });

      plane.unregisterScoped(
        scope: CapabilityScope.page(pageId: 'page-a'),
        capabilityId: 'panel',
      );

      expect(transport.broadcasts.last.type, 'capability_scope_changed');
      expect(transport.broadcasts.last.payload['change'], 'unregistered');
      expect(transport.broadcasts.last.payload['scopeRevision'], 2);
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

      expect(received.map((e) => e.sequence), [1, 2]);
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
    test('/hello aggregates appMeta + serverInfo + protocolVersion', () async {
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
      expect(result.body['protocolVersion'], kDebugControlPlaneProtocolVersion);
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
      expect(result.body['protocolVersion'], kDebugControlPlaneProtocolVersion);
      // serverInfo is always spread (transport owns it).
      expect(result.body['serverHost'], '127.0.0.1');
      expect(result.body['serverPort'], 0);
      expect(result.body['localIps'], <String>[]);
      // Without appMeta, app/capabilities are absent.
      expect(result.body.containsKey('app'), isFalse);
      expect(result.body.containsKey('capabilities'), isFalse);
      expect(result.body['eventsEndpoint'], '/events');
    });

    test('/state aggregates only app capability state() fields', () async {
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
      plane.register(_FakeCapability(
        id: 'page-cap',
        scope: CapabilityScope.page(pageId: 'page-a'),
        initialState: const <String, Object?>{
          'activeSource': 'page',
          'pageOnly': true,
        },
      ));

      final result = await plane.dispatch(_get(const ['state']));
      expect(result.statusCode, 200);
      // `/state` mirrors the legacy flat aggregate (no top-level `ok`) — see
      // ControlPlane._handleState contract-alignment note.
      expect(result.body.containsKey('ok'), isFalse);
      expect(result.body['activeSource'], 'virtual');
      expect(result.body['profileRevision'], 1);
      expect(result.body['lastError'], null);
      expect(result.body.containsKey('pageOnly'), isFalse);
    });

    test('/hello top-level state only includes app capabilities', () async {
      final plane = ControlPlane(transport: _FakeTransport());
      plane.register(_FakeCapability(
        id: 'app',
        initialState: const <String, Object?>{'shared': 'app'},
      ));
      plane.register(_FakeCapability(
        id: 'page',
        scope: CapabilityScope.page(pageId: 'page-a'),
        initialState: const <String, Object?>{
          'shared': 'page',
          'pageOnly': true,
        },
      ));

      final result = await plane.dispatch(_get(const ['hello']));

      expect(result.body['shared'], 'app');
      expect(result.body.containsKey('pageOnly'), isFalse);
      expect(result.body['registeredCapabilities'], isA<List>());
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

  group('ControlPlane auth routes', () {
    test('auth disabled keeps hello state and capability behavior', () async {
      final transport = _FakeTransport();
      final plane = ControlPlane(transport: transport);
      var handlerCalls = 0;
      plane.register(_FakeCapability(
        id: 'cap-a',
        resources: [
          Resource(
            method: 'GET',
            path: const ['foo'],
            handler: (ctx) async {
              handlerCalls += 1;
              return <String, Object?>{'ok': true};
            },
          ),
        ],
        initialState: const <String, Object?>{'activeSource': 'none'},
      ));

      final hello = await plane.dispatch(_get(const ['hello']));
      final state = await plane.dispatch(_get(const ['state']));
      final resource = await plane.dispatch(_get(const ['foo']));

      expect(hello.body['registeredCapabilities'], isA<List>());
      expect(hello.body['activeSource'], 'none');
      expect(state.body['activeSource'], 'none');
      expect(resource.statusCode, 200);
      expect(handlerCalls, 1);
    });

    test('unauthorized hello returns minimal bootstrap without state',
        () async {
      final auth = _RecordingAuthManager(
        authorizeDecision: DebugAuth.authorizationRequired(),
      );
      final transport = _FakeTransport();
      final plane = ControlPlane(
        transport: transport,
        authManager: auth,
        appMeta: () => const <String, Object?>{
          'app': 'example-app',
          'deviceId': 'dev-x',
          'deviceName': 'Virtual Debug',
          'platform': 'ios',
          'capabilities': <String>['must-not-leak'],
        },
      );
      plane.register(_FakeCapability(
        id: 'cap-a',
        initialState: const <String, Object?>{'activeSource': 'none'},
      ));

      final result = await plane.dispatch(_get(const ['hello']));

      expect(result.statusCode, 200);
      expect(result.body['protocolVersion'], 1);
      expect(result.body['app'], 'example-app');
      expect(result.body['deviceId'], 'dev-x');
      expect(result.body['eventsEndpoint'], '/events');
      expect(result.body['authRequired'], true);
      expect(result.body['authStatus'], 'authorization_required');
      expect(result.body['authEndpoints'], const <String, String>{
        'request': '/auth/request',
        'status': '/auth/status',
        'claim': '/auth/claim',
      });
      expect(result.body.containsKey('registeredCapabilities'), isFalse);
      expect(result.body.containsKey('activeSource'), isFalse);
      expect(result.body.containsKey('capabilities'), isFalse);
      expect(result.body.containsKey('token'), isFalse);
      expect(auth.authorizeRequests.single.routeClass,
          AuthRouteClass.helloBootstrap);
    });

    test('authorized hello returns full hello with auth state', () async {
      final auth = _RecordingAuthManager();
      final plane = ControlPlane(
        transport: _FakeTransport(),
        authManager: auth,
      );
      plane.register(_FakeCapability(
        id: 'cap-a',
        initialState: const <String, Object?>{'activeSource': 'none'},
      ));

      final result = await plane.dispatch(_get(
        const ['hello'],
        headers: const <String, String>{
          'Authorization': 'Bearer test-token-not-real',
        },
      ));

      expect(result.body['registeredCapabilities'], isA<List>());
      expect(result.body['activeSource'], 'none');
      expect(result.body['authRequired'], true);
      expect(result.body['authStatus'], 'authorized');
      expect(auth.authorizeRequests.single.bearerToken, 'test-token-not-real');
    });

    test('unauthorized state does not expose aggregate state', () async {
      final auth = _RecordingAuthManager(
        authorizeDecision: DebugAuth.tokenExpired(),
      );
      var stateCalls = 0;
      final plane = ControlPlane(
        transport: _FakeTransport(),
        authManager: auth,
      );
      plane.register(_FakeCapability(
        id: 'cap-a',
        initialState: const <String, Object?>{'activeSource': 'none'},
      ));
      plane.register(_FakeCapability(
        id: 'cap-b',
        resources: const <Resource>[],
        commands: const <Command>[],
      ));

      final result = await plane.dispatch(_get(const ['state']));

      expect(result.statusCode, 401);
      expect(result.body['code'], 'token_expired');
      expect(result.body.containsKey('activeSource'), isFalse);
      expect(auth.authorizeRequests.single.segments, const ['state']);
      expect(stateCalls, 0);
    });

    test('unauthorized capability routes do not invoke handlers', () async {
      final auth = _RecordingAuthManager(
        authorizeDecision: DebugAuth.invalidToken(),
      );
      var resourceCalls = 0;
      var commandCalls = 0;
      final plane = ControlPlane(
        transport: _FakeTransport(),
        authManager: auth,
      );
      plane.register(_FakeCapability(
        id: 'cap-a',
        resources: [
          Resource(
            method: 'GET',
            path: const ['items'],
            handler: (ctx) async {
              resourceCalls += 1;
              return <String, Object?>{'ok': true};
            },
          ),
        ],
        commands: [
          Command(
            method: 'POST',
            path: const ['invoke'],
            handler: (ctx) async {
              commandCalls += 1;
              return <String, Object?>{'ok': true};
            },
          ),
        ],
      ));

      final resource = await plane.dispatch(_get(
        const ['items'],
        headers: const <String, String>{'Authorization': 'Bearer bad-token'},
      ));
      final command = await plane.dispatch(_post(
        const ['invoke'],
        const <String, Object?>{'x': 1},
        headers: const <String, String>{'Authorization': 'Bearer bad-token'},
      ));

      expect(resource.statusCode, 401);
      expect(command.statusCode, 401);
      expect(resource.body['code'], 'invalid_token');
      expect(command.body['code'], 'invalid_token');
      expect(resourceCalls, 0);
      expect(commandCalls, 0);
      expect(auth.authorizeRequests.first.bearerToken, 'bad-token');
      expect(auth.authorizeRequests.last.body, const <String, Object?>{'x': 1});
    });

    test('auth bootstrap routes use manager and beat capabilities', () async {
      final auth = _RecordingAuthManager(
        requestResult: const AuthRouteOk(
          <String, Object?>{
            'ok': true,
            'requestId': 'req-1',
            'status': 'pending',
            'pairingCode': '123456',
            'expiresAt': '2026-08-20T10:05:00Z',
          },
          statusCode: 202,
        ),
      );
      var shadowCalls = 0;
      final plane = ControlPlane(
        transport: _FakeTransport(),
        authManager: auth,
      );
      plane.register(_FakeCapability(
        id: 'shadow',
        commands: [
          Command(
            method: 'POST',
            path: const ['auth', 'request'],
            handler: (ctx) async {
              shadowCalls += 1;
              return <String, Object?>{'shadow': true};
            },
          ),
        ],
      ));

      final request = await plane.dispatch(
        _post(const [
          'auth',
          'request'
        ], const <String, Object?>{
          'clientNonce': 'nonce',
        }),
      );
      final status = await plane.dispatch(
        _post(const [
          'auth',
          'status'
        ], const <String, Object?>{
          'requestId': 'req-1',
        }),
      );
      final claim = await plane.dispatch(
        _post(const [
          'auth',
          'claim'
        ], const <String, Object?>{
          'requestId': 'req-1',
        }),
      );

      expect(request.statusCode, 202);
      expect(request.body['status'], 'pending');
      expect(status.statusCode, 200);
      expect(status.body['status'], 'approved');
      expect(claim.statusCode, 200);
      expect(claim.body['token'], 'test-token-not-real');
      expect(shadowCalls, 0);
      expect(auth.requestBodies.single['clientNonce'], 'nonce');
    });

    test('auth bootstrap denied results preserve status and body shape',
        () async {
      final auth = _RecordingAuthManager(
        statusResult: const AuthRouteDenied(
          statusCode: 403,
          code: 'authorization_denied',
          message: 'Debug authorization was denied.',
        ),
        claimResult: const AuthRouteDenied(
          statusCode: 401,
          code: 'token_revoked',
          message: 'Debug authorization token was revoked.',
        ),
      );
      final plane = ControlPlane(
        transport: _FakeTransport(),
        authManager: auth,
      );

      final denied = await plane.dispatch(
        _post(const ['auth', 'status'], const <String, Object?>{}),
      );
      final revoked = await plane.dispatch(
        _post(const ['auth', 'claim'], const <String, Object?>{}),
      );

      expect(denied.statusCode, 403);
      expect(denied.body, const <String, Object?>{
        'ok': false,
        'code': 'authorization_denied',
        'message': 'Debug authorization was denied.',
      });
      expect(revoked.statusCode, 401);
      expect(revoked.body['code'], 'token_revoked');
    });

    test('direct events dispatch is sensitive when auth is enabled', () async {
      final auth = _RecordingAuthManager(
        authorizeDecision: DebugAuth.authorizationRequired(),
      );
      final plane = ControlPlane(
        transport: _FakeTransport(),
        authManager: auth,
      );

      final result = await plane.dispatch(_get(const ['events']));

      expect(result.statusCode, 401);
      expect(result.body['code'], 'authorization_required');
      expect(
          auth.authorizeRequests.single.routeClass, AuthRouteClass.sensitive);
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
