---
module: flutter_debug_control_plane
version: 1.0
date: 2026-09-04
tags: [auth, plugin, assembly-api, test]
type: design_test
status: designed
requirement_cycle: R006
source_analysis: .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy.md
source_design: .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-design.md
---

# Android 插件授权策略装配 API — 测试设计

> 关联设计：[R006 设计报告](2026-09-04--android-plugin-auth-policy-design.md)

## 1. 测试策略

| 层 | 工具 | 覆盖目标 |
|---|---|---|
| unit (Kotlin JVM) | gradle testDebugUnitTest（插件 android 工程） | 三策略装配语义 + 非法值 + autoApprove 行为（BF001 核心） |
| unit (Dart) | flutter test（插件包） | AuthPolicy 序列化 + start 参数透传（FF001） |
| integration (e2e 真机) | 既有 integration-android.sh 模式 fork | auto 策略 python 直连 + none 一致性（BF002；deferred 契约复用） |
| 契约 | 既有 protocol fixtures 测试 | `/auth/*`、`/hello` wire 零改动回归 |

覆盖率目标：BF001 装配分支（BF002 承载的 JVM 单测）100%（when 三分支 + 非法值）；e2e 主场景（auto 直连）。

## 2. 测试场景矩阵

### JVM 单测（BF001，新增文件 PluginAuthPolicyTest.kt）

| # | 场景 | 断言 |
|---|---|---|
| K1 | plane.start 无 authPolicy | ensurePlane 装配非 null manager 且 autoApprove=false（现状） |
| K2 | authPolicy=default | 同 K1（显式=隐式） |
| K3 | authPolicy=auto | manager 非 null 且 autoApprove=true |
| K4 | authPolicy=none | mount 收到 authManager=null（可观察：authorize 直接放行/`/hello` 无 authRequired） |
| K5 | authPolicy="bogus" | 返回 invalid_arguments error，PlaneCarrier 未 mount |
| K6 | autoApprove=true 的 requestAuthorization | 响应 202 status=approved 且 tokenRecord 已落 store；宿主通知仍发出 |
| K7 | autoApprove=false（对照） | 响应 202 status=pending（现状不变） |
| K8 | auto 下 claim → Bearer authorize | claim 得 token；authorize(token) = Authorized |

### Dart 单测（FF001，新增 test/auth_policy_test.dart）

| # | 场景 | 断言 |
|---|---|---|
| T1 | AuthPolicy 三值 wireName 映射 | defaultPolicy→"default" / auto→"auto" / none→"none" |
| T2 | start() 不传 authPolicy | channel 参数表无 authPolicy 字段（字节兼容） |
| T3 | start(authPolicy: auto) | channel 参数表含 authPolicy:"auto" |
| T4 | 枚举不可构造非法值 | 类型系统保证（编译期），测试仅断言 fromWire(null)→defaultPolicy |

### e2e 真机（BF002，fork integration-android.sh → R006 test-overrides）

| # | 场景 | 断言 |
|---|---|---|
| E1 | auto 策略启动 + python 脚手架编排 401→request→claim | claim 200 得 token，全程无人工审批 |
| E2 | E1 后 Bearer 直连敏感路由 | 200 |
| E3 | 冷重启后旧 Bearer（auto token 持久化链） | 200 authorized（R004 持久化在 auto 策略下照常） |
| E4 | none 策略启动（对照组 app 或重启切策略） | 无 token 请求敏感路由 200；/hello 无 authRequired |
| E5 | 非法策略值经 channel 直调 | invalid_arguments，plane 未启动 |
| E6 | default（不传）回归 | 既有验收集全绿 |

deferred 契约：真机不在场（23116PN5BC）→ evidence 双写 `status: deferred, deferred_reason: device_required`，exit 0（复用 R004/R005 模式）。

## 3. 验收标准（对齐 design §7）

AC1/AC6 → E6 + 既有 fixtures；AC2/AC4 → K4/K5+T4；AC3 → K6/K8+E1/E2；AC5 → E4（+纯 Dart 既有语义对照）；AC7 → E1-E3（python 零改动前提）。

## 4. 集成测试方案

- 拓扑：宿主 macOS（python 脚手架）↔ USB 真机（example app 两 profile：默认/default 与 auto；none 用第三 profile 或 env 切换）。
- 启动清理：每用例 simctl/adb 层重启 app（冷重启断言 E3 需要）；`.dev-flow/R006/test-overrides/R006-BF002/` 落驱动+断言脚本，产物 `.work/` 已在 .gitignore。
- 真实 vs Mock：全真实（真机 plugin + 真实 HTTP）；python 编排用纯标准库 urllib（R004/R005 先例），不依赖 mcp_plane 内部 API。
- 故障注入：E5（非法值）、E3（冷重启）、损坏 store 文件不自愈路径不在本 RC（R004 已覆盖）。

## 5. 测试数据与 Mock 实现

- JVM 单测：FakePluginDebugAuthStore（内存 map，R004 既有测试先例）+ 可注入 now() 固定时钟。
- e2e：clientLabel 用 `r006-e{N}` 前缀分派（沿用 R002 driver deny*/hold* 约定外新增无需分派的直连场景）。
- fixture：无新增 wire fixture（协议零改动）。

## 6. 暂不测试

- python mcp_plane 库自动编排（未实现，D6 边界外）。
- iOS 模拟器路径（authPolicy 通道是 Android plugin channel；iOS 走纯 Dart 宿主既有测试覆盖）。
- 运行时动态切换策略（设计明确 start 后不可变）。
