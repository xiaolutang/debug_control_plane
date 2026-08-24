import 'dart:async';

import 'package:debug_control_plane/debug_control_plane.dart';
import 'package:flutter/services.dart';

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

  final Map<String, _RegisteredCapability> _caps =
      <String, _RegisteredCapability>{};

  /// Per-capability event pump subscriptions (unregister/dispose cancels
  /// them — otherwise the `await for` loops outlive the registration and
  /// keep forwarding frames for an unregistered capId).
  final Map<String, StreamSubscription<DebugEvent>> _eventPumps =
      <String, StreamSubscription<DebugEvent>>{};

  final Set<String> _registeredIds = <String>{};
  bool _attached = false;
  DebugAuthRequestHandler? _authRequestHandler;

  /// All registered capability ids, in registration order.
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
  /// Returns the bound URI, or `null` if the transport is connection-less.
  /// Native bind failure (EADDRINUSE) resurfaces as a [SocketException]
  /// shaped [PlatformException] (code [kErrorCodeBindFailed], errorCode=98)
  /// — FF002-3 maps it onto the R024 degradation catch.
  Future<Uri?> start({
    required Object address,
    required int port,
    Map<String, Object?> Function()? appMeta,
  }) async {
    final raw = await _channel.invokeMethod<dynamic>(kMethodPlaneStart, {
      'address': '$address',
      'port': port,
      if (appMeta != null) 'appMeta': appMeta(),
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
  Future<void> register(BridgeCapability cap) async {
    if (_caps.containsKey(cap.id)) {
      throw StateError('Capability already registered: ${cap.id}');
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
    });

    _caps[cap.id] = _RegisteredCapability(
      id: cap.id,
      resources: cap.resources,
      commands: cap.commands,
      state: cap.state,
    );
    _registeredIds.add(cap.id);

    _startEventPump(cap);
    unawaited(pushState(cap.id, cap.state()));
  }

  /// Unregister the capability with [id] (`capability.unregister`).
  Future<void> unregister(String id) async {
    await _channel
        .invokeMethod<void>(kMethodCapabilityUnregister, {'capId': id});
    _caps.remove(id);
    _registeredIds.remove(id);
    await _cancelEventPumps([id]);
  }

  /// Forward one event frame upstream (`events.emit`).
  ///
  /// The Dart-side `sequence` value is discarded — the native bus assigns the
  /// global monotonic sequence (PROTOCOL.md §3.1).
  Future<void> emitEvent(String capId, DebugEvent event) async {
    await _channel.invokeMethod<void>(kMethodEventsEmit, {
      'capId': capId,
      'event': {
        'type': event.type,
        'payload': event.payload,
      },
    });
  }

  /// Push a state snapshot into the native cached aggregate
  /// (`capability.state.update`, design §3.2.4 — no runBlocking pull).
  Future<void> pushState(String capId, Map<String, Object?> state) async {
    await _channel.invokeMethod<void>(kMethodCapabilityStateUpdate, {
      'capId': capId,
      'state': state,
    });
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
    final pathParamsRaw = args['pathParams'] as Map<Object?, Object?>?;
    final pathParams = (pathParamsRaw ?? const <Object?, Object?>{})
        .map((k, v) => MapEntry(k as String, v as String));
    final bodyRaw = args['body'] as Map<Object?, Object?>?;
    final body = bodyRaw?.cast<String, Object?>() ?? const <String, Object?>{};

    try {
      final cap = _caps[capId];
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
    final state = _caps[capId]?.state() ?? const <String, Object?>{};
    await _channel.invokeMethod<void>(kMethodCapabilityStateResult, {
      'reqId': reqId,
      'state': state,
    });
    return null;
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
  void _startEventPump(BridgeCapability cap) {
    late final StreamSubscription<DebugEvent> subscription;
    try {
      subscription = cap.events.listen(
        (event) => unawaited(emitEvent(cap.id, event)),
      );
    } on StateError {
      // D2 single-subscription: the producer's events stream was already
      // collected (e.g. the capability is also registered elsewhere) —
      // nothing to forward, not a bridge failure.
      return;
    }
    _eventPumps[cap.id] = subscription;
  }

  Future<void> _cancelEventPumps(List<String> capIds) async {
    for (final capId in capIds) {
      await _eventPumps.remove(capId)?.cancel();
    }
  }
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
