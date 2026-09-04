#!/usr/bin/env python3
"""R006-BF002 — 真机 authPolicy 策略 e2e 断言（E1-E6）。

纯标准库 urllib 编排（D6：e2e 脚手架归测试目录，不动 mcp_plane 库）。
fork 自 R004 e2e-token-persistence.py / R005 ios-simulator-persistence.py
的 http_json 工具函数与日志骨架。

策略注入机制：r006_auth_policy_driver_test.dart（本目录）以
  fvm flutter test <driver> -d <serial> \
    --dart-define=R006_AUTH_POLICY=<v> --dart-define=DRIVER_SECONDS=<n>
运行；stdout 打印 `pytest-driver: endpoint=<URL>`（bogus 轮改为
`r006-e5: plane-not-started code=invalid_arguments` 标记行）。

端到端拓扑（真机）：driver 启动 native plane 绑 0.0.0.0:随机端口；
shell 侧经 adb forward tcp:18080 → <plane_port>，python 直连
127.0.0.1:18080。每轮策略用独立 driver 会话（force-stop + 重启 driver）。

用例：
  E1 auto 直连链    无 token 敏感路由 401 authorization_required →
                    POST /auth/request (clientLabel=r006-e1) 202 且
                    status=approved（auto 即时批准主断言，零人工审批）→
                    POST /auth/claim 200 得 token。
  E2 Bearer 直连    E1 token 直连敏感路由 200。
  E3 冷重启持久化    force-stop + 重启 auto driver → 旧 Bearer /hello
                    200 authStatus=authorized（R004 持久化在 auto 下照常）。
  E4 none 同构      无 token 敏感路由 200；/hello 200 且响应无
                    authRequired 字段（core null 放行语义，主断言）。
  E5 非法策略       R006_AUTH_POLICY=bogus driver：stdout 有
                    `r006-e5: plane-not-started` 标记行 + code 含
                    invalid_arguments，且 endpoint 不可达（双断言）。
  E6 default 回归    R006_AUTH_POLICY 缺席启动：无 token 401 +
                    /auth/request 202 status=pending 可达（不 approve，
                    只断言 pending 状态）。

输出（供 shell 侧消费）：最后一行 `E2E_STATUS: pass|failed`。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

REPO = Path(__file__).resolve().parents[4]
EXAMPLE_DIR = REPO / "flutter_debug_control_plane" / "example"
DRIVER = Path(__file__).resolve().parent / "r006_auth_policy_driver_test.dart"
BASE = "http://127.0.0.1:18080"

results: dict[str, str] = {}
_driver_proc: subprocess.Popen | None = None


# --- HTTP 工具（R004/R005 沿用，纯标准库） ------------------------------------

def http_json(method: str, path: str, body: dict[str, Any] | None = None,
              bearer: str | None = None,
              timeout: float = 5.0) -> tuple[int, Any]:
    req = Request(BASE + path, data=json.dumps(body or {}).encode(),
                  method=method)
    req.add_header("Content-Type", "application/json")
    if bearer:
        req.add_header("Authorization", f"Bearer {bearer}")
    try:
        with urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else {})
        except ValueError:
            return e.code, raw.decode(errors="replace")


def endpoint_unreachable(timeout: float = 3.0) -> bool:
    try:
        urlopen(Request(BASE + "/hello"), timeout=timeout)
        return False
    except HTTPError:
        return False  # 有响应 = 可达
    except (URLError, OSError, TimeoutError):
        return True


# --- driver 会话控制（adb 真机） ----------------------------------------------

def adb(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["adb", *args], capture_output=True, text=True)


def stop_driver() -> None:
    global _driver_proc
    if _driver_proc is None:
        return
    _driver_proc.terminate()
    try:
        _driver_proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        _driver_proc.kill()
    _driver_proc = None


def launch_driver(policy: str, serial: str, package: str,
                  seconds: int, timeout: float = 420.0) -> str | None:
    """启动一轮策略 driver，返回 endpoint（bogus 轮返回 None）。

    流式读 stdout：`pytest-driver: endpoint=` → endpoint；bogus 轮等
    `r006-e5: plane-not-started` 标记行。driver 保持存活（python 编排
    期间 plane/审批托管在 driver）。
    """
    global _driver_proc
    # 冷启动：杀旧 app 会话（E3 语义同源；也保证端口/状态干净）
    adb("-s", serial, "shell", "am", "force-stop", package)
    stop_driver()
    time.sleep(2.0)

    cmd = (f"cd {EXAMPLE_DIR} && fvm flutter test {DRIVER} -d {serial}"
           f" --dart-define=R006_AUTH_POLICY={policy}"
           f" --dart-define=DRIVER_SECONDS={seconds}")
    proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1,
                            cwd="/tmp")
    _driver_proc = proc
    marker: str | None = None
    deadline = time.monotonic() + timeout
    tail: list[str] = []
    while time.monotonic() < deadline:
        line = proc.stdout.readline() if proc.stdout else ""
        if line:
            tail.append(line.rstrip())
            tail = tail[-20:]
            if "endpoint=" in line and "pytest-driver" in line:
                ep = line.split("endpoint=", 1)[1].strip()
                if ep.startswith("http"):
                    print(f"  [driver] endpoint={ep}")
                    return ep
            if "r006-e5: plane-not-started" in line:
                marker = line.strip()
                print(f"  [driver] {marker}")
                return marker
        if proc.poll() is not None:
            break
        time.sleep(0.2)
    raise AssertionError("driver 未输出 endpoint/E5 标记;tail:\n"
                         + "\n".join(tail))


def forward_plane_port(serial: str, package: str, retries: int = 12) -> int:
    """R004 端口发现算法：app uid 的 tcp6 通配 LISTEN 行 → adb forward。"""
    for _ in range(retries):
        pid = adb("-s", serial, "shell", "pidof", package
                  ).stdout.strip().replace("\r", "")
        if pid:
            uid = adb("-s", serial, "shell", "stat", "-c", "%u",
                      f"/proc/{pid}").stdout.strip()
            out = adb("-s", serial, "shell",
                      f"cat /proc/{pid}/net/tcp6").stdout
            for ln in out.splitlines():
                f = ln.split()
                if (len(f) > 8 and f[3] == "0A" and f[8] == uid
                        and f[1].startswith("00000000000000000000000000000000:")):
                    port = int(f[1].split(":", 1)[1], 16)
                    adb("forward", "--remove", "tcp:18080")
                    adb("forward", "tcp:18080", f"tcp:{port}")
                    return port
        time.sleep(5.0)
    raise AssertionError("未能发现 plane 监听端口(app uid tcp6 LISTEN)")


def wait_hello(timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            st, _ = http_json("GET", "/hello", timeout=2.0)
            if st == 200:
                return
        except Exception:
            pass
        time.sleep(1.0)
    raise AssertionError("/hello 健康探测超时")


# --- E1-E6 --------------------------------------------------------------------

def e1_e2_auto(serial: str, package: str) -> str:
    """E1 auto 直连授权链 + E2 Bearer 直连敏感路由。"""
    launch_driver("auto", serial, package, seconds=150)
    port = forward_plane_port(serial, package)
    print(f"  [forward] plane:{port} -> 127.0.0.1:18080")
    wait_hello()
    nonce = f"r006-e1-{uuid.uuid4().hex[:8]}"
    st, body = http_json("POST", "/debug/secure-action", {"via": "r006-e1"})
    assert st == 401 and body.get("code") == "authorization_required", \
        f"E1-1 无 token 应 401 authorization_required: {st} {body!r:.80}"
    st, body = http_json("POST", "/auth/request",
                         {"clientNonce": nonce, "clientLabel": "r006-e1"})
    assert st == 202 and body.get("status") == "approved", \
        f"E1-2 auto 即时批准主断言失败(期望 202 approved): {st} {body!r:.80}"
    st, body = http_json("POST", "/auth/claim",
                         {"requestId": body["requestId"],
                          "clientNonce": nonce})
    assert st == 200 and isinstance(body.get("token"), str) and body["token"], \
        f"E1-3 claim 应 200 得 token: {st} {body!r:.80}"
    token = body["token"]
    results["E1"] = "pass"
    print("  E1 PASS: 401 → /auth/request 202 approved(auto) → claim 200"
          " 全程零人工审批")

    st, body = http_json("POST", "/debug/secure-action",
                         {"via": "r006-e2"}, bearer=token)
    assert st == 200, f"E2 Bearer 直连敏感路由应 200: {st} {body!r:.80}"
    results["E2"] = "pass"
    print("  E2 PASS: Bearer 直连 /debug/secure-action 200")
    return token


def e3_cold_restart(token: str, serial: str, package: str) -> None:
    launch_driver("auto", serial, package, seconds=120)
    forward_plane_port(serial, package)
    wait_hello()
    st, body = http_json("GET", "/hello", bearer=token)
    assert st == 200 and body.get("authStatus") == "authorized", \
        f"E3 冷重启旧 Bearer /hello 应 200 authorized: {st} {body!r:.80}"
    results["E3"] = "pass"
    print("  E3 PASS: force-stop + 重启后旧 Bearer /hello 200 authorized"
          "(auto 下持久化照常)")


def e4_none(serial: str, package: str) -> None:
    launch_driver("none", serial, package, seconds=90)
    forward_plane_port(serial, package)
    wait_hello()
    st, body = http_json("POST", "/debug/secure-action", {"via": "r006-e4"})
    assert st == 200, f"E4-1 none 无 token 敏感路由应 200: {st} {body!r:.80}"
    st, body = http_json("GET", "/hello")
    assert st == 200 and "authRequired" not in body, \
        f"E4-2 /hello 应 200 且无 authRequired 字段: {st} {body!r:.80}"
    results["E4"] = "pass"
    print("  E4 PASS: none 无 token 敏感路由 200;/hello 无 authRequired"
          "(core null 放行,两宿主同构主断言)")


def e5_bogus(serial: str, package: str) -> None:
    marker = launch_driver("bogus", serial, package, seconds=25)
    assert marker is not None and "r006-e5: plane-not-started" in marker, \
        f"E5 driver 未输出标记行: {marker!r}"
    assert "invalid_arguments" in marker, f"E5 code 非 invalid_arguments: {marker}"
    assert endpoint_unreachable(), "E5 endpoint 应不可达(plane 未启动)"
    results["E5"] = "pass"
    print("  E5 PASS: PlatformException(invalid_arguments) 标记行 + "
          "endpoint 不可达(plane 未 mount)")
    stop_driver()
    adb("-s", serial, "shell", "am", "force-stop", package)


def e6_default(serial: str, package: str) -> None:
    launch_driver("", serial, package, seconds=60)  # 缺席 = 现状
    forward_plane_port(serial, package)
    wait_hello()
    st, body = http_json("POST", "/debug/secure-action", {"via": "r006-e6"})
    assert st == 401, f"E6-1 default 无 token 应 401: {st}"
    nonce = f"r006-e6-{uuid.uuid4().hex[:8]}"
    st, body = http_json("POST", "/auth/request",
                         {"clientNonce": nonce, "clientLabel": "r006-e6"})
    assert st == 202 and body.get("status") == "pending", \
        f"E6-2 授权链应 202 pending(不 approve): {st} {body!r:.80}"
    results["E6"] = "pass"
    print("  E6 PASS: default 回归 无 token 401 + 授权链 pending 可达")


# --- 入口 ----------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--package", required=True)
    args = ap.parse_args()
    try:
        token = e1_e2_auto(args.serial, args.package)
        e3_cold_restart(token, args.serial, args.package)
        e4_none(args.serial, args.package)
        e5_bogus(args.serial, args.package)
        e6_default(args.serial, args.package)
    except (AssertionError, Exception) as e:  # noqa: BLE001
        for k in ("E1", "E2", "E3", "E4", "E5", "E6"):
            results.setdefault(k, "failed")
        for k, v in results.items():
            if v == "pass":
                print(f"  {k} PASS")
        print(f"FAILED: {e}")
        print("E2E_STATUS: failed")
        return 1
    finally:
        stop_driver()
    print("E2E_STATUS: pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
