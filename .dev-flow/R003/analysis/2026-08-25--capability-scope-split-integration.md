---
type: analysis-integration
status: integrated
requirement_cycle: R003
topic: capability-scope-split
date: 2026-08-25
---

# Capability Scope Split — Integration Ledger

## Slice Summary

| Slice | Owner | 状态 | 产物 |
|---|---|---|---|
| S01-protocol-scope-contract | SCN-SCOPE-CONTRACT, BF001, BF002 | completed | 协议字段、错误码、刷新信号 |
| S02-core-runtime-scope-registry | SCN-CORE-SCOPE-REGISTRY, BF003, BF004 | completed | Dart/Kotlin scope API、registry、unregister、hello |
| S03-flutter-plugin-page-lifecycle | SCN-FLUTTER-PAGE-LIFECYCLE, FF001, FB001 | completed | Flutter MethodChannel metadata、页面 helper/example |
| S04-python-mcp-scope-mirror | SCN-MCP-SCOPE-MIRROR, BF005, BF006 | completed | Python schema、MCP refresh、stale/gone 调用 |
| S05-acceptance-and-regression | SCN-SCOPE-ACCEPTANCE, BF007, BF008 | completed | fixture、单测、Android 集成验收 |

## Capability Ledger

| 编号 | trigger | responsibility | result | acceptance | independently_absent |
|---|---|---|---|---|---|
| BF001 | capability 注册或 `/hello` 聚合 | 定义 scope/page metadata 与默认值 | `/hello` 可表达 app/page 能力 | 旧 schema 缺省 app，新 schema 多 page 保真 | 无它则下游无法区分页面能力 |
| BF002 | 页面离开或镜像过期 | 定义 gone/expired 错误与刷新信号 | 控制端可收敛失效工具 | 错误码稳定，刷新后失效 tool 消失 | 无它则 scope 字段存在但 stale tool 不收敛 |
| BF003 | Dart/Kotlin capability 创建 | core API 表达 scope metadata | 旧 app 与新 page capability 都可注册 | page 缺 pageId 失败，旧能力兼容 | 无它则 registry 无法获得元数据 |
| BF004 | register/unregister/hello | scope-aware registry 与聚合 | 多 page 并存、精确解除注册 | `(scope,pageId,id)` 唯一，unregister 不误删 | 无它则页面生命周期无法落地 |
| FF001 | Flutter bridge register | MethodChannel 透传 scope metadata | native plugin 收到 pageId/pageName | 旧 payload app 默认，新 payload 保真 | 无它则 Flutter 页面能力无法到 native |
| FB001 | 页面进入/离开 | helper/example 管理 page capability 生命周期 | active 时可见，离开后不可见 | 多页面互不影响，plane 生命周期仍归宿主 | 无它底层可用但业务接入易错 |
| BF005 | Python 解析 `/hello` | CapabilitySchema 携带 scope/page metadata | MCP list_capabilities 返回 page 信息 | app 默认、多 page、pageName 保真 | 无它 MCP 看不到页面上下文 |
| BF006 | refresh 或旧 tool 调用 | tools/list_changed 与 stale page 错误处理 | MCP 工具列表最终收敛 | schema shrink 触发 changed，gone/expired 后刷新 | 无它 Python 会长期暴露旧 page tool |
| BF007 | 协议/API 变更 | 跨语言 fixture 与单测守卫 | 字段/错误/默认值不漂移 | ci-check-all 覆盖 Dart/Kotlin/Flutter/Python | 无它跨端容易字段分叉 |
| BF008 | Android example 集成 | 真机/集成生命周期验收 | 页面注册/解除在真实 runtime 可观测 | page A 离开不影响 page B/app | 无它无法证明 Android 集成链路 |

## Shared Contract Decisions

| 决策 | 结论 | 原因 |
|---|---|---|
| Scope 字段形态 | `/hello.registeredCapabilities[]` 顶层新增 `scope/pageId/pageName/scopeRevision` | 与现有平铺 schema 一致，Python/Dart/Kotlin 容易兼容解析。 |
| 默认 scope | 缺省等价 `app` | 保持旧 capability 和旧 fixture 可用。 |
| 唯一键 | app: `(app,id)`；page: `(page,pageId,id)` | 支持多个 active page 下同名 capability，不强制业务拼接 id。 |
| `pageId` 来源 | 业务传入，runtime 只校验非空/一致性 | 避免 control plane 引入业务页面依赖。 |
| `pageName` 语义 | 展示 metadata，不参与唯一性，不强制 tool id | 满足 MCP 可读性，同时不破坏工具稳定 id。 |
| gone/expired | 稳定 code：`page_capability_gone`、`capability_scope_expired` | 避免各端在 404/409/410 间自由漂移。 |
| 刷新策略 | 第一版以重新拉 `/hello` 为准，SSE 只提示 changed | 降低跨语言 diff 解释成本。 |

## Reverse Collapse Check

R003 的 10 个 capability 没有需要反向拆分的聚合节点：

- 协议字段与错误刷新分离：BF001 负责表达，BF002 负责失效收敛。
- core API 与 registry 行为分离：BF003 负责模型，BF004 负责状态流转。
- Flutter bridge 与业务可用 helper 分离：FF001 是基础设施，FB001 是页面场景。
- Python schema 与 MCP 调用收敛分离：BF005 负责镜像，BF006 负责动态列表/错误处理。
- 验收基础设施与 Android 集成分离：BF007 是跨语言回归，BF008 是真实运行验收。

## Integration Risks For Design

| 风险 | 影响 | design 必须明确 |
|---|---|---|
| 平铺 route first-match-wins | 多页面同路径 page capability 可能命中错误页面 | 是否引入 scope-aware dispatch 参数，或限制 page capability route path 冲突。 |
| `/state` 扁平 spread | 多 page state 同 key 覆盖 | page state 是否嵌套到 scope 结构，或暂不聚合 page state。 |
| Flutter bridge 旧 `capId` 唯一 | 多页面同名能力无法并存 | bridge/native registry 必须采用 scope-aware identity。 |
| MCP tool name 冲突 | provider 可能为多 page 生成同名 tool | tool 描述/输入参数/去重策略由 design 固化，不强制 pageName 改 id。 |
| stale 调用判定 | Python 本地和 App 端都可能发现 gone | Python 只做缓存校验与刷新，App debug plane 是最终授权/有效性边界。 |

## Consumer Refs

design 阶段应按以下顺序读取：

1. `.dev-flow/R003/analysis/2026-08-25--capability-scope-split-integration.md`
2. `.dev-flow/R003/analysis/2026-08-25--capability-scope-split.md`
3. S01-S05 slice 文件
4. `.dev-flow/R003/analysis/brainstorm-2026-08-25--capability-scope-split.md`

## Open Issues

- `scopeRevision` 是否以全局 capability manifest revision 还是单 page scope revision 表达，交给 design 定义。
- 旧 `unregister(id)` 的兼容行为建议只定位 app capability；page capability 使用 scoped unregister。
- 真机集成测试是否纳入默认 CI 取决于设备可用性；本地 evidence 可作为手动 integration gate。
