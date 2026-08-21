enum AuthRouteClass {
  helloBootstrap,
  authBootstrap,
  sensitive,
}

class AuthRequest {
  const AuthRequest({
    required this.method,
    required this.segments,
    required this.routeClass,
    this.bearerToken,
    this.body = const <String, Object?>{},
    this.request,
  });

  final String method;
  final List<String> segments;
  final AuthRouteClass routeClass;
  final String? bearerToken;
  final Map<String, Object?> body;
  final Object? request;
}

sealed class AuthDecision {
  const AuthDecision();
}

class AuthAuthorized extends AuthDecision {
  const AuthAuthorized();
}

class AuthDenied extends AuthDecision {
  const AuthDenied({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;
}

sealed class AuthRouteResult {
  const AuthRouteResult();
}

class AuthRouteOk extends AuthRouteResult {
  const AuthRouteOk(this.body, {this.statusCode = 200});

  final Map<String, Object?> body;
  final int statusCode;
}

class AuthRouteDenied extends AuthRouteResult {
  const AuthRouteDenied({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;
}

abstract interface class DebugAuthManager {
  Future<AuthDecision> authorize(AuthRequest request);

  Future<Map<String, Object?>> helloAuthState(String? token);

  Future<AuthRouteResult> requestAuthorization(Map<String, Object?> body);

  Future<AuthRouteResult> authorizationStatus(Map<String, Object?> body);

  Future<AuthRouteResult> claimAuthorization(Map<String, Object?> body);
}

class NoOpDebugAuthManager implements DebugAuthManager {
  const NoOpDebugAuthManager();

  @override
  Future<AuthDecision> authorize(AuthRequest request) async =>
      const AuthAuthorized();

  @override
  Future<Map<String, Object?>> helloAuthState(String? token) async =>
      const <String, Object?>{
        'authRequired': false,
        'authStatus': 'disabled',
      };

  @override
  Future<AuthRouteResult> requestAuthorization(
    Map<String, Object?> body,
  ) async =>
      AuthRouteDenied(
        statusCode: 401,
        code: 'authorization_required',
        message: 'Debug authorization is required.',
      );

  @override
  Future<AuthRouteResult> authorizationStatus(
    Map<String, Object?> body,
  ) async =>
      AuthRouteDenied(
        statusCode: 401,
        code: 'invalid_token',
        message: 'Debug authorization token is invalid.',
      );

  @override
  Future<AuthRouteResult> claimAuthorization(
    Map<String, Object?> body,
  ) async =>
      AuthRouteDenied(
        statusCode: 401,
        code: 'invalid_token',
        message: 'Debug authorization token is invalid.',
      );
}

final class DebugAuth {
  const DebugAuth._();

  static AuthRouteClass classifyRoute(String method, List<String> segments) {
    final normalizedMethod = method.toUpperCase();
    if (normalizedMethod == 'GET' &&
        segments.length == 1 &&
        segments.first == 'hello') {
      return AuthRouteClass.helloBootstrap;
    }
    if (normalizedMethod == 'POST' &&
        segments.length == 2 &&
        segments.first == 'auth' &&
        _authBootstrapActions.contains(segments[1])) {
      return AuthRouteClass.authBootstrap;
    }
    return AuthRouteClass.sensitive;
  }

  static String? bearerToken(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'authorization') {
        return bearerTokenValue(entry.value);
      }
    }
    return null;
  }

  static String? bearerTokenValue(String? headerValue) {
    if (headerValue == null || !headerValue.startsWith('Bearer ')) {
      return null;
    }
    final token = headerValue.substring('Bearer '.length);
    if (token.trim().isEmpty) return null;
    if (token.contains(RegExp(r'\s'))) return null;
    return token;
  }

  static AuthDenied authorizationRequired() => const AuthDenied(
        statusCode: 401,
        code: 'authorization_required',
        message: 'Debug authorization is required.',
      );

  static AuthDenied invalidToken() => const AuthDenied(
        statusCode: 401,
        code: 'invalid_token',
        message: 'Debug authorization token is invalid.',
      );

  static AuthDenied tokenExpired() => const AuthDenied(
        statusCode: 401,
        code: 'token_expired',
        message: 'Debug authorization token expired.',
      );

  static AuthDenied tokenRevoked() => const AuthDenied(
        statusCode: 401,
        code: 'token_revoked',
        message: 'Debug authorization token was revoked.',
      );

  static const Set<String> _authBootstrapActions = <String>{
    'request',
    'status',
    'claim',
  };
}
