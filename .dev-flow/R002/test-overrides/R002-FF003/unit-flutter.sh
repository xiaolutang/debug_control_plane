#!/usr/bin/env bash
# R002-FF003 unit:flutter override — example app 全量单测
# （含既有 FF002/FB001 21 例零回归 + 新增 android_native_plane 12 例）。
set -euo pipefail

cd flutter_debug_control_plane/example
fvm flutter test
