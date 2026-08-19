# debug_control_plane

Multi-product reusable **debug control plane** infrastructure (Dart + Python monorepo).
多产品复用的 **调试控制平面** 基础设施（Dart + Python 单体仓库）。

Split out from an internal Flutter app's debug control plane into a standalone repo for horizontal reuse across products.
从一个内部 Flutter 应用的调试控制平面抽离为独立仓库，供多产品横向复用。

## Structure / 结构

- `dart/` — Dart package `debug_control_plane` (Transport / ControlPlane / Capability)
- `kotlin/` — Kotlin core `com.github.xiaolutang:debug_control_plane` (JVM pure library; Android native hosts)
- `flutter_debug_control_plane/` — Flutter plugin bridging Dart capabilities to the Kotlin core (Android)
- `python/` — Python package `debug-control-plane` (`device_discovery` + `mcp_plane`)
- `ci/` — Repo-level checks (dependency direction guards, etc.) / repo 级检查（依赖方向守护等）

## Dependency invariant (hard) / 依赖不变量（硬约束）

Business apps → plane (`debug_control_plane`).
业务应用 → 平面（`debug_control_plane`）。

`debug_control_plane` **NEVER** imports business code. This is enforced by `ci/zero-business-dep-check.sh`.
`debug_control_plane` **绝不** import 业务代码。由 `ci/zero-business-dep-check.sh` 强制执行。

## Distribution / 分发

- Dart: [`pub.dev`](https://pub.dev/packages/debug_control_plane) (`debug_control_plane`)
- Kotlin core: [`JitPack`](https://jitpack.io/#xiaolutang/debug_control_plane) — `com.github.xiaolutang:debug_control_plane`
- Flutter plugin: [`pub.dev`](https://pub.dev/packages/flutter_debug_control_plane) (`flutter_debug_control_plane`)
- Python: [`PyPI`](https://pypi.org/project/debug-control-plane/) (`debug-control-plane`) + git tag; dev mode uses `pip install -e .`
- Python：[`PyPI`](https://pypi.org/project/debug-control-plane/)（`debug-control-plane`）+ git tag；开发模式用 `pip install -e .`

**Version alignment / 版本对齐**: the whole ecosystem shares one version line —
kotlin (JitPack) / dart (pub.dev) / flutter plugin (pub.dev) all at `0.2.0`.
Same version number = verified-compatible set; upgrade all three together.
**版本对齐**：整个生态统一版本线——kotlin（JitPack）/ dart（pub.dev）/ flutter
插件（pub.dev）同为 `0.2.0`。同版本号 = 已验证兼容组合；升级时三端一起动。

Licensed under the MIT License — see [LICENSE](LICENSE).
采用 MIT 许可证授权——见 [LICENSE](LICENSE)。

## Integration guide / 接入指南

- New Flutter project? See [`dart/GETTING_STARTED.md`](dart/GETTING_STARTED.md) — 5-step integration (dependency → import → capability → assemble → verify), capability authoring, platform support matrix, and common pitfalls.
  新 Flutter 项目接入？见 [`dart/GETTING_STARTED.md`](dart/GETTING_STARTED.md) —— 5 步接入（依赖 → import → 实现 capability → 装配启动 → 验证）+ capability 编写规范 + 平台支持矩阵 + 常见坑。
- Android native (or any JVM) project? See [`kotlin/README.md`](kotlin/README.md) — JitPack dependency, `Application` wiring, start-once semantics, capability authoring.
  Android 原生（或任意 JVM）项目接入？见 [`kotlin/README.md`](kotlin/README.md) —— JitPack 依赖、`Application` 装配、start-once 启动语义、capability 编写。

## Version / 版本

`0.2.0` — current release, API unstable (expect breaking changes without a major bump until the first stable release).
`0.2.0` —— 当前版本，API 不稳定（在首个稳定版之前，次版本号变更也可能含破坏性改动）。

## Origin / 来源

Extracted from an internal app's debug control plane into this standalone repo. See [CHANGELOG.md](CHANGELOG.md) for the release history.
抽自一个内部应用的调试控制平面，抽离为本独立仓库。发布历史见 [CHANGELOG.md](CHANGELOG.md)。
