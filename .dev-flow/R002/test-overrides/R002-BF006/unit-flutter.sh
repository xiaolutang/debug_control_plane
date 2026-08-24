#!/usr/bin/env bash
set -euo pipefail

cd flutter_debug_control_plane/example
fvm flutter test test/acceptance_plane_test.dart
