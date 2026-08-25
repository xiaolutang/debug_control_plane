"""Unit + smoke tests for the MCP stdio server (R020-BF011).

Two test layers (test analysis §2.1 MCP baseline rows):

  * **Unit** (``TestDispatch``, ``TestErrorMapping``, ``TestNormalize``,
    ``TestListTools``): exercise the dispatch table / error floor / result
    normalization / manifest mapping **in-process**, with BridgeClient +
    DevicePool mocked. These give fast, deterministic coverage of the
    routing + error-translation logic (AC1 floor, AC9 routing, §5.5 ④).

  * **Smoke** (``test_smoke_stdio_baseline``): spawn the *real* server.py
    over stdio (subprocess), send a JSON-RPC ``initialize`` + ``tools/list``
    + ``tools/call`` sequence, and assert the AC1 baseline end-to-end:
    empty pool → 8 static tools, no gamepad; ``listChanged=true`` declared;
    stdin close → process exits (NOT a daemon, design S7).

The smoke test is the first one in the BF series to actually boot a server
(``smoke_required=true`` on BF011); it gates the integration tests in BF012.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest

from debug_control_plane.device_discovery.device_pool import DevicePool, DeviceRecord
from debug_control_plane.device_discovery.protocol import NetworkTarget
from debug_control_plane.mcp_plane import server
from debug_control_plane.mcp_plane.bridge_client import (
    BridgeClient,
    BridgeError,
    DeviceAuthError,
    DeviceHttpError,
    DeviceStale,
    DeviceUnreachable,
)
from debug_control_plane.mcp_plane.capability_mirror import (
    CapabilityMirror,
    CapabilitySchema,
    ToolSpec,
)
from debug_control_plane.mcp_plane.server import (
    McpServer,
    _bridge_error_to_mcp,
    _device_record_to_jsonable,
    _normalize_tool_result,
    _tool_spec_to_mcp,
)

# ★ BF008-010 (Contract §0.4 方案 X): 平面 stub provider + handler — 测注入
# 机制(AC-B9),零业务依赖。原业务用例已分类:
# A 类(路由/注入)改 stub 留 control_plane;B 类(业务逻辑)迁业务侧测试。
_STUB_CAP_ID = "stub_cap"
_STUB_LEGACY_TAG = "virtual_input"  # 平面 E 方案 sentinel 通用化(非业务常量)
_STUB_TOOL_NAME = "stub_tool"


class _StubProvider:
    """平面 stub provider — 测注入机制(AC-B9),不知任何产品语义。"""

    def matches(
        self,
        schema: CapabilitySchema,
        *,
        legacy_capabilities: frozenset[str] | None = None,
    ) -> bool:
        del legacy_capabilities  # E 方案下平面不传(dead 参数)
        return schema.capability_id in (_STUB_CAP_ID, _STUB_LEGACY_TAG)

    def build_tools(self, schema: CapabilitySchema) -> list[ToolSpec]:
        del schema
        return [
            ToolSpec(
                name=_STUB_TOOL_NAME,
                description="stub tool for injection-mechanism test",
                input_schema={"type": "object", "properties": {}},
            )
        ]


async def _stub_handler(args: dict[str, Any]) -> dict[str, Any]:
    """平面 stub handler — 返回 echo,证明 tool_handlers 注入接口可用。"""
    return {"ok": True, "echo": dict(args)}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _make_target(
    *,
    device_id: str = "dev1",
    virtual_connected: bool = False,
    registered: tuple[dict[str, Any], ...] | None = None,
    capabilities: frozenset[str] = frozenset(),
) -> NetworkTarget:
    """Build a NetworkTarget with the fields the server reads."""
    return NetworkTarget(
        device_id=device_id,
        device_name="iPhone X",
        platform="ios",
        host="192.168.1.34",
        port=18080,
        protocol_version=1,
        capabilities=capabilities,
        active_source="none",
        virtual_connected=virtual_connected,
        profile_id=None,
        real_controller_active=False,
        last_error=None,
        profile_revision=0,
        registered_capabilities=registered,
    )


@pytest.fixture
def tmp_pool(tmp_path: Path) -> DevicePool:
    """Empty DevicePool backed by a temp persist_path (no ~/.debug-control-plane leak)."""
    return DevicePool(persist_path=tmp_path / "devices.json")


@pytest.fixture
def mock_client() -> MagicMock:
    """BridgeClient with all methods mocked — no real HTTP."""
    c = MagicMock(spec=BridgeClient)
    return c


@pytest.fixture
def assembled(
    tmp_pool: DevicePool, mock_client: MagicMock
) -> tuple[McpServer, CapabilityMirror, MagicMock, DevicePool]:
    """Assemble McpServer with mocked BridgeClient + temp pool.

    ★ BF008-010 (Contract §0.4 方案 X): 注入平面 stub provider + stub handler
    (零业务依赖),证明 McpServer providers + tool_handlers 注入接口可用。
    业务装配(真 GamepadSemanticProvider + 5 handler)归 R021-CLEANUP;本平面
    test 是注入机制的第一个消费者(合同 §0.0 "SemanticProvider 消费点" 语义②)。
    """
    mirror = CapabilityMirror(client=mock_client, providers=[_StubProvider()])  # type: ignore[arg-type]
    srv = McpServer(
        mirror=mirror,
        client=mock_client,  # type: ignore[arg-type]
        pool=tmp_pool,
        providers=[_StubProvider()],
        tool_handlers={_STUB_TOOL_NAME: _stub_handler},
    )
    return srv, mirror, mock_client, tmp_pool


# ---------------------------------------------------------------------------
# Tool-spec → mcp Tool adapter
# ---------------------------------------------------------------------------


class TestToolSpecMapping:
    def test_fields_map_one_to_one(self):
        spec = ToolSpec(
            name="foo",
            description="does foo",
            input_schema={"type": "object", "properties": {"x": {"type": "string"}}},
        )
        tool = _tool_spec_to_mcp(spec)
        assert tool.name == "foo"
        assert tool.description == "does foo"
        assert tool.inputSchema == {"type": "object", "properties": {"x": {"type": "string"}}}

    def test_round_trip_through_build_tools(self, assembled):
        """Empty-pool manifest maps 1:1 onto mcp Tool objects (AC1 floor)."""
        srv, mirror, *_ = assembled
        specs = mirror.build_tools(None)
        tools = [_tool_spec_to_mcp(s) for s in specs]
        names = sorted(t.name for t in tools)
        # 5 meta + 3 device-mgmt = 8 static floor; no gamepad in empty pool.
        assert names == sorted([
            "list_capabilities", "invoke_command", "read_resource",
            "get_state", "subscribe_events",
            "list_devices", "discover_devices", "register_device",
        ])
        # Every Tool has the MCP-required inputSchema field.
        for t in tools:
            assert isinstance(t.inputSchema, dict)
            assert t.inputSchema.get("type") == "object"


# ---------------------------------------------------------------------------
# Dispatch — tool name routing
# ---------------------------------------------------------------------------


class TestDispatchRouting:
    """Each tool name routes to the right BF module (AC9 routing layer)."""

    @pytest.mark.asyncio
    async def test_stub_handler_routes_via_dispatch(self, assembled):
        """★ BF008-010 (Contract §0.4 方案 X A 类): 注入的 stub_tool 经 dispatch
        路由到 stub_handler(测 tool_handlers 注入接口 + _build_dispatch 合并)。

        原 gamepad 业务路由测试(test_gamepad_handlers_route_to_bf010)已分类
        B 类(测 gamepad.press_button 帧构造业务逻辑),迁业务侧
        test_semantic_gamepad;本 A 类用例改平面 stub,测 server 注入机制本身
        (server 零业务依赖)。
        """
        srv, *_ = assembled
        h = srv.call_handler_for_test(_STUB_TOOL_NAME)
        result = await h({"any": "args"})
        # stub_handler 返回 echo,证明 tool_handlers 注入接口经 dispatch 可达.
        assert result == {"ok": True, "echo": {"any": "args"}}

    # ★ BF008-010 B 类用例: test_dpad_invalid_direction_raises_value_error
    # 测 gamepad.dpad 方向校验业务逻辑,已迁业务侧 test_semantic_gamepad
    # (TestDpad.test_invalid_direction_raises_value_error 等价覆盖),control_plane
    # 侧删除。

    @pytest.mark.asyncio
    async def test_invoke_command_forwards_command_path(self, assembled):
        srv, *_ = assembled
        mock_client = assembled[2]
        mock_client.invoke.return_value = {"result": "ok"}
        h = srv.call_handler_for_test("invoke_command")
        await h({
            "device_id": "dev1",
            "capability_id": "debug",
            "command_path": ["virtual", "connect"],
            "args": {"profileId": "x"},
        })
        call = mock_client.invoke.call_args
        assert call.args == ("dev1", "POST", ["virtual", "connect"], {"profileId": "x"})

    @pytest.mark.asyncio
    async def test_read_resource_uses_path_segments(self, assembled):
        srv, *_ = assembled
        mock_client = assembled[2]
        mock_client.read.return_value = {"profiles": []}
        h = srv.call_handler_for_test("read_resource")
        await h({
            "device_id": "dev1",
            "capability_id": "debug",
            "resource_path": ["profiles"],
        })
        assert mock_client.read.call_args.args == ("dev1", ["profiles"])

    @pytest.mark.asyncio
    async def test_get_state_reads_state_path(self, assembled):
        srv, *_ = assembled
        mock_client = assembled[2]
        mock_client.read.return_value = {"virtual_connected": False}
        h = srv.call_handler_for_test("get_state")
        await h({"device_id": "dev1"})
        assert mock_client.read.call_args.args == ("dev1", ["state"])

    @pytest.mark.asyncio
    async def test_list_devices_empty_pool(self, assembled):
        """Raw handler returns list of sanitized records; empty pool → []."""
        srv, *_ = assembled
        h = srv.call_handler_for_test("list_devices")
        result = await h({})
        # Raw handler returns the list of records (SDK wrapper normalizes
        # to JSON text; here we assert the dispatch routing is correct).
        assert result == []

    @pytest.mark.asyncio
    async def test_unknown_tool_name_raises_keyerror(self, assembled):
        srv, *_ = assembled
        with pytest.raises(KeyError):
            srv.call_handler_for_test("no_such_tool")


# Mark all async dispatch tests to use asyncio mode. We use anyio in server.py
# so the tests run fine under pytest-anyio or the asyncio back-compat shim.
@pytest.fixture
def anyio_backend():
    return "asyncio"


# ---------------------------------------------------------------------------
# Error mapping — §5.5 ④ floor (BridgeError → McpError → isError=true)
# ---------------------------------------------------------------------------


class TestErrorMapping:
    def test_device_unreachable_includes_discover_hint(self):
        exc = DeviceUnreachable("dev1 not found")
        mcp_err = _bridge_error_to_mcp(exc)
        assert mcp_err.error.code == -32602
        assert "discover_devices" in mcp_err.error.message

    def test_device_stale_includes_rediscover_hint(self):
        exc = DeviceStale("dev1 TTL expired")
        mcp_err = _bridge_error_to_mcp(exc)
        assert "stale" in mcp_err.error.message.lower()
        assert "discover" in mcp_err.error.message.lower()

    def test_device_http_error_propagates_status(self):
        exc = DeviceHttpError(status_code=409, body={"err": "real_controller_active"})
        mcp_err = _bridge_error_to_mcp(exc)
        assert "status=409" in mcp_err.error.message
        assert "real_controller_active" in mcp_err.error.message
        assert "real controller" in mcp_err.error.message  # 409 hint

    def test_device_http_error_500_propagates_body(self):
        exc = DeviceHttpError(status_code=500, body="oops")
        mcp_err = _bridge_error_to_mcp(exc)
        assert "status=500" in mcp_err.error.message
        assert "oops" in mcp_err.error.message

    def test_generic_bridge_error_wrapped(self):
        exc = BridgeError("transport boom")
        mcp_err = _bridge_error_to_mcp(exc)
        assert mcp_err.error.code == -32602
        assert "bridge error" in mcp_err.error.message

    @pytest.mark.asyncio
    async def test_dispatch_translates_bridge_error(self, assembled):
        """A handler that raises BridgeError → McpError propagates (caller
        wraps to isError). Verified at the dispatch boundary."""
        srv, *_ = assembled
        mock_client = assembled[2]
        mock_client.read.side_effect = DeviceUnreachable("ghost not found")
        h = srv.call_handler_for_test("get_state")
        with pytest.raises(Exception) as exc_info:
            await h({"device_id": "ghost"})
        # _run wraps BridgeError → McpError before re-raising.
        from mcp.shared.exceptions import McpError
        assert isinstance(exc_info.value, McpError)


# ---------------------------------------------------------------------------
# Auth error translation (R001-BB001) — DeviceAuthError actionable hints
# ---------------------------------------------------------------------------


class TestAuthErrorMapping:
    """_bridge_error_to_mcp maps the six stable auth codes to next-step hints.

    DeviceAuthError is a DeviceHttpError subclass — the auth branch must be
    checked FIRST (isinstance order), else auth errors degrade to the generic
    HTTP message with no authorization hint.
    """

    @pytest.mark.parametrize(
        "code,hint_fragments",
        [
            ("authorization_required", ["authorize", "App"]),
            ("token_expired", ["re-authorize", "App", "cleared"]),
            ("token_revoked", ["re-authorize", "App", "cleared"]),
            ("invalid_token", ["re-authorize", "App", "cleared"]),
            ("authorization_denied", ["denied", "do not retry"]),
            ("forbidden", ["denied", "do not retry"]),
        ],
    )
    def test_six_auth_codes_map_to_actionable_hints(self, code, hint_fragments):
        exc = DeviceAuthError(
            status_code=401 if code != "forbidden" else 403,
            body={"code": code},
            code=code,
        )
        mcp_err = _bridge_error_to_mcp(exc)
        assert mcp_err.error.code == -32602
        msg = mcp_err.error.message.lower()
        for frag in hint_fragments:
            assert frag.lower() in msg, f"code={code}: missing hint {frag!r} in {msg!r}"
        # device_id + original code are preserved.
        assert code in mcp_err.error.message

    def test_auth_error_message_has_no_plaintext_token(self):
        exc = DeviceAuthError(
            status_code=401,
            body={"code": "invalid_token", "token": "SECRET-TOKEN-XYZ"},
            code="invalid_token",
        )
        mcp_err = _bridge_error_to_mcp(exc)
        assert "SECRET-TOKEN-XYZ" not in mcp_err.error.message

    def test_auth_error_branch_precedes_http_branch(self):
        """DeviceAuthError must NOT fall into the generic DeviceHttpError
        message ('device HTTP error: status=...')."""
        exc = DeviceAuthError(401, {"code": "authorization_required"}, "authorization_required")
        msg = _bridge_error_to_mcp(exc).error.message
        assert "authorization_required" in msg
        assert "device http error" not in msg.lower()

    @pytest.mark.asyncio
    async def test_get_state_auth_error_raises_mcp_error(self, assembled):
        """Tool handler path: DeviceAuthError from BridgeClient → McpError."""
        srv, *_ = assembled
        mock_client = assembled[2]
        mock_client.read.side_effect = DeviceAuthError(
            401, {"code": "authorization_required"}, "authorization_required"
        )
        h = srv.call_handler_for_test("get_state")
        from mcp.shared.exceptions import McpError
        with pytest.raises(McpError) as ei:
            await h({"device_id": "dev1"})
        assert "App" in ei.value.error.message  # actionable authorize hint

    @pytest.mark.asyncio
    async def test_list_capabilities_auth_error_raises_mcp_error(self, assembled):
        """AC2: list_capabilities must NOT silently degrade an auth error to
        an empty capability list — it surfaces as MCP isError."""
        srv, *_ = assembled
        mock_client = assembled[2]
        mock_client.hello.side_effect = DeviceAuthError(
            401, {"code": "token_expired"}, "token_expired"
        )
        h = srv.call_handler_for_test("list_capabilities")
        from mcp.shared.exceptions import McpError
        with pytest.raises(McpError) as ei:
            await h({"device_id": "dev1"})
        assert "token_expired" in ei.value.error.message
        assert "re-authorize" in ei.value.error.message.lower()

    @pytest.mark.asyncio
    async def test_list_capabilities_offline_still_degrades_to_empty(self, assembled):
        """AC2 regression guard: offline stays a degrade (empty list), NOT an
        MCP error — auth error handling must not change the offline path."""
        srv, *_ = assembled
        mock_client = assembled[2]
        mock_client.hello.side_effect = DeviceUnreachable("nope")
        h = srv.call_handler_for_test("list_capabilities")
        result = await h({"device_id": "ghost"})
        assert result == []

    @pytest.mark.asyncio
    async def test_subscribe_events_auth_error_is_mcp_error_not_crash(self, assembled):
        """AC3: SSE connect 401/403 → MCP isError, server dispatch stays alive."""
        srv, *_ = assembled
        mock_client = assembled[2]

        def _gen(*a, **kw):
            raise DeviceAuthError(403, {"code": "forbidden"}, "forbidden")
            yield  # pragma: no cover — makes this a generator

        mock_client.events.side_effect = lambda *a, **kw: _gen()
        h = srv.call_handler_for_test("subscribe_events")
        from mcp.shared.exceptions import McpError
        with pytest.raises(McpError) as ei:
            await h({"device_id": "dev1"})
        assert "forbidden" in ei.value.error.message
        # Dispatch still usable after the auth failure (server not crashed).
        h2 = srv.call_handler_for_test("list_devices")
        assert await h2({}) == []


# ---------------------------------------------------------------------------
# Result normalization
# ---------------------------------------------------------------------------


class TestNormalize:
    def test_dict_becomes_text_plus_structured(self):
        from mcp import types
        result = _normalize_tool_result({"a": 1})
        assert isinstance(result, types.CallToolResult)
        assert result.structuredContent == {"a": 1}
        assert json.loads(result.content[0].text) == {"a": 1}
        assert result.isError is False

    def test_list_of_data_becomes_json_text(self):
        result = _normalize_tool_result([1, 2, 3])
        assert isinstance(result, list)
        assert json.loads(result[0].text) == [1, 2, 3]

    def test_empty_list_is_data_not_no_content(self):
        """Regression: empty list must NOT be treated as 'no content blocks'."""
        result = _normalize_tool_result([])
        assert isinstance(result, list)
        assert len(result) == 1
        assert json.loads(result[0].text) == []

    def test_string_wraps_as_text(self):
        result = _normalize_tool_result("hello")
        assert isinstance(result, list)
        assert result[0].text == '"hello"'

    def test_none_wraps_as_text(self):
        result = _normalize_tool_result(None)
        assert isinstance(result, list)
        assert json.loads(result[0].text) is None

    def test_existing_call_tool_result_passes_through(self):
        from mcp import types
        ctr = types.CallToolResult(
            content=[types.TextContent(type="text", text="x")], isError=True
        )
        assert _normalize_tool_result(ctr) is ctr

    def test_existing_content_blocks_pass_through(self):
        from mcp import types
        blocks = [types.TextContent(type="text", text="raw")]
        assert _normalize_tool_result(blocks) is blocks

    def test_pydantic_model_serialized(self):
        """NetworkTarget (pydantic) → JSON via model_dump fallback."""
        nt = _make_target()
        result = _normalize_tool_result(nt)
        dumped = json.loads(result[0].text)
        assert dumped["device_id"] == "dev1"
        assert dumped["platform"] == "ios"

    def test_frozen_dataclass_serialized(self):
        """DebugEvent-ish frozen dataclass → asdict fallback."""
        from dataclasses import dataclass

        @dataclass(frozen=True)
        class Ev:
            event_type: str
            sequence: int

        result = _normalize_tool_result(Ev(event_type="x", sequence=1))
        assert json.loads(result[0].text) == {"event_type": "x", "sequence": 1}


# ---------------------------------------------------------------------------
# DeviceRecord public view (sanitized — no internal TTL/timestamps leak)
# ---------------------------------------------------------------------------


class TestDeviceRecordView:
    def test_sanitized_view_excludes_internal_state(self):
        rec = DeviceRecord(
            device_id="d1", label="L", source="manual",
            last_known_host="10.0.0.1", last_seen=12345.6,
            hardware_name="iPhone X", machine_id="iPhone10,3",
            platform="ios",
        )
        view = _device_record_to_jsonable(rec)
        assert view["device_id"] == "d1"
        assert view["label"] == "L"
        assert view["source"] == "manual"
        assert view["hardware_name"] == "iPhone X"
        assert view["machine_id"] == "iPhone10,3"
        assert view["platform"] == "ios"
        # Internal IP / TTL / last_seen must NOT leak (design §4.2.1).
        assert "last_known_host" not in view
        assert "last_seen" not in view
        assert "ttl" not in view

    def test_connected_flag_from_network_target(self):
        nt = _make_target(virtual_connected=True)
        rec = DeviceRecord(
            device_id="d1", label="L", source="auto",
            platform="ios", network_target=nt,
        )
        assert _device_record_to_jsonable(rec)["connected"] is True


# ---------------------------------------------------------------------------
# subscribe_events — bounded drain (design §4.2.2)
# ---------------------------------------------------------------------------


class TestSubscribeEvents:
    @pytest.mark.asyncio
    async def test_subscribe_drains_bounded_batch(self, assembled):
        from debug_control_plane.device_discovery.protocol import DebugEvent

        srv, *_ = assembled
        mock_client = assembled[2]
        # Simulate a stream that yields 30 events; we should cap at the batch.
        events = [DebugEvent(event_type="ctrl", sequence=i) for i in range(30)]
        mock_client.events.return_value = iter(events)
        h = srv.call_handler_for_test("subscribe_events")
        result = await h({"device_id": "dev1"})
        # Raw handler returns the list of events run through _event_to_jsonable
        # (dict form); SDK wrapper normalizes to JSON text. Assert the batch
        # cap is honored.
        assert isinstance(result, list)
        assert len(result) <= 16  # _SUBSCRIBE_EVENT_BATCH cap
        assert result[0]["event_type"] == "ctrl"

    @pytest.mark.asyncio
    async def test_subscribe_with_event_types_filter(self, assembled):
        srv, *_ = assembled
        mock_client = assembled[2]
        mock_client.events.return_value = iter([])
        h = srv.call_handler_for_test("subscribe_events")
        await h({"device_id": "dev1", "event_types": ["controller_state_changed"]})
        call = mock_client.events.call_args
        assert call.args == ("dev1", ["controller_state_changed"])


# ---------------------------------------------------------------------------
# register_device — delegates to BF007 ManualRegistry (wired in BF012)
# ---------------------------------------------------------------------------


class TestRegisterDevice:
    @pytest.mark.asyncio
    async def test_register_probes_hello_and_upserts(self, assembled, monkeypatch):
        """register_device delegates to BF007 ManualRegistry.

        ManualRegistry honors analysis L3 (no phantom entry on probe failure)
        by construction: it only upserts on a successful probe. We verify the
        wiring by stubbing ManualRegistry to a deterministic ok=True result.
        """
        srv, *_ = assembled
        pool = assembled[3]
        from debug_control_plane.device_discovery.device_pool import manual_device_id
        from debug_control_plane.device_discovery.discovery.manual_registry import RegisterResult

        did = manual_device_id("192.168.1.50")

        class _StubRegistry:
            def __init__(self, *a, **kw): pass
            def register(self, host, *, label=None, note=None):
                rec = DeviceRecord(
                    device_id=did, label=label or host, source="manual",
                    last_known_host=host, last_seen=12345.0,
                )
                # ManualRegistry.register upserts on success — mirror that.
                pool.upsert(rec)
                return RegisterResult(ok=True, record=rec)

        monkeypatch.setattr("debug_control_plane.mcp_plane.server.ManualRegistry", _StubRegistry)
        h = srv.call_handler_for_test("register_device")
        result = await h({"host": "192.168.1.50", "label": "Manual"})
        # Pool now contains the manual entry.
        ids = [r.device_id for r in pool.list_all()]
        assert did in ids, f"manual id not in pool: {ids}"
        # Raw handler returns the sanitized DeviceRecord dict (SDK wrapper
        # normalizes to JSON text; here we assert routing + label retention).
        assert result["label"] == "Manual"
        assert result["source"] == "manual"

    @pytest.mark.asyncio
    async def test_register_failed_probe_rolls_back(self, assembled, monkeypatch):
        """Analysis L3: a failed probe must NOT leave a phantom entry.

        ManualRegistry returns RegisterResult(ok=False, error=DeviceUnreachable);
        the handler translates it to McpError. The pool is never touched by
        ManualRegistry on the failure path, so no phantom entry survives.
        """
        srv, *_ = assembled
        pool = assembled[3]
        from debug_control_plane.device_discovery.discovery.manual_registry import RegisterResult

        class _FailingRegistry:
            def __init__(self, *a, **kw): pass
            def register(self, host, *, label=None, note=None):
                return RegisterResult(
                    ok=False,
                    error=DeviceUnreachable(f"probe failed for {host}"),
                )

        monkeypatch.setattr("debug_control_plane.mcp_plane.server.ManualRegistry", _FailingRegistry)
        h = srv.call_handler_for_test("register_device")
        from mcp.shared.exceptions import McpError
        with pytest.raises(McpError):
            await h({"host": "192.168.1.99"})
        assert pool.list_all() == [], "phantom entry left after failed probe"


# ---------------------------------------------------------------------------
# Gamepad semantic-sugar handlers (BF010 routing — full coverage)
# ---------------------------------------------------------------------------


class TestStubHandlerDispatch:
    """★ BF008-010 (Contract §0.4 方案 X): 平面 stub handler 注入接口测试.

    原业务 handler 整类用例(connect/disconnect/dpad/press_button/
    send_input 经 dispatch 测业务帧构造)属 B 类(测业务逻辑),已迁
    业务侧测试(等价覆盖 — 用 mock client 直调业务函数测同样行为)。

    control_plane test 零业务依赖(HG13),注入机制由 TestDispatchRouting.
    test_stub_handler_routes_via_dispatch + 本类 stub echo 用例覆盖。
    """

    @pytest.mark.asyncio
    async def test_stub_handler_echo_via_dispatch(self, assembled):
        srv, *_ = assembled
        h = srv.call_handler_for_test(_STUB_TOOL_NAME)
        result = await h({"k": "v"})
        assert result == {"ok": True, "echo": {"k": "v"}}


# ---------------------------------------------------------------------------
# Meta + list_changed handlers
# ---------------------------------------------------------------------------


class TestMetaAndListChanged:
    @pytest.mark.asyncio
    async def test_list_capabilities_returns_schemas(self, assembled):
        """list_capabilities probes /hello + returns the parsed schemas."""
        srv, mirror, mock_client, _ = assembled
        # Seed the mirror cache so refresh() returns it without hitting HTTP.
        nt = _make_target(registered=(
            {"id": _STUB_CAP_ID, "resources": [], "commands": []},
        ))
        mock_client.hello.return_value = nt
        h = srv.call_handler_for_test("list_capabilities")
        result = await h({"device_id": "dev1"})
        assert isinstance(result, list)
        assert any(s["capability_id"] == _STUB_CAP_ID for s in result)

    @pytest.mark.asyncio
    async def test_list_capabilities_bridge_error_degrades_to_empty(self, assembled):
        """list_capabilities on unreachable device → degrade to empty (BF009
        refresh is degrade-only: it catches BridgeError and clears the cache)."""
        srv, *_ = assembled
        mock_client = assembled[2]
        mock_client.hello.side_effect = DeviceUnreachable("nope")
        h = srv.call_handler_for_test("list_capabilities")
        result = await h({"device_id": "ghost"})
        assert result == []  # degrade — empty schema list, no crash

    @pytest.mark.asyncio
    async def test_discover_devices_empty_lan(self, assembled, monkeypatch):
        """discover_devices with no LAN candidates → empty list, no crash."""
        srv, *_ = assembled

        class _FakeLanScan:
            def __init__(self, *a, **kw): pass
            def scan(self): return []

        class _NoUsbIdentity:
            def __init__(self, *a, **kw): pass
            def all_candidates(self): return []

        monkeypatch.setattr("debug_control_plane.mcp_plane.server.LanScan", _FakeLanScan)
        monkeypatch.setattr("debug_control_plane.mcp_plane.server.UsbIdentity", _NoUsbIdentity)
        h = srv.call_handler_for_test("discover_devices")
        result = await h({"force": False})
        assert result == []

    @pytest.mark.asyncio
    async def test_discover_devices_upserts_candidates(self, assembled, monkeypatch):
        """discover_devices wires UsbIdentity + LanScan + CrossIdentify.

        With no USB candidates, the LAN-only fallback path synthesizes a
        DeviceRecord keyed on /hello.deviceId (D9 — USB identity preferred
        when available; LAN-only is the documented degrade path).
        """
        srv, *_ = assembled
        pool = assembled[3]
        from debug_control_plane.device_discovery.discovery.lan_scan import LanCandidate

        nt = _make_target(device_id="lan-dev", virtual_connected=False)
        cands = [LanCandidate(host="192.168.1.34", port=18080, network_target=nt)]

        class _FakeLanScan:
            def __init__(self, *a, **kw): pass
            def scan(self): return cands

        class _NoUsbIdentity:
            def __init__(self, *a, **kw): pass
            def all_candidates(self): return []

        monkeypatch.setattr("debug_control_plane.mcp_plane.server.LanScan", _FakeLanScan)
        monkeypatch.setattr("debug_control_plane.mcp_plane.server.UsbIdentity", _NoUsbIdentity)
        h = srv.call_handler_for_test("discover_devices")
        result = await h({})
        assert len(result) == 1
        assert result[0]["device_id"] == "lan-dev"
        # Pool gained the entry.
        assert any(r.device_id == "lan-dev" for r in pool.list_all())

    @pytest.mark.asyncio
    async def test_discover_devices_fills_last_seen_for_paired_record(
        self, assembled, monkeypatch
    ):
        """USB+LAN paired record (CrossIdentify returns last_seen=None) must
        get last_seen filled at discover time, else resolve_ip → is_ip_fresh
        returns False → TTL expired on the very next connect/dpad/get_state.

        Regression for R020 BF012 real-device e2e: USB+LAN paired devices
        (the D9 preferred path) became un-operable right after discover
        because CrossIdentify leaves last_seen=None (by design — it must not
        depend on time) and the discover handler upsert-ed the record as-is.
        The LAN-only fallback branch already stamped last_seen=time.time(),
        so "no USB" worked but "has USB" didn't.

        This test injects a fake CrossIdentify that mimics the real one's
        last_seen=None contract, then asserts discover fills it (so the
        record is fresh and resolve_ip won't stale-out).
        """
        srv, *_ = assembled
        pool = assembled[3]

        # Simulate the real CrossIdentify output for a USB+LAN paired device:
        # device_id from USB identity (D9), last_known_host from LAN, but
        # last_seen=None (CrossIdentify is pure / time-free by design).
        paired_record = DeviceRecord(
            device_id="usb-serial-001",
            label="iPhone X",
            source="auto",
            last_known_host="192.168.1.34",
            last_seen=None,  # <-- the bug: real CrossIdentify leaves this None
            hardware_name="iPhone X",
            machine_id="iPhone10,3",
            platform="ios",
        )

        class _FakeCrossIdentify:
            def __init__(self, *a, **kw): pass
            def identify(self, usb, lan):
                return [paired_record]

        # LanScan/UsbIdentity still need to be constructible (discover handler
        # instantiates them); their return values are irrelevant since
        # CrossIdentify is faked.
        class _FakeLanScan:
            def __init__(self, *a, **kw): pass
            def scan(self): return []

        class _NoUsbIdentity:
            def __init__(self, *a, **kw): pass
            def all_candidates(self): return []

        monkeypatch.setattr("debug_control_plane.mcp_plane.server.CrossIdentify", _FakeCrossIdentify)
        monkeypatch.setattr("debug_control_plane.mcp_plane.server.LanScan", _FakeLanScan)
        monkeypatch.setattr("debug_control_plane.mcp_plane.server.UsbIdentity", _NoUsbIdentity)

        h = srv.call_handler_for_test("discover_devices")
        result = await h({})

        # Discover returned the paired record.
        assert len(result) == 1
        assert result[0]["device_id"] == "usb-serial-001"

        # The bug: pool's copy must have last_seen filled (not None), so that
        # resolve_ip → is_ip_fresh returns True and the next connect/dpad/
        # get_state doesn't TTL-expire immediately.
        pooled = next(r for r in pool.list_all() if r.device_id == "usb-serial-001")
        assert pooled.last_known_host == "192.168.1.34"
        assert pooled.last_seen is not None, (
            "discover_devices must stamp last_seen for USB+LAN paired records "
            "(CrossIdentify leaves it None by design); otherwise resolve_ip "
            "is_stale=True → TTL expired on the very next operation"
        )
        # And it must actually be fresh (the whole point of stamping it).
        assert pooled.is_ip_fresh() is True

    @pytest.mark.asyncio
    async def test_discover_devices_wraps_env_error(self, assembled, monkeypatch):
        """Non-bridge discovery failure → wrapped McpError (server stays up)."""
        srv, *_ = assembled

        class _BoomLanScan:
            def __init__(self, *a, **kw): pass
            def scan(self): raise OSError("route command not found")

        class _NoUsbIdentity:
            def __init__(self, *a, **kw): pass
            def all_candidates(self): return []

        monkeypatch.setattr("debug_control_plane.mcp_plane.server.LanScan", _BoomLanScan)
        monkeypatch.setattr("debug_control_plane.mcp_plane.server.UsbIdentity", _NoUsbIdentity)
        h = srv.call_handler_for_test("discover_devices")
        from mcp.shared.exceptions import McpError
        with pytest.raises(McpError) as ei:
            await h({})
        assert "discovery failed" in str(ei.value.error.message)

    @pytest.mark.asyncio
    async def test_register_device_port_validation(self, assembled):
        """Out-of-range port → ValueError from the handler's sync validation
        (the SDK call_tool wrapper normalizes it to McpError; the raw handler
        raises ValueError — see TestDispatchRouting.test_dpad_invalid_*)."""
        srv, *_ = assembled
        h = srv.call_handler_for_test("register_device")
        with pytest.raises(ValueError):
            await h({"host": "1.2.3.4", "port": 99999})

    @pytest.mark.asyncio
    async def test_register_device_non_default_port_recorded_in_note(
        self, assembled, monkeypatch
    ):
        """Non-default port is recorded in the note for AI reference."""
        srv, *_ = assembled
        pool = assembled[3]
        from debug_control_plane.device_discovery.device_pool import manual_device_id
        from debug_control_plane.device_discovery.discovery.manual_registry import RegisterResult

        captured_note = {}

        did = manual_device_id("10.0.0.5")

        class _StubRegistry:
            def __init__(self, *a, **kw): pass
            def register(self, host, *, label=None, note=None):
                captured_note["note"] = note
                # Return a record carrying the note so it round-trips to pool.
                rec = DeviceRecord(
                    device_id=did, label=label or host, source="manual",
                    last_known_host=host, last_seen=12345.0, note=note,
                )
                pool.upsert(rec)
                return RegisterResult(ok=True, record=rec)

        monkeypatch.setattr("debug_control_plane.mcp_plane.server.ManualRegistry", _StubRegistry)
        h = srv.call_handler_for_test("register_device")
        await h({"host": "10.0.0.5", "port": 19000, "label": "L2"})
        # The handler passes the port-as-note through to ManualRegistry.
        assert captured_note["note"] == "port=19000"
        rec = pool.list_all()[0]
        assert "port=19000" in (rec.note or "")

    @pytest.mark.asyncio
    async def test_emit_list_changed_no_ctx_is_noop(self, assembled):
        """_emit_list_changed outside a request context → silent no-op."""
        srv, *_ = assembled
        # No request_ctx set → LookupError caught, no crash.
        await srv._emit_list_changed()  # noqa: SLF001

    @pytest.mark.asyncio
    async def test_emit_list_changed_with_mock_session(self, assembled, monkeypatch):
        """When a session is present in request_ctx, list_changed is sent."""
        srv, *_ = assembled
        from unittest.mock import AsyncMock

        from mcp.server.lowlevel.server import request_ctx

        sent = []
        session = MagicMock()
        # send_tool_list_changed is async — use AsyncMock so await works.
        session.send_tool_list_changed = AsyncMock(
            side_effect=lambda: sent.append(True)
        )
        ctx = MagicMock()
        ctx.session = session
        token = request_ctx.set(ctx)
        try:
            await srv._emit_list_changed()  # noqa: SLF001
        finally:
            request_ctx.reset(token)
        assert sent == [True]

    @pytest.mark.asyncio
    async def test_maybe_emit_list_changed_for_swallows_errors(self, assembled):
        """refresh failure inside the list_changed path must not propagate."""
        srv, mirror, mock_client, _ = assembled
        mock_client.hello.side_effect = DeviceUnreachable("x")
        # Should not raise even though refresh hits BridgeError.
        await srv._maybe_emit_list_changed_for("dev1")  # noqa: SLF001


# ---------------------------------------------------------------------------
# _make_app — SDK handler registration (list_tools + call_tool wiring)
# ---------------------------------------------------------------------------


class TestMakeApp:
    def test_make_app_registers_list_tools_handler(self, assembled):
        from mcp import types
        srv, *_ = assembled
        app = srv._make_app()  # noqa: SLF001
        assert types.ListToolsRequest in app.request_handlers
        assert types.CallToolRequest in app.request_handlers

    def test_make_app_carries_server_name_version(self, assembled):
        srv = assembled[0]
        app = srv._make_app()  # noqa: SLF001
        assert app.name == "mcp-debug-bridge"
        assert app.version == "0.3.0"

    def test_make_app_registers_stub_provider(self, assembled):
        """★ BF008-010 (A 类): assembled fixture 注入的 _StubProvider 已注册到
        mirror(测 providers 参数注入接口,AC-B9)。原 gamepad provider 注入测试
        属业务装配(CLEANUP),control_plane 侧用 stub 验证注入机制本身。
        """
        srv, mirror, *_ = assembled
        # assembled fixture 注入 _StubProvider,verify it's registered.
        providers = [type(p).__name__ for p in mirror._providers]  # noqa: SLF001
        assert "_StubProvider" in providers

    def test_make_app_idempotent_dispatch(self, assembled):
        """Calling _make_app twice rebuilds dispatch without leaking state.

        ★ BF008-010: dispatch 计数 = 1 stub_handler + 5 meta + 3 device-mgmt
        = 9(assembled fixture 注入 1 stub_tool handler;原 13 = 5 gamepad
        + 5 meta + 3 device-mgmt 已迁业务侧)。
        """
        srv = assembled[0]
        srv._make_app()  # noqa: SLF001
        n1 = len(srv.dispatch_for_test())
        srv._make_app()  # noqa: SLF001
        n2 = len(srv.dispatch_for_test())
        assert n1 == n2 == 9  # 1 stub + 5 meta + 3 device-mgmt

    def test_list_tools_aggregates_device_semantic_sugar(self, assembled):
        """tools/list unions static floor + cached device semantic sugar.

        ★ BF008-010 (A 类): 改用 stub capability schema 验证 aggregate +
        providers 注入接口(原 gamepad schema 测试属业务,control_plane 用
        stub 验证平面机制)。

        Verifies the §5.1 sequence + §5.5 ① path: a device with a cached
        stub schema makes the stub tool appear in ``tools/list``, even
        though MCP's tools/list protocol carries no device_id. An empty
        cache (no refresh yet) degrades to the static floor (AC8).

        Exercises the *real* ``_aggregate_tool_specs`` method (the one the
        ``@app.list_tools()`` handler delegates to) — not a copy of its
        logic — so a regression in the handler's aggregation is caught here.
        """
        srv, mirror, mock_client, pool = assembled

        # Empty cache → static floor (8 tools, no stub sugar).
        names_empty = sorted(s.name for s in srv._aggregate_tool_specs())  # noqa: SLF001
        assert _STUB_TOOL_NAME not in names_empty
        assert len(names_empty) == 8  # 5 meta + 3 device-mgmt, no duplicates

        # Register a device with a stub capability schema + refresh the cache.
        nt = _make_target(
            device_id="dev-stub",
            registered=(
                {"id": _STUB_CAP_ID, "resources": [], "commands": []},
            ),
        )
        mock_client.hello.return_value = nt
        pool.upsert(DeviceRecord(
            device_id="dev-stub", label="d", source="manual",
            last_known_host="10.0.0.1", last_seen=time.time(),
            platform="ios",
        ))
        mirror.refresh("dev-stub")

        names_full = sorted(s.name for s in srv._aggregate_tool_specs())  # noqa: SLF001
        assert _STUB_TOOL_NAME in names_full, \
            f"stub tool missing from aggregated list: {names_full}"

    def test_aggregate_skips_uncached_devices(self, assembled):
        """A pooled device with no cached schema must NOT inflate the manifest.

        Regression guard: ``build_tools(device_id)`` on an uncached device
        returns the whole static floor again, so a naive aggregation loop
        would rebuild the floor N times (then de-dup). ``_aggregate_tool_specs``
        skips uncached devices via the cheap ``schemas()`` check, so an
        uncached device contributes zero tools and the manifest stays at the
        8-tool static floor.
        """
        srv, mirror, mock_client, pool = assembled
        # Two pooled devices, NEITHER refreshed (no cache entry).
        for did in ("d-uncached-1", "d-uncached-2"):
            pool.upsert(DeviceRecord(
                device_id=did, label=did, source="manual",
                last_known_host="10.0.0.1", last_seen=time.time(),
                platform="ios",
            ))
        specs = srv._aggregate_tool_specs()  # noqa: SLF001
        names = [s.name for s in specs]
        # Floor only, no duplicates despite two uncached devices.
        assert len(names) == len(set(names)) == 8
        assert "dpad" not in names


# ---------------------------------------------------------------------------
# main() assembly chain (design §4.4) — lightweight, no real run
# ---------------------------------------------------------------------------


class TestMainAssembly:
    def test_main_wires_anyio_run(self, monkeypatch):
        """main() builds the chain and calls anyio.run on _serve."""
        called = {}
        monkeypatch.setattr(server.anyio, "run", lambda fn: called.setdefault("ran", fn))
        # Avoid touching ~/.debug-control-plane: redirect home to a temp dir.
        import tempfile
        tmp_home = tempfile.mkdtemp()
        monkeypatch.setattr(server.Path, "home", classmethod(lambda cls: server.Path(tmp_home)))
        server.main()
        assert "ran" in called
        # The function passed to anyio.run is McpServer._serve (bound method).
        assert called["ran"].__name__ == "_serve"

    def test_run_stdio_invokes_anyio_run(self, assembled, monkeypatch):
        srv = assembled[0]
        captured = {}
        monkeypatch.setattr(server.anyio, "run", lambda fn: captured.setdefault("fn", fn))
        srv.run_stdio()
        assert captured["fn"].__name__ == "_serve"


# ---------------------------------------------------------------------------
# Smoke — subprocess end-to-end (smoke_required=true on BF011)
# ---------------------------------------------------------------------------


_SMOKE_ENTRY = Path(__file__).resolve().parent / "_smoke_server_entry.py"


def _send(proc: subprocess.Popen, obj: dict) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


def _recv(proc: subprocess.Popen) -> dict:
    assert proc.stdout is not None
    line = proc.stdout.readline()
    if not line:
        err = proc.stderr.read() if proc.stderr else b""
        raise RuntimeError(f"EOF on stdout; stderr={err[:1000]!r}")
    return json.loads(line)


def _wait_for_response(proc: subprocess.Popen, req_id: int, timeout: float = 8.0) -> dict:
    """Skip notifications, return the response matching req_id."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        msg = _recv(proc)
        if msg.get("id") == req_id:
            return msg
        # Skip notifications (no id) and unrelated responses.
    raise AssertionError(f"timeout waiting for response id={req_id}")


def test_smoke_stdio_baseline(tmp_path: Path):
    """AC1 end-to-end: real server.py over stdio, empty pool baseline.

    Verifies (gates BF012 integration):
      * initialize succeeds; ``capabilities.tools.listChanged == true``
      * tools/list returns the 8 static tools (5 meta + 3 device-mgmt)
      * NO business semantic-sugar tools leak (empty pool, AC1 — main()
        keeps a bare server with no providers/tool_handlers injection)
      * tools/call list_devices returns []
      * tools/call unknown tool → isError=true (§5.5 ④)
      * tools/call ghost device → isError with discover hint
      * stdin close → process exits cleanly (NOT a daemon, design S7)
    """
    env = os.environ.copy()
    env["DEBUG_CONTROL_PLANE_POOL"] = str(tmp_path / "devices.json")

    proc = subprocess.Popen(
        [sys.executable, str(_SMOKE_ENTRY)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        # 1. initialize
        _send(proc, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "smoke-test", "version": "0.1"},
            },
        })
        init_resp = _wait_for_response(proc, 1)
        assert "result" in init_resp, f"init failed: {init_resp}"
        tools_cap = init_resp["result"]["capabilities"].get("tools", {})
        assert tools_cap.get("listChanged") is True, \
            f"tools.listChanged not declared: {tools_cap}"
        _send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})

        # 2. tools/list
        _send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        list_resp = _wait_for_response(proc, 2)
        tools = list_resp["result"]["tools"]
        names = sorted(t["name"] for t in tools)
        expected = sorted([
            "list_capabilities", "invoke_command", "read_resource",
            "get_state", "subscribe_events",
            "list_devices", "discover_devices", "register_device",
        ])
        assert names == expected, f"baseline tool set mismatch:\n got={names}\n exp={expected}"

        # ★ BF008-010 方案 X: main() 保持裸 server(providers/tool_handlers
        # 均不注入),空池 baseline 必须零业务语义糖 tool —— 用 gamepad 的 5
        # 个 tool 名作为典型业务样例做负面断言(main 没装配,这些必不在列表)。
        business_sugar_names = {
            "connect_virtual_controller", "disconnect_virtual_controller",
            "dpad", "press_button", "send_input",
        }
        assert not (business_sugar_names & set(names)), \
            f"business sugar leaked into empty-pool baseline: {business_sugar_names & set(names)}"

        # 3. tools/call list_devices (empty pool)
        _send(proc, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                     "params": {"name": "list_devices", "arguments": {}}})
        r3 = _wait_for_response(proc, 3)
        assert "error" not in r3, f"list_devices errored: {r3}"
        body = json.loads(r3["result"]["content"][0]["text"])
        assert body == [], f"expected empty list, got {body}"
        assert r3["result"].get("isError") is not True

        # 4. tools/call unknown tool → isError
        _send(proc, {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                     "params": {"name": "nonexistent_tool", "arguments": {}}})
        r4 = _wait_for_response(proc, 4)
        assert r4["result"].get("isError") is True, \
            f"unknown tool should yield isError, got: {r4}"
        assert "Unknown tool" in r4["result"]["content"][0]["text"]

        # 5. tools/call ghost device → DeviceUnreachable → isError + discover hint
        _send(proc, {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                     "params": {"name": "get_state", "arguments": {"device_id": "ghost-xyz"}}})
        r5 = _wait_for_response(proc, 5, timeout=15)  # HTTP timeout may apply
        assert r5["result"].get("isError") is True, f"ghost device should be isError: {r5}"
        msg = r5["result"]["content"][0]["text"].lower()
        assert "unreachable" in msg or "discover" in msg, \
            f"missing discover hint in error: {msg}"

    finally:
        # 6. Lifecycle: stdin close → clean exit (design S7, NOT a daemon).
        if proc.stdin is not None:
            proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
            pytest.fail("server did not exit within 5s of stdin close — is it a daemon?")
        assert proc.returncode == 0, \
            f"server exited with non-zero code {proc.returncode}"


def test_smoke_stdio_lifecycle_is_not_daemon(tmp_path: Path):
    """Stronger lifecycle assertion: the process must die with its stdin.

    A daemon would survive stdin close; this test fails fast if the server
    ever accidentally backgrounds itself (e.g. via a stray asyncio task that
    outlives the stdio transport).
    """
    env = os.environ.copy()
    env["DEBUG_CONTROL_PLANE_POOL"] = str(tmp_path / "devices.json")
    proc = subprocess.Popen(
        [sys.executable, str(_SMOKE_ENTRY)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=env,
    )
    try:
        # Don't even initialize — just close stdin. The server should exit
        # promptly (stdio_server observes EOF → Server.run returns).
        assert proc.stdin is not None
        proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
            pytest.fail("server survived stdin close — daemon-like behavior")
    finally:
        if proc.poll() is None:
            proc.kill()
