# 项目变更摘要

## 2026-09-01

- 归档 R005 `dart-plane-token-persistence`：R004 持久化的 Dart plane 补齐——iOS 模拟器/纯 Dart 宿主路径获得与 Android 原生 plane 同构的「授权弹窗只弹第一次」体验。
- dart core 新增 token 存储管理（BF001）：`DebugAuthStore` 抽象恰 5 方法 + `InMemoryDebugAuthStore`（map 键=tokenHash）+ `FileBackedDebugAuthStore` 装饰器（惰性 load/损坏回退空不抛/过期行 load 丢弃不回写/tmp+rename 原子写）；sha256 纯 Dart FIPS 180-4 手写（零新依赖红线，`debugAuthTokenHash` 公开别名）。
- example 接线（FF001）：`AcceptanceDebugAuthManager` 构造接受可选 store（缺省 InMemory）+ 校验路径 hash 索引化两处 + TTL 默认 15min→7d 对齐 R004；持久化挂载在 main() 装配层（DEC-R005-006：widget 测试 fake-async 无引擎插件,path_provider await 永不完成,实证后移出 startDartPlane）；expireToken 内存旁路 `_expiryOverrides`（DEC-R005-005,不混淆 expired/revoked 语义）。
- 集成测试（BF002）：iOS 模拟器 I1-I5 端到端（simctl terminate/relaunch 冷重启主断言：旧 Bearer /hello 200 authStatus=authorized 零弹窗；损坏文件自愈；TTL 604800s 窗口断言；wire 回归）；pytest 入口 endpoint 双通道 + session fixture skip 模式；驱动脚本 deferred 契约（模拟器不在场 device_required 白名单）。重跑复现 I1-I5 全 PASS;pytest 391 passed 13 skipped 0 error。
- 与 Kotlin 侧差异点（有意）：过期行 load 时丢弃且不回写（Kotlin 清理时回写）——I4 过期断言码因此为 invalid_token（load-discard 语义等价,已批准偏离）。
- visual-verify 接入状态：R005 FF001 domain=ui 但为纯接线任务（无新 UI 面,复用 R002 标识），visual-verify 不适用豁免；独立 collector（collectors/flutter/）仍未接入,与 R002/R003/R004 同作后续技术债。
- 归档 R004 `token-persistence`：token 生命周期从进程生命周期升级为跨进程持久化,授权弹窗只在首次出现(app 冷重启/覆盖安装/python 重停/token 过期不再人工介入)。
- app 侧(Kotlin plugin)`FileBackedPluginDebugAuthStore` 装饰器:hash 记录落 `filesDir/debug_auth_tokens.json`(tmp+rename 原子写,损坏回退空,过期清理回写);`onAttachedToEngine` 惰性升级 InMemory→FileBacked 零拷贝迁移;红线:明文 token 永不落盘(pending 组纯内存透传)。
- python 侧 `FileTokenProvider`(`~/.debug-control-plane/tokens.json`,os.open 0600 绕 umask + os.replace 原子替换):claim 自动落盘,Bearer 自动复用,401 三码(token_expired/token_revoked/invalid_token)联动清行;main() 注入。
- token TTL 默认 1h→7 天(`DEFAULT_TOKEN_TTL_SECONDS=604800` 挂 PluginDebugAuthManager.companion,显式 ttlSeconds 通道语义不变)。
- 验收脚本 fork R003-BF008 → R004 test-override 副本:uninstall 仅 `DELETE_AND_REINSTALL=1` 逃生门执行,安装统一 `install -r`,APK 未变快速路径保留(压制 HyperOS 安装弹窗与 auth 弹窗机制分工写入注释);端到端 runner 6 用例 + deferred 契约。
- iOS 模拟器集成验证(iPhone 16e 真实 Dart plane):BF001 全链路 4/4 场景 pass(授权落盘 0600/新进程免授权/过期清行+401 联动/wire 回归)+ 既有验收集 4 passed 零回归;FF001/FF002(Kotlin)iOS 无代码路径,android JVM 81 用例覆盖。
- 真机 deferred 债务:e2e 用例 1/2/3/6(设备 23116PN5BC 在场时经 `.dev-flow/R004/test-overrides/R004-BF002/integration-android.sh` 回收,用例 6 需 `DELETE_AND_REINSTALL=1` 单独轮次)。
- visual-verify 接入状态：R004 FF001/FF002 domain=ui 但为纯持久化/常量任务(无新 UI 面),visual-verify 由 evaluate subagent 以 DEFERRED 判定(无视觉面可采集);独立 collector(collectors/flutter/)未接入,与 R002/R003 同作后续技术债。

## 2026-08-27

- 归档 R003 `capability-scope-split`：capability 注册引入 app/page 双 scope 模型,page 级生命周期(进入注册/离开释放/gone 后 410 + refresh 提示)四端落地。
- 三方同构 scoped key:Kotlin `BridgeCapabilityIdentity` = Dart `_ScopedCapabilityKey` = Python `ScopedCapabilityKey`;scope 元数据镜像进 `/hello` `registeredCapabilities`(scope/pageId/scopeRevision)。
- scoped selector dispatch(`X-DCP-Capability-Id`/`Scope`/`Page-Id`/`Revision` 头):page gone 后带 selector 调用 410 `page_capability_gone`,无 selector 404;scope 过滤转发与陈旧工具刷新。
- 验收 app 新增 Page Scope Demo(page A/B 独立 route,AndroidNativePlane bridge 复用 host 真实注册,非 Android 走降级 demo channel 演示失败路径)。
- ci-check-all 新增 [9] r003-scope-cross-stack 步(存在性断言 + dart/python 定向回归);Android 真机三阶段验收脚本落地并完成真机回收(Xiaomi 14 Pro/Android 16:集成测试 8/8、三阶段 dump 语义、410 gone HTTP 直证)。
- visual-verify 接入状态：R003 ui 任务（FF001/FF002/FB001/FB002）以 Flutter widget 稳定标识 + 真机 uiautomator dump 三层证据为主（baseline owner R003-BF008 已真机回收）；独立 visual-verify collector（collectors/flutter/）未接入，FB001/FB002 visual_verify_status=UNCERTAIN → 由真机 dump 结构证据闭环，collector 接入作为后续技术债（与 R002 同）。

## 2026-08-25

- 归档 R002 `flutter-auth-acceptance-app`：新增 Flutter 真实宿主验收 App，覆盖 App 侧授权弹窗、状态控制、请求日志和固定测试 capability。
- 补齐电脑端 Python acceptance runner 与 Android 真机 plugin/native bridge 验收路径，区分 setup failure、denied、expired、invalid token 与成功授权路径。
- 完成 `0.3.0` 四端发布：JitPack Kotlin、pub.dev Dart、pub.dev Flutter plugin、PyPI Python，并验证 main/tag CI 与 JitPack/pub/PyPI 可用。
- visual-verify 接入状态：R002 UI 任务仍以 Flutter widget/integration 稳定标识和人工真机证据为主；独立 visual-verify collector 未接入，作为后续技术债。

## 2026-08-20

- 初始化 xlfoundry runtime 软链、Codex 引导文档和代码地图。
- 补齐 `.dev-flow` 全局配置、架构宪法、功能地图和摘要。
