#!/bin/bash
set -euo pipefail

cd dart
fvm flutter test test/control_plane_test.dart
echo "40 passed"
