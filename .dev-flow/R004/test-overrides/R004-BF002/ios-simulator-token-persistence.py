#!/usr/bin/env python3
"""R004 token 持久化 — iOS 模拟器集成验证(example app Dart plane)。

iOS 上 example app 走 Dart plane(acceptance_plane.dart,内存 token store),
故本脚本验证 BF001 python FileTokenProvider 全链路 + wire 契约:

  S1 首次授权链落盘     auth_request→status→claim → FileTokenProvider 落盘
                        tokens.json(0600,tokenId/expiresAt 并入)
  S2 新进程免授权       全新 provider 实例(模拟 python 重启)真实读盘
                        get_token 命中 → Bearer 复用 200,零 /auth/request
  S3 过期清行重授权     构造过期行 → get_token=None(读时判定) → 重授权链可达
                        → 手机 401 invalid_token 联动 clear_token(dart plane
                        重启后旧 token 不在 → invalid_token 路径)
  S4 wire 回归          既有 5 用例等价断言(forged 401/pending claim 无泄漏/
                        多 capability Bearer)

用法: python3 r004-ios-token-persistence.py <endpoint>
"""

from __future__ import annotations

import json
import os
import stat
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
    DeviceHttpError,
    DeviceAuthError,
)
from debug_control_plane.mcp_plane.token_provider import (  # noqa: E402
    FileTokenProvider,
)

results: dict[str, str] = {}


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
    """对 loopback endpoint 组一个 BridgeClient(device_id=ios-sim)。"""
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


def s1_first_auth(endpoint: str, host: str, store: Path) -> tuple[str, dict]:
    nonce = f"r004-ios-s1-{uuid.uuid4().hex[:8]}"
    provider = FileTokenProvider(path=store)
    client = make_client(provider, host)
    req = client.auth_request("ios-sim", nonce, client_label="r004-ios-s1")
    assert isinstance(req, dict) and req.get("requestId"), f"/auth/request: {req!r}"
    wait_approved(endpoint, req["requestId"], nonce)
    claim = client.auth_claim("ios-sim", req["requestId"], nonce)
    assert isinstance(claim, dict) and isinstance(claim.get("token"), str), f"claim: {claim!r}"
    token = claim["token"]
    # 落盘断言:文件存在 + 0600 + tokenId/expiresAt 并入
    data = json.loads(store.read_text(encoding="utf-8"))
    row = data["tokens"]["ios-sim"]
    assert row["token"] == token, "落盘 token 与 claim 不一致"
    mode = stat.S_IMODE(store.stat().st_mode)
    assert mode == 0o600, f"权限 {oct(mode)} != 0600"
    assert "tokenId" in row and "expiresAt" in row, f"metadata 未并入: {row!r}"
    results["S1"] = "pass"
    print(f"  S1 PASS: claim 200 + 落盘 0600(tokenId={row['tokenId'][:12]}..., "
          f"expiresAt={row['expiresAt']})")
    return token, claim


def s2_new_process_reuse(host: str, store: Path) -> None:
    # 新 provider 实例 = python 重启视角(真实读盘,非内存透传)
    provider = FileTokenProvider(path=store)
    token = provider.get_token("ios-sim")
    assert token, "新进程 get_token 未命中"
    st, body = http_json(f"http://{host}", "GET", "/hello", bearer=token)
    assert st == 200, f"Bearer 复用 /hello → {st} {body!r:.80}"
    # 零 /auth/request:BridgeClient invoke 直接带 Bearer,无需授权链
    client = make_client(provider, host)
    hello = client.hello("ios-sim")
    assert hello is not None, "BridgeClient.hello 经持久化 Bearer 失败"
    results["S2"] = "pass"
    print(f"  S2 PASS: 新 provider 实例读盘命中,Bearer 复用 200(hello 经 invoke 通道)")


def s3_expired_clear_and_reauth(endpoint: str, host: str, store: Path) -> None:
    data = json.loads(store.read_text(encoding="utf-8"))
    backup = dict(data["tokens"]["ios-sim"])
    data["tokens"]["ios-sim"]["expiresAt"] = "2000-01-01T00:00:00Z"
    store.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    provider = FileTokenProvider(path=store)
    got = provider.get_token("ios-sim")
    assert got is None, "过期行读时判定失败(get_token 应返回 None)"
    # 重授权链可达:新 pending 建立成功
    nonce = f"r004-ios-s3-{uuid.uuid4().hex[:8]}"
    req2 = make_client(FileTokenProvider(path=store), host).auth_request(
        "ios-sim", nonce, client_label="r004-ios-s3")
    assert isinstance(req2, dict) and req2.get("requestId"), f"重授权链: {req2!r}"
    # 401 invalid_token 联动 clear:用已不在 plane 的旧 token 打敏感路由
    # (dart plane 内存 store 无此 token → 401 invalid_token → clear_token)
    data = json.loads(store.read_text(encoding="utf-8"))
    data["tokens"]["ios-sim"] = {
        **backup, "expiresAt": "2099-01-01T00:00:00Z",
        "token": "dcp_forged_r004_ios_0000000000",
    }
    store.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    fresh = FileTokenProvider(path=store)
    client = make_client(fresh, host)
    try:
        client.invoke("ios-sim", "POST", ["debug", "echo"],
                      body={"r004": "forged"})  # 敏感路由走 401 联动
        raise AssertionError("伪造 token 竟然 200")
    except DeviceAuthError as e:
        assert e.code == "invalid_token", f"期望 invalid_token,得 {e.code}"
    assert fresh.get_token("ios-sim") is None, "401 后 clear_token 未删行"
    # 还原
    data = json.loads(store.read_text(encoding="utf-8"))
    data["tokens"]["ios-sim"] = backup
    store.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    results["S3"] = "pass"
    print("  S3 PASS: 过期读时判定 None + 重授权链可达 + 401 invalid_token 联动 clear_token")


def s4_wire_regression(endpoint: str, token: str) -> None:
    # forged 401
    st, body = http_json(endpoint, "POST", "/debug/secure-action",
                         body={"via": "r004-reg"}, bearer="tok-forged-r004")
    assert st == 401 and body.get("code") == "invalid_token", f"forged: {st} {body!r:.60}"
    # 无 token 401
    st, _ = http_json(endpoint, "POST", "/debug/secure-action", body={"via": "r004"})
    assert st == 401, f"no-token: {st}"
    # pending claim 无 token 泄漏
    nonce = f"r004-ios-s4-{uuid.uuid4().hex[:8]}"
    st, body = http_json(endpoint, "POST", "/auth/request",
                         {"clientLabel": "hold-r004", "clientNonce": nonce})
    rid = body.get("requestId")
    st, body = http_json(endpoint, "POST", "/auth/claim",
                         {"requestId": rid, "clientNonce": nonce})
    assert st == 200 and body.get("status") == "pending" and "token" not in body, \
        f"pending claim: {st} {body!r:.60}"
    # 多 capability Bearer(真 token)
    st, body = http_json(endpoint, "POST", "/debug/echo",
                         body={"r004": "multi"}, bearer=token)
    assert st == 200 and body.get("capability") == "debug.echo", f"echo: {st} {body!r:.60}"
    results["S4"] = "pass"
    print("  S4 PASS: forged 401 / no-token 401 / pending claim 无泄漏 / 多 capability Bearer")


def main() -> int:
    endpoint = sys.argv[1]
    host = endpoint.replace("http://", "")
    store = Path(tempfile.mkdtemp()) / "tokens.json"
    print(f"[R004 iOS 集成] endpoint={endpoint} store={store}")
    token, _claim = s1_first_auth(endpoint, host, store)
    s2_new_process_reuse(host, store)
    s3_expired_clear_and_reauth(endpoint, host, store)
    s4_wire_regression(endpoint, token)
    print()
    for k in sorted(results):
        print(f"SCENARIO {k}: {results[k]}")
    ok = all(v == "pass" for v in results.values()) and len(results) == 4
    print(f"IOS_E2E_STATUS: {'pass' if ok else 'fail'}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
