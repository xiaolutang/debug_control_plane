# 架构宪法

## 项目定位

`debug_control_plane` 是多产品复用的调试控制平面基础设施，覆盖 Kotlin JVM core、Dart package、Flutter Android plugin、Python device discovery + MCP adapter。

## 硬约束

- 零业务依赖：control plane 不得 import 业务包；业务应用只能向下依赖 control plane。
- 协议真相源：HTTP/SSE 字节级协议以 `PROTOCOL.md` 和 `fixtures/` 为准。
- 跨语言一致：Kotlin、Dart、Flutter plugin、Python 的字段、错误码、协议版本必须同步演进。
- 根 Gradle 仅聚合：根 `build.gradle.kts` 不发布，`:kotlin` 是 JVM 发布模块；Flutter plugin Android 工程独立由 Flutter toolchain 消费。
- Android 生命周期归宿主：debug plane 不自动启动，宿主负责 scope、start/stop、端口生命周期。

## 模块边界

- `kotlin/`：纯 JVM debug plane core，负责 ControlPlane、Transport、Capability、HTTP/SSE、路由、事件总线。
- `dart/`：Dart 侧 ControlPlane / Transport / Capability 抽象与 HTTP/SSE 实现。
- `flutter_debug_control_plane/`：Android Flutter plugin，通过 MethodChannel 把 Dart capability 桥到 Kotlin core。
- `python/`：设备发现、设备池、MCP adapter、BridgeClient；对 App debug plane 是 HTTP client，对 AI host 是 MCP stdio server adapter。
- `ci/`：跨语言全量守卫、零业务依赖、协议版本和发布前置检查。

## 鉴权设计约束

- 真实资源边界在 App debug plane，最终授权判定必须由 debug plane 执行，Python adapter 只负责携带凭证和翻译错误。
- MCP adapter 架构保留；不为了标准化而把 App 直接改成完整 MCP server。
- 鉴权不得破坏未授权发现的最小 bootstrap 能力；敏感调试能力必须统一经过授权门。
- token 不得通过 query string 传递；HTTP 请求使用 `Authorization: Bearer <token>`。

## 验证入口

- 全量：`bash ci/ci-check-all.sh`
- Kotlin：`./gradlew build`
- Dart：`cd dart && fvm flutter test`
- Flutter plugin：`cd flutter_debug_control_plane && fvm flutter test`
- Python：`cd python && ${PYTHON_BIN:-python3} -m pytest tests -q --no-header`

