---
date: 2026-09-01
type: integration
requirement_cycle: R005
topic: dart-plane-token-persistence
---

# dart plane token 持久化 — 集成账本（integration ledger）

> integration 摘要（manifest-first archive/design/plan 消费入口）。single slice，细节以主分析为准。

## 能力汇总（integrate 后唯一编号）

| 编号 | 能力 | 端 | slice |
|---|---|---|---|
| BF001 | dart core token 存储管理（InMemory + FileBacked 装饰器 + sha256 纯 Dart） | dart core | S01 |
| FF001 | example AcceptanceDebugAuthManager store 注入 + TTL 7 天对齐 | example app | S01 |
| BF002 | dart plane 持久化集成测试（iOS 模拟器，冷重启旧 token 200） | 跨栈测试 | S01 |

## 场景归属

- SCN-DART-TOKEN-PERSIST → BF001 + FF001 + BF002（S01 owns）
- SCN-DART-PLANE-FIRST-AUTH（现状链，零改动回归）→ BF002 覆盖回归（S01 owns）

## 跨片契约

- `/auth/*` wire 契约零改动；token `dcp_` 前缀不变。
- app 侧明文 token 永不落盘（文件只含 sha256 hex 的 tokenHash）；与 Android 侧 R004 红线一致。
- 文件 schema `{version:1, tokens:[...]}` 与 Kotlin 版同构但相互独立（不同端不同文件，不共享）。
- dart core 零新依赖：sha256 纯 Dart 手写；store 路径参数化（path_provider 只进 example）。

## 编号修正留痕

无。
