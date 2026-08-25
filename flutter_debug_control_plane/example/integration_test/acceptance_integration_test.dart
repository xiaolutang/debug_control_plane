import 'dart:io';
import 'dart:ui' as ui;

import 'package:debug_control_plane_acceptance_example/main.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// R002 集成测试（验收夹具，随 example 提交）：
// 在真实 iOS simulator / Android 设备上验证 AcceptanceApp 的三区域渲染、
// 12 个 stable identifiers 可定位（auth_dialog.* 五个标识在 pending 弹窗出现，
// 由真实 /auth/request 事件触发）、占位控件可点击，并把滚动视口真实引擎渲染
// 截图写到宿主机 /tmp/ff002_integration/（iOS）或 app code_cache（Android）。
Future<void> main() async {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final String platform = Platform.isIOS ? 'ios' : 'android';
  final String model = Platform.environment.containsKey('SIMULATOR_MODEL_NAME')
      ? 'simulator'
      : 'device';
  // iOS simulator lets tests write /tmp; Android sandboxes the app — fall
  // back to the app documents dir and pull files via adb afterwards.
  final Directory outputRoot = Platform.isIOS
      ? Directory('/tmp/ff002_integration')
      : Directory.systemTemp;
  final String prefix = '${outputRoot.path}/ff002_integration/${platform}_$model';
  Directory('${outputRoot.path}/ff002_integration').createSync(recursive: true);

  testWidgets('top viewport renders status section', (tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    await tester.pumpAndSettle();

    expect(find.text('Status'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('acceptance.status.endpoint_text')),
      findsOneWidget,
    );
    await _capture(tester, binding, '${prefix}_01_top.png');
  });

  // 12 标识 = 页面 7 个常驻 + 弹窗 5 个 pending 时可见：分两段断言。
  testWidgets('page stable identifiers present on device', (tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    await tester.pumpAndSettle();

    for (final identifier in acceptanceStableIdentifiers
        .where((id) => !id.startsWith('acceptance.auth_dialog.'))) {
      expect(
        find.byKey(ValueKey<String>(identifier)),
        findsOneWidget,
        reason: 'Missing stable identifier: $identifier',
      );
    }
  });

  // pending 弹窗五标识：经真实 plane 的 /auth/request 触发后可见。
  testWidgets('auth dialog anchors appear on pending request', (tester) async {
    final AcceptanceController controller = AcceptanceController();
    await tester.pumpWidget(AcceptanceApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await controller.start();
      await controller.plane.authManager.requestAuthorization(
        <String, Object?>{'clientLabel': 'integration-test'},
      );
    });
    await tester.pumpAndSettle();

    for (final identifier in acceptanceStableIdentifiers
        .where((id) => id.startsWith('acceptance.auth_dialog.'))) {
      expect(
        find.byKey(ValueKey<String>(identifier)),
        findsOneWidget,
        reason: 'Missing dialog identifier: $identifier',
      );
    }
    // auth_state_text 与弹窗内容各显示一次 pending（两处合法），用 descendant 收紧到状态区。
    expect(
      find.descendant(
        of: find.byKey(
            const ValueKey<String>('acceptance.status.auth_state_text')),
        matching: find.text('pending'),
      ),
      findsOneWidget,
    );
    await _capture(tester, binding, '${prefix}_04_dialog.png');

    // approve 关闭弹窗：五标识随 dialog 生命周期消失。
    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.approve_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('acceptance.auth_dialog.root')),
      findsNothing,
    );
    controller.dispose();
  });

  testWidgets('scroll reveals requests section', (tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('acceptance.requests.list')),
      findsOneWidget,
    );
    await _capture(tester, binding, '${prefix}_02_requests.png');
  });

  testWidgets('scroll reveals controls section', (tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('acceptance.controls.clear_token_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('acceptance.controls.expire_token_button')),
      findsOneWidget,
    );
    await _capture(tester, binding, '${prefix}_03_controls.png');
  });

  testWidgets('controls tappable without exceptions', (tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    await tester.pumpAndSettle();

    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('acceptance.controls.clear_token_button')));
    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.controls.clear_token_button')));
    await tester.pump();
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('acceptance.controls.expire_token_button')));
    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.controls.expire_token_button')));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
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
  debugPrint('ff002-integration: wrote $path');
}
