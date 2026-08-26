---
version: "1.0"
type: tasks
topic: capability-scope-split
requirement_cycle: R003
taskPackageVersion: "1.8"
workflow:
  evaluate_provider: direct_subagent
  mode: auto
status: planned
analysisManifestPath: .dev-flow/R003/analysis/manifest.json
analysisManifestRevision: 4
analysisManifestDigest: caa27b26fb4321f0b0624484af9ab8c8ea949731a900c9cf7489a5e85c849ced
analysisIntegrationPath: .dev-flow/R003/analysis/2026-08-25--capability-scope-split-integration.md
bootstrapLegacy: false
analysisSourceMdPaths:
  - .dev-flow/R003/analysis/manifest.json
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-protocol-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-core-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-flutter-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-python-mcp-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-acceptance-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-integration.md
designMdPaths:
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md
testMdPaths:
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md
contextMdPaths:
  - .dev-flow/architecture.md
  - .dev-flow/R003/analysis/manifest.json
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-protocol-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-core-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-flutter-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-python-mcp-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-acceptance-slice.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-integration.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md
  - .dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md
---

# R003 调试能力应用级/页面级拆分任务清单

全局约束：`protocolVersion=1` 保持不变；`pageId/pageName` 不拼进 capability id 或 MCP tool name；App 端仍是授权与 capability 有效性最终判定方；Python 只转发 selector header 并刷新镜像；Flutter helper 不自动监听 Navigator，不启动或停止 native plane；page capability state 不扁平聚合进 `/state` 或 `/hello` 顶层 state。

执行顺序：R003-BF001 -> R003-BF002 -> R003-BF003；R003-BF004 -> R003-BF005；R003-FF001 -> R003-FF002 -> R003-FB001 -> R003-FB002；R003-BF006 -> R003-BF007；最后 R003-BF008。

## R003-BF001：protocol fixtures — scope schema 与错误契约 `✅ 已完成`

- 文件：`PROTOCOL.md` + `fixtures/hello.json` + `fixtures/hello-page-scope.json` + `fixtures/hello-multi-page-scope.json` + `fixtures/hello-schema-shrink.json` + `fixtures/error-page-capability-gone.json` + `fixtures/error-capability-scope-expired.json`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: []
- priority: 5
- risk_tags: [protocol, compatibility, fixtures]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF001, BF002]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-protocol-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [PROTOCOL 记录 scope/pageId/pageName/scopeRevision 且 protocolVersion 保持 1, fixture 覆盖 app 默认、page、多 page、gone、expired 和 schema-shrink, 旧 hello fixture 仍被 Dart、Kotlin、Python golden 测试接受]
- test_tasks: [{type: unit, layer: unit, domain: backend, description: golden fixture 读取新旧 scope schema, scenarios: [Protocol fixture, Dart core, Kotlin core, Python mirror]}]
- contract_refs: [PROTOCOL.md, fixtures/README.md]
- decision_refs: [DEC-R003-001, DEC-R003-003, DEC-R003-005]
- blocked_files: []
- 具体改动点：R003-BF001.1 `✅` PROTOCOL 补 scope 字段；R003-BF001.2 `✅` 定义 `page_capability_gone`/`capability_scope_expired`；R003-BF001.3 `✅` 新增 app/page/multi-page/schema-shrink fixture。
- 关键代码片段：`{"id":"sample.page.panel","scope":"page","pageId":"page-a","pageName":"Page A","scopeRevision":2}`
- 改动理由/上下文：协议和 fixture 是四端字段对齐的真相源。

## R003-BF002：dart capability model — CapabilityScope 数据结构 `✅ 已完成`

- 文件：`dart/lib/src/capability.dart` + `dart/lib/debug_control_plane.dart` + `dart/test/capability_scope_test.dart`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R003-BF001]
- priority: 5
- risk_tags: [dart, api, compatibility]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF001, BF003]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-core-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [旧 Capability 实现无需改代码也默认 scope=app, page scope 缺 pageId 时注册前明确拒绝, 公共导出包含 CapabilityScope 类型]
- test_tasks: [{type: unit, layer: unit, domain: flutter, description: Dart scope 默认值、pageId 校验、导出测试, scenarios: [Dart core registry]}]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R003-001, DEC-R003-002]
- blocked_files: []
- 具体改动点：R003-BF002.1 `✅` 新增 `CapabilityScopeType/CapabilityScope`；R003-BF002.2 `✅` `Capability.scope` 默认 app；R003-BF002.3 `✅` public entrypoint 导出 scope 类型。
- 关键代码片段：`extension CapabilityScopeDefault on Capability { CapabilityScope get scope => const CapabilityScope.app(); }`
- 改动理由/上下文：先定义 Dart core、Flutter bridge 和测试共用的 scope identity。

## R003-BF003：dart control plane — scoped registry 与 dispatch `✅ 已完成`

- 文件：`dart/lib/src/control_plane.dart` + `dart/test/control_plane_test.dart` + `dart/test/golden_fixture_test.dart`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R003-BF002]
- priority: 5
- risk_tags: [dart, registry, routing, auth]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF002, BF003, BF004]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-core-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [registry key 使用 scope/pageId/capabilityId 并允许不同 pageId 同 id 并存, selector header 命中目标 page capability 且 gone=410 expired=409, /state 和 /hello 顶层 state 只聚合 app 且 auth gate 优先]
- test_tasks: [{type: unit, layer: unit, domain: flutter, description: Dart scoped registry、dispatch、state 聚合、auth 边界测试, scenarios: [Dart core registry, Dart core dispatch]}]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R003-002, DEC-R003-003, DEC-R003-004, DEC-R003-005]
- blocked_files: []
- 具体改动点：R003-BF003.1 `✅` 新增 `ScopedCapabilityKey`；R003-BF003.2 `✅` register/unregister 保留旧签名并新增 scoped unregister；R003-BF003.3 `✅` dispatch 读取 `X-DCP-*` selector；R003-BF003.4 `✅` hello 输出 scope metadata 和 changed 事件。
- 关键代码片段：`void unregisterScoped({required CapabilityScope scope, required String capabilityId});`
- 改动理由/上下文：Dart core 是协议行为参考实现。

## R003-BF004：kotlin capability model — scope 模型对齐 Dart `✅ 已完成`

- 文件：`kotlin/src/main/kotlin/com/pantas/debug/controlplane/Capability.kt` + `kotlin/src/test/kotlin/com/pantas/debug/controlplane/GoldenFixtureTest.kt`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R003-BF001]
- priority: 5
- risk_tags: [kotlin, api, compatibility]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF001, BF003]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-core-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [Kotlin Capability 默认 scope=app 且不破坏现有测试 double, page scope 缺 pageId 有明确参数校验, golden fixture 与 Dart/Python 字段名保持一致]
- test_tasks: [{type: unit, layer: unit, domain: android, description: Kotlin scope model、默认 app、fixture 字段解析, scenarios: [Kotlin core hello/state/events]}]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R003-001, DEC-R003-002]
- blocked_files: []
- 具体改动点：R003-BF004.1 `✅` 新增 `CapabilityScopeType/CapabilityScope`；R003-BF004.2 `✅` `Capability` 增加默认 scope；R003-BF004.3 `✅` 测试 fakes 覆盖 app/page。
- 关键代码片段：`data class CapabilityScope(val type: CapabilityScopeType = APP, val pageId: String? = null, val pageName: String? = null, val revision: Long? = null)`
- 改动理由/上下文：Android native plugin 走 Kotlin core，模型必须同形。

## R003-BF005：kotlin control plane — scoped registry 与状态事件 `✅ 已完成`

- 文件：`kotlin/src/main/kotlin/com/pantas/debug/controlplane/ControlPlane.kt` + `kotlin/src/test/kotlin/com/pantas/debug/controlplane/ControlPlaneTest.kt` + `kotlin/src/test/kotlin/com/pantas/debug/controlplane/SseAndRoutingIntegrationTest.kt`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R003-BF004]
- priority: 5
- risk_tags: [kotlin, routing, lifecycle, auth]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF002, BF003, BF004]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-core-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [Kotlin registry 支持多 page scope 并存和 scoped unregister 不误删, selector dispatch/gone/expired/auth 优先级与 Dart 对齐, unregister 后 event subscription 取消且 hello/state 符合 R003 fixture]
- test_tasks: [{type: unit, layer: unit, domain: android, description: Kotlin scoped registry、selector dispatch、SSE cleanup, scenarios: [Kotlin core hello/state/events, Dart core dispatch]}]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R003-002, DEC-R003-003, DEC-R003-004, DEC-R003-005]
- blocked_files: []
- 具体改动点：R003-BF005.1 `✅` `_capabilities/_eventSubscriptions` 改为 scoped key；R003-BF005.2 `✅` hello 聚合 scope metadata，state 只聚合 app；R003-BF005.3 `✅` sensitive route 授权通过后 scoped match。
- 关键代码片段：`data class ScopedCapabilityKey(val scope: CapabilityScopeType, val pageId: String?, val capabilityId: String)`
- 改动理由/上下文：Kotlin core 是 Android 真机链路的执行端。

## R003-FF001：flutter bridge — MethodChannel 透传 scope identity `✅ 已完成`

- 文件：`flutter_debug_control_plane/lib/src/bridge_capability.dart` + `flutter_debug_control_plane/lib/src/native_control_plane_bridge.dart` + `flutter_debug_control_plane/test/native_control_plane_bridge_test.dart`
- 改动类型：修改
- domain: ui
- task_layer: foundation
- depends_on: [R003-BF002]
- priority: 4
- risk_tags: [flutter, methodchannel, compatibility]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [FF001]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-flutter-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [register/unregister/events/state/reverse invoke payload 保留 scope/pageId/capId identity, 旧 app capability 调用路径和重复注册行为保持兼容, 实现 5 个稳定标识（acceptance.page_scope.* 清单见 AcceptanceSpec）, visual-verify PASS（三层证据对照 AcceptanceSpec）, visual baseline deferred: Android 真机 390x844 采集，deferred_reason=device_required]
- test_tasks: [{type: unit, layer: unit, domain: flutter, description: Flutter bridge channel payload 透传 scope identity, scenarios: [Flutter bridge channel payload]}]
- contract_refs: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-acceptance-spec.yaml]
- decision_refs: [DEC-R003-002, DEC-R003-006]
- blocked_files: []
- 具体改动点：R003-FF001.1 `✅` `BridgeCapability` 暴露 inner scope；R003-FF001.2 `✅` channel payload 增加 scope；R003-FF001.3 `✅` reverse invoke 按 scope-aware local key 查 handler。
- 关键代码片段：`Future<void> register(BridgeCapability cap, {CapabilityScope scope = const CapabilityScope.app()});`
- 改动理由/上下文：Flutter Dart 侧必须把页面 identity 传给 native。

## R003-FF002：android plugin bridge — native registry 解析 scope payload `✅ 已完成`

- 文件：`flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/DartCapabilityRegistry.kt` + `flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/DebugControlPlaneFlutterPlugin.kt` + `flutter_debug_control_plane/android/src/test/kotlin/com/pantas/debug/controlplane/flutter/DartCapabilityRegistryTest.kt` + `flutter_debug_control_plane/android/src/test/kotlin/com/pantas/debug/controlplane/flutter/DebugControlPlaneFlutterPluginTest.kt`
- 改动类型：修改
- domain: ui
- task_layer: foundation
- depends_on: [R003-BF005, R003-FF001]
- priority: 4
- risk_tags: [android, flutter-plugin, methodchannel]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [FF001, BF004]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-flutter-slice.md, .dev-flow/R003/analysis/2026-08-25--capability-scope-split-core-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [Android plugin 解析 scope/pageId/pageName 并拒绝无 pageId 的 page payload, DartCapabilityRegistry 保存 scoped BridgeCapability 且 unregister 不误删其它 page, 实现 5 个稳定标识（acceptance.page_scope.* 清单见 AcceptanceSpec）, visual-verify PASS（三层证据对照 AcceptanceSpec）, visual baseline deferred: Android 真机执行采集，deferred_reason=device_required]
- test_tasks: [{type: unit, layer: unit, domain: android, description: Android plugin scope payload、registry key、duplicate identity 测试, scenarios: [Flutter bridge channel payload, Flutter helper/example]}]
- contract_refs: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-acceptance-spec.yaml]
- decision_refs: [DEC-R003-002, DEC-R003-006]
- blocked_files: []
- 具体改动点：R003-FF002.1 `✅` `parseDecl` 读取 scope metadata；R003-FF002.2 `✅` registry map 升级为 scoped identity；R003-FF002.3 `✅` teardown 支持 page scoped cleanup。
- 关键代码片段：`data class BridgeCapabilityIdentity(val scope: CapabilityScope, val capId: String)`
- 改动理由/上下文：Android plugin 是 Flutter helper 到 Kotlin core 的桥。

## R003-FB001：page helper — PageCapabilityScope 生命周期注册器 `✅ 已完成`

- 文件：`flutter_debug_control_plane/lib/src/page_capability_scope.dart` + `flutter_debug_control_plane/lib/flutter_debug_control_plane.dart` + `flutter_debug_control_plane/test/page_capability_scope_test.dart`
- 改动类型：新建
- domain: ui
- task_layer: business
- depends_on: [R003-FF001]
- priority: 4
- risk_tags: [flutter, lifecycle, helper]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [FB001, FF001]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-flutter-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [helper 用业务传入 pageId/pageName 注册 page capability 且 dispose scoped unregister, 多个 pageId 同时 active 互不影响且重复 dispose 为 no-op, 实现 5 个稳定标识（acceptance.page_scope.* 清单见 AcceptanceSpec）, visual-verify PASS（三层证据对照 AcceptanceSpec）, visual baseline deferred: Android 真机执行采集，deferred_reason=device_required]
- test_tasks: [{type: unit, layer: unit, domain: flutter, description: fake bridge 验证 PageCapabilityScope register/unregister payload, scenarios: [Flutter helper/example, page_register_on_open, page_unregister_on_close]}]
- contract_refs: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-acceptance-spec.yaml]
- decision_refs: [DEC-R003-006]
- blocked_files: []
- 具体改动点：R003-FB001.1 `✅` 新建 registration/helper；R003-FB001.2 `✅` 维护本 page capId 列表并 dispose 清理；R003-FB001.3 `✅` public library 导出 helper。
- 关键代码片段：`final class PageCapabilityScope { Future<void> registerAll(List<BridgeCapability> capabilities); Future<void> dispose(); }`
- 改动理由/上下文：业务接入不应手拼 MethodChannel payload。

## R003-FB002：example page demo — 页面级 capability 验收入口 `✅ 已完成`

- 文件：`flutter_debug_control_plane/example/lib/main.dart` + `flutter_debug_control_plane/test/page_capability_scope_example_test.dart`
- 改动类型：修改
- domain: ui
- task_layer: business
- depends_on: [R003-FB001, R003-FF002]
- priority: 3
- risk_tags: [flutter, example, android]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [FB001, BF008]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-flutter-slice.md, .dev-flow/R003/analysis/2026-08-25--capability-scope-split-acceptance-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [example 可进入 page A/page B demo 并显示 pageId 与 active page capability 数量, 离开 page A 后 app capability 与 page B capability 保持可用, 实现 5 个稳定标识（acceptance.page_scope.* 清单见 AcceptanceSpec）, visual-verify PASS（三层证据对照 AcceptanceSpec）, visual baseline deferred: Android 真机页面截图采集，deferred_reason=device_required]
- test_tasks: [{type: unit, layer: unit, domain: flutter, description: example demo widget/controller 覆盖稳定标识, scenarios: [Flutter helper/example, Android integration]}, {type: integration, layer: integration, domain: android, description: 真机验证 page A/page B lifecycle, scenarios: [Android integration, page_register_on_open, page_unregister_on_close], deferred: true, deferred_reason: device_required}]
- contract_refs: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-acceptance-spec.yaml]
- decision_refs: [DEC-R003-006]
- blocked_files: []
- 具体改动点：R003-FB002.1 `✅` example 添加 page scope demo 入口和稳定标识；R003-FB002.2 `✅` 注册 `sample.page.panel/form`；R003-FB002.3 `✅` 离开页面触发 dispose 并展示状态。
- 关键代码片段：`const pageAId = 'page-a'; const pageBId = 'page-b';`
- 改动理由/上下文：example 是业务接入参考和真机验收入口。

## R003-BF006：python mirror — CapabilitySchema scope 解析与 diff `✅ 已完成`

- 文件：`python/debug_control_plane/mcp_plane/capability_mirror.py` + `python/tests/test_capability_mirror.py`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R003-BF001]
- priority: 4
- risk_tags: [python, mcp, schema]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF005]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-python-mcp-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [CapabilitySchema 保留 scope/page_id/page_name/scope_revision 且旧 schema 默认 app, schema grow/shrink、pageName 变化、page unregister 均返回 changed, malformed scope 不导致离线误判或清空为 no caps]
- test_tasks: [{type: unit, layer: unit, domain: backend, description: Python mirror scope parse/diff/stale cache 测试, scenarios: [Python mirror schema parse/diff]}]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R003-001, DEC-R003-007]
- blocked_files: []
- 具体改动点：R003-BF006.1 `✅` 扩展 `CapabilitySchema`；R003-BF006.2 `✅` `_parse_one` 解析 scope metadata；R003-BF006.3 `✅` static meta tools schema 增加可选 selector 参数。
- 关键代码片段：`CapabilitySchema(capability_id: str, scope: str = "app", page_id: str | None = None, scope_revision: int | None = None)`
- 改动理由/上下文：MCP 工具暴露以 Python mirror cache 为准。

## R003-BF007：python bridge/server — selector header 与 stale tool 收敛 `✅ 已完成`

- 文件：`python/debug_control_plane/mcp_plane/bridge_client.py` + `python/debug_control_plane/mcp_plane/server.py` + `python/tests/test_bridge_client.py` + `python/tests/test_server.py`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R003-BF006, R003-BF003, R003-BF005]
- priority: 4
- risk_tags: [python, mcp, bridge, stale]
- smoke_required: true
- mode: negotiated
- status: completed
- sourceCapabilities: [BF002, BF006]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-python-mcp-slice.md, .dev-flow/R003/analysis/2026-08-25--capability-scope-split-core-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [invoke_command/read_resource 可选 scope/page_id/scope_revision 并发送 X-DCP selector headers, App 返回 gone/expired 后 mirror 标记 stale 并刷新工具列表, Bearer token header 保持原路径且 auth error 不改写成 page gone]
- test_tasks: [{type: unit, layer: unit, domain: backend, description: BridgeClient selector header、McpServer stale refresh 测试, scenarios: [Python MCP server meta tools, Python mirror stale/offline]}]
- contract_refs: [PROTOCOL.md]
- decision_refs: [DEC-R003-003, DEC-R003-005, DEC-R003-007]
- blocked_files: []
- 具体改动点：R003-BF007.1 `✅` `BridgeClient.invoke/read` 增加 selector 参数并合并 headers；R003-BF007.2 `✅` server meta tool 校验并转发 selector；R003-BF007.3 `✅` gone/expired 后 refresh 并发送 list_changed。
- 关键代码片段：`def selector_headers(*, capability_id: str, scope: str | None, page_id: str | None, scope_revision: int | None) -> dict[str, str]: ...`
- 改动理由/上下文：agent 仍调用 MCP 工具，页面命中依赖 Python selector header。

## R003-BF008：acceptance regression — 跨语言与 Android 真机验收 `⬜ 待处理`

- 文件：`ci/ci-check-all.sh` + `.dev-flow/R003/test-overrides/R003-BF008/integration-android.sh` + `.dev-flow/R003/evidence/android-page-scope.md`
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: [R003-BF003, R003-BF005, R003-FF002, R003-FB002, R003-BF007]
- priority: 5
- risk_tags: [integration, android, cross-stack, device]
- smoke_required: true
- mode: negotiated
- status: pending
- sourceCapabilities: [BF007, BF008]
- sourceSlices: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-acceptance-slice.md]
- sourceDesigns: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-design.md]
- sourceTests: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-test.md]
- acceptance_criteria: [ci-check-all 覆盖可自动运行的 Dart、Kotlin、Flutter、Python scope 回归, Android 真机 evidence 记录 page A、page B、离开 page A 三阶段 hello/tool 变化, 页面 A gone 后旧工具失败并刷新且 app/page B capability 仍可用]
- test_tasks: [{type: integration, layer: integration, domain: cross_stack, description: 自动跨语言回归入口运行 R003 scope 测试, scenarios: [BF007 自动化跨语言回归]}, {type: integration, layer: integration, domain: android, description: Android 真机页面能力验收，需用户授权安装或已授权设备, scenarios: [BF008 Android 真机页面能力验收], deferred: true, deferred_reason: device_required}]
- contract_refs: [.dev-flow/R003/analysis/2026-08-25--capability-scope-split-acceptance-spec.yaml]
- decision_refs: [DEC-R003-001, DEC-R003-002, DEC-R003-003, DEC-R003-004, DEC-R003-005, DEC-R003-006, DEC-R003-007]
- blocked_files: []
- 具体改动点：R003-BF008.1 `⬜` R003 自动测试纳入 cross-stack 命令或 test override；R003-BF008.2 `⬜` 增加 Android 真机 page scope 验收脚本和 evidence 输出；R003-BF008.3 `⬜` 记录不可自动化部分 `deferred_reason=device_required`。
- 关键代码片段：`cd dart && fvm flutter test; ./gradlew build; cd flutter_debug_control_plane && fvm flutter test; cd python && ${PYTHON_BIN:-python3} -m pytest tests -q --no-header`
- 改动理由/上下文：R003 触达四端，最终风险在字段漂移和 Android 页面生命周期链路。
