import 'dart:io';
import 'dart:ui' as ui;

import 'package:debug_control_plane_acceptance_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// R002-FF002 模拟器集成测试（验收夹具，随 example 一起提交）：
// 在真实 iOS simulator / Android 设备上验证 AcceptanceApp 骨架的三区域渲染、
// 12 个 stable identifiers 可定位、占位控件可点击，并把每个滚动视口的
// 真实引擎渲染截图写到宿主机 /tmp/ff002_integration/ 供视觉验收归档。
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

  testWidgets('top viewport renders status section', (WidgetTester tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    await tester.pumpAndSettle();

    expect(find.text('Status'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('acceptance.status.endpoint_text')),
      findsOneWidget,
    );
    await _capture(tester, binding, '${prefix}_01_top.png');
  });

  testWidgets('all stable identifiers present on device', (tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    await tester.pumpAndSettle();

    for (final identifier in acceptanceStableIdentifiers) {
      expect(
        find.byKey(ValueKey<String>(identifier)),
        findsOneWidget,
        reason: 'Missing stable identifier: $identifier',
      );
    }
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

  testWidgets('scroll reveals controls and auth dialog anchors', (tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('acceptance.controls.clear_token_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('acceptance.auth_dialog.deny_button')),
      findsOneWidget,
    );
    await _capture(tester, binding, '${prefix}_03_controls.png');
  });

  testWidgets('placeholder controls tappable without exceptions', (tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    await tester.pumpAndSettle();

    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.controls.clear_token_button')));
    await tester.pump();
    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.controls.expire_token_button')));
    await tester.pump();
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.approve_button')));
    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.approve_button')));
    await tester.pump();
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.deny_button')));
    await tester.tap(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.deny_button')));
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
