"""R002-BF005 — example app auth claim acceptance runner (real endpoint).

消费「已在运行的 example app Dart plane endpoint」(loopback, 由 flutter
integration driver 或操作者启动), 完整走 R001 auth wire 链路:

  POST /auth/request → POST /auth/status (轮询等 approve, 30s 上限)
  → POST /auth/claim (token + expiresAt) → Bearer 调敏感路由 → 200
  → 无 token/伪造 token → 401

Endpoint 解析双通道: pytest ``--endpoint`` option 或 env
``ACCEPTANCE_ENDPOINT``; 两者皆缺 → 每用例 ``pytest.skip(setup_required)``,
绝不误报 pass。session 级健康探测 (GET /hello) 不可达 → 全部
skip(setup_required: endpoint unreachable); 运行中断连 → FAIL + 稳定
单行原因 (无裸 traceback)。

Refs:
  - contract: .dev-flow/R002/contracts/R002-BF005.md
  - wire source: flutter_debug_control_plane/example/lib/src/acceptance_plane.dart
  - design: .dev-flow/R001/analysis/2026-08-20--debug-plane-auth-design.md
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from collections.abc import Iterator
from typing import Any

import pytest

# ---------------------------------------------------------------------------
# endpoint 参数化 (option + env 双通道, contract Q2; addoption 在 conftest.py)
# ---------------------------------------------------------------------------

_ENDPOINT_ENV = "ACCEPTANCE_ENDPOINT"
_REQUEST_TIMEOUT = 5.0  # 单请求超时 (秒)
_APPROVE_WAIT_TIMEOUT = 30.0  # 等 approve 轮询上限 (秒)
_POLL_INTERVAL = 0.5


def _get_pytest_endpoint(request: pytest.FixtureRequest) -> str | None:
    """--endpoint option 优先, 其次 ACCEPTANCE_ENDPOINT, 皆缺返回 None。"""
    option_value = request.config.getoption("--endpoint")
    return option_value or os.environ.get(_ENDPOINT_ENV) or None


# ---------------------------------------------------------------------------
# HTTP helper (标准库 urllib, 零第三方依赖)
# ---------------------------------------------------------------------------


class EndpointUnreachable(Exception):
    """健康探测不可达 → 全部 skip(setup_required)。"""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class ConnectionLost(Exception):
    """用例运行中断连 → 该用例 FAIL (稳定单行原因)。"""


class HttpResponse:
    def __init__(self, status: int, body: dict[str, Any]) -> None:
        self.status = status
        self.body = body

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return f"HttpResponse(status={self.status}, body={self.body!r})"


def http_call(
    endpoint: str,
    method: str,
    path: str,
    body: dict[str, Any] | None = None,
    bearer: str | None = None,
    timeout: float = _REQUEST_TIMEOUT,
) -> HttpResponse:
    """Single HTTP call; connection errors raise ConnectionLost (stable msg)."""
    url = endpoint.rstrip("/") + path
    data = json.dumps(body or {}).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if bearer is not None:
        request.add_header("Authorization", f"Bearer {bearer}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            payload = json.loads(raw) if raw else {}
            return HttpResponse(response.status, payload)
    except urllib.error.HTTPError as error:
        raw = error.read()
        payload: dict[str, Any] = {}
        try:
            payload = json.loads(raw) if raw else {}
        except (ValueError, UnicodeDecodeError):
            payload = {}
        return HttpResponse(error.code, payload)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        reason = getattr(error, "reason", error)
        raise ConnectionLost(f"{url}: {type(error).__name__}: {reason}") from None


# ---------------------------------------------------------------------------
# fixtures: session 健康探测 + endpoint 解析
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def endpoint(request: pytest.FixtureRequest) -> Iterator[str]:
    """Resolve + health-probe the endpoint; unreachable → all skip."""
    value = _get_pytest_endpoint(request)
    if not value:
        pytest.skip("setup_required: no endpoint (use --endpoint or "
                    f"{_ENDPOINT_ENV})")
    try:
        hello = http_call(value, "GET", "/hello", timeout=_REQUEST_TIMEOUT)
    except ConnectionLost as error:
        pytest.skip(f"setup_required: endpoint unreachable ({error})")
    if hello.status != 200:
        pytest.skip(
            f"setup_required: endpoint unhealthy (GET /hello → {hello.status})")
    yield value


# ---------------------------------------------------------------------------
# auth flow helpers (R001 wire 协议)
# ---------------------------------------------------------------------------


def request_authorization(
    endpoint: str, client_label: str, client_nonce: str | None = None,
) -> HttpResponse:
    body: dict[str, Any] = {"clientLabel": client_label}
    if client_nonce is not None:
        body["clientNonce"] = client_nonce
    return http_call(endpoint, "POST", "/auth/request", body)


def authorization_status(
    endpoint: str, request_id: str, client_nonce: str | None = None,
) -> HttpResponse:
    body: dict[str, Any] = {"requestId": request_id}
    if client_nonce is not None:
        body["clientNonce"] = client_nonce
    return http_call(endpoint, "POST", "/auth/status", body)


def claim_authorization(
    endpoint: str, request_id: str, client_nonce: str | None = None,
) -> HttpResponse:
    body: dict[str, Any] = {"requestId": request_id}
    if client_nonce is not None:
        body["clientNonce"] = client_nonce
    return http_call(endpoint, "POST", "/auth/claim", body)


def wait_until_approved(
    endpoint: str,
    request_id: str,
    client_nonce: str | None = None,
    timeout: float = _APPROVE_WAIT_TIMEOUT,
) -> None:
    """Poll /auth/status until approved; raise AssertionError with a stable
    one-line reason on timeout (client-side approval_timeout semantics)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        response = authorization_status(endpoint, request_id, client_nonce)
        if response.status == 200 and response.body.get("status") == "approved":
            return
        if response.status == 403:
            raise AssertionError(
                f"authorization denied while waiting approve: {response.body}")
        time.sleep(_POLL_INTERVAL)
    raise AssertionError(
        f"approve not delivered within {timeout:.0f}s for {request_id} "
        "(needs flutter-side driver; client-side approval timeout)")


# ---------------------------------------------------------------------------
# 用例
# ---------------------------------------------------------------------------


def test_acceptance_auth_claim_and_bearer_retry(endpoint: str) -> None:
    """主链路: request → status(approved) → claim → Bearer retry 200 + 401。"""
    nonce = f"bf005-main-{int(time.time())}"
    request = request_authorization(
        endpoint, client_label="bf005-pytest", client_nonce=nonce)
    assert request.status == 202, f"/auth/request → {request.status}"
    assert request.body.get("status") == "pending"
    request_id = request.body.get("requestId")
    assert isinstance(request_id, str) and request_id

    wait_until_approved(endpoint, request_id, nonce)

    claim = claim_authorization(endpoint, request_id, nonce)
    assert claim.status == 200, f"/auth/claim → {claim.status}: {claim.body}"
    token = claim.body.get("token")
    assert isinstance(token, str) and token, "claim must issue a token"
    assert claim.body.get("expiresAt"), "claim must return expiresAt"

    secured = http_call(
        endpoint, "POST", "/debug/secure-action",
        body={"via": "bf005"}, bearer=token)
    assert secured.status == 200, f"Bearer retry → {secured.status}"

    no_token = http_call(endpoint, "POST", "/debug/secure-action")
    assert no_token.status == 401, f"no token → {no_token.status}"


def test_forged_token_rejected_401(endpoint: str) -> None:
    """伪造 token → 401 invalid_token (协议级, 无需 approve)。"""
    forged = "tok-forged-bf005-0000000000"
    response = http_call(
        endpoint, "POST", "/debug/secure-action",
        body={"via": "bf005-forged"}, bearer=forged)
    assert response.status == 401, f"forged token → {response.status}"
    assert response.body.get("code") == "invalid_token", response.body


def test_claim_before_approval_rejected(endpoint: str) -> None:
    """claim 未 approved 的 requestId → 不发放 token。

    Wire 事实 (acceptance_plane.dart claimAuthorization): pending 状态的
    claim 返回 200 + {status:'pending'} 状态回显 (非 4xx — contract 预估的
    403/4xx 仅适用于 denied/unknown requestId); 本用例断言核心安全语义:
    无 token 泄漏 + status 回显 pending。
    """
    nonce = f"bf005-hold-{int(time.time())}"
    request = request_authorization(
        endpoint, client_label="hold-bf005", client_nonce=nonce)
    assert request.status == 202
    request_id = request.body["requestId"]

    claim = claim_authorization(endpoint, request_id, nonce)
    assert claim.status == 200, f"pending claim → {claim.status}: {claim.body}"
    assert claim.body.get("status") == "pending", claim.body
    assert "token" not in claim.body, f"token leaked on pending claim: {claim.body}"

    # unknown requestId → 401 invalid_token (真正的 4xx 负向)。
    bogus = claim_authorization(endpoint, "req-bf005-no-such-id", nonce)
    assert bogus.status == 401, f"unknown requestId claim → {bogus.status}"
    assert bogus.body.get("code") == "invalid_token", bogus.body

    status = authorization_status(endpoint, request_id, nonce)
    assert status.status == 200
    assert status.body.get("status") == "pending"


def test_multi_capability_bearer(endpoint: str) -> None:
    """多 capability: ≥2 个 fixed capability 带 Bearer 调用成功。"""
    nonce = f"bf005-multi-{int(time.time())}"
    request = request_authorization(
        endpoint, client_label="bf005-multi", client_nonce=nonce)
    assert request.status == 202
    request_id = request.body["requestId"]
    wait_until_approved(endpoint, request_id, nonce)
    claim = claim_authorization(endpoint, request_id, nonce)
    assert claim.status == 200
    token = claim.body["token"]

    echo = http_call(
        endpoint, "POST", "/debug/echo", body={"bf005": "multi"}, bearer=token)
    assert echo.status == 200, f"debug.echo → {echo.status}"
    assert echo.body.get("capability") == "debug.echo"

    info = http_call(endpoint, "GET", "/debug/device-info", bearer=token)
    assert info.status == 200, f"debug.deviceInfo → {info.status}"
    assert info.body.get("capability") == "debug.deviceInfo"


@pytest.mark.auth_denied_driver
def test_denied_flow(endpoint: str) -> None:
    """denied: flutter 侧驱动 denyPending (label 'deny*' 分派) 后 claim 403。

    无驱动信号 (env AUTH_DENIED_DRIVER != 1) → skip(setup_required)。
    """
    if os.environ.get("AUTH_DENIED_DRIVER") != "1":
        pytest.skip("setup_required: denied driver not available "
                    "(set AUTH_DENIED_DRIVER=1 when the flutter-side deny "
                    "driver is running)")
    nonce = f"bf005-deny-{int(time.time())}"
    request = request_authorization(
        endpoint, client_label="deny-bf005", client_nonce=nonce)
    assert request.status == 202
    request_id = request.body["requestId"]

    deadline = time.monotonic() + _APPROVE_WAIT_TIMEOUT
    denied = False
    while time.monotonic() < deadline:
        status = authorization_status(endpoint, request_id, nonce)
        if status.status == 403:
            denied = True
            break
        time.sleep(_POLL_INTERVAL)
    if not denied:
        raise AssertionError(
            f"deny not delivered within {_APPROVE_WAIT_TIMEOUT:.0f}s "
            "for request (needs flutter-side deny driver)")

    claim = claim_authorization(endpoint, request_id, nonce)
    assert claim.status == 403, f"claim after deny → {claim.status}"
    assert claim.body.get("code") == "authorization_denied", claim.body
    assert "token" not in claim.body
