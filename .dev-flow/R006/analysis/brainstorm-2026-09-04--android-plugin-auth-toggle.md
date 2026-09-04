---
date: 2026-09-04
type: brainstorm
status: concluded
requirement_cycle: R006
topic: android-plugin-auth-toggle
---

# android-plugin-auth-toggle

## 结论
- 要做什么：降低 Android 插件宿主的授权接入门槛——业务「不配置授权弹窗」时的行为要可预期。候选：①插件加 `enableAuth:false` 关闭开关；②文档化「自动 approve handler」最小接入模式（不改代码）；③两者都做。
- 不做什么：不改 `/auth/*` wire 协议；不动纯 Dart 宿主路径（已天然免授权）。
- 关键约束：架构宪法「敏感调试能力必须统一经过授权门」——完全关闭授权与宪法存在张力，若做开关需评估 dev-only 门禁（debug 包生效/release 关闭）或显式风险豁免决策。
- 核心场景：业务 app 接入插件后不写任何授权 UI，python MCP 端请求敏感接口——期望要么直接可用，要么有明确文档指引的最小接入（自动 approve handler ~6 行，example driver 先例）。
- 待确认：业务真实宿主形态与诉求（纯 Dart 宿主已满足，还是必须 Android 插件？）；开关是否接受 dev-only 限制；宪法约束是否豁免。

## 关键讨论
- 现状勘察（2026-09-04，0.5.1）：
  - 纯 Dart/iOS 宿主：`ControlPlane` 不传 `authManager` 即天然免授权（dart/lib/src/control_plane.dart:370 `if (auth == null) return null`），`/hello` 无 `authRequired` 字段——**该形态已满足业务诉求，无需任何改动**。
  - Android 插件宿主：`DebugControlPlaneFlutterPlugin.kt:111`（`onAttachedToEngine` 无条件 `authManager = PluginDebugAuthManager(...)` 挂进 plane，channel 协议无 enableAuth 开关）。业务不接 UI 时授权请求挂 pending，敏感接口 401 `authorization_required`。
  - python 端：`bridge_client.py:676` 对 401 `authorization_required` 自动走 request→poll→claim 链；「自动 approve」的先例在 example driver（clientLabel 前缀分派，r005_persistence_driver_test.dart:56-66）。
- 取舍倾向：优先方案②（文档+示例零代码），①作为后续选项待业务确认后评估——避免仓促引入与架构宪法冲突的开关。
- 用户指示：先记录，后续处理（2026-09-04）。
