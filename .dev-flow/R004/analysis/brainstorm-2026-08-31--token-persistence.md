---
date: 2026-08-31
type: brainstorm
status: concluded
requirement_cycle: R004
topic: token-persistence
---

# token 持久化——AI 自动化循环授权只弹一次

## 结论

- 要做什么：让 debug auth token 活得比进程长——app 侧 `PluginDebugAuthStore`
  持久化实现（hash 记录落 app 数据目录）、Python 侧持久化 TokenProvider
  （明文 token 落 `~/.debug-control-plane/tokens.json`，0600）、token TTL 默认
  1h → **7 天**、验收脚本 uninstall+install 改 `adb install -r`。
- 目标场景：AI 自动化编码验证循环（反复覆盖安装 + app/Python 重启 + 长会话），
  授权弹窗只弹第一次，其后任何一环单独发生都不再需要人介入。
- 不做什么：卸载清装场景（uninstall 抹 app 数据，明确不支持）、debug 构建
  预置 token、release CI 守卫、iOS/纯 Dart 路径（dart core auth store 仍
  NoOp/宿主自管）、协议改动（/auth/* wire 契约零变更）。
- 关键约束：
  - App 侧明文 token 永不落盘（`DebugAuthTokenRecord` 只含 hash）——红线不动。
  - 零业务依赖 + 极简依赖纪律：不引入 DataStore/加密库，单文件 JSON 实现。
  - Kotlin core `DebugAuth.kt` 零改动；改动集中在 flutter plugin Android 侧
    store 实现、python 包新增 FileTokenProvider、dart 验收 app 注入点。
  - 归属版本线 0.5.0。
- 核心场景（验收即按此断言）：
  1. approve → app 冷重启 → 同 token 请求仍 200（store 从盘恢复）。
  2. `adb install -r` 覆盖安装 → 同 token 仍可用。
  3. Python 重启 → 从 tokens.json 恢复，不重新走 auth 链。
  4. token 7 天后过期 → 自动回到未授权态（非报错）。
- 待确认：无（TTL 7 天、客户端明文存放、0.5.0 归属均已拍板）。

## 关键讨论

- 卸载场景被用户明确排除：「重新安装没问题就行，不用管卸载的场景」——
  不为清装引入 debug 预置 token/信任列表模型，避免复杂化。
- 存储设计：app 侧存 hash 索引（安全边界在 app 内），Python 侧存明文
  （开发机文件 + 0600，用户确认可接受）——两侧风险模型不同故策略不同。
- 脚本配套：`install -r` 是 app 侧持久化生效的前提（清装会连 token 记录
  一起抹掉）；`DELETE_AND_REINSTALL=1` 保留为强制清装逃生门。
- TTL 通道已存在（approve 的 ttlSeconds 参数），提默认值不动弹窗 UI。
