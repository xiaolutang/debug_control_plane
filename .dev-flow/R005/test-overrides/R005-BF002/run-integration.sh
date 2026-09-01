#!/usr/bin/env bash
# =============================================================================
# R005-BF002 iOS 模拟器 token 持久化端到端驱动（fork 自 R004-BF002 模式）
# =============================================================================
# 阶段：
#   1. simctl 检测 booted 模拟器；无 booted 尝试 boot 第一个可用；完全无
#      模拟器 → DEFERRED（evidence 双写空壳 device_required，exit 0，
#      R003/R004 deferred 契约）。
#   2. flutter build ios --simulator --debug（fvm；build 失败直接 FAIL）。
#   3. simctl install Runner.app。
#   4. 启动 R002 现成 driver 机制（本任务 fork 为
#      r005_persistence_driver_test.dart，加 ensurePersistentStore）：
#      `fvm flutter test -d <udid> --dart-define=DRIVER_SECONDS=<n>`，
#      stdout 打印 `pytest-driver: endpoint=`；模拟器 lo0 与宿主共享，
#      宿主直连 127.0.0.1。
#   5. 运行断言脚本 ios-simulator-persistence.py（python 主控 I1-I5，
#      含 simctl terminate/relaunch 冷重启）。
#   6. evidence 双写：R005-BF002-integration-cross_stack-test.log
#      （frontmatter: type/task_id/layer/domain/run_at/status/exit_code/
#       deferred_reason）。
#
# 环境变量：
#   DRIVER_SECONDS（默认 90）每次 driver 存活秒数（断言脚本会多次重启
#   driver：I2/I3/I4 各一次 + 首启一次，每次存活本值）。
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO_ROOT"

OVERRIDE_DIR="$REPO_ROOT/.dev-flow/R005/test-overrides/R005-BF002"
EVIDENCE_DIR="$REPO_ROOT/.dev-flow/R005/evidence"
LOG="$EVIDENCE_DIR/R005-BF002-integration-cross_stack-test.log"
WORK_DIR="$OVERRIDE_DIR/.work"
EXAMPLE_DIR="$REPO_ROOT/flutter_debug_control_plane/example"
APP_PATH="$EXAMPLE_DIR/build/ios/iphonesimulator/Runner.app"
BUNDLE_ID="com.debugplane.debugControlPlaneAcceptanceExample"
DRIVER_SECONDS="${DRIVER_SECONDS:-90}"
RUN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$WORK_DIR" "$EVIDENCE_DIR"

write_deferred_evidence() {
  cat > "$LOG" <<EOF
---
type: test-log
task_id: R005-BF002
layer: integration
domain: cross_stack
run_at: $RUN_AT
status: deferred
exit_code: null
deferred_reason: device_required
---

# Test Log: R005-BF002 (integration.cross_stack — DEFERRED)

- status: deferred
- deferred_reason: device_required
- reason_detail: tasks.md R005-BF002 需要 iOS 模拟器执行 token 持久化
  I1-I5 端到端验收;本次运行时 \`xcrun simctl list devices\` 无任何可用
  模拟器(实测),按 deferred 契约登记,不虚构任何模拟器输出。
- 回收动作: 待模拟器可用时重跑
  \`bash .dev-flow/R005/test-overrides/R005-BF002/run-integration.sh\`。
EOF
}

# --- 阶段 1: 模拟器检测 -------------------------------------------------------
echo "[1/6] 检测 iOS 模拟器 ..."
UDID="$(xcrun simctl list devices booted 2>/dev/null | grep -m1 Booted | sed -n 's/.*(\([0-9A-F-]*\)) (Booted).*/\1/p')"
if [[ -z "$UDID" ]]; then
  FIRST="$(xcrun simctl list devices available 2>/dev/null | grep -m1 -o '([0-9A-F-]*)' | tr -d '()')"
  if [[ -z "$FIRST" ]]; then
    echo "DEFERRED: device_required(simctl 无可用模拟器)"
    write_deferred_evidence
    echo "evidence 已写: $LOG (status: deferred)"
    exit 0
  fi
  echo "  无 booted 模拟器,尝试 boot $FIRST ..."
  xcrun simctl boot "$FIRST" 2>/dev/null || true
  UDID="$FIRST"
fi
echo "OK: udid=$UDID"

# --- 阶段 2: 构建 ------------------------------------------------------------
if [[ -d "$APP_PATH" ]] && [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  echo "[2/6] SKIP_BUILD=1 且产物在场,跳过构建"
else
  echo "[2/6] flutter build ios --simulator --debug ..."
  ( cd "$EXAMPLE_DIR" && fvm flutter build ios --simulator --debug ) \
    > "$WORK_DIR/build.log" 2>&1 || {
      echo "FAIL: flutter build 失败,详见 $WORK_DIR/build.log" >&2
      exit 1
    }
fi
[[ -d "$APP_PATH" ]] || { echo "FAIL: 未找到 $APP_PATH" >&2; exit 1; }

# --- 阶段 3: 安装 ------------------------------------------------------------
echo "[3/6] simctl install ..."
xcrun simctl install "$UDID" "$APP_PATH" || {
  echo "FAIL: simctl install 失败" >&2; exit 1; }

# --- 阶段 4: 首启 driver + endpoint 发现 -------------------------------------
# driver(fork 自 R002 acceptance_pytest_driver_test,加 ensurePersistentStore)
# stdout 打印 pytest-driver: endpoint=URL;模拟器 lo0 宿主直连。
echo "[4/6] 启动 driver(首启)并发现 endpoint ..."
# 后台跑 driver,日志落盘,pid 记录;endpoint 从日志轮询取
( cd "$EXAMPLE_DIR" && fvm flutter test integration_test/r005_persistence_driver_test.dart -d "$UDID" --dart-define=DRIVER_SECONDS="$DRIVER_SECONDS" ) > "$WORK_DIR/driver-first.log" 2>&1 &
DRIVER_PID=$!
echo "$DRIVER_PID" > "$WORK_DIR/driver.pid"

ENDPOINT=""
for _ in $(seq 1 120); do
  ENDPOINT="$(grep -a -m1 -o 'endpoint=http://[^ ]*' "$WORK_DIR/driver-first.log" 2>/dev/null | tail -1 | sed 's/^endpoint=//')"
  [[ -n "$ENDPOINT" ]] && break
  kill -0 "$DRIVER_PID" 2>/dev/null || break
  sleep 2
done
if [[ -z "$ENDPOINT" ]]; then
  echo "FAIL: driver 首启未发现 endpoint,详见 $WORK_DIR/driver-first.log" >&2
  kill "$DRIVER_PID" 2>/dev/null || true
  exit 1
fi
echo "OK: endpoint=$ENDPOINT"

# --- 阶段 5: 断言脚本(python 主控 I1-I5,含冷重启) ----------------------------
echo "[5/6] 运行 ios-simulator-persistence.py(I1-I5)..."
# 首启 driver 保持存活:I1 直接消费其 endpoint/approver;后续冷重启由
# python 脚本 restart_app 经 simctl terminate 触发(旧 flutter test 进程
# 随 app 终止自行收尾)。
E2E_LOG="$WORK_DIR/e2e-out.log"
if python3 "$OVERRIDE_DIR/ios-simulator-persistence.py" \
    "$ENDPOINT" "$UDID" "$BUNDLE_ID" \
    --example-dir "$EXAMPLE_DIR" \
    --driver-seconds "$DRIVER_SECONDS" 2>&1 | tee "$E2E_LOG"; then
  STATUS="pass"; EXIT_CODE=0
else
  STATUS="failed"; EXIT_CODE=1
fi

# --- 阶段 6: evidence 双写 ----------------------------------------------------
cat > "$LOG" <<EOF
---
type: test-log
task_id: R005-BF002
layer: integration
domain: cross_stack
run_at: $RUN_AT
status: $STATUS
exit_code: $EXIT_CODE
deferred_reason:
---

# Test Log: R005-BF002 (integration.cross_stack — iOS 模拟器 token 持久化 I1-I5)

- status: $STATUS
- device: iOS Simulator (udid $UDID)
- 执行路径: simctl 检测 → flutter build ios --simulator --debug →
  simctl install → driver 首启(r005_persistence_driver_test.dart, fork 自
  R002 pytest driver + ensurePersistentStore)endpoint 发现 → python
  ios-simulator-persistence.py 主控 I1-I5(含 simctl terminate/relaunch
  冷重启 I2/I3/I4 各一次)。
- I1 首次授权双侧落盘 / I2 冷重启旧 Bearer 200 authorized / I3 损坏自愈 /
  I4 TTL 窗口 + load-discard / I5 wire 回归。
- 原始证据: test-overrides/R005-BF002/.work/e2e-out.log
- endpoint 发现机制: driver stdout \`pytest-driver: endpoint=\` 行
  (模拟器 lo0 与宿主共享,宿主直连 127.0.0.1)。

\`\`\`
$(grep -E '^(SCENARIO|IOS_E2E_STATUS|  I[1-5] PASS)' "$E2E_LOG" 2>/dev/null)
\`\`\`
EOF

echo "DONE: I1-I5 验收完成(status=$STATUS);evidence: $LOG"
[[ "$STATUS" == "pass" ]] || exit 1
exit 0
