---
module: debug_control_plane_dart_core
version: 1.0
date: 2026-09-01
tags: [dart, token, persistence, test]
type: design_test
status: designed
requirement_cycle: R005
source_analysis: .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence.md
source_design: .dev-flow/R005/analysis/2026-09-01--dart-plane-token-persistence-design.md
---

# dart plane token 持久化 — 测试设计

> 关联设计：[dart core + example 设计 1.0](2026-09-01--dart-plane-token-persistence-design.md)

## 1. 测试策略

| 层 | 工具 | 覆盖目标 |
|---|---|---|
| unit（dart core） | `flutter test`（dart/test） | BF001 store 行为 100%（roundtrip/损坏/过期/原子/红线/sha256 向量） |
| unit（example） | `flutter test` | FF001 hash 校验语义 + 既有授权用例零回归 |
| integration（iOS 模拟器） | python 断言脚本 + pytest + example app 真实 plane | BF002 冷重启免授权/损坏自愈/TTL/wire 回归 |

覆盖率要求：BF001 新增代码行 ≥90%（行为分支密集）；integration 关键链路（冷重启恢复、首次授权落盘）100%。

## 2. 测试场景矩阵

### dart core 单测（BF001，`dart/test/debug_auth_store_test.dart`）

| # | 场景 | 断言 |
|---|---|---|
| U1 | put→tokenByHash roundtrip | 存取一致；hash 键命中 |
| U2 | sha256 已知向量 | `sha256("abc")=ba7816bf...`、空串 `e3b0c442...`（NIST 向量） |
| U3 | 文件 roundtrip 跨实例 | 实例 A putToken→persist；新实例 B load 后 tokenByHash 命中 |
| U4 | 损坏回退 | 预置截断/非法 JSON/version=2 文件 → load 空 map 不抛 |
| U5 | 过期清理 | expiresAt < now 的行 load 时丢弃且不回写文件 |
| U6 | markRevoked 持久化 | revokedAt 落盘；跨实例 load 后状态保留 |
| U7 | removeExpired | 过期行被移除、有效行保留 |
| U8 | 原子写 | persist 后无 .tmp 残留；目标文件始终完整 JSON |
| U9 | 红线：明文不落盘 | putToken(token:"tok_secret_1") 后读文件字节，`tok_secret_1` 不出现 |
| U10 | 0 权限假设 | 不做权限断言（目录由宿主给，沙箱内即可；区别于 python 侧 0600） |

### example 单测（FF001，改造 `acceptance_plane_test.dart`）

| # | 场景 | 断言 |
|---|---|---|
| E1 | hash 校验授权链 | claim 拿 token → Bearer 敏感路由 200 → 伪造 token 401 invalid_token |
| E2 | store 注入 | 注入 InMemory store 的 manager 与默认行为等价 |
| E3 | TTL 默认 7d | claim 响应 expiresAt-now ∈ [604790,604810]s |
| E4 | 既有用例适配 | R002 时代全部授权用例（approve/deny/expire/clear）在新 hash 校验下零回归 |
| E5 | 持久层/索引无明文 | claim 后 store 内存 map 键与文件字节均无明文 token 串（map 键=hash；`_activeToken` UI 便利引用按 D3 收敛版明确豁免） |

### 集成测试（BF002，iOS 模拟器）

| # | 场景 | 断言 | 环境要求 |
|---|---|---|---|
| I1 | 首次授权双侧落盘 | claim 200；app 沙箱 debug_auth_tokens.json 存在且无明文；python tokens.json 有行 | 模拟器 booted |
| I2 | **app 冷重启免授权**（核心） | 杀 app 进程→重启→旧 Bearer /hello 200 authorized，零弹窗 | 同上 |
| I3 | 损坏自愈 | 篡改 app 侧文件为非法 JSON→重启→401→新授权链可达→claim 后文件恢复合法 JSON | 同上 |
| I4 | TTL 生效 | claim expiresAt delta≈604800s；构造过期→401 token_expired→重授权可达 | 同上 |
| I5 | wire 回归 | no-token 401/forged 401/claim 无 token 泄漏字段 | 同上（复用 R004 S4 断言） |

## 3. 验收标准

与 design 第 7 节 A1-A7 一一对应（A1↔U1-U10、A2↔E1-E5、A3↔I2、A4↔I3、A5↔I4、A6↔I5、A7↔U9+I1+依赖检查）。全绿才可 commit；I2 是本 RC 价值主断言。

## 4. 集成测试方案

- **拓扑**：macOS 宿主跑 python 断言脚本 ←HTTP→ iOS 模拟器内 example app（Dart plane loopback，复用 R004-ios 脚本的 endpoint 发现：driver 输出 plane port）。
- **启动/清理**：每轮 `fvm flutter build ios --simulator --debug` + install + launch driver（auto-approve 模式）；轮间清 python tokens.json + app 文档目录（除 I3/I4 故意保留/篡改）。冷重启=kill 进程再 launch（保留安装与沙箱）。
- **真实 vs Mock**：零 mock——真实 Dart plane、真实文件系统、真实 python FileTokenProvider 读盘。
- **故障注入**：I3 直接写坏 app 沙箱内 JSON；I4 篡改 expiresAt 为过去时间。

## 5. 测试数据与 Mock 实现策略

- fixture：sha256 NIST 向量常量；伪造 token 串 `forged-token-*`。
- 无 mock 框架引入；python 侧复用 `tests/` 既有 httpx 模式。
- 隔离：每用例独立 requestId/clientNonce；文件操作全部在 tmp/沙箱目录。

## 6. 暂不测试

- Web 平台（dart:io 不可用，不支持）。
- 并发写竞争（单 isolate 顺序语义，D7；多 isolate 场景出界）。
- 清装场景（OS 行为，R004 已在 Android 真机验证语义）。
- 磁盘满/IO 异常路径（Kotlin 版同出界；损坏回退已覆盖主恢复语义）。
