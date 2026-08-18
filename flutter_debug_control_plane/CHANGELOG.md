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
