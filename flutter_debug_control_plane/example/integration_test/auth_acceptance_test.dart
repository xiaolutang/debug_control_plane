import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_control_plane_acceptance_example/main.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// R002-FF004 手动验收入口（区别于 acceptance_integration_test.dart 的锚点扫描）：
// 覆盖 AcceptanceSpec 的完整验收链路——
//   app 启动 → plane 运行 → 真实 HTTP /auth/request（测试进程 HttpClient 打到
//   endpoint）→ pending 弹窗 → approve → tokenPresent → 真实敏感请求 →
//   状态/日志断言 → 截图采集。
//
// 运行方式（iOS 模拟器，必须显式指定 -d）：
//   cd flutter_debug_control_plane/example
//   fvm flutter test integration_test/auth_acceptance_test.dart \
//     -d DAA2A14D-9BF2-4E3B-9EF2-A7E1136C631F
//
// 不带 -d（如普通 CI 的 host 测试）时不会静默通过：非 iOS 目标环境本入口
// 第一个用例显式 fail 并提示 setup_required（iOS simulator 未连接/非 iOS
// 平台均不会误报 pass）。详见 example/README.md。
Future<void> main() async {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final Directory outputRoot = Directory('/tmp/ff004_acceptance');
  final String prefix = '${outputRoot.path}/ff004';

  testWidgets('setup guard: manual acceptance entry requires an iOS '
      'simulator target', (tester) async {
    if (!Platform.isIOS) {
      fail(
        'setup_required: auth_acceptance_test is the manual iOS simulator '
        'acceptance entry. Run it with: fvm flutter test '
        'integration_test/auth_acceptance_test.dart -d <ios-simulator-udid>',
      );
    }
    outputRoot.createSync(recursive: true);
  });

  testWidgets('full chain: launch → real /auth/request → pending dialog → '
      'approve → token → sensitive request → logged', (tester) async {
    final controller = AcceptanceController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(AcceptanceApp(controller: controller));
    await tester.pump();

    Uri? endpoint;
    await tester.runAsync(() async {
      await controller.start();
      endpoint = controller.endpoint;
    });
    await tester.pumpAndSettle();

    // 1. plane 运行 + endpoint 可见（interaction assertion #1）。
    expect(controller.planeRunning, isTrue);
    expect(endpoint, isNotNull);
    expect(
      find.byKey(const ValueKey<String>('acceptance.status.endpoint_text')),
      findsOneWidget,
    );
    await _capture(tester, binding, '${prefix}_01_launch.png');

    // 2. 真实 HTTP /auth/request 驱动 pending 弹窗（assertion #2）。
    final Uri uri = endpoint!;
    final String requestId = await _postAuthRequest(uri);
    await tester.pumpAndSettle();
    expect(controller.authState, AcceptanceAuthState.pending);
    expect(controller.pendingClientLabel, 'manual-acceptance');
    expect(controller.pendingRequestId, requestId);
    expect(
      find.byKey(const ValueKey<String>('acceptance.auth_dialog.root')),
      findsOneWidget,
    );
    await _capture(tester, binding, '${prefix}_02_pending.png');

    // 3. approve → claim（由测试进程模拟 desktop 客户端 claim）→ token。
    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.approve_button')));
    await tester.pumpAndSettle();
    expect(controller.authState, AcceptanceAuthState.approved,
        reason: 'approve closes dialog and sets approved (assertion #3)');
    expect(
      find.byKey(const ValueKey<String>('acceptance.auth_dialog.root')),
      findsNothing,
    );

    final String token = await _claimToken(uri, requestId);
    await tester.pumpAndSettle();
    expect(controller.tokenPresent, isTrue);

    // 4. 带真实 token 的敏感请求 → allowed（assertion #7：log 追加记录）。
    await tester.runAsync(() async {
      final status = await _postSensitive(uri, token);
      expect(status, 200, reason: 'sensitive request allowed with token');
    });
    await tester.pumpAndSettle();
    expect(
      controller.requestLog.any(
        (e) =>
            e.route == '/debug/secure-action' &&
            e.statusCode == 200 &&
            e.authResult == 'allowed',
      ),
      isTrue,
      reason: 'capability request appended with route/statusCode/authResult',
    );
    await _capture(tester, binding, '${prefix}_03_allowed.png');

    // 5. expire → 下一次敏感请求 token_expired（assertion #6）。
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('acceptance.controls.expire_token_button')));
    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.controls.expire_token_button')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final status = await _postSensitive(uri, token);
      expect(status, 401, reason: 'expired token rejected');
    });
    await tester.pumpAndSettle();
    expect(controller.authState, AcceptanceAuthState.expired);
    expect(
      controller.requestLog.any(
        (e) => e.authResult == 'token_expired' && e.statusCode == 401,
      ),
      isTrue,
      reason: 'token_expired log entry present (assertion #6)',
    );
    await _capture(tester, binding, '${prefix}_04_expired.png');

    // 6. clear token（assertion #5）。
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('acceptance.controls.clear_token_button')));
    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.controls.clear_token_button')));
    await tester.pumpAndSettle();
    expect(controller.tokenPresent, isFalse,
        reason: 'clear_token sets tokenPresent=false (assertion #5)');
    await _capture(tester, binding, '${prefix}_05_cleared.png');

    await tester.runAsync(controller.stop);
  });

  testWidgets('deny path: real /auth/request → deny → denied + no claim',
      (tester) async {
    final controller = AcceptanceController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(AcceptanceApp(controller: controller));
    await tester.pump();

    Uri? endpoint;
    await tester.runAsync(() async {
      await controller.start();
      endpoint = controller.endpoint;
    });
    await tester.pumpAndSettle();

    final String requestId = await _postAuthRequest(endpoint!);
    await tester.pumpAndSettle();
    expect(controller.authState, AcceptanceAuthState.pending,
        reason: 'pending dialog before deny (assertion #2)');

    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.deny_button')));
    await tester.pumpAndSettle();
    expect(controller.authState, AcceptanceAuthState.denied,
        reason: 'deny sets denied (assertion #4)');
    expect(
      find.byKey(const ValueKey<String>('acceptance.auth_dialog.root')),
      findsNothing,
    );
    await _capture(tester, binding, '${prefix}_06_denied.png');

    // Denied request cannot claim a token (desktop-side view of denial).
    await tester.runAsync(() async {
      final client = HttpClient();
      try {
        final request = await client
            .postUrl(endpoint!.replace(path: '/auth/claim'));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(<String, Object?>{
          'requestId': requestId,
          'clientNonce': 'ff004-manual',
        }));
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 403,
            reason: 'claim after deny is rejected');
      } finally {
        client.close(force: true);
      }
    });
    expect(controller.tokenPresent, isFalse);

    await tester.runAsync(controller.stop);
  });
}

Future<String> _postAuthRequest(Uri endpoint) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      endpoint.replace(path: '/auth/request'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(<String, Object?>{
      'clientNonce': 'ff004-manual',
      'clientLabel': 'manual-acceptance',
    }));
    final response = await request.close();
    final body = await _decode(response);
    expect(response.statusCode, 202);
    return body['requestId']! as String;
  } finally {
    client.close(force: true);
  }
}

Future<String> _claimToken(Uri endpoint, String requestId) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      endpoint.replace(path: '/auth/claim'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(<String, Object?>{
      'requestId': requestId,
      'clientNonce': 'ff004-manual',
    }));
    final response = await request.close();
    final body = await _decode(response);
    expect(response.statusCode, 200, reason: 'claim succeeds after approve');
    return body['token']! as String;
  } finally {
    client.close(force: true);
  }
}

Future<int> _postSensitive(Uri endpoint, String token) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      endpoint.replace(path: '/debug/secure-action'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.contentType = ContentType.json;
    request.write('{}');
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, Object?>> _decode(HttpClientResponse response) async {
  final body = await utf8.decodeStream(response);
  return jsonDecode(body) as Map<String, Object?>;
}

Future<void> _capture(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  String path,
) async {
  final RenderView view = tester.binding.renderViews.first;
  final OffsetLayer layer = view.debugLayer! as OffsetLayer;
  final ui.Image image =
      layer.toImageSync(Offset.zero & view.paintBounds.size);
  final ByteData? bytes =
      await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
  debugPrint('ff004-acceptance: wrote $path');
}
