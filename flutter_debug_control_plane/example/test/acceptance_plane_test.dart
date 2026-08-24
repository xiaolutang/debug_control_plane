import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
}

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
