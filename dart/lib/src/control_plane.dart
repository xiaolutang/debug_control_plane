import 'dart:async';

import 'capability.dart';
import 'debug_event.dart';
import 'route_failure.dart';
import 'transport.dart';

/// Stable protocol version advertised in `/hello` (decision: framework owns
/// the protocol number; app identity is injected via [appMeta]).
const int kDebugControlPlaneProtocolVersion = 1;

/// The debug control plane: a capability registry + addressing/dispatch
/// engine + SSE event bus + discovery handshake.
///
/// Routing model (decision D6):
/// * System routes `/hello`, `/state`, `/events` are handled by the plane.
/// * Capability routes are declared by capabilities
///   ([Capability.resources] for GET, [Capability.commands] for POST) and
///   dispatched by the plane via flat, prefix-less matching.
///
/// Event bus (decision D5): the plane owns a broadcast
/// `StreamController<DebugEvent>`; the transport (e.g. `HttpSseTransport`
/// in BF002) subscribes and encodes onto `/events`.
///
/// App metadata (decision D8): `/hello` app identity (`app`, `deviceId`,
/// `platform`, ...) is injected via [appMeta]; the framework never hard-codes
/// it, preserving zero business dependencies.
class ControlPlane {
  /// Create a control plane backed by [transport].
  ///
  /// [appMeta] is invoked per `/hello` request to supply app identity. When
  /// omitted, `/hello` emits an empty app-meta block (the framework still
  /// fills in `protocolVersion` and capability listings).
  ControlPlane({required this.transport, this.appMeta});

  /// The transport this plane routes through.
  final Transport transport;

  /// Injected app metadata provider for `/hello`.
  final Map<String, Object?> Function()? appMeta;

  final Map<String, Capability> _capabilities = <String, Capability>{};

  // Aggregated event subscriptions per capability (kept so unregister can
  // cancel cleanly).
  final Map<String, StreamSubscription<DebugEvent>> _eventSubs =
      <String, StreamSubscription<DebugEvent>>{};

  final StreamController<DebugEvent> _eventBus =
      StreamController<DebugEvent>.broadcast(sync: true);

  int _nextSequence = 0;

  /// The global event bus. Transports subscribe here to encode `/events`
  /// (SSE / WS / MCP). Events flow in when capabilities emit on their
  /// [Capability.events] stream.
  Stream<DebugEvent> get eventBus => _eventBus.stream;

  /// All registered capability ids.
  Iterable<String> get registeredIds => _capabilities.keys;

  // ---------------------------------------------------------------------------
  // Registry
  // ---------------------------------------------------------------------------

  /// Register [cap]. Throws [StateError] if a capability with the same id is
  /// already registered (decision D4 — runtime register/unregister is
  /// supported, but duplicate ids are rejected).
  void register(Capability cap) {
    if (_capabilities.containsKey(cap.id)) {
      throw StateError(
        'Capability already registered: ${cap.id}',
      );
    }
    _capabilities[cap.id] = cap;
    _eventSubs[cap.id] = cap.events.listen(_onCapabilityEvent);
  }

  /// Unregister the capability with the given [id]. No-op if not registered.
  void unregister(String id) {
    final cap = _capabilities.remove(id);
    if (cap == null) return;
    _eventSubs.remove(id)?.cancel();
  }

  void _onCapabilityEvent(DebugEvent event) {
    final sequenced = DebugEvent(
      type: event.type,
      sequence: _nextSequence++,
      payload: event.payload,
    );
    _eventBus.add(sequenced);
    transport.broadcast(sequenced);
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Start the transport. Returns the bound URI (or `null` if the transport
  /// is connection-less).
  Future<Uri?> start({
    required Object address,
    required int port,
  }) async {
    transport.listen(dispatch);
    return transport.bind(address: address, port: port);
  }

  /// Stop the transport and tear down event subscriptions.
  Future<void> stop() async {
    await transport.close();
    for (final sub in _eventSubs.values) {
      await sub.cancel();
    }
    _eventSubs.clear();
  }

  // ---------------------------------------------------------------------------
  // Routing
  // ---------------------------------------------------------------------------

  /// Route a parsed [RouteRequest] to the matching system route or
  /// capability declaration. Public so transports (and tests) can drive the
  /// plane without going through [Transport.listen].
  Future<RouteResult> dispatch(RouteRequest req) async {
    try {
      // System routes — handled by the plane itself.
      final system = _matchSystemRoute(req.method, req.segments);
      if (system != null) {
        return RouteResult.ok(await system(req));
      }

      // Capability routes — flat, prefix-less matching across all declared
      // resources / commands. Resources answer GET; commands answer POST.
      if (req.method == 'GET') {
        for (final cap in _capabilities.values) {
          for (final decl in cap.resources) {
            if (decl.method != req.method) continue;
            final pathParams = <String, String>{};
            if (_matchPath(decl.path, req.segments, pathParams)) {
              final ctx = RouteContext(
                pathParams: pathParams,
                body: req.body,
                request: req.request,
              );
              return RouteResult.ok(await decl.handler(ctx));
            }
          }
        }
      } else if (req.method == 'POST') {
        for (final cap in _capabilities.values) {
          for (final decl in cap.commands) {
            if (decl.method != req.method) continue;
            final pathParams = <String, String>{};
            if (_matchPath(decl.path, req.segments, pathParams)) {
              final ctx = RouteContext(
                pathParams: pathParams,
                body: req.body,
                request: req.request,
              );
              return RouteResult.ok(await decl.handler(ctx));
            }
          }
        }
      }

      return RouteResult.error(
        404,
        'not_found',
        'Endpoint was not found.',
      );
    } on RouteFailure catch (error) {
      return RouteResult.error(
        error.statusCode,
        error.code,
        error.message,
      );
    } catch (error) {
      return RouteResult.error(
        500,
        'internal_error',
        error.toString(),
      );
    }
  }

  Future<Map<String, Object?>> Function(RouteRequest req)?
      _matchSystemRoute(String method, List<String> segments) {
    if (method == 'GET' && _listEquals(segments, const ['hello'])) {
      return _handleHello;
    }
    if (method == 'GET' && _listEquals(segments, const ['state'])) {
      return _handleState;
    }
    if (method == 'GET' && _listEquals(segments, const ['events'])) {
      return _handleEvents;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // System route handlers
  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>> _handleHello(RouteRequest req) async {
    final meta = appMeta?.call() ?? const <String, Object?>{};
    return <String, Object?>{
      'protocolVersion': kDebugControlPlaneProtocolVersion,
      ...meta,
      ...await transport.serverInfo(req.request),
      'eventsEndpoint': '/events',
      'profileRevision': 1,
      ..._aggregateState(),
      // R020-FF001/FF002: runtime capability schema (the dynamic mirror source
      // of truth for MCP tooling). Spread last so existing R019 fields keep
      // their values; only adds the new `registeredCapabilities` key.
      ..._aggregateCapabilities(),
    };
  }

  Future<Map<String, Object?>> _handleState(RouteRequest req) async {
    // Byte-level parity with the legacy launcher `/state` body: the legacy
    // `_statePayload()` returned the flat aggregate state with no top-level
    // `ok` flag. Adding `ok` here would diverge from the TEST01 contract
    // (golden snapshot). R019-FF002 contract-alignment (extension of BF002.0
    // which originally only named `/hello`).
    return _aggregateState();
  }

  Future<Map<String, Object?>> _handleEvents(RouteRequest req) async {
    // `/events` is a long-lived stream handshake in the BF002 transport
    // (text/event-stream). The framework exposes the data source via
    // [eventBus]; the wire-level implementation lives in `HttpSseTransport`.
    // Direct GET /events through this code path (without a transport that
    // hijacks the connection) returns the current bus subscription info so
    // the route is non-404 and introspectable.
    return <String, Object?>{
      'ok': true,
      'note': 'event_bus_is_stream',
      'eventsEndpoint': '/events',
    };
  }

  Map<String, Object?> _aggregateState() {
    final state = <String, Object?>{};
    for (final cap in _capabilities.values) {
      final capState = cap.state();
      for (final entry in capState.entries) {
        // Capabilities own their keys; later registrations win on collision
        // (predictable, debug-only, easy to spot).
        state[entry.key] = entry.value;
      }
    }
    return state;
  }

  /// Aggregate the runtime capability registry into the
  /// `/hello.registeredCapabilities` schema (R020-FF001/FF002).
  ///
  /// Shape: `{'registeredCapabilities': [{id, resources:[{method, path,
  /// ?description}], commands:[{...}]}]}`. Insertion order is preserved
  /// (`_capabilities` is a `LinkedHashMap`). The `description` key is omitted
  /// per-declaration when `null` so old apps / old tooling see a stable schema
  /// (decision D3 — backward compatible).
  Map<String, Object?> _aggregateCapabilities() {
    return <String, Object?>{
      'registeredCapabilities': _capabilities.values
          .map((cap) => <String, Object?>{
                'id': cap.id,
                'resources': cap.resources
                    .map((r) => <String, Object?>{
                          'method': r.method,
                          'path': r.path,
                          if (r.description != null) 'description': r.description,
                        })
                    .toList(),
                'commands': cap.commands
                    .map((c) => <String, Object?>{
                          'method': c.method,
                          'path': c.path,
                          if (c.description != null) 'description': c.description,
                        })
                    .toList(),
              })
          .toList(),
    };
  }

  // ---------------------------------------------------------------------------
  // Path matching helpers
  // ---------------------------------------------------------------------------

  bool _matchPath(
    List<String> declaration,
    List<String> actual,
    Map<String, String> pathParams,
  ) {
    if (declaration.length != actual.length) return false;
    for (var i = 0; i < declaration.length; i++) {
      final decl = declaration[i];
      final act = actual[i];
      if (decl.startsWith('{') && decl.endsWith('}')) {
        final name = decl.substring(1, decl.length - 1);
        pathParams[name] = act;
      } else if (decl != act) {
        return false;
      }
    }
    return true;
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
