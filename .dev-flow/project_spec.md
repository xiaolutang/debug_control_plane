# 项目概述

## 基本信息

- **项目名称**：debug_control_plane
- **创建时间**：2026-08-20
- **状态**：in_progress
- **负责人**：tangxiaolu

## 目标

提供跨产品复用的 debug control plane 基础设施，让业务 App 通过通用协议暴露调试能力，并通过 Python MCP adapter 连接 AI 调试工作流。

## 技术栈

- Kotlin JVM core
- Dart package
- Flutter Android plugin
- Python package with MCP adapter and device discovery
- HTTP/SSE debug protocol

## 硬约束

- control plane 保持零业务依赖。
- 协议变更必须跨语言同步并更新 fixtures。
- CI 全量门以 `ci/ci-check-all.sh` 为入口。
