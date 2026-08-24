#!/usr/bin/env bash
# R002-FF002 integration:ios override — iOS 模拟器集成测试（iPhone 16e, 390x844@3）。
# config.json project_capabilities.tests.integration.ios 为 null（项目无 CI iOS 集成通道），
# 用 task override 声明本任务的真机/模拟器集成入口，可重复执行产出正式日志。
set -euo pipefail

cd flutter_debug_control_plane/example
fvm flutter test integration_test/acceptance_integration_test.dart \
  -d DAA2A14D-9BF2-4E3B-9EF2-A7E1136C631F
