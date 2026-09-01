import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:debug_control_plane/debug_control_plane.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_plane.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AcceptancePlane', () {
    test('starts Dart ControlPlane and registers fixed capabilities', () async {
      final logs = <AcceptanceRequestLogEntry>[];
      final plane = AcceptancePlane(onRequestLog: logs.add);
      addTearDown(plane.stop);

      final endpoint = await plane.startDartPlane();

      expect(endpoint.scheme, 'http');
      expect(endpoint.port, greaterThan(0));
      expect(plane.isRunning, isTrue);
      expect(
        plane.buildCapabilities().map((cap) => cap.id),
        containsAll(<String>[
          'debug.echo',
          'debug.deviceInfo',
          'debug.secureAction',
          'debug.errorCase',
        ]),
      );

      final hello = await _getJson(endpoint, '/hello');
      expect(hello.statusCode, 200);
      expect(hello.body['authRequired'], true);
      expect(hello.body['authStatus'], 'authorization_required');
      expect(
        (hello.body['authEndpoints'] as Map).cast<String, Object?>(),
        containsPair('claim', '/auth/claim'),
      );
      expect(
        logs.map((entry) => entry.authResult),
        contains('plane_started'),
      );
    });

    test('auth request/status/claim enables Bearer access', () async {
      final logs = <AcceptanceRequestLogEntry>[];
      final clock = _MutableClock(DateTime.utc(2026, 8, 24, 10));
      final plane = AcceptancePlane(
        onRequestLog: logs.add,
        now: clock.now,
        random: Random(7),
      );
      addTearDown(plane.stop);
      final endpoint = await plane.startDartPlane();

      final denied = await _postJson(endpoint, '/debug/secure-action');
      expect(denied.statusCode, 401);
      expect(denied.body['code'], 'authorization_required');

      final request =
          await _postJson(endpoint, '/auth/request', body: <String, Object?>{
        'clientNonce': 'nonce-1',
        'clientLabel': 'pytest acceptance',
      });
      expect(request.statusCode, 202);
      final requestId = request.body['requestId'] as String;

      final pending =
          await _postJson(endpoint, '/auth/status', body: <String, Object?>{
        'requestId': requestId,
        'clientNonce': 'nonce-1',
      });
      expect(pending.statusCode, 200);
      expect(pending.body['status'], 'pending');

      await plane.authManager.approvePending(requestId);

      final approved =
          await _postJson(endpoint, '/auth/status', body: <String, Object?>{
        'requestId': requestId,
        'clientNonce': 'nonce-1',
      });
      expect(approved.body['status'], 'approved');

      final claim =
          await _postJson(endpoint, '/auth/claim', body: <String, Object?>{
        'requestId': requestId,
        'clientNonce': 'nonce-1',
      });
      expect(claim.statusCode, 200);
      final token = claim.body['token'] as String;
      expect(token, isNotEmpty);

      final secure = await _postJson(
        endpoint,
        '/debug/secure-action',
        bearer: token,
      );
      expect(secure.statusCode, 200);
      expect(secure.body['allowed'], true);

      final echo = await _postJson(
        endpoint,
        '/debug/echo',
        body: <String, Object?>{'message': 'hello'},
        bearer: token,
      );
      expect(echo.body['payload'], <String, Object?>{'message': 'hello'});

      final deviceInfo = await _getJson(
        endpoint,
        '/debug/device-info',
        bearer: token,
      );
      expect(deviceInfo.body['fixtureApp'], 'flutter-auth-acceptance-app');

      final businessError = await _postJson(
        endpoint,
        '/debug/error-case',
        bearer: token,
      );
      expect(businessError.statusCode, 200);
      expect(businessError.body['ok'], false);
      expect(businessError.body['errorCode'], 'stable_business_error');

      expect(
        logs.map((entry) => entry.authResult),
        containsAll(<String>[
          'authorization_required',
          'pending',
          'approved',
          'claimed',
          'allowed',
        ]),
      );
      expect(jsonEncode(logs.map((entry) => entry.toJson()).toList()),
          isNot(contains(token)));
    });

    test('denied, invalid and expired tokens return stable auth errors',
        () async {
      final clock = _MutableClock(DateTime.utc(2026, 8, 24, 10));
      final plane = AcceptancePlane(now: clock.now, random: Random(11));
      addTearDown(plane.stop);
      final endpoint = await plane.startDartPlane();

      final deniedRequest = await _postJson(endpoint, '/auth/request', body: {
        'clientNonce': 'nonce-deny',
        'clientLabel': 'denied client',
      });
      final deniedRequestId = deniedRequest.body['requestId'] as String;
      await plane.authManager.denyPending(deniedRequestId);
      final deniedClaim = await _postJson(endpoint, '/auth/claim', body: {
        'requestId': deniedRequestId,
        'clientNonce': 'nonce-deny',
      });
      expect(deniedClaim.statusCode, 403);
      expect(deniedClaim.body['code'], 'authorization_denied');

      final invalid = await _postJson(
        endpoint,
        '/debug/secure-action',
        bearer: 'forged-token',
      );
      expect(invalid.statusCode, 401);
      expect(invalid.body['code'], 'invalid_token');

      final request = await _postJson(endpoint, '/auth/request', body: {
        'clientNonce': 'nonce-expire',
        'clientLabel': 'expiry client',
      });
      final requestId = request.body['requestId'] as String;
      await plane.authManager.approvePending(requestId);
      final claim = await _postJson(endpoint, '/auth/claim', body: {
        'requestId': requestId,
        'clientNonce': 'nonce-expire',
      });
      final token = claim.body['token'] as String;

      plane.authManager.expireToken();
      final expired = await _postJson(
        endpoint,
        '/debug/secure-action',
        bearer: token,
      );
      expect(expired.statusCode, 401);
      expect(expired.body['code'], 'token_expired');

      plane.authManager.clearToken();
      expect(plane.authManager.tokenPresent, isFalse);
    });

    test('auth request reuses pending request for the same client nonce',
        () async {
      final plane = AcceptancePlane(random: Random(17));
      addTearDown(plane.stop);
      final endpoint = await plane.startDartPlane();

      final first = await _postJson(endpoint, '/auth/request', body: {
        'clientNonce': 'nonce-reuse',
        'clientLabel': 'first label',
      });
      final second = await _postJson(endpoint, '/auth/request', body: {
        'clientNonce': 'nonce-reuse',
        'clientLabel': 'second label',
      });

      expect(second.statusCode, 202);
      expect(second.body['requestId'], first.body['requestId']);
      expect(second.body['status'], 'pending');
      expect(second.body['clientLabel'], 'first label');
    });
  });

  group('R005 token persistence', () {
    // E4 (existing-cases zero regression) is covered by running the full
    // test file above — no separate case needed.

    test('E1: hash-verified auth chain — claim, Bearer 200, forged 401',
        () async {
      final plane = AcceptancePlane(
        now: _fixedClock(DateTime.utc(2026, 8, 24, 10)),
        random: Random(23),
        store: InMemoryDebugAuthStore(),
      );
      addTearDown(plane.stop);
      final endpoint = await plane.startDartPlane();

      final token = await _claimToken(plane, endpoint, 'nonce-e1');
      expect(token, isNotEmpty);

      final secure = await _postJson(
        endpoint,
        '/debug/secure-action',
        bearer: token,
      );
      expect(secure.statusCode, 200);

      final forged = await _postJson(
        endpoint,
        '/debug/secure-action',
        bearer: 'forged-e1-token',
      );
      expect(forged.statusCode, 401);
      expect(forged.body['code'], 'invalid_token');
    });

    test('E2: injected store behaves like the default in-memory store',
        () async {
      Future<String> claim(AcceptancePlane plane) async =>
          _claimToken(plane, await plane.startDartPlane(), 'nonce-e2');

      final withStore = AcceptancePlane(
        random: Random(31),
        store: InMemoryDebugAuthStore(),
      );
      addTearDown(withStore.stop);
      final tokenWithStore = await claim(withStore);

      final withDefault = AcceptancePlane(random: Random(31));
      addTearDown(withDefault.stop);
      final tokenDefault = await claim(withDefault);

      final endpointWithStore = withStore.endpoint!;
      final secureWithStore = await _postJson(
        endpointWithStore,
        '/debug/secure-action',
        bearer: tokenWithStore,
      );
      expect(secureWithStore.statusCode, 200);

      final secureDefault = await _postJson(
        withDefault.endpoint!,
        '/debug/secure-action',
        bearer: tokenDefault,
      );
      expect(secureDefault.statusCode, 200);
    });

    test('E3: default TTL is 7 days (expiresAt - now within 604790-604810s)',
        () async {
      final clock = _MutableClock(DateTime.utc(2026, 8, 24, 10));
      final plane = AcceptancePlane(now: clock.now, random: Random(37));
      addTearDown(plane.stop);
      final endpoint = await plane.startDartPlane();

      final claim = await _claim(plane, endpoint, 'nonce-e3');
      final token = claim.token;
      final hello = await _getJson(endpoint, '/hello', bearer: token);
      expect(hello.body['authStatus'], 'authorized');

      final expiresAt = DateTime.parse(claim.expiresAt);
      final deltaSeconds =
          expiresAt.difference(clock.value).inMilliseconds / 1000;
      expect(deltaSeconds, greaterThanOrEqualTo(604790));
      expect(deltaSeconds, lessThanOrEqualTo(604810));
    });

    test('E5: persistence layer and store keys contain no plaintext token',
        () async {
      final tmpDir = await Directory.systemTemp.createTemp('r005-ff001-e5');
      addTearDown(() => tmpDir.delete(recursive: true));

      final store = FileBackedDebugAuthStore(directory: tmpDir.path);
      final plane = AcceptancePlane(
        now: _fixedClock(DateTime.utc(2026, 8, 24, 10)),
        random: Random(41),
        store: store,
      );
      addTearDown(plane.stop);
      final endpoint = await plane.startDartPlane();

      final token = await _claimToken(plane, endpoint, 'nonce-e5');
      expect(token, isNotEmpty);

      final file = File(
        '${tmpDir.path}${Platform.pathSeparator}debug_auth_tokens.json',
      );
      expect(file.existsSync(), isTrue);
      final bytes = await file.readAsBytes();
      expect(utf8.decode(bytes), isNot(contains(token)));
      expect(bytes, isNot(contains(utf8.encode(token))));

      // Store index keys are hashes — verify via a fresh in-memory store
      // seeded with the same flow.
      final memory = InMemoryDebugAuthStore();
      final memoryPlane = AcceptancePlane(random: Random(41), store: memory);
      addTearDown(memoryPlane.stop);
      final memoryToken =
          await _claimToken(memoryPlane, await memoryPlane.startDartPlane(),
              'nonce-e5');
      final hashes = memory.snapshot().map((r) => r.tokenHash).toList();
      expect(hashes, isNotEmpty);
      expect(hashes, contains(debugAuthTokenHash(memoryToken)));
      for (final hash in hashes) {
        expect(hash, isNot(contains(memoryToken)));
        expect(memoryToken, isNot(contains(hash)));
      }
    });
  });
}

class _ClaimResult {
  const _ClaimResult(this.token, this.expiresAt);
  final String token;
  final String expiresAt;
}

Future<_ClaimResult> _claim(
  AcceptancePlane plane,
  Uri endpoint,
  String nonce,
) async {
  final request = await _postJson(endpoint, '/auth/request', body: {
    'clientNonce': nonce,
    'clientLabel': 'r005 test client',
  });
  final requestId = request.body['requestId'] as String;
  await plane.authManager.approvePending(requestId);
  final claim = await _postJson(endpoint, '/auth/claim', body: {
    'requestId': requestId,
    'clientNonce': nonce,
  });
  expect(claim.statusCode, 200);
  return _ClaimResult(
    claim.body['token'] as String,
    claim.body['expiresAt'] as String,
  );
}

Future<String> _claimToken(
  AcceptancePlane plane,
  Uri endpoint,
  String nonce,
) async =>
    (await _claim(plane, endpoint, nonce)).token;

DateTime Function() _fixedClock(DateTime at) => () => at;

class _MutableClock {
  _MutableClock(this.value);

  DateTime value;

  DateTime now() => value;
}

Future<_JsonResponse> _getJson(
  Uri endpoint,
  String path, {
  String? bearer,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(endpoint.replace(path: path));
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    return _readResponse(await request.close());
  } finally {
    client.close(force: true);
  }
}

Future<_JsonResponse> _postJson(
  Uri endpoint,
  String path, {
  Map<String, Object?> body = const <String, Object?>{},
  String? bearer,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(endpoint.replace(path: path));
    request.headers.contentType = ContentType.json;
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    request.write(jsonEncode(body));
    return _readResponse(await request.close());
  } finally {
    client.close(force: true);
  }
}

Future<_JsonResponse> _readResponse(HttpClientResponse response) async {
  final body = await utf8.decodeStream(response);
  return _JsonResponse(
    response.statusCode,
    jsonDecode(body) as Map<String, Object?>,
  );
}

class _JsonResponse {
  const _JsonResponse(this.statusCode, this.body);

  final int statusCode;
  final Map<String, Object?> body;
}
