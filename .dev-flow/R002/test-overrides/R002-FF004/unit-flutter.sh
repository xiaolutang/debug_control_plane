#!/usr/bin/env bash
# R002-FF004 unit:flutter override — example 目录的 widget/controller 测试集
# （config.json unit.flutter 指向 package 根，本任务改动在 example/）。
set -euo pipefail

cd flutter_debug_control_plane/example
fvm flutter test
