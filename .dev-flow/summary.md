# 项目变更摘要

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
