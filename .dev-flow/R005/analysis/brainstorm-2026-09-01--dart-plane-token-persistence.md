---
date: 2026-09-01
type: brainstorm
status: concluded
requirement_cycle: R005
topic: dart-plane-token-persistence
---

# dart-plane-token-persistence

## 结论
- 要做什么：dart core 补齐 token 存储管理能力（与 Kotlin plugin 侧同构）：`InMemoryDebugAuthStore` + `FileBackedDebugAuthStore`（hash 落盘/原子写/损坏回退/过期清理）；example `AcceptanceDebugAuthManager` 改为接受 store 注入并默认启用文件持久化；自测（dart 单测）+ iOS 模拟器集成测试（含 app 冷重启旧 token 200 用例）。
- 不做什么：plugin 的 ios/ 原生实现（另一个需求）；Web 平台；卸载清装场景；协议改动（/auth/* wire 契约零变更）；keychain/加密存储/第三方库。
- 关键约束：明文 token 永不落盘（只存 hash，对齐 Android 侧红线）；dart core 零新依赖（store 接收目录/文件路径参数，path_provider 只进 example）；TTL 默认 7 天对齐 R004；不引入 DataStore。
- 核心场景：iOS 模拟器/纯 Dart plane 路径上，app 冷重启或覆盖安装后 python 侧旧 token 免授权直连（弹窗只弹第一次）；未来 iOS 生产 app 直接复用包内能力。
- 待确认：无（TTL 7 天、目录由宿主传入已定）。

## 关键讨论
- 三落点取舍（dart core / example 内 / plugin 层）：选 dart core——包已有 dart:io 依赖（http_codec/transport），加文件 store 不破坏定位；example 内做会把能力困在验收 app；plugin 是 Android-only 层级错位。
- 现状事实：三端存储能力不对称——Kotlin plugin 有 InMemory+FileBacked，Python 有 FileTokenProvider，dart core 只有 `DebugAuthManager` 接口 + NoOp（把存储完全留给宿主，成为短板）。
- 效果对齐：与 Android 侧 R004 真机实测效果一致（冷重启/覆盖安装旧 token 200；卸载清装回首次授权=设计行为）；明文红线两侧一致（app 侧只 hash，python 侧 0600 明文）。
