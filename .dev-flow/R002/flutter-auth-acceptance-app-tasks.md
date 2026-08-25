---
version: "1.0"
type: tasks
topic: flutter-auth-acceptance-app
requirement_cycle: R002
taskPackageVersion: "1.8"
workflow:
  evaluate_provider: direct_subagent
  mode: auto
status: planned
analysisManifestPath: .dev-flow/R002/analysis/manifest.json
analysisManifestRevision: 3
analysisManifestDigest: 030e1b3d7d7215c51ba98a4754d07817f328a84db3075492e12b364f811dc15b
analysisIntegrationPath: .dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-integration.md
bootstrapLegacy: false
analysisSourceMdPaths:
  - .dev-flow/R002/analysis/manifest.json
  - .dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app.md
  - .dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-integration.md
designMdPaths:
  - .dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-design.md
testMdPaths:
  - .dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md
contextMdPaths:
  - .dev-flow/architecture.md
  - .dev-flow/R002/analysis/manifest.json
  - .dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app.md
  - .dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-integration.md
  - .dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-design.md
  - .dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md
---

# R002 Flutter 鉴权验收 App 任务清单

全局约束：

- 验收 App 是 Flutter App，放在 `flutter_debug_control_plane/example/`。
- iOS 模拟器阶段使用 Dart `debug_control_plane` 验证 App 宿主授权闭环。
- Android 真机阶段使用 `flutter_debug_control_plane` plugin 验证 native bridge/Kotlin core。
- R002 不实现 iOS native plugin bridge，不改变 R001 auth wire contract。
- 真实设备验收独立为 acceptance gate，不默认加入 `ci/ci-check-all.sh`。

## 执行顺序

1. R002-BF006
2. R002-FF002 → R002-FB001
3. R002-BF005
4. R002-FF003
5. R002-FF004
6. R002-BF008

## R002-FF002：example app — Flutter 验收 App 骨架 `✅ 已完成`

- 文件：`flutter_debug_control_plane/example/lib/main.dart` + `flutter_debug_control_plane/example/pubspec.yaml`
- 改动类型：新建
- domain: ui
- task_layer: foundation
- depends_on: [R002-BF006]
- priority: 5
- risk_tags: [flutter, example, ios_simulator]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [FF002, BF006]
- sourceSlices: [S01-acceptance-app]
- sourceDesigns: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-design.md]
- sourceTests: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md]
- acceptance_criteria:
  - example app 可在 Flutter test 环境构建，包含 Status、Requests、Controls 三个区域。
  - 实现 12 个稳定标识（清单见 AcceptanceSpec）。
  - visual-verify PASS（三层证据对照 AcceptanceSpec）。
  - visual baseline deferred: device_profile=iPhone simulator 390x844@3 和 Android 真实设备后续实测；thresholds 见 AcceptanceSpec，deferred_reason=device_required。
- test_tasks:
  - type: unit
    layer: unit
    domain: flutter
    description: Flutter widget/unit test 验证页面结构与稳定标识存在
    scenarios: [design-test-2 Flutter unit, AcceptanceSpec stable_identifiers]
- contract_refs: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-acceptance-spec.yaml]
- decision_refs: [DEC-R002-001, DEC-R002-005]
- blocked_files: []
- 具体改动点：
  - R002-FF002.1 `✅` 新建 example `pubspec.yaml`，path 依赖 `../` plugin 与 `../../dart` debug_control_plane。
  - R002-FF002.2 `✅` 新建 `main.dart` 与 `AcceptanceApp`，提供 Status、Requests、Controls UI。
  - R002-FF002.3 `✅` 使用中立稳定标识清单落地 12 个 UI 锚点。
- 关键代码片段：
  ```dart
  void main() => runApp(const AcceptanceApp());

  class AcceptanceApp extends StatelessWidget {
    const AcceptanceApp({super.key});
  }
  ```
- 改动理由/上下文：先建立 Flutter App 宿主载体，后续任务在该载体上接入 Dart plane、auth UI 与真实 endpoint 验收。

## R002-FB001：example auth UI — 授权弹窗与状态控制 `✅ 已完成`

- 文件：`flutter_debug_control_plane/example/lib/src/acceptance_controller.dart` + `flutter_debug_control_plane/example/lib/src/auth_dialog.dart`
- 改动类型：新建
- domain: ui
- task_layer: business
- depends_on: [R002-FF002]
- priority: 5
- risk_tags: [auth, ui, state]
- smoke_required: true
- mode: negotiated
- status: done
- sourceCapabilities: [FB001, BF006]
- sourceSlices: [S01-acceptance-app]
- sourceDesigns: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-design.md]
- sourceTests: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md]
- acceptance_criteria:
  - 未授权请求产生 pending 状态后展示授权弹窗，可同意和拒绝。
  - Controls 可清 token、模拟 token 过期，并同步更新请求日志。
  - 实现 12 个稳定标识（清单见 AcceptanceSpec）。
  - visual-verify PASS（三层证据对照 AcceptanceSpec）。
  - visual baseline deferred: iOS simulator 和 Android 真机截图在执行阶段采集，deferred_reason=device_required。
- test_tasks:
  - type: unit
    layer: unit
    domain: flutter
    description: controller 状态机覆盖 pending/approved/denied/cleared/expired
    scenarios: [design-test-2 Flutter unit, design-test-2 Flutter integration]
- contract_refs: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-acceptance-spec.yaml]
- decision_refs: [DEC-R002-004]
- blocked_files: []
- 具体改动点：
  - R002-FB001.1 `✅` 定义 `AcceptanceAuthState`、`AcceptancePlaneStatus`（复用 BF006 `AcceptanceRequestLogEntry`）。
  - R002-FB001.2 `✅` 实现 approve/deny/clear/expire 操作与日志追加。
  - R002-FB001.3 `✅` 授权弹窗绑定 `clientLabel/requestId` 和 approve/deny callbacks。
- 关键代码片段：
  ```dart
  enum AcceptanceAuthStatus { idle, pending, approved, denied, expired, cleared }

  class AcceptanceController extends ChangeNotifier {
    Future<void> approvePending();
    Future<void> denyPending();
    void clearToken();
    void expireToken();
  }
  ```
- 改动理由/上下文：R002 的核心人工验收价值在 App 侧可见授权状态和可复现控制。

## R002-BF006：acceptance harness — Dart plane 与固定 capability `✅ 已完成`

- 文件：`flutter_debug_control_plane/example/lib/src/acceptance_plane.dart` + `flutter_debug_control_plane/example/pubspec.yaml` + `flutter_debug_control_plane/example/test/acceptance_plane_test.dart`
- 改动类型：新建
- domain: backend
- task_layer: foundation
- depends_on: []
- priority: 5
- risk_tags: [dart, auth, capability]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [FF002, BF006]
- sourceSlices: [S01-acceptance-app]
- sourceDesigns: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-design.md]
- sourceTests: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md]
- acceptance_criteria:
  - iOS 模拟器模式可启动 Dart `ControlPlane` + `HttpSseTransport` 并返回 endpoint。
  - 注册 `debug.echo`、`debug.deviceInfo`、`debug.secureAction`、`debug.errorCase` 四个固定 capability。
  - auth manager 支持 `/auth/request/status/claim`、Bearer 校验、denied、expired、invalid_token。
- test_tasks:
  - type: unit
    layer: unit
    domain: flutter
    description: fixed capability 和 auth manager 单测覆盖 claim/Bearer/expired
    scenarios: [design-test-2 fixed capability, design-test-2 Python acceptance auth bootstrap]
- contract_refs: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- decision_refs: [DEC-R002-003, DEC-R002-004, DEC-R002-005]
- blocked_files: []
- 具体改动点：
  - R002-BF006.1 `✅` 实现 `AcceptancePlane`，封装 Dart `ControlPlane.start/stop/register`。
  - R002-BF006.2 `✅` 实现测试 auth manager，token 只保存在 App 内存或私有状态。
  - R002-BF006.3 `✅` 暴露 request log sink 接口；UI 任务负责把日志绑定到页面。
- 关键代码片段：
  ```dart
  class AcceptancePlane {
    Future<Uri> startDartPlane();
    Future<void> stop();
    List<Capability> buildCapabilities();
  }
  ```
- 改动理由/上下文：iOS 模拟器不依赖 Android native plugin，先用 Dart plane 提供可被 UI 和 Python runner 消费的基础验收 harness。

## R002-BF005：Python acceptance — auth claim runner 与脚本入口 `⬜ 待处理`

- 文件：`ci/acceptance-flutter-app.sh` + `python/tests/test_acceptance_flutter_app_auth.py`
- 改动类型：新建
- domain: integration
- task_layer: foundation
- depends_on: [R002-BF006]
- priority: 5
- risk_tags: [python, acceptance, device]
- smoke_required: true
- mode: negotiated
- status: pending
- sourceCapabilities: [BF005, BF006]
- sourceSlices: [S01-acceptance-app]
- sourceDesigns: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-design.md]
- sourceTests: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md]
- acceptance_criteria:
  - endpoint 缺失时输出 setup_required 或 pytest skip，不误报 pass。
  - runner 完整执行 `/auth/request -> /auth/status -> /auth/claim -> Bearer retry`。
  - 覆盖 denied、approval_timeout、token_expired、伪造 token、多 capability。
- test_tasks:
  - type: integration
    layer: integration
    domain: backend
    description: Python endpoint acceptance 可在提供真实 endpoint 时运行
    scenarios: [design-test-2 Python acceptance, design-test-4 集成测试方案]
    deferred: true
    deferred_reason: device_required
- contract_refs: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- decision_refs: [DEC-R002-002, DEC-R002-003]
- blocked_files: [ci/ci-check-all.sh]
- 具体改动点：
  - R002-BF005.1 `⬜` shell 脚本解析 `--target`、`--endpoint` 并传给 pytest。
  - R002-BF005.2 `⬜` pytest 中实现 claim token、内存保存 token、Bearer retry。
  - R002-BF005.3 `⬜` 对无 endpoint、连接失败、超时、denied 输出稳定结果。
- 关键代码片段：
  ```python
  def test_acceptance_auth_claim_and_bearer_retry(endpoint: str) -> None:
      request_id = request_authorization(endpoint)
      wait_until_approved(endpoint, request_id)
      token = claim_token(endpoint, request_id)
      assert_secure_action_allowed(endpoint, token)
  ```
- 改动理由/上下文：电脑端验收必须验证真实授权领取链路，不能只预置 token 后测成功。

## R002-FF003：Android device mode — plugin/native bridge 接入 `⬜ 待处理`

- 文件：`flutter_debug_control_plane/example/lib/src/android_native_plane.dart`
- 改动类型：新建
- domain: ui
- task_layer: foundation
- depends_on: [R002-BF006]
- priority: 4
- risk_tags: [android, native_bridge, device]
- smoke_required: true
- mode: negotiated
- status: pending
- sourceCapabilities: [FF002, BF006]
- sourceSlices: [S01-acceptance-app]
- sourceDesigns: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-design.md]
- sourceTests: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md]
- acceptance_criteria:
  - Android 真机模式通过 `NativeControlPlaneBridge` 启动 native debug plane。
  - 同一组固定 capability 可通过 plugin/native bridge 注册并被 Python endpoint acceptance 调用。
  - 实现 12 个稳定标识（清单见 AcceptanceSpec）。
  - visual-verify PASS（三层证据对照 AcceptanceSpec）。
  - visual baseline deferred: Android 真机由用户提供后采集，deferred_reason=device_required。
- test_tasks:
  - type: integration
    layer: integration
    domain: android
    description: Android 真机 endpoint acceptance 验证 native bridge 链路
    scenarios: [design-test-2 Android real device]
    deferred: true
    deferred_reason: device_required
- contract_refs: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-acceptance-spec.yaml]
- decision_refs: [DEC-R002-005]
- blocked_files: []
- 具体改动点：
  - R002-FF003.1 `⬜` 增加运行模式选择：iOS/Dart plane 与 Android/native plane。
  - R002-FF003.2 `⬜` Android 分支复用已有 `NativeControlPlaneBridge` start/register/stop。
  - R002-FF003.3 `⬜` 将 native plane endpoint 和 request log 同步到同一 UI。
- 关键代码片段：
  ```dart
  class AndroidNativePlane {
    Future<Uri?> start({required NativeControlPlaneBridge bridge});
    Future<void> registerCapabilities(List<BridgeCapability> capabilities);
  }
  ```
- 改动理由/上下文：Android 真机阶段验证 R001/R002 穿过 Flutter plugin、Android native bridge 和 Kotlin core 的真实链路。

## R002-FF004：example tests — Flutter 单测与 iOS 模拟器验收入口 `⬜ 待处理`

- 文件：`flutter_debug_control_plane/example/test/acceptance_app_test.dart` + `flutter_debug_control_plane/example/integration_test/auth_acceptance_test.dart`
- 改动类型：新建
- domain: ui
- task_layer: foundation
- depends_on: [R002-FF002, R002-FB001, R002-BF006]
- priority: 4
- risk_tags: [tests, flutter, ios_simulator]
- smoke_required: true
- mode: direct
- status: pending
- sourceCapabilities: [FF002, FB001, BF006]
- sourceSlices: [S01-acceptance-app]
- sourceDesigns: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-design.md]
- sourceTests: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md]
- acceptance_criteria:
  - Flutter tests 覆盖页面结构、稳定标识、auth 状态机和固定 capability。
  - iOS 模拟器 integration test 可作为手动验收入口运行。
  - 无模拟器时测试输出明确 skip/setup_required，不阻塞普通 CI。
  - 实现 12 个稳定标识（清单见 AcceptanceSpec）。
  - visual-verify PASS（三层证据对照 AcceptanceSpec）。
  - visual baseline deferred: iOS simulator 截图在执行阶段采集，deferred_reason=device_required。
- test_tasks:
  - type: unit
    layer: unit
    domain: flutter
    description: example app headless tests
    scenarios: [design-test-1 unit.flutter]
  - type: integration
    layer: integration
    domain: ios
    description: iOS simulator integration test 手动执行
    scenarios: [design-test-2 iOS simulator]
    deferred: true
    deferred_reason: device_required
- contract_refs: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md]
- decision_refs: [DEC-R002-002, DEC-R002-005]
- blocked_files: []
- 具体改动点：
  - R002-FF004.1 `⬜` 添加 controller/capability/widget tests。
  - R002-FF004.2 `⬜` 添加 iOS simulator integration_test 入口和 README 注释。
  - R002-FF004.3 `⬜` 确保无设备环境不会误报通过。
- 关键代码片段：
  ```dart
  testWidgets('acceptance app exposes stable identifiers', (tester) async {
    await tester.pumpWidget(const AcceptanceApp());
    expect(find.byKey(const ValueKey('acceptance.status.endpoint_text')), findsOneWidget);
  });
  ```
- 改动理由/上下文：把 iOS 模拟器验收作为第一阶段真实 App 验收入口，同时保持主 CI 可控。

## R002-BF008：regression gate — R001+R002 联合回归 `⬜ 待处理`

- 文件：`ci/README.md` + `.dev-flow/R002/evidence/execute-checkpoint.md`
- 改动类型：修改 / 新建
- domain: integration
- task_layer: foundation
- depends_on: [R002-BF005, R002-FF003, R002-FF004]
- priority: 5
- risk_tags: [ci, regression, acceptance]
- smoke_required: true
- mode: negotiated
- status: pending
- sourceCapabilities: [BF005, BF006, FF002, FB001]
- sourceSlices: [S01-acceptance-app]
- sourceDesigns: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-design.md]
- sourceTests: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md]
- acceptance_criteria:
  - `PYTHON_BIN=python3 bash ci/ci-check-all.sh` 仍通过。
  - 文档说明 iOS 模拟器验收命令和 Android 真机验收命令。
  - evidence checkpoint 记录 R002 自动测试、deferred device tests 和人工验收步骤。
- test_tasks:
  - type: integration
    layer: integration
    domain: cross_stack
    description: 全量主 CI 回归
    scenarios: [design-test-3 回归]
  - type: e2e
    layer: e2e
    domain: full
    description: iOS simulator 与 Android real device acceptance
    scenarios: [design-test-4 集成测试方案]
    deferred: true
    deferred_reason: device_required
- contract_refs: [.dev-flow/R002/analysis/2026-08-24--flutter-auth-acceptance-app-test.md]
- decision_refs: [DEC-R002-002]
- blocked_files: []
- 具体改动点：
  - R002-BF008.1 `⬜` 更新 `ci/README.md`，记录独立 acceptance gate 用法。
  - R002-BF008.2 `⬜` 新建/更新 R002 execute checkpoint。
  - R002-BF008.3 `⬜` 跑主 CI 和可用的 example app tests，记录 deferred device 验收。
- 关键代码片段：
  ```bash
  PYTHON_BIN=python3 bash ci/ci-check-all.sh
  bash ci/acceptance-flutter-app.sh --target ios-simulator --endpoint "$ACCEPTANCE_APP_ENDPOINT"
  bash ci/acceptance-flutter-app.sh --target android-device --endpoint "$ACCEPTANCE_APP_ENDPOINT"
  ```
- 改动理由/上下文：R002 的完成标准需要同时保护现有 R001 回归和新增真实 App 验收入口。
