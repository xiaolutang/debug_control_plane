#!/usr/bin/env bash
# R003-FB002 formal unit test: example widget tests + main package regression.
set -euo pipefail
cd /Users/tangxiaolu/project/debug_control_plane/flutter_debug_control_plane/example
fvm flutter test
echo "--- main package regression ---"
cd /Users/tangxiaolu/project/debug_control_plane/flutter_debug_control_plane
fvm flutter test
