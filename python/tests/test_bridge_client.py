"""R020-BF008 BridgeClient 服务测试 (HTTP 转发手机 18080).

AC 覆盖:
  AC7 device_id IP TTL 过期 → resolve 触发重发现信号
     — mock pool.resolve_ip 返 is_stale=True → resolve() raise DeviceStale;
       found=False → DeviceUnreachable
  AC9 SSE → 结构化 DebugEvent (subscribe_events)
     — MockTransport 流式返 SSE 行 → events() yield DebugEvent; event_types filter

§2.1 BridgeClient 转发:
  invoke 透传 method/path/body; read 便捷; hello → NetworkTarget;
  path join 多段
§4.4 故障注入:
  409 real_controller_active 透传 (DeviceHttpError.status_code==409, body 保留);
  5xx/网络错误 (transport 失败)

设计来源:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF008 节
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
            §3.4 BridgeClient / §4.1 / §4.2.2 / §4.2.3
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1/§4.4

测试策略 (service 层, 不触网):
  httpx.MockTransport 注入: handler 接 httpx.Request 返 httpx.Response.
  SSE 流式 mock: Response(content=b"data: {...}\\n\\n", headers=...).
  DevicePool mock: 直接返回预设 ResolveResult.
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

import httpx
import pytest

from debug_control_plane.device_discovery.device_pool import ResolveResult
from debug_control_plane.mcp_plane.bridge_client import (
    BridgeClient,
    BridgeError,
    DeviceAuthError,
    DeviceHttpError,
    DeviceStale,
    DeviceUnreachable,
    _iter_sse,
    _safe_body,
    selector_headers,
)

# ---------------------------------------------------------------------------
# Mock helpers
# ---------------------------------------------------------------------------


@dataclass
class _MockPool:
    """DevicePool 替身: 按预置映射返 ResolveResult (不调真实池)."""

    by_device: dict[str, ResolveResult]
    calls: list[str]

    def resolve_ip(self, device_id: str, *, now: float | None = None) -> ResolveResult:
        self.calls.append(device_id)
        return self.by_device.get(
            device_id,
            ResolveResult(host=None, is_stale=True, found=False),
        )


@dataclass
class _FakeTokenProvider:
    tokens: dict[str, str | None]
    get_calls: list[str]
    saved: list[tuple[str, str, dict[str, Any]]]
    cleared: list[tuple[str, str]]

    def get_token(self, device_id: str) -> str | None:
        self.get_calls.append(device_id)
        return self.tokens.get(device_id)

    def save_token(
        self, device_id: str, token: str, metadata: Mapping[str, Any]
    ) -> None:
        self.saved.append((device_id, token, dict(metadata)))
        self.tokens[device_id] = token

    def clear_token(self, device_id: str, reason: str) -> None:
        self.cleared.append((device_id, reason))
        self.tokens.pop(device_id, None)


def _fresh(host: str = "192.168.1.34") -> ResolveResult:
    return ResolveResult(host=host, is_stale=False, found=True)


def _stale(host: str | None = "192.168.1.34") -> ResolveResult:
    return ResolveResult(host=host, is_stale=True, found=True)


def _unknown() -> ResolveResult:
    return ResolveResult(host=None, is_stale=True, found=False)


def _make_client(
    pool: _MockPool,
    handler,
    *,
    port: int = 18080,
    token_provider: _FakeTokenProvider | None = None,
) -> BridgeClient:
    """构造一个注入 MockTransport 的 BridgeClient."""
    transport = httpx.MockTransport(handler)
    http_client = httpx.Client(transport=transport)
    return BridgeClient(
        pool=pool, port=port, client=http_client, token_provider=token_provider
    )


def _ok_json(body: Any, status: int = 200) -> httpx.Response:
    return httpx.Response(status, json=body)


def _ok_text(text: str, status: int = 200) -> httpx.Response:
    return httpx.Response(status, text=text)


def _auth_error(code: str, status: int = 401) -> httpx.Response:
    return httpx.Response(
        status,
        json={
            "ok": False,
            "code": code,
            "message": f"Debug auth test error: {code}",
        },
    )


# ---------------------------------------------------------------------------
# resolve() three-state (AC7)
# ---------------------------------------------------------------------------


class TestResolve:
    """resolve() 按 BF001 ResolveResult 三态分发异常."""

    def test_unknown_device_raises_unreachable(self):
        pool = _MockPool({"dev1": _unknown()}, [])
        client = _make_client(pool, lambda req: _ok_json({}))
        with pytest.raises(DeviceUnreachable):
            client.resolve("dev1")

    def test_stale_raises_device_stale(self):
        # AC7: TTL 过期 → DeviceStale (不静默用 stale IP)
        pool = _MockPool({"dev1": _stale()}, [])
        client = _make_client(pool, lambda req: _ok_json({}))
        with pytest.raises(DeviceStale):
            client.resolve("dev1")

    def test_fresh_returns_host(self):
        pool = _MockPool({"dev1": _fresh("10.0.0.5")}, [])
        client = _make_client(pool, lambda req: _ok_json({}))
        assert client.resolve("dev1") == "10.0.0.5"

    def test_fresh_no_host_raises_unreachable(self):
        # Defensive: found=True+is_stale=False 但 host=None (不应发生, 但容错)
        pool = _MockPool(
            {"dev1": ResolveResult(host=None, is_stale=False, found=True)}, []
        )
        client = _make_client(pool, lambda req: _ok_json({}))
        with pytest.raises(DeviceUnreachable):
            client.resolve("dev1")

    def test_resolve_asks_pool_every_time(self):
        # 不缓存 IP: 每次调用都问 pool (IP TTL 变化即时生效)
        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, lambda req: _ok_json({}))
        client.resolve("dev1")
        client.resolve("dev1")
        client.resolve("dev1")
        assert pool.calls == ["dev1", "dev1", "dev1"]


# ---------------------------------------------------------------------------
# invoke() pass-through (§2.1)
# ---------------------------------------------------------------------------


class TestInvoke:
    """invoke: 透传 method/path/body; path join; 错误透传 (§4.4)."""

    def test_post_forwards_method_url_json(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({"ok": True, "profileId": "p1"})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        body = {"profileId": "default"}
        result = client.invoke("dev1", "POST", ["virtual", "connect"], body)

        assert result == {"ok": True, "profileId": "p1"}
        assert len(captured) == 1
        req = captured[0]
        assert req.method == "POST"
        assert req.url.path == "/virtual/connect"
        assert json.loads(req.content) == body

    def test_get_with_path_segment_id(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({"id": "abc", "name": "profile-abc"})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        result = client.invoke("dev1", "GET", ["profiles", "abc"], None)

        assert result == {"id": "abc", "name": "profile-abc"}
        assert captured[0].url.path == "/profiles/abc"

    def test_post_input_frame(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({"accepted": True})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        frame = {"dpad": "up", "buttons": ["a"]}
        client.invoke("dev1", "POST", ["input"], frame)

        assert captured[0].url.path == "/input"
        assert json.loads(captured[0].content) == frame

    def test_409_real_controller_active_passthrough(self):
        # §4.4: 409 real_controller_active 必须让 AI 看到错误码
        def handler(req: httpx.Request) -> httpx.Response:
            return httpx.Response(
                409,
                json={"errorCode": "real_controller_active",
                      "message": "real controller is connected"},
            )

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        with pytest.raises(DeviceHttpError) as exc_info:
            client.invoke("dev1", "POST", ["virtual", "connect"], {})

        err = exc_info.value
        assert err.status_code == 409
        # body 保留 (AI 能看到 errorCode)
        assert err.body == {
            "errorCode": "real_controller_active",
            "message": "real controller is connected",
        }

    def test_5xx_raises_http_error(self):
        def handler(req: httpx.Request) -> httpx.Response:
            return httpx.Response(500, text="internal server error")

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        with pytest.raises(DeviceHttpError) as exc_info:
            client.invoke("dev1", "GET", ["state"], None)
        assert exc_info.value.status_code == 500

    def test_transport_failure_raises_http_error_status_zero(self):
        def handler(req: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("connection refused")

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        with pytest.raises(DeviceHttpError) as exc_info:
            client.invoke("dev1", "GET", ["state"], None)
        # 0 = transport 失败 (无 HTTP 响应)
        assert exc_info.value.status_code == 0

    def test_unreachable_device_raises_before_request(self):
        # resolve 失败时不应发任何请求
        called = {"count": 0}

        def handler(req: httpx.Request) -> httpx.Response:
            called["count"] += 1
            return _ok_json({})

        pool = _MockPool({"dev1": _unknown()}, [])
        client = _make_client(pool, handler)
        with pytest.raises(DeviceUnreachable):
            client.invoke("dev1", "GET", ["state"], None)
        assert called["count"] == 0

    def test_stale_device_raises_before_request(self):
        called = {"count": 0}

        def handler(req: httpx.Request) -> httpx.Response:
            called["count"] += 1
            return _ok_json({})

        pool = _MockPool({"dev1": _stale()}, [])
        client = _make_client(pool, handler)
        with pytest.raises(DeviceStale):
            client.invoke("dev1", "GET", ["state"], None)
        assert called["count"] == 0

    def test_body_none_get_no_content(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        client.invoke("dev1", "GET", ["state"], None)
        # GET 请求 body 应为空
        assert captured[0].content in (b"", None)

    def test_non_dict_body_passes_through(self):
        # body 非 dict/list → content= 透传 (raw bytes/str)
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        client.invoke("dev1", "POST", ["raw"], b"hello-bytes")
        assert captured[0].content == b"hello-bytes"

    def test_selector_headers_forwarded_with_auth_header(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({"ok": True})

        pool = _MockPool({"dev1": _fresh()}, [])
        provider = _FakeTokenProvider({"dev1": "token-1"}, [], [], [])
        client = _make_client(pool, handler, token_provider=provider)

        client.invoke(
            "dev1",
            "POST",
            ["debug", "tap"],
            {},
            capability_id="debug",
            scope="page",
            page_id="page-a",
            scope_revision=7,
        )

        headers = captured[0].headers
        assert headers["Authorization"] == "Bearer token-1"
        assert headers["X-DCP-Capability-Id"] == "debug"
        assert headers["X-DCP-Capability-Scope"] == "page"
        assert headers["X-DCP-Page-Id"] == "page-a"
        assert headers["X-DCP-Scope-Revision"] == "7"

    def test_no_selector_keeps_legacy_headers(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({"ok": True})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        client.invoke("dev1", "POST", ["debug", "tap"], {})

        assert "X-DCP-Capability-Id" not in captured[0].headers
        assert "X-DCP-Capability-Scope" not in captured[0].headers
        assert "X-DCP-Page-Id" not in captured[0].headers
        assert "X-DCP-Scope-Revision" not in captured[0].headers


# ---------------------------------------------------------------------------
# auth token provider + auth error taxonomy (R001-BF009)
# ---------------------------------------------------------------------------


class TestBridgeAuth:
    def test_invoke_read_hello_events_inject_bearer_from_provider(self):
        captured: list[httpx.Request] = []
        event_payload = json.dumps({"type": "state", "sequence": 1})

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            if req.url.path == "/events":
                return _sse_response([(event_payload, None)])
            if req.url.path == "/hello":
                return _ok_json(TestHello()._hello_payload())
            return _ok_json({"ok": True})

        pool = _MockPool({"dev1": _fresh()}, [])
        provider = _FakeTokenProvider({"dev1": "test-token-plain"}, [], [], [])
        client = _make_client(pool, handler, token_provider=provider)

        client.invoke("dev1", "POST", ["virtual", "connect"], {})
        client.read("dev1", ["state"])
        client.hello("dev1")
        list(client.events("dev1"))

        assert [req.url.path for req in captured] == [
            "/virtual/connect",
            "/state",
            "/hello",
            "/events",
        ]
        assert all(
            req.headers.get("Authorization") == "Bearer test-token-plain"
            for req in captured
        )
        assert provider.get_calls == ["dev1", "dev1", "dev1", "dev1"]

    def test_missing_token_sends_no_authorization_and_app_401_surfaces(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _auth_error("authorization_required")

        pool = _MockPool({"dev1": _fresh()}, [])
        provider = _FakeTokenProvider({"dev1": None}, [], [], [])
        client = _make_client(pool, handler, token_provider=provider)

        with pytest.raises(DeviceAuthError) as exc_info:
            client.read("dev1", ["state"])

        assert "Authorization" not in captured[0].headers
        assert exc_info.value.status_code == 401
        assert exc_info.value.code == "authorization_required"
        assert provider.cleared == []

    @pytest.mark.parametrize(
        "code",
        ["invalid_token", "token_expired", "token_revoked"],
    )
    def test_401_clear_token_codes_clear_provider_token(self, code: str):
        def handler(req: httpx.Request) -> httpx.Response:
            return _auth_error(code)

        pool = _MockPool({"dev1": _fresh()}, [])
        provider = _FakeTokenProvider({"dev1": "old-token"}, [], [], [])
        client = _make_client(pool, handler, token_provider=provider)

        with pytest.raises(DeviceAuthError) as exc_info:
            client.invoke("dev1", "GET", ["state"], None)

        assert exc_info.value.code == code
        assert exc_info.value.body["code"] == code
        assert provider.cleared == [("dev1", code)]
        assert provider.tokens == {}

    @pytest.mark.parametrize(
        ("code", "status"),
        [("authorization_required", 401), ("authorization_denied", 403), ("forbidden", 403)],
    )
    def test_auth_codes_that_do_not_invalidate_token_do_not_clear(
        self, code: str, status: int
    ):
        def handler(req: httpx.Request) -> httpx.Response:
            return _auth_error(code, status)

        pool = _MockPool({"dev1": _fresh()}, [])
        provider = _FakeTokenProvider({"dev1": "still-valid"}, [], [], [])
        client = _make_client(pool, handler, token_provider=provider)

        with pytest.raises(DeviceAuthError) as exc_info:
            client.read("dev1", ["state"])

        assert exc_info.value.status_code == status
        assert exc_info.value.code == code
        assert provider.cleared == []
        assert provider.tokens == {"dev1": "still-valid"}

    def test_non_auth_http_error_keeps_device_http_error(self):
        def handler(req: httpx.Request) -> httpx.Response:
            return httpx.Response(401, json={"errorCode": "legacy_error"})

        pool = _MockPool({"dev1": _fresh()}, [])
        provider = _FakeTokenProvider({"dev1": "token"}, [], [], [])
        client = _make_client(pool, handler, token_provider=provider)

        with pytest.raises(DeviceHttpError) as exc_info:
            client.read("dev1", ["state"])

        assert not isinstance(exc_info.value, DeviceAuthError)
        assert provider.cleared == []

    def test_events_auth_error_iterates_generator_and_clears_expired_token(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _auth_error("token_expired")

        pool = _MockPool({"dev1": _fresh()}, [])
        provider = _FakeTokenProvider({"dev1": "expired-token"}, [], [], [])
        client = _make_client(pool, handler, token_provider=provider)

        with pytest.raises(DeviceAuthError) as exc_info:
            list(client.events("dev1"))

        assert captured[0].url.path == "/events"
        assert captured[0].headers.get("Authorization") == "Bearer expired-token"
        assert exc_info.value.code == "token_expired"
        assert provider.cleared == [("dev1", "token_expired")]

    def test_auth_request_status_claim_helpers_use_post_json_and_save_claim_token(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            body = json.loads(req.content)
            if req.url.path == "/auth/request":
                assert body == {
                    "clientNonce": "nonce-1",
                    "clientLabel": "Codex",
                    "requestedMethod": "GET",
                    "requestedPath": "/state",
                }
                return _ok_json(
                    {
                        "ok": True,
                        "requestId": "req-1",
                        "status": "pending",
                        "expiresAt": "2026-08-20T13:00:00Z",
                    },
                    status=202,
                )
            if req.url.path == "/auth/status":
                assert body == {"requestId": "req-1", "clientNonce": "nonce-1"}
                return _ok_json(
                    {
                        "ok": True,
                        "requestId": "req-1",
                        "status": "approved",
                    }
                )
            if req.url.path == "/auth/claim":
                assert body == {"requestId": "req-1", "clientNonce": "nonce-1"}
                return _ok_json(
                    {
                        "ok": True,
                        "token": "new-token",
                        "tokenId": "token-1",
                        "expiresAt": "2026-08-20T14:00:00Z",
                    }
                )
            raise AssertionError(f"unexpected path {req.url.path}")

        pool = _MockPool({"dev1": _fresh()}, [])
        provider = _FakeTokenProvider({}, [], [], [])
        client = _make_client(pool, handler, token_provider=provider)

        request = client.auth_request(
            "dev1",
            "nonce-1",
            client_label="Codex",
            requested_method="GET",
            requested_path="/state",
        )
        status = client.auth_status("dev1", "req-1", "nonce-1")
        claim = client.auth_claim("dev1", "req-1", "nonce-1")

        assert request["status"] == "pending"
        assert status["status"] == "approved"
        assert claim["token"] == "new-token"
        assert [req.method for req in captured] == ["POST", "POST", "POST"]
        assert [req.url.path for req in captured] == [
            "/auth/request",
            "/auth/status",
            "/auth/claim",
        ]
        assert provider.saved == [
            (
                "dev1",
                "new-token",
                {"tokenId": "token-1", "expiresAt": "2026-08-20T14:00:00Z"},
            )
        ]


# ---------------------------------------------------------------------------
# read() convenience
# ---------------------------------------------------------------------------


class TestRead:
    def test_read_state_returns_parsed_dict(self):
        state = {
            "activeSource": "virtual",
            "virtualConnected": True,
            "profileId": "p1",
            "realControllerActive": False,
        }
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json(state)

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        result = client.read("dev1", ["state"])
        assert result == state
        assert captured[0].method == "GET"
        assert captured[0].url.path == "/state"

    def test_read_profiles(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json([{"id": "a"}, {"id": "b"}])

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        result = client.read("dev1", ["profiles"])
        assert result == [{"id": "a"}, {"id": "b"}]
        assert captured[0].url.path == "/profiles"

    def test_read_forwards_selector_headers(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({"status": "ok"})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        result = client.read(
            "dev1",
            ["debug", "status"],
            capability_id="debug",
            scope="page",
            page_id="page-a",
            scope_revision=8,
        )

        assert result == {"status": "ok"}
        assert captured[0].method == "GET"
        assert captured[0].headers["X-DCP-Capability-Id"] == "debug"
        assert captured[0].headers["X-DCP-Capability-Scope"] == "page"
        assert captured[0].headers["X-DCP-Page-Id"] == "page-a"
        assert captured[0].headers["X-DCP-Scope-Revision"] == "8"


class TestSelectorHeaders:
    def test_selector_headers_stringifies_int_revision(self):
        assert selector_headers(
            capability_id="debug",
            scope="page",
            page_id="page-a",
            scope_revision=3,
        ) == {
            "X-DCP-Capability-Id": "debug",
            "X-DCP-Capability-Scope": "page",
            "X-DCP-Page-Id": "page-a",
            "X-DCP-Scope-Revision": "3",
        }

    def test_selector_headers_ignores_malformed_optional_values(self):
        assert selector_headers(
            capability_id="debug",
            scope="invalid",
            page_id="",
            scope_revision=True,
        ) == {"X-DCP-Capability-Id": "debug"}


# ---------------------------------------------------------------------------
# hello() → NetworkTarget (含 BF005 扩展字段)
# ---------------------------------------------------------------------------


class TestHello:
    def _hello_payload(self) -> dict[str, Any]:
        return {
            "deviceId": "gmacro-virtual-iOS",
            "deviceName": "iPhone X",
            "platform": "ios",
            "protocolVersion": 1,
            "capabilities": ["virtual_input", "profiles", "sse"],
            "activeSource": "none",
            "virtualConnected": False,
            "realControllerActive": False,
            "profileRevision": 0,
            # FF001/FF002 扩展字段
            "hardwareName": "iPhone X",
            "machineId": "iPhone10,3",
            "registeredCapabilities": [
                {
                    "id": "gamepad",
                    "resources": [
                        {"method": "GET", "path": ["profiles"], "description": "列出"},
                    ],
                    "commands": [
                        {"method": "POST", "path": ["virtual", "connect"],
                         "description": "连接虚拟手柄"},
                    ],
                },
            ],
        }

    def test_hello_returns_network_target_with_extension_fields(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json(self._hello_payload())

        pool = _MockPool({"dev1": _fresh("192.168.1.34")}, [])
        client = _make_client(pool, handler)
        target = client.hello("dev1")

        # R019 基础字段
        assert target.device_id == "gmacro-virtual-iOS"
        assert target.device_name == "iPhone X"
        assert target.platform == "ios"
        assert target.host == "192.168.1.34"
        assert target.port == 18080
        assert target.capabilities == frozenset({"virtual_input", "profiles", "sse"})
        # FF001/FF002 扩展字段
        assert target.hardware_name == "iPhone X"
        assert target.machine_id == "iPhone10,3"
        assert target.registered_capabilities is not None
        assert len(target.registered_capabilities) == 1
        assert target.registered_capabilities[0]["id"] == "gamepad"
        # URL/path 验证
        assert captured[0].url.path == "/hello"
        assert captured[0].method == "GET"

    def test_hello_non_200_raises(self):
        def handler(req: httpx.Request) -> httpx.Response:
            return httpx.Response(503, text="unavailable")

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        with pytest.raises(DeviceHttpError) as exc_info:
            client.hello("dev1")
        assert exc_info.value.status_code == 503

    def test_hello_non_object_payload_raises(self):
        def handler(req: httpx.Request) -> httpx.Response:
            return _ok_json(["not", "an", "object"])

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        with pytest.raises(DeviceHttpError):
            client.hello("dev1")

    def test_hello_transport_failure(self):
        def handler(req: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("connection refused")

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        with pytest.raises(DeviceHttpError) as exc_info:
            client.hello("dev1")
        assert exc_info.value.status_code == 0


# ---------------------------------------------------------------------------
# events() SSE → DebugEvent (AC9)
# ---------------------------------------------------------------------------


def _sse_response(events: list[tuple[str, str]], status: int = 200) -> httpx.Response:
    """构造 SSE 响应: events = [(data_json_str, event_type_or_None), ...]."""
    chunks: list[bytes] = []
    for data, event_type in events:
        if event_type is not None:
            chunks.append(f"event: {event_type}\n".encode())
        chunks.append(f"data: {data}\n".encode())
        chunks.append(b"\n")  # blank line dispatches the event
    return httpx.Response(
        status,
        content=b"".join(chunks),
        headers={"content-type": "text/event-stream"},
    )


class TestEvents:
    def test_events_yields_structured_debug_events(self):
        payload = json.dumps({
            "type": "input",
            "sequence": 42,
            "activeSource": "virtual",
            "virtualConnected": True,
        })

        def handler(req: httpx.Request) -> httpx.Response:
            return _sse_response([(payload, None)])

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        events_list = list(client.events("dev1"))
        assert len(events_list) == 1
        evt = events_list[0]
        assert evt.event_type == "input"
        assert evt.sequence == 42
        assert evt.active_source == "virtual"
        assert evt.virtual_connected is True

    def test_events_multiple_in_order(self):
        ev1 = json.dumps({"type": "state", "sequence": 1})
        ev2 = json.dumps({"type": "input", "sequence": 2})
        ev3 = json.dumps({"type": "controller", "sequence": 3})

        def handler(req: httpx.Request) -> httpx.Response:
            return _sse_response([(ev1, None), (ev2, None), (ev3, None)])

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        events_list = list(client.events("dev1"))
        assert [e.event_type for e in events_list] == ["state", "input", "controller"]
        assert [e.sequence for e in events_list] == [1, 2, 3]

    def test_events_filter_by_type(self):
        ev1 = json.dumps({"type": "state", "sequence": 1})
        ev2 = json.dumps({"type": "input", "sequence": 2})
        ev3 = json.dumps({"type": "input", "sequence": 3})

        def handler(req: httpx.Request) -> httpx.Response:
            return _sse_response([(ev1, None), (ev2, None), (ev3, None)])

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        events_list = list(client.events("dev1", event_types=["input"]))
        assert len(events_list) == 2
        assert all(e.event_type == "input" for e in events_list)
        assert [e.sequence for e in events_list] == [2, 3]

    def test_events_with_explicit_event_field_prefix(self):
        # 标准 SSE: event: 行 + data: 行 (DebugEvent 仍从 JSON type 读)
        payload = json.dumps({"type": "input", "sequence": 7})

        def handler(req: httpx.Request) -> httpx.Response:
            return _sse_response([(payload, "input")])

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        events_list = list(client.events("dev1"))
        assert len(events_list) == 1
        assert events_list[0].event_type == "input"

    def test_events_multi_data_lines_joined(self):
        # SSE 允许同一事件多个 data: 行, 用 \n 拼接
        body = (
            b'data: {"type":\n'
            b'data: "input", "sequence": 99}\n'
            b'\n'
        )

        def handler(req: httpx.Request) -> httpx.Response:
            return httpx.Response(
                200, content=body, headers={"content-type": "text/event-stream"}
            )

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        events_list = list(client.events("dev1"))
        assert len(events_list) == 1
        assert events_list[0].event_type == "input"
        assert events_list[0].sequence == 99

    def test_events_comment_lines_ignored(self):
        body = (
            b': this is a comment\n'
            b'data: {"type": "input", "sequence": 1}\n'
            b'\n'
            b': another comment\n'
            b'data: {"type": "state", "sequence": 2}\n'
            b'\n'
        )

        def handler(req: httpx.Request) -> httpx.Response:
            return httpx.Response(
                200, content=body, headers={"content-type": "text/event-stream"}
            )

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        events_list = list(client.events("dev1"))
        assert [e.event_type for e in events_list] == ["input", "state"]

    def test_events_non_json_data_yields_unknown(self):
        # 非 JSON data → DebugEvent.event_type="unknown" (容错, 不崩)
        def handler(req: httpx.Request) -> httpx.Response:
            return httpx.Response(
                200,
                content=b"data: not-valid-json\n\n",
                headers={"content-type": "text/event-stream"},
            )

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        events_list = list(client.events("dev1"))
        assert len(events_list) == 1
        assert events_list[0].event_type == "unknown"

    def test_events_error_status_raises(self):
        def handler(req: httpx.Request) -> httpx.Response:
            return httpx.Response(403, json={"errorCode": "forbidden"})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)

        with pytest.raises(DeviceHttpError) as exc_info:
            list(client.events("dev1"))
        assert exc_info.value.status_code == 403

    def test_events_unreachable_device(self):
        def handler(req: httpx.Request) -> httpx.Response:
            return _sse_response([(json.dumps({"type": "x"}), None)])

        pool = _MockPool({"dev1": _unknown()}, [])
        client = _make_client(pool, handler)

        with pytest.raises(DeviceUnreachable):
            list(client.events("dev1"))

    def test_events_stale_device(self):
        def handler(req: httpx.Request) -> httpx.Response:
            return _sse_response([(json.dumps({"type": "x"}), None)])

        pool = _MockPool({"dev1": _stale()}, [])
        client = _make_client(pool, handler)

        with pytest.raises(DeviceStale):
            list(client.events("dev1"))

    def test_events_transport_failure_mid_stream(self):
        def handler(req: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("stream dropped")

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        with pytest.raises(DeviceHttpError) as exc_info:
            list(client.events("dev1"))
        assert exc_info.value.status_code == 0


# ---------------------------------------------------------------------------
# Path join semantics
# ---------------------------------------------------------------------------


class TestPathJoin:
    def test_empty_path_is_root(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        client.invoke("dev1", "GET", [], None)
        assert captured[0].url.path == "/"

    def test_multi_segment_path(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        client.invoke("dev1", "GET", ["a", "b", "c", "d"], None)
        assert captured[0].url.path == "/a/b/c/d"

    def test_segment_with_special_chars_quoted(self):
        # 含特殊字符的 segment 必须 percent-encode (一个 list 元素 = 一个 URL 段)
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler)
        client.invoke("dev1", "GET", ["profiles", "a b/c"], None)
        # ' ' → %20, '/' → %2F (保持单段, 不被 / 拆开).
        # 用 raw_path 验证 (url.path 是解码形式, raw_path 是线路上的原始编码).
        assert captured[0].url.raw_path == b"/profiles/a%20b%2Fc"


# ---------------------------------------------------------------------------
# _safe_body defensive parsing
# ---------------------------------------------------------------------------


class TestSafeBody:
    def test_json_dict(self):
        resp = httpx.Response(200, json={"k": "v"})
        assert _safe_body(resp) == {"k": "v"}

    def test_json_list(self):
        resp = httpx.Response(200, json=[1, 2, 3])
        assert _safe_body(resp) == [1, 2, 3]

    def test_json_scalar(self):
        resp = httpx.Response(200, json=42)
        assert _safe_body(resp) == 42

    def test_non_json_text(self):
        resp = httpx.Response(200, text="plain text")
        assert _safe_body(resp) == "plain text"

    def test_empty_body(self):
        resp = httpx.Response(200, content=b"")
        assert _safe_body(resp) is None


# ---------------------------------------------------------------------------
# _iter_sse unit (helper coverage)
# ---------------------------------------------------------------------------


class TestIterSse:
    def test_blank_line_dispatches(self):
        body = b"data: hello\n\ndata: world\n\n"
        resp = httpx.Response(200, content=body)
        events = list(_iter_sse(resp))
        assert events == [("hello", None), ("world", None)]

    def test_crlf_line_endings(self):
        body = b"data: hello\r\n\r\ndata: world\r\n\r\n"
        resp = httpx.Response(200, content=body)
        events = list(_iter_sse(resp))
        assert events == [("hello", None), ("world", None)]

    def test_event_field_captured(self):
        body = b"event: input\ndata: {}\n\n"
        resp = httpx.Response(200, content=body)
        events = list(_iter_sse(resp))
        assert events == [("{}", "input")]

    def test_data_field_with_leading_space_stripped(self):
        body = b"data: {\"a\":1}\n\n"
        resp = httpx.Response(200, content=body)
        events = list(_iter_sse(resp))
        assert events == [('{"a":1}', None)]

    def test_trailing_event_without_blank_line_flushed(self):
        body = b"data: hello"
        resp = httpx.Response(200, content=body)
        events = list(_iter_sse(resp))
        assert events == [("hello", None)]

    def test_line_without_colon_treated_as_field_no_value(self):
        # SSE spec: 一行无冒号 → 整行是 field, value 为空字符串.
        # 例如纯 "event" 单字段 (无值) → field="event", value="" → 归一化为 None
        body = b"event\ndata: hello\n\n"
        resp = httpx.Response(200, content=body)
        events = list(_iter_sse(resp))
        assert events == [("hello", None)]


class TestParseJsonObject:
    """_parse_json_object: 容错校验 (非 JSON / 非 dict)."""

    def test_valid_object(self):
        from debug_control_plane.mcp_plane.bridge_client import _parse_json_object
        assert _parse_json_object('{"a":1}') == {"a": 1}

    def test_invalid_json_raises(self):
        from debug_control_plane.mcp_plane.bridge_client import _parse_json_object
        with pytest.raises((ValueError, TypeError, json.JSONDecodeError)):
            _parse_json_object("not-json")

    def test_non_object_json_raises(self):
        # JSON 是合法的但不是 dict (如数组/标量) → ValueError
        from debug_control_plane.mcp_plane.bridge_client import _parse_json_object
        with pytest.raises(ValueError):
            _parse_json_object("[1,2,3]")
        with pytest.raises(ValueError):
            _parse_json_object("42")


# ---------------------------------------------------------------------------
# Default client / lifecycle
# ---------------------------------------------------------------------------


class TestLifecycle:
    def test_default_client_created_when_not_injected(self):
        # 不注入 client → 自建 httpx.Client (owns_client=True)
        pool = _MockPool({"dev1": _fresh()}, [])
        client = BridgeClient(pool=pool)
        try:
            assert client._owns_client is True
        finally:
            client.close()

    def test_injected_client_not_closed_by_close(self):
        # 注入的 client 不被 close (caller 管理生命周期)
        pool = _MockPool({"dev1": _fresh()}, [])
        http_client = httpx.Client(transport=httpx.MockTransport(lambda r: _ok_json({})))
        client = BridgeClient(pool=pool, client=http_client)
        assert client._owns_client is False
        client.close()
        # http_client 仍可用
        assert http_client.is_closed is False
        http_client.close()

    def test_context_manager_closes_owned_client(self):
        pool = _MockPool({"dev1": _fresh()}, [])
        with BridgeClient(pool=pool) as client:
            assert client._owns_client is True
        assert client._client.is_closed is True

    def test_bridge_error_is_base_class(self):
        # 异常分类基类: 调用方只 catch BridgeError 即可统一处理
        # AD-B9: DeviceUnreachable 已下沉 device_discovery.protocol,直继承
        # Exception(脱离 BridgeError,避免 mcp_plane 反向依赖网络平面异常),
        # 不再 BridgeError 子类。验它仍可用 + 其他 BridgeError 子类不变。
        assert issubclass(DeviceUnreachable, Exception)
        assert not issubclass(DeviceUnreachable, BridgeError)
        assert issubclass(DeviceStale, BridgeError)
        assert issubclass(DeviceHttpError, BridgeError)

    def test_custom_port(self):
        captured: list[httpx.Request] = []

        def handler(req: httpx.Request) -> httpx.Response:
            captured.append(req)
            return _ok_json({})

        pool = _MockPool({"dev1": _fresh()}, [])
        client = _make_client(pool, handler, port=9999)
        client.invoke("dev1", "GET", ["state"], None)
        # URL host:port
        assert captured[0].url.port == 9999
