## 0.4.0

- 新增 `PageCapabilityScope` helper:业务按 pageId 注册/释放 page 级
  capability(两段式预检查 + 幂等 + dispose no-op),MethodChannel 透传
  scope identity。
- Android 侧 native registry 解析 scope/pageId payload,page capability
  与 app capability 同 ControlPlane 并存;离开页面即释放,gone 后调用
  返回 `410 page_capability_gone`。
- 示例 app 新增 Page Scope Demo(page A/B 独立 route);Android 侧
  Kotlin 核心依赖升到 `0.4.0`(dart 侧 ^0.4.0)。

## 0.3.0

- 版本对齐: kotlin 核心、dart 核心、本插件统一到 `0.3.0`，同版本号 =
  已验证兼容组合。
- Android 真机验收覆盖认证流程，并修正示例 app 重复启动/停止 native plane
  时的注册去重与清理行为。
- Android 侧 Kotlin 核心依赖升到
  `com.github.xiaolutang:debug_control_plane:0.3.0`。

## 0.2.0

- 版本对齐:整个 debug_control_plane 生态统一版本线——kotlin 0.2.0
  (JitPack)、dart 核心 0.2.0(pub.dev)、本插件 0.2.0。同版本号 =
  已验证兼容组合,升级时三端对齐到同一版本。
- Dart 侧依赖升 debug_control_plane ^0.2.0。

## 0.1.0

- 首个 pub.dev 版本。Android MethodChannel 桥:Dart Capability 注册到原生
  ControlPlane(via NanoHTTPD server),支持正向调用 / SSE 事件流 / 反向
  invoke(native → Dart capability)。
- Kotlin 核心经 JitPack 坐标 `com.github.xiaolutang:debug_control_plane:0.2.0`
  分发(源码 tag v0.2.0,同一 repo)。
- Dart 侧依赖 debug_control_plane ^0.1.1(pub.dev)。
