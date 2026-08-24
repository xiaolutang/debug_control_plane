---
type: analysis
status: integrating
requirement_cycle: R002
topic: flutter-auth-acceptance-app
date: 2026-08-24
---

# Flutter 鉴权验收 App — 集成分析

## 概述

R002 新增 `flutter_debug_control_plane/example/` 下的最小真实宿主 App，并配套独立 acceptance 入口。它用于把 R001 debug plane 自身鉴权从模块级验证推进到真实 App 接入验证：电脑端 Python MCP adapter 连接 App debug plane，App 侧弹出授权 UI，授权状态与请求日志可观察，多个测试 capability 统一经过鉴权。

## 集成范围

| 能力 | Owner | 说明 |
|---|---|---|
| FF002 | Flutter acceptance fixture app | example app 骨架、plugin 接入、plane 状态、测试 capability 注册。 |
| FB001 | app-hosted auth acceptance flow | 授权弹窗、同意/拒绝、清 token、模拟过期等验收动作。 |
| BF005 | acceptance runner boundary | 电脑端验收脚本入口与运行边界，不并入主 CI。 |
| BF006 | acceptance observability contract | 状态/日志/固定 capability 返回 shape，支撑人工和脚本断言。 |

## 反向坍缩复验

| 能力 | trigger | responsibility | result | acceptance | independently_absent |
|---|---|---|---|---|---|
| FF002 | 启动 example app | 真实宿主接入 plugin 与 debug plane | App listening 并注册测试 capability | 端口/状态可见，capability 可被请求 | 移除后无法验证真实 App 接入，但不影响脚本定义 |
| FB001 | 未授权请求或验收者控制操作 | 承载授权 UI 和 token 状态操作 | 授权状态变化、日志更新 | 同意/拒绝/过期路径可人工验证 | 移除后仍可启动 App，但不能验收授权交互 |
| BF005 | 维护者运行 acceptance 命令 | 从电脑端驱动真实 App 验收 | pass/fail/setup_required 结果 | 可复现未授权、授权后、过期、多 capability 场景 | 移除后 App 可运行，但缺少端到端脚本 |
| BF006 | App 收到请求或 capability 返回 | 定义可观察日志和固定返回协议 | 稳定 JSON/log entry | 脚本和人工验收有同一事实源 | 移除后仍可操作，但断言不稳定 |

结论：4 个能力均满足五项原子检查，不需要进一步拆分。

## 下游设计关注点

- 目录归属优先使用 `flutter_debug_control_plane/example/`，因为该 App 是 plugin 的真实宿主示例和验收夹具。
- 第一阶段支持 iOS 模拟器，通过 Flutter App + Dart `debug_control_plane` 跑通 App 宿主授权闭环；第二阶段支持真实 Android 设备，通过 `flutter_debug_control_plane` plugin 验证 native bridge。
- iOS native plugin bridge 不进入 R002；如果后续需要 iOS 也验证 plugin native bridge，应另开 RC 增加 iOS plugin 平台实现。
- acceptance 脚本需要清晰区分 setup failure 与功能 failure。
- 主 CI `ci/ci-check-all.sh` 保持稳定；新增独立 `ci/acceptance-flutter-app.sh` 或等价入口。
- UI 要克制实用，避免做成产品页面；核心是可观察、可重置、可复现。

## 开放问题

- Python 端真实连接 App 的 endpoint 来源可先支持手动传入，后续再接设备发现自动选择。
- token 领取方式以 R001 已实现机制为准，R002 不重新定义鉴权协议。
- 是否把 Flutter integration test 纳入 R002 第一版，由 design 根据现有 example 工程成本决定。
