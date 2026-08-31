---
date: 2026-08-31
type: integration
requirement_cycle: R004
topic: token-persistence
---

# token 持久化 — 集成账本（integration ledger）

> integration 摘要（manifest-first archive/design/plan 消费入口）。细节以
> 主分析 + 各 slice 为准。

## 能力汇总（integrate 后唯一编号）

| 编号 | 能力 | 端 | slice |
|---|---|---|---|
| FF001 | app 侧 FileBackedPluginDebugAuthStore + attach 升级接线 | flutter plugin Android | S01 |
| BF001 | Python FileTokenProvider + main() 注入 | python | S02 |
| FF002 | TTL 默认 1h → 7 天（604800 常量） | flutter plugin Android | S03 |
| BF002 | 验收脚本 install -r 改造 + 端到端 runner | test-override | S03 |

## 场景归属

- SCN-APP-TOKEN-SURVIVE-RESTART → FF001（S01 owns）
- SCN-PY-TOKEN-SURVIVE-RESTART → BF001（S02 owns）
- SCN-AUTOLOOP-ONE-APPROVE → FF002 + BF002（S03 owns,依赖 S01/S02）

## 跨片契约

- wire 协议零改动;token 格式 dcp_ 前缀不变;DebugAuthTokenRecord 结构不变。
- app 侧落盘仅 hash;python 侧明文 + 0600（两侧风险模型不同,均已拍板）。
- BF002 用例 3（install -r 后旧 token 200）失败定位 S01 层,不兜底。

## 编号修正留痕

- S03 原稿 FB001（标题）与 BF 判定矛盾且与 S02 BF001 撞号 → integrate 坍缩
  为 **BF002**（analysis review 确认无残留）。
