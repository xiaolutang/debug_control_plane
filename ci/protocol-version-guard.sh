#!/usr/bin/env bash
# =============================================================================
# protocolVersion 跨语言一致性守卫
# =============================================================================
#
# 用途
#   protocolVersion=1 是跨语言硬常量(PROTOCOL.md §6 — 独立于各包版本线
#   dart 0.1.x / python 0.1.x / kotlin 0.2.0,协议未变就不 bump)。
#   本门静态断言三端声明 + 黄金 fixture 四处同值,任何一端单方面改值
#   立即 FAIL(防「契约改了一端忘改另一端」的长期漂移)。
#
# 检查点(4 处)
#   1. Kotlin  kotlin/.../ControlPlane.kt      const val PROTOCOL_VERSION: Int = 1
#   2. Dart    dart/lib/src/control_plane.dart  const int kDebugControlPlaneProtocolVersion = 1
#   3. Fixture fixtures/hello.json              "protocolVersion": 1
#   4. Fixture fixtures/discovery-python.json   hello_handshake.protocolVersion == 1
#   (python 端无独立常量 — 它按字段解析 data["protocolVersion"],值由
#    服务端决定;BF003-2 test_cross_lang_kotlin_plane.py 已运行时断言 ==1,
#    此处静态只守服务端 + fixture。)
#
# 退出码
#   0 = PASS(四点同值)
#   1 = FAIL(drift / 文件缺失)
#
# 本地跑
#   bash ci/protocol-version-guard.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED="${EXPECTED_PROTOCOL_VERSION:-1}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 与 zero-business-dep-check.sh 同一覆盖约定(本地 /usr/local/bin/python3.13,
# GitHub runner 由 workflow 注入 PYTHON_BIN=python3.13)—— 判活收敛在
# ci/lib.sh resolve_py_bin(绝对路径走 -x,PATH 命令名走 command -v,
# CI 第四红的根因:本脚本残留旧 `[[ -x ]]` 写法对命令名恒 false)。
# shellcheck source=ci/lib.sh
source "$(dirname "$0")/lib.sh"
PY_BIN="$(resolve_py_bin)"

KOTLIN_CONST="$REPO_ROOT/kotlin/src/main/kotlin/com/pantas/debug/controlplane/ControlPlane.kt"
DART_CONST="$REPO_ROOT/dart/lib/src/control_plane.dart"
HELLO_FIXTURE="$REPO_ROOT/fixtures/hello.json"
DISCOVERY_FIXTURE="$REPO_ROOT/fixtures/discovery-python.json"

[[ -f "$KOTLIN_CONST" ]]      || fail "missing $KOTLIN_CONST"
[[ -f "$DART_CONST" ]]        || fail "missing $DART_CONST"
[[ -f "$HELLO_FIXTURE" ]]     || fail "missing $HELLO_FIXTURE"
[[ -f "$DISCOVERY_FIXTURE" ]] || fail "missing $DISCOVERY_FIXTURE"

# --- 1/4 Kotlin: const val PROTOCOL_VERSION: Int = 1 -----------------------
KOTLIN_VAL="$(grep -oE 'const val PROTOCOL_VERSION: Int = [0-9]+' "$KOTLIN_CONST" | grep -oE '[0-9]+$' | head -1)"
[[ -n "$KOTLIN_VAL" ]] || fail "kotlin PROTOCOL_VERSION 常量未找到(ControlPlane.kt)"
echo "kotlin  PROTOCOL_VERSION              = $KOTLIN_VAL"

# --- 2/4 Dart: const int kDebugControlPlaneProtocolVersion = 1 -------------
DART_VAL="$(grep -oE 'const int kDebugControlPlaneProtocolVersion = [0-9]+' "$DART_CONST" | grep -oE '[0-9]+$' | head -1)"
[[ -n "$DART_VAL" ]] || fail "dart kDebugControlPlaneProtocolVersion 常量未找到(control_plane.dart)"
echo "dart    kDebugControlPlaneProtocolVersion = $DART_VAL"

# --- 3/4 fixtures/hello.json: "protocolVersion": 1 --------------------------
# 跳过 _ 前缀元数据键(_fixture_meta.hard_constraints 里也提到 "1"),
# 只取根级 protocolVersion 字段(python json 解析,免手写 JSON 提取)。
HELLO_VAL="$("$PY_BIN" -c "
import json, sys
data = json.load(open('$HELLO_FIXTURE'))
root = {k: v for k, v in data.items() if not k.startswith('_')}
v = root.get('protocolVersion')
print(v if isinstance(v, int) else '')
")"
[[ -n "$HELLO_VAL" ]] || fail "fixtures/hello.json 根级 protocolVersion 整数字段未找到"
echo "fixture hello.json protocolVersion     = $HELLO_VAL"

# --- 4/4 fixtures/discovery-python.json: hello_handshake.protocolVersion ----
DISCOVERY_VAL="$("$PY_BIN" -c "
import json
data = json.load(open('$DISCOVERY_FIXTURE'))
v = data.get('hello_handshake', {}).get('protocolVersion')
print(v if isinstance(v, int) else '')
")"
[[ -n "$DISCOVERY_VAL" ]] || fail "fixtures/discovery-python.json hello_handshake.protocolVersion 整数字段未找到"
echo "fixture discovery-python protocolVersion = $DISCOVERY_VAL"

# --- 同值守卫 ---------------------------------------------------------------
if [[ "$KOTLIN_VAL" != "$EXPECTED" || "$DART_VAL" != "$EXPECTED" \
   || "$HELLO_VAL" != "$EXPECTED" || "$DISCOVERY_VAL" != "$EXPECTED" ]]; then
  fail "protocolVersion drift: kotlin=$KOTLIN_VAL dart=$DART_VAL hello=$HELLO_VAL discovery=$DISCOVERY_VAL (expected all=$EXPECTED)"
fi

echo "PASS: protocolVersion=$EXPECTED (kotlin/dart/hello.json/discovery-python.json 四点一致)"
