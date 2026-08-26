#!/usr/bin/env bash
# R003-FF002 official unit test entry (CI fact command).
# Layer: unit / domain: android — Android plugin JVM tests.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO/flutter_debug_control_plane/android"
../../kotlin/gradlew -p . testDebugUnitTest "$@"
