#!/usr/bin/env bash
# R002-FF002 integration:android override — Android 真机集成测试（GMC 7127M, 720x1560）。
# 前置：设备已解锁、亮屏（svc power stayon true）；锁屏会导致 pumpAndSettle 永不 settle。
set -euo pipefail

cd flutter_debug_control_plane/example
fvm flutter test integration_test/acceptance_integration_test.dart \
  -d RZCY128JJLV
