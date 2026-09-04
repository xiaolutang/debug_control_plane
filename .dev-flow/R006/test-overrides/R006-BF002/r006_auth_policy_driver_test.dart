import 'package:debug_control_plane_acceptance_example/src/acceptance_plane.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart'
    show AuthPolicy, BridgeCapability, NativeControlPlaneBridge;
import 'package:integration_test/integration_test.dart';

// R006-BF002 授权策略驱动用例（纯测试文件，fork 自
// r005_persistence_driver_test.dart / acceptance_pytest_driver_test.dart，
// 不改 example/lib/ app 代码——策略注入点由本 driver 自持）。
//
// 与 R005 驱动的差异：
//   - 不经 AcceptanceController/AndroidNativePlane（其 start() 签名无
//     authPolicy，且 example/lib 被 block）——本 driver 直接用
//     NativeControlPlaneBridge.start(authPolicy: ...) 装配（R006-FF001
//     API 面），capability 仍取 AcceptancePlane.buildCapabilities() 的
//     固定 4 能力集（/hello、/debug/secure-action 等路由由此而来）。
//   - 策略经编译常量注入：--dart-define=R006_AUTH_POLICY=<v>
//       "" / "default" → start() 不传 authPolicy（default 分支，字节兼容）
//       "auto"  → AuthPolicy.auto（autoApprove 装配，落库即 approve）
//       "none"  → AuthPolicy.none（mount 无 authManager）
//       "bogus" → 裸 MethodChannel 传 authPolicy:"bogus"（enum 不可构造
//                 非法值），捕获 PlatformException(invalid_arguments) 后
//                 打印 `r006-e5: plane-not-started` 标记行（E5 双断言的
//                 driver 侧信号，plan-review L2）。
//   - 存活时长 --dart-define=DRIVER_SECONDS=<n>（默认 150s，python 侧
//     编排 E1-E6 需多轮）。
//
// stdout 约定（沿用 pytest-driver: 前缀）：
//   pytest-driver: endpoint=<uri>          plane 已启动（bogus 轮不出现）
//   pytest-driver: policy=<wire>           本轮装配策略
//   r006-e5: plane-not-started code=<code> E5 非法策略 fail-fast 标记
//
// 运行（脚本调用；driver 文件在 example 包外，flutter test 以 example 为
// cwd 指定绝对路径文件）：
//   cd flutter_debug_control_plane/example && fvm flutter test \
//     <abs>/r006_auth_policy_driver_test.dart -d <serial> \
//     --dart-define=R006_AUTH_POLICY=auto --dart-define=DRIVER_SECONDS=150

const String _policy = String.fromEnvironment('R006_AUTH_POLICY');
const int _driverSeconds =
    int.fromEnvironment('DRIVER_SECONDS', defaultValue: 150);

Future<void> main() async {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('r006 auth policy driver ($_policy)', (tester) async {
    // --- E5: bogus —— 裸通道传非法 wire 值，断言 invalid_arguments -----
    if (_policy == 'bogus') {
      String? errorCode;
      await tester.runAsync(() async {
        try {
          await const MethodChannel('debug_control_plane/method')
              .invokeMethod<dynamic>('plane.start', <String, Object?>{
            'address': '0.0.0.0',
            'port': 0,
            'authPolicy': 'bogus',
          });
        } on PlatformException catch (e) {
          errorCode = e.code;
        }
      });
      if (errorCode != null) {
        debugPrint('r006-e5: plane-not-started code=$errorCode');
        expect(errorCode!.contains('invalid_arguments'), isTrue,
            reason: 'expected invalid_arguments, got $errorCode');
      } else {
        debugPrint('r006-e5: plane-not-started code=NO_EXCEPTION');
        fail('bogus authPolicy 应 fail-fast 抛 PlatformException, '
            '实际: 未抛异常');
      }
      // 保持存活若干秒让 python 侧完成「endpoint 不可达 + 标记行」双断言
      await tester.runAsync(
          () => Future<void>.delayed(Duration(seconds: _driverSeconds)));
      return;
    }

    // --- default/auto/none —— 经 FF001 API 面装配 -----------------------
    final AuthPolicy? policy = switch (_policy) {
      'auto' => AuthPolicy.auto,
      'none' => AuthPolicy.none,
      'default' => AuthPolicy.defaultPolicy,
      _ => null, // 缺席 = 现状（E6 回归轮）
    };

    final AcceptancePlane plane = AcceptancePlane();
    final NativeControlPlaneBridge bridge = NativeControlPlaneBridge();
    bridge.attach();
    // 宿主侧审计通知仅打印（auto 下 native 即时 approve，此回调仍发出——D4）
    bridge.setAuthorizationHandler((request) async {
      debugPrint('pytest-driver: pending ${request.requestId} '
          'label=${request.clientLabel}');
    });

    final Uri? endpoint = await tester.runAsync<Uri?>(() async {
      final uri = await bridge.start(
        address: '0.0.0.0',
        port: 0,
        authPolicy: policy,
      );
      for (final capability in plane.buildCapabilities()) {
        await bridge.register(BridgeCapability(capability));
      }
      return uri;
    });
    debugPrint('pytest-driver: policy=${policy?.wireName ?? 'omitted'}');
    debugPrint('pytest-driver: endpoint=$endpoint');
    if (endpoint == null) {
      fail('pytest-driver: plane failed to start (policy=$_policy)');
    }

    final DateTime deadline =
        DateTime.now().add(const Duration(seconds: _driverSeconds));
    await tester.runAsync(() async {
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    });
    debugPrint('pytest-driver: done');
    await bridge.dispose();
  });
}
