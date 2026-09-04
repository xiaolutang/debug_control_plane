---
date: 2026-09-04
type: integration
requirement_cycle: R006
topic: android-plugin-auth-policy
---

# Android 插件授权策略装配 API — 集成账本（integration ledger）

> integration 摘要（manifest-first archive/design/plan 消费入口）。single slice，细节以主分析为准。

## 能力汇总（integrate 后唯一编号）

| 编号 | 能力 | 端 | slice |
|---|---|---|---|
| BF001 | 插件 Kotlin 装配层 authPolicy 通道（ChannelProtocol + ensurePlane 策略装配 + fail-fast） | 插件 Android | S01 |
| FF001 | Dart 侧 plane.start authPolicy 参数（AuthPolicy 类型 + bridge 透传 + 接入文档） | 插件 Dart 面 | S01 |
| BF002 | authPolicy 装配跨栈测试（JVM 三策略 + e2e auto 直连） | 跨栈测试 | S01 |

## 场景归属

- SCN-PLUGIN-AUTH-POLICY-DECLARE（宿主声明策略）→ BF001 + FF001（S01 owns）
- SCN-PLUGIN-AUTH-AUTO-DIRECT（auto 策略 python 自动授权直连）→ BF001 + BF002（S01 owns；python 链路既有零改动，回归覆盖）
- SCN-PLUGIN-AUTH-DEFAULT-UI（default 不传=现状授权 UI 链）→ BF002 回归覆盖（S01 owns）

## 跨片契约

- `/auth/*` wire 协议零改动（PROTOCOL.md 冻结）。
- MethodChannel `plane.start` 参数表追加可选 `authPolicy`（默认 default=现状）；非法值 fail-fast `invalid_arguments`（channel 内层协议，向后兼容）。
- `none` 策略下 `/hello` 无 `authRequired` 字段 = core 无门既有语义（与纯 Dart 宿主一致，消除断裂点）。
- python 侧零改动（401→request→poll→claim 自动链已有）。

## 反向坍缩检测

无（三能力各自通过五项原子；无跨平面聚合节点）。

## 编号修正留痕

无。

## open issues

- 宪法「敏感调试能力必须统一经过授权门」的分层表述校准将在 design 阶段以 `architecture_md_updates: true` 提出（core 门不变量 vs 宿主策略决策权）；本分析已给出建议表述，待 design-review 评审。
