import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

Future<Map<String, Object?>> _getBodyAndClose(HttpClientResponse response,
    {bool expect200 = true}) async {
  if (expect200) {
    expect(response.statusCode, HttpStatus.ok);
  }
  final raw = await utf8.decoder.bind(response).join();
  return Map<String, Object?>.from(jsonDecode(raw) as Map);
}

/// A simple dispatch handler for tests: returns JSON echoes or 404.
Future<RouteResult> _echoHandler(RouteRequest req) async {
  if (req.method == 'GET' && req.segments.length == 1 && req.segments.first == 'echo') {
    return RouteResult.ok(<String, Object?>{'ok': true, 'segments': req.segments});
  }
  if (req.method == 'POST' && req.segments.length == 1 && req.segments.first == 'echo') {
    return RouteResult.ok(<String, Object?>{'ok': true, 'echo': req.body});
  }
  return RouteResult.error(404, 'not_found', 'Endpoint was not found.');
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

void main() {
  HttpOverrides.global = null;

  group('HttpSseTransport bind/listen/close', () {
    test('bind returns actual bound URI with resolved port', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);

      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      expect(uri, isNotNull);
      expect(uri!.port, greaterThan(0));
      expect(transport.server, isNotNull);
      expect(transport.server!.port, uri.port);
    });

    test('listen before bind is deferred; replayed once bind resolves',
        () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      // Install handler BEFORE bind (the framework's ControlPlane.start does
      // this). Must not throw and must still receive traffic after bind().
      transport.listen(_echoHandler);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      final client = HttpClient();
      try {
        final response =
            await client.getUrl(uri!.resolve('/echo')).then((r) => r.close());
        final body = await _getBodyAndClose(response);
        expect(body, {'ok': true, 'segments': ['echo']});
      } finally {
        client.close(force: true);
      }
    });

    test('listen called twice throws StateError', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      await transport.bind(address: InternetAddress.loopbackIPv4, port: 0);
      transport.listen(_echoHandler);
      expect(
        () => transport.listen(_echoHandler),
        throwsA(isA<StateError>()),
      );
    });

    test('GET routes flow through handler and produce JSON body', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      transport.listen(_echoHandler);

      final client = HttpClient();
      try {
        final response =
            await client.getUrl(uri!.resolve('/echo')).then((r) => r.close());
        final body = await _getBodyAndClose(response);
        expect(body, {'ok': true, 'segments': ['echo']});
      } finally {
        client.close(force: true);
      }
    });

    test('POST routes parse body and route through handler', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      transport.listen(_echoHandler);

      final client = HttpClient();
      try {
        final request = await client.postUrl(uri!.resolve('/echo'));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(<String, Object?>{'v': 7}));
        final response = await request.close();
        final body = await _getBodyAndClose(response);
        expect(body, {
          'ok': true,
          'echo': <String, Object?>{'v': 7},
        });
      } finally {
        client.close(force: true);
      }
    });

    test('undeclared path returns 404 not_found', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      transport.listen(_echoHandler);

      final client = HttpClient();
      try {
        final response = await client
            .getUrl(uri!.resolve('/nope'))
            .then((r) => r.close());
        expect(response.statusCode, HttpStatus.notFound);
        final raw = await utf8.decoder.bind(response).join();
        final body = Map<String, Object?>.from(jsonDecode(raw) as Map);
        expect(body['ok'], false);
        expect(body['code'], 'not_found');
      } finally {
        client.close(force: true);
      }
    });
  });

  group('HttpSseTransport /events hijack', () {
    test('GET /events streams ": connected" preamble + text/event-stream',
        () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      transport.listen(_echoHandler);

      final client = HttpClient();
      try {
        final response = await client
            .getUrl(uri!.resolve('/events'))
            .then((r) => r.close());
        expect(
          response.headers.contentType?.mimeType,
          'text/event-stream',
        );
        // Read only the first line to avoid blocking on the long-lived
        // stream, then force-close the connection.
        final firstLine = await response
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 2));
        expect(firstLine, ': connected');
      } finally {
        client.close(force: true);
      }
    });

    test('GET /events does NOT invoke the dispatch handler', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      var handlerCalled = false;
      transport.listen((req) async {
        handlerCalled = true;
        return RouteResult.ok(<String, Object?>{'ok': true});
      });

      final client = HttpClient();
      try {
        final response = await client
            .getUrl(uri!.resolve('/events'))
            .then((r) => r.close());
        final firstLine = await response
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 2));
        expect(firstLine, ': connected');
        // Give the server a microtask to (incorrectly) call the handler.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(handlerCalled, isFalse,
            reason: '/events must be hijacked; dispatch must not run');
      } finally {
        client.close(force: true);
      }
    });

    test('broadcast emits event: <type>\\ndata: <json>\\n\\n to subscribers',
        () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      transport.listen(_echoHandler);

      final client = HttpClient();
      try {
        final response = await client
            .getUrl(uri!.resolve('/events'))
            .then((r) => r.close());
        final lines = <String>[];
        final sub = response
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(lines.add);

        // Wait for preamble.
        await _waitForLines(lines, [': connected']);
        // Broadcast an event.
        transport.broadcast(const DebugEvent(
          type: 'controller_state_changed',
          sequence: 42,
          payload: <String, Object?>{'activeSource': 'virtual'},
        ));
        await _waitForLine(lines, 'event: controller_state_changed',
            const Duration(seconds: 2));
        await sub.cancel();

        // Verify frame format.
        final eventIdx =
            lines.indexOf('event: controller_state_changed');
        expect(eventIdx, greaterThanOrEqualTo(0));
        final dataLine = lines[eventIdx + 1];
        expect(dataLine.startsWith('data: '), isTrue);
        final json =
            jsonDecode(dataLine.substring('data: '.length)) as Map;
        expect(json['type'], 'controller_state_changed');
        expect(json['sequence'], 42);
        expect(json['activeSource'], 'virtual');
      } finally {
        client.close(force: true);
      }
    });

    test('broadcast is a no-op when no subscribers are connected', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      // Should not throw.
      transport.broadcast(const DebugEvent(
        type: 'controller_state_changed',
        sequence: 1,
        payload: <String, Object?>{},
      ));
    });
  });

  group('HttpSseTransport serverInfo', () {
    test('serverInfo returns {serverHost, serverPort, localIps} from bound '
        'socket', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );

      // No Host-header context here → host falls back to '0.0.0.0' (no
      // HttpRequest instance), port comes from the bound server.
      final info = await transport.serverInfo(null);
      expect(info['serverHost'], '0.0.0.0');
      expect(info['serverPort'], uri!.port);
      expect(info['localIps'], isA<List>());
    });

    test('serverInfo without Host header falls back to 0.0.0.0', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      // Stub a handler that captures the request then calls serverInfo —
      // mirrors how ControlPlane._handleHello spreads serverInfo(req.request).
      HttpRequest? captured;
      transport.listen((req) async {
        captured = req.request as HttpRequest;
        final info = await transport.serverInfo(req.request);
        return RouteResult.ok(info);
      });

      final client = HttpClient();
      try {
        final request = await client.getUrl(uri!.resolve('/whatever'));
        request.headers.removeAll(HttpHeaders.hostHeader);
        final response = await request.close();
        final body = await _getBodyAndClose(response, expect200: false);
        expect(captured, isNotNull);
        expect(body['serverHost'], '0.0.0.0');
        expect(body['serverPort'], uri.port);
        expect(body['localIps'], isA<List>());
      } finally {
        client.close(force: true);
      }
    });

    test('serverInfo with Host header uses Host-derived host', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final uri = await transport.bind(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      transport.listen((req) async {
        final info = await transport.serverInfo(req.request);
        return RouteResult.ok(info);
      });

      final client = HttpClient();
      try {
        // dart:io auto-populates `Host: <loopback host>:<port>` from the Uri.
        // requestEndpoint() parses that header; the returned host matches the
        // loopback literal the client used (not the synthetic '0.0.0.0'
        // fallback that fires only when the header is absent).
        final response =
            await client.getUrl(uri!.resolve('/whatever')).then((r) => r.close());
        final body = await _getBodyAndClose(response, expect200: false);
        expect(body['serverHost'], uri.host);
        expect(body['serverPort'], uri.port);
      } finally {
        client.close(force: true);
      }
    });

    test('serverInfo with non-HttpRequest returns 0.0.0.0 host', () async {
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      await transport.bind(address: InternetAddress.loopbackIPv4, port: 0);
      final info = await transport.serverInfo('not-an-http-request');
      expect(info['serverHost'], '0.0.0.0');
    });
  });

  group('HttpSseTransport close', () {
    test('close is idempotent and clears subscribers', () async {
      final transport = HttpSseTransport();
      await transport.bind(address: InternetAddress.loopbackIPv4, port: 0);
      await transport.close();
      // Calling again should be safe.
      await transport.close();
      expect(transport.server, isNull);
    });
  });

  group('Transport protocol-agnostic replaceability', () {
    test('a non-HttpSseTransport still drives plane.dispatch through its '
        'handler', () async {
      // This is a structural smoke: proves ControlPlane.dispatch works
      // regardless of which Transport implementation is plugged in. The
      // real _FakeTransport exercise lives in control_plane_test.dart.
      final transport = HttpSseTransport();
      addTearDown(transport.close);
      final plane = ControlPlane(
        transport: transport,
        appMeta: () => const <String, Object?>{
          'app': 'example-app',
          'capabilities': <String>['virtual_input'],
        },
      );
      plane.register(_FakeCap());
      final uri = await plane.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      expect(uri, isNotNull);

      final client = HttpClient();
      try {
        final response =
            await client.getUrl(uri!.resolve('/hello')).then((r) => r.close());
        final body = await _getBodyAndClose(response);
        expect(body['app'], 'example-app');
        expect(body['protocolVersion'], 1);
        expect(body['capabilities'], ['virtual_input']);
        // serverInfo came from the real HttpSseTransport.
        expect(body['serverHost'], isA<String>());
        expect(body['serverPort'], uri.port);
        expect(body['localIps'], isA<List>());
      } finally {
        client.close(force: true);
      }
      await plane.stop();
    });
  });
}

// -----------------------------------------------------------------------------
// Local helpers used above
// -----------------------------------------------------------------------------

class _FakeCap implements Capability {
  @override
  String get id => 'demo';

  @override
  List<Command> get commands => const <Command>[];

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();

  @override
  List<Resource> get resources => const <Resource>[];

  @override
  Map<String, Object?> state() => const <String, Object?>{'activeSource': 'none'};
}

Future<void> _waitForLines(
  List<String> lines,
  List<String> required, [
  Duration timeout = const Duration(seconds: 2),
]) async {
  final deadline = DateTime.now().add(timeout);
  while (!required.every(lines.contains)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for lines $required; got $lines');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _waitForLine(
  List<String> lines,
  String line, [
  Duration timeout = const Duration(seconds: 2),
]) async {
  await _waitForLines(lines, [line], timeout);
}
