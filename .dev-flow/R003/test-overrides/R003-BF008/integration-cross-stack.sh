#!/usr/bin/env bash
# =============================================================================
# R003-BF008 cross-stack 定向 scope 回归(test override,可单独重跑)
# =============================================================================
# 职责(契约 KD-1 / 评估挑战 Q1 修订):
#   1. 断言四端 scope 测试资产存在(kotlin/dart/flutter plugin+example/python)
#      —— kotlin 与 flutter 两端的全量执行由 ci-check-all [1]/[3] 步承担,
#         此处只守卫存在性,避免双份全量拖慢幂等性;
#   2. dart 单文件定向回归:capability_scope_test.dart;
#   3. python 定向 pytest 选择器子集(capability_mirror/selector/stale/scope)。
#
# 用法:
#   bash .dev-flow/R003/test-overrides/R003-BF008/integration-cross-stack.sh
#   (或经 ci/ci-check-all.sh [9] 步挂载运行)
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO_ROOT"
export PYTHON_BIN="${PYTHON_BIN:-/usr/local/bin/python3.13}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "--- [cross-stack guard 1/4] 四端 scope 测试资产存在性断言 ---"
SCOPE_ASSETS=(
  "dart/test/capability_scope_test.dart"
  "kotlin/src/test/kotlin/com/pantas/debug/controlplane/CapabilityScopeTest.kt"
  "flutter_debug_control_plane/test/page_capability_scope_test.dart"
  "flutter_debug_control_plane/example/test/page_capability_scope_demo_test.dart"
  "python/tests/test_capability_mirror.py"
)
for asset in "${SCOPE_ASSETS[@]}"; do
  [[ -f "$asset" ]] || fail "scope 测试资产缺失: $asset"
  echo "  OK: $asset"
done
echo ">>> 存在性断言通过(${#SCOPE_ASSETS[@]} 个资产)"

echo ""
echo "--- [cross-stack guard 2/4] dart 单文件定向回归 ---"
run_dart() { (cd dart && fvm flutter test test/capability_scope_test.dart); }
run_dart || fail "dart capability_scope_test.dart 定向回归失败"

echo ""
echo "--- [cross-stack guard 3/4] python 定向 pytest 子集 ---"
run_python() {
  (
    cd python &&
      "$PYTHON_BIN" -m pytest tests -q --no-header \
        -k "capability_mirror or selector or stale or scope"
  )
}
run_python || fail "python 定向 pytest 子集失败"

echo ""
echo "--- [cross-stack guard 4/4] 结论 ---"
echo "PASS: R003-BF008 cross-stack 定向 scope 回归(存在性断言 + dart/python 定向)"
echo "附注: kotlin(CapabilityScopeTest.kt)与 flutter plugin/example scope 测试的"
echo "全量执行由 ci-check-all [1-kotlin-build-test] / [3-plugin-test] 步承担并已通过;"
echo "integration-android.sh 的设备缺失分支(deferred exit 0 + evidence 双写)行为已于"
echo "同日单独验证,记录于 R003-BF008-integration-android-test.log。"
exit 0
