---
date: 2026-08-25
type: brainstorm
status: concluded
requirement_cycle: R003
topic: capability-scope-split
---

# Capability Scope Split

## 结论
- 要做什么：把调试 capability 拆成应用级 `app` 与页面级 `page`，让控制端能区分全局能力和当前页面/路由上下文能力。
- 不做什么：不把页面能力做成业务页面 SDK，不引入业务依赖，不在第一版实现复杂页面树调试 UI。
- 关键约束：保持现有 capability 注册/路由兼容；未声明 scope 的旧 capability 默认视为 `app`；Python MCP tools 不能长期暴露已离开页面的能力。
- 核心场景：App 启动后全局能力常驻；页面进入时注册 page capability；页面离开时 unregister；控制端刷新 tools 或调用时得到稳定 gone/expired 语义。
- 已确认：允许多个 page scope 同时活跃；`pageId` 可由业务传入；MCP 可以展示 `pageName` 辅助识别，但 tool id 不强制改为页面名称。

## 关键讨论
- 推荐允许多个 page scope 同时存在，以兼容 Flutter 嵌套路由、弹窗、tab 和多 Navigator。
- 推荐 capability id 保持业务可读，scope metadata 单独携带 `scope=page`、`pageId`、可选 `pageName`，避免把 pageId 硬拼进 id。
- 推荐 Python MCP 侧在 capability manifest 变化时刷新 tools；调用已离开的 page capability 返回稳定错误并触发二次刷新。
- 第一版应覆盖 Dart core、Kotlin core、Flutter plugin、Python mirror 四端协议一致性，并提供 Flutter example 页面级能力样例。
