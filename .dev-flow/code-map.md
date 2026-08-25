# 代码地图（code-map）

> AI 进项目的代码索引页。按模块→目录→关键文件记录一句话职责。
> AI 先读本文件，再按需读取源码；⚠ 待确认项必须人工复核。

## &#x2E;github

### 目录结构

- `.github/workflows/ci.yml` — GitHub Actions CI gate mirrors the repo seven step local check flow with Java Flutter Python and fvm shim setup

## Project 根目录

### 目录结构

- `README.md` — Project overview documenting module layout dependency invariant distribution versions and integration guide links
- `build.gradle.kts` — Root Gradle aggregator repository configuration for Kotlin module builds and JitPack plugin resolution

## dart

### 目录结构

- `dart/lib/src/route_failure.dart` — Dart routing failure type converted by ControlPlane into stable HTTP error responses
