# debug_control_plane

Multi-product reusable **debug control plane** infrastructure (Dart + Python monorepo).
多产品复用的 **调试控制平面** 基础设施（Dart + Python 单体仓库）。

Split out from an internal Flutter app's debug control plane into a standalone repo for horizontal reuse across products.
从一个内部 Flutter 应用的调试控制平面抽离为独立仓库，供多产品横向复用。

## Structure / 结构

- `dart/` — Flutter package `debug_control_plane` (Transport / ControlPlane / Capability)
- `python/` — Python package `debug-control-plane` (`device_discovery` + `mcp_plane`)
- `ci/` — Repo-level checks (dependency direction guards, etc.) / repo 级检查（依赖方向守护等）

## Dependency invariant (hard) / 依赖不变量（硬约束）

Business apps → plane (`debug_control_plane`).
业务应用 → 平面（`debug_control_plane`）。

`debug_control_plane` **NEVER** imports business code. This is enforced by `ci/zero-business-dep-check.sh`.
`debug_control_plane` **绝不** import 业务代码。由 `ci/zero-business-dep-check.sh` 强制执行。

## Distribution / 分发

- Dart: [`pub.dev`](https://pub.dev/packages/debug_control_plane) (`debug_control_plane`)
- Python: [`PyPI`](https://pypi.org/project/debug-control-plane/) (`debug-control-plane`) + git tag; dev mode uses `pip install -e .`
- Python：[`PyPI`](https://pypi.org/project/debug-control-plane/)（`debug-control-plane`）+ git tag；开发模式用 `pip install -e .`

Licensed under the MIT License — see [LICENSE](LICENSE).
采用 MIT 许可证授权——见 [LICENSE](LICENSE)。

## Integration guide / 接入指南

New Flutter project? See [`dart/GETTING_STARTED.md`](dart/GETTING_STARTED.md) — 5-step integration (dependency → import → capability → assemble → verify), capability authoring, platform support matrix, and common pitfalls.
新 Flutter 项目接入？见 [`dart/GETTING_STARTED.md`](dart/GETTING_STARTED.md) —— 5 步接入（依赖 → import → 实现 capability → 装配启动 → 验证）+ capability 编写规范 + 平台支持矩阵 + 常见坑。

## Version / 版本

`0.1.2` — current release, API unstable (expect breaking changes without a major bump until the first stable release).
`0.1.2` — 当前版本，API 不稳定（在首个稳定版之前，次版本号变更也可能含破坏性改动）。

## Origin / 来源

Extracted from an internal app's debug control plane into this standalone repo. See [CHANGELOG.md](CHANGELOG.md) for the release history.
抽自一个内部应用的调试控制平面，抽离为本独立仓库。发布历史见 [CHANGELOG.md](CHANGELOG.md)。
