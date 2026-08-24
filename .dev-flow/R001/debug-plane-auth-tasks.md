---
version: "1.0"
type: tasks
topic: debug-plane-auth
requirement_cycle: R001
taskPackageVersion: "1.8"
workflow:
  evaluate_provider: direct_subagent
  mode: auto
status: planned
analysisManifestPath: .dev-flow/R001/analysis/manifest.json
analysisManifestRevision: 1
analysisManifestDigest: 8547495e42aab361b9007a5ab0e4ea3e88c02eddf08a1324402d3f2e249adc4b
analysisIntegrationPath: .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-integration.md
bootstrapLegacy: false
analysisSourceMdPaths:
  - .dev-flow/R001/analysis/manifest.json
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-python-slice.md
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-integration.md
designMdPaths:
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md
testMdPaths:
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md
contextMdPaths:
  - .dev-flow/architecture.md
  - .dev-flow/R001/analysis/manifest.json
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-python-slice.md
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-integration.md
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md
  - .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md
---

# R001 Debug Plane 自身鉴权任务清单

全局约束：

- 保留 Python MCP adapter 架构；不实现 App 直连 MCP server。
- token 不走 query string；敏感请求统一使用 `Authorization: Bearer <token>`。
- Kotlin core 保持 pure JVM，不 import Android/Flutter/UI/storage。
- `DevicePool` 持久化保持 identity-only，不写 token。
- 第一版不做 OAuth/JWT/RBAC/refresh token/scope。

## 执行顺序

1. R001-BF001 → R001-BF002
2. R001-BF003 → R001-BF004 → R001-BF005 → R001-BF006
3. R001-BF007 → R001-BF008
4. R001-FF001 → R001-FF002 → R001-FF003
5. R001-BF009 → R001-BB001
6. R001-BF010

## R001-BF001：PROTOCOL.md — Auth wire contract `✅ 已完成`

- 文件：`PROTOCOL.md`
- 改动类型：修改
- domain: docs
- task_layer: foundation
- depends_on: []
- priority: 5
- risk_tags: [protocol, auth, cross_language]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF002]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md, .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-python-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - 明确定义 `Authorization: Bearer <token>` 只能走 header 且不得走 query string。
  - 明确定义 `/hello` 未授权最小 bootstrap 与授权后完整 hello 字段差异。
  - 明确定义 `/auth/request`、`/auth/status`、`/auth/claim` 的方法、body、状态码与响应字段。
  - 明确定义 401/403 auth error code 且 `protocolVersion` 保持 1。
- test_tasks:
  - type: unit
    layer: unit
    domain: backend
    description: 协议文档更新后由 fixture/golden 任务验证字段一致性
    scenarios: [design-test-2 fixtures auth json]
- contract_refs: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- decision_refs: [DEC-R001-001, DEC-R001-002, DEC-R001-003, DEC-R001-004, DEC-R001-006]
- blocked_files: []
- 具体改动点：
  - R001-BF001.1 `⬜` 新增 Auth 章节，放在系统路由和错误契约附近。
  - R001-BF001.2 `⬜` 标注未授权 `/hello` 不返回 `registeredCapabilities` 与聚合 state。
  - R001-BF001.3 `⬜` 记录 SSE 建连鉴权：失败不能写 `: connected`。
- 关键代码片段：
  ```http
  Authorization: Bearer <opaque-token>
  POST /auth/claim
  {"requestId":"...","clientNonce":"..."}
  ```
- 改动理由/上下文：协议是跨 Kotlin/Dart/Python/Flutter 的真相源，必须先固化再实现。

## R001-BF002：fixtures — Auth golden fixtures `✅ 已完成`

- 文件：`fixtures/README.md` + `fixtures/*.json`
- 改动类型：修改 / 新建
- domain: backend
- task_layer: foundation
- depends_on: [R001-BF001]
- priority: 5
- risk_tags: [fixtures, protocol]
- smoke_required: true
- mode: direct
- status: completed
- sourceCapabilities: [BF002]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md, .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-python-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - 新增 auth bootstrap、authorized hello、401 authorization_required、401 token_expired、403 authorization_denied、auth claim fixtures。
  - fixtures 不包含真实 token 明文，测试 token 只使用明显假值。
  - README 说明每个 auth fixture 的使用场景。
- test_tasks:
  - type: unit
    layer: unit
    domain: backend
    description: Kotlin/Dart/Python golden fixture tests 读取新增 auth fixtures
    scenarios: [design-test-5 fixture list]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R001-003, DEC-R001-006]
- blocked_files: []
- 具体改动点：
  - R001-BF002.1 `✅` 新建 `hello-auth-required.json`、`hello-auth-authorized.json`。
  - R001-BF002.2 `✅` 新建 `error-401-authorization-required.json`、`error-401-token-expired.json`、`error-403-authorization-denied.json`。
  - R001-BF002.3 `✅` 新建 `auth-claim-approved.json` 并更新 fixtures README。
- 关键代码片段：
  ```json
  {"ok":false,"code":"authorization_required","message":"Debug authorization is required."}
  ```
- 改动理由/上下文：fixtures 是协议可执行投影，后续实现必须以它们对齐。

## R001-BF003：kotlin Auth types — pure JVM auth model `✅ 已完成`

- 文件：`kotlin/src/main/kotlin/com/pantas/debug/controlplane/DebugAuth.kt`
- 改动类型：新建
- domain: backend
- task_layer: foundation
- depends_on: [R001-BF001, R001-BF002]
- priority: 5
- risk_tags: [kotlin, auth, api]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF001, BF003]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md, .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - 定义 pure JVM `DebugAuthManager`/`DebugAuthDecision`/`DebugAuthRequest`/`DebugAuthTokenRecord`，不依赖 Android 或 Flutter。
  - 默认 no-op auth manager 保持现有裸用行为。
  - token 比对设计支持 hash 存储和过期/撤销状态。
- test_tasks:
  - type: unit
    layer: unit
    domain: android
    description: Kotlin auth model 单元测试覆盖 authorized/required/expired/revoked
    scenarios: [design-test-2 App auth]
- contract_refs: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- decision_refs: [DEC-R001-001, DEC-R001-007]
- blocked_files: []
- 具体改动点：
  - R001-BF003.1 `✅` 新增 sealed result：`Authorized`、`Denied(statusCode, code, message)`。
  - R001-BF003.2 `✅` 新增 route classification：`HELLO_BOOTSTRAP`、`AUTH_BOOTSTRAP`、`SENSITIVE`。
  - R001-BF003.3 `✅` 新增 helper 解析 Bearer header。
- 关键代码片段：
  ```kotlin
  interface DebugAuthManager {
      suspend fun authorize(request: DebugAuthRequest): DebugAuthDecision
      suspend fun helloAuthState(token: String?): Map<String, Any?>
  }
  ```
- 改动理由/上下文：AuthGate 需要跨普通路由和 SSE 共享的纯接口。

## R001-BF004：kotlin ControlPlane — AuthGate and auth routes `✅ 已完成`

- 文件：`kotlin/src/main/kotlin/com/pantas/debug/controlplane/ControlPlane.kt`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R001-BF003]
- priority: 5
- risk_tags: [kotlin, auth, routing]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF001, BF002, BF003]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md, .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - auth enabled 时 `/state` 和 capability routes 在 handler 前短路 401/403。
  - `/hello` 无 token 返回最小 bootstrap，授权后返回完整 hello。
  - `/auth/request/status/claim` 按协议返回 pending/approved/denied/expired/claim。
- test_tasks:
  - type: unit
    layer: unit
    domain: android
    description: ControlPlane auth route 和敏感 route gating 测试
    scenarios: [design-test-2 Kotlin/Dart core]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R001-002, DEC-R001-003, DEC-R001-004, DEC-R001-006, DEC-R001-007]
- blocked_files: []
- 具体改动点：
  - R001-BF004.1 `✅` 构造函数接收可选 `authManager`。
  - R001-BF004.2 `✅` `_handleHello` 按 auth 状态选择 minimal/full payload。
  - R001-BF004.3 `✅` dispatch 前对 sensitive routes 调用 auth manager。
  - R001-BF004.4 `✅` 增加 `/auth/*` system routes。
- 关键代码片段：
  ```kotlin
  if (auth.enabled && isSensitive(req)) {
      when (val d = auth.authorize(req.toAuthRequest())) {
          is Denied -> return RouteResult.error(d.statusCode, d.code, d.message)
      }
  }
  ```
- 改动理由/上下文：普通 HTTP route 的最终授权必须由 App debug plane 判定。

## R001-BF005：kotlin HttpSseTransport — SSE pre-hijack auth `✅ 已完成`

- 文件：`kotlin/src/main/kotlin/com/pantas/debug/controlplane/HttpSseTransport.kt`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R001-BF003, R001-BF004]
- priority: 5
- risk_tags: [kotlin, sse, auth]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF001, BF002]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - `/events` 建连前校验 Bearer token。
  - 鉴权失败返回 JSON 401/403，且不写 SSE `: connected` 首帧。
  - 鉴权失败不增加 subscriber count。
- test_tasks:
  - type: unit
    layer: unit
    domain: android
    description: SSE auth pre-hijack 测试
    scenarios: [design-test-2 Kotlin transport]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R001-005, DEC-R001-006]
- blocked_files: []
- 具体改动点：
  - R001-BF005.1 `✅` transport 可访问 auth checker 或 dispatch 前 preflight handler。
  - R001-BF005.2 `✅` 在 `hijackEvents()` 前短路 unauthorized response。
  - R001-BF005.3 `✅` 保持 authorized 首帧字节契约不变。
- 关键代码片段：
  ```kotlin
  if (method == Method.GET && segments == listOf("events")) {
      auth.preflight(session)?.let { return it.toNanoResponse() }
      return hijackEvents()
  }
  ```
- 改动理由/上下文：`/events` 当前在 transport 层劫持，dispatch 内 gate 会漏掉 SSE。

## R001-BF006：kotlin tests — auth coverage `✅ 已完成`

- 文件：`kotlin/src/test/kotlin/com/pantas/debug/controlplane/*Auth*Test.kt`
- 改动类型：新建
- domain: backend
- task_layer: foundation
- depends_on: [R001-BF003, R001-BF004, R001-BF005]
- priority: 4
- risk_tags: [tests, kotlin, auth]
- smoke_required: true
- mode: direct
- status: completed
- sourceCapabilities: [BF001, BF002, BF003]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md, .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - 覆盖 `/hello` minimal/full、`/state` 401、capability handler 不执行、SSE 未授权不写首帧。
  - 覆盖 auth claim approve/deny/expired/revoked。
  - `./gradlew build` 通过。
- test_tasks:
  - type: unit
    layer: unit
    domain: android
    description: 运行 Kotlin 全量测试
    scenarios: [design-test-3 BF001-BF003]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R001-001, DEC-R001-002, DEC-R001-003, DEC-R001-005, DEC-R001-006]
- blocked_files: []
- 具体改动点：
  - R001-BF006.1 `✅` 新增 fake auth manager 与 fake capability。
  - R001-BF006.2 `✅` 新增 HTTP/SSE auth 测试。
  - R001-BF006.3 `✅` 新增 auth route lifecycle 测试。
- 关键代码片段：
  ```kotlin
  assertEquals(0, transport.subscriberCount())
  assertEquals(401, response.status.requestStatus)
  ```
- 改动理由/上下文：鉴权是安全边界，必须先由单元测试锁定。

## R001-BF007：dart core — auth protocol mirror `✅ 已完成`

- 文件：`dart/lib/src/control_plane.dart` + `dart/lib/src/http_sse_transport.dart`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R001-BF001, R001-BF002]
- priority: 4
- risk_tags: [dart, protocol, auth]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF001, BF002, BF003]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md, .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - Dart core 镜像 Kotlin auth behavior，未启用 auth 时保持现有行为。
  - `/hello` minimal/full、`/auth/*`、sensitive route 401 与 Kotlin 语义一致。
  - `/events` 建连鉴权失败不输出 SSE 首帧。
- test_tasks:
  - type: unit
    layer: unit
    domain: flutter
    description: Dart auth route/transport tests
    scenarios: [design-test-2 Kotlin/Dart core]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R001-003, DEC-R001-004, DEC-R001-005, DEC-R001-006, DEC-R001-007]
- blocked_files: []
- 具体改动点：
  - R001-BF007.1 `✅` 增加 Dart auth abstraction。
  - R001-BF007.2 `✅` 更新 `ControlPlane.dispatch` 和 `/hello`。
  - R001-BF007.3 `✅` 更新 `HttpSseTransport` events preflight。
- 关键代码片段：
  ```dart
  abstract interface class DebugAuthManager {
    Future<AuthDecision> authorize(AuthRequest request);
  }
  ```
- 改动理由/上下文：Dart package 是协议实现之一，不能只改 Kotlin。

## R001-BF008：dart tests — auth golden alignment `✅ 已完成`

- 文件：`dart/test/*auth*_test.dart` + `dart/test/golden_fixture_test.dart`
- 改动类型：新建 / 修改
- domain: backend
- task_layer: foundation
- depends_on: [R001-BF002, R001-BF007]
- priority: 4
- risk_tags: [tests, dart, fixtures]
- smoke_required: true
- mode: direct
- status: completed
- sourceCapabilities: [BF001, BF002]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - Dart tests 覆盖新增 auth fixtures。
  - `cd dart && fvm flutter test` 通过。
  - 未启用 auth 的既有 golden fixture 不变。
- test_tasks:
  - type: unit
    layer: unit
    domain: flutter
    description: 运行 Dart package tests
    scenarios: [design-test-3 BF001-BF002]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R001-003, DEC-R001-006, DEC-R001-007]
- blocked_files: []
- 具体改动点：
  - R001-BF008.1 `✅` 新增 auth fake manager。
  - R001-BF008.2 `✅` 覆盖 hello bootstrap 和 SSE unauthorized。
  - R001-BF008.3 `✅` 更新 golden fixture 测试读取新增 fixtures。
- 关键代码片段：
  ```dart
  expect(body['registeredCapabilities'], isNull);
  expect(response.statusCode, 401);
  ```
- 改动理由/上下文：Dart 侧是跨语言协议守卫的重要消费者。

## R001-FF001：ChannelProtocol — auth method constants `✅ 已实现`

- 文件：`flutter_debug_control_plane/lib/src/channel_protocol.dart` + `flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/ChannelProtocol.kt`
- 改动类型：修改
- domain: ui
- task_layer: foundation
- depends_on: [R001-BF001]
- priority: 4
- risk_tags: [flutter, channel, alignment]
- smoke_required: true
- mode: direct
- status: completed
- sourceCapabilities: [FF001]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - 新增 `auth.request`、`auth.approve`、`auth.deny`、`auth.revoke`、`auth.status` 常量。
  - Dart/Kotlin channel alignment tests 覆盖新增常量。
  - visual-verify 不适用：本任务不提供 UI，仅提供 channel 常量。
- test_tasks:
  - type: unit
    layer: unit
    domain: flutter
    description: Channel protocol alignment tests
    scenarios: [design-test-2 Flutter plugin]
- contract_refs: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- decision_refs: [DEC-R001-002]
- blocked_files: []
- 具体改动点：
  - R001-FF001.1 `✅` 在 Dart/Kotlin 常量文件添加 auth method strings。
  - R001-FF001.2 `✅` 扩展 alignment tests。
- 关键代码片段：
  ```dart
  const kMethodAuthRequest = 'auth.request';
  const kMethodAuthApprove = 'auth.approve';
  ```
- 改动理由/上下文：Flutter auth bridge 必须先有稳定 channel 协议。

## R001-FF002：Flutter Dart API — host auth bridge `✅ 已完成`

- 文件：`flutter_debug_control_plane/lib/src/native_control_plane_bridge.dart`
- 改动类型：修改
- domain: ui
- task_layer: foundation
- depends_on: [R001-FF001]
- priority: 4
- risk_tags: [flutter, dart, auth]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [FF001, BF003]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - Dart API 暴露 auth pending handler 和 approve/deny/revoke/status 方法。
  - auth pending 池不复用 capability invoke 30s timeout 池。
  - 不提供默认 UI，因此 AcceptanceSpec 豁免保持成立。
  - visual-verify 不适用：本任务不提供 UI，仅提供 Flutter Dart host auth bridge API。
- test_tasks:
  - type: unit
    layer: unit
    domain: flutter
    description: Flutter Dart bridge auth API tests
    scenarios: [design-test-2 Flutter plugin]
- contract_refs: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- decision_refs: [DEC-R001-002]
- blocked_files: []
- 具体改动点：
  - R001-FF002.1 `✅` 定义 `DebugAuthRequest`/`DebugAuthStatus` Dart DTO。
  - R001-FF002.2 `✅` 增加 `setAuthorizationHandler` 或等价 API。
  - R001-FF002.3 `✅` 增加 approve/deny/revoke/status MethodChannel 调用。
- 关键代码片段：
  ```dart
  typedef DebugAuthRequestHandler = Future<void> Function(DebugAuthRequest request);
  Future<DebugAuthClaim?> approveAuthorization(String requestId, {Duration? ttl});
  ```
- 改动理由/上下文：宿主 UI 需要语义 API，而不是直接拼 MethodChannel 字符串。

## R001-FF003：Flutter Android plugin — native auth bridge `✅ 已完成`

- 文件：`flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/DebugControlPlaneFlutterPlugin.kt` + `NativeControlPlaneBridge.kt`
- 改动类型：修改
- domain: ui
- task_layer: foundation
- depends_on: [R001-BF003, R001-BF004, R001-FF001, R001-FF002]
- priority: 4
- risk_tags: [flutter, android, auth]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF003, FF001]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - native plugin 能把 pending auth signal 转发到 Dart。
  - approve/deny/revoke/status 能更新 native auth manager。
  - engine detach 时 pending auth 不崩溃，已持久化 token 状态不丢。
  - visual-verify 不适用：本任务不提供 UI，仅提供 Android plugin native auth bridge。
- test_tasks:
  - type: unit
    layer: unit
    domain: android
    description: Flutter plugin Android auth bridge unit tests
    scenarios: [design-test-2 Flutter plugin]
- contract_refs: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- decision_refs: [DEC-R001-002, DEC-R001-007]
- blocked_files: []
- 具体改动点：
  - R001-FF003.1 `✅` 在 plugin method dispatcher 增加 auth methods。
  - R001-FF003.2 `✅` 增加 native auth pending bridge，和 capability pending 分离。
  - R001-FF003.3 `✅` 增加 token store 默认实现或可注入接口。
- 关键代码片段：
  ```kotlin
  fun requestAuthorization(req: DebugAuthRequest) {
      channel.invokeMethod(ChannelProtocol.AUTH_REQUEST, req.toMap())
  }
  ```
- 改动理由/上下文：App 弹窗和 token 私有存储属于 Flutter/plugin/宿主运行时边界。

## R001-BF009：Python BridgeClient — token provider and header injection `✅ 已完成`

- 文件：`python/debug_control_plane/mcp_plane/bridge_client.py`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R001-BF001, R001-BF002]
- priority: 5
- risk_tags: [python, auth, token]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF004]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-python-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - `invoke/read/hello/events` 均从 token provider 读取 token 并注入 Bearer header。
  - token 缺失时不伪造授权，让 App 返回标准 401。
  - `token_expired/token_revoked/invalid_token` 时清理该 device_id token。
  - 不修改 `DevicePool` 持久化 schema。
- test_tasks:
  - type: unit
    layer: unit
    domain: backend
    description: BridgeClient MockTransport auth header and clear-token tests
    scenarios: [design-test-2 Python BridgeClient]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R001-001, DEC-R001-006]
- blocked_files: [python/debug_control_plane/device_discovery/device_pool.py]
- 具体改动点：
  - R001-BF009.1 `✅` 定义 `DebugAuthTokenProvider` Protocol。
  - R001-BF009.2 `✅` 抽出 `_auth_headers(device_id)` 并用于 request/get/stream。
  - R001-BF009.3 `✅` 增加 `DeviceAuthError` 并解析 stable `code`。
  - R001-BF009.4 `✅` 增加 `/auth/request/status/claim` helper。
- 关键代码片段：
  ```python
  class DebugAuthTokenProvider(Protocol):
      def get_token(self, device_id: str) -> str | None: ...
      def save_token(self, device_id: str, token: str, metadata: Mapping[str, Any]) -> None: ...
      def clear_token(self, device_id: str, reason: str) -> None: ...
  ```
- 改动理由/上下文：Python 是 App debug plane client，只携带凭证和处理授权错误。

## R001-BB001：Python MCP server — auth error surfacing `✅ 已完成`

- 文件：`python/debug_control_plane/mcp_plane/server.py` + `capability_mirror.py`
- 改动类型：修改
- domain: backend
- task_layer: business
- depends_on: [R001-BF009]
- priority: 4
- risk_tags: [python, mcp, auth]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BB001, BF004]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-python-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - `_bridge_error_to_mcp` 对 auth error 输出授权/重新授权/拒绝的可操作提示。
  - `list_capabilities` 不把 auth error 静默降级为“没有 capability”。
  - `subscribe_events` 建连 401/403 返回 MCP isError，不崩溃。
- test_tasks:
  - type: unit
    layer: unit
    domain: backend
    description: MCP auth error mapping and CapabilityMirror auth behavior tests
    scenarios: [design-test-2 Python MCP, CapabilityMirror]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R001-006]
- blocked_files: []
- 具体改动点：
  - R001-BB001.1 `✅` 在 `_bridge_error_to_mcp` 增加 `DeviceAuthError` 分支。
  - R001-BB001.2 `✅` 调整 `CapabilityMirror.refresh` 对 auth error 的处理策略。
  - R001-BB001.3 `✅` 增加用户可执行的授权下一步提示。
- 关键代码片段：
  ```python
  if isinstance(exc, DeviceAuthError):
      message = f"debug authorization required for {exc.device_id}: {exc.action_hint}"
  ```
- 改动理由/上下文：Agent 需要知道“去 App 授权”，而不是误以为设备离线。

## R001-BF010：CI integration — full auth regression gate `⬜ 待处理`

- 文件：`ci/ci-check-all.sh` + 相关测试入口
- 改动类型：修改
- domain: integration
- task_layer: foundation
- depends_on: [R001-BF006, R001-BF008, R001-FF003, R001-BB001]
- priority: 5
- risk_tags: [ci, integration, regression]
- smoke_required: true
- mode: direct
- status: pending
- sourceCapabilities: [BF001, BF002, BF003, BF004, BB001, FF001]
- sourceSlices: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-server-slice.md, .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-app-slice.md, .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-python-slice.md]
- sourceDesigns: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md]
- sourceTests: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- acceptance_criteria:
  - `./gradlew build`、Dart tests、Flutter plugin tests、Python pytest 均通过或明确记录环境 blocker。
  - `bash ci/zero-business-dep-check.sh` 不因 auth 改动引入业务依赖。
  - `bash ci/protocol-version-guard.sh` 仍保持 `protocolVersion=1`。
  - `bash ci/ci-check-all.sh` 可作为最终全量门。
- test_tasks:
  - type: integration
    layer: integration
    domain: cross_stack
    description: 运行 R001 全量跨语言回归
    scenarios: [design-test-3 全量, design-test-4 集成测试方案]
    requires: []
- contract_refs: [.dev-flow/R001/analysis/2026-08-20--debug-plane-auth-test.md]
- decision_refs: [DEC-R001-001, DEC-R001-002, DEC-R001-003, DEC-R001-004, DEC-R001-005, DEC-R001-006, DEC-R001-007]
- blocked_files: []
- 具体改动点：
  - R001-BF010.1 `⬜` 确认新增测试已被现有 CI 入口覆盖。
  - R001-BF010.2 `⬜` 如发现遗漏，仅补 CI 调用路径，不改变测试语义。
  - R001-BF010.3 `⬜` 记录最终验证命令和结果。
- 关键代码片段：
  ```bash
  bash ci/ci-check-all.sh
  ```
- 改动理由/上下文：R001 跨语言协议改动必须以全量门收口。
