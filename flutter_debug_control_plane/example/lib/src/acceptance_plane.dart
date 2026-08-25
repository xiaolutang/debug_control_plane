import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:debug_control_plane/debug_control_plane.dart';

typedef AcceptanceRequestLogSink = void Function(AcceptanceRequestLogEntry);

class AcceptancePlane {
  AcceptancePlane({
    AcceptanceRequestLogSink? onRequestLog,
    DateTime Function()? now,
    Random? random,
  }) : authManager = AcceptanceDebugAuthManager(
          onRequestLog: onRequestLog,
          now: now ?? DateTime.now,
          random: random ?? Random.secure(),
        );

  final AcceptanceDebugAuthManager authManager;

  ControlPlane? _plane;
  Uri? _endpoint;

  Uri? get endpoint => _endpoint;

  bool get isRunning => _endpoint != null;

  Future<Uri> startDartPlane({
    Object? address,
    int port = 0,
  }) async {
    if (_endpoint != null) return _endpoint!;

    final transport = HttpSseTransport();
    final plane = ControlPlane(
      transport: transport,
      authManager: authManager,
      appMeta: () => <String, Object?>{
        'app': 'flutter-auth-acceptance-app',
        'deviceId': 'acceptance-simulator',
        'deviceName': 'Acceptance Simulator',
        'platform': Platform.operatingSystem,
      },
    );
    for (final capability in buildCapabilities()) {
      plane.register(capability);
    }

    final bound = await plane.start(
      address: address ?? InternetAddress.loopbackIPv4,
      port: port,
    );
    if (bound == null) {
      throw StateError('HttpSseTransport did not return an endpoint.');
    }
    _plane = plane;
    _endpoint = bound;
    authManager.recordSystem(
      route: '/plane/start',
      statusCode: 200,
      authResult: 'plane_started',
      message: bound.toString(),
    );
    return bound;
  }

  Future<void> stop() async {
    final plane = _plane;
    _plane = null;
    _endpoint = null;
    await plane?.stop();
  }

  List<Capability> buildCapabilities() => <Capability>[
        _EchoCapability(authManager),
        _DeviceInfoCapability(authManager, () => _endpoint),
        _SecureActionCapability(authManager),
        _ErrorCaseCapability(authManager),
      ];
}

class AcceptanceDebugAuthManager implements DebugAuthManager {
  AcceptanceDebugAuthManager({
    AcceptanceRequestLogSink? onRequestLog,
    DateTime Function()? now,
    Random? random,
    Duration tokenTtl = const Duration(minutes: 15),
  })  : _onRequestLog = onRequestLog,
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure(),
        _tokenTtl = tokenTtl;

  final AcceptanceRequestLogSink? _onRequestLog;
  final DateTime Function() _now;
  final Random _random;
  final Duration _tokenTtl;
  final Map<String, _PendingAuthorization> _pending =
      <String, _PendingAuthorization>{};
  final Map<String, _IssuedToken> _tokens = <String, _IssuedToken>{};

  String? _activeToken;
  int _logSequence = 0;

  bool get tokenPresent => _activeToken != null;

  String? get activeToken => _activeToken;

  Iterable<String> get pendingRequestIds => _pending.keys;

  Future<void> approvePending(String requestId) async {
    final pending = _pending[requestId];
    if (pending == null) return;
    pending.status = AcceptanceAuthStatus.approved;
    _emit(
      method: 'POST',
      route: '/auth/status',
      statusCode: 200,
      authResult: 'approved',
      requestId: requestId,
      clientLabel: pending.clientLabel,
    );
  }

  Future<void> denyPending(String requestId) async {
    final pending = _pending[requestId];
    if (pending == null) return;
    pending.status = AcceptanceAuthStatus.denied;
    _emit(
      method: 'POST',
      route: '/auth/status',
      statusCode: 403,
      authResult: 'denied',
      requestId: requestId,
      clientLabel: pending.clientLabel,
    );
  }

  void clearToken() {
    if (_activeToken != null) {
      _tokens.remove(_activeToken);
    }
    _activeToken = null;
    recordSystem(
      route: '/auth/token',
      statusCode: 200,
      authResult: 'cleared',
    );
  }

  void expireToken() {
    final token = _activeToken;
    if (token == null) return;
    final issued = _tokens[token];
    if (issued == null) return;
    issued.expiresAt = _now().subtract(const Duration(seconds: 1));
    recordSystem(
      route: '/auth/token',
      statusCode: 200,
      authResult: 'expired',
    );
  }

  void recordCapability({
    required String method,
    required String route,
    required String capability,
    required int statusCode,
    required String authResult,
    String? message,
  }) {
    _emit(
      method: method,
      route: route,
      capability: capability,
      statusCode: statusCode,
      authResult: authResult,
      message: message,
    );
  }

  void recordSystem({
    required String route,
    required int statusCode,
    required String authResult,
    String? message,
  }) {
    _emit(
      method: 'SYSTEM',
      route: route,
      statusCode: statusCode,
      authResult: authResult,
      message: message,
    );
  }

  @override
  Future<AuthDecision> authorize(AuthRequest request) async {
    if (request.routeClass != AuthRouteClass.sensitive) {
      return const AuthAuthorized();
    }

    final token = request.bearerToken;
    if (token == null) {
      _emitDenied(request, DebugAuth.authorizationRequired());
      return DebugAuth.authorizationRequired();
    }
    final issued = _tokens[token];
    if (issued == null) {
      final denied = DebugAuth.invalidToken();
      _emitDenied(request, denied);
      return denied;
    }
    if (!issued.expiresAt.isAfter(_now())) {
      final denied = DebugAuth.tokenExpired();
      _emitDenied(request, denied);
      return denied;
    }
    _activeToken = token;
    return const AuthAuthorized();
  }

  @override
  Future<Map<String, Object?>> helloAuthState(String? token) async {
    final hasValidToken = token != null &&
        _tokens[token] != null &&
        _tokens[token]!.expiresAt.isAfter(_now());
    return <String, Object?>{
      'authRequired': true,
      'authStatus': hasValidToken ? 'authorized' : 'authorization_required',
      'tokenPresent': hasValidToken,
      'authEndpoints': const <String, String>{
        'request': '/auth/request',
        'status': '/auth/status',
        'claim': '/auth/claim',
      },
    };
  }

  @override
  Future<AuthRouteResult> requestAuthorization(
    Map<String, Object?> body,
  ) async {
    final clientNonce = _stringValue(body['clientNonce']);
    final reusable = _findReusablePending(clientNonce);
    if (reusable != null) {
      _emit(
        method: 'POST',
        route: '/auth/request',
        statusCode: 202,
        authResult: 'pending',
        requestId: reusable.requestId,
        clientLabel: reusable.clientLabel,
      );
      return AuthRouteOk(
        <String, Object?>{
          'requestId': reusable.requestId,
          'status': reusable.status.wireValue,
          'clientLabel': reusable.clientLabel,
        },
        statusCode: 202,
      );
    }

    final requestId = _newId('req');
    final pending = _PendingAuthorization(
      requestId: requestId,
      clientNonce: clientNonce,
      clientLabel: _stringValue(body['clientLabel']) ?? 'unknown client',
      createdAt: _now(),
    );
    _pending[requestId] = pending;
    _emit(
      method: 'POST',
      route: '/auth/request',
      statusCode: 202,
      authResult: 'pending',
      requestId: requestId,
      clientLabel: pending.clientLabel,
    );
    return AuthRouteOk(
      <String, Object?>{
        'requestId': requestId,
        'status': 'pending',
        'clientLabel': pending.clientLabel,
      },
      statusCode: 202,
    );
  }

  @override
  Future<AuthRouteResult> authorizationStatus(
    Map<String, Object?> body,
  ) async {
    final requestId = _stringValue(body['requestId']);
    final pending = requestId == null ? null : _pending[requestId];
    if (pending == null) {
      return const AuthRouteDenied(
        statusCode: 401,
        code: 'invalid_token',
        message: 'Debug authorization token is invalid.',
      );
    }
    if (!_nonceMatches(body, pending)) {
      return const AuthRouteDenied(
        statusCode: 401,
        code: 'invalid_token',
        message: 'Debug authorization token is invalid.',
      );
    }
    if (pending.status == AcceptanceAuthStatus.denied) {
      return const AuthRouteDenied(
        statusCode: 403,
        code: 'authorization_denied',
        message: 'Debug authorization was denied.',
      );
    }
    return AuthRouteOk(<String, Object?>{
      'requestId': pending.requestId,
      'status': pending.status.wireValue,
    });
  }

  @override
  Future<AuthRouteResult> claimAuthorization(
    Map<String, Object?> body,
  ) async {
    final requestId = _stringValue(body['requestId']);
    final pending = requestId == null ? null : _pending[requestId];
    if (pending == null || !_nonceMatches(body, pending)) {
      return const AuthRouteDenied(
        statusCode: 401,
        code: 'invalid_token',
        message: 'Debug authorization token is invalid.',
      );
    }
    if (pending.status == AcceptanceAuthStatus.denied) {
      return const AuthRouteDenied(
        statusCode: 403,
        code: 'authorization_denied',
        message: 'Debug authorization was denied.',
      );
    }
    if (pending.status != AcceptanceAuthStatus.approved) {
      return AuthRouteOk(<String, Object?>{
        'requestId': pending.requestId,
        'status': pending.status.wireValue,
      });
    }

    final token = _newId('tok');
    final tokenId = _newId('token');
    final expiresAt = _now().add(_tokenTtl);
    _tokens[token] = _IssuedToken(
      tokenId: tokenId,
      token: token,
      expiresAt: expiresAt,
      requestId: pending.requestId,
    );
    _activeToken = token;
    _pending.remove(pending.requestId);
    _emit(
      method: 'POST',
      route: '/auth/claim',
      statusCode: 200,
      authResult: 'claimed',
      requestId: pending.requestId,
      clientLabel: pending.clientLabel,
    );
    return AuthRouteOk(<String, Object?>{
      'requestId': pending.requestId,
      'status': 'approved',
      'token': token,
      'tokenId': tokenId,
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    });
  }

  void _emitDenied(AuthRequest request, AuthDenied denied) {
    _emit(
      method: request.method,
      route: '/${request.segments.join('/')}',
      statusCode: denied.statusCode,
      authResult: denied.code,
      message: denied.message,
    );
  }

  void _emit({
    required String method,
    required String route,
    required int statusCode,
    required String authResult,
    String? capability,
    String? requestId,
    String? clientLabel,
    String? message,
  }) {
    _onRequestLog?.call(AcceptanceRequestLogEntry(
      sequence: _logSequence++,
      timestamp: _now(),
      method: method,
      route: route,
      capability: capability,
      authResult: authResult,
      statusCode: statusCode,
      requestId: requestId,
      clientLabel: clientLabel,
      message: message,
    ));
  }

  bool _nonceMatches(
    Map<String, Object?> body,
    _PendingAuthorization pending,
  ) {
    final expected = pending.clientNonce;
    return expected == null || _stringValue(body['clientNonce']) == expected;
  }

  _PendingAuthorization? _findReusablePending(String? clientNonce) {
    if (clientNonce == null) return null;
    for (final pending in _pending.values) {
      if (pending.clientNonce == clientNonce &&
          pending.status != AcceptanceAuthStatus.denied) {
        return pending;
      }
    }
    return null;
  }

  String _newId(String prefix) {
    final nowMicros = _now().microsecondsSinceEpoch.toRadixString(36);
    final randomPart = _random.nextInt(1 << 32).toRadixString(36);
    return '$prefix-$nowMicros-$randomPart';
  }

  String? _stringValue(Object? value) => value is String ? value : null;
}

enum AcceptanceAuthStatus {
  pending('pending'),
  approved('approved'),
  denied('denied');

  const AcceptanceAuthStatus(this.wireValue);

  final String wireValue;
}

class AcceptanceRequestLogEntry {
  const AcceptanceRequestLogEntry({
    required this.sequence,
    required this.timestamp,
    required this.method,
    required this.route,
    required this.authResult,
    required this.statusCode,
    this.capability,
    this.requestId,
    this.clientLabel,
    this.message,
  });

  final int sequence;
  final DateTime timestamp;
  final String method;
  final String route;
  final String authResult;
  final int statusCode;
  final String? capability;
  final String? requestId;
  final String? clientLabel;
  final String? message;

  /// Returns a copy with [sequence] overridden.
  ///
  /// Used by the controller to re-stamp the controller-global sequence on
  /// entries arriving from independent channel-scoped counters (native mode
  /// has two active log channels; R002-FF003 real-device fix).
  AcceptanceRequestLogEntry copyWith({int? sequence}) =>
      AcceptanceRequestLogEntry(
        sequence: sequence ?? this.sequence,
        timestamp: timestamp,
        method: method,
        route: route,
        authResult: authResult,
        statusCode: statusCode,
        capability: capability,
        requestId: requestId,
        clientLabel: clientLabel,
        message: message,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'sequence': sequence,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'method': method,
        'route': route,
        if (capability != null) 'capability': capability,
        'authResult': authResult,
        'statusCode': statusCode,
        if (requestId != null) 'requestId': requestId,
        if (clientLabel != null) 'clientLabel': clientLabel,
        if (message != null) 'message': message,
      };
}

class _PendingAuthorization {
  _PendingAuthorization({
    required this.requestId,
    required this.clientLabel,
    required this.createdAt,
    this.clientNonce,
    this.status = AcceptanceAuthStatus.pending,
  });

  final String requestId;
  final String? clientNonce;
  final String clientLabel;
  final DateTime createdAt;
  AcceptanceAuthStatus status;
}

class _IssuedToken {
  _IssuedToken({
    required this.tokenId,
    required this.token,
    required this.expiresAt,
    required this.requestId,
  });

  final String tokenId;
  final String token;
  DateTime expiresAt;
  final String requestId;
}

abstract class _AcceptanceCapability implements Capability {
  _AcceptanceCapability(this.authManager);

  final AcceptanceDebugAuthManager authManager;

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();

  void recordCapabilityLog({
    required String method,
    required String route,
    required int statusCode,
    required String authResult,
    String? message,
  }) {
    authManager.recordCapability(
      method: method,
      route: route,
      capability: id,
      statusCode: statusCode,
      authResult: authResult,
      message: message,
    );
  }
}

class _EchoCapability extends _AcceptanceCapability {
  _EchoCapability(super.authManager);

  @override
  String get id => 'debug.echo';

  @override
  List<Resource> get resources => const <Resource>[];

  @override
  List<Command> get commands => <Command>[
        Command(
          method: 'POST',
          path: const ['debug', 'echo'],
          description: 'Returns the posted payload for acceptance testing.',
          handler: (ctx) async {
            recordCapabilityLog(
              method: 'POST',
              route: '/debug/echo',
              statusCode: 200,
              authResult: 'allowed',
            );
            return <String, Object?>{
              'ok': true,
              'capability': id,
              'payload': ctx.body,
            };
          },
        ),
      ];

  @override
  Map<String, Object?> state() => const <String, Object?>{};
}

class _DeviceInfoCapability extends _AcceptanceCapability {
  _DeviceInfoCapability(super.authManager, this._endpoint);

  final Uri? Function() _endpoint;

  @override
  String get id => 'debug.deviceInfo';

  @override
  List<Resource> get resources => <Resource>[
        Resource(
          method: 'GET',
          path: const ['debug', 'device-info'],
          description: 'Returns fixed acceptance app device metadata.',
          handler: (_) async {
            recordCapabilityLog(
              method: 'GET',
              route: '/debug/device-info',
              statusCode: 200,
              authResult: 'allowed',
            );
            return <String, Object?>{
              'ok': true,
              'capability': id,
              'fixtureApp': 'flutter-auth-acceptance-app',
              'platform': Platform.operatingSystem,
              'endpoint': _endpoint()?.toString(),
            };
          },
        ),
      ];

  @override
  List<Command> get commands => const <Command>[];

  @override
  Map<String, Object?> state() => <String, Object?>{
        'acceptanceDeviceInfo': <String, Object?>{
          'fixtureApp': 'flutter-auth-acceptance-app',
          'platform': Platform.operatingSystem,
        },
      };
}

class _SecureActionCapability extends _AcceptanceCapability {
  _SecureActionCapability(super.authManager);

  @override
  String get id => 'debug.secureAction';

  @override
  List<Resource> get resources => const <Resource>[];

  @override
  List<Command> get commands => <Command>[
        Command(
          method: 'POST',
          path: const ['debug', 'secure-action'],
          description: 'Sensitive acceptance command that must pass auth.',
          handler: (_) async {
            recordCapabilityLog(
              method: 'POST',
              route: '/debug/secure-action',
              statusCode: 200,
              authResult: 'allowed',
            );
            return <String, Object?>{
              'ok': true,
              'capability': id,
              'allowed': true,
            };
          },
        ),
      ];

  @override
  Map<String, Object?> state() => const <String, Object?>{};
}

class _ErrorCaseCapability extends _AcceptanceCapability {
  _ErrorCaseCapability(super.authManager);

  @override
  String get id => 'debug.errorCase';

  @override
  List<Resource> get resources => const <Resource>[];

  @override
  List<Command> get commands => <Command>[
        Command(
          method: 'POST',
          path: const ['debug', 'error-case'],
          description: 'Returns a stable business error payload.',
          handler: (_) async {
            recordCapabilityLog(
              method: 'POST',
              route: '/debug/error-case',
              statusCode: 200,
              authResult: 'allowed',
              message: 'stable_business_error',
            );
            return <String, Object?>{
              'ok': false,
              'capability': id,
              'errorCode': 'stable_business_error',
              'message': 'Stable acceptance error.',
            };
          },
        ),
      ];

  @override
  Map<String, Object?> state() => const <String, Object?>{};
}
