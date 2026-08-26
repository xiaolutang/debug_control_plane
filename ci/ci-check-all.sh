#!/usr/bin/env bash
# =============================================================================
# R025 CI 全量守卫编排(kotlin build+test / dart test / python pytest /
# 零业务依赖 / fixture 契约 + 发布前置)
# =============================================================================
#
# 用途
#   R025-BF004-3 的 CI 主入口:把跨语言三端测试 + 静态守卫串成一条命令,
#   .github/workflows/ci.yml 与本地共用同一入口(本地跑过 = CI 会过,
#   除 GitHub-hosted runner 的 fvm/python 路径差异 — workflow 注入
#   fvm shim + PYTHON_BIN=python3.13,见 ci/README.md「CI 接入」)。
#
# 套件(按依赖顺序)
#   [1] kotlin build + test        — ./gradlew build(root aggregator,76+ 测试)
#   [2] dart test                  — dart/ 黄金 fixture 两端断言(72+ 测试)
#   [3] flutter plugin test        — flutter_debug_control_plane/(26+ Dart
#                                    测试)
#   [4] flutter android JVM test   — flutter_debug_control_plane/android
#                                    standalone Gradle testDebugUnitTest
#   [5] python pytest              — python/tests/(317+ 测试,含 BF003-2
#                                    cross-lang 真实起 JVM 交叉验证)
#   [6] zero-business-dep-check.sh — dart analyze + python AST 白名单 + ruff
#                                    + [4/5]kotlin gradle 白名单(R025 扩展)
#   [7] protocol-version-guard.sh  — protocolVersion 四点同值守卫
#   [8] gradle-publish-check.sh    — JitPack 发版前置条件静态守卫
#   [9] r003-scope-cross-stack     — R003 scope 跨语言定向回归守卫(test
#                                    override:存在性断言 + dart/python 定向;
#                                    page/capability scope 全量由 [1][2][3][5]
#                                    步承担,见 R003-BF008 契约 KD-1)
#
# 环境要求
#   - JDK 17(kotlin jvmToolchain)
#   - fvm stable(系统 Flutter 是 OHOS 分支不可用;CI runner 由 workflow 注入 shim)
#   - python3.13(默认 /usr/local/bin/python3.13,可 PYTHON_BIN=... 覆盖 —
#     与 zero-business-dep-check.sh 同一覆盖约定,runner 注入 PYTHON_BIN=python3.13)
#     + pip install -e python/[test]
#
# 退出码
#   0 = 全过;非 0 = 第一个失败套件的退出码
#
# R003 scope 标注(R003-BF008):page/capability scope 回归覆盖 —
#   dart capability_scope_test.dart → [2];kotlin CapabilityScopeTest → [1];
#   flutter plugin/example page_capability_scope_test → [3];
#   python test_capability_mirror/selector/stale → [5];定向守卫 → [9]。
#
# 本地跑
#   bash ci/ci-check-all.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# python 解释器:沿用 zero-business-dep-check.sh 的 PYTHON_BIN 覆盖约定
# (本地默认 /usr/local/bin/python3.13;GitHub runner 无该路径,workflow 注入
#  PYTHON_BIN=python3.13 — 否则步骤 4 在线上必挂,「本地跑过 = CI 会过」失效)
export PYTHON_BIN="${PYTHON_BIN:-/usr/local/bin/python3.13}"

PLUGIN_OVERRIDE="$REPO_ROOT/flutter_debug_control_plane/pubspec_overrides.yaml"
cleanup_plugin_override() {
  rm -f "$PLUGIN_OVERRIDE"
}
trap cleanup_plugin_override EXIT

write_plugin_local_override() {
  cat > "$PLUGIN_OVERRIDE" <<'YAML'
dependency_overrides:
  debug_control_plane:
    path: ../dart
YAML
}

run_step() {
  local name="$1"; shift
  echo ""
  echo "================================================================"
  echo ">>> [$name] $*"
  echo "================================================================"
  "$@"
  local rc=$?
  if (( rc != 0 )); then
    echo "FAIL: [$name] 退出码 $rc" >&2
    exit $rc
  fi
  echo ">>> [$name] OK"
}

# --- [1] kotlin build + test(root aggregator)--------------------------------
run_step "1-kotlin-build-test" ./gradlew build

# --- [2] dart 核心 package test ---------------------------------------------
run_step "2-dart-test" bash -c 'cd dart && fvm flutter test'

# --- [3] flutter 插件 Dart 桥接 test ----------------------------------------
write_plugin_local_override
run_step "3-plugin-test" bash -c 'cd flutter_debug_control_plane && fvm flutter test'
cleanup_plugin_override

# --- [4] flutter 插件 Android JVM test --------------------------------------
run_step "4a-fetch-flutter-artifacts" bash flutter_debug_control_plane/tool/fetch_flutter_artifacts.sh
run_step "4-plugin-android-jvm-test" bash -c 'cd flutter_debug_control_plane/android && ../../kotlin/gradlew -p . testDebugUnitTest'

# --- [5] python pytest -------------------------------------------------------
run_step "5-python-pytest" bash -c 'cd python && "$PYTHON_BIN" -m pytest tests -q --no-header'

# --- [6] 零业务依赖门(五件套)------------------------------------------------
run_step "6-zero-business-dep" bash ci/zero-business-dep-check.sh

# --- [7] protocolVersion 跨语言一致性 ---------------------------------------
run_step "7-protocol-version" bash ci/protocol-version-guard.sh

# --- [8] JitPack 发布前置条件 ------------------------------------------------
run_step "8-gradle-publish-check" bash ci/gradle-publish-check.sh

# --- [9] R003 scope 跨语言定向回归守卫(R003-BF008)---------------------------
run_step "9-r003-scope-cross-stack" \
  bash .dev-flow/R003/test-overrides/R003-BF008/integration-cross-stack.sh

echo ""
echo "================================================================"
echo "PASS: R025 CI 全量守卫(9 步全过)"
echo "================================================================"
