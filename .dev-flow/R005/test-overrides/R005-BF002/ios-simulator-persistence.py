#!/usr/bin/env python3
"""R005-BF002 — iOS 模拟器 token 持久化端到端断言（I1-I5）。

fork 自 R004 ios-simulator-token-persistence.py（http_json / make_client /
wait_approved 工具函数直接沿用）。差异：本脚本主控整个 I1-I5 流程，含
app 冷重启（simctl terminate + 重新 launch driver 发现新 endpoint）。

  I1 首次授权双侧落盘   auth_request→(driver auto-approve)→claim 200；
                        app 沙箱 Documents/debug_control_plane/
                        debug_auth_tokens.json 存在、jsonDecode 成功、
                        version==1、字节不含明文 token（红线）；
                        python 侧 tokens.json 有行。
  I2 冷重启主断言       simctl terminate → 重新 launch driver → 旧 Bearer
                        GET /hello 200 authStatus=authorized；敏感路由
                        POST /debug/secure-action 200；零 /auth/request。
  I3 损坏自愈           app 沙箱文件写截断 JSON → 重启 → 旧 token 401
                        invalid_token → 重授权链 claim 成功 → 沙箱文件
                        json.loads 不抛（persist 覆盖损坏文件）。
  I4 TTL 生效           claim 响应 expiresAt-now ∈ [604790, 604810]s；
                        篡改沙箱行 expiresAt 为过去（tokenHash 不变）→
                        重启 → 401 invalid_token（BF001 load 时过期行
                        丢弃 → tokenByHash 未命中——TTL 语义经
                        load-discard 达成）；重授权链可达。
  I5 wire 回归          no-token 401 / forged 401 invalid_token /
                        pending claim 无 token 泄漏（抄 R004 S4）。

用法（由 run-integration.sh 驱动；也可手动）:
  python3 ios-simulator-persistence.py <endpoint> <udid> <bundle-id> \
      --example-dir <abs path> --driver-seconds <n>

endpoint 发现机制：R002 现成 integration driver（本任务 fork 为
r005_persistence_driver_test.dart，加 ensurePersistentStore）以
`fvm flutter test -d <udid> --dart-define=DRIVER_SECONDS=<n>` 运行，
stdout 打印 `pytest-driver: endpoint=<URL>`。模拟器 lo0 与宿主共享，
宿主直连 127.0.0.1。冷重启 = simctl terminate 杀 app（driver 进程随
之收尾）→ 重新 launch driver 流式读新 endpoint。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request, urlopen

REPO = Path("/Users/tangxiaolu/project/debug_control_plane")
sys.path.insert(0, str(REPO / "python"))

from debug_control_plane.device_discovery.device_pool import (  # noqa: E402
    DevicePool,
    DeviceRecord,
)
from debug_control_plane.mcp_plane.bridge_client import (  # noqa: E402
    BridgeClient,
)
from debug_control_plane.mcp_plane.token_provider import (  # noqa: E402
    FileTokenProvider,
)

results: dict[str, str] = {}
UDID = ""
BUNDLE = ""
EXAMPLE_DIR = REPO / "flutter_debug_control_plane" / "example"
DRIVER_SECONDS = 90
_driver_proc: subprocess.Popen | None = None
_endpoint: str = ""


# --- 工具函数（R004 沿用） ----------------------------------------------------

def http_json(endpoint: str, method: str, path: str,
              body: dict[str, Any] | None = None,
              bearer: str | None = None, timeout: float = 5.0) -> tuple[int, Any]:
    url = endpoint.rstrip("/") + path
    data = json.dumps(body or {}).encode()
    req = Request(url, data=data, method=method)
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


def make_client(provider: FileTokenProvider, host: str) -> BridgeClient:
    pool = DevicePool(persist_path=Path(tempfile.mkdtemp()) / "devices.json")
    addr, _, _port = host.rpartition(":")
    pool.upsert(DeviceRecord(
        device_id="ios-sim", label="ios-sim", source="manual",
        last_known_host=addr, last_seen=time.time(), ttl=3600.0,
    ))
    return BridgeClient(pool, port=int(_port), token_provider=provider)


def wait_approved(endpoint: str, rid: str, nonce: str, timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        st, body = http_json(endpoint, "POST", "/auth/status",
                             {"requestId": rid, "clientNonce": nonce})
        if st == 200 and isinstance(body, dict) and body.get("status") == "approved":
            return
        if st == 403:
            raise AssertionError(f"denied while waiting approve: {body}")
        time.sleep(0.5)
    raise AssertionError(f"approve timeout for {rid}(driver 应自动 approve)")


# --- 模拟器 / driver 控制 -----------------------------------------------------

def simctl(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True,
                          text=True, check=check)


def sandbox_store_path() -> Path:
    """app 数据沙箱内的 token 存储文件（Documents/debug_control_plane/）。"""
    out = simctl("get_app_container", UDID, BUNDLE, "data")
    root = Path(out.stdout.strip())
    return root / "Documents" / "debug_control_plane" / "debug_auth_tokens.json"


def launch_driver(seconds: int, timeout: float = 300.0) -> str:
    """启动 driver（flutter test），流式读 stdout 直到 endpoint 行。

    返回 endpoint；driver 进程保持存活（auto-approve + plane 托管），
    记入 _driver_proc 由后续 restart 清理。
    """
    global _driver_proc
    cmd = ("cd " + str(EXAMPLE_DIR) +
           " && fvm flutter test integration_test/r005_persistence_driver_test.dart"
           f" -d {UDID} --dart-define=DRIVER_SECONDS={seconds}")
    proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1,
                            cwd="/tmp")
    _driver_proc = proc
    deadline = time.monotonic() + timeout
    tail: list[str] = []
    while time.monotonic() < deadline:
        line = proc.stdout.readline() if proc.stdout else ""
        if line:
            tail.append(line.rstrip())
            tail = tail[-15:]
            if "endpoint=" in line:
                ep = line.split("endpoint=", 1)[1].strip()
                if ep.startswith("http"):
                    print(f"  [driver] endpoint={ep}")
                    return ep
        if proc.poll() is not None:
            break
        time.sleep(0.2)
    raise AssertionError(f"driver 未输出 endpoint;tail:\n" + "\n".join(tail))


def wait_hello(endpoint: str, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            st, _ = http_json(endpoint, "GET", "/hello", timeout=2.0)
            if st == 200:
                return
        except Exception:
            pass
        time.sleep(1.0)
    raise AssertionError(f"/hello 健康探测超时: {endpoint}")


def restart_app(seconds: int = 90) -> str:
    """冷重启：terminate app（driver 随之收尾）→ 重新 launch driver。

    每次成功重启后更新全局 _last_endpoint（I5 复用最新 plane）。
    """
    global _driver_proc, _last_endpoint
    simctl("terminate", UDID, BUNDLE, check=False)
    if _driver_proc is not None:
        try:
            _driver_proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            _driver_proc.terminate()
            try:
                _driver_proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                _driver_proc.kill()
        _driver_proc = None
    # 等 app 进程真正退场 + 旧 flutter test 自行收尾(避免与新 driver 抢
    # 模拟器/flutter build 锁)
    for _ in range(30):
        out = simctl("spawn", UDID, "launchctl", "list", check=False)
        if BUNDLE not in out.stdout:
            break
        time.sleep(1.0)
    time.sleep(5.0)
    endpoint = launch_driver(seconds)
    wait_hello(endpoint)
    _last_endpoint = endpoint
    return endpoint


# --- 授权链 -------------------------------------------------------------------

def auth_chain(endpoint: str, host: str, store: Path,
               label: str) -> tuple[str, dict[str, Any]]:
    """完整授权链：request → driver auto-approve → claim → python 落盘。"""
    nonce = f"r005-{label}-{uuid.uuid4().hex[:8]}"
    provider = FileTokenProvider(path=store)
    client = make_client(provider, host)
    req = client.auth_request("ios-sim", nonce, client_label=label)
    assert isinstance(req, dict) and req.get("requestId"), f"/auth/request: {req!r}"
    wait_approved(endpoint, req["requestId"], nonce)
    claim = client.auth_claim("ios-sim", req["requestId"], nonce)
    assert isinstance(claim, dict) and isinstance(claim.get("token"), str), \
        f"claim: {claim!r}"
    return claim["token"], claim


# --- I1-I5 -------------------------------------------------------------------

def i1_first_auth(endpoint: str, host: str, store: Path) -> str:
    token, claim = auth_chain(endpoint, host, store, label="i1")
    app_store = sandbox_store_path()
    assert app_store.exists(), f"app 沙箱存储缺失: {app_store}"
    raw = app_store.read_bytes()
    data = json.loads(raw)  # jsonDecode 成功（损坏场景由 I3 覆盖）
    assert data.get("version") == 1, f"version: {data.get('version')!r}"
    assert token.encode() not in raw, "红线: app 沙箱字节含明文 token"
    rows = data.get("tokens", [])
    assert isinstance(rows, list) and rows, "app 沙箱 tokens 空表"
    assert "tokenHash" in rows[-1], f"tokenHash 缺失: {rows[-1]!r}"
    py = json.loads(store.read_text(encoding="utf-8"))
    assert py["tokens"]["ios-sim"]["token"] == token, "python tokens.json 无对应行"
    assert "expiresAt" in claim, f"claim 无 expiresAt: {claim!r}"
    results["I1"] = "pass"
    print(f"  I1 PASS: claim 200 + 双侧落盘(app={len(rows)} 行只含 hash;"
          f"python tokens.json 有行;claim expiresAt={claim['expiresAt']})")
    return token


def i2_cold_restart(token: str, store: Path) -> None:
    endpoint = restart_app()
    host = endpoint.replace("http://", "")
    st, body = http_json(endpoint, "GET", "/hello", bearer=token)
    assert st == 200 and body.get("authStatus") == "authorized", \
        f"冷重启旧 Bearer /hello: {st} {body!r:.80}"
    st, body = http_json(endpoint, "POST", "/debug/secure-action",
                         body={"via": "r005-i2"}, bearer=token)
    assert st == 200, f"敏感路由: {st} {body!r:.80}"
    # 零 /auth/request：本轮重启后 python 侧 store 行 token 未变
    py = json.loads(store.read_text(encoding="utf-8"))
    assert py["tokens"]["ios-sim"]["token"] == token, \
        "I2 期间发生重授权(违反零 /auth/request)"
    results["I2"] = "pass"
    print("  I2 PASS: 冷重启(terminate+relaunch)后旧 Bearer /hello 200 "
          "authStatus=authorized;敏感路由 200;零 /auth/request")


def i3_corrupt_self_heal(token: str, store: Path) -> str:
    sandbox_store_path().write_text('{"version":1,"tokens":[BROKEN',
                                    encoding="utf-8")
    endpoint = restart_app()
    host = endpoint.replace("http://", "")
    st, body = http_json(endpoint, "POST", "/debug/secure-action",
                         body={"via": "r005-i3"}, bearer=token)
    assert st == 401 and body.get("code") == "invalid_token", \
        f"损坏重启后旧 token 应 401 invalid_token: {st} {body!r:.60}"
    new_token, _claim = auth_chain(endpoint, host, store, label="i3")
    raw = sandbox_store_path().read_bytes()
    json.loads(raw)  # claim persist 覆盖损坏文件,不再抛
    assert new_token.encode() not in raw, "红线: 重写后沙箱字节含明文 token"
    results["I3"] = "pass"
    print("  I3 PASS: 截断 JSON 重启→401 invalid_token→重授权 claim 成功"
          "→沙箱文件恢复合法 JSON(且无明文)")
    return new_token


def i4_ttl(token: str, store: Path) -> str:
    data = json.loads(store.read_text(encoding="utf-8"))
    expires_at = data["tokens"]["ios-sim"]["expiresAt"]
    exp = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    delta = (exp - datetime.now(timezone.utc)).total_seconds()
    assert 604790 <= delta <= 604810, f"expiresAt-now={delta:.0f}s 超出窗口"
    # 篡改 app 沙箱行 expiresAt 为过去(tokenHash 不变,合法 JSON)
    app_store = sandbox_store_path()
    data = json.loads(app_store.read_text(encoding="utf-8"))
    rows = data["tokens"]
    assert rows, "I4 前置: app 沙箱 tokens 空表"
    rows[-1]["expiresAt"] = "2000-01-01T00:00:00.000Z"
    app_store.write_text(json.dumps(data, indent=2), encoding="utf-8")
    endpoint = restart_app()
    host = endpoint.replace("http://", "")
    # BF001 load 丢弃过期行 → tokenByHash 未命中 → 401 invalid_token
    # (TTL 语义经 load-discard 达成,非 token_expired 码——按实现断言)
    st, body = http_json(endpoint, "POST", "/debug/secure-action",
                         body={"via": "r005-i4"}, bearer=token)
    assert st == 401 and body.get("code") == "invalid_token", \
        f"过期行重启后应 401 invalid_token(load-discard): {st} {body!r:.60}"
    fresh_token, _claim = auth_chain(endpoint, host, store, label="i4")
    results["I4"] = "pass"
    print(f"  I4 PASS: TTL 窗口 {delta:.0f}s(∈[604790,604810]);过期行重启"
          "→401 invalid_token(load-discard);重授权链可达")
    return fresh_token


def i5_wire_regression(endpoint: str, token: str) -> None:
    st, _ = http_json(endpoint, "POST", "/debug/secure-action",
                      body={"via": "r005"})
    assert st == 401, f"no-token: {st}"
    st, body = http_json(endpoint, "POST", "/debug/secure-action",
                         body={"via": "r005"}, bearer="tok-forged-r005")
    assert st == 401 and body.get("code") == "invalid_token", \
        f"forged: {st} {body!r:.60}"
    nonce = f"r005-i5-{uuid.uuid4().hex[:8]}"
    st, body = http_json(endpoint, "POST", "/auth/request",
                         {"clientLabel": "hold-r005-i5", "clientNonce": nonce})
    rid = body.get("requestId")
    st, body = http_json(endpoint, "POST", "/auth/claim",
                         {"requestId": rid, "clientNonce": nonce})
    assert st == 200 and body.get("status") == "pending" and "token" not in body, \
        f"pending claim: {st} {body!r:.60}"
    st, body = http_json(endpoint, "POST", "/debug/echo",
                         body={"r005": "multi"}, bearer=token)
    assert st == 200 and body.get("capability") == "debug.echo", \
        f"echo: {st} {body!r:.60}"
    results["I5"] = "pass"
    print("  I5 PASS: no-token 401 / forged 401 invalid_token / "
          "pending claim 无泄漏 / 多 capability Bearer")


def main() -> int:
    global UDID, BUNDLE, EXAMPLE_DIR, DRIVER_SECONDS
    ap = argparse.ArgumentParser()
    ap.add_argument("endpoint")
    ap.add_argument("udid")
    ap.add_argument("bundle_id")
    ap.add_argument("--example-dir", default=str(EXAMPLE_DIR))
    ap.add_argument("--driver-seconds", type=int, default=90)
    args = ap.parse_args()
    UDID, BUNDLE = args.udid, args.bundle_id
    EXAMPLE_DIR = Path(args.example_dir)
    DRIVER_SECONDS = args.driver_seconds
    endpoint = args.endpoint
    host = endpoint.replace("http://", "")
    store = Path(tempfile.mkdtemp()) / "tokens.json"
    print(f"[R005 iOS 集成] endpoint={endpoint} udid={UDID} bundle={BUNDLE}")
    print(f"[R005 iOS 集成] python store={store} driver_seconds={DRIVER_SECONDS}")

    token = i1_first_auth(endpoint, host, store)
    i2_cold_restart(token, store)
    # I2 重启后 endpoint 已变;I3/I4 链内各自再重启自取新 endpoint
    new_token = i3_corrupt_self_heal(token, store)
    # I4 篡改的正是 I3 token 的沙箱行,重启后该 token 失效;
    # I5 用 I4 重授权的新 token
    fresh_token = i4_ttl(new_token, store)
    # I4 重启后 _last_endpoint 已更新;I5 复用最新 plane
    wait_hello(current_endpoint())
    i5_wire_regression(current_endpoint(), fresh_token)
    print()
    for k in sorted(results):
        print(f"SCENARIO {k}: {results[k]}")
    ok = all(v == "pass" for v in results.values()) and len(results) == 5
    print(f"IOS_E2E_STATUS: {'pass' if ok else 'fail'}")
    if _driver_proc is not None:
        _driver_proc.terminate()
    return 0 if ok else 1


_last_endpoint = ""


def current_endpoint() -> str:
    return _last_endpoint


if __name__ == "__main__":
    raise SystemExit(main())
