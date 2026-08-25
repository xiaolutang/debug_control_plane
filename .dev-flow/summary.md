# 项目变更摘要

## 2026-08-25

- 归档 R002 `flutter-auth-acceptance-app`：新增 Flutter 真实宿主验收 App，覆盖 App 侧授权弹窗、状态控制、请求日志和固定测试 capability。
- 补齐电脑端 Python acceptance runner 与 Android 真机 plugin/native bridge 验收路径，区分 setup failure、denied、expired、invalid token 与成功授权路径。
- 完成 `0.3.0` 四端发布：JitPack Kotlin、pub.dev Dart、pub.dev Flutter plugin、PyPI Python，并验证 main/tag CI 与 JitPack/pub/PyPI 可用。
- visual-verify 接入状态：R002 UI 任务仍以 Flutter widget/integration 稳定标识和人工真机证据为主；独立 visual-verify collector 未接入，作为后续技术债。

## 2026-08-20

- 初始化 xlfoundry runtime 软链、Codex 引导文档和代码地图。
- 补齐 `.dev-flow` 全局配置、架构宪法、功能地图和摘要。
