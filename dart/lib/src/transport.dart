import 'dart:async';

import 'debug_event.dart';

/// Outcome of routing a single request through the [Transport].
///
/// The [Transport.listen] callback returns a [RouteResult]; the transport is
/// responsible for translating it into the wire format (HTTP response, WS
/// frame, MCP message, ...).
class RouteResult {
  /// Create a routing result.
  const RouteResult({
    required this.statusCode,
    required this.body,
  });

  /// A 200 success with the given JSON body.
  factory RouteResult.ok(Map<String, Object?> body) =>
      RouteResult(statusCode: 200, body: body);

  /// An error result with `{ok:false, code, message}` body shape.
  factory RouteResult.error(
    int statusCode,
    String code,
    String message, {
    Map<String, Object?> extra = const {},
  }) {
    return RouteResult(
      statusCode: statusCode,
      body: <String, Object?>{
        'ok': false,
        'code': code,
        'message': message,
        ...extra,
      },
    );
  }

  /// HTTP-style status code (200 / 400 / 404 / 409 / 500 ...).
  final int statusCode;

  /// JSON-serializable response body.
  final Map<String, Object?> body;
}

/// A request handed to the control plane by the [Transport].
///
/// Protocol-agnostic: `request` is the opaque protocol handle (e.g. the
/// `HttpRequest` for an HTTP transport). The framework never inspects it;
/// capabilities may downcast it when they need protocol-specific behavior.
class RouteRequest {
  /// Create a route request.
  const RouteRequest({
    required this.method,
    required this.segments,
    required this.body,
    required this.request,
  });

  /// HTTP method, upper-cased (`GET`, `POST`, ...).
  final String method;

  /// Path segments, e.g. `/profiles/{id}` -> `['profiles', '<id>']`.
  final List<String> segments;

  /// Parsed JSON body (empty map for bodyless requests).
  final Map<String, Object?> body;

  /// Opaque protocol handle (e.g. `HttpRequest`). May be `null`.
  final Object? request;
}

/// Protocol-agnostic transport contract (decision: abstraction reserved for
/// WS / MCP transports; the BF001 control plane only holds this type).
///
/// BF001 ships only this interface plus a test fake. `HttpSseTransport`
/// (REST + SSE) lands in BF002.
abstract interface class Transport {
  /// Bind to [address] / [port]. Returns the actual bound URI (with the
  /// resolved port), or `null` if the transport has not been started or is
  /// connection-less.
  Future<Uri?> bind({required Object address, required int port});

  /// Install the routing callback. The transport parses incoming wire
  /// messages into [RouteRequest]s, hands them to [handler], and writes the
  /// returned [RouteResult] back onto the wire.
  void listen(Future<RouteResult> Function(RouteRequest req) handler);

  /// Broadcast a [DebugEvent] to all subscribers of the transport's event
  /// stream (e.g. `/events` SSE clients). No-op if the transport does not
  /// expose a push channel.
  void broadcast(DebugEvent event);

  /// Supply server-side discovery metadata for the `/hello` handshake.
  ///
  /// Returns a JSON-serializable map (typically `{serverHost, serverPort,
  /// localIps}`) derived from the bound socket + request headers. [request]
  /// is the same opaque handle carried by [RouteRequest] — the framework
  /// never inspects it, so the contract stays protocol-agnostic (the
  /// framework never imports `dart:io`).
  ///
  /// Implementations that have no server-side identity (e.g. WS / MCP stubs)
  /// may return an empty map.
  Future<Map<String, Object?>> serverInfo(Object? request);

  /// Release all resources (server socket, subscriptions, ...). Idempotent.
  Future<void> close();
}
