#!/usr/bin/env bash
# R002-BF005 — example app auth acceptance 入口。
#
# 不负责启动 app/模拟器: 消费「已在运行的 example app Dart plane endpoint」
# (由 flutter integration driver 或操作者启动)。
#
# 用法:
#   bash ci/acceptance-flutter-app.sh --target ios-simulator --endpoint http://127.0.0.1:PORT
#   ACCEPTANCE_ENDPOINT=http://127.0.0.1:PORT bash ci/acceptance-flutter-app.sh
#
# 退出码: 0=pass; 1-5=pytest 测试失败(透传); 75=setup_required(无 endpoint /
#         endpoint 不可达导致全部 skip)。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT/ci/lib.sh"

TARGET="ios-simulator"
ENDPOINT="${ACCEPTANCE_ENDPOINT:-}"

usage() {
  cat <<'EOF'
Usage: acceptance-flutter-app.sh [--target ios-simulator|android-device] [--endpoint URL]

Drives the Python auth acceptance runner against a RUNNING example app
Dart plane endpoint. The app itself must already be running (flutter
integration driver or manual launch); this script only consumes the
loopback endpoint.

  --endpoint URL   Dart plane endpoint (default: env ACCEPTANCE_ENDPOINT)
  --target TARGET  ios-simulator (default) | android-device (recorded only,
                   device orchestration is out of scope — R002-BF008)

Exit codes: 0 pass; 1-5 pytest failure; 75 setup_required (no/lost endpoint).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { echo "FAIL: --target needs a value" >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    --endpoint)
      [[ $# -ge 2 ]] || { echo "FAIL: --endpoint needs a value" >&2; exit 2; }
      ENDPOINT="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "FAIL: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$TARGET" != "ios-simulator" && "$TARGET" != "android-device" ]]; then
  echo "FAIL: --target must be ios-simulator or android-device (got: $TARGET)" >&2
  exit 2
fi

if [[ -z "$ENDPOINT" ]]; then
  echo "setup_required: no endpoint provided (use --endpoint or ACCEPTANCE_ENDPOINT)"
  exit 75
fi

PY="$(resolve_py_bin)"
echo "acceptance-flutter-app: target=$TARGET endpoint=$ENDPOINT"

set +e
SUMMARY="$(cd "$ROOT/python" && "$PY" -m pytest \
  tests/test_acceptance_flutter_app_auth.py \
  --endpoint="$ENDPOINT" -v --no-header 2>&1 | tee /dev/stderr)"
STATUS=${PIPESTATUS[0]}
set -e

# pytest 对 skip-only 会话仍返回 0 — 汇总行含 skipped 且无 passed 时视为
# 环境未就绪 (endpoint 不可达 → 全 skip) → setup_required / 75, 不误报 pass。
if [[ $STATUS -eq 0 && "$SUMMARY" == *"skipped"* && "$SUMMARY" != *" passed"* ]]; then
  echo "setup_required: all cases skipped against endpoint (see output above)"
  exit 75
fi
exit $STATUS
