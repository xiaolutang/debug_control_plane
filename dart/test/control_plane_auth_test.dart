import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';

import 'fixtures/normalize.dart';

// R001-BF008: Dart auth golden alignment — cover the six auth fixtures from
// BF002 (fixtures/hello-auth-*.json, error-40{1,3}-*.json, auth-claim-
// approved.json) through the REAL HttpSseTransport + ControlPlane stack,
// mirroring the Kotlin ControlPlaneAuthTest semantics (same scenarios, same
// fixtures). Fixture is the truth: tweaking a fixture field must turn BOTH
// language suites red.
//
// Kotlin mirror: `kotlin/src/test/.../ControlPlaneAuthTest.kt`.

const String _kFakeToken = 'test-token-not-real';

final Directory _fixturesDir =
    Directory('${Directory.current.path}/../fixtures');

/// Configurable fake auth manager (R001-BF008.1). Tokens below are obviously
/// fake test values, never real credentials.
class _FakeAuthManager implements DebugAuthManager {
  _FakeAuthManager({
    this.authorizeDecision,
    Map<String, Object?>? helloState,
    AuthRouteResult? requestResult,
    AuthRouteResult? statusResult,
    AuthRouteResult? claimResult,
  })  : helloState = helloState ??
            const <String, Object?>{
              'authRequired': true,
              'authStatus': 'authorized',
            },
        requestResult = requestResult ??
            const AuthRouteDenied(
              statusCode: 401,
              code: 'authorization_required',
              message: 'Debug authorization is required.',
            ),
        statusResult = statusResult ??
            const AuthRouteDenied(
              statusCode: 401,
              code: 'invalid_token',
              message: 'Debug authorization token is invalid.',
            ),
        claimResult = claimResult ??
            const AuthRouteDenied(
              statusCode: 401,
              code: 'invalid_token',
              message: 'Debug authorization token is invalid.',
            );

  /// When null, authorize() grants `AuthAuthorized` (bare-mode parity).
  AuthDecision? authorizeDecision;
  final Map<String, Object?> helloState;
  final AuthRouteResult requestResult;
  final AuthRouteResult statusResult;
  final AuthRouteResult claimResult;
  final List<AuthRequest> authorizeCalls = <AuthRequest>[];

  @override
  Future<AuthDecision> authorize(AuthRequest request) async {
    authorizeCalls.add(request);
    return authorizeDecision ?? const AuthAuthorized();
  }

  @override
  Future<Map<String, Object?>> helloAuthState(String? token) async =>
      helloState;

  @override
  Future<AuthRouteResult> requestAuthorization(
    Map<String, Object?> body,
  ) async =>
      requestResult;

  @override
  Future<AuthRouteResult> authorizationStatus(
    Map<String, Object?> body,
  ) async =>
      statusResult;

  @override
  Future<AuthRouteResult> claimAuthorization(
    Map<String, Object?> body,
  ) async =>
      claimResult;
}

/// cap-alpha exactly as declared in hello-auth-authorized.json: one resource,
/// one command, both with descriptions.
class _AuthAlphaCap implements Capability {
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

void main() {
  HttpOverrides.global = null;

  setUpAll(() {
    expect(_fixturesDir.existsSync(), isTrue,
        reason: 'fixtures dir must exist at ${_fixturesDir.path}');
  });

  group('hello bootstrap vs fixtures/hello-auth-*.json', () {
    test('unauthorized hello matches hello-auth-required.json', () async {
      final fixture = _loadJson('hello-auth-required.json');
      final auth = _FakeAuthManager(
        authorizeDecision: DebugAuth.authorizationRequired(),
      );
      final (transport, uri) = await _startPlane(
        caps: <Capability>[_AuthAlphaCap()],
        auth: auth,
      );
      addTearDown(transport.close);

      final (status, body) = await _httpGet(uri!, '/hello');
      expect(status, 200);

      // Hard contract: minimal bootstrap must NOT leak capability state or
      // declarations, and must advertise the auth bootstrap endpoints.
      expect(body.containsKey('registeredCapabilities'), isFalse);
      expect(body.containsKey('aKey1'), isFalse);
      expect(body['authEndpoints'], const <String, String>{
        'request': '/auth/request',
        'status': '/auth/status',
        'claim': '/auth/claim',
      });
      expect(auth.authorizeCalls.single.routeClass,
          AuthRouteClass.helloBootstrap);

      expect(
        normalizedEquals(normalize(fixture), normalize(body)),
        isTrue,
        reason: 'unauthorized hello must match fixtures/hello-auth-required.json',
      );
    });

    test('authorized hello matches hello-auth-authorized.json', () async {
      final fixture = _loadJson('hello-auth-authorized.json');
      final auth = _FakeAuthManager();
      final (transport, uri) = await _startPlane(
        caps: <Capability>[_AuthAlphaCap()],
        auth: auth,
      );
      addTearDown(transport.close);

      final (status, body) =
          await _httpGet(uri!, '/hello', bearer: _kFakeToken);
      expect(status, 200);
      expect(body['authRequired'], true);
      expect(body['authStatus'], 'authorized');
      expect(auth.authorizeCalls.single.bearerToken, _kFakeToken);

      expect(
        normalizedEquals(normalize(fixture), normalize(body)),
        isTrue,
        reason: 'authorized hello must match fixtures/hello-auth-authorized.json',
      );
    });
  });

  group('sensitive routes vs fixtures/error-401-*.json', () {
    test('missing token on /state matches error-401-authorization-required',
        () async {
      final fixture = _loadJson('error-401-authorization-required.json');
      final auth = _FakeAuthManager(
        authorizeDecision: DebugAuth.authorizationRequired(),
      );
      final (transport, uri) = await _startPlane(
        caps: <Capability>[_AuthAlphaCap()],
        auth: auth,
      );
      addTearDown(transport.close);

      final (status, body) = await _httpGet(uri!, '/state');
      expect(status, 401);
      expect(body.containsKey('aKey1'), isFalse);
      expect(normalizedEquals(normalize(fixture), normalize(body)), isTrue);
    });

    test('expired token on /state matches error-401-token-expired', () async {
      final fixture = _loadJson('error-401-token-expired.json');
      final auth = _FakeAuthManager(
        authorizeDecision: DebugAuth.tokenExpired(),
      );
      final (transport, uri) = await _startPlane(auth: auth);
      addTearDown(transport.close);

      final (status, body) =
          await _httpGet(uri!, '/state', bearer: 'expired-test-token-not-real');
      expect(status, 401);
      expect(normalizedEquals(normalize(fixture), normalize(body)), isTrue);
    });
  });

  group('auth bootstrap routes vs fixtures', () {
    test(
        'denied /auth/request matches error-403-authorization-denied.json',
        () async {
      final fixture = _loadJson('error-403-authorization-denied.json');
      final auth = _FakeAuthManager(
        requestResult: const AuthRouteDenied(
          statusCode: 403,
          code: 'authorization_denied',
          message: 'Debug authorization was denied.',
        ),
      );
      final (transport, uri) = await _startPlane(auth: auth);
      addTearDown(transport.close);

      final (status, body) = await _httpPost(uri!, '/auth/request', const {});
      expect(status, 403);
      expect(normalizedEquals(normalize(fixture), normalize(body)), isTrue);
    });

    test('approved /auth/claim matches auth-claim-approved.json', () async {
      final fixture = _loadJson('auth-claim-approved.json');
      final auth = _FakeAuthManager(
        claimResult: const AuthRouteOk(
          <String, Object?>{
            'ok': true,
            'token': 'test-token-not-real',
            'tokenId': 'test-token-id-not-real',
            'expiresAt': '2030-01-01T00:00:00Z',
          },
        ),
      );
      final (transport, uri) = await _startPlane(auth: auth);
      addTearDown(transport.close);

      final (status, body) = await _httpPost(
        uri!,
        '/auth/claim',
        const <String, Object?>{'requestId': 'test-request-not-real'},
      );
      expect(status, 200);
      expect(normalizedEquals(normalize(fixture), normalize(body)), isTrue);
    });
  });

  group('SSE /events unauthorized (R001-BF008.2)', () {
    test('returns JSON 401 before any SSE frame and registers no subscriber',
        () async {
      final auth = _FakeAuthManager(
        authorizeDecision: DebugAuth.authorizationRequired(),
      );
      final (transport, uri) = await _startPlane(auth: auth);
      addTearDown(transport.close);

      final client = HttpClient();
      try {
        final response =
            await client.getUrl(uri!.resolve('/events')).then((r) => r.close());
        final text = await utf8.decoder.bind(response).join();
        expect(response.statusCode, 401);
        // JSON error body, NOT an SSE stream: content type must not be
        // text/event-stream and the first byte must not be the `: connected`
        // preamble.
        expect(response.headers.contentType?.mimeType, 'application/json');
        expect(text.startsWith(': connected'), isFalse);
        final body =
            Map<String, Object?>.from(jsonDecode(text) as Map);
        expect(body['code'], 'authorization_required');
        expect(body['ok'], false);
        // No subscriber leaked past the denial.
        expect(transport.subscriberCount, 0);
        expect(auth.authorizeCalls.single.segments, const ['events']);
      } finally {
        client.close(force: true);
      }
    });

    test('authorized /events keeps the SSE stream (bare first frame)',
        () async {
      final expected = _loadBytes('sse-connected.bin');
      final auth = _FakeAuthManager(); // authorize grants
      final (transport, uri) = await _startPlane(auth: auth);
      addTearDown(transport.close);

      final client = HttpClient();
      try {
        final request = await client.getUrl(uri!.resolve('/events'));
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_kFakeToken',
        );
        final response = await request.close();
        final actual = <int>[];
        await for (final chunk in response) {
          actual.addAll(chunk);
          if (actual.length >= expected.length) break;
        }
        expect(actual, expected,
            reason: 'authorized SSE first frame must stay byte-identical');
        expect(transport.subscriberCount, 1);
      } finally {
        client.close(force: true);
      }
    });
  });

  group('auth disabled keeps existing golden fixture behavior', () {
    test('bare /hello adds no auth keys when authManager is null', () async {
      final (transport, uri) =
          await _startPlane(caps: <Capability>[_AuthAlphaCap()]);
      addTearDown(transport.close);

      final (status, body) = await _httpGet(uri!, '/hello');
      expect(status, 200);
      // No auth keys in bare mode.
      expect(body.containsKey('authRequired'), isFalse);
      expect(body.containsKey('authEndpoints'), isFalse);
      // The shared cap-alpha declaration must still project (fixture parity
      // with the golden suite is asserted there; here we guard the no-auth
      // contract keys only).
      expect(body['protocolVersion'], 1);
      expect(body['eventsEndpoint'], '/events');
      // Full hello.json golden parity (multi-capability) is asserted in
      // golden_fixture_test.dart; here we guard the no-auth contract only.
      expect((body['registeredCapabilities'] as List), isNotEmpty);
    });
  });
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

Object _loadJson(String name) =>
    jsonDecode(File('${_fixturesDir.path}/$name').readAsStringSync());

List<int> _loadBytes(String name) =>
    File('${_fixturesDir.path}/$name').readAsBytesSync();

Future<(HttpSseTransport, Uri?)> _startPlane({
  List<Capability> caps = const <Capability>[],
  DebugAuthManager? auth,
}) async {
  final transport = HttpSseTransport();
  final plane = ControlPlane(
    transport: transport,
    authManager: auth,
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
  return (transport, await plane.start(
    address: InternetAddress.loopbackIPv4,
    port: 0,
  ));
}

Future<(int, Map<String, Object?>)> _httpGet(
  Uri base,
  String path, {
  String? bearer,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(base.resolve(path));
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (response.statusCode,
      Map<String, Object?>.from(jsonDecode(text) as Map),
    );
  } finally {
    client.close(force: true);
  }
}

Future<(int, Map<String, Object?>)> _httpPost(
  Uri base,
  String path,
  Map<String, Object?> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(base.resolve(path));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (response.statusCode,
      Map<String, Object?>.from(jsonDecode(text) as Map),
    );
  } finally {
    client.close(force: true);
  }
}
