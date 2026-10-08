"""In-process MCP authorization integration against a protocol-shaped App stub.

This test uses the real BridgeClient, CapabilityMirror, McpServer and token
provider.  The only fake is the remote App transport, so it guards the local
editable dependency path without requiring a phone or product capability.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import httpx
import pytest

from debug_control_plane.device_discovery.device_pool import ResolveResult
from debug_control_plane.mcp_plane.bridge_client import BridgeClient
from debug_control_plane.mcp_plane.capability_mirror import CapabilityMirror
from debug_control_plane.mcp_plane.server import McpServer
from debug_control_plane.mcp_plane.token_provider import FileTokenProvider


@dataclass
class _FreshPool:
    def resolve_ip(self, device_id: str, *, now: float | None = None) -> ResolveResult:
        assert device_id == "phone-1"
        return ResolveResult(host="127.0.0.1", is_stale=False, found=True)

    def list_all(self) -> list[object]:
        return []


@pytest.mark.asyncio
async def test_mcp_read_resource_completes_auth_and_retries_with_claimed_bearer(tmp_path) -> None:
    state_attempts = 0
    calls: list[httpx.Request] = []

    def app_stub(request: httpx.Request) -> httpx.Response:
        nonlocal state_attempts
        calls.append(request)
        if request.url.path == "/ai-voice/state":
            state_attempts += 1
            if state_attempts == 1:
                assert request.headers.get("Authorization") is None
                return httpx.Response(
                    401,
                    json={"ok": False, "code": "authorization_required"},
                )
            assert request.headers.get("Authorization") == "Bearer claimed-token"
            return httpx.Response(200, json={"ok": True, "phase": "ready_to_listen"})
        if request.url.path == "/auth/request":
            body = json.loads(request.content)
            assert body["clientLabel"] == "MCP Debug Control Plane"
            assert body["requestedMethod"] == "GET"
            assert body["requestedPath"] == "/ai-voice/state"
            return httpx.Response(202, json={"ok": True, "requestId": "req-1", "status": "pending"})
        if request.url.path == "/auth/status":
            return httpx.Response(200, json={"ok": True, "status": "approved"})
        if request.url.path == "/auth/claim":
            return httpx.Response(
                200,
                json={"ok": True, "token": "claimed-token", "tokenId": "token-1"},
            )
        raise AssertionError(f"unexpected request: {request.method} {request.url}")

    pool = _FreshPool()
    tokens = FileTokenProvider(path=tmp_path / "tokens.json")
    client = BridgeClient(
        pool=pool,  # type: ignore[arg-type]
        client=httpx.Client(transport=httpx.MockTransport(app_stub)),
        token_provider=tokens,
    )
    server = McpServer(
        mirror=CapabilityMirror(client=client),
        client=client,
        pool=pool,  # type: ignore[arg-type]
    )

    result = await server.call_handler_for_test("read_resource")({
        "device_id": "phone-1",
        "capability_id": "ai.voice",
        "resource_path": ["ai-voice", "state"],
    })

    assert result == {"ok": True, "phase": "ready_to_listen"}
    assert [request.url.path for request in calls] == [
        "/ai-voice/state",
        "/auth/request",
        "/auth/status",
        "/auth/claim",
        "/ai-voice/state",
    ]
    assert tokens.get_token("phone-1") == "claimed-token"


@pytest.mark.asyncio
async def test_mcp_capability_refresh_authorizes_then_exposes_dynamic_capability(tmp_path) -> None:
    calls: list[httpx.Request] = []
    hello = json.loads(
        (Path(__file__).parents[2] / "fixtures" / "hello-auth-authorized.json").read_text()
    )
    hello["registeredCapabilities"] = [{
        "id": "ai.voice",
        "resources": [{"method": "GET", "path": ["ai-voice", "state"]}],
        "commands": [{"method": "POST", "path": ["ai-voice", "open"]}],
    }]

    def app_stub(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        if request.url.path == "/hello":
            if request.headers.get("Authorization") is None:
                return httpx.Response(
                    401, json={"ok": False, "code": "authorization_required"}
                )
            assert request.headers.get("Authorization") == "Bearer claimed-token"
            return httpx.Response(200, json=hello)
        if request.url.path == "/auth/request":
            body = json.loads(request.content)
            assert body["requestedMethod"] == "GET"
            assert body["requestedPath"] == "/hello"
            return httpx.Response(202, json={"ok": True, "requestId": "req-1", "status": "pending"})
        if request.url.path == "/auth/status":
            return httpx.Response(200, json={"ok": True, "status": "approved"})
        if request.url.path == "/auth/claim":
            return httpx.Response(200, json={"ok": True, "token": "claimed-token"})
        raise AssertionError(f"unexpected request: {request.method} {request.url}")

    pool = _FreshPool()
    client = BridgeClient(
        pool=pool,  # type: ignore[arg-type]
        client=httpx.Client(transport=httpx.MockTransport(app_stub)),
        token_provider=FileTokenProvider(path=tmp_path / "tokens.json"),
    )
    server = McpServer(
        mirror=CapabilityMirror(client=client),
        client=client,
        pool=pool,  # type: ignore[arg-type]
    )

    schemas = await server.call_handler_for_test("list_capabilities")({"device_id": "phone-1"})

    assert schemas[0]["capability_id"] == "ai.voice"
    assert [request.url.path for request in calls] == [
        "/hello", "/auth/request", "/auth/status", "/auth/claim", "/hello",
    ]
