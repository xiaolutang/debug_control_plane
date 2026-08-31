---
version: "1.0"
type: tasks
topic: token-persistence
requirement_cycle: R004
taskPackageVersion: "1.8"
workflow:
  evaluate_provider: direct_subagent
  mode: auto
status: planned
analysisManifestPath: .dev-flow/R004/analysis/manifest.json
analysisManifestRevision: 4
analysisManifestDigest: efd0e801f958597aab9c3baf80db40ac4fa57eea3f1cc20136860a58750cb668
analysisIntegrationPath: .dev-flow/R004/analysis/2026-08-31--token-persistence-integration.md
bootstrapLegacy: false
analysisSourceMdPaths:
  - .dev-flow/R004/analysis/manifest.json
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-app-store-slice.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-python-provider-slice.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-ttl-script-slice.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-integration.md
designMdPaths:
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-design.md
testMdPaths:
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-test.md
contextMdPaths:
  - .dev-flow/architecture.md
  - .dev-flow/R004/analysis/manifest.json
  - .dev-flow/R004/analysis/2026-08-31--token-persistence.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-app-store-slice.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-python-provider-slice.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-ttl-script-slice.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-integration.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-design.md
  - .dev-flow/R004/analysis/2026-08-31--token-persistence-test.md
---

# R004 token 持久化任务清单

全局约束：wire 协议零改动（`/auth/*` 契约、token `dcp_` 前缀、`DebugAuthTokenRecord` 结构不变）；app 侧明文 token 永不落盘（persist 数据源只有 tokens map 的 hash 记录；pending 含 tokenPlaintext 仅内存）；Kotlin 纯 JVM core（`kotlin/`）零改动；不引入 DataStore/加密库/keyring（org.json 或手写编解码）；python 侧 `DevicePool` 禁存 token 红线不违反（独立文件独立 schema）；验收脚本 fork 自 R003-BF008 副本，不回写 R003 产物。

执行顺序：R004-FF001 → R004-FF002；R004-BF001 与前两者并行；最后 R004-BF002（依赖 FF001+BF001+FF002 全部完成）。

## R004-FF001：app 侧 FileBackedPluginDebugAuthStore — 持久化与 attach 接线 `⬜ 待处理`

- 文件：`flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/PluginDebugAuth.kt`（新增类）+ `flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/DebugControlPlaneFlutterPlugin.kt`（attach 升级）+ `flutter_debug_control_plane/android/src/test/kotlin/com/pantas/debug/controlplane/flutter/PluginDebugAuthStorePersistenceTest.kt`（新增）
- 改动类型：修改
- domain: ui
- task_layer: foundation
- depends_on: []
- priority: 5
- risk_tags: [android, persistence, concurrency, security]
- smoke_required: true
- mode: negotiated
- status: pending
- sourceCapabilities: [FF001]
- sourceSlices: [.dev-flow/R004/analysis/2026-08-31--token-persistence-app-store-slice.md]
- sourceDesigns: [.dev-flow/R004/analysis/2026-08-31--token-persistence-design.md]
- sourceTests: [.dev-flow/R004/analysis/2026-08-31--token-persistence-test.md]
- acceptance_criteria: [装饰器形态内嵌 InMemory 工作集且 pending 组纯透传不落盘, putToken/markRevoked/markAllRevoked 后同步原子写(tmp+rename)且临界区重收集快照, load 损坏回退空不抛(attach 路径安全)且过期记录丢弃并回写, onAttachedToEngine 用 applicationContext 幂等升级 processAuthStore 并迁移内存记录, setAuthStoreForHost 整体替换语义不变, 单测覆盖 roundtrip/截断回退/可空往返/revoked 持久化/过期清理/原子写/并发 persist/红线(pending 明文不出现在文件)]
- test_tasks: [{type: unit, layer: unit, domain: android, description: FileBacked store 持久化单测(@TempDir), scenarios: [roundtrip, corrupt-fallback, nullable-roundtrip, revoked-persist, expired-cleanup, atomic-write, concurrent-persist, plaintext-redline]}]
- contract_refs: [.dev-flow/R004/analysis/2026-08-31--token-persistence-acceptance-spec.yaml]
- decision_refs: [DEC-R004-001]
- blocked_files: [kotlin/src/main/kotlin/com/pantas/debug/controlplane/DebugAuth.kt, python/]
- 具体改动点：R004-FF001.1 新增 `FileBackedPluginDebugAuthStore(context: Context, delegate: InMemoryPluginDebugAuthStore = InMemoryPluginDebugAuthStore())` 装饰器（load/persist/JSON 编解码/单锁）；R004-FF001.2 `onAttachedToEngine` 幂等升级接线（迁移内存记录后赋回 companion）；R004-FF001.3 新增单测 8 用例。
- 关键代码片段：`class FileBackedPluginDebugAuthStore(private val context: Context, private val delegate: InMemoryPluginDebugAuthStore = InMemoryPluginDebugAuthStore()) : PluginDebugAuthStore { private val persistLock = Any(); private val file: File get() = File(context.filesDir, "debug_auth_tokens.json") /* 透传 8 方法;token 组写后 persist() */ }`
- 改动理由/上下文：token 生命周期当前=进程生命周期是弹窗反复的 app 侧根因；filesDir 覆盖安装保留/卸载抹除恰好匹配支持与出界边界。

## R004-BF001：python FileTokenProvider — 持久化实现与 server 注入 `⬜ 待处理`

- 文件：`python/debug_control_plane/mcp_plane/token_provider.py`（新增）+ `python/debug_control_plane/mcp_plane/server.py`（main 注入一行）+ `python/tests/test_token_provider.py`（新增）
- 改动类型：修改
- domain: backend
- task_layer: foundation
- depends_on: []
- priority: 5
- risk_tags: [python, persistence, security, py310-compat]
- smoke_required: true
- mode: negotiated
- status: pending
- sourceCapabilities: [BF001]
- sourceSlices: [.dev-flow/R004/analysis/2026-08-31--token-persistence-python-provider-slice.md]
- sourceDesigns: [.dev-flow/R004/analysis/2026-08-31--token-persistence-design.md]
- sourceTests: [.dev-flow/R004/analysis/2026-08-31--token-persistence-test.md]
- acceptance_criteria: [懒加载(_loaded 首次读写触发)且 asyncio 单线程假设写入 docstring, tmp 以 os.open(O_WRONLY|O_CREAT|O_TRUNC, 0o600) 创建绕 umask 后 os.replace 原子替换, expiresAt 用 fromisoformat(value.replace("Z","+00:00")) 判定且解析失败/naive 视为未过期, 损坏/版本不符静默回退空不崩 server, clear_token 落盘重写删行(401 三码联动), tokens.json 与 devices.json 独立 schema 互不引用, main() 注入 token_provider=FileTokenProvider(), 单测覆盖 roundtrip/0600/过期四态/clear 删盘/损坏回退/metadata 并入/版本不符]
- test_tasks: [{type: unit, layer: unit, domain: backend, description: FileTokenProvider 单测(tmp_path), scenarios: [roundtrip-cross-instance, 0600-permission, expired-past-future-Z-invalid, clear-deletes-row, corrupt-fallback, metadata-merge, version-mismatch]}]
- contract_refs: [.dev-flow/R004/analysis/2026-08-31--token-persistence-acceptance-spec.yaml]
- decision_refs: [DEC-R004-002]
- blocked_files: [python/debug_control_plane/mcp_plane/bridge_client.py, python/debug_control_plane/device_discovery/device_pool.py]
- 具体改动点：R004-BF001.1 新增 `token_provider.py`（FileTokenProvider：get/save/clear + _load + _flush）；R004-BF001.2 `server.py` main() 注入；R004-BF001.3 新增单测 7 用例。
- 关键代码片段：`class FileTokenProvider: def __init__(self, path: Path | None = None) -> None: self._path = path or Path.home() / ".debug-control-plane" / "tokens.json"; self._loaded = False; self._tokens: dict[str, dict[str, str]] = {}`
- 改动理由/上下文：Protocol 已存在但零正式实现，python 侧 token 每进程即散；开发机明文+0600 已拍板。

## R004-FF002：token TTL 默认 1h → 7 天 `⬜ 待处理`

- 文件：`flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/PluginDebugAuth.kt`（常量）+ `flutter_debug_control_plane/android/src/test/kotlin/com/pantas/debug/controlplane/flutter/PluginDebugAuthManagerTest.kt`（新增用例）
- 改动类型：修改
- domain: ui
- task_layer: foundation
- depends_on: [R004-FF001]
- priority: 4
- risk_tags: [android, ttl, regression]
- smoke_required: true
- mode: negotiated
- status: pending
- sourceCapabilities: [FF002]
- sourceSlices: [.dev-flow/R004/analysis/2026-08-31--token-persistence-ttl-script-slice.md]
- sourceDesigns: [.dev-flow/R004/analysis/2026-08-31--token-persistence-design.md]
- sourceTests: [.dev-flow/R004/analysis/2026-08-31--token-persistence-test.md]
- acceptance_criteria: [defaultTokenTtlSeconds 提常量 DEFAULT_TOKEN_TTL_SECONDS=604800 替换字面量 3600, 显式 ttlSeconds 通道语义不变(宿主覆盖默认), 新增 JVM 回归用例断言不传 ttl 时 expiresAt-now ∈ [604790,604810], 既有全部显式 ttl 用例零回归(analysis 已排查零 3600 依赖)]
- test_tasks: [{type: unit, layer: unit, domain: android, description: TTL 默认值回归用例, scenarios: [default-7d, explicit-override]}]
- contract_refs: [.dev-flow/R004/analysis/2026-08-31--token-persistence-acceptance-spec.yaml]
- decision_refs: [DEC-R004-003]
- blocked_files: [kotlin/, dart/, python/, PROTOCOL.md]
- 具体改动点：R004-FF002.1 提常量并替换默认值；R004-FF002.2 新增默认值回归用例。
- 关键代码片段：`private val defaultTokenTtlSeconds: Long = DEFAULT_TOKEN_TTL_SECONDS // companion: const val DEFAULT_TOKEN_TTL_SECONDS = 604800L`
- 改动理由/上下文：默认值属 plugin 行为层全宿主免配置；1h 对自动化循环过短，7 天覆盖一个开发周。

## R004-BF002：验收脚本 install -r 改造 + 端到端 runner `⬜ 待处理`

- 文件：`.dev-flow/R004/test-overrides/R004-BF002/integration-android.sh`（fork 新建）+ `.dev-flow/R004/test-overrides/R004-BF002/e2e-token-persistence.py`（新建 runner）+ `.dev-flow/R004/evidence/`（evidence 双写）
- 改动类型：新建
- domain: backend
- task_layer: acceptance
- depends_on: [R004-FF001, R004-BF001, R004-FF002]
- priority: 3
- risk_tags: [android-device, integration, deferred]
- smoke_required: true
- mode: negotiated
- status: pending
- sourceCapabilities: [BF002]
- sourceSlices: [.dev-flow/R004/analysis/2026-08-31--token-persistence-ttl-script-slice.md]
- sourceDesigns: [.dev-flow/R004/analysis/2026-08-31--token-persistence-design.md]
- sourceTests: [.dev-flow/R004/analysis/2026-08-31--token-persistence-test.md]
- acceptance_criteria: [fork R003-BF008 脚本且不回写 R003 产物, 无条件 uninstall 移除(仅 DELETE_AND_REINSTALL=1 执行)且安装统一 install -r, APK_ALREADY_INSTALLED 快速路径保留且注释写明安装弹窗(HyperOS USB 安装授权)与 auth 弹窗消灭机制分工, 头部注释与 test-log 执行路径描述同步, python runner 覆盖 6 用例(1 双侧落盘/2 冷重启[device-deferred]/3 install-r 主断言[device-deferred]/4 python 重启免 auth/5 过期自动重授权/6 清装逃生门[device-deferred]), deferred 时 evidence 双写空壳(device_required)沿用 R003 模式, 真机在场时 1/2/3/6 必须 pass]
- test_tasks: [{type: integration, layer: integration, domain: android, description: 端到端 6 用例真机验收, scenarios: [first-auth-both-persist, cold-restart-token-200, install-r-token-200, python-restart-no-auth, expired-re-auth, delete-and-reinstall-fresh]}, {type: integration, layer: integration, domain: cross_stack, description: python 侧断言链(provider 真实读盘不 mock 读路径), scenarios: [bearer-reuse, 401-clear-relay]}]
- contract_refs: [.dev-flow/R004/analysis/2026-08-31--token-persistence-acceptance-spec.yaml]
- decision_refs: [DEC-R004-004]
- blocked_files: [.dev-flow/R003/]
- 具体改动点：R004-BF002.1 fork 脚本并改安装语义（uninstall 仅逃生门 + 注释分工 + log 描述同步）；R004-BF002.2 新增 e2e runner（6 用例 + skip(setup_required)/deferred 契约）；R004-BF002.3 evidence 双写结构。
- 关键代码片段：`if [[ "${DELETE_AND_REINSTALL:-0}" == "1" ]]; then adb_cmd uninstall "$PACKAGE_NAME" >/dev/null 2>&1 || true; fi; install_apk() { adb_cmd install -r "$APK_PATH"; }`
- 改动理由/上下文：uninstall 前置（非安装命令）是 install -r 场景下 token 丢失的主因；设备无独立 curl 通道，断言必须 python 侧发起。

## 决策记录

- DEC-R004-001：store 用装饰器而非平行实现；attach 惰性升级（方案 A）而非构造期 Context；同步 persist 而非异步（消灭丢写窗口）；损坏回退空而非 fail-fast（attach 路径安全）。
- DEC-R004-002：python tmp 文件以 os.open 0o600 创建（无 0644 窗口）；读时判定过期不回写；损坏静默回退（token 可再生）；单线程不加锁。
- DEC-R004-003：默认值放 plugin Kotlin 行为层（全宿主免配置）；不改 Dart/app 层；fixtures 零同步（已排查）。
- DEC-R004-004：fork R003 脚本到 R004 test-override 副本（analysis review 建议）；快速路径保留（HyperOS 安装弹窗与 auth 弹窗是两个机制）。
