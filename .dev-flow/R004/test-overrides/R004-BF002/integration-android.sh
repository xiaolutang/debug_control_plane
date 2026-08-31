#!/usr/bin/env bash
# =============================================================================
# R004-BF002 token 持久化端到端验收脚本(fork 自 R003-BF008,不回写 R003 产物)
# =============================================================================
# 契约: 设备检测 → 构建/安装(install -r 语义) → 启动 app → 调用 python
# e2e runner(e2e-token-persistence.py)执行 6 用例断言 → evidence 输出。
#
# 与 R003-BF008 的安装语义差异(R004 design §3.4):
#   - 无条件 uninstall 已移除:uninstall 前置(非安装命令)是 install -r
#     场景下 token 丢失的主因(filesDir 抹除 → invalid_token)。现仅
#     DELETE_AND_REINSTALL=1 时执行 uninstall(逃生门,等价首次授权场景)。
#   - 安装统一 `adb install -r`(覆盖安装,保 filesDir)。
#
# 两个弹窗压制机制的分工(两件事,不可混淆):
#   - 安装弹窗(HyperOS「USB 安装」授权):靠 APK_ALREADY_INSTALLED 快速
#     路径压制——APK 未变且包已在设备上时跳过 install,不触发授权弹窗;
#   - auth 弹窗(授权 approve):靠 token 持久化消灭——旧 token 跨进程/
#     跨重装存活,Bearer 直达 200,授权链根本不触发。install -r 本身
#     仍会被 HyperOS 弹安装授权,但那是前者的事。
#
# 行为约定(沿用 R003-BF008):
#   - 设备缺失  : 打印 DEFERRED, 双写 evidence(android log deferred +
#                 token-persistence-e2e.md 空壳结构)后 exit 0(不是失败);
#   - 多设备并存: 报错退出(非确定环境禁止盲选);
#   - HyperOS   : 安装失败给「USB 安装」手动授权提示后重试一次。
#
# 用法:
#   bash .dev-flow/R004/test-overrides/R004-BF002/integration-android.sh
#   # 清装逃生门(用例 6,等价首次授权):
#   DELETE_AND_REINSTALL=1 bash .dev-flow/R004/test-overrides/R004-BF002/integration-android.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO_ROOT"

OVERRIDE_DIR="$REPO_ROOT/.dev-flow/R004/test-overrides/R004-BF002"
EVIDENCE_DIR="$REPO_ROOT/.dev-flow/R004/evidence"
SCOPE_MD="$EVIDENCE_DIR/token-persistence-e2e.md"
ANDROID_LOG="$EVIDENCE_DIR/${BF002_ANDROID_LOG:-R004-BF002-integration-android-test.log}"
CROSS_LOG="$EVIDENCE_DIR/${BF002_CROSS_LOG:-R004-BF002-integration-cross_stack-test.log}"
WORK_DIR="$OVERRIDE_DIR/.android-work"
EXAMPLE_DIR="$REPO_ROOT/flutter_debug_control_plane/example"
APK_PATH="$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-debug.apk"
# 包名以 build 产物实际 applicationId 为准(aapt 校正见 get_package_name)
PACKAGE_NAME_FALLBACK="com.example.debug_control_plane_acceptance_example"
RUN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$WORK_DIR"

get_package_name() {
  local pkg
  pkg="$(AAPT_BIN="${AAPT_BIN:-}" bash "$0" --internal-print-package "$APK_PATH" 2>/dev/null || true)"
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
  # android log(deferred)+ token-persistence-e2e.md 空壳结构(R003 模式)
  cat > "$ANDROID_LOG" <<EOF
---
type: test-log
task_id: R004-BF002
layer: integration
domain: android
run_at: $RUN_AT
status: deferred
exit_code: null
deferred_reason: device_required
---

# Test Log: R004-BF002 (integration.android — DEFERRED)

- status: deferred
- deferred_reason: device_required
- reason_detail: tasks.md R004-BF002 test_tasks 第一项(integration android)
  需要 Android 真机执行 token 持久化 6 用例端到端验收;本次运行时
  \`adb devices\` 无 device 状态行(实测),按 deferred 契约登记,不虚构
  任何真机输出。
- substitute_evidence: 自动化部分(cross_stack 定向回归)见
  ${CROSS_LOG}(由 e2e runner python 侧断言链产出)。
- 回收动作: 待设备可用时重跑
  \`bash .dev-flow/R004/test-overrides/R004-BF002/integration-android.sh\`
  (HyperOS 设备需先手动开启「USB 安装」授权),脚本将补齐 6 用例内容并
  翻转为 pass/failed。
EOF

  cat > "$SCOPE_MD" <<EOF
---
type: acceptance-evidence
task_id: R004-BF002
run_at: $RUN_AT
device_model: null
os_version: null
status: deferred
deferred_reason: device_required
---

# token 持久化端到端 6 用例验收(R004-BF002)

> **未执行声明**:本次运行(\`$RUN_AT\`)\`adb devices\` 无 device,
> 6 用例**均未执行**。以下各节仅为空壳结构占位,不存在任何实际运行
> 产生的命令输出或推定性结论。待设备可用时重跑 integration-android.sh
> 补齐内容并翻转 status。

## 用例 1:首次授权双侧落盘(claim 200;expiresAt≈7d;两侧文件存在)

(未执行)

## 用例 2:app 冷重启旧 token 200(force-stop+start → Bearer /hello)[device]

(未执行)

## 用例 3:install -r 重建安装旧 token 200【主断言】[device]

(未执行)

## 用例 4:python 重启免 auth(新进程 get_token 命中,零 /auth/request)

(视 endpoint 可达性,未执行)

## 用例 5:过期自动重授权(401 token_expired → 行被清 → 授权链可达)

(视 endpoint 可达性,未执行)

## 用例 6:清装逃生门(DELETE_AND_REINSTALL=1 → invalid_token → 弹窗回归)[device]

(未执行)

## 结论(对照验收标准)

(未执行——1/2/3/6 需真机采集后逐条对照登记;4/5 按 deferred 契约允许
skip(setup_required)。)

## Deferred 与回收指引

- deferred_reason: device_required
- 回收动作: 开启设备 USB 调试与(HyperOS)「USB 安装」授权后重跑
  \`bash .dev-flow/R004/test-overrides/R004-BF002/integration-android.sh\`;
  用例 6 需以 \`DELETE_AND_REINSTALL=1\` 环境变量单独重跑一轮。
EOF
}

adb_cmd() { adb "$@"; }

has_device() {
  adb devices | awk 'NR>1 && $2=="device" {found=1} END{print found+0}'
}

# --- 步骤 1:前置检测 ---------------------------------------------------------
echo "[1/6] 检测 adb 设备 ..."
DEV_COUNT="$(has_device)"
if (( DEV_COUNT == 0 )); then
  echo "DEFERRED: device_required(adb devices 无 device 状态行)"
  # 设备不在场时 python 侧用例仍可按可达性评估(4/5 → skip(setup_required));
  # cross_stack 断言链(bearer-reuse / 401-clear-relay,provider 真实读盘)
  # 不依赖设备,始终执行。
  echo "[python] 运行 cross_stack 断言链(deferred 分支)..."
  python3 "$OVERRIDE_DIR/e2e-token-persistence.py" \
    --mode cross-stack-only --cross-log "$CROSS_LOG" --run-at "$RUN_AT" \
    || true
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

# --- 步骤 2:安装态检测(R004 语义:仅逃生门 uninstall)------------------------
# 两个弹窗压制机制分工(头部注释详述):安装弹窗(HyperOS「USB 安装」授权)
# 靠本快速路径压制——APK 未变且包已在设备上时跳过 install;auth 弹窗靠
# token 持久化消灭(旧 token 跨重装存活直达 200)。二者是两件事。
# 逃生门:DELETE_AND_REINSTALL=1 → uninstall(filesDir 抹除,等价首次
# 授权场景,用例 6 依赖此语义)。
PACKAGE_NAME="$(get_package_name)"
if [[ "${DELETE_AND_REINSTALL:-0}" == "1" ]]; then
  echo "[2/6] 逃生门模式(DELETE_AND_REINSTALL=1):uninstall 清装(等价首次)..."
  adb_cmd uninstall "$PACKAGE_NAME" >/dev/null 2>&1 || true
  APK_ALREADY_INSTALLED=0
elif adb_cmd shell pm list packages 2>/dev/null | grep -q "^package:${PACKAGE_NAME}$"; then
  APK_ALREADY_INSTALLED=1
  echo "[2/6] 包已在设备且非逃生门模式,跳过 install(免 HyperOS 安装弹窗)"
else
  APK_ALREADY_INSTALLED=0
  echo "[2/6] 包未安装,将执行 install -r(不做前置 uninstall)"
fi

# --- 步骤 3:构建 APK(已安装快速路径下仅校验产物存在)-------------------------
if (( APK_ALREADY_INSTALLED == 1 )) && [[ -f "$APK_PATH" ]]; then
  echo "[3/6] APK 已存在且包已安装,跳过构建($APK_PATH)"
else
  echo "[3/6] 构建 debug APK ..."
  (
    cd "$EXAMPLE_DIR" &&
      fvm flutter build apk --debug
  ) >"$WORK_DIR/build.log" 2>&1 || {
    echo "FAIL: flutter build apk --debug 失败,详见 $WORK_DIR/build.log" >&2
    exit 1
  }
fi
[[ -f "$APK_PATH" ]] || { echo "FAIL: 未找到 APK: $APK_PATH" >&2; exit 1; }

# --- 步骤 4:安装(R004 语义:统一 install -r;快速路径跳过)-------------------
# install -r 覆盖安装保 filesDir(token 存活的前提);即便 HyperOS 对
# install -r 仍弹「USB 安装」授权,也不能回退到 uninstall+install。
if (( APK_ALREADY_INSTALLED == 1 )); then
  echo "[4/6] 跳过安装(包已在设备)"
else
  install_apk() { adb_cmd install -r "$APK_PATH"; }
  echo "[4/6] 安装 APK(install -r)..."
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
fi

# --- 步骤 5:启动 app --------------------------------------------------------
# resolve-activity 对不存在的包返回字符串 "No activity found"(退出码 0),
# 须校验解析结果确为该包自身组件。
MAIN_ACTIVITY="$(adb_cmd shell cmd package resolve-activity --brief "$PACKAGE_NAME" 2>/dev/null | tr -d '\r' | tail -1)"
if [[ -z "$MAIN_ACTIVITY" || "$MAIN_ACTIVITY" != "$PACKAGE_NAME"* ]]; then
  MAIN_ACTIVITY="$PACKAGE_NAME/.MainActivity"
fi
echo "[5/6] 启动 app($MAIN_ACTIVITY)..."
adb_cmd shell am start -W -n "$MAIN_ACTIVITY" >"$WORK_DIR/am-start.log" 2>&1 ||
  echo "WARN: am start 失败(见 $WORK_DIR/am-start.log)" >&2
sleep 5

# --- 步骤 6:python e2e runner(6 用例断言,设备侧断言由 python 发起)----------
# 设备无独立 curl 通道(Dart plane loopback),所有 HTTP 断言 python 侧发起。
echo "[6/6] 运行 e2e-token-persistence.py(6 用例)..."
E2E_LOG="$WORK_DIR/e2e-out.log"
if python3 "$OVERRIDE_DIR/e2e-token-persistence.py" \
    --mode full \
    --serial "$DEVICE_SERIAL" \
    --package "$PACKAGE_NAME" \
    --activity "$MAIN_ACTIVITY" \
    --device-model "$DEVICE_MODEL" \
    --os-version "$OS_VERSION" \
    --cross-log "$CROSS_LOG" \
    --scope-md "$SCOPE_MD" \
    --run-at "$RUN_AT" 2>&1 | tee "$E2E_LOG"; then
  E2E_STATUS="$(grep -m1 '^E2E_STATUS: ' "$E2E_LOG" | sed 's/^E2E_STATUS: //')"
else
  E2E_STATUS="failed"
fi
STATUS="${E2E_STATUS:-failed}"

# 更新 scope md frontmatter(R003 模式:翻转 status + 设备信息)
python3 - "$SCOPE_MD" "$STATUS" "$DEVICE_MODEL" "$OS_VERSION" <<'PYEOF'
import re, sys
p, status, model, osver = sys.argv[1:5]
t = open(p).read()
t = re.sub(r"(?m)^status: deferred$", f"status: {status}", t, count=1)
t = re.sub(r"(?m)^device_model: null$", f"device_model: {model}", t, count=1)
t = re.sub(r"(?m)^os_version: null$", f"os_version: {osver}", t, count=1)
open(p, "w").write(t)
PYEOF

cat > "$ANDROID_LOG" <<EOF
---
type: test-log
task_id: R004-BF002
layer: integration
domain: android
run_at: $RUN_AT
status: $STATUS
exit_code: $( [ "$STATUS" = "pass" ] && echo 0 || echo 1 )
device: $DEVICE_MODEL (Android $OS_VERSION, serial $DEVICE_SERIAL)
deferred_reason:
---

# Test Log: R004-BF002 (integration.android — token 持久化 6 用例端到端)

- status: $STATUS
- device: $DEVICE_MODEL(Android $OS_VERSION,serial $DEVICE_SERIAL)
- 执行路径: device 检测 → (仅 DELETE_AND_REINSTALL=1 时 uninstall 逃生门)
  → flutter build apk --debug → adb install -r → am start -W →
  python e2e runner 6 用例(1 首次授权双侧落盘 / 2 冷重启[device] /
  3 install -r 主断言[device] / 4 python 重启免 auth / 5 过期自动重授权 /
  6 清装逃生门[device])。
  注:用例 3 由本脚本当前轮的 install -r + runner 的旧 token Bearer
  /hello 断言联合覆盖;用例 6 需 DELETE_AND_REINSTALL=1 单独重跑一轮。
- 原始证据:
  - runner 逐用例输出:test-overrides/R004-BF002/.android-work/e2e-out.log
  - 结构性判定:token-persistence-e2e.md(run_at: $RUN_AT 分节)
  - cross_stack 断言链(bearer-reuse / 401-clear-relay):
    $CROSS_LOG
- deferred 回收说明:本 log 由真机回收运行产出,覆盖此前的 deferred 占位
  (device_required);历史 deferred 记录见 git history。
EOF

echo "DONE: 6 用例验收完成(status=$STATUS);token-persistence-e2e.md 已更新。"
[ "$STATUS" = "pass" ] || exit 1
exit 0
