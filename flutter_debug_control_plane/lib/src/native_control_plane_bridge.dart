import 'dart:async';

import 'package:debug_control_plane/debug_control_plane.dart';
import 'package:flutter/services.dart';

import 'auth_policy.dart';
import 'bridge_capability.dart';
import 'channel_protocol.dart';

/// Called when native reports a pending debug-plane authorization request.
typedef DebugAuthRequestHandler = Future<void> Function(
    DebugAuthRequest request);

/// Native -> Dart pending authorization request.
class DebugAuthRequest {
  const DebugAuthRequest({
    required this.requestId,
    this.reqId,
    this.clientLabel,
    this.endpoint,
    this.method,
    this.createdAt,
  });

  factory DebugAuthRequest.fromChannel(Object? raw) {
    final args = _requiredMap(raw, 'DebugAuthRequest');
    return DebugAuthRequest(
      requestId: _requiredString(args, 'requestId'),
      reqId: _optionalInt(args['reqId']),
      clientLabel: _optionalString(args['clientLabel']),
      endpoint: _optionalString(args['endpoint']),
      method: _optionalString(args['method']),
      createdAt: _optionalDateTime(args['createdAt']),
    );
  }

  final String requestId;
  final int? reqId;
  final String? clientLabel;
  final String? endpoint;
  final String? method;
  final DateTime? createdAt;
}

/// Authorization status exposed to Flutter hosts.
class DebugAuthStatus {
  const DebugAuthStatus({
    required this.status,
    this.requestId,
    this.expiresAt,
    this.clientLabel,
  });

  factory DebugAuthStatus.fromChannel(Object? raw) {
    final args = _requiredMap(raw, 'DebugAuthStatus');
    return DebugAuthStatus(
      status: _requiredString(args, 'status'),
      requestId: _optionalString(args['requestId']),
      expiresAt: _optionalDateTime(args['expiresAt']),
      clientLabel: _optionalString(args['clientLabel']),
    );
  }

  final String status;
  final String? requestId;
  final DateTime? expiresAt;
  final String? clientLabel;
}

/// Token claim data returned by an authorization approval.
class DebugAuthClaim {
  const DebugAuthClaim({
    this.token,
    this.tokenId,
    this.expiresAt,
    this.status,
  });

  factory DebugAuthClaim.fromChannel(Object? raw) {
    final args = _requiredMap(raw, 'DebugAuthClaim');
    return DebugAuthClaim(
      token: _optionalString(args['token']),
      tokenId: _optionalString(args['tokenId']),
      expiresAt: _optionalDateTime(args['expiresAt']),
      status: _optionalString(args['status']),
    );
  }

  final String? token;
  final String? tokenId;
  final DateTime? expiresAt;
  final String? status;
}

/// FF001-3: Dart 侧 native ControlPlane 桥接（Android）。
///
/// 一个 app 一个 server（server 实体在 native，由 FF002-2 Service 载体
/// 装配），本类只经 MethodChannel 转发注册/生命周期/事件/状态（design
/// §3.2.1 公共 API 子集）。iOS / 桌面不使用本类（FF002 走
/// DartControlPlaneHandle 薄转发，零回归）。
///
/// 反向调用（native → Dart `capability.invoke`）：handler 闭包留在 Dart
/// 侧（闭包不可序列化），native dispatch 命中声明后带 `reqId + capId +
/// routeKind + routeIndex` 反向 invokeMethod；本类按
/// `(capId, routeKind, routeIndex)` 查回注册时快照的声明，取其 `handler`
/// 执行后经 `capability.invoke.result` 回填。routeIndex 是注册列表下标，
/// 避免 path 字符串二次匹配（design §3.2.1）。
///
/// 一个实例持有唯一 MethodCallHandler（第二次 attach 未 detach 前直接
/// 抛 [StateError]）；[dispose] 释放 handler。
class NativeControlPlaneBridge {
  /// Create a bridge over [channel] (defaults to [kMethodChannel]).
  NativeControlPlaneBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(kMethodChannel);

  final MethodChannel _channel;

  /// Scope-aware local registry (R003-FF001 KD-1): key =
  /// `(scope, pageId?, capId)` — field-for-field isomorphic with the
  /// R003-BF005 Kotlin `ScopedCapabilityKey`. App key = `(app, null, id)`,
  /// page key = `(page, pageId, id)` — app and page entries sharing a capId,
  /// and page entries with different pageIds sharing a capId, coexist.
  final Map<_ScopedCapabilityKey, _RegisteredCapability> _caps =
      <_ScopedCapabilityKey, _RegisteredCapability>{};

  /// Per-capability event pump subscriptions keyed by the same scope-aware
  /// key as [_caps] (unregister/dispose cancels them — otherwise the
  /// `await for` loops outlive the registration and keep forwarding frames
  /// for an unregistered capId).
  final Map<_ScopedCapabilityKey, StreamSubscription<DebugEvent>> _eventPumps =
      <_ScopedCapabilityKey, StreamSubscription<DebugEvent>>{};

  /// Legacy app-only debug view (R003-FF001 KD-2): contains ONLY app
  /// capability ids. Not a scoped identity source — scoped lookups go
  /// through [_caps] exclusively.
  final Set<String> _registeredIds = <String>{};
  bool _attached = false;
  DebugAuthRequestHandler? _authRequestHandler;

  /// Registered app capability ids, in registration order (legacy app-only
  /// debug view — page capability ids are NOT listed; see KD-2).
  Set<String> get registeredIds => Set<String>.unmodifiable(_registeredIds);

  /// Install the native → Dart reverse-invoke handler (`capability.invoke`
  /// / `capability.state.pull`).
  ///
  /// Not idempotent: attaching while already attached throws [StateError]
  /// (one channel, one handler — avoids silently dropping the previous one).
  /// [dispose] releases the handler and allows attaching again.
  void attach() {
    if (_attached) {
      throw StateError('NativeControlPlaneBridge already attached.');
    }
    _attached = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// Detach the handler and drop all registered capabilities.
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    _attached = false;
    _authRequestHandler = null;
    await _cancelEventPumps(_caps.keys.toList());
    _caps.clear();
    _registeredIds.clear();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle (forward)
  // ---------------------------------------------------------------------------

  /// Start the native plane (`plane.start`).
  ///
  /// [authPolicy] (R006-FF001, optional) selects the assembly-time
  /// authorization policy: omitted → the param stays absent from the
  /// channel payload (byte-compatible with 0.5.1, native assembles the
  /// default policy); non-null → serialized as its lowercase
  /// [AuthPolicy.wireName] and an unknown value fails fast natively with
  /// `invalid_arguments` (the plane is not mounted).
  ///
  /// Returns the bound URI, or `null` if the transport is connection-less.
  /// Native bind failure (EADDRINUSE) resurfaces as a [SocketException]
  /// shaped [PlatformException] (code [kErrorCodeBindFailed], errorCode=98)
  /// — FF002-3 maps it onto the R024 degradation catch.
  Future<Uri?> start({
    required Object address,
    required int port,
    Map<String, Object?> Function()? appMeta,
    AuthPolicy? authPolicy,
  }) async {
    final raw = await _channel.invokeMethod<dynamic>(kMethodPlaneStart, {
      'address': '$address',
      'port': port,
      if (appMeta != null) 'appMeta': appMeta(),
      if (authPolicy != null) kAuthPolicyArgName: authPolicy.wireName,
    });
    final uri = (raw is Map) ? raw['uri'] : raw;
    return uri == null ? null : Uri.parse(uri as String);
  }

  /// Stop the native plane (`plane.stop`).
  Future<void> stop() async {
    await _channel.invokeMethod<void>(kMethodPlaneStop, null);
  }

  // ---------------------------------------------------------------------------
  // Registry (forward)
  // ---------------------------------------------------------------------------

  /// Register [cap] (`capability.register`).
  ///
  /// [cap] must be a [BridgeCapability]-compatible [Capability]: its
  /// `resources` / `commands` declarations are serialized as Decl maps
  /// (**path is a JSON array**, PROTOCOL.md §2.3) and its `events` stream is
  /// collected once (D2) — each frame is forwarded upstream via
  /// `events.emit`. Its current `state()` snapshot is pushed eagerly so the
  /// native cached aggregate is warm from the start (§3.2.4).
  Future<void> register(BridgeCapability cap,
      {CapabilityScope scope = const CapabilityScope.app()}) async {
    // Defensive pageId guard (R003-FF001 KD-3): validation proper lives in
    // the `CapabilityScope.page()` factory (BF002) — this only rejects a
    // malformed page scope before any channel traffic.
    if (scope.type == CapabilityScopeType.page &&
        (scope.pageId == null || scope.pageId!.trim().isEmpty)) {
      throw ArgumentError.value(
        scope.pageId,
        'pageId',
        'must be a non-blank string for page capability scope',
      );
    }
    final key = _ScopedCapabilityKey.fromScope(scope, cap.id);
    if (_caps.containsKey(key)) {
      throw StateError('Capability already registered: $key');
    }
    final resources = cap.resources
        .map((r) => <String, Object?>{
              'method': r.method,
              'path': r.path,
              if (r.description != null) 'description': r.description,
            })
        .toList();
    final commands = cap.commands
        .map((c) => <String, Object?>{
              'method': c.method,
              'path': c.path,
              if (c.description != null) 'description': c.description,
            })
        .toList();

    await _channel.invokeMethod<void>(kMethodCapabilityRegister, {
      'capId': cap.id,
      'resources': resources,
      'commands': commands,
      'scope': scope.type.name,
      if (scope.pageId != null) 'pageId': scope.pageId,
      if (scope.pageName != null) 'pageName': scope.pageName,
    });

    _caps[key] = _RegisteredCapability(
      id: cap.id,
      resources: cap.resources,
      commands: cap.commands,
      state: cap.state,
    );
    // KD-2: legacy app-only debug view — page capability ids never enter.
    if (scope.type == CapabilityScopeType.app) {
      _registeredIds.add(cap.id);
    }

    cap.bindScope(scope);
    _startEventPump(cap, key);
    unawaited(pushState(cap.id, cap.state(), scope: scope));
  }

  /// Unregister the capability with [id] (`capability.unregister`).
  ///
  /// [scope] defaults to app-only (KD-4): the legacy `unregister(id)` call
  /// removes ONLY the `(app, id)` entry — a page capability sharing the same
  /// capId is never touched. Passing a page scope removes exactly that
  /// scope-aware key.
  Future<void> unregister(String id, {CapabilityScope? scope}) async {
    final effective = scope ?? const CapabilityScope.app();
    final key = _ScopedCapabilityKey.fromScope(effective, id);
    await _channel.invokeMethod<void>(kMethodCapabilityUnregister, {
      'capId': id,
      'scope': effective.type.name,
      if (effective.pageId != null) 'pageId': effective.pageId,
    });
    _caps.remove(key);
    if (effective.type == CapabilityScopeType.app) {
      _registeredIds.remove(id);
    }
    await _cancelEventPumps([key]);
  }

  /// Forward one event frame upstream (`events.emit`).
  ///
  /// The Dart-side `sequence` value is discarded — the native bus assigns the
  /// global monotonic sequence (PROTOCOL.md §3.1). [scope] overrides the
  /// registration-time scope snapshot; when omitted, the first registration
  /// matching [capId] (app entries first) supplies the scope identity.
  Future<void> emitEvent(String capId, DebugEvent event,
      {CapabilityScope? scope}) async {
    final effective = scope ?? _scopeFor(capId) ?? const CapabilityScope.app();
    await _channel.invokeMethod<void>(kMethodEventsEmit, {
      'capId': capId,
      'event': {
        'type': event.type,
        'payload': event.payload,
      },
      'scope': effective.type.name,
      if (effective.pageId != null) 'pageId': effective.pageId,
    });
  }

  /// Push a state snapshot into the native cached aggregate
  /// (`capability.state.update`, design §3.2.4 — no runBlocking pull).
  ///
  /// [scope] overrides the registration-time scope snapshot; when omitted,
  /// the first registration matching [capId] (app entries first) supplies the
  /// scope identity.
  Future<void> pushState(String capId, Map<String, Object?> state,
      {CapabilityScope? scope}) async {
    final effective = scope ?? _scopeFor(capId) ?? const CapabilityScope.app();
    await _channel.invokeMethod<void>(kMethodCapabilityStateUpdate, {
      'capId': capId,
      'state': state,
      'scope': effective.type.name,
      if (effective.pageId != null) 'pageId': effective.pageId,
    });
  }

  /// Resolve the registration-time scope for [capId] (app entries win over
  /// page entries — the eager state push and event pump both target app
  /// registration first). Returns `null` for an unregistered capId.
  CapabilityScope? _scopeFor(String capId) {
    for (final entry in _caps.entries) {
      if (entry.value.id != capId) continue;
      final key = entry.key;
      if (key.scopeType == CapabilityScopeType.app) {
        return const CapabilityScope.app();
      }
    }
    for (final entry in _caps.entries) {
      if (entry.value.id != capId) continue;
      final key = entry.key;
      if (key.pageId case final pageId?) {
        return CapabilityScope.page(pageId: pageId);
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Authorization (forward + native pending callback)
  // ---------------------------------------------------------------------------

  /// Register or clear the native -> Dart pending authorization handler.
  void setAuthorizationHandler(DebugAuthRequestHandler? handler) {
    _authRequestHandler = handler;
  }

  /// Approve a pending authorization request.
  Future<DebugAuthClaim?> approveAuthorization(
    String requestId, {
    Duration? ttl,
    String? clientLabel,
  }) async {
    final raw = await _channel.invokeMethod<dynamic>(kMethodAuthApprove, {
      'requestId': requestId,
      if (ttl != null) 'ttlSeconds': ttl.inSeconds,
      if (clientLabel != null) 'clientLabel': clientLabel,
    });
    return raw == null ? null : DebugAuthClaim.fromChannel(raw);
  }

  /// Deny a pending authorization request.
  Future<void> denyAuthorization(String requestId, {String? reason}) async {
    await _channel.invokeMethod<void>(kMethodAuthDeny, {
      'requestId': requestId,
      if (reason != null) 'reason': reason,
    });
  }

  /// Revoke a single token or all tokens.
  Future<void> revokeAuthorization({String? tokenId, bool all = false}) async {
    if (tokenId == null && !all) {
      throw ArgumentError(
          'Either tokenId must be provided or all must be true.');
    }
    await _channel.invokeMethod<void>(kMethodAuthRevoke, {
      if (tokenId != null) 'tokenId': tokenId,
      if (all) 'all': true,
    });
  }

  /// Read the current authorization status.
  Future<DebugAuthStatus> authorizationStatus({String? requestId}) async {
    final raw = await _channel.invokeMethod<dynamic>(kMethodAuthStatus, {
      if (requestId != null) 'requestId': requestId,
    });
    return DebugAuthStatus.fromChannel(raw);
  }

  // ---------------------------------------------------------------------------
  // Reverse invoke handling (native → Dart)
  // ---------------------------------------------------------------------------

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case kMethodCapabilityInvoke:
        return _handleCapabilityInvoke(call);
      case kMethodCapabilityStatePull:
        return _handleCapabilityStatePull(call);
      case kMethodAuthRequest:
        return _handleAuthRequest(call);
      default:
        throw MissingPluginException(call.method);
    }
  }

  Future<void> _handleAuthRequest(MethodCall call) async {
    final handler = _authRequestHandler;
    if (handler == null) {
      return;
    }
    try {
      await handler(DebugAuthRequest.fromChannel(call.arguments));
    } catch (_) {
      // Auth pending is intentionally independent from capability.invoke fill-in
      // semantics; native owns pending expiry and status transitions.
    }
  }

  Future<void> _handleCapabilityInvoke(MethodCall call) async {
    final args =
        (call.arguments as Map<Object?, Object?>).cast<String, Object?>();
    final reqId = args['reqId'] as int;
    final capId = args['capId'] as String;
    final routeKind = args['routeKind'] as String;
    final routeIndex = args['routeIndex'] as int;
    // KD-4: a missing `scope` field is the legacy format — routed as the app
    // key. `scope='page'` with `pageId` routes to the page entry.
    final scopeName = args['scope'] as String?;
    final pageId = args['pageId'] as String?;
    final pathParamsRaw = args['pathParams'] as Map<Object?, Object?>?;
    final pathParams = (pathParamsRaw ?? const <Object?, Object?>{})
        .map((k, v) => MapEntry(k as String, v as String));
    final bodyRaw = args['body'] as Map<Object?, Object?>?;
    final body = bodyRaw?.cast<String, Object?>() ?? const <String, Object?>{};

    try {
      final cap = _caps[_routeKeyFromPayload(scopeName, pageId, capId)];
      if (cap == null) {
        throw RouteFailure(404, 'not_registered',
            'Capability not registered on the Dart side: $capId');
      }
      final ctx =
          RouteContext(pathParams: pathParams, body: body, request: null);
      final Future<Map<String, Object?>> Function(RouteContext) handler;
      if (routeKind == kRouteKindResource) {
        handler = _handlerAt(cap.resources, routeIndex, capId).handler;
      } else if (routeKind == kRouteKindCommand) {
        handler = _handlerAt(cap.commands, routeIndex, capId).handler;
      } else {
        throw RouteFailure(
            500, 'internal_error', 'Unknown routeKind: $routeKind');
      }
      final result = await handler(ctx);
      await _fillInvokeResult(reqId, result: result);
    } on RouteFailure catch (error) {
      await _fillInvokeResult(reqId, error: (
        statusCode: error.statusCode,
        code: error.code,
        message: error.message
      ));
    } catch (error) {
      await _fillInvokeResult(reqId, error: (
        statusCode: 500,
        code: 'internal_error',
        message: error.toString()
      ));
    }
  }

  /// Fill one reverse invoke back to native (`capability.invoke.result`).
  ///
  /// Exactly one of [result] / [error] is present — the single construction
  /// site of the fill-in payload (previously three near-identical copies).
  Future<void> _fillInvokeResult(
    int reqId, {
    Map<String, Object?>? result,
    ({int statusCode, String code, String message})? error,
  }) async {
    await _channel.invokeMethod<void>(kMethodCapabilityInvokeResult, {
      'reqId': reqId,
      if (error == null) 'result': result ?? const <String, Object?>{},
      if (error != null)
        'error': {
          'statusCode': error.statusCode,
          'code': error.code,
          'message': error.message,
        },
    });
  }

  Future<void> _handleCapabilityStatePull(MethodCall call) async {
    final args =
        (call.arguments as Map<Object?, Object?>).cast<String, Object?>();
    final reqId = args['reqId'] as int;
    final capId = args['capId'] as String;
    // Same legacy-compatible routing as `capability.invoke` (KD-4): missing
    // `scope` reads the app entry.
    final scopeName = args['scope'] as String?;
    final pageId = args['pageId'] as String?;
    final state = _caps[_routeKeyFromPayload(scopeName, pageId, capId)]?.state() ??
        const <String, Object?>{};
    await _channel.invokeMethod<void>(kMethodCapabilityStateResult, {
      'reqId': reqId,
      'state': state,
    });
    return null;
  }

  /// Build the lookup key from a native→Dart payload (KD-4): a missing
  /// `scope` field is the legacy format — routed as the app key.
  /// `scope='page'` with `pageId` routes to the page entry.
  _ScopedCapabilityKey _routeKeyFromPayload(
      String? scopeName, String? pageId, String capId) {
    return (scopeName == CapabilityScopeType.page.name)
        ? _ScopedCapabilityKey(
            scopeType: CapabilityScopeType.page, pageId: pageId, capId: capId)
        : _ScopedCapabilityKey(
            scopeType: CapabilityScopeType.app, pageId: null, capId: capId);
  }

  R _handlerAt<R>(List<R> list, int index, String capId) {
    if (index < 0 || index >= list.length) {
      throw RouteFailure(500, 'internal_error',
          'routeIndex $index out of range for capability $capId');
    }
    return list[index];
  }

  /// Start the events-upstream pump for [cap] (one per capability).
  ///
  /// Subscription-based (not a bare `await for`): unregister/dispose cancels
  /// it via [_cancelEventPumps], so frames stop crossing the channel for an
  /// unregistered capId and the capability's source stream can be released.
  void _startEventPump(BridgeCapability cap, _ScopedCapabilityKey key) {
    late final StreamSubscription<DebugEvent> subscription;
    try {
      final boundScope = cap.boundScope;
      subscription = cap.events.listen(
        (event) => unawaited(
            emitEvent(cap.id, event, scope: boundScope ?? const CapabilityScope.app())),
      );
    } on StateError {
      // D2 single-subscription: the producer's events stream was already
      // collected (e.g. the capability is also registered elsewhere) —
      // nothing to forward, not a bridge failure.
      return;
    }
    _eventPumps[key] = subscription;
  }

  Future<void> _cancelEventPumps(List<_ScopedCapabilityKey> keys) async {
    for (final key in keys) {
      await _eventPumps.remove(key)?.cancel();
    }
  }
}

/// Scope-aware local registry key (R003-FF001 KD-1) — field-for-field
/// isomorphic with the R003-BF005 Kotlin `ScopedCapabilityKey(scope,
/// pageId?, capabilityId)`. App key = `(app, null, id)`; page key =
/// `(page, pageId, id)`. `pageName` is NOT part of the key (display metadata
/// only).
class _ScopedCapabilityKey {
  const _ScopedCapabilityKey({
    required this.scopeType,
    required this.pageId,
    required this.capId,
  });

  factory _ScopedCapabilityKey.fromScope(CapabilityScope scope, String capId) =>
      _ScopedCapabilityKey(
        scopeType: scope.type,
        pageId: scope.pageId,
        capId: capId,
      );

  final CapabilityScopeType scopeType;
  final String? pageId;
  final String capId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ScopedCapabilityKey &&
          other.scopeType == scopeType &&
          other.pageId == pageId &&
          other.capId == capId;

  @override
  int get hashCode => Object.hash(scopeType, pageId, capId);

  @override
  String toString() =>
      '(scope: ${scopeType.name}, pageId: $pageId, capId: $capId)';
}

/// Registration-time snapshot backing reverse-invoke lookup.
class _RegisteredCapability {
  _RegisteredCapability({
    required this.id,
    required this.resources,
    required this.commands,
    required this.state,
  });

  final String id;
  final List<Resource> resources;
  final List<Command> commands;
  final Map<String, Object?> Function() state;
}

Map<String, Object?> _requiredMap(Object? raw, String label) {
  if (raw is! Map) {
    throw ArgumentError('$label payload must be a map.');
  }
  return raw.cast<String, Object?>();
}

String _requiredString(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw ArgumentError('Missing required string field: $key.');
}

String? _optionalString(Object? value) => value is String ? value : null;

int? _optionalInt(Object? value) => value is int ? value : null;

DateTime? _optionalDateTime(Object? value) {
  if (value is DateTime) {
    return value;
  }
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  if (value is String) {
    return DateTime.tryParse(value);
  }
  return null;
}
