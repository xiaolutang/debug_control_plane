---
version: "1.0"
type: tasks
topic: dart-plane-token-persistence
requirement_cycle: R005
taskPackageVersion: "1.8"
workflow:
  evaluate_provider: direct_subagent
  mode: auto
status: planned
analysisManifestPath: .dev-flow/R005/analysis/manifest.json
analysisManifestRevision: 1
analysisManifestDigest: afd145bdb50143d83de0cbca5ab357ce7c6871b7a084a360405369686dac7f60
analysisIntegrationPath: .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-integration.md
bootstrapLegacy: false
analysisSourceMdPaths:
  - .dev-flow/R005/analysis/manifest.json
  - .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence.md
  - .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-integration.md
designMdPaths:
  - .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-design.md
testMdPaths:
  - .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-test.md
contextMdPaths:
  - .dev-flow/architecture.md
  - .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence.md
  - .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-integration.md
  - .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-design.md
  - .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-test.md
---

# R005 dart plane token 持久化任务清单

全局约束：`/auth/*` wire 契约零改动（响应字段、状态码、`dcp_` 前缀语义不变）；明文 token 不落盘且不作索引键（文件只含 sha256 hex、map 键=hash；`_activeToken` UI 演示豁免按 design D3 收敛版）；dart core 零新依赖（sha256 纯 Dart 手写，`path_provider` 只进 example）；Kotlin/python 两侧零改动；pending 组不入持久化（D6）；同步 persist（D7）；`design.md`「暂不实现」清单（plugin ios/、Web、清装、加密存储、pending 恢复）不得进入任务。

执行顺序：R005-BF001 → R005-FF001（依赖 BF001 的 store）→ R005-BF002（依赖前两者全部完成）。

## R005-BF001：dart core token 存储管理 — DebugAuthStore + InMemory + FileBacked + sha256 `✅ 已完成 (430a9f8)`

- 文件：`dart/lib/src/debug_auth_store.dart`（新建）+ `dart/lib/debug_control_plane.dart`（加一行 export）+ `dart/test/debug_auth_store_test.dart`（新建）
- 改动类型：新建
- domain: backend
- task_layer: foundation
- depends_on: []
- priority: 5
- risk_tags: [dart, persistence, security, cryptography]
- smoke_required: true
- mode: direct
- status: completed
- sourceCapabilities: [BF001]
- sourceSlices: [S01-dart-token-store]
- sourceDesigns: [.dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-design.md]
- sourceTests: [.dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-test.md]
- acceptance_criteria: [TokenRecord 数据类与 Kotlin DebugAuthTokenRecord 字段同构(tokenId/tokenHash/createdAt/expiresAt/revokedAt/clientLabel), InMemoryDebugAuthStore 实现 DebugAuthStore 抽象且 map 键为 tokenHash, FileBackedDebugAuthStore 装饰器构造惰性 load 损坏或 version 不符回退空 map 不抛, putToken/markRevoked/markAllRevoked 同步 persist 用 tmp 写入后 File.rename 原子替换且无 tmp 残留, load 时 expiresAt 过期行丢弃且不回写, sha256Hex 纯 Dart 实现通过 NIST 已知向量 abc 与空串, 单测覆盖 roundtrip/损坏回退/过期清理/原子写/红线明文不出现于文件字节, dart pubspec.yaml 零新依赖, 既有 dart/test 全部用例零回归]
- test_tasks: [{type: unit, layer: unit, domain: backend, description: BF001 store 单测(test.md U1-U10), scenarios: [put-tokenByHash-roundtrip, sha256-nist-vectors, file-roundtrip-cross-instance, corrupt-fallback, expired-cleanup, revoked-persist, remove-expired, atomic-write-no-tmp-residue, plaintext-redline-file-bytes]}]
- contract_refs: []
- decision_refs: [D1, D2, D3, D4, D6, D7]
- blocked_files: [dart/lib/src/debug_auth.dart, dart/lib/src/control_plane.dart, kotlin/, python/, flutter_debug_control_plane/android/, PROTOCOL.md]
- 具体改动点：R005-BF001.1 新建 `debug_auth_store.dart`：`TokenRecord` 数据类 + `DebugAuthStore` 抽象 + `InMemoryDebugAuthStore` + `FileBackedDebugAuthStore` + 库私有 `sha256Hex`；R005-BF001.2 `debug_control_plane.dart` 加 `export 'src/debug_auth_store.dart';`；R005-BF001.3 新建单测 10 用例（U1-U10）。
- 关键代码片段：
  ```dart
  class TokenRecord {
    const TokenRecord({required this.tokenId, required this.tokenHash,
      required this.createdAt, required this.expiresAt,
      this.revokedAt, this.clientLabel});
    final String tokenId; final String tokenHash;      // sha256 hex,明文永不出现
    final DateTime createdAt; final DateTime expiresAt;
    final DateTime? revokedAt; final String? clientLabel;
    Map<String, Object?> toJson() => {/* version:1 schema 行 */};
    factory TokenRecord.fromJson(Map<String, Object?> json) => /* ... */;
  }
  abstract interface class DebugAuthStore {
    TokenRecord? tokenByHash(String tokenHash);
    void putToken(TokenRecord record);
    void markRevoked(String tokenId, DateTime revokedAt);
    void markAllRevoked(DateTime revokedAt);
    void removeExpired(DateTime now);
  }
  class InMemoryDebugAuthStore implements DebugAuthStore {
    final Map<String, TokenRecord> _tokens = {};  // key = tokenHash
    /* 五方法直通 map 操作 */
  }
  class FileBackedDebugAuthStore implements DebugAuthStore {
    FileBackedDebugAuthStore({required this.directory, this.delegate = ...});
    // 1. 首次访问触发 _load():读 <directory>/debug_auth_tokens.json
    //    jsonDecode 抛 FormatException / version!=1 → 空 map(吞异常)
    //    过期行(expiresAt<=now)丢弃
    // 2. 写方法:先 delegate 更新 → _persist()
    //    encode 全部记录 → writeAsString('.tmp') → rename(目标) 原子替换
    // 3. sha256Hex: 标准 FIPS 180-4 纯 Dart(K 常量表+64 轮压缩+padding)
  }
  ```
- 改动理由/上下文：dart core 是唯一无 token 存储的一端（Kotlin/Python R004 已补）；装饰器形态与 Kotlin `FileBackedPluginDebugAuthStore` 同构，行为心智一致；目录参数化让 core 不感知平台路径（D4）。

## R005-FF001：example 接线 — AcceptanceDebugAuthManager store 注入 + hash 索引 + TTL 7d `✅ 已完成 (e3680f7)`

- 文件：`flutter_debug_control_plane/example/lib/src/acceptance_plane.dart`（修改）+ `flutter_debug_control_plane/example/pubspec.yaml`（加 path_provider）+ `flutter_debug_control_plane/example/test/acceptance_plane_test.dart`（适配）
- 改动类型：修改
- domain: ui
- task_layer: foundation
- depends_on: [R005-BF001]
- priority: 4
- risk_tags: [flutter, auth, regression]
- smoke_required: true
- mode: direct
- status: completed
- sourceCapabilities: [FF001]
- sourceSlices: [S01-dart-token-store]
- sourceDesigns: [.dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-design.md]
- sourceTests: [.dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-test.md]
- acceptance_criteria: [构造参数新增可选 store 缺省为 InMemoryDebugAuthStore 且 tokenTtl 默认 Duration(days:7), AcceptancePlane 装配层默认注入 FileBackedDebugAuthStore(documents 目录经 path_provider), token 校验路径全部改走 tokenByHash(sha256(token)) 即 authorize 与 helloAuthState 两处, _tokens 明文 map 与 _IssuedToken 删除或重构为 hash 索引记录, claim 落 store 后 expiresAt 为 7 天(604790-604810s 区间断言), clearToken/expireToken 改经 store(markAllRevoked/removeExpired 语义等价)且公开 API 行为不变(tokenPresent/activeToken/pendingRequestIds), 既有 acceptance_plane_test 用例全部零回归且新增 E1-E5 用例, /auth/* 五方法响应字段与状态码逐字段与改动前一致(wire 零改动)]
- test_tasks: [{type: unit, layer: unit, domain: flutter, description: FF001 example 单测(test.md E1-E5), scenarios: [hash-verify-auth-chain, store-injection-equivalence, ttl-default-7d, existing-cases-zero-regression, persist-layer-no-plaintext]}]
- contract_refs: []
- decision_refs: [D3, D4, D5]
- blocked_files: [dart/lib/, kotlin/, python/, PROTOCOL.md, flutter_debug_control_plane/lib/]
- visual-verify 不适用：本任务无新增 UI 元素（行为增强非 UI 变更，复用 R002 既有 acceptance.auth_dialog.* 标识；plan-review A1 豁免判定）
- 具体改动点：R005-FF001.1 `acceptance_plane.dart`：`AcceptanceDebugAuthManager` 构造加 `DebugAuthStore? store`（缺省 InMemory）+ `tokenTtl` 默认改 `Duration(days: 7)`；R005-FF001.2 校验路径 hash 化（authorize/helloAuthState/claim 三处）；R005-FF001.3 `AcceptancePlane` 装配层默认注入 FileBacked（path_provider documents 目录，异步装配：store 目录解析完成前 manager 用内存版，避免构造顺序耦合）；R005-FF001.4 既有测试适配 + E1-E5。
- 关键代码片段：
  ```dart
  AcceptanceDebugAuthManager({
    AcceptanceRequestLogSink? onRequestLog,
    DateTime Function()? now, Random? random,
    DebugAuthStore? store,                                  // ← 新增
    Duration tokenTtl = const Duration(days: 7),            // ← 15min → 7d
  }) : _store = store ?? InMemoryDebugAuthStore(), ...;

  // authorize/helloAuthState:
  final record = _store.tokenByHash(sha256(token));   // ← 明文 map 命中改为 hash 查询
  // 判定:record==null → invalid_token;expiresAt<=now → token_expired;revokedAt!=null → token_revoked

  // claim:
  final token = _newId('tok');
  _store.putToken(TokenRecord(tokenId: tokenId, tokenHash: sha256(token), ...));
  // clearToken → _store.markAllRevoked(now);expireToken → 构造过期(expiresAt 已过)后 removeExpired
  ```
- 改动理由/上下文：example 是 Dart plane 的参照宿主；装配层默认文件持久化让 iOS 模拟器集成测试无需特殊配置即验证冷重启；manager 缺省内存保持 dart core 语义（D4 两层表述）。

## R005-BF002：集成测试 — iOS 模拟器 token 持久化端到端 5 用例 `▶ 进行中`

- 文件：`.dev-flow/R005/test-overrides/R005-BF002/ios-simulator-persistence.py`（新建断言脚本）+ `.dev-flow/R005/test-overrides/R005-BF002/run-integration.sh`（新建驱动）+ `python/tests/test_dart_plane_persistence.py`（新建 pytest 入口）+ `.dev-flow/R005/evidence/`（evidence 双写）
- 改动类型：新建
- domain: integration
- task_layer: acceptance
- depends_on: [R005-BF001, R005-FF001]
- priority: 3
- risk_tags: [ios-simulator, integration, cross-stack]
- smoke_required: true
- mode: direct
- status: in_progress
- sourceCapabilities: [BF002]
- sourceSlices: [S01-dart-token-store]
- sourceDesigns: [.dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-design.md]
- sourceTests: [.dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-test.md]
- acceptance_criteria: [驱动脚本完成 build+install+launch driver(auto-approve)与 plane endpoint 发现复用 R004 模式, I1 首次授权断言 claim 200 且 app 沙箱 debug_auth_tokens.json 存在且字节不含明文 token 且 python tokens.json 有行, I2 冷重启主断言杀 app 进程重启后旧 Bearer /hello 返回 200 且 authStatus=authorized 零弹窗, I3 损坏自愈篡改 app 侧 JSON 为非法内容重启后 401 且新授权链可达且 claim 后文件恢复合法 JSON, I4 TTL 断言 claim 响应 expiresAt-now 在 604790-604810 秒且构造过期后 401 token_expired 且重授权可达, I5 wire 回归 no-token 401/forged 401 invalid_token/claim 响应无 token 字段泄漏语义复用 R004 S4 断言, deferred 契约模拟器不在场时 evidence 双写空壳 device_required 沿用 R003/R004 模式, python pytest 全量零回归]
- test_tasks: [{type: integration, layer: integration, domain: cross_stack, description: iOS 模拟器持久化 5 用例(test.md I1-I5), scenarios: [first-auth-both-persist, cold-restart-token-200, corrupt-file-self-heal, ttl-effective, wire-regression], requires: [flutter_built, simulator_booted]}]
- contract_refs: []
- decision_refs: [D3, D5]
- blocked_files: [dart/lib/, flutter_debug_control_plane/example/lib/, kotlin/, python/debug_control_plane/]
- 具体改动点：R005-BF002.1 驱动脚本（build/install/launch/endpoint 发现，fork R004-ios 模式）；R005-BF002.2 断言脚本 I1-I5；R005-BF002.3 pytest 入口 + evidence 双写；R005-BF002.4 真机/模拟器执行与证据落盘。
- 关键代码片段：
  ```python
  # I2 核心断言(冷重启):
  #   1. 首次授权链 → python 持 token(app 沙箱文件已生成)
  #   2. kill app(simctl terminate 或 driver 退出)→ 重新 launch
  #   3. GET /hello, headers={"Authorization": f"Bearer {token}"}
  #   assert r.status_code == 200 and r.json()["authStatus"] == "authorized"
  # I3: app 沙箱路径 = simctl get_app_container <udid> <bundle> data +
  #     Documents/debug_control_plane/debug_auth_tokens.json
  #     写坏 → 重启 → 敏感路由 401 → 重走授权 → 读文件 json.loads 不抛
  ```
- 改动理由/上下文：I2 是本 RC 价值主断言（冷重启免授权=与 Android R004 真机用例 2 对称）；脚本 fork 自 R004-ios 模式而非 Android 通道（无 adb，用 simctl + loopback）。

## 决策记录

- DEC-R005-001（=design D3 收敛版）：明文边界=「持久层与索引键无明文」；`_activeToken`/`activeToken` getter 保留（UI 演示链便利，公开 API 零破坏）。
- DEC-R005-002（=design D2）：sha256 纯 Dart 手写库内私有不导出；零新依赖红线。
- DEC-R005-003（=design D4）：store 目录参数化；manager 缺省内存，example 装配层默认注入 FileBacked。
- DEC-R005-004（=design D5/D6/D7）：TTL 7d 常量；pending 不持久化；同步 persist。
