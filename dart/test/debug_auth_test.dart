import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';

void main() {
  group('DebugAuth route classification', () {
    test('marks GET /hello as hello bootstrap only', () {
      expect(
        DebugAuth.classifyRoute('GET', const ['hello']),
        AuthRouteClass.helloBootstrap,
      );
      expect(
        DebugAuth.classifyRoute('POST', const ['hello']),
        AuthRouteClass.sensitive,
      );
    });

    test('marks POST /auth bootstrap endpoints', () {
      for (final action in const ['request', 'status', 'claim']) {
        expect(
          DebugAuth.classifyRoute('POST', ['auth', action]),
          AuthRouteClass.authBootstrap,
        );
      }
      expect(
        DebugAuth.classifyRoute('GET', const ['auth', 'request']),
        AuthRouteClass.sensitive,
      );
    });

    test('defaults state events and capabilities to sensitive', () {
      expect(
        DebugAuth.classifyRoute('GET', const ['state']),
        AuthRouteClass.sensitive,
      );
      expect(
        DebugAuth.classifyRoute('GET', const ['events']),
        AuthRouteClass.sensitive,
      );
      expect(
        DebugAuth.classifyRoute('GET', const ['items', '1']),
        AuthRouteClass.sensitive,
      );
      expect(
        DebugAuth.classifyRoute('POST', const ['invoke']),
        AuthRouteClass.sensitive,
      );
    });
  });

  group('DebugAuth Bearer parsing', () {
    test('parses exact Bearer token', () {
      expect(
        DebugAuth.bearerToken(
          const <String, String>{'Authorization': 'Bearer test-token-not-real'},
        ),
        'test-token-not-real',
      );
    });

    test('parses Authorization header name case-insensitively', () {
      expect(
        DebugAuth.bearerToken(
          const <String, String>{'authorization': 'Bearer test-token-not-real'},
        ),
        'test-token-not-real',
      );
    });

    test('rejects missing malformed blank and whitespace tokens', () {
      expect(DebugAuth.bearerToken(const <String, String>{}), isNull);
      expect(DebugAuth.bearerTokenValue('Basic abc'), isNull);
      expect(DebugAuth.bearerTokenValue('Bearer '), isNull);
      expect(DebugAuth.bearerTokenValue('Bearer   '), isNull);
      expect(DebugAuth.bearerTokenValue('Bearer token extra'), isNull);
      expect(DebugAuth.bearerTokenValue('bearer token'), isNull);
      expect(DebugAuth.bearerTokenValue('token'), isNull);
    });
  });
}
