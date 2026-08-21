import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'debug_event.dart';
import 'http_codec.dart';
import 'route_failure.dart';
import 'transport.dart';

/// REST + Server-Sent-Events transport: the production transport for the
/// debug control plane.
///
/// Implements the legacy `internal debug runtime` HTTP
/// contract byte-for-byte:
/// * `bind` → `HttpServer.bind`;
/// * `listen(handler)` parses each [HttpRequest] into a [RouteRequest],
///   **except** `GET /events` which is hijacked into a long-lived SSE
///   subscriber (the handler is NOT invoked — the plane's introspection
///   fallback must not fire, decision documented in BF002.1);
/// * `broadcast(event)` writes an `event: <type>\ndata: <json>\n\n` frame
///   onto every connected SSE subscriber (BF002.2);
/// * `serverInfo(request)` returns `{serverHost, serverPort, localIps}`
///   computed from the bound socket + `Host` header (BF002.0).
///
/// Zero business dependencies: only `dart:*` + framework types.
class HttpSseTransport implements Transport {
  HttpSseTransport();

  HttpServer? _server;

  /// Handler installed via [listen], replayed onto the server once it binds.
  /// Stored so callers may invoke [listen] before [bind] (the framework's
  /// [ControlPlane.start] does exactly this — `listen(dispatch)` then `bind`).
  Future<RouteResult> Function(RouteRequest req)? _pendingHandler;

  /// Active long-lived `/events` subscribers. Hijacked responses live here
  /// until the client disconnects (detected on write failure) or [close] is
  /// called.
  final Set<_SseSubscriber> _sseSubscribers = <_SseSubscriber>{};

  Future<RouteResult?> Function(RouteRequest req)? _eventsPreflight;

  /// The bound HTTP server, if any. Exposed for tests + `serverInfo`.
  HttpServer? get server => _server;

  /// Active SSE subscriber count. Exposed for auth preflight and lifecycle tests.
  int get subscriberCount => _sseSubscribers.length;

  @override
  Future<Uri?> bind({required Object address, required int port}) async {
    final bound = await HttpServer.bind(address, port);
    _server = bound;
    _attachHandlerIfPending();
    final host = bound.address.address;
    return Uri(scheme: 'http', host: host, port: bound.port);
  }

  @override
  void listen(Future<RouteResult> Function(RouteRequest req) handler) {
    if (_pendingHandler != null) {
      throw StateError('HttpSseTransport.listen called twice.');
    }
    _pendingHandler = handler;
    _attachHandlerIfPending();
  }

  void setEventsPreflight(
    Future<RouteResult?> Function(RouteRequest req)? handler,
  ) {
    _eventsPreflight = handler;
  }

  void _attachHandlerIfPending() {
    final server = _server;
    final handler = _pendingHandler;
    if (server == null || handler == null) return;
    _pendingHandler = null;
    server.listen((HttpRequest request) {
      // Hijack GET /events into the SSE subscriber pool. The handler must NOT
      // be called — otherwise the plane's introspection fallback (`/events`
      // returns 200 `{ok:true, note:'event_bus_is_stream'}`) would fire and
      // break the SSE byte contract (TEST01: first line must be
      // `: connected`, not a JSON body).
      final segments = request.uri.pathSegments;
      if (request.method == 'GET' &&
          segments.length == 1 &&
          segments.first == 'events') {
        unawaited(_handleEventsHijack(request));
        return;
      }
      unawaited(_handleRoute(request, handler));
    });
  }

  Future<void> _handleRoute(
    HttpRequest request,
    Future<RouteResult> Function(RouteRequest req) handler,
  ) async {
    try {
      final body = request.method == 'POST'
          ? await readObject(request)
          : const <String, Object?>{};
      final routeReq = RouteRequest(
        method: request.method,
        segments: request.uri.pathSegments,
        body: body,
        headers: _headers(request),
        request: request,
      );
      final result = await handler(routeReq);
      await writeJson(request.response, result.body,
          statusCode: result.statusCode);
    } on RouteFailure catch (error) {
      await writeError(
        request.response,
        error.statusCode,
        error.code,
        error.message,
      );
    } catch (error) {
      await writeError(
        request.response,
        HttpStatus.internalServerError,
        'internal_error',
        error.toString(),
      );
    }
  }

  Future<void> _handleEventsHijack(HttpRequest request) async {
    final preflight = _eventsPreflight;
    if (preflight != null) {
      final result = await preflight(RouteRequest(
        method: request.method,
        segments: request.uri.pathSegments,
        body: const <String, Object?>{},
        headers: _headers(request),
        request: request,
      ));
      if (result != null) {
        await writeJson(
          request.response,
          result.body,
          statusCode: result.statusCode,
        );
        return;
      }
    }

    final response = request.response;
    response.bufferOutput = false;
    response.statusCode = HttpStatus.ok;
    response.headers
      ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..set(HttpHeaders.connectionHeader, 'keep-alive');

    final subscriber = _SseSubscriber(response);
    _sseSubscribers.add(subscriber);
    response.write(': connected\n\n');
    unawaited(response.flush().catchError((Object? _) {}));
    // Detach on close so a dropped client doesn't leak.
    response.done.whenComplete(() {
      _sseSubscribers.remove(subscriber);
    });
  }

  Map<String, String> _headers(HttpRequest request) {
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name] = values.join(',');
    });
    return headers;
  }

  @override
  void broadcast(DebugEvent event) {
    if (_sseSubscribers.isEmpty) return;
    final frame =
        'event: ${event.type}\ndata: ${jsonEncode(event.toJson())}\n\n';
    // Iterate over a copy because the set may mutate during write errors.
    for (final subscriber in List<_SseSubscriber>.of(_sseSubscribers)) {
      subscriber.write(frame);
    }
  }

  @override
  Future<Map<String, Object?>> serverInfo(Object? request) async {
    final server = _server;
    final endpoint = request is HttpRequest ? requestEndpoint(request) : null;
    final host = endpoint?.host ?? '0.0.0.0';
    final port = server?.port ?? endpoint?.port ?? 0;
    return <String, Object?>{
      'serverHost': host,
      'serverPort': port,
      'localIps': await localIPv4Addresses(),
    };
  }

  @override
  Future<void> close() async {
    final server = _server;
    _server = null;
    // Cancel SSE subscribers first so their hijacked responses flush the
    // closing frame and stop holding connections.
    for (final subscriber in List<_SseSubscriber>.of(_sseSubscribers)) {
      await subscriber.close();
    }
    _sseSubscribers.clear();
    await server?.close(force: true);
  }
}

/// A single `/events` long-lived connection.
///
/// Writes are best-effort: any error (broken pipe, client gone) removes the
/// subscriber from its transport so subsequent broadcasts skip it.
class _SseSubscriber {
  _SseSubscriber(this._response);

  final HttpResponse _response;

  void write(String frame) {
    try {
      _response.write(frame);
      unawaited(_response.flush().catchError((Object? _) {
        // Swallow write errors — the transport's `response.done` completer
        // will detach this subscriber.
      }));
    } catch (_) {
      // Best-effort: caller (`broadcast`) cannot throw on a single dead
      // subscriber; rely on response.done cleanup for removal.
    }
  }

  Future<void> close() async {
    try {
      await _response.close();
    } catch (_) {
      // Already torn down — ignore.
    }
  }
}
