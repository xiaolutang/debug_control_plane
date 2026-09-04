---
version: "1.0"
type: tasks
topic: android-plugin-auth-policy
requirement_cycle: R006
taskPackageVersion: "1.8"
workflow:
  evaluate_provider: direct_subagent
  mode: auto
status: planned
analysisManifestPath: .dev-flow/R006/analysis/manifest.json
analysisManifestRevision: 1
analysisManifestDigest: f532ccf54cd4e37db2585f12b9477cc8eb55dcc8df98c6ede64d27eb19921b7a
analysisIntegrationPath: .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-integration.md
bootstrapLegacy: false
analysisSourceMdPaths:
  - .dev-flow/R006/analysis/manifest.json
  - .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy.md
  - .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-integration.md
designMdPaths:
  - .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-design.md
testMdPaths:
  - .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-test.md
contextMdPaths:
  - .dev-flow/architecture.md
  - .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy.md
  - .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-integration.md
  - .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-design.md
  - .dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-test.md
---

# R006 Android 插件授权策略装配 API 任务清单

全局约束：`/auth/*` 与 `/hello` wire 契约零改动（PROTOCOL.md 冻结；`none` 下 `/hello` 无 `authRequired` 是 core null 放行既有语义，非 wire 变更）；channel 参数 `authPolicy` 可选、缺席=现状（0.5.1 逐字节兼容）；非法策略值 fail-fast（Dart `ArgumentError` / Kotlin `invalid_arguments`）不静默回退；kotlin core / dart core / python / 纯 Dart 宿主路径 / example 既有授权 UI 链全部零改动；`design.md`「暂不实现」清单（python mcp_plane 自动编排、运行时动态切换、纯 Dart 宿主 AuthPolicy 导出、iOS 专属处理）不得进入任务；PluginDebugAuthManager 既有构造参数零破坏（`autoApprove` 带默认值追加）。

执行顺序：R006-BF001（Kotlin 装配层，含 JVM 单测）→ R006-FF001（Dart API 面 + 文档，依赖 BF001 channel 契约对齐）→ R006-BF002（跨栈 e2e，依赖前两者）。

## R006-BF001：插件 Kotlin 装配层 — authPolicy 通道 + 三策略装配 + fail-fast + JVM 单测 `✅ 已完成 (723f85e)`

- 文件：`flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/ChannelProtocol.kt`（修改）+ `.../PluginDebugAuth.kt`（修改）+ `.../DebugControlPlaneFlutterPlugin.kt`（修改）+ `flutter_debug_control_plane/android/src/test/kotlin/com/pantas/debug/controlplane/flutter/PluginAuthPolicyTest.kt`（新建）
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: []
- priority: 5
- risk_tags: [kotlin, channel-protocol, auth, assembly]
- smoke_required: true
- mode: direct
- status: pending
- sourceCapabilities: [BF001]
- sourceSlices: [S01-plugin-auth-policy]
- sourceDesigns: [.dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-design.md]
- sourceTests: [.dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-test.md]
- acceptance_criteria: [ChannelProtocol 新增 AUTH_POLICY 参数名常量与 AUTH_POLICY_DEFAULT/AUTO/NONE 三 wire 值常量且不破坏既有常量表, PluginDebugAuthManager 构造追加 autoApprove: Boolean = false 默认值既有调用点零改动, autoApprove=true 时 requestAuthorization 在 pending 落库后返回 202 前调用既有 approve 路径即响应体 status=approved 且宿主通知 bridge.requestAuthorization 仍发出, autoApprove=false 行为与现状逐字段一致(K7 对照), ensurePlane 接收 authPolicy 并三分支装配 default-auto 传 PluginDebugAuthManager(autoApprove=对应值) none 传 authManager=null 给 PlaneCarrier.mount, 非法策略字符串返回 invalid_arguments error 且 PlaneCarrier 未 mount plane 不启动, PLANE_START handler 读取可选 authPolicy 参数缺席走 default 分支, K1-K8 JVM 单测全绿, 既有 android JVM 测试全部零回归]
- test_tasks: [{type: unit, layer: unit, domain: backend, description: BF001 三策略装配 + autoApprove 行为 JVM 单测(test.md K1-K8), scenarios: [no-policy-default-assembly, explicit-default-same, auto-approves-instantly, none-mounts-null, bogus-fails-fast-unmounted, auto-request-returns-approved-and-notifies, pending-control-group, auto-claim-bearer-chain]}]
- contract_refs: []
- decision_refs: [D2, D3, D4, D5]
- blocked_files: [flutter_debug_control_plane/lib/, kotlin/src/, dart/lib/, python/, PROTOCOL.md, flutter_debug_control_plane/example/]
- 具体改动点：R006-BF001.1 `ChannelProtocol.kt`：`AUTH_POLICY` 参数名 + `AUTH_POLICY_DEFAULT/AUTO/NONE` wire 值 + `ERROR_INVALID_ARGUMENTS` code；R006-BF001.2 `PluginDebugAuth.kt`：构造追加 `autoApprove: Boolean = false`，`requestAuthorization` pending 落库后按标志走 `approve(pending.requestId, ttlSeconds = null, clientLabel = pending.clientLabel)`（复用既有签发，新分支仅在落库后返回前插入）；R006-BF001.3 `DebugControlPlaneFlutterPlugin.kt`：`PLANE_START` handler 读 `call.argument<String>("authPolicy")` → `ensurePlane` 加 `authPolicy: String?` 参数三分支装配 → 非法值 `result.error(ERROR_INVALID_ARGUMENTS, ...)` 且不 mount；R006-BF001.4 新建 `PluginAuthPolicyTest.kt`（K1-K8）。
- 关键代码片段：
  ```kotlin
  // ChannelProtocol.kt
  const val AUTH_POLICY = "authPolicy"            // plane.start 可选参数名
  const val AUTH_POLICY_DEFAULT = "default"
  const val AUTH_POLICY_AUTO = "auto"
  const val AUTH_POLICY_NONE = "none"
  const val ERROR_INVALID_ARGUMENTS = "invalid_arguments"
  val AUTH_POLICY_VALUES = setOf(AUTH_POLICY_DEFAULT, AUTH_POLICY_AUTO, AUTH_POLICY_NONE)

  // PluginDebugAuth.kt — requestAuthorization 尾部（落库后、return 前）:
  bridge.requestAuthorization(pending.toWireStatus())        // 审计通知永远发（D4）
  if (autoApprove) {                                          // 单条件即可（plan-review L3：status 在此插入点恒 pending）
      approve(pending.requestId, ttlSeconds = null, clientLabel = pending.clientLabel)
      return DebugAuthRouteResult.Ok(store.pending(pending.requestId)!!.toRouteStatus(), statusCode = 202)
  }
  return DebugAuthRouteResult.Ok(pending.toRouteStatus(), statusCode = 202)

  // DebugControlPlaneFlutterPlugin.kt — PLANE_START handler:
  val authPolicy = call.argument<String>("authPolicy") ?: ChannelProtocol.AUTH_POLICY_DEFAULT
  if (authPolicy !in ChannelProtocol.AUTH_POLICY_VALUES) {
      result.error(ChannelProtocol.ERROR_INVALID_ARGUMENTS, "unknown authPolicy: $authPolicy", null); return
  }
  val plane = ensurePlane(pluginScope, port, appMeta, authPolicy)

  // ensurePlane 尾部（fallback self-mount 分支）:
  val manager = when (authPolicy) {
      ChannelProtocol.AUTH_POLICY_NONE -> null
      else -> authManager?.let { /* default/auto 复用 attach 时创建的 manager；auto 需重建带 autoApprove=true */ }
  }
  PlaneCarrier.mount(transport, pluginScope, manager) { appMeta ?: emptyMap() }
  ```
- 改动理由/上下文：autoApprove 注入点=既有 `requestAuthorization` 落库→202 返回缝隙（design §4.3）；fail-fast 在 handler 层拦在 mount 之前（plane 不启动不静默回退，D5）；ChannelProtocol 双端逐字对齐由既有 ChannelProtocolAlignmentTest 守护。

## R006-FF001：Dart API 面 — AuthPolicy 类型 + start 透传 + 序列化单测 + 接入文档 `✅ 已完成 (0b6963c)`

- 文件：`flutter_debug_control_plane/lib/src/auth_policy.dart`（新建）+ `.../channel_protocol.dart`（修改，追加常量）+ `.../native_control_plane_bridge.dart`（修改，start 加参数）+ `flutter_debug_control_plane/lib/flutter_debug_control_plane.dart`（修改，export）+ `flutter_debug_control_plane/test/auth_policy_test.dart`（新建）+ `flutter_debug_control_plane/README.md` + `GETTING_STARTED.md`（修改，接入文档）
- 改动类型：新建 + 修改
- domain: frontend
- task_layer: foundation
- depends_on: [R006-BF001]
- priority: 4
- risk_tags: [dart, api-surface, serialization, docs]
- smoke_required: true
- mode: direct
- status: pending
- sourceCapabilities: [FF001]
- sourceSlices: [S01-plugin-auth-policy]
- sourceDesigns: [.dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-design.md]
- sourceTests: [.dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-test.md]
- acceptance_criteria: [AuthPolicy enum 三值 defaultPolicy/auto/none 且 wireName 映射 default/auto/none, start() 追加可选参数 AuthPolicy? authPolicy 不传时 channel 参数表不含 authPolicy 字段(字节兼容 0.5.1), 传值时参数表含 authPolicy=对应小写字符串, fromWire(null) 返回 defaultPolicy, enum 构造封闭类型系统保证非法值不可构造(测试断言 ArgumentError 路径), channel_protocol.dart 常量与 ChannelProtocol.kt 逐字对齐(既有 alignment test 扩展), 包导出 AuthPolicy, README/GETTING_STARTED 新增授权策略接入节含三策略表与 auto/none 示例, T1-T4 单测全绿, 既有 flutter 包 dart test 全部零回归]
- test_tasks: [{type: unit, layer: unit, domain: frontend, description: FF001 序列化与参数透传单测(test.md T1-T4), scenarios: [wire-name-mapping, absent-param-byte-compat, present-param-serialized, fromWire-null-default]}]
- contract_refs: []
- decision_refs: [D1, D7]
- blocked_files: [flutter_debug_control_plane/android/, kotlin/src/, dart/lib/, python/, PROTOCOL.md, flutter_debug_control_plane/example/lib/]
- 具体改动点：R006-FF001.1 新建 `auth_policy.dart`（enum + wireName + fromWire）；R006-FF001.2 `channel_protocol.dart` 追加 `kAuthPolicyArgName/kAuthPolicyDefault/Auto/None` 常量；R006-FF001.3 `native_control_plane_bridge.dart` `start()` 加 `AuthPolicy? authPolicy`（null 不进参数表）；R006-FF001.4 export + README/GETTING_STARTED 文档节；R006-FF001.5 新建 `auth_policy_test.dart`（T1-T4）。
- 关键代码片段：
  ```dart
  /// lib/src/auth_policy.dart
  enum AuthPolicy {
    defaultPolicy('default'),   // Dart 保留字回避（design D7）
    auto('auto'),
    none('none');

    const AuthPolicy(this.wireName);
    final String wireName;

    /// channel 缺席语义：null → defaultPolicy（向后兼容 0.5.1）。
    static AuthPolicy fromWire(String? wire) =>
        switch (wire) {
          null || 'default' => AuthPolicy.defaultPolicy,
          'auto' => AuthPolicy.auto,
          'none' => AuthPolicy.none,
          _ => throw ArgumentError.value(wire, 'authPolicy', 'unknown authPolicy wire value'),
        };
  }

  // native_control_plane_bridge.dart — start():
  Future<Uri?> start({
    required Object address,
    required int port,
    Map<String, Object?> Function()? appMeta,
    AuthPolicy? authPolicy,                       // ← 新增（null 不进参数表）
  }) async {
    final raw = await _channel.invokeMethod<dynamic>(kMethodPlaneStart, {
      'address': '$address',
      'port': port,
      if (appMeta != null) 'appMeta': appMeta(),
      if (authPolicy != null) 'authPolicy': authPolicy.wireName,
    });
    ...
  }
  ```
- 改动理由/上下文：参数可选缺席=现状是全链向后兼容的锚点（AC1）；`defaultPolicy` 命名避 Dart 保留字而 wire 层仍用 `"default"`（D7 两层显式映射）；文档是 FF001 编号成立的组成部分（授权策略从实现细节变显式装配声明）。

## R006-BF002：跨栈验证 — 真机 e2e auto/none 策略 6 用例 + deferred 契约 `✅ 已完成`

- 文件：`.dev-flow/R006/test-overrides/R006-BF002/integration-android.sh`（新建驱动，fork 自 R004-BF002）+ `.dev-flow/R006/test-overrides/R006-BF002/auth-policy-e2e.py`（新建断言脚本）+ `.dev-flow/R006/evidence/`（evidence 双写）
- 改动类型：新建
- domain: integration
- task_layer: acceptance
- depends_on: [R006-BF001, R006-FF001]
- priority: 3
- risk_tags: [android-device, integration, cross-stack, deferred]
- smoke_required: false
- mode: direct
- status: pending
- sourceCapabilities: [BF002]
- sourceSlices: [S01-plugin-auth-policy]
- sourceDesigns: [.dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-design.md]
- sourceTests: [.dev-flow/R006/analysis/2026-09-04--android-plugin-auth-policy-test.md]
- acceptance_criteria: [驱动脚本完成设备检测构建安装启动与 endpoint 发现复用 R004 模式含策略切换参数, E1 auto 策略 python 编排 401-request-claim 全程无人工审批 claim 200 得 token, E2 E1 后 Bearer 直连敏感路由 200, E3 冷重启后旧 Bearer 200 authorized(R004 持久化在 auto 下照常), E4 none 策略无 token 请求敏感路由 200 且 /hello 响应无 authRequired 字段(两宿主同构主断言), E5 非法策略值经 channel 直调返回 invalid_arguments 且 plane 未启动, E6 default 不传回归既有验收集全绿, deferred 契约真机不在场 evidence 双写 status deferred deferred_reason device_required 后 exit 0(R003/R004/R005 模式), python pytest 全量零回归]
- test_tasks: [{type: integration, layer: integration, domain: cross_stack, description: 真机 auto/none 策略 6 用例(test.md E1-E6), scenarios: [auto-direct-chain, bearer-sensitive-200, cold-restart-persist, none-no-auth-required, invalid-policy-fail-fast, default-regression], requires: [android_device, flutter_built]}]
- contract_refs: []
- decision_refs: [D6]
- blocked_files: [flutter_debug_control_plane/lib/, flutter_debug_control_plane/android/src/main/, kotlin/src/, python/debug_control_plane/, dart/lib/]
- 具体改动点：R006-BF002.1 驱动脚本 fork R004-BF002 `integration-android.sh`（设备检测/构建/install -r/APK_ALREADY_INSTALLED 快速路径/HyperOS 弹窗提示/deferred 双写全沿用），加 `AUTH_POLICY` 环境变量策略注入与切 profile 重装机制；R006-BF002.2 断言脚本 `auth-policy-e2e.py`（纯标准库 urllib，E1-E6）；R006-BF002.3 执行 + evidence 双写（R006-BF002-integration-android-test.log / R006-BF002-integration-cross_stack-test.log）。
- 关键代码片段：
  ```python
  # E1 auto 策略授权链（python 编排，纯 urllib，不动 mcp_plane 库——D6）:
  #   1. GET /debug/...（无 token）→ assert 401, code == "authorization_required"
  #   2. POST /auth/request {"clientNonce": ..., "clientLabel": "r006-e1"}
  #      → assert 202, body["status"] == "approved"          ← auto 即时批准主断言
  #   3. POST /auth/claim {requestId, clientNonce} → assert 200, body["token"]
  # E4 none 策略同构断言:
  #   r = GET /hello  → assert 200
  #   assert "authRequired" not in r.json()                    ← core null 放行语义
  #   GET /debug/...（无 token）→ assert 200                  ← 无门直连
  # E5: driver 以 --dart-define=AUTH_POLICY=bogus 启动 → 通道返回
  #     PlatformException(invalid_arguments) → app 侧断言 plane 未启动
  ```
- 改动理由/上下文：python 编排归 e2e 脚手架而非 mcp_plane 库（D6 吸收 W1）；真机 23116PN5BC 不在场走 deferred（R003/R004/R005 已建立契约，evidence 双写 device_required 后 exit 0 不算失败）。E5 plane 未启动的宿主可见信号：driver 侧捕获 `PlatformException(invalid_arguments)` 后打印 `r006-e5: plane-not-started` 标记行，python 以 endpoint 不可达 + 该标记行双断言（plan-review L2 吸收）；e2e 产物不入 example 树（plan-review W1 吸收，design §3.1 已同步修正）。

## 决策记录

- DEC-R006-001（=design D1/D7）：三值 enum `AuthPolicy{defaultPolicy, auto, none}`，wire 层小写字符串 `"default"/"auto"/"none"`；参数可选缺席=现状。
- DEC-R006-002（=design D2）：auto 审批在 Kotlin 侧 `PluginDebugAuthManager(autoApprove=true)`，Dart/宿主零轮询代码。
- DEC-R006-003（=design D3）：不做 dev-only 门禁；显式声明即审计点（吸收 review W2）。
- DEC-R006-004（=design D5）：非法值双保险 fail-fast——Dart `ArgumentError` + Kotlin `invalid_arguments`，plane 不启动不静默回退。
- DEC-R006-005（=design D6）：python 401→request→poll→claim 编排归 BF002 e2e 脚手架（纯标准库），mcp_plane 库零改动（吸收 review W1）。
