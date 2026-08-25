# Debug Plane Acceptance Example (R002)

Flutter 验收 App：内嵌 Dart debug plane（Android 真机走 native bridge），
暴露 12 个稳定标识（`acceptance.*`）与六态 auth 状态机，作为 R002 验收载体。

## 测试

### 单元 / widget 测试（headless，普通 CI）

```bash
cd flutter_debug_control_plane/example
fvm flutter test
```

全部为 headless 用例，无需设备；真实 plane I/O 通过 `tester.runAsync` 驱动。

### iOS 模拟器手动验收入口（R002-FF004）

`integration_test/auth_acceptance_test.dart` 是完整验收链路的**手动入口**
（app 启动 → plane 运行 → 真实 HTTP `/auth/request` → pending 弹窗 →
approve → token → 敏感请求 → expire/clear → 截图）：

```bash
cd flutter_debug_control_plane/example
fvm flutter test integration_test/auth_acceptance_test.dart \
  -d DAA2A14D-9BF2-4E3B-9EF2-A7E1136C631F
```

- 截图输出到宿主机 `/tmp/ff004_acceptance/`（`ff004_*.png`）。
- **必须显式传 `-d <simulator-udid>`**；该入口不属于普通 CI 单测集
  （`fvm flutter test` 不会运行 `integration_test/` 下的用例）。
- 无模拟器 / 非 iOS 平台误跑时，首个用例显式 fail 并提示
  `setup_required`（不会静默通过、不会误报 pass）。

### 锚点扫描集成测试（FF002/FB001/FF003）

`integration_test/acceptance_integration_test.dart`：12 稳定标识定位 +
三区域滚动截图；Android 分组含 native bridge 真实 HTTP 用例。

`integration_test/acceptance_pytest_driver_test.dart`：BF005 驱动夹具。
