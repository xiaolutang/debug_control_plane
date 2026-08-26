import 'dart:async';

import 'capability.dart';
import 'debug_event.dart';
import 'debug_auth.dart';
import 'http_sse_transport.dart';
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
  ControlPlane({
    required this.transport,
    this.appMeta,
    this.authManager,
  });

  /// The transport this plane routes through.
  final Transport transport;

  /// Injected app metadata provider for `/hello`.
  final Map<String, Object?> Function()? appMeta;

  /// Optional App-side debug auth boundary. `null` preserves bare mode.
  final DebugAuthManager? authManager;

  final Map<_ScopedCapabilityKey, _CapabilityEntry> _capabilities =
      <_ScopedCapabilityKey, _CapabilityEntry>{};

  // Aggregated event subscriptions per scoped capability (kept so unregister
  // can cancel cleanly without touching another app/page capability with the
  // same public id).
  final Map<_ScopedCapabilityKey, StreamSubscription<DebugEvent>> _eventSubs =
      <_ScopedCapabilityKey, StreamSubscription<DebugEvent>>{};

  final StreamController<DebugEvent> _eventBus =
      StreamController<DebugEvent>.broadcast(sync: true);

  int _nextSequence = 0;
  int _scopeRevision = 0;

  /// The global event bus. Transports subscribe here to encode `/events`
  /// (SSE / WS / MCP). Events flow in when capabilities emit on their
  /// [Capability.events] stream.
  Stream<DebugEvent> get eventBus => _eventBus.stream;

  /// All registered capability ids.
  Iterable<String> get registeredIds =>
      _capabilities.values.map((entry) => entry.capability.id);

  // ---------------------------------------------------------------------------
  // Registry
  // ---------------------------------------------------------------------------

  /// Register [cap]. Throws [StateError] if a capability with the same scoped
  /// identity is already registered. Legacy capabilities default to app scope.
  void register(Capability cap) {
    final scope = cap.scope;
    final key = _ScopedCapabilityKey.from(capabilityId: cap.id, scope: scope);
    if (_capabilities.containsKey(key)) {
      throw StateError(
        'Capability already registered: ${key.describe()}',
      );
    }
    final entry = _CapabilityEntry(
      capability: cap,
      scope: scope,
      scopeRevision: ++_scopeRevision,
    );
    _capabilities[key] = entry;
    _eventSubs[key] = cap.events.listen(_onCapabilityEvent);
    _emitScopeChanged('registered', entry);
  }

  /// Unregister the app-scoped capability with the given [id].
  ///
  /// This preserves the legacy API: page capabilities with the same id remain
  /// registered and must be removed with [unregisterScoped].
  void unregister(String id) {
    unregisterScoped(scope: const CapabilityScope.app(), capabilityId: id);
  }

  /// Unregister the capability identified by [scope] and [capabilityId].
  ///
  /// Missing scoped keys are a no-op.
  void unregisterScoped({
    required CapabilityScope scope,
    required String capabilityId,
  }) {
    final key = _ScopedCapabilityKey.from(
      capabilityId: capabilityId,
      scope: scope,
    );
    final entry = _capabilities.remove(key);
    if (entry == null) return;
    _eventSubs.remove(key)?.cancel();
    _scopeRevision += 1;
    _emitScopeChanged('unregistered', entry, scopeRevision: _scopeRevision);
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
    if (authManager != null && transport is HttpSseTransport) {
      (transport as HttpSseTransport).setEventsPreflight(_eventsPreflight);
    }
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
    _capabilities.clear();
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
        final result = await system(req);
        return RouteResult(statusCode: result.statusCode, body: result.body);
      }

      // Capability routes are sensitive. Authorize before selector parsing,
      // scoped lookup, revision checks, or path matching so unauthenticated
      // callers cannot infer page capability existence.
      final denied = await _authorize(req);
      if (denied != null) return _authDeniedResult(denied);

      final selector = _CapabilitySelector.parse(req.headers);
      if (selector.isPresent) {
        return await _dispatchSelected(req, selector);
      }

      final flat = await _dispatchFlat(req, _capabilities.values);
      if (flat != null) return flat;

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

  Future<RouteResult> Function(RouteRequest req)? _matchSystemRoute(
      String method, List<String> segments) {
    if (method == 'GET' && _listEquals(segments, const ['hello'])) {
      return _handleHello;
    }
    if (method == 'GET' && _listEquals(segments, const ['state'])) {
      return _handleState;
    }
    if (method == 'GET' && _listEquals(segments, const ['events'])) {
      return _handleEvents;
    }
    if (method == 'POST' && _listEquals(segments, const ['auth', 'request'])) {
      return _handleAuthRequest;
    }
    if (method == 'POST' && _listEquals(segments, const ['auth', 'status'])) {
      return _handleAuthStatus;
    }
    if (method == 'POST' && _listEquals(segments, const ['auth', 'claim'])) {
      return _handleAuthClaim;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // System route handlers
  // ---------------------------------------------------------------------------

  Future<RouteResult> _handleHello(RouteRequest req) async {
    final auth = authManager;
    if (auth != null) {
      final token = DebugAuth.bearerToken(req.headers);
      final authReq = _toAuthRequest(req, AuthRouteClass.helloBootstrap);
      final decision = await auth.authorize(authReq);
      if (decision is AuthDenied) {
        return RouteResult.ok(await _minimalAuthHello(req, decision));
      }
      return RouteResult.ok(<String, Object?>{
        ...await _fullHello(req),
        ...await auth.helloAuthState(token),
      });
    }
    return RouteResult.ok(await _fullHello(req));
  }

  Future<Map<String, Object?>> _fullHello(RouteRequest req) async {
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

  Future<Map<String, Object?>> _minimalAuthHello(
    RouteRequest req,
    AuthDenied decision,
  ) async {
    final meta = appMeta?.call() ?? const <String, Object?>{};
    final safeMeta = <String, Object?>{
      for (final key in const ['app', 'deviceId', 'deviceName', 'platform'])
        if (meta.containsKey(key)) key: meta[key],
    };
    return <String, Object?>{
      'protocolVersion': kDebugControlPlaneProtocolVersion,
      ...safeMeta,
      ...await transport.serverInfo(req.request),
      'eventsEndpoint': '/events',
      'profileRevision': 1,
      'authRequired': true,
      'authStatus': decision.code,
      'authEndpoints': const <String, String>{
        'request': '/auth/request',
        'status': '/auth/status',
        'claim': '/auth/claim',
      },
    };
  }

  Future<RouteResult> _handleState(RouteRequest req) async {
    // Byte-level parity with the legacy launcher `/state` body: the legacy
    // `_statePayload()` returned the flat aggregate state with no top-level
    // `ok` flag. Adding `ok` here would diverge from the TEST01 contract
    // (golden snapshot). R019-FF002 contract-alignment (extension of BF002.0
    // which originally only named `/hello`).
    final denied = await _authorize(req);
    if (denied != null) return _authDeniedResult(denied);
    return RouteResult.ok(_aggregateState());
  }

  Future<RouteResult> _handleEvents(RouteRequest req) async {
    // `/events` is a long-lived stream handshake in the BF002 transport
    // (text/event-stream). The framework exposes the data source via
    // [eventBus]; the wire-level implementation lives in `HttpSseTransport`.
    // Direct GET /events through this code path (without a transport that
    // hijacks the connection) returns the current bus subscription info so
    // the route is non-404 and introspectable.
    final denied = await _authorize(req);
    if (denied != null) return _authDeniedResult(denied);
    return RouteResult.ok(<String, Object?>{
      'ok': true,
      'note': 'event_bus_is_stream',
      'eventsEndpoint': '/events',
    });
  }

  Future<RouteResult> _handleAuthRequest(RouteRequest req) async =>
      _authRouteResult(
        await (authManager?.requestAuthorization(req.body) ??
            Future<AuthRouteResult>.value(AuthRouteDenied(
              statusCode: 401,
              code: 'authorization_required',
              message: 'Debug authorization is required.',
            ))),
      );

  Future<RouteResult> _handleAuthStatus(RouteRequest req) async =>
      _authRouteResult(
        await (authManager?.authorizationStatus(req.body) ??
            Future<AuthRouteResult>.value(AuthRouteDenied(
              statusCode: 401,
              code: 'authorization_required',
              message: 'Debug authorization is required.',
            ))),
      );

  Future<RouteResult> _handleAuthClaim(RouteRequest req) async =>
      _authRouteResult(
        await (authManager?.claimAuthorization(req.body) ??
            Future<AuthRouteResult>.value(AuthRouteDenied(
              statusCode: 401,
              code: 'authorization_required',
              message: 'Debug authorization is required.',
            ))),
      );

  RouteResult _authRouteResult(AuthRouteResult result) {
    return switch (result) {
      AuthRouteOk(:final body, :final statusCode) =>
        RouteResult(statusCode: statusCode, body: body),
      AuthRouteDenied(:final statusCode, :final code, :final message) =>
        RouteResult.error(statusCode, code, message),
    };
  }

  Future<RouteResult?> _eventsPreflight(RouteRequest req) async {
    final denied = await _authorize(req);
    return denied == null ? null : _authDeniedResult(denied);
  }

  Future<AuthDenied?> _authorize(RouteRequest req) async {
    final auth = authManager;
    if (auth == null) return null;
    final decision = await auth.authorize(_toAuthRequest(req));
    return decision is AuthDenied ? decision : null;
  }

  AuthRequest _toAuthRequest(
    RouteRequest req, [
    AuthRouteClass? routeClass,
  ]) {
    final classified =
        routeClass ?? DebugAuth.classifyRoute(req.method, req.segments);
    return AuthRequest(
      method: req.method,
      segments: List<String>.unmodifiable(req.segments),
      routeClass: classified,
      bearerToken: DebugAuth.bearerToken(req.headers),
      body: req.body,
      request: req.request,
    );
  }

  RouteResult _authDeniedResult(AuthDenied denied) => RouteResult.error(
        denied.statusCode,
        denied.code,
        denied.message,
      );

  Map<String, Object?> _aggregateState() {
    final state = <String, Object?>{};
    for (final entry in _capabilities.values) {
      if (entry.scope.type != CapabilityScopeType.app) continue;
      final cap = entry.capability;
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
      'registeredCapabilities':
          _capabilities.values.map(_capabilityEntryToJson).toList(),
    };
  }

  Map<String, Object?> _capabilityEntryToJson(_CapabilityEntry entry) {
    final cap = entry.capability;
    final scope = entry.scope;
    final emitsScopeMetadata = cap is ScopedCapability;
    return <String, Object?>{
      'id': cap.id,
      if (emitsScopeMetadata) 'scope': scope.type.name,
      if (emitsScopeMetadata && scope.type == CapabilityScopeType.page)
        'pageId': scope.pageId,
      if (emitsScopeMetadata && scope.pageName != null)
        'pageName': scope.pageName,
      if (emitsScopeMetadata) 'scopeRevision': entry.scopeRevision,
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
    };
  }

  Future<RouteResult?> _dispatchFlat(
    RouteRequest req,
    Iterable<_CapabilityEntry> entries,
  ) async {
    if (req.method == 'GET') {
      for (final entry in entries) {
        final result = await _dispatchResources(req, entry.capability);
        if (result != null) return result;
      }
    } else if (req.method == 'POST') {
      for (final entry in entries) {
        final result = await _dispatchCommands(req, entry.capability);
        if (result != null) return result;
      }
    }
    return null;
  }

  Future<RouteResult> _dispatchSelected(
    RouteRequest req,
    _CapabilitySelector selector,
  ) async {
    final key = selector.key;
    if (key == null) {
      return RouteResult.error(
        404,
        'not_found',
        'Endpoint was not found.',
      );
    }

    final entry = _capabilities[key];
    if (entry == null && key.scope == CapabilityScopeType.page) {
      return RouteResult.error(
        410,
        'page_capability_gone',
        'Page capability is no longer available. Refresh /hello before invoking tools.',
      );
    }
    if (entry == null) {
      return RouteResult.error(
        404,
        'not_found',
        'Endpoint was not found.',
      );
    }

    final requestedRevision = selector.scopeRevision;
    if (requestedRevision != null && requestedRevision != entry.scopeRevision) {
      return RouteResult.error(
        409,
        'capability_scope_expired',
        'Capability scope mirror expired. Refresh /hello before invoking tools.',
      );
    }

    final result = await _dispatchFlat(req, <_CapabilityEntry>[entry]);
    if (result != null) return result;
    return RouteResult.error(
      404,
      'not_found',
      'Endpoint was not found.',
    );
  }

  Future<RouteResult?> _dispatchResources(
    RouteRequest req,
    Capability cap,
  ) async {
    for (final decl in cap.resources) {
      if (decl.method != req.method) continue;
      final pathParams = <String, String>{};
      if (!_matchPath(decl.path, req.segments, pathParams)) continue;
      final ctx = RouteContext(
        pathParams: pathParams,
        body: req.body,
        request: req.request,
      );
      return RouteResult.ok(await decl.handler(ctx));
    }
    return null;
  }

  Future<RouteResult?> _dispatchCommands(
    RouteRequest req,
    Capability cap,
  ) async {
    for (final decl in cap.commands) {
      if (decl.method != req.method) continue;
      final pathParams = <String, String>{};
      if (!_matchPath(decl.path, req.segments, pathParams)) continue;
      final ctx = RouteContext(
        pathParams: pathParams,
        body: req.body,
        request: req.request,
      );
      return RouteResult.ok(await decl.handler(ctx));
    }
    return null;
  }

  void _emitScopeChanged(
    String change,
    _CapabilityEntry entry, {
    int? scopeRevision,
  }) {
    final scope = entry.scope;
    _onCapabilityEvent(DebugEvent(
      type: 'capability_scope_changed',
      sequence: -1,
      payload: <String, Object?>{
        'change': change,
        'scope': scope.type.name,
        'capabilityId': entry.capability.id,
        if (scope.type == CapabilityScopeType.page) 'pageId': scope.pageId,
        if (scope.pageName != null) 'pageName': scope.pageName,
        'scopeRevision': scopeRevision ?? entry.scopeRevision,
      },
    ));
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

final class _CapabilityEntry {
  const _CapabilityEntry({
    required this.capability,
    required this.scope,
    required this.scopeRevision,
  });

  final Capability capability;
  final CapabilityScope scope;
  final int scopeRevision;
}

final class _ScopedCapabilityKey {
  const _ScopedCapabilityKey._({
    required this.scope,
    required this.capabilityId,
    this.pageId,
  });

  factory _ScopedCapabilityKey.from({
    required CapabilityScope scope,
    required String capabilityId,
  }) {
    return _ScopedCapabilityKey._(
      scope: scope.type,
      capabilityId: capabilityId,
      pageId: scope.type == CapabilityScopeType.page ? scope.pageId : null,
    );
  }

  final CapabilityScopeType scope;
  final String capabilityId;
  final String? pageId;

  String describe() {
    if (scope == CapabilityScopeType.app) return 'app/$capabilityId';
    return 'page/$pageId/$capabilityId';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ScopedCapabilityKey &&
          other.scope == scope &&
          other.capabilityId == capabilityId &&
          other.pageId == pageId;

  @override
  int get hashCode => Object.hash(scope, capabilityId, pageId);
}

final class _CapabilitySelector {
  const _CapabilitySelector._({
    required this.isPresent,
    required this.key,
    required this.scopeRevision,
  });

  factory _CapabilitySelector.parse(Map<String, String> headers) {
    final capabilityId = _header(headers, 'X-DCP-Capability-Id');
    final scopeValue = _header(headers, 'X-DCP-Capability-Scope');
    final pageId = _header(headers, 'X-DCP-Page-Id');
    final revisionValue = _header(headers, 'X-DCP-Scope-Revision');
    final present = capabilityId != null ||
        scopeValue != null ||
        pageId != null ||
        revisionValue != null;
    if (!present) {
      return const _CapabilitySelector._(
        isPresent: false,
        key: null,
        scopeRevision: null,
      );
    }

    final scope = switch (scopeValue) {
      'app' => CapabilityScopeType.app,
      'page' => CapabilityScopeType.page,
      _ => null,
    };
    final revision = revisionValue == null ? null : int.tryParse(revisionValue);
    final complete = capabilityId != null &&
        capabilityId.isNotEmpty &&
        scope != null &&
        (scope == CapabilityScopeType.app ||
            (pageId != null && pageId.isNotEmpty));
    return _CapabilitySelector._(
      isPresent: true,
      key: complete
          ? _ScopedCapabilityKey._(
              scope: scope,
              capabilityId: capabilityId,
              pageId: scope == CapabilityScopeType.page ? pageId : null,
            )
          : null,
      scopeRevision: revision,
    );
  }

  final bool isPresent;
  final _ScopedCapabilityKey? key;
  final int? scopeRevision;
}

String? _header(Map<String, String> headers, String name) {
  final lowerName = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() != lowerName) continue;
    final value = entry.value.trim();
    return value.isEmpty ? null : value;
  }
  return null;
}
