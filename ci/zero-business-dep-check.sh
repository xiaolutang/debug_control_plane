#!/usr/bin/env bash
# =============================================================================
# repo 级零业务依赖门(CI 三件套)
# =============================================================================
#
# 用途
#   守护 control_plane repo 硬约束(dart + python 双语言零业务依赖)。
#   debug_control_plane 只允许依赖: 标准库 + 声明依赖(pyproject/pubspec) + 自身。
#   任何 PR/commit 引入未声明的业务包 import,本门立即 FAIL。
#
# 三件套
#   [1/3] dart analyze       — dart package 静态分析(用 fvm flutter; pubspec 仅依赖
#                              flutter sdk,故 dart 包天然零外部业务依赖)
#   [2/3] python 依赖白名单   — AST 解析真实 import,只允许标准库 + pyproject 声明依赖
#                              + debug_control_plane 自身(精确,排除 docstring/注释误报)
#   [3/3] python ruff(致命级) — --select E9,F401,F811(语法错/未用 import/重复定义)
#
# 退出码
#   0 = PASS(repo 当前零未声明业务依赖)
#   1 = FAIL(任一套件不通过)
#
# 本地跑
#   bash ci/zero-business-dep-check.sh
#
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY_BIN="${PYTHON_BIN:-/usr/local/bin/python3.13}"

# ---------- 工具自检 ----------
if ! command -v fvm >/dev/null 2>&1; then
  echo "FAIL: 未找到 fvm(系统 Flutter 是 OHOS 分支,不可用于 dart analyze)" >&2
  exit 1
fi
if [[ ! -x "$PY_BIN" ]]; then
  echo "FAIL: 未找到 python3.13($PY_BIN)" >&2
  exit 1
fi

echo "REPO_ROOT=$REPO_ROOT"
echo "PY_BIN=$PY_BIN"
echo

# ============================================================================
# [1/3] dart analyze
# ============================================================================
echo "=== [1/3] dart analyze(dart package)==="
if [[ ! -d "$REPO_ROOT/dart" ]]; then
  echo "FAIL: $REPO_ROOT/dart 不存在" >&2
  exit 1
fi
pushd "$REPO_ROOT/dart" >/dev/null
fvm flutter analyze --no-fatal-infos
popd >/dev/null
echo "[1/3] dart analyze OK"
echo

# ============================================================================
# [2/3] python 依赖白名单(AST)
# ============================================================================
echo "=== [2/3] python 依赖白名单(AST 只允许标准库 + 声明依赖 + 自身)==="

# 用 AST 只解析真实 import / import-from 语句,注释、docstring、字符串字面量、
# logger 名等一律不命中——避免反向证明注释触发误报。允许清单 = 标准库 +
# pyproject 声明依赖 + debug_control_plane 自身;任何未声明的业务包 import 即 FAIL。
PY_AST_CHECK='
import ast, pathlib, sys
# 允许的外部依赖(须与 pyproject.toml [project].dependencies 保持同步)
declared = {"mcp", "httpx", "anyio"}
allowed = set(sys.stdlib_module_names) | declared | {"debug_control_plane"}
root = pathlib.Path("debug_control_plane")
hits = []
for f in sorted(root.rglob("*.py")):
    try:
        tree = ast.parse(f.read_text(encoding="utf-8"), filename=str(f))
    except SyntaxError as e:
        hits.append((str(f), "<syntax-error: %s>" % e))
        continue
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for n in node.names:
                top = n.name.split(".")[0]
                if top not in allowed:
                    hits.append((str(f), "import %s (非标准库/非声明依赖)" % n.name))
        elif isinstance(node, ast.ImportFrom) and node.module:
            if node.level and node.level > 0:
                continue  # 相对 import(from .xxx,包内模块互引),合法跳过
            top = node.module.split(".")[0]
            if top not in allowed:
                hits.append((str(f), "from %s import ... (非标准库/非声明依赖)" % node.module))
if hits:
    print("FAIL: python control_plane 含未声明的外部依赖(只允许标准库+声明依赖):", file=sys.stderr)
    for f, why in hits:
        print("  %s  <- %s" % (f, why), file=sys.stderr)
    sys.exit(1)
print("[2/3] python 依赖白名单 OK(%d py 文件仅依赖标准库+声明依赖 %s)" % (
    sum(1 for _ in root.rglob("*.py")), sorted(declared)))
'

if [[ ! -d "$REPO_ROOT/python/debug_control_plane" ]]; then
  echo "FAIL: $REPO_ROOT/python/debug_control_plane 不存在" >&2
  exit 1
fi
pushd "$REPO_ROOT/python" >/dev/null
$PY_BIN -c "$PY_AST_CHECK"
popd >/dev/null
echo

# ============================================================================
# [3/3] python ruff(致命级)
# ============================================================================
echo "=== [3/3] python ruff(致命级 E9/F401/F811)==="
pushd "$REPO_ROOT/python" >/dev/null
$PY_BIN -m ruff check \
  --select E9,F401,F811 \
  --no-cache \
  debug_control_plane/
popd >/dev/null
echo "[3/3] python ruff(致命级)OK"
echo

# ============================================================================
echo "================================================================"
echo "PASS: control_plane repo 级零业务依赖门(三件套全过)"
echo "================================================================"
