#!/usr/bin/env bash
# =============================================================================
# gradle 发布配置静态守卫(JitPack 发版通道前置条件)
# =============================================================================
#
# 用途
#   spike-b §1.4 实测硬约束:JitPack 线上构建跑 `./gradlew build
#   publishToMavenLocal`,子模块若未显式启用 maven-publish plugin +
#   声明 publication,publishToMavenLocal task 不存在 → 线上发布失败。
#   本门静态扫描(零 JDK 依赖,秒级)确认发版通道的 5 个前置条件:
#
#   [1/5] kotlin/build.gradle.kts 显式 maven-publish plugin
#   [2/5] kotlin/build.gradle.kts 声明 publication(create<MavenPublication>)
#   [3/5] java-library plugin 启用,保证 api/implementation 能正确进 POM
#   [4/5] 公开 ABI 依赖使用 api 暴露:NanoHTTPD + kotlinx-coroutines-core
#         (非 fi.iki.elonen:nanohttpd — 后者 Maven Central 缺 POM,spike-a 纠正)
#   [5/5] 根聚合器 settings.gradle.kts include(":kotlin") + 根 wrapper 存在
#         (JitPack 从 repo 根构建,tag 推送后走根 gradlew)
#
# 退出码
#   0 = PASS(发版前置条件齐)
#   1 = FAIL(任一条件缺失)
#
# 本地跑
#   bash ci/gradle-publish-check.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

KOTLIN_GRADLE="$REPO_ROOT/kotlin/build.gradle.kts"
ROOT_SETTINGS="$REPO_ROOT/settings.gradle.kts"

[[ -f "$KOTLIN_GRADLE" ]] || { echo "FAIL: missing $KOTLIN_GRADLE" >&2; exit 1; }

# --- [1/5] maven-publish plugin 显式启用 ------------------------------------
if grep -qE '^\s*`?maven-publish`?\s*$' "$KOTLIN_GRADLE"; then
  echo "[1/5] maven-publish plugin 显式启用 OK"
else
  echo "FAIL [1/5]: kotlin/build.gradle.kts 未显式启用 maven-publish plugin(spike-b §1.4:不启用则 JitPack publishToMavenLocal task 不存在)" >&2
  FAIL=1
fi

# --- [2/5] publication 声明 --------------------------------------------------
if grep -q 'create<MavenPublication>' "$KOTLIN_GRADLE"; then
  echo "[2/5] publication 声明(create<MavenPublication>)OK"
else
  echo "FAIL [2/5]: kotlin/build.gradle.kts 未声明 publication(create<MavenPublication>),JitPack 无构件可发布" >&2
  FAIL=1
fi

# --- [3/5] java-library plugin 启用 -----------------------------------------
if grep -qE '^\s*`?java-library`?\s*$' "$KOTLIN_GRADLE"; then
  echo "[3/5] java-library plugin 启用(api/implementation 发布语义)OK"
else
  echo "FAIL [3/5]: kotlin/build.gradle.kts 未启用 java-library plugin,api 依赖无法进入编译期 POM scope" >&2
  FAIL=1
fi

# --- [4/5] 公开 ABI 依赖 -----------------------------------------------------
if grep -q 'api("org.nanohttpd:nanohttpd:2.3.1")' "$KOTLIN_GRADLE" \
  && grep -q 'api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")' "$KOTLIN_GRADLE"; then
  echo "[4/5] 公开 ABI 依赖(NanoHTTPD/coroutines-core)作为 api 暴露 OK"
else
  echo "FAIL [4/5]: kotlin/build.gradle.kts 必须用 api 暴露 org.nanohttpd:nanohttpd:2.3.1 和 org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0;它们出现在公开父类/函数签名里" >&2
  FAIL=1
fi

# --- [5/5] 根聚合器 + 根 wrapper ---------------------------------------------
if grep -q 'include(":kotlin")' "$ROOT_SETTINGS"; then
  echo "[5/5] 根 settings.gradle.kts include(\":kotlin\") OK"
else
  echo "FAIL [5/5]: 根 settings.gradle.kts 未 include(\":kotlin\")(JitPack 从 repo 根构建)" >&2
  FAIL=1
fi
if [[ -x "$REPO_ROOT/gradlew" && -f "$REPO_ROOT/gradle/wrapper/gradle-wrapper.properties" ]]; then
  echo "[5/5] 根 gradle wrapper 存在(JitPack 推荐用 wrapper 构建)OK"
else
  echo "FAIL [5/5]: 根 gradlew / gradle/wrapper 缺失(JitPack 无 wrapper 时用其自带 gradle 版本,不可控)" >&2
  FAIL=1
fi

if (( FAIL )); then
  echo "FAIL: gradle 发布配置守卫未过" >&2
  exit 1
fi
echo "PASS: gradle 发布配置守卫(JitPack 前置条件 5 项全过;注意:R025-C 决策本次不打 tag,仅备好通道)"
