#!/usr/bin/env bash
# =============================================================================
# R006-BF002 authPolicy 策略真机 e2e 驱动(fork 自 R004-BF002
# integration-android.sh,不回写先例产物)
# =============================================================================
# 契约: 设备检测 → 构建/安装(install -r 语义) → 策略 driver 会话轮转 →
# python 断言脚本(auth-policy-e2e.py E1-E6) → evidence 双写。
#
# 与 R004 的差异:
#   - 策略注入机制(plan 决策): example 无现成 authPolicy 注入点且
#     example/lib 被 block,故用 test-overrides 内独立 driver 文件
#     r006_auth_policy_driver_test.dart + --dart-define=R006_AUTH_POLICY=<v>
#     (default/auto/none/bogus;缺席 = default 现状)。driver 不经
#     AcceptanceController,直接用 NativeControlPlaneBridge.start(
#     authPolicy:) 装配(R006-FF001 API 面)。
#   - 端点发现: 既有 R004 /proc/net/tcp6 端口发现算法原样沿用(python 侧
#     forward_plane_port 实现)。
#
# 行为约定(沿用 R004/R005):
#   - 设备缺失  : 打印 DEFERRED,双写 evidence(android + cross_stack 均
#                 status=deferred, deferred_reason=device_required)后
#                 exit 0(不算失败);
#   - 多设备并存: 报错退出(非确定环境禁止盲选);
#   - HyperOS   : 安装失败给「USB 安装」手动授权提示后重试一次。
#
# 用法:
#   bash .dev-flow/R006/test-overrides/R006-BF002/integration-android.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO_ROOT"

OVERRIDE_DIR="$REPO_ROOT/.dev-flow/R006/test-overrides/R006-BF002"
EVIDENCE_DIR="$REPO_ROOT/.dev-flow/R006/evidence"
ANDROID_LOG="$EVIDENCE_DIR/R006-BF002-integration-android-test.log"
CROSS_LOG="$EVIDENCE_DIR/R006-BF002-integration-cross_stack-test.log"
WORK_DIR="$OVERRIDE_DIR/.android-work"
EXAMPLE_DIR="$REPO_ROOT/flutter_debug_control_plane/example"
APK_PATH="$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-debug.apk"
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

# --- evidence 双写(deferred 分支) --------------------------------------------
write_deferred_evidence() {
  for f in "$ANDROID_LOG" "$CROSS_LOG"; do
    cat > "$f" <<EOF
---
type: test-log
task_id: R006-BF002
layer: integration
domain: $( [[ "$f" == "$ANDROID_LOG" ]] && echo android || echo cross_stack )
run_at: $RUN_AT
status: deferred
exit_code: 0
deferred_reason: device_required
---

# Test Log: R006-BF002 (integration — DEFERRED)

- status: deferred
- deferred_reason: device_required
- reason_detail: tasks.md R006-BF002 test_tasks(integration cross_stack)
  需要 Android 真机执行 authPolicy 策略 6 用例(E1-E6)端到端验收;
  本次运行时 \`adb devices\` 无 device 状态行(实测),按 deferred 契约
  (R003/R004/R005 模式)登记,不虚构任何真机输出。
- 回收动作: 待设备可用时重跑
  \`bash .dev-flow/R006/test-overrides/R006-BF002/integration-android.sh\`
  (HyperOS 设备需先手动开启「USB 安装」授权),脚本将补齐 E1-E6 内容并
  翻转为 pass/failed。
EOF
  done
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
  echo "  $CROSS_LOG   (status: deferred)"
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

# --- 步骤 2:安装态检测(R004 install -r 语义) --------------------------------
PACKAGE_NAME="$(get_package_name)"
if adb_cmd -s "$DEVICE_SERIAL" shell pm list packages 2>/dev/null | grep -q "^package:${PACKAGE_NAME}$"; then
  APK_ALREADY_INSTALLED=1
  echo "[2/5] 包已在设备,跳过 install(免 HyperOS 安装弹窗)"
else
  APK_ALREADY_INSTALLED=0
  echo "[2/5] 包未安装,将执行 install -r"
fi

# --- 步骤 3:构建 APK --------------------------------------------------------
# 注: driver 会话经 fvm flutter test 运行(其自身会再编译注入 dart-define),
# 此处 build apk 仅为首次 install 提供产物。
if (( APK_ALREADY_INSTALLED == 1 )); then
  echo "[3/5] 包已安装,跳过独立构建"
else
  echo "[3/5] 构建 debug APK ..."
  (
    cd "$EXAMPLE_DIR" &&
      fvm flutter build apk --debug
  ) >"$WORK_DIR/build.log" 2>&1 || {
    echo "FAIL: flutter build apk --debug 失败,详见 $WORK_DIR/build.log" >&2
    exit 1
  }
fi

# --- 步骤 4:安装(install -r;快速路径跳过) ---------------------------------
if (( APK_ALREADY_INSTALLED == 1 )); then
  echo "[4/5] 跳过安装(包已在设备)"
else
  [[ -f "$APK_PATH" ]] || { echo "FAIL: 未找到 APK: $APK_PATH" >&2; exit 1; }
  install_apk() { adb_cmd -s "$DEVICE_SERIAL" install -r "$APK_PATH"; }
  echo "[4/5] 安装 APK(install -r)..."
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

# --- 步骤 5:python e2e runner(E1-E6,策略 driver 轮转由 python 主控) -------
echo "[5/5] 运行 auth-policy-e2e.py(E1-E6,策略注入 R006_AUTH_POLICY)..."
E2E_LOG="$WORK_DIR/e2e-out.log"
if python3 "$OVERRIDE_DIR/auth-policy-e2e.py" \
    --serial "$DEVICE_SERIAL" \
    --package "$PACKAGE_NAME" 2>&1 | tee "$E2E_LOG"; then
  STATUS="pass"; EXIT_CODE=0
else
  STATUS="failed"; EXIT_CODE=1
fi

# --- evidence 双写 ----------------------------------------------------------
cat > "$ANDROID_LOG" <<EOF
---
type: test-log
task_id: R006-BF002
layer: integration
domain: android
run_at: $RUN_AT
status: $STATUS
exit_code: $EXIT_CODE
device: $DEVICE_MODEL (Android $OS_VERSION, serial $DEVICE_SERIAL)
deferred_reason:
---

# Test Log: R006-BF002 (integration.android — authPolicy 策略 E1-E6 真机)

- status: $STATUS
- device: $DEVICE_MODEL(Android $OS_VERSION,serial $DEVICE_SERIAL)
- 执行路径: device 检测 → flutter build apk --debug(仅首装) →
  adb install -r → python auth-policy-e2e.py 主控 E1-E6(每策略独立
  driver 会话: r006_auth_policy_driver_test.dart +
  --dart-define=R006_AUTH_POLICY=auto/none/bogus/缺席;端点发现 R004
  /proc/net/tcp6 uid LISTEN 算法 + adb forward tcp:18080)。
- 原始证据: test-overrides/R006-BF002/.android-work/e2e-out.log
- deferred 回收说明: 本 log 由真机回收运行产出,覆盖 deferred 占位;
  历史 deferred 记录见 git history。

\`\`\`
$(grep -E '^  E[1-6] (PASS|.*failed)|^E2E_STATUS' "$E2E_LOG" 2>/dev/null)
\`\`\`
EOF

cp "$ANDROID_LOG" "$CROSS_LOG"
# cross_stack 副本 frontmatter 域名校正
python3 - "$CROSS_LOG" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("domain: android", "domain: cross_stack", 1)
t = t.replace("(integration.android — authPolicy 策略 E1-E6 真机)",
              "(integration.cross_stack — authPolicy 策略 E1-E6 真机)", 1)
open(p, "w").write(t)
PYEOF

echo "DONE: E1-E6 验收完成(status=$STATUS);evidence:"
echo "  $ANDROID_LOG"
echo "  $CROSS_LOG"
[ "$STATUS" = "pass" ] || exit 1
exit 0
