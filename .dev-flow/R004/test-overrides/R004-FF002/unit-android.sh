#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../../flutter_debug_control_plane/android"
../../kotlin/gradlew -p . testDebugUnitTest --rerun-tasks
