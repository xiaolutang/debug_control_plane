---
type: analysis
slice_id: S01-app-store-persistence
round: R004
date: 2026-08-31
---

# R004 S01 — App 侧 token 持久化 store 片分析

## 概述

本片只做一件事：把 `PluginDebugAuthStore` 的 tokens map 从进程内存迁到 app 私有目录单文件 JSON（`filesDir/debug_auth_tokens.json`），使 app 冷重启 / `adb install -r` 覆盖安装后，同 token 请求仍能通过 `DebugAuth.validateToken` 验证。与 S02 的边界：Python provider 只负责带旧 token 重连（token 格式与 wire 协议零改动，S02 不感知存储介质）；与 S03 的边界：TTL 续期与脚本化验证场景依赖本片的"记录可存活"前提，但本片不引入任何 TTL 语义变化（过期判定仍由 `DebugAuth.validateToken` 在请求时点执行）。

红线重申：`DebugAuthTokenRecord` 只含 tokenHash（SHA-256 hex），明文 token 仅存在于 pending 的 `tokenPlaintext` 内存字段，approve 后 claim 一次即焚（`claimAuthorization` 里 `copy(tokenPlaintext = null)` 回写）。持久化文件里因此只有 hash——暴力还原 64 hex 字符的 SHA-256 不可行。

## 一、交互链（用户平面）

场景 SCN-APP-TOKEN-SURVIVE-RESTART。

### 1. 首次授权链（现状，不变）

```
Python client                    App (Flutter plugin + Kotlin core)
   |  POST /auth/request {clientNonce, clientLabel}
   |------------------------------------->|
   |            202 {requestId, pairingCode}
   |<-------------------------------------|
   |        (App 弹窗 → 用户 approve)
   |  GET /auth/status {requestId, clientNonce}  (轮询)
   |------------------------------------->|
   |            200 {status: approved}
   |  POST /auth/claim {requestId, clientNonce}
   |------------------------------------->|
   |            200 {token: dcp_..., tokenId, expiresAt}
   |<-------------------------------------|
```

approve 在 `PluginDebugAuthManager.approve` 内生成 `dcp_` + 64 hex token，putToken（hash 记录）+ putPending（含明文，5 分钟 pending TTL 内可 claim）。

### 2. 新增：app 冷重启后带旧 token 访问

```
Python                            App（新进程）
   |  GET /hello  Authorization: Bearer dcp_...
   |------------------------------------->|
   |        store.tokenByHash(SHA-256(token))
   |        ← 懒加载 debug_auth_tokens.json 命中记录
   |        DebugAuth.validateToken(token, record, now) → Authorized
   |            200 {authStatus: authorized, tokenId, expiresAt, clientLabel}
   |<-------------------------------------|
```

关键点：authorize / helloAuthState 走的都是 `store.tokenByHash(DebugAuth.tokenHash(it))`，因此只要 store 的读路径命中持久化记录，manager 与 core 代码零改动即达成场景。

### 3. `adb install -r` 覆盖安装后

filesDir 跨覆盖安装保留，行为与场景 2 完全一致（新进程 → 懒加载 → 命中 → 200）。这也覆盖宿主 app 自己的热重启/被系统回收重建。

### 4. 边界（明确不支持）：uninstall 清装

卸载时系统抹除 filesDir，store 文件随之消失。重启后 Python 带旧 token 请求 → `tokenByHash` 返回 null → `DebugAuth.validateToken` 判 `record == null` → 401 `invalid_token` → Python 走完整重新授权链（场景 1）。这是正确的失败方向：凭证状态随数据目录销毁，语义上等价于 `markAllRevoked`，无需任何代码处理。

## 二、逻辑树（系统平面）

### 现有 store 结构

`PluginDebugAuthStore` 接口（PluginDebugAuth.kt:14-23）8 个方法，两组：

- pending 组（requestId / nonceHash 索引）：`pending` / `pendingByNonceHash` / `putPending`
- token 组（tokenId / tokenHash 索引）：`token` / `tokenByHash` / `putToken` / `markRevoked` / `markAllRevoked`

消费方全部在 `PluginDebugAuthManager`；进程级单例由 `DebugControlPlaneFlutterPlugin.companion object.processAuthStore`（:52）持有，plugin attach 时若 host 未注入则用它构造 manager（:81），`setAuthStoreForHost`（:56）是测试/host 注入替换点。

### 新增 FileBackedPluginDebugAuthStore 设计

**形态：装饰器（推荐）而非平行实现。** 新类持有内部 `InMemoryPluginDebugAuthStore` 作为工作集 + 一个 `persist()` 钩子，接口方法透传内存实现后按需触发落盘。理由：InMemory 的并发语义（ConcurrentHashMap、firstOrNull 线性扫描）已经过 R002/R003 验证，装饰器只加"何时写盘"一个职责，测试也最薄。

#### 存储位置与 Context 时序

- 路径：`context.filesDir/debug_auth_tokens.json`。filesDir 是 app 私有目录，覆盖安装保留、卸载抹除——正好匹配场景 2/3 支持与场景 4 不支持的边界。
- **Context 获取：`onAttachedToEngine(binding)` 的 `binding.applicationContext` 是唯一安全入口。** companion object 静态初始化时无 Context，不能在 `processAuthStore` 初始化处直接构造文件 store。两个可选方案：
  - **方案 A（推荐）：惰性升级。** `processAuthStore` 仍初始为 InMemory；`onAttachedToEngine` 首次执行时若 `processAuthStore` 是 InMemory，则升级为 `FileBackedPluginDebugAuthStore(applicationContext, delegate=现有内存实例)`——把已 attach 期间可能产生的记录迁移进去，再赋回 companion。因为 attach 必然先于任何 HTTP 请求（plane 由 attach 后的 method call 启动），实际不会有"先有 token 后升级"的窗口，但迁移保证稳妥。
  - 方案 B：`FileBackedPluginDebugAuthStore` 构造时只收目录 File，`processAuthStore` 用 `null` Context 占位、attach 时 `ensureContext()`。多一个可空字段与并发可见性问题，劣于 A。
- 生命周期归宿主（架构宪法）：文件 store 的生命周期绑定进程（companion），不随 engine detach 销毁——与现有 processAuthStore 语义一致，detach 时不删文件不关句柄（无打开句柄，每次 persist 开-写-关）。

#### 持久化范围：只持久化 tokens，不持久化 pending

pending 是短命数据（默认 300s TTL，`effectiveStatus` 过期即 expired），且 `PluginDebugAuthPending` 含 `tokenPlaintext` 与 `pairingCode`——**持久化 pending 会把明文 token 落盘，直接踩红线**。重启后 pending 丢失的代价是：claim 中的授权请求需重新走 request→approve→claim，这与"授权弹窗只弹第一次"的目标不冲突（弹窗决策已沉淀为 token）。因此 pending 仅内存，重启即清空。

#### 写入与读取时机

- 读：构造（升级）时一次性懒加载到内存 delegate；此后所有读走内存，零 IO 热路径。
- 写：`putToken` / `markRevoked` / `markAllRevoked` 之后同步全量写。**同步优先于异步**：写频极低（一次授权 1 写，revoke 每次 1 写），数据量极小（个位数记录），异步带来的丢写窗口（app 被杀在 putToken 与 flush 之间 → 已授权 token 丢失 → 重新弹窗）正是本需求要消灭的场景。全量写而非增量写：文件小、无 append 碎片、天然自愈。
- **原子写：写 `debug_auth_tokens.json.tmp` → `File.renameTo`。** 非原子写在中途被杀会留下截断 JSON，下次加载即触发容错回退，等效丢 token。rename 在同目录下 POSIX 语义原子，成本可忽略。

#### JSON schema

单文件、手写 org.json（Android 内置，零依赖，满足"不引入 DataStore/加密库"约束）：

```json
{
  "version": 1,
  "tokens": [
    {
      "tokenId": "tok-...",
      "tokenHash": "<64 hex>",
      "createdAt": "2026-08-31T09:00:00Z",
      "expiresAt": "2026-08-31T10:00:00Z",
      "revokedAt": null,
      "clientLabel": "pytest"
    }
  ]
}
```

- Instant 序列化：**统一 `Instant.toString()`（ISO-8601 UTC，Z 后缀）/ `Instant.parse()` 往返**。这与 wire 协议上 `expiresAt` 的既有字符串格式一致（claim/hello 响应里就是 `expiresAt.toString()`），不引入第二套时间格式。
- `revokedAt` / `clientLabel` 可空字段必须显式 null 或省略，读取端用 `optInstant` 风格容错。
- version 字段为未来 schema 演进预留；未知 version 按容错处理。

#### 损坏容错：回退空 store（建议）

解析失败（JSONException / IO 错误 / 单条字段非法）→ 记一条 logcat warn + 返回空 map + 把坏文件 rename 成 `.corrupt` 留档（可选）。对齐 device_pool 对损坏状态文件的容错风格：debug 工具链不应因一个可重建的缓存文件 crash 宿主 app 或 fail 启动。代价是坏文件里的有效 token 也丢了——但唯一恢复路径就是重新授权一次，可接受。不要 fail-fast：`onAttachedToEngine` 路径上抛异常会打断 plugin attach。

#### 过期清理：加载时丢弃 expiresAt < now 并回写

加载阶段过滤 `!record.expiresAt.isBefore(now)` 之外的记录；若有丢弃则立即回写一次（顺便把刚清理的结果固化，也覆盖 .corrupt 恢复场景）。避免文件随时间无限膨胀（自动化循环里每次 run 颁一个 token，一周就是上百条死记录）。

#### 错误注入点：setAuthStoreForHost 与文件 store 共存

`setAuthStoreForHost` 语义保持"整体替换 store 实例"——测试注入 InMemory 或自造 fake 时，manager 用注入实例、完全不触文件。文件 store 的升级只发生在 attach 且 host 未注入的前提下。因此单测不需任何 tmpdir；文件 store 自身另配独立单测（`@TempDir` 或 Robolectric `filesDir`）直测 load/persist/原子写/容错。

#### 线程模型

- 内存层沿用 ConcurrentHashMap，与现状一致。
- `persist()` 并发：approve/revoke 可能在不同 NanoHTTPD worker 线程并发触发。**方案：persist 用 store 内单一 `synchronized(lock)` 串行化 + tmp 文件名固定（同目录 rename 原子）。** 写临界区内重新从内存 delegate 收集快照，保证写出的总是最新一致状态。不做 per-record diff，避免顺序问题。
- IO 线程：写发生在调用线程（HTTP worker / MethodChannel 主线程派发前的 handler）。写量小（<1KB），可接受；若 attach 后 plane 的 Dispatchers.IO scope 可达，可在 FileBacked 构造时收一个可选 `CoroutineScope` 用 `launch` 包 persist——但这引入异步丢写窗口，**不建议**，保持同步。

## 三、功能编号与网络定位

| 编号 | 能力名 | 归属 | slice | 文件落点 | 验收要点 |
|---|---|---|---|---|---|
| FF001 | app 侧 token 持久化 store（FileBackedPluginDebugAuthStore + attach 升级注入） | 本片 | S01 | `flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/PluginDebugAuth.kt`（新增类）；`DebugControlPlaneFlutterPlugin.kt`（onAttachedToEngine 升级 processAuthStore） | 冷重启后旧 token /hello 200；install -r 同；uninstall 后 invalid_token；明文 token 不出现于文件；损坏文件回退空 store；过期记录加载时清理 |
| FF001-T | FileBacked store 单测（load/persist/原子写/容错/过期清理） | 本片 | S01 | `flutter_debug_control_plane/android/src/test/kotlin/.../PluginDebugAuthStorePersistenceTest.kt`（新增） | tmpdir 下往返、截断 JSON 回退空、revokedAt/clientLabel 可空往返、并发 persist 不损坏 |

**BF vs FF 判断：归 FF（flutter plugin 原生实现），不归 BF。** 理由：本能力的实现端是 `flutter_debug_control_plane/android/` 的 Kotlin 原生代码（FlutterPlugin 生命周期 + filesDir），不触碰 `kotlin/` 纯 JVM core（DebugAuth.kt 零改动的约束已锁定），也不触碰 Python/Dart。参照 R002 先例（android plugin bridge 归 FF002），落点在同一模块的功能应编 FF。本片无 BF/BB/FB 编号产出：wire 协议、core Kotlin、Python 均零改动。

## 四、边界接口

- token 格式不变：`dcp_` + 64 hex（approve 生成逻辑零改动），Python 侧（S02）无感知。
- wire 协议零改动：/hello、/auth/request|status|claim 的请求/响应字节不变；持久化是纯 app 内部存储细节。
- `DebugAuthTokenRecord` 结构不变：tokenId/tokenHash/createdAt/expiresAt/revokedAt/clientLabel，JSON schema 字段一一对应，无新增字段。
- `PluginDebugAuthStore` 接口不变：新增类是实现，不是接口演进；`setAuthStoreForHost` 签名不变。
- 对 S03：`revoke(all=true)` 语义因持久化而自然增强（重启后 revoke 仍生效），无新接口。

## 五、结论

### 实现顺序建议

1. `FileBackedPluginDebugAuthStore`（装饰 InMemory + load/persist + 原子写 + 容错 + 过滤）及单测——纯新增，可独立验证。
2. `DebugControlPlaneFlutterPlugin.onAttachedToEngine` 的 processAuthStore 升级接线 + 注入路径回归（确保 setAuthStoreForHost 测试不被文件 store 污染）。
3. 真机/集成验收：冷重启 + install -r 场景（依赖 S02 的 Python 侧脚本或 adb 手工 curl）。

### 风险点

- **Context 时序**：companion 静态初始化无 Context，必须走 attach 时惰性升级；注意 attach 可能多次发生（多 engine），升级逻辑要幂等（已是 FileBacked 则跳过）。
- **并发写**：多 worker 线程同时 persist；用 store 内单锁 + 快照收集 + 固定 tmp 名 + rename 化解。反向风险是"写丢了 revoke"——被杀于 markRevoked 后 persist 前会复活已 revoke token，属可接受窗口（重启后重新 revoke 或过期自清）。
- **Instant 序列化**：必须 `Instant.toString()`/`Instant.parse()` 配对；`Date` 风格时间戳或 epoch 秒会造成与 wire 格式不一致及精度歧义。parse 失败单条按容错丢弃而非整体失败。
- 红线回归：`PluginDebugAuthPending`（含 tokenPlaintext/pairingCode）绝不进入 persist 路径——代码评审时盯死 persist 的数据源只来自 tokens map。
