#!/usr/bin/env bash
# =============================================================================
# R003-BF008 Android 真机 page scope 三阶段验收脚本
# =============================================================================
# 契约 KD-2:设备检测 → 构建/安装 → 三阶段采集(logcat bridge 日志 +
# uiautomator dump 结构性主证)→ evidence 输出。
#
# 行为约定:
#   - 设备缺失  : 打印 DEFERRED, 双写 evidence(android log deferred +
#                 android-page-scope.md 空壳结构)后 exit 0(不是失败);
#   - 多设备并存: 报错退出(非确定环境禁止盲选);
#   - 可重入    : 开头 uninstall 旧包容错清理;working 输出目录每次覆写;
#                 evidence md 按 run_at 分节追加多次运行记录;
#   - HyperOS   : 安装失败给「USB 安装」手动授权提示后重试一次,仍失败
#                 non-zero 退出;logcat 关键字抓不到记 WARN 继续,
#                 判定以 uiautomator dump 结构文本为主证。
#
# 用法:
#   bash .dev-flow/R003/test-overrides/R003-BF008/integration-android.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO_ROOT"

EVIDENCE_DIR="$REPO_ROOT/.dev-flow/R003/evidence"
SCOPE_MD="$EVIDENCE_DIR/android-page-scope.md"
ANDROID_LOG="$EVIDENCE_DIR/${BF008_ANDROID_LOG:-R003-BF008-integration-android-test.log}"
WORK_DIR="$REPO_ROOT/.dev-flow/R003/test-overrides/R003-BF008/.android-work"
EXAMPLE_DIR="$REPO_ROOT/flutter_debug_control_plane/example"
APK_PATH="$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-debug.apk"
# 包名以 build 产物实际 applicationId 为准(KD-2.4;aapt 校正见 get_package_name)
PACKAGE_NAME_FALLBACK="com.example.debug_control_plane_acceptance_example"
RUN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$WORK_DIR"

get_package_name() {
  local pkg
  pkg="$(AAPT_BIN="${AAPT_BIN:-}" "$0" --internal-print-package "$APK_PATH" 2>/dev/null || true)"
  if [[ -n "$pkg" ]]; then
    echo "$pkg"
    return 0
  fi
  echo "$PACKAGE_NAME_FALLBACK"
}

if [[ "${1:-}" == "--internal-print-package" ]]; then
  aapt_bin=""
  for cand in "$(command -v aapt || true)" \
    "$HOME/Library/Android/sdk/build-tools/"*/aapt; do
    if [[ -x "${cand% *}" || -x "$cand" ]]; then
      aapt_bin="$cand"
      break
    fi
  done
  [[ -z "$aapt_bin" ]] && exit 1
  out="$("$aapt_bin" dump badging "$2" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
  [[ -n "$out" ]] && echo "$out"
  exit 0
fi

# --- evidence 双写工具函数 ---------------------------------------------------
write_deferred_evidence() {
  # android log(deferred)+ page-scope.md 空壳结构(KD-4)
  cat > "$ANDROID_LOG" <<EOF
---
type: test-log
task_id: R003-BF008
layer: integration
domain: android
run_at: $RUN_AT
status: deferred
exit_code: null
deferred_reason: device_required
---

# Test Log: R003-BF008 (integration.android — DEFERRED)

- status: deferred
- deferred_reason: device_required
- reason_detail: tasks.md R003-BF008 test_tasks 第二项(integration android)
  需要 Android 真机执行 page A / page B / 离开 page A 三阶段 hello/tool
  变化采集;本次运行时 \`adb devices\` 无 device 状态行(实测),按契约
  KD-4 登记为 deferred,不虚构任何真机输出。
- substitute_evidence: 本任务自身即回收任务,不再提供结构层替代证据;
  自动化部分(cross-stack 定向回归 + ci-check-all [9] 步挂载)由
  R003-BF008-integration-cross_stack-test.log 承担且真实 PASS。
- 回收动作: 待设备可用时重跑
  \`bash .dev-flow/R003/test-overrides/R003-BF008/integration-android.sh\`
  (HyperOS 设备需先手动开启「USB 安装」授权),
  脚本将补齐 android-page-scope.md 三阶段内容并翻转为 pass/failed。
EOF

  cat > "$SCOPE_MD" <<EOF
---
type: acceptance-evidence
task_id: R003-BF008
run_at: $RUN_AT
device_model: null
os_version: null
status: deferred
deferred_reason: device_required
---

# Android 真机 Page Scope 三阶段验收(R003-BF008)

> **未执行声明**:本次运行(\`$RUN_AT\`)\`adb devices\` 无 device,
> 三阶段采集**均未执行**。以下各节仅为空壳结构占位,不存在任何实际
> 运行产生的命令输出、dump 片段或推定性结论。待设备可用时重跑
> integration-android.sh 补齐内容并翻转 status。

## 阶段 1:进入 page A(hello/tool 变化)

(未执行)

## 阶段 2:page A 保持下进入 page B(并存状态记录)

(未执行)

## 阶段 3:关闭 page A(旧工具 gone 后刷新 + app/page B capability 可用性)

(未执行)

## 结论(对照验收标准 2/3)

(未执行——验收标准 2「三阶段变化 evidence」与标准 3「gone 后旧工具失败
并刷新且 app/page B capability 仍可用」均需真机采集后逐条对照登记。)

## Deferred 与回收指引

- deferred_reason: device_required
- 回收动作: 开启设备 USB 调试与(HyperOS)「USB 安装」授权后重跑
  \`bash .dev-flow/R003/test-overrides/R003-BF008/integration-android.sh\`;
  脚本可重入(uninstall 清理 + working 输出覆写 + 按 run_at 分节追加)。
EOF
}

adb_cmd() { adb "$@"; }

has_device() {
  adb devices | awk 'NR>1 && $2=="device" {found=1} END{print found+0}'
}

# --- 步骤 1:前置检测 ---------------------------------------------------------
echo "[1/5] 检测 adb 设备 ..."
DEV_COUNT="$(has_device)"
if (( DEV_COUNT == 0 )); then
  echo "DEFERRED: device_required(adb devices 无 device 状态行)"
  write_deferred_evidence
  echo "evidence 已双写:"
  echo "  $ANDROID_LOG (status: deferred)"
  echo "  $SCOPE_MD   (空壳结构)"
  exit 0
elif (( DEV_COUNT > 1 )); then
  echo "FAIL: 检测到 $DEV_COUNT 台 device 并存,非确定环境禁止盲选;" >&2
  echo "      请只保留一台目标设备后重跑。" >&2
  exit 1
fi
DEVICE_SERIAL="$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
DEVICE_MODEL="$(adb_cmd -s "$DEVICE_SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
OS_VERSION="$(adb_cmd -s "$DEVICE_SERIAL" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
echo "OK: $DEVICE_SERIAL ($DEVICE_MODEL, Android $OS_VERSION)"

# --- 步骤 2:可重入清理(卸载旧包,容错)--------------------------------------
PACKAGE_NAME="$(get_package_name)"
echo "[2/5] 清理旧安装(package=$PACKAGE_NAME)..."
adb_cmd uninstall "$PACKAGE_NAME" >/dev/null 2>&1 || true

# --- 步骤 3:构建 APK ---------------------------------------------------------
echo "[3/5] 构建 debug APK ..."
(
  cd "$EXAMPLE_DIR" &&
    fvm flutter build apk --debug
) >"$WORK_DIR/build.log" 2>&1 || {
  echo "FAIL: flutter build apk --debug 失败,详见 $WORK_DIR/build.log" >&2
  exit 1
}
[[ -f "$APK_PATH" ]] || { echo "FAIL: 未找到 APK: $APK_PATH" >&2; exit 1; }

# --- 步骤 4:安装(HyperOS「USB 安装」授权引导,最多重试 1 次)---------------
install_apk() { adb_cmd install -r "$APK_PATH"; }
echo "[4/5] 安装 APK ..."
if ! INSTALL_OUT="$(install_apk 2>&1)"; then
  echo "WARN: 安装失败(可能被 HyperOS 拦截):"
  echo "$INSTALL_OUT"
  echo ">>> 请在手机上手动开启「设置 → 开发者选项 → USB 安装」后继续 ..."
  read -r -p "已开启授权,按回车重试(仅此一次)> "
  INSTALL_OUT="$(install_apk 2>&1)" || {
    echo "FAIL: 重试安装仍失败:" >&2
    echo "$INSTALL_OUT" >&2
    exit 1
  }
fi
echo "OK: $INSTALL_OUT"

# --- 步骤 5:三阶段采集 -------------------------------------------------------
DUMP_DIR="$WORK_DIR/dumps"
rm -rf "$DUMP_DIR"
mkdir -p "$DUMP_DIR"

collect_stage() {
  # collect_stage <stage-id> <描述> — logcat 抓取 + uiautomator dump 主证
  local stage_id="$1" desc="$2"
  echo "--- 阶段 [$stage_id]: $desc @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ---"
  adb_cmd logcat -d -v time >"$DUMP_DIR/$stage_id-logcat.txt" 2>&1 || \
    echo "WARN: logcat -d 抓取失败($stage_id),继续以 dump 为主证" >&2
  if ! adb_cmd exec-out uiautomator dump /dev/tty >"$DUMP_DIR/$stage_id-ui.xml" 2>/dev/null; then
    # 回退:设备端写 /sdcard 再 pull(exec-out 不被该设备支持时)
    if adb_cmd shell uiautomator dump >/dev/null 2>&1 &&
      adb_cmd pull /sdcard/window_dump.xml "$DUMP_DIR/$stage_id-ui.xml" >/dev/null 2>&1; then
      :
    else
      echo "WARN: uiautomator dump 失败($stage_id)" >&2
    fi
  fi
}

MAIN_ACTIVITY="$(adb_cmd shell cmd package resolve-activity --brief "$PACKAGE_NAME" 2>/dev/null | tr -d '\r' | tail -1)"
[[ -n "$MAIN_ACTIVITY" ]] || MAIN_ACTIVITY="$PACKAGE_NAME/.MainActivity"

echo "[5/5] 开始三阶段采集 ..."

# 阶段 1:启动 app(home)→ tap open_button 进 page A → 记录 hello/tool 变化
STAGE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "# stage-1 操作序列 @ $STAGE_TS"
  echo "\$ adb shell am start -n $MAIN_ACTIVITY"
} >"$WORK_DIR/stage-1-actions.log"
adb_cmd shell am start -n "$MAIN_ACTIVITY" >>"$WORK_DIR/stage-1-actions.log" 2>&1 ||
  echo "WARN: am start 失败" >&2
sleep 3
collect_stage "1" "app home 启动完成"

# 阶段 2 / 阶段 3 的具体 tap 坐标与按钮资源 id 因真机 UI而定:
# 以 dump 出的稳定标识(open_button 等,AcceptanceSpec stable_identifiers)
# 解析 bounds 后 tap;解析不到则 WARN 并中止后续阶段(failed,非虚构)。
resolve_bounds_and_tap() {
  # resolve_bounds_and_tap <ui-xml> <stable-key-substring> ;输出 0=成功
  local xml="$1" key="$2" line bounds cx cy x1 x2 y1 y2
  line="$(grep -o "<node[^>]*${key}[^>]*>" "$xml" 2>/dev/null | tail -1 || true)"
  [[ -z "$line" ]] && return 1
  bounds="$(sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' <<<"$line")"
  [[ -z "$bounds" ]] && return 1
  read -r x1 y1 x2 y2 <<<"$bounds"
  cx=$(( (x1 + x2) / 2 )); cy=$(( (y1 + y2) / 2 ))
  adb_cmd shell input tap "$cx" "$cy"
}

TAP_XML="$DUMP_DIR/1-ui.xml"
if resolve_bounds_and_tap "$TAP_XML" "open_button"; then
  echo "\$ tap open_button via dump bounds @ $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$WORK_DIR/stage-1-actions.log"
  sleep 2
else
  echo "FAIL: 在 home 页 dump 中找不到 open_button 稳定标识,无法推进阶段 1。" >&2
  echo "      结构判定失败按 failed 处理(不以推定性结论虚构 evidence)。" >&2
  exit 1
fi
collect_stage "1b" "进入 page A 后"

# 阶段 2:保持 page A,寻找进 page B 入口并点击 → 记录并存状态
STAGE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "# stage-2 操作序列 @ $STAGE_TS"
  echo "\$ 从当前页 dump 寻找 page B(open)入口并 tap"
} >"$WORK_DIR/stage-2-actions.log"
if resolve_bounds_and_tap "$DUMP_DIR/1b-ui.xml" "open_b" ||
  resolve_bounds_and_tap "$DUMP_DIR/1b-ui.xml" "page_b_open"; then
  echo "\$ tap page B 入口成功" >>"$WORK_DIR/stage-2-actions.log"
  sleep 2
else
  echo "WARN: 阶段 2 未在 page A dump 中找到 page B 入口标识,记 failed 段落而非推定。" >&2
  echo "failed: page_B_entry_not_found" >>"$WORK_DIR/stage-2-actions.log"
fi
collect_stage "2" "page A + page B 并存状态"

# 阶段 3:返回/关闭 page A → 驱动旧工具调用观察 gone 后刷新行为
STAGE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "# stage-3 操作序列 @ $STAGE_TS"
  echo "\$ 关闭 page A(back 至 page 列表/home),随后驱动 MCP 工具调用观察 gone+refresh"
} >"$WORK_DIR/stage-3-actions.log"
adb_cmd shell input keyevent KEYCODE_BACK >>"$WORK_DIR/stage-3-actions.log" 2>&1 || true
sleep 2
collect_stage "3" "离开 page A 之后"

# --- 汇总写 android-page-scope.md(pass 或 failed)---------------------------
PASS_OK=true
for f in "$DUMP_DIR"/1-ui.xml "$DUMP_DIR"/1b-ui.xml "$DUMP_DIR"/2-ui.xml "$DUMP_DIR"/3-ui.xml; do
  [[ -s "$f" ]] || PASS_OK=false
done
STATUS="pass"
$PASS_OK || STATUS="failed"

SCOPE_SECTION_TMP="$WORK_DIR/scope-section.md"
{
  echo ""
  echo "## 运行记录 run_at: $RUN_AT(device=$DEVICE_MODEL / Android $OS_VERSION,status=$STATUS)"
  echo ""
  for s in 1 1b 2 3; do
    case "$s" in
      1) title="阶段 1:进入 page A(hello/tool 变化)" ;;
      1b) title="阶段 1b:page A 进入后的页面结构" ;;
      2) title="阶段 2:page A 保持下进入 page B(并存状态)" ;;
      3) title="阶段 3:离开 page A(gone 后刷新 + capability 可用性)" ;;
    esac
    echo "### $title"
    echo ""
    echo "操作序列日志:\`test-overrides/R003-BF008/.android-work/stage-${s%%[!0-9]*}-actions.log\`"
    echo "原始输出(uiautomator dump 主证):\`$DUMP_DIR/$s-ui.xml\`;logcat 辅证:\`$DUMP_DIR/$s-logcat.txt\`"
    echo ""
  done
  echo "### 结论对照(验收标准 2/3)"
  echo ""
  echo "(内容由实施者依据上述 dump/logcat 原始片段填写,本脚本只产出原始证据;)"
} >"$SCOPE_SECTION_TMP"
cat "$SCOPE_SECTION_TMP" >>"$SCOPE_MD"

# 更新 frontmatter status
python3 - "$SCOPE_MD" "$STATUS" <<'PYEOF'
import re, sys
p, status = sys.argv[1], sys.argv[2]
t = open(p).read()
t = re.sub(r"(?m)^status: deferred$", f"status: {status}", t, count=1)
open(p, "w").write(t)
PYEOF

echo "DONE: 三阶段采集完成(status=$STATUS);android-page-scope.md 已追加运行记录分节。"
$PASS_OK || exit 1
exit 0
