#!/usr/bin/env bash
# ci/ 共享辅助(供各守卫脚本 source)。
#
# resolve_py_bin — PYTHON_BIN 判活的统一约定:
#   值可以是绝对路径(本地默认 /usr/local/bin/python3.13)或 PATH 上的命令名
#   (GitHub runner 由 workflow 注入 python3.13)。
#   含 / 走 -x 判文件;纯命令名走 command -v 查 PATH。
#   `[[ -x python3.13 ]]` 只查 cwd,对 PATH 命令恒 false —— CI 第二红的根因,
#   该约定已写进 ci/README.md「CI 接入」,新增守卫脚本一律 source 本文件。

resolve_py_bin() {  # resolve_py_bin [值] → 校验通过输出该值,失败 stderr 报错并 exit 1
  local bin="${1:-${PYTHON_BIN:-/usr/local/bin/python3.13}}"
  if [[ "$bin" == */* ]]; then
    [[ -x "$bin" ]] || { echo "FAIL: 未找到 python3.13($bin)" >&2; exit 1; }
  else
    command -v "$bin" >/dev/null 2>&1 \
      || { echo "FAIL: PATH 上未找到 $bin(可用 PYTHON_BIN=... 覆盖)" >&2; exit 1; }
  fi
  echo "$bin"
}
