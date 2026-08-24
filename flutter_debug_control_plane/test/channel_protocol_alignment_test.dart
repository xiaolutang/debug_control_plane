import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart';
import 'package:flutter_test/flutter_test.dart';

import 'src/file_helper_io.dart';

/// FF001-1 acceptance: the Dart-side method-name literals must stay aligned
/// with the Kotlin side. The Kotlin constants live in
/// `android/src/main/kotlin/com/pantas/debug/controlplane/flutter/ChannelProtocol.kt`
/// — this test reads that file at runtime (repo-relative path resolution) and
/// asserts every constant literal is present, so drift fails CI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ktFile = 'android/src/main/kotlin/com/pantas/debug/controlplane'
      '/flutter/ChannelProtocol.kt';

  late String ktSource;

  setUpAll(() {
    // The plugin test runner's CWD is the package root.
    ktSource = FileHelper.readSync(ktFile);
  });

  void expectKtContains(String dartLiteral, String ktName) {
    expect(
      ktSource,
      contains('const val $ktName = "$dartLiteral"'),
      reason: 'Kotlin ChannelProtocol.$ktName drifted from Dart literal '
          '"$dartLiteral"',
    );
  }

  test('channel names aligned', () {
    expectKtContains(kMethodChannel, 'METHOD_CHANNEL');
    expectKtContains(kEventChannel, 'EVENT_CHANNEL');
  });

  test('forward methods (Dart -> native) aligned', () {
    expectKtContains(kMethodPlaneStart, 'PLANE_START');
    expectKtContains(kMethodPlaneStop, 'PLANE_STOP');
    expectKtContains(kMethodCapabilityRegister, 'CAPABILITY_REGISTER');
    expectKtContains(kMethodCapabilityUnregister, 'CAPABILITY_UNREGISTER');
    expectKtContains(kMethodEventsEmit, 'EVENTS_EMIT');
    expectKtContains(kMethodCapabilityStateUpdate, 'CAPABILITY_STATE_UPDATE');
    expectKtContains(kMethodCapabilityInvokeResult, 'CAPABILITY_INVOKE_RESULT');
    expectKtContains(kMethodAuthApprove, 'AUTH_APPROVE');
    expectKtContains(kMethodAuthDeny, 'AUTH_DENY');
    expectKtContains(kMethodAuthRevoke, 'AUTH_REVOKE');
    expectKtContains(kMethodAuthStatus, 'AUTH_STATUS');
  });

  test('reverse invokes (native -> Dart) aligned', () {
    expectKtContains(kMethodCapabilityInvoke, 'CAPABILITY_INVOKE');
    expectKtContains(kMethodAuthRequest, 'AUTH_REQUEST');
    expectKtContains(kMethodCapabilityStatePull, 'CAPABILITY_STATE_PULL');
    expectKtContains(kMethodCapabilityStateResult, 'CAPABILITY_STATE_RESULT');
  });

  test('routeKind literals aligned', () {
    expectKtContains(kRouteKindResource, 'ROUTE_KIND_RESOURCE');
    expectKtContains(kRouteKindCommand, 'ROUTE_KIND_COMMAND');
  });

  test('PlatformException codes aligned', () {
    expectKtContains(kErrorCodeDuplicate, 'ERROR_DUPLICATE');
    expectKtContains(kErrorCodeNotRegistered, 'ERROR_NOT_REGISTERED');
    expectKtContains(kErrorCodeBindFailed, 'ERROR_BIND_FAILED');
  });
}

/// Thin dart:io wrapper (kept in one place so a future fvm/IO pin is easy).
class FileHelper {
  static String readSync(String path) {
    return FileHelperIo.read(path);
  }
}
