import 'package:debug_control_plane_acceptance_example/main.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// R002-BF005 pytest 驱动用例（纯测试文件，不改 app 代码）。
//
// 在 iOS 模拟器上启动 example app 的 Dart plane（loopback endpoint），并在
// 测试存活期内扮演「approve/deny 操作者」：按 clientLabel 前缀分派——
//   - 'deny*'  → denyPending（驱动 denied 场景）
//   - 'hold*'  → 保持 pending（驱动 claim-before-approval 场景）
//   - 其他     → approvePending（主链路 / 多 capability）
// endpoint 通过 debugPrint 输出到宿主机 stdout（`pytest-driver: endpoint=`），
// 供 ci/acceptance-flutter-app.sh / 操作者取用。存活时长由
// --dart-define=DRIVER_SECONDS=<n> 控制（默认 90s）。
//
// 运行：cd flutter_debug_control_plane/example && fvm flutter test \
//   integration_test/acceptance_pytest_driver_test.dart -d DAA2A14D-...

const int _driverSeconds = int.fromEnvironment('DRIVER_SECONDS', defaultValue: 90);

Future<void> main() async {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('hosts dart plane and drives auth approvals', (tester) async {
    final AcceptanceController controller = AcceptanceController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(AcceptanceApp(controller: controller));
    await tester.pumpAndSettle();

    if (!controller.planeRunning) {
      await tester.runAsync(controller.start);
      await tester.pumpAndSettle();
    }
    final Uri? endpoint = controller.endpoint;
    debugPrint('pytest-driver: endpoint=$endpoint');
    debugPrint('pytest-driver: seconds=$_driverSeconds');
    if (endpoint == null) {
      fail('pytest-driver: plane failed to start');
    }

    final DateTime deadline =
        DateTime.now().add(const Duration(seconds: _driverSeconds));
    await tester.runAsync(() async {
      while (DateTime.now().isBefore(deadline)) {
        final String? requestId = controller.pendingRequestId;
        final String? label = controller.activeClientLabel;
        if (requestId != null && label != null) {
          if (label.startsWith('deny')) {
            debugPrint('pytest-driver: deny $requestId (label=$label)');
            await controller.denyPending();
          } else if (!label.startsWith('hold')) {
            debugPrint('pytest-driver: approve $requestId (label=$label)');
            await controller.approvePending();
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    });
    debugPrint('pytest-driver: done');
    await controller.stop();
  });
}
