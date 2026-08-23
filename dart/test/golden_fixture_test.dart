import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';

import 'fixtures/normalize.dart';

// R025-BF003-1: Dart-side golden fixture assertions.
//
// `../../fixtures/` (repo root, relative to the dart package) is the
// language-agnostic source of truth (PROTOCOL.md's executable projection).
// The Dart ControlPlane + HttpSseTransport must produce wire output matching
// the fixtures — content-level for `.json` (parsed-field comparison with
// `$$unstable:<reason>` normalization) and byte-level for `.bin`.
//
// Kotlin mirror: `kotlin/src/test/.../GoldenFixtureTest.kt` (same scenarios,
// same fixtures). Fixture is the truth: tweaking a fixture field must turn
// BOTH suites red.

const String _markerPrefix = '\$\$unstable:';

final Directory _fixturesDir =
    Directory('${Directory.current.path}/../fixtures');

/// A capability whose declarations/state exactly match hello.json's neutral
/// placeholders (cap-alpha: descriptions present on every declaration).
class _AlphaCap implements Capability {
  @override
  String get id => 'cap-alpha';

  @override
  List<Resource> get resources => <Resource>[
        Resource(
          method: 'GET',
          path: const ['items'],
          description: '示例资源（中性占位，非业务语义约束）',
          handler: (_) async => const <String, Object?>{},
        ),
        Resource(
          method: 'GET',
          path: const ['items', '{id}'],
          description: '含 {id} 单段占位符的资源',
          handler: (_) async => const <String, Object?>{},
        ),
      ];

  @override
  List<Command> get commands => <Command>[
        Command(
          method: 'POST',
          path: const ['invoke'],
          description: '示例命令（占位）',
          handler: (_) async => const <String, Object?>{},
        ),
      ];

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();

  @override
  Map<String, Object?> state() =>
      const <String, Object?>{'aKey1': 'value1', 'aKey2': true};
}

/// cap-beta from hello.json: no descriptions anywhere (the `description` key
/// must be omitted from the wire schema when null).
class _BetaCap implements Capability {
  @override
  String get id => 'cap-beta-no-description';

  @override
  List<Resource> get resources => <Resource>[
        Resource(
          method: 'GET',
          path: const ['nested', '{leaf}'],
          handler: (_) async => const <String, Object?>{},
        ),
      ];

  @override
  List<Command> get commands => <Command>[
        Command(
          method: 'POST',
          path: const ['nested', 'submit'],
          handler: (_) async => const <String, Object?>{},
        ),
      ];

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();

  @override
  Map<String, Object?> state() => const <String, Object?>{};
}

/// state-with-cap.json overlay capability: later registration wins on
/// `aKey2`, adds `aKey3`/`aKey4`.
class _OverlayCap implements Capability {
  @override
  String get id => 'cap-gamma-overlay';

  @override
  List<Resource> get resources => const <Resource>[];

  @override
  List<Command> get commands => const <Command>[];

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();

  @override
  Map<String, Object?> state() =>
      const <String, Object?>{'aKey2': 1, 'aKey3': true, 'aKey4': null};
}

void main() {
  HttpOverrides.global = null;

  setUpAll(() {
    expect(_fixturesDir.existsSync(), isTrue,
        reason: 'fixtures dir must exist at ${_fixturesDir.path}');
  });

  group('/hello vs fixtures/hello.json', () {
    test('content matches golden (normalized)', () async {
      final fixture = _loadJson('hello.json');
      final body = await _helloBody(<Capability>[
        _AlphaCap(),
        _BetaCap(),
      ]);

      // Hard contract first (acceptance criteria): protocolVersion=1,
      // eventsEndpoint, profileRevision, path is a JSON array.
      expect(body['protocolVersion'], 1);
      expect(body['eventsEndpoint'], '/events');
      expect(body['profileRevision'], 1);
      final caps = body['registeredCapabilities'] as List;
      final alphaRes = (caps[0] as Map)['resources'] as List;
      expect((alphaRes[1] as Map)['path'], ['items', '{id}']);

      expect(
        normalizedEquals(normalize(fixture), normalize(body)),
        isTrue,
        reason: 'hello body must match fixtures/hello.json (normalized)',
      );
    });

    test('unstable reasons in fixture are from the closed set', () {
      for (final reason in _unstableReasons(_loadJson('hello.json'))) {
        expect(kUnstableReasons.contains(reason), isTrue,
            reason: 'reason "$reason" must be in the closed set');
      }
    });
  });

  group('/state vs fixtures/state-*.json', () {
    test('empty plane returns {} with no ok wrapper', () async {
      final body = await _stateBody(<Capability>[]);
      // fixtures/state-empty.json carries no comparable keys beyond
      // _fixture_meta — the shape contract IS the assertion.
      expect(body, isEmpty);
      expect(body.containsKey('ok'), isFalse);
    });

    test('with capabilities matches golden (normalized)', () async {
      final fixture = _loadJson('state-with-cap.json');
      final body = await _stateBody(<Capability>[
        _AlphaCap(),
        _BetaCap(),
        _OverlayCap(),
      ]);

      // Hard constraint: no top-level ok (§1.3) + flat aggregation with
      // later-registration-wins on aKey2.
      expect(body.containsKey('ok'), isFalse);
      expect(body['aKey1'], 'value1');
      expect(body['aKey2'], 1);
      expect(body['aKey3'], isTrue);
      expect(body.containsKey('aKey4'), isTrue);
      expect(body['aKey4'], isNull);

      expect(
        normalizedEquals(normalize(fixture), normalize(body)),
        isTrue,
        reason: 'state body must match fixtures/state-with-cap.json',
      );
    });
  });

  group('SSE vs fixtures/sse-*.bin (byte level)', () {
    test('first frame is byte-identical to sse-connected.bin', () async {
      final expected = _loadBytes('sse-connected.bin');
      final (transport, uri) = await _startPlane(<Capability>[]);
      addTearDown(transport.close);
      final client = HttpClient();
      try {
        final response = await client.getUrl(uri!.resolve('/events')).then(
              (r) => r.close(),
            );
        final actual = <int>[];
        await for (final chunk in response) {
          actual.addAll(chunk);
          if (actual.length >= expected.length) break;
        }
        expect(
          actual,
          expected,
          reason: 'SSE first frame must be byte-identical to '
              'sse-connected.bin',
        );
      } finally {
        client.close(force: true);
      }
    });

    test('event frame is byte-identical to sse-event-frame.bin', () async {
      final expected = _loadBytes('sse-event-frame.bin');
      final (transport, uri) = await _startPlane(<Capability>[]);
      addTearDown(transport.close);

      final client = HttpClient();
      try {
        final response = await client.getUrl(uri!.resolve('/events')).then(
              (r) => r.close(),
            );
        final received = <int>[];
        final sub = response.listen(received.addAll);
        // Wait for the connected preamble (13 bytes).
        await _waitFor(() => received.length >= 13, 'connected preamble');
        // sequence=0 assumption documented by the fixture README: this is the
        // plane's FIRST event (the bus counter starts at 0).
        transport.broadcast(const DebugEvent(
          type: 'sample_state_changed',
          sequence: 0,
          payload: <String, Object?>{'aKey1': 'value1'},
        ));
        await _waitFor(
          () => received.length >= 13 + expected.length,
          'event frame',
        );
        await sub.cancel();
        final actual = received.sublist(13, 13 + expected.length);
        expect(
          actual,
          expected,
          reason: 'SSE event frame must be byte-identical to '
              'sse-event-frame.bin',
        );
      } finally {
        client.close(force: true);
      }
    });
  });

  group('error contract vs fixtures/error-*.json', () {
    test('404 matches golden', () async {
      final fixture = _loadJson('error-404.json') as Map;
      final (status, body) = await _request('GET', '/nope');
      expect(status, 404);
      expect(normalizedEquals(fixture, body), isTrue);
    });

    test('400 matches golden (message variants allowed)', () async {
      final fixture = _loadJson('error-400.json') as Map;
      final (status, body) = await _request(
        'POST',
        '/submit',
        rawBody: 'not-json{{',
        caps: <Capability>[_PostCap()],
      );
      expect(status, 400);
      // The fixture takes the readObject failure path; all three message
      // variants are legal (fixture _fixture_meta.message_variants).
      final variants = (fixture['_fixture_meta'] as Map)['message_variants']
          as List;
      expect(variants, contains(body['message']));
      expect(normalizedEquals(fixture, body), isTrue);
    });

    test('500 matches golden with unstable-marker normalization', () async {
      final fixture = _loadJson('error-500.json') as Map;
      final (status, body) = await _request(
        'POST',
        '/boom500',
        jsonBody: jsonEncode(<String, Object?>{}),
        caps: <Capability>[_BoomCap()],
      );
      expect(status, 500);
      // message is $$unstable:exception-toString — normalized comparison.
      expect(
        normalizedEquals(normalize(fixture), normalize(body)),
        isTrue,
        reason: '500 body must match fixtures/error-500.json (normalized)',
      );
    });
  });

  group('route declaration vs fixtures/route-decl.json', () {
    test('single-capability projection matches golden', () async {
      final fixture = _loadJson('route-decl.json');
      final body = await _helloBody(<Capability>[_SampleCapability()]);
      final caps = body['registeredCapabilities'] as List;
      expect(caps, hasLength(1));
      final actual = caps[0];

      // Hard constraint: path is a JSON array (§2.3 cross-language pitfall).
      final res = (actual as Map)['resources'] as List;
      expect((res[1] as Map)['path'], ['items', '{id}']);

      expect(
        normalizedEquals(normalize(fixture), normalize(actual)),
        isTrue,
        reason: 'capability declaration must match fixtures/route-decl.json',
      );
    });
  });

  group('discovery-python.json drift guard', () {
    test('constants match the python source text', () {
      final fixture = _loadJson('discovery-python.json') as Map;
      expect((fixture['lan_scan'] as Map)['port'], 18080);
      expect((fixture['lan_scan'] as Map)['timeout_seconds'], 2.5);
      expect((fixture['lan_scan'] as Map)['concurrency'], 64);

      // Cross-check the python source so fixture and code cannot drift apart.
      final pythonRoot =
          Directory('${Directory.current.path}/../python');
      final lanScan = File(
        '${pythonRoot.path}/debug_control_plane/device_discovery/'
        'discovery/lan_scan.py',
      ).readAsStringSync();
      final endpoint = File(
        '${pythonRoot.path}/debug_control_plane/device_discovery/'
        'endpoint.py',
      ).readAsStringSync();
      expect(lanScan.contains('DEFAULT_PORT = 18080'), isTrue,
          reason: 'lan_scan.py must hard-code DEFAULT_PORT = 18080');
      expect(lanScan.contains('DEFAULT_PROBE_TIMEOUT = 2.5'), isTrue);
      expect(lanScan.contains('DEFAULT_MAX_WORKERS = 64'), isTrue);
      expect(endpoint.contains('default_port: int = 18080'), isTrue);

      // Handshake hard constraints (§5).
      final handshake = fixture['hello_handshake'] as Map;
      expect(handshake['protocolVersion'], 1);
      expect(handshake['eventsEndpoint'], '/events');
    });
  });

  group('auth fixtures (R001) presence and closed-set guard', () {
    test('auth fixture files exist and carry _fixture_meta', () {
      const authFixtures = <String>[
        'hello-auth-required.json',
        'hello-auth-authorized.json',
        'error-401-authorization-required.json',
        'error-401-token-expired.json',
        'error-403-authorization-denied.json',
        'auth-claim-approved.json',
      ];
      for (final name in authFixtures) {
        final fixture = _loadJson(name) as Map;
        expect(fixture.containsKey('_fixture_meta'), isTrue,
            reason: '$name must carry _fixture_meta (fixture contract)');
        expect(fixture['_fixture_meta'], isA<Map>());
      }
    });

    test('auth fixture unstable reasons are from the closed set', () {
      const authFixtures = <String>[
        'hello-auth-required.json',
        'hello-auth-authorized.json',
      ];
      for (final name in authFixtures) {
        for (final reason in _unstableReasons(_loadJson(name))) {
          expect(kUnstableReasons.contains(reason), isTrue,
              reason: 'reason "$reason" in $name must be in the closed set');
        }
      }
    });

    test('auth claim fixture token is an obvious fake test value', () {
      final fixture = _loadJson('auth-claim-approved.json') as Map;
      expect(fixture['token'], 'test-token-not-real');
      expect((fixture['tokenId'] as String).contains('not-real'), isTrue);
    });
  });

  group('normalizer parity contract (vs FixtureNormalize.kt)', () {
    test('skips underscore keys', () {
      final expected = jsonDecode('{"_fixture_meta":{"x":1},"ok":false}');
      final actual = jsonDecode('{"ok":false,"_other":"skip me"}');
      expect(normalizedEquals(expected, actual), isTrue);
    });

    test('replaces unstable markers with type guards', () {
      const expectedRaw = '{"serverPort":"\$\$unstable:bound-port"}';
      final expected = jsonDecode(expectedRaw);
      expect(
        normalizedEquals(expected, jsonDecode('{"serverPort":18123}')),
        isTrue,
      );
      expect(
        normalizedEquals(expected, jsonDecode('{"serverPort":"18123"}')),
        isFalse,
      );
      expect(normalizedEquals(expected, jsonDecode('{}')), isFalse);
    });

    test('rejects unknown reason', () {
      const expectedRaw = '{"x":"\$\$unstable:no-such-reason"}';
      final expected = jsonDecode(expectedRaw);
      expect(
        () => normalizedEquals(expected, jsonDecode('{"x":1}')),
        throwsA(isA<StateError>()),
      );
    });

    test('detects real drift (fixture is truth)', () {
      final expected =
          jsonDecode('{"code":"not_found","message":"Endpoint was not found."}');
      final actual =
          jsonDecode('{"code":"not_found","message":"Different message."}');
      expect(normalizedEquals(expected, actual), isFalse);
    });
  });
}

// -----------------------------------------------------------------------------
// Test helpers
// -----------------------------------------------------------------------------

class _PostCap implements Capability {
  @override
  String get id => 'golden-post';

  @override
  List<Resource> get resources => const <Resource>[];

  @override
  List<Command> get commands => <Command>[
        Command(
          method: 'POST',
          path: const ['submit'],
          handler: (_) async => const <String, Object?>{},
        ),
      ];

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();

  @override
  Map<String, Object?> state() => const <String, Object?>{};
}

class _BoomCap implements Capability {
  @override
  String get id => 'golden-boom';

  @override
  List<Resource> get resources => const <Resource>[];

  @override
  List<Command> get commands => <Command>[
        Command(
          method: 'POST',
          path: const ['boom500'],
          handler: (_) async => throw StateError('boom for golden test'),
        ),
      ];

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();

  @override
  Map<String, Object?> state() => const <String, Object?>{};
}

/// Declares exactly fixtures/route-decl.json (neutral placeholders).
class _SampleCapability implements Capability {
  @override
  String get id => 'sample-capability';

  @override
  List<Resource> get resources => <Resource>[
        Resource(
          method: 'GET',
          path: const ['items'],
          description: '无占位符的静态路径（单段）',
          handler: (_) async => const <String, Object?>{},
        ),
        Resource(
          method: 'GET',
          path: const ['items', '{id}'],
          description: '含 {id} 单段占位符（matchPath 捕获 pathParams.id）',
          handler: (_) async => const <String, Object?>{},
        ),
        Resource(
          method: 'GET',
          path: const ['nested', 'deep', '{leaf}'],
          handler: (_) async => const <String, Object?>{},
        ),
      ];

  @override
  List<Command> get commands => <Command>[
        Command(
          method: 'POST',
          path: const ['invoke'],
          handler: (_) async => const <String, Object?>{},
        ),
        Command(
          method: 'POST',
          path: const ['items', '{id}', 'submit'],
          description: 'POST 也可带占位符（与 resources 同语义）',
          handler: (_) async => const <String, Object?>{},
        ),
      ];

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();

  @override
  Map<String, Object?> state() => const <String, Object?>{};
}

/// Collects `$$unstable:` reasons from a fixture (any nesting depth).
List<String> _unstableReasons(Object? fixture) {
  final reasons = <String>[];
  void walk(Object? v) {
    if (v is Map) {
      v.values.forEach(walk);
    } else if (v is List) {
      v.forEach(walk);
    } else if (v is String && v.startsWith(_markerPrefix)) {
      reasons.add(v.substring(_markerPrefix.length));
    }
  }

  walk(fixture);
  return reasons;
}

Object _loadJson(String name) =>
    jsonDecode(File('${_fixturesDir.path}/$name').readAsStringSync());

List<int> _loadBytes(String name) =>
    File('${_fixturesDir.path}/$name').readAsBytesSync();

/// Start a real ControlPlane + HttpSseTransport with the given capabilities,
/// appMeta supplying exactly the $$unstable:app-injected keys hello.json
/// marks, on an OS-picked port.
Future<(HttpSseTransport, Uri?)> _startPlane(List<Capability> caps) async {
  final transport = HttpSseTransport();
  final plane = ControlPlane(
    transport: transport,
    appMeta: () => const <String, Object?>{
      'app': 'dart-golden-test',
      'deviceId': 'dart-vm-test',
      'deviceName': 'Dart VM golden',
      'platform': 'dart',
      'capabilities': <String>['golden'],
      'hardwareName': 'Dart Test Machine',
      'machineId': 'dart-test-1',
    },
  );
  for (final cap in caps) {
    plane.register(cap);
  }
  final uri = await plane.start(
    address: InternetAddress.loopbackIPv4,
    port: 0,
  );
  return (transport, uri);
}

Future<Map<String, Object?>> _helloBody(List<Capability> caps) async {
  final (_, uri) = await _startPlaneWithTeardown(caps);
  final (status, body) = await _rawRequest('GET', uri!, '/hello');
  expect(status, 200);
  return body;
}

Future<Map<String, Object?>> _stateBody(List<Capability> caps) async {
  final (_, uri) = await _startPlaneWithTeardown(caps);
  final (status, body) = await _rawRequest('GET', uri!, '/state');
  expect(status, 200);
  return body;
}

Future<(int, Map<String, Object?>)> _request(
  String method,
  String path, {
  String? rawBody,
  Object? jsonBody,
  List<Capability> caps = const <Capability>[],
}) async {
  final (_, uri) = await _startPlaneWithTeardown(caps);
  return _rawRequest(method, uri!, path,
      rawBody: rawBody, jsonBody: jsonBody);
}

/// Start a plane and register its teardown (leak guard: every helper above
/// spins a fresh plane on an OS-picked port — without teardown the bound
/// socket and the plane's timer keep alive until the test suite ends).
Future<(HttpSseTransport, Uri?)> _startPlaneWithTeardown(
    List<Capability> caps) async {
  final (transport, uri) = await _startPlane(caps);
  addTearDown(transport.close);
  return (transport, uri);
}

Future<(int, Map<String, Object?>)> _rawRequest(
  String method,
  Uri base,
  String path, {
  String? rawBody,
  Object? jsonBody,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (jsonBody != null || rawBody != null) {
      request.headers.contentType = ContentType.json;
      // Write pre-encoded text either way: an empty Dart map {} would encode
      // as "{}" correctly, but dart:io HttpClient drops a zero-length body —
      // write at least one byte so the plane's readObject path sees a body.
      request.write(rawBody ?? (jsonBody is String ? jsonBody : jsonEncode(jsonBody!)));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (
      response.statusCode,
      Map<String, Object?>.from(jsonDecode(text) as Map),
    );
  } finally {
    client.close(force: true);
  }
}

Future<void> _waitFor(bool Function() predicate, String what,
    [Duration timeout = const Duration(seconds: 5)]) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
