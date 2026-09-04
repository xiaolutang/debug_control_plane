#!/usr/bin/env bash
# =============================================================================
# R006-BF002 authPolicy 策略真机 e2e 驱动(fork 自 R004-BF002
# integration-android.sh,不回写先例产物)
# =============================================================================
# 契约: 设备检测 → python 断言脚本(auth-policy-e2e.py E1-E6,app 模式
# 主控按策略轮转 build/install/start/forward)→ evidence 双写。
#
# 与 R004 的差异(B 方案, 2026-09-04):
#   - 策略注入机制: example/lib/src/android_native_plane.dart 的
#     AndroidNativePlane.start 有 opt-in 编译常量注入点
#     String.fromEnvironment('R006_AUTH_POLICY')(auto|none 显式声明,
#     缺席 = null = default 现状)。旧 flutter-test driver 路线
#     (r006_auth_policy_driver_test.dart)因 plugin Kotlin 侧在
#     flutter test 模式不注册(GeneratedPluginRegistrant 只在真实
#     app Activity 启动)抛 MissingPluginException,已废弃删除。
#   - python 主控每轮策略: flutter build apk --debug
#     --dart-define=R006_AUTH_POLICY=<v> → install -r → am start -W →
#     R004 /proc/net/tcp6 uid LISTEN 端口发现 → adb forward tcp:18080 →
#     HTTP 断言 → force-stop。
#   - E5 非法值: switch 注入点在 Dart 侧把 bogus 坍缩为 default(枚举
#     不可构造非法值),fail-fast 主断言由 JVM 单测 K5 覆盖,python 侧
#     只断言坍缩行为(401 + pending)并登记 K5 证据引用。
#
# 行为约定(沿用 R004/R005):
#   - 设备缺失  : 打印 DEFERRED,双写 evidence(android + cross_stack 均
#                 status=deferred, deferred_reason=device_required)后
#                 exit 0(不算失败);
#   - 多设备并存: 报错退出(非确定环境禁止盲选);
#   - HyperOS   : 安装失败给「USB 安装」手动授权提示后重试一次
#                 (python install_apk 内 5s 退避重试)。
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
# 包名以 build 产物实际 applicationId 为准(aapt 校正见 get_package_name)
PACKAGE_NAME_FALLBACK="com.debugplane.debug_control_plane_acceptance_example"
APK_PATH="$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-debug.apk"
RUN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$WORK_DIR"

get_package_name() {
  # APK 未构建时 aapt 无产物可读,优先从设备已装包校正,最后 fallback
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
echo "[1/3] 检测 adb 设备 ..."
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

# --- 步骤 2:包名校正 --------------------------------------------------------
# python 侧按策略轮转 build/install,首轮 build 前无 APK 产物;包名从
# 设备已装包读(装过 R004-R006 任一轮的设备),否则用 fallback + 设备
# pm list 验证,不一致即报错(fail-fast,禁止盲跑错包)。
PACKAGE_NAME="$(get_package_name)"
if adb_cmd -s "$DEVICE_SERIAL" shell pm list packages 2>/dev/null |
    grep -q "^package:${PACKAGE_NAME}$"; then
  echo "[2/3] 包名校正: $PACKAGE_NAME(设备已装)"
else
  echo "[2/3] 包名 $PACKAGE_NAME 未在设备上(首轮将 install)"
fi

# --- 步骤 3:python e2e runner(E1-E6,策略轮转由 python 主控) --------------
echo "[3/3] 运行 auth-policy-e2e.py(E1-E6,app 模式策略轮转)..."
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
- 执行路径: device 检测 → python auth-policy-e2e.py 主控 E1-E6(app
  模式策略轮转: flutter build apk --debug
  --dart-define=R006_AUTH_POLICY=auto/none/bogus/缺席 → adb install -r
  → am start -W → R004 /proc/net/tcp6 uid LISTEN 端口发现 +
  adb forward tcp:18080 → HTTP 断言 → force-stop;策略注入点在
  example/lib/src/android_native_plane.dart 的编译常量
  String.fromEnvironment('R006_AUTH_POLICY'),opt-in 不改产品接入面)。
- E5 边界说明: switch 注入点只映射 auto/none,bogus 在 Dart 侧坍缩为
  default;python 侧断言坍缩行为(401 + pending),非法值 fail-fast
  主断言由 JVM 单测 PluginAuthPolicyTest.K5 覆盖。
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
