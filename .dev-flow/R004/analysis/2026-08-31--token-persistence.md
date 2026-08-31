---
date: 2026-08-31
type: analysis
requirement_cycle: R004
topic: token-persistence
manifest: manifest.json
slices: 3
---

# token 持久化 — R004 主分析（integrated ledger）

> 源：brainstorm-2026-08-31（已结题）+ 3 片 slice 分析（S01 app store / S02 python
> provider / S03 TTL+脚本）。本文档是全局能力 ledger 与整合结论;细节以各 slice
> 文档为准。

## ScopeInventory（两轮后判定）

- **分类**：sliced（3 片）——跨 flutter plugin Android / python 包 / 验收脚本
  三个实现端、两类场景 owner;Kotlin core 与 wire 协议零改动。
- **核心场景**：
  - SCN-APP-TOKEN-SURVIVE-RESTART（S01 owns）
  - SCN-PY-TOKEN-SURVIVE-RESTART（S02 owns）
  - SCN-AUTOLOOP-ONE-APPROVE（S03 owns,依赖 S01+S02）
- **明确出界**：卸载清装场景、debug 构建预置 token、release CI 守卫、
  iOS/纯 Dart 路径、keyring/加密存储。

## 全局能力 ledger（integrate 后唯一编号表）

| 编号 | 能力 | 实现端 | slice | 关键落点 | 验收要点 |
|---|---|---|---|---|---|
| FF001 | app 侧 token 持久化 store（FileBackedPluginDebugAuthStore，装饰 InMemory + attach 惰性升级接线） | flutter plugin Android 原生 | S01 | `PluginDebugAuth.kt`（新增类）+ `DebugControlPlaneFlutterPlugin.kt`（onAttachedToEngine 用 applicationContext 幂等升级 processAuthStore） | 冷重启/install -r 后旧 token /hello 200;uninstall 后 invalid_token;**明文 token 不出现于文件**;损坏回退空;过期记录加载即清 |
| FF001-T | FileBacked store 单测 | 同上 | S01 | `PluginDebugAuthStorePersistenceTest.kt`（新增） | tmpdir 往返/截断 JSON 回退空/可空字段往返/并发 persist 不损坏 |
| BF001 | Python FileTokenProvider + main() 注入 | python | S02 | `mcp_plane/token_provider.py`（新）+ `server.py` main 注入 | save→新实例 get roundtrip;**0600 权限（os.open 绕 umask）**;过期 get 返 None;损坏回退空;clear 同步删盘;401 三码联动 |
| BF001-T | provider 单测 | python | S02 | `tests/test_token_provider.py`（新） | roundtrip/权限/过期（过去/未来/Z 后缀/非法）/损坏/clear 删盘 |
| FF002 | TTL 默认 1h → 7 天 | flutter plugin Android | S03 | `PluginDebugAuth.kt`（提常量 604800）+ 默认值回归用例 | 不传 ttl → expiresAt=now+604800;显式 ttl 通道不回归;**现有 fixtures 无 3600 硬编码（已排查,零同步）** |
| BF002 | 验收脚本 install -r 改造 + 端到端验收场景 | test-override 脚本 + python runner | S03 | `.dev-flow/R004/test-overrides/R004-BF002/integration-android.sh`（fork R003-BF008）+ runner | 用例 3（install -r 后旧 token 200）主断言;用例 6 逃生门;deferred 双写沿用 R003 模式 |

**编号判定记录**（integrate 坍缩）：
- S03 原稿标题 FB001、判定文字 BF——冲突修正为 **BF002**（S02 已占 BF001）。
- FF001/FF002 归 FF：实现端是 flutter plugin 的 Android 原生模块（R002 FF002 先例）,
  Kotlin 纯 JVM core 零改动。
- BF002 归 BF：端到端集成验收（R003-BF008 先例）,非 UI。

## 反向坍缩复验（integration check）

- 唯一性:FF001/FF002/BF001/BF002 无跨片重号（S03 修正后）。
- 覆盖:三个场景全部有 owner;S03 显式声明依赖 S01/S02,失败定位规则明确
  （用例 3 失败 → S01 层,不兜底）。
- 红线复验:两侧落盘物均不含明文于 app 侧（app 存 hash;python 明文+
  0600,用户已确认）;wire 协议零改动（expiresAt 本是动态语义）。
- 依赖顺序:S01、S02 可并行;S03 依赖两者。

## 端到端验收用例总表（BF002 执行时展开）

1. 首次授权 → token 双侧落盘（app hash + python 明文）
2. app 冷重启（force-stop + start）→ 同 token 200【真机】
3. install -r 覆盖安装 → 同 token 200【真机,主断言】
4. python 重启（新进程）→ 不重新 auth【真机】
5. 过期 token → 401 → 自动重新授权
6. DELETE_AND_REINSTALL=1 → 等价首次【真机,逃生门】

## 结论（实现顺序）

1. S01 FF001 + FF001-T（store + 接线 + 单测）
2. S02 BF001 + BF001-T（provider + 注入 + 单测）——与 1 并行
3. S03 FF002（TTL 常量 + 回归）→ BF002（脚本 fork + runner + 真机回收 deferred）

风险登记：Context 时序幂等 / 并发 persist / Instant ISO 序列化配对 /
umask-0600 竞态 / 'Z' 后缀 py310 兼容（各 slice 文档已展开对策）。
