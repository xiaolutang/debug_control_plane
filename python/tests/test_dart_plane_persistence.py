"""R005-BF002 — dart plane token 持久化验收入口（pytest 侧子集）。

消费「已在运行的 example app Dart plane endpoint」（R002-BF005 双通道：
pytest ``--endpoint`` option 或 env ``ACCEPTANCE_ENDPOINT``；由
``.dev-flow/R005/test-overrides/R005-BF002/run-integration.sh`` 驱动或
操作者手动启动）。两者皆缺 → 每用例 ``pytest.skip(setup_required)``，
绝不误报 pass。session 级健康探测 GET /hello 不可达 → 全部
skip(setup_required: endpoint unreachable)。

覆盖范围（明示）：
  - 本文件只覆盖 I1/I4-TTL/I5 的 wire 子集 + I1 的 python 侧落盘断言。
  - I2（冷重启）/ I3（损坏自愈）/ I4 的「篡改 app 沙箱文件 + simctl
    terminate/relaunch」部分**仅在驱动脚本执行**（需要 simctl udid/bundle
    与 driver 重启能力，pytest 会话内不掌握这些环境句柄），对应断言在
    ``.dev-flow/R005/test-overrides/R005-BF002/ios-simulator-persistence.py``
    （I1-I5 全量）。
  - 全量执行入口：``bash .dev-flow/R005/test-overrides/R005-BF002/run-integration.sh``。

Refs:
  - tasks: .dev-flow/R005/dart-plane-token-persistence-tasks.md (R005-BF002)
  - pattern: python/tests/test_acceptance_flutter_app_auth.py (R002-BF005)
  - wire source: flutter_debug_control_plane/example/lib/src/acceptance_plane.dart
"""

from __future__ import annotations

import json
import os
import stat
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pytest

_ENDPOINT_ENV = "ACCEPTANCE_ENDPOINT"
_REQUEST_TIMEOUT = 5.0
_APPROVE_WAIT_TIMEOUT = 30.0
_POLL_INTERVAL = 0.5


def _get_pytest_endpoint(request: pytest.FixtureRequest) -> str | None:
    """--endpoint option 优先，其次 ACCEPTANCE_ENDPOINT，皆缺返回 None。"""
    option_value = request.config.getoption("--endpoint")
    return option_value or os.environ.get(_ENDPOINT_ENV) or None


def _http_json(endpoint: str, method: str, path: str,
               body: dict[str, Any] | None = None, bearer: str | None = None,
               timeout: float = _REQUEST_TIMEOUT) -> tuple[int, Any]:
    url = endpoint.rstrip("/") + path
    data = json.dumps(body or {}).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if bearer:
        req.add_header("Authorization", f"Bearer {bearer}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else {})
        except ValueError:
            return e.code, raw.decode(errors="replace")


class _EndpointUnreachable(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


@pytest.fixture(scope="session")
def plane_endpoint(request: pytest.FixtureRequest) -> str:
    """endpoint 解析 + session 级健康探测；缺/不可达 → skip(setup_required)。

    与 test_acceptance_flutter_app_auth.py 同模式：session fixture 内直接
    pytest.skip，依赖用例呈现 skip 而非 error。
    """
    endpoint = _get_pytest_endpoint(request)
    if not endpoint:
        pytest.skip("setup_required: no endpoint (use --endpoint or ACCEPTANCE_ENDPOINT)")
    try:
        st, _ = _http_json(endpoint, "GET", "/hello", timeout=3.0)
        if st != 200:
            pytest.skip(f"setup_required: endpoint unreachable (/hello -> {st})")
    except Exception as e:  # noqa: BLE001
        pytest.skip(f"setup_required: endpoint unreachable ({type(e).__name__}: {e})")
    return endpoint


@pytest.fixture
def endpoint_or_skip(plane_endpoint: str) -> str:
    """session 探测通过的 endpoint（失败已在 session fixture skip）。"""
    return plane_endpoint


def _wait_approved(endpoint: str, rid: str, nonce: str,
                   timeout: float = _APPROVE_WAIT_TIMEOUT) -> None:
    """轮询等 driver（按 clientLabel 非 deny*/hold* 自动 approve）。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        st, body = _http_json(endpoint, "POST", "/auth/status",
                              {"requestId": rid, "clientNonce": nonce})
        if st == 200 and isinstance(body, dict) and body.get("status") == "approved":
            return
        if st == 403:
            raise AssertionError(f"denied: {body}")
        time.sleep(_POLL_INTERVAL)
    raise AssertionError(f"approve timeout for {rid}")


def _auth_chain(endpoint: str, store: Path,
                label: str) -> tuple[str, dict[str, Any]]:
    """授权链（标准库 urllib 版，与 R002 模式一致）。"""
    nonce = f"r005-py-{label}-{uuid.uuid4().hex[:8]}"
    st, body = _http_json(endpoint, "POST", "/auth/request",
                          {"clientLabel": f"r005-py-{label}", "clientNonce": nonce})
    assert st in (200, 202), f"/auth/request: {st} {body!r:.60}"
    rid = body["requestId"]
    _wait_approved(endpoint, rid, nonce)
    st, body = _http_json(endpoint, "POST", "/auth/claim",
                          {"requestId": rid, "clientNonce": nonce})
    assert st == 200 and isinstance(body.get("token"), str), \
        f"/auth/claim: {st} {body!r:.60}"
    # python 侧 FileTokenProvider 落盘（等价 R004 S1 语义）
    row = {"token": body["token"], "tokenId": body.get("tokenId"),
           "expiresAt": body.get("expiresAt"), "obtainedAt": datetime.now(timezone.utc).isoformat()}
    store.parent.mkdir(parents=True, exist_ok=True)
    store.write_text(json.dumps({"version": 1, "tokens": {"ios-sim": row}},
                                indent=2), encoding="utf-8")
    os.chmod(store, 0o600)
    return body["token"], body


@pytest.fixture
def claimed(endpoint_or_skip: str, tmp_path: Path) -> tuple[str, dict[str, Any]]:
    """session 内每用例独立授权链（新 nonce 新 token）。"""
    return _auth_chain(endpoint_or_skip, tmp_path / "tokens.json", "case")


# ---------------------------------------------------------------------------
# 用例（I1/I4-TTL/I5 子集；I2/I3 仅驱动脚本执行，见模块 docstring）
# ---------------------------------------------------------------------------

def test_i1_first_auth_python_side(claimed: tuple[str, dict[str, Any]],
                                   tmp_path: Path) -> None:
    """I1 子集（python 侧）：claim 200 + token 落盘 0600 + expiresAt 在场。

    I1 的 app 沙箱断言（Documents/debug_control_plane/debug_auth_tokens.json
    存在/version==1/字节无明文）仅在驱动脚本执行（需 simctl 沙箱句柄）。
    """
    token, claim = claimed
    assert token, "claim token 空"
    store = tmp_path / "tokens.json"
    data = json.loads(store.read_text(encoding="utf-8"))
    row = data["tokens"]["ios-sim"]
    assert row["token"] == token, "落盘 token 与 claim 不一致"
    mode = stat.S_IMODE(store.stat().st_mode)
    assert mode == 0o600, f"权限 {oct(mode)} != 0600"
    assert row["tokenId"] and row["expiresAt"], f"metadata 未并入: {row!r}"


def test_i4_ttl_window(claimed: tuple[str, dict[str, Any]]) -> None:
    """I4 子集（TTL 窗口）：claim expiresAt - now ∈ [604790, 604810]s。

    I4 的「篡改 app 沙箱 + 冷重启 → 401」部分仅在驱动脚本执行。
    """
    token, claim = claimed
    exp = datetime.fromisoformat(claim["expiresAt"].replace("Z", "+00:00"))
    delta = (exp - datetime.now(timezone.utc)).total_seconds()
    assert 604790 <= delta <= 604810, f"expiresAt-now={delta:.0f}s 超出窗口"


def test_i5_no_token_401(endpoint_or_skip: str) -> None:
    """I5：无 Authorization → 敏感路由 401。"""
    st, _ = _http_json(endpoint_or_skip, "POST", "/debug/secure-action",
                       body={"via": "r005-py"})
    assert st == 401, f"no-token: {st}"


def test_i5_forged_401_invalid_token(endpoint_or_skip: str) -> None:
    """I5：伪造 Bearer → 401 invalid_token。"""
    st, body = _http_json(endpoint_or_skip, "POST", "/debug/secure-action",
                          body={"via": "r005-py"}, bearer="tok-forged-r005")
    assert st == 401 and body.get("code") == "invalid_token", \
        f"forged: {st} {body!r:.60}"


def test_i5_pending_claim_no_token_leak(endpoint_or_skip: str) -> None:
    """I5：hold* 前缀保持 pending → claim 200 status=pending 且无 token。"""
    nonce = f"r005-py-hold-{uuid.uuid4().hex[:8]}"
    st, body = _http_json(endpoint_or_skip, "POST", "/auth/request",
                          {"clientLabel": "hold-r005-py", "clientNonce": nonce})
    rid = body.get("requestId")
    assert st in (200, 202) and rid, f"/auth/request: {st} {body!r:.60}"
    st, body = _http_json(endpoint_or_skip, "POST", "/auth/claim",
                          {"requestId": rid, "clientNonce": nonce})
    assert st == 200 and body.get("status") == "pending" and "token" not in body, \
        f"pending claim: {st} {body!r:.60}"


def test_i5_bearer_multi_capability(endpoint_or_skip: str,
                                    claimed: tuple[str, dict[str, Any]]) -> None:
    """I5：真 token Bearer 走 /debug/echo（capability 语义回归）。"""
    token, _ = claimed
    st, body = _http_json(endpoint_or_skip, "POST", "/debug/echo",
                          body={"r005": "multi"}, bearer=token)
    assert st == 200 and body.get("capability") == "debug.echo", \
        f"echo: {st} {body!r:.60}"
