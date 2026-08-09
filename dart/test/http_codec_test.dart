import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';

/// Codec-level tests for `http_codec.dart`. The legacy runtime's top-level
/// functions (`_readObject` / `_requiredObject` / `_requiredString` /
/// `_writeJson` / `_writeError` / `_requestEndpoint` / `_localIPv4Addresses`)
/// were ported byte-for-byte; these tests pin their contract independently
/// of the transport layer.
void main() {
  HttpOverrides.global = null;

  group('requiredObject / requiredString', () {
    test('requiredObject accepts Map<String,Object?> as-is', () {
      const value = <String, Object?>{'a': 1, 'b': 'two'};
      expect(requiredObject(value), same(value));
    });

    test('requiredObject coerces dynamic-key Map<String,Object?> form', () {
      // Map<String,Object?>.from(map) requires every key castable to String;
      // matches the legacy runtime contract (JSON objects only yield String
      // keys anyway, so this is the realistic shape).
      final value = <String, Object?>{'k': 'v', 'n': 2};
      final result = requiredObject(value);
      expect(result, {'k': 'v', 'n': 2});
    });

    test('requiredObject throws RouteFailure 400 invalid_request on non-map',
        () {
      expect(
        () => requiredObject([1, 2, 3]),
        throwsA(predicate<RouteFailure>(
          (e) =>
              e.statusCode == HttpStatus.badRequest &&
              e.code == 'invalid_request' &&
              e.message == 'Expected object.',
        )),
      );
      expect(
        () => requiredObject(null),
        throwsA(isA<RouteFailure>()),
      );
      expect(
        () => requiredObject('string'),
        throwsA(isA<RouteFailure>()),
      );
    });

    test('requiredString accepts non-empty string', () {
      expect(requiredString('hello'), 'hello');
      expect(requiredString(' '), ' ');
    });

    test('requiredString throws RouteFailure on empty string or non-string',
        () {
      expect(
        () => requiredString(''),
        throwsA(predicate<RouteFailure>(
          (e) =>
              e.statusCode == HttpStatus.badRequest &&
              e.code == 'invalid_request' &&
              e.message == 'Expected non-empty string.',
        )),
      );
      expect(
        () => requiredString(null),
        throwsA(isA<RouteFailure>()),
      );
      expect(
        () => requiredString(42),
        throwsA(isA<RouteFailure>()),
      );
    });

    test('optionalString: null passes through; non-null delegates to '
        'requiredString', () {
      expect(optionalString(null), isNull);
      expect(optionalString('hi'), 'hi');
      expect(() => optionalString(''), throwsA(isA<RouteFailure>()));
      expect(() => optionalString(7), throwsA(isA<RouteFailure>()));
    });
  });

  group('readObject', () {
    test('parses a JSON object body', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((HttpRequest request) async {
        try {
          final body = await readObject(request);
          await writeJson(request.response, <String, Object?>{
            'ok': true,
            'received': body,
          });
        } on RouteFailure catch (error) {
          await writeError(
              request.response, error.statusCode, error.code, error.message);
        }
      });

      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('http://${server.address.address}:${server.port}/x'),
        );
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(<String, Object?>{'k': 'v'}));
        final response = await request.close();
        final raw = await utf8.decoder.bind(response).join();
        final body = Map<String, Object?>.from(jsonDecode(raw) as Map);
        expect(response.statusCode, HttpStatus.ok);
        expect(body['ok'], true);
        expect(body['received'], {'k': 'v'});
      } finally {
        client.close(force: true);
      }
    });

    test('throws RouteFailure 400 invalid_request on malformed JSON', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((HttpRequest request) async {
        try {
          await readObject(request);
          await writeJson(request.response, <String, Object?>{'ok': true});
        } on RouteFailure catch (error) {
          await writeError(
              request.response, error.statusCode, error.code, error.message);
        }
      });

      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('http://${server.address.address}:${server.port}/x'),
        );
        request.headers.contentType = ContentType.json;
        request.write('this is not json');
        final response = await request.close();
        final raw = await utf8.decoder.bind(response).join();
        final body = Map<String, Object?>.from(jsonDecode(raw) as Map);
        expect(response.statusCode, HttpStatus.badRequest);
        expect(body['ok'], false);
        expect(body['code'], 'invalid_request');
        expect(body['message'], 'Request body must be valid JSON object.');
      } finally {
        client.close(force: true);
      }
    });

    test('throws RouteFailure 400 invalid_request on JSON array body',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((HttpRequest request) async {
        try {
          await readObject(request);
          await writeJson(request.response, <String, Object?>{'ok': true});
        } on RouteFailure catch (error) {
          await writeError(
              request.response, error.statusCode, error.code, error.message);
        }
      });

      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('http://${server.address.address}:${server.port}/x'),
        );
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(<Object?>[1, 2, 3]));
        final response = await request.close();
        final raw = await utf8.decoder.bind(response).join();
        final body = Map<String, Object?>.from(jsonDecode(raw) as Map);
        expect(response.statusCode, HttpStatus.badRequest);
        expect(body['ok'], false);
        expect(body['code'], 'invalid_request');
        expect(body['message'], 'Expected object.');
      } finally {
        client.close(force: true);
      }
    });
  });

  group('writeJson / writeError', () {
    test('writeJson writes status + body with Content-Type: application/json',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((HttpRequest request) {
        unawaited(writeJson(request.response, <String, Object?>{'ok': true},
            statusCode: HttpStatus.accepted));
      });

      final client = HttpClient();
      try {
        final response = await client
            .getUrl(Uri.parse('http://${server.address.address}:${server.port}/'))
            .then((r) => r.close());
        expect(response.statusCode, HttpStatus.accepted);
        expect(response.headers.contentType?.mimeType, 'application/json');
        final raw = await utf8.decoder.bind(response).join();
        expect(jsonDecode(raw), {'ok': true});
      } finally {
        client.close(force: true);
      }
    });

    test('writeError writes {ok:false, code, message}', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((HttpRequest request) {
        unawaited(writeError(request.response, HttpStatus.conflict,
            'real_controller_active', 'Real controller is active.'));
      });

      final client = HttpClient();
      try {
        final response = await client
            .getUrl(Uri.parse('http://${server.address.address}:${server.port}/'))
            .then((r) => r.close());
        expect(response.statusCode, HttpStatus.conflict);
        final raw = await utf8.decoder.bind(response).join();
        expect(jsonDecode(raw), {
          'ok': false,
          'code': 'real_controller_active',
          'message': 'Real controller is active.',
        });
      } finally {
        client.close(force: true);
      }
    });
  });

  group('requestEndpoint', () {
    test('parses Host header host component (port always comes from server)',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      late ({String host, int port}) captured;
      server.listen((HttpRequest request) {
        captured = requestEndpoint(request);
        unawaited(writeJson(request.response, <String, Object?>{'ok': true}));
      });

      final client = HttpClient();
      try {
        final response = await client
            .getUrl(Uri.parse(
                'http://${server.address.address}:${server.port}/x'))
            .then((r) => r.close());
        await response.drain<void>();
        // dart:io `HttpHeaders.host` getter returns the host component only
        // (no port) — so requestEndpoint parses a port-less Host and falls
        // back to 80. This matches the legacy runtime byte-for-byte: the
        // real serverPort comes from `_server.port`, not the Host header.
        expect(captured.host, server.address.address);
        expect(captured.port, 80);
      } finally {
        client.close(force: true);
      }
    });

    test('returns 0.0.0.0:0 when Host header is absent', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      late ({String host, int port}) captured;
      server.listen((HttpRequest request) {
        captured = requestEndpoint(request);
        unawaited(writeJson(request.response, <String, Object?>{'ok': true}));
      });

      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://${server.address.address}:${server.port}/x'),
        );
        request.headers.removeAll(HttpHeaders.hostHeader);
        final response = await request.close();
        await response.drain<void>();
        expect(captured.host, '0.0.0.0');
        expect(captured.port, 0);
      } finally {
        client.close(force: true);
      }
    });

    test('parses Host without port defaults port to 80', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      late ({String host, int port}) captured;
      server.listen((HttpRequest request) {
        captured = requestEndpoint(request);
        unawaited(writeJson(request.response, <String, Object?>{'ok': true}));
      });

      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://${server.address.address}:${server.port}/x'),
        );
        request.headers.removeAll(HttpHeaders.hostHeader);
        request.headers.set(HttpHeaders.hostHeader, 'myhost.example');
        final response = await request.close();
        await response.drain<void>();
        expect(captured.host, 'myhost.example');
        expect(captured.port, 80);
      } finally {
        client.close(force: true);
      }
    });
  });

  group('localIPv4Addresses', () {
    test('returns a sorted List<String> of addresses (may be empty)', () async {
      final addresses = await localIPv4Addresses();
      expect(addresses, isA<List<String>>());
      // Verify sorted invariant (uses String sort, the legacy contract).
      final sorted = List<String>.from(addresses)..sort();
      expect(addresses, sorted);
    });
  });
}
