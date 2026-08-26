#!/bin/bash
set -euo pipefail

cd dart
fvm flutter test test/capability_scope_test.dart
