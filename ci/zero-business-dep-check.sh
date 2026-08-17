#!/usr/bin/env bash
# =============================================================================
# repo 级零业务依赖门(CI 五件套,R025 扩展)
# =============================================================================
#
# 用途
#   守护 control_plane repo 硬约束(dart + python + kotlin 三语言零业务依赖)。
#   debug_control_plane 只允许依赖: 标准库 + 声明依赖(pyproject/pubspec/gradle) + 自身。
#   任何 PR/commit 引入未声明的业务包 import,本门立即 FAIL。
#
# 五件套
#   [1/5] dart analyze       — dart package 静态分析(用 fvm flutter; pubspec 仅依赖
#                              flutter sdk,故 dart 包天然零外部业务依赖)
#   [2/5] python 依赖白名单   — AST 解析真实 import,只允许标准库 + pyproject 声明依赖
#                              + debug_control_plane 自身(精确,排除 docstring/注释误报)
#   [3/5] python ruff(致命级) — --select E9,F401,F811(语法错/未用 import/重复定义)
#   [4/5] kotlin 源码白名单   — grep kotlin/ + flutter_debug_control_plane/android/src/
#                              真实 import 行,禁 io.flutter(插件桥接层豁免)/androidx/
#                              com.host4/pantas 业务包;插件主源码的 io.flutter 是
#                              其存在理由(channel 桥),单独豁免文件清单管理
#   [5/5] kotlin gradle 白名单 — kotlin/build.gradle.kts 静态扫描 implementation/api
#                              坐标,非白名单依赖即 FAIL(对齐 [2/5] AST 模式)
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
# [1/5] dart analyze
# ============================================================================
echo "=== [1/5] dart analyze(dart package)==="
if [[ ! -d "$REPO_ROOT/dart" ]]; then
  echo "FAIL: $REPO_ROOT/dart 不存在" >&2
  exit 1
fi
pushd "$REPO_ROOT/dart" >/dev/null
fvm flutter analyze --no-fatal-infos
popd >/dev/null
echo "[1/5] dart analyze OK"
echo

# ============================================================================
# [2/5] python 依赖白名单(AST)
# ============================================================================
echo "=== [2/5] python 依赖白名单(AST 只允许标准库 + 声明依赖 + 自身)==="

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
print("[2/5] python 依赖白名单 OK(%d py 文件仅依赖标准库+声明依赖 %s)" % (
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
# [3/5] python ruff(致命级)
# ============================================================================
echo "=== [3/5] python ruff(致命级 E9/F401/F811)==="
pushd "$REPO_ROOT/python" >/dev/null
$PY_BIN -m ruff check \
  --select E9,F401,F811 \
  --no-cache \
  debug_control_plane/
popd >/dev/null
echo "[3/5] python ruff(致命级)OK"
echo

# ============================================================================
# [4/5] kotlin 源码 import 白名单(R025-BF004-3)
# ============================================================================
# 真实 import 行 grep(kotlin 无 AST 级工具链,但 import 语句本身语法固定,
# 行首 `import ` 前缀 + 词边界已排除注释/字符串;docstring 在 kotlin 是
# /** */ 块,内部 import 字样不会顶行首)。
#
# 允许的顶层组(四档 = 所在树 × 源码集,定义见下方变量):
#   kotlin/        : fi.iki.elonen(NanoHTTPD) java.* javax.* kotlinx.* org.json
#                    com.pantas.debug.controlplane(自身,词边界防 controlplaneX 绕过)
#   插件 android/  : 上述 + io.flutter.*(channel 桥是插件存在理由,豁免)
#   */src/test/*   : 上述 + org.junit.*(junit 是 testImplementation,
#                    main 源码 import 测试依赖属越界,不放行)
# 禁止:androidx.* / com.host4.* / pantas(除 com.pantas.debug.controlplane)/
#       其他一切未声明第三方
echo "=== [4/5] kotlin 源码 import 白名单(kotlin/ + 插件 android/src)==="

# 允许前缀以 `(\.|$)` 收尾:匹配「该包自身或子包」,不允许前缀拼接造新包名
# 四档 = 所在树(kotlin 核心/插件) × 源码集(main/test):
#   插件树追加 io.flutter(channel 桥是插件存在理由,豁免);
#   test 源码追加 org.junit(junit 是 testImplementation,main 源码 import
#   测试依赖属越界不放行;插件测试 double 仿造 MethodChannel 走插件档)。
COMMON_GROUPS='fi\.iki\.elonen|java|javax|kotlin|kotlinx|org\.json|com\.pantas\.debug\.controlplane'
KOTLIN_ALLOWED="^(${COMMON_GROUPS})(\.|$)"
KOTLIN_TEST_ALLOWED="^(${COMMON_GROUPS}|org\.junit)(\.|$)"
PLUGIN_ALLOWED="^(${COMMON_GROUPS}|io\.flutter)(\.|$)"
PLUGIN_TEST_ALLOWED="^(${COMMON_GROUPS}|io\.flutter|org\.junit)(\.|$)"

hits=()
while IFS= read -r f; do
  if [[ "$f" == flutter_debug_control_plane/* ]]; then
    if [[ "$f" == */src/test/* ]]; then allowed="$PLUGIN_TEST_ALLOWED"; else allowed="$PLUGIN_ALLOWED"; fi
  else
    if [[ "$f" == */src/test/* ]]; then allowed="$KOTLIN_TEST_ALLOWED"; else allowed="$KOTLIN_ALLOWED"; fi
  fi
  while IFS= read -r line; do
    # 提取 import 后的限定名(截到空白/通配/别名为止,保留点号)
    dep="$(printf '%s' "$line" | sed -E 's/^import +(static +)?//; s/[[:space:]].*$//; s/\*+$//')"
    [[ -z "$dep" ]] && continue
    [[ "$dep" =~ $allowed ]] || hits+=("$f  <- import $dep (允许清单外)")
  done < <(grep -hE '^import ' "$f")
done < <(cd "$REPO_ROOT" && find kotlin/src flutter_debug_control_plane/android/src -name '*.kt' | sort)

if (( ${#hits[@]:-0} > 0 )); then
  echo "FAIL: kotlin 侧含未声明依赖 import:" >&2
  printf '  %s\n' "${hits[@]}" >&2
  exit 1
fi
echo "[4/5] kotlin 源码 import 白名单 OK"

# ---------- [4b/5] kotlin 核心 FQN 绕过扫描 ----------
# M2:import 白名单只盯 `^import` 行,`java.util.concurrent.Executor` 这类
# 代码体内 FQN 使用可绕过(尤其 android/androidx/com.host4 的内联引用)。
# 只扫 kotlin/ 核心(插件层允许 android,不扫)。词边界匹配代码体内
# `\b(android|androidx|com\.host4)\.[A-Za-z]` —— 排除 import 行自身(上一轮
# 已覆盖)。保守策略:命中即 FAIL 并提示人工复核(注释/字符串里的合法提及
# 一并命中,宁可误报不漏报)。
fqn_hits=()
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  fqn_hits+=("$hit")
done < <(cd "$REPO_ROOT" && grep -rnE '(^|[^A-Za-z0-9_.])(android|androidx|com\.host4)\.[A-Za-z]' kotlin/src \
    --include='*.kt' | grep -v ':[0-9]*:import ' || true)

if (( ${#fqn_hits[@]} > 0 )); then
  echo "FAIL: kotlin 核心代码体内出现 android/androidx/com.host4 FQN 使用(可能为依赖绕过,须人工复核):" >&2
  printf '  %s\n' "${fqn_hits[@]}" >&2
  exit 1
fi
echo "[4b/5] kotlin 核心 FQN 绕过扫描 OK"
echo

# ============================================================================
# [5/5] kotlin gradle 依赖白名单(R025-BF004-3,对齐 [2/5] AST 模式)
# ============================================================================
echo "=== [5/5] kotlin gradle 依赖白名单(build.gradle.kts 静态扫描)==="

KOTLIN_GRADLE="$REPO_ROOT/kotlin/build.gradle.kts"
if [[ ! -f "$KOTLIN_GRADLE" ]]; then
  echo "FAIL: $KOTLIN_GRADLE 不存在" >&2
  exit 1
fi

# 允许的依赖坐标(精确到 group:artifact 并以 `(:|$)` 收尾 — 白名单按
# slice-2 §6.1 是 artifact 级,前缀放行会让 nanohttpd-evolution /
# junit5-engine 这类同前缀新包静默混入):
#   org.nanohttpd:nanohttpd / org.json:json / kotlinx-coroutines-{core,test,android}
#   / junit:junit / kotlin-stdlib
ALLOWED_GRADLE='^(org\.nanohttpd:nanohttpd|org\.json:json|org\.jetbrains\.kotlinx:kotlinx-coroutines-[a-z]+|junit:junit|org\.jetbrains\.kotlin:kotlin-stdlib)(:.+)?$'
FORBIDDEN_GROUPS='^(io\.flutter|androidx|com\.host4|pantas|com\.android)'

ghits=()
while IFS= read -r decl; do
  [[ -z "$decl" ]] && continue
  group="${decl%%:*}"
  if printf '%s' "$group" | grep -qE "$FORBIDDEN_GROUPS"; then
    ghits+=("$decl (禁止的业务/flutter/androidx 依赖)")
  elif ! printf '%s' "$decl" | grep -qE "$ALLOWED_GRADLE"; then
    ghits+=("$decl (非白名单声明依赖)")
  fi
done < <(grep -E '(implementation|api|testImplementation|compileOnly)\s*\(' "$KOTLIN_GRADLE" | grep -oE '"[^"]+"' | tr -d '"')

if (( ${#ghits[@]} > 0 )); then
  echo "FAIL: kotlin 核心含违规 gradle 依赖声明:" >&2
  printf '  %s\n' "${ghits[@]}" >&2
  exit 1
fi
echo "[5/5] kotlin gradle 依赖白名单 OK"
echo

# ============================================================================
echo "================================================================"
echo "PASS: control_plane repo 级零业务依赖门(五件套全过)"
echo "================================================================"
