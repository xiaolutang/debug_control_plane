# debug_control_plane (Dart / Flutter)

> Multi-product reusable **debug control plane** infrastructure for Flutter apps.
> 多产品复用的 **调试控制平面** 基础设施（Flutter 应用用）。
>
> Extracted from an internal Flutter app into an independent repo so it can be reused across multiple products without coupling to any single business package.
> 从某内部 Flutter 应用抽离为独立仓库，可在多产品间复用，不耦合任何单一业务包。

**Status / 状态**: version `0.5.2` — **API is UNSTABLE**. Breaking changes are expected before `1.0.0`; pin the exact version in consumers. The ecosystem (kotlin JitPack core / this package / `flutter_debug_control_plane`) shares one version line — same number = verified-compatible set.
版本 `0.5.2` — **API 不稳定**。`1.0.0` 之前可能有破坏性变更，消费方请锁定精确版本号。整个生态（kotlin JitPack 核心 / 本包 / `flutter_debug_control_plane`）统一版本线——同版本号 = 已验证兼容组合。

## Three-layer skeleton / 三层骨架

The package is organized as three cooperating layers. Business code depends on the `ControlPlane` facade; the plane itself never imports business code.
本包组织为三个协作层。业务代码依赖 `ControlPlane` 门面；平面本身绝不 import 业务代码。

| Layer / 层 | Responsibility / 职责 | Direction / 方向 |
|-------------|------------------------|--------------------|
| **Transport** | Wire transport for the debug HTTP protocol (8 endpoints, byte-level stable). Pluggable: REST+SSE (shipped) / future WS / MCP. 调试 HTTP 协议的线上传输（8 端点，字节级稳定）。可插拔：REST+SSE（已交付）/ 未来 WS / MCP。 | bottom — knows nothing above / 底层，对上层一无所知 |
| **ControlPlane** | Facade that wires capabilities to a transport, owns request dispatch and lifecycle (`start` / `stop`). 把能力接到传输上、负责请求分发与生命周期（`start` / `stop`）的门面。 | middle — the only thing business code talks to / 中层，业务代码唯一对接处 |
| **Capability** | Self-contained debug feature (e.g. `MyDebugCapability`). Declares resources / commands against the plane. 自包含的调试特性（如 `MyDebugCapability`）。向平面声明资源 / 命令。 | top — authored by business / product teams / 顶层，由业务 / 产品团队编写 |

### Dependency direction (strict, one-way) / 依赖方向（严格，单向）

```
business / product code          业务 / 产品代码
        │  depends on (imports)   依赖（import）
        ▼
   ControlPlane  (facade)
        │  depends on (imports)   依赖（import）
        ▼
    Transport

   ControlPlane  NEVER imports business code.   平面绝不 import 业务代码。
   Capability    is shipped by the plane as base classes; product capabilities live in the product repo.
                  Capability 由平面作为基类提供；产品自有能力放在产品仓库。
```

- business → plane: allowed (the only legal direction). 业务 → 平面：允许（唯一合法方向）。
- plane → business: **FORBIDDEN**. 平面 → 业务：**禁止**。

## Usage / 用法

```dart
import 'package:debug_control_plane/debug_control_plane.dart';

Future<void> main() async {
  final plane = ControlPlane(
    transport: HttpSseTransport(),
    // App identity is injected here; the framework stays business-agnostic.
    // 应用身份在此注入；框架保持业务无关。
    appMeta: () => {'app': 'my_app'},
  )..register(MyCapability());

  await plane.start(address: '0.0.0.0', port: 18080);
}
```

A complete runnable example lives in
[`example/debug_control_plane_example.dart`](example/debug_control_plane_example.dart) —
run it with `dart example/debug_control_plane_example.dart`.
完整可运行示例见 [`example/debug_control_plane_example.dart`](example/debug_control_plane_example.dart)——用 `dart example/debug_control_plane_example.dart` 运行。

**新项目接入?** 见分步指南 [GETTING_STARTED.md](GETTING_STARTED.md)(5 步接入 + capability 编写 + 平台支持 + 常见坑)。
**New project?** See the step-by-step [GETTING_STARTED.md](GETTING_STARTED.md) (5-step integration + capability authoring + platform matrix + pitfalls).

### Public API surface / 公共 API 面

- `ControlPlane({required Transport transport, Map<String,Object?> Function()? appMeta})` — registry + dispatch + event bus + `/hello` handshake. 注册表 + 分发 + 事件总线 + `/hello` 握手。
- `Capability` — `id` / `resources` (GET) / `commands` (POST) / `events` / `state()`.
- `Resource` / `Command` — `{method, path, handler, description?}`; `path` is a list of segments with `{name}` placeholders. `path` 是带 `{name}` 占位符的段列表。
- `Transport` — `bind` / `listen` / `broadcast` / `serverInfo` / `close` (protocol-agnostic contract). 协议无关契约。
- `HttpSseTransport` — the REST + SSE production transport (byte-level compatible with the legacy `internal debug runtime`). REST + SSE 生产传输（与遗留 `internal debug runtime` 字节级兼容）。

## Dependencies / 依赖

This package depends on the **Flutter / Dart SDK only** (`dart:io`, `dart:async`, `dart:convert`). It deliberately has **zero business dependencies** — no business packages. This is what makes it reusable across products.
本包**仅依赖 Flutter / Dart SDK**（`dart:io`、`dart:async`、`dart:convert`），刻意保持**零业务依赖**——不引任何业务包。这正是它能跨产品复用的关键。

## Versioning / 版本策略

- `0.1.0` — initial release. 首发版本。
- Pre-`1.0.0` versions have **unstable public API**. Do not rely on type / method signatures being stable across minor bumps. `1.0.0` 前版本 **公共 API 不稳定**。次版本号变更也可能改动类型 / 方法签名。
- See [CHANGELOG.md](CHANGELOG.md) for release history. 发布历史见 [CHANGELOG.md](CHANGELOG.md)。

## Origin / 来源

Extracted from an internal app's debug control plane into this standalone repo.
抽自某内部应用的调试控制平面，抽离为本独立仓库。

## License / 许可证

Licensed under the MIT License — see [LICENSE](LICENSE).
采用 MIT 许可证授权——见 [LICENSE](LICENSE)。
