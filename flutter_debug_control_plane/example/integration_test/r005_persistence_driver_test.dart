import 'package:debug_control_plane_acceptance_example/main.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// R005-BF002 token 持久化驱动用例（纯测试文件，fork 自
// acceptance_pytest_driver_test.dart，不改 example/lib/ app 代码）。
//
// 与 R002 驱动的唯一差异：start() 前先 `await controller
// .ensurePersistentStore()`（R005-FF001 装配层语义，与 main.dart 一致），
// 使 FileBacked store 在任何 claim 之前挂载 —— I2 冷重启 / I3 损坏自愈 /
// I4 TTL 断言依赖该挂载。
//
// 其余机制不变：endpoint 经 debugPrint 输出（`pytest-driver: endpoint=`），
// 按 clientLabel 前缀分派 deny*→deny / hold*→保持 pending / 其他→approve；
// 存活时长 --dart-define=DRIVER_SECONDS=<n>（默认 90s）。
//
// 运行：cd flutter_debug_control_plane/example && fvm flutter test \
//   integration_test/r005_persistence_driver_test.dart -d <udid> \
//   --dart-define=DRIVER_SECONDS=150

const int _driverSeconds = int.fromEnvironment('DRIVER_SECONDS', defaultValue: 90);

Future<void> main() async {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('hosts dart plane with persistent token store', (tester) async {
    final AcceptanceController controller = AcceptanceController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(AcceptanceApp(controller: controller));
    await tester.pumpAndSettle();

    // R005-FF001: attach the file-backed store BEFORE the plane starts.
    await tester.runAsync(controller.ensurePersistentStore);

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
