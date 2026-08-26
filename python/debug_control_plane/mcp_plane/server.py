"""MCP stdio server — assembly point for the debug-bridge adapter layer.

(R020-BF011)

This module is the **single SDK touchpoint** (design §3.4 / §4.4): it wires
BF001/BF005/BF008/BF009/BF010 onto the MCP Python SDK and serves the result
over stdio. The lifecycle follows the AI session (``run_stdio`` blocks until
the client closes stdin; the process exits, it is NOT a daemon — design S7).

mcp SDK 1.28.1 spike conclusions (BF011.5, see evidence):

    * **Why the low-level ``Server`` (not ``FastMCP``):** FastMCP's
      ``add_tool(fn)`` derives ``inputSchema`` from the function's type hints.
      Our tools come from :class:`CapabilityMirror.build_tools`, which already
      carries a hand-built JSON-Schema dict (BF009 ``ToolSpec.input_schema``).
      The low-level ``Server`` lets ``@server.list_tools()`` return
      ``mcp.types.Tool(name, description, inputSchema=...)`` directly — a 1:1
      mapping of ToolSpec → Tool with zero hint-derivation friction. It also
      re-runs the handler on **every** ``tools/list`` and refreshes
      ``_tool_cache`` from the return value (verified in source) — which is
      exactly design §5.5 ① "snapshot rebuild, recompute the whole table each
      time" without us having to manage ``add_tool``/``remove_tool``.
    * **``capabilities.tools.listChanged=true``** is declared automatically
      once a ``@server.list_tools()`` handler is registered *and*
      ``NotificationOptions(tools_changed=True)`` is passed to
      ``create_initialization_options`` (verified — ``get_capabilities`` maps
      handler presence + notification option to the capability flag).
    * **``notifications/tools/list_changed``** is sent via
      ``request_ctx.get().session.send_tool_list_changed()``. The session is
      only reachable inside a request handler (it is a local var of
      ``Server.run``), so a background polling task cannot send it. Design
      §5.5 ②③ "list_changed + polling" is therefore realized as: after any
      tool call that may mutate the manifest (``discover_devices`` /
      ``register_device`` / ``list_capabilities``), the handler — still inside
      the request context — calls ``mirror.refresh`` for the affected device
      and, on change, emits the notification. The **main consistency path**
      remains §5.5 ① (every ``tools/list`` recomputes from current /hello),
      so list_changed is a SHOULD-tier convenience, not a consistency
      requirement (design §5.5 D-1).
    * **Error mapping (§5.5 ④):** ``raise McpError(ErrorData(...))`` from
      ``call_tool`` is converted by the SDK (``raise_exceptions=False``) into
      a ``CallToolResult(isError=True, content=[TextContent(message)])``.
      This is the MCP-spec "Tool Execution Error" path and what we use for
      every :class:`BridgeError` subclass (DeviceUnreachable / DeviceStale /
      DeviceHttpError), so the AI gets a structured, actionable error instead
      of the server crashing.

Refs:
    - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF011
    - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
              §3.4 McpServer / §4.4 Python API / §5.1 sequence / §5.2 degrade
              / §5.5 tool-table consistency
    - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1
"""

from __future__ import annotations

import logging
import time
from pathlib import Path
from typing import Any

import anyio

# --- mcp SDK (spike: low-level Server, see module docstring) ----------------
from mcp import types
from mcp.server import NotificationOptions
from mcp.server.lowlevel.server import Server, request_ctx
from mcp.server.stdio import stdio_server
from mcp.shared.exceptions import McpError

from debug_control_plane.device_discovery.device_pool import DevicePool, DeviceRecord
from debug_control_plane.device_discovery.discovery.cross_identify import CrossIdentify
from debug_control_plane.device_discovery.discovery.lan_scan import LanScan
from debug_control_plane.device_discovery.discovery.manual_registry import ManualRegistry
from debug_control_plane.device_discovery.discovery.usb_identity import UsbIdentity
from debug_control_plane.device_discovery.discovery.vpn_immune import VpnImmune

# --- BF007 包内相对 + 跨包 device_discovery -------------------------------
from .bridge_client import (
    BridgeClient,
    BridgeError,
    DeviceAuthError,
    DeviceHttpError,
    DeviceStale,
    DeviceUnreachable,
)
from .capability_mirror import CapabilityMirror, ToolSpec
from .semantic_provider import SemanticProvider

# ★ BF008-010 (Contract §0.1 边界 1 收尾 + 方案 X): capability-specific semantic
# sugar 已迁业务侧(强耦合产品 protocol,属业务知识)。平面 server 零业务依赖
# (硬约束②),改 __init__ providers + tool_handlers 参数注入。业务装配(console-
# script 装 SemanticProvider 子类 + 业务 async handler + 启动 McpServer)归
# R021-CLEANUP;main() 保持裸 server(providers=None, tool_handlers=None)。

logger = logging.getLogger("debug_control_plane.mcp_plane.server")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: Default listen port of the phone's R19 debug plane.
_DEFAULT_PORT: int = 18080

#: How many events to drain from the SSE stream per ``subscribe_events`` call.
#:
#: MCP stdio is request/response — a single ``tools/call`` must return. We
#: drain a bounded batch of buffered events and return them; the AI can call
#: again for the next batch. (design §4.2.2 subscribe_events — SSE mapped to
#: structured DebugEvent; long-lived streaming is not a fit for the stdio
#: request/response model.)
_SUBSCRIBE_EVENT_BATCH: int = 16

#: Cap of wall-clock seconds for one ``subscribe_events`` batch. Keeps the
#: tool responsive when the stream is quiet (returns whatever arrived).
_SUBSCRIBE_EVENT_TIMEOUT_S: float = 1.0


# ---------------------------------------------------------------------------
# Tool-spec → mcp Tool adapter (the only place that imports mcp.types.Tool)
# ---------------------------------------------------------------------------


def _tool_spec_to_mcp(spec: ToolSpec) -> types.Tool:
    """Map BF009's SDK-agnostic ToolSpec onto an ``mcp.types.Tool``.

    The fields are 1:1 (``name`` / ``description`` / ``inputSchema``). This
    is the seam BF011 owns: BF009 stays SDK-free and testable without a live
    server; BF011 is the single module that knows about the mcp SDK's Tool
    shape (layered design, see capability_mirror.py docstring).
    """
    return types.Tool(
        name=spec.name,
        description=spec.description,
        inputSchema=spec.input_schema,
    )


# ---------------------------------------------------------------------------
# BridgeError → McpError translation (design §5.5 ④ error floor)
# ---------------------------------------------------------------------------


# R001-BB001 (BB001.1/BB001.3): auth errors carry a stable ``code``
# (PROTOCOL.md §2.4). Map each code to the user's next step — never a bare
# "token validation failed". Token clearing already happened in BridgeClient
# (BF009); the MCP layer only surfaces the hint, and the message must never
# contain a plaintext token.
_TOKEN_CLEARED_ACTION = (
    " — the locally cached token was cleared; re-authorize on the App "
    "(open the App and grant access again), then retry"
)
_DENIED_ACTION = (
    " — the App denied or does not grant this access; do not retry "
    "automatically (check the App's permission settings or ask the "
    "user to allow this client)"
)
_AUTH_CODE_ACTIONS: dict[str, str] = {
    "authorization_required": (
        " — open the App on the device and approve the authorization request "
        "(this client is not yet authorized; no token was sent or accepted)"
    ),
    # Token-family codes share one remediation.
    **dict.fromkeys(
        ("token_expired", "token_revoked", "invalid_token"), _TOKEN_CLEARED_ACTION
    ),
    # authorization_denied / forbidden: no automatic retry.
    **dict.fromkeys(("authorization_denied", "forbidden"), _DENIED_ACTION),
}


def _bridge_error_to_mcp(exc: BridgeError | DeviceUnreachable) -> McpError:
    """Translate a :class:`BridgeError` into an MCP ``isError`` result.

    Keeps the server alive (no crash) and gives the AI an actionable hint:

      * :class:`DeviceUnreachable` → "device {id} not found; run
        discover_devices or register_device first" (analysis L1/L2/L3).
      * :class:`DeviceStale` → "device {id} IP TTL expired; re-discover"
        (design §5.3).
      * :class:`DeviceHttpError` → verbatim status_code + body (so 409
        ``real_controller_active`` propagates with its hint).
      * bare :class:`BridgeError` → generic transport failure.

    The MCP ``code`` mirrors JSON-RPC's ``-32602`` (invalid params) semantics
    so AI clients that branch on the code treat it as a retryable user error
    rather than a fatal server fault.
    """
    if isinstance(exc, DeviceAuthError):
        # MUST precede the DeviceHttpError branch: DeviceAuthError is a
        # DeviceHttpError subclass, so isinstance order decides which branch
        # fires. Unknown codes fall back to the deny-style hint (safe default:
        # no automatic retry).
        action = _AUTH_CODE_ACTIONS.get(exc.code, _DENIED_ACTION)
        message = (
            f"device authorization error: auth_code={exc.code} "
            f"status={exc.status_code}{action}"
        )
    elif isinstance(exc, DeviceHttpError):
        hint = ""
        # 409 real_controller_active: the phone's contract says the real pad
        # wins; surface that as an actionable hint (analysis fault injection).
        if exc.status_code == 409:
            hint = " (real controller is active — disconnect it or let it win)"
        message = (
            f"device HTTP error: status={exc.status_code} "
            f"body={exc.body!r}{hint}"
        )
    elif isinstance(exc, DeviceUnreachable):
        message = (
            f"device unreachable: {exc}"
            " — run discover_devices (or register_device with a known host)"
        )
    elif isinstance(exc, DeviceStale):
        message = (
            f"device stale: {exc}"
            " — IP TTL expired; run discover_devices to re-locate it"
        )
    else:
        message = f"bridge error: {exc}"

    return McpError(
        types.ErrorData(code=-32602, message=message, data=None)
    )


# ---------------------------------------------------------------------------
# McpServer — assembly + handler registration
# ---------------------------------------------------------------------------


class McpServer:
    """MCP stdio server holding the assembled adapter layer (design §4.4).

    Owns three concerns, each delegated to its BF module:

      * **Manifest** (what tools exist): :class:`CapabilityMirror` — queried
        on every ``tools/list`` (design §5.5 ①).
      * **Dispatch** (executing a tool by name): a name → async-handler table
        wired here; each handler delegates to BridgeClient / DevicePool /
        injected business handlers and maps BridgeError → McpError.
      * **Lifecycle** (stdio blocking on the AI session): ``run_stdio``
        enters ``stdio_server`` + ``Server.run``; the process exits when the
        client disconnects stdin (NOT a daemon — design S7).

    Construction is side-effect-free; the SDK handlers are registered in
    :meth:`_register_handlers` (called from :meth:`run_stdio` so the
    :class:`Server` instance is created lazily, keeping tests cheap).
    """

    def __init__(
        self,
        mirror: CapabilityMirror,
        client: BridgeClient,
        pool: DevicePool,
        *,
        server_name: str = "mcp-debug-bridge",
        server_version: str = "0.3.0",
        providers: list[SemanticProvider] | None = None,
        tool_handlers: dict[str, Any] | None = None,
    ) -> None:
        """Assemble the adapter layer with optional semantic-sugar injection.

        ★ BF010 (Contract §0.1 边界 1 收尾 + 方案 X): ``providers`` +
        ``tool_handlers`` are the **injection interface** for capability-
        specific semantic sugar (per-product). The server itself is
        capability-agnostic — it knows nothing about any product's
        capability protocol. The caller (console-script entry, R021-CLEANUP)
        wires the product's ``SemanticProvider`` subclass + async handler
        map here.

        ``providers`` are registered on ``mirror`` once at construction so
        ``build_tools()`` sees them from the very first tools/list (design
        §3.4 SRV→MIR→ST arrow; idempotent on CapabilityMirror's side).

        ``tool_handlers`` is the business async handler map (tool name →
        ``async (args) -> result``). ``_build_dispatch`` merges it with the
        meta + device-management handlers; main() keeps a bare server
        (``tool_handlers=None``) so the control_plane repo stays zero-
        business-dependency (硬约束②). 补 design 空白:SemanticProvider
        Protocol 只暴露 manifest (matches + build_tools), 不含 handler
        注入接口(BF002 YAGNI),故 handler 走独立参数。
        """
        self._mirror = mirror
        self._client = client
        self._pool = pool
        self._server_name = server_name
        self._server_version = server_version
        # ★ BF010: 外部注入 providers (server 零业务硬编码).
        for p in (providers or []):
            self._mirror.register_provider(p)
        # ★ 补 design 空白: 外部注入 tool_handlers (业务 async handler).
        self._tool_handlers: dict[str, Any] = (
            dict(tool_handlers) if tool_handlers else {}
        )
        # Lazy-built low-level Server (created in run_stdio so __init__ stays
        # side-effect-free and unit tests can construct McpServer cheaply).
        self._app: Server | None = None
        self._dispatch: dict[str, Any] = {}

    # ------------------------------------------------------------------
    # Dispatch table — built once, called per tools/call
    # ------------------------------------------------------------------

    def _build_dispatch(self) -> dict[str, Any]:
        """Return the name → async-handler map (design §4.2 tool routing).

        Each handler takes the raw ``arguments`` dict and returns an MCP
        result (list[Content] | CallToolResult | dict). They wrap the
        synchronous BF modules in ``anyio.to_thread.run_sync`` so the stdio
        event loop is never blocked by an HTTP probe (BridgeClient is sync;
        spike confirmed the SDK runs handlers on the event loop directly).
        """
        client = self._client
        pool = self._pool
        mirror = self._mirror

        async def _run(sync_fn, *args):
            """Run a sync BF call off the event loop + map errors to MCP.

            AD-B9 后 DeviceUnreachable 直继承 Exception(脱离 BridgeError),
            需独立 catch 调 ``_bridge_error_to_mcp``(该函数内已有
            ``isinstance(exc, DeviceUnreachable)`` 分支,运行时正常翻译)。
            """
            try:
                return await anyio.to_thread.run_sync(sync_fn, *args)
            except (BridgeError, DeviceUnreachable) as exc:
                raise _bridge_error_to_mcp(exc) from exc

        # ★ BF008-010 (Contract §0.1 边界 1 收尾): capability-specific
        # semantic-sugar handlers 整段删 — 业务 async handler 改由 __init__
        # tool_handlers 参数注入,_build_dispatch 合并 **self._tool_handlers
        # (见下方 return)。平面 server 零业务知识(硬约束②),业务装配归
        # R021-CLEANUP。

        # -- meta tools (BF008 BridgeClient forward) ---------------------
        async def h_invoke_command(args):
            # invoke_command is the unknown-capability fallback (design §4.2.2
            # / AC10). BF009's input schema carries capability_id +
            # command_path segments + args; the phone's REST contract keys on
            # method+path, so we forward command_path as the path and pass
            # the body verbatim. method defaults to POST (R19 commands are
            # all POST per the debug-capability declarations); a future
            # schema field could override it. capability_id is reserved for
            # routing/audit (the phone's path already encodes it) so it's
            # validated for presence by the schema but not forwarded.
            return await _run(
                client.invoke,
                args["device_id"], "POST",
                list(args.get("command_path", [])),
                args.get("args"),
            )

        async def h_read_resource(args):
            return await _run(
                client.read,
                args["device_id"], list(args.get("resource_path", [])),
            )

        async def h_list_capabilities(args):
            device_id = args["device_id"]
            # Probe /hello + drive list_changed change-detection (§5.5 ②③).
            # ``mirror.refresh`` is **degrade-only**: it catches every
            # BridgeError subclass itself (clearing the cache, returning the
            # had-cache signal) and never re-raises — so this probe does not
            # throw on an unreachable device; it just yields an empty schema
            # list. We capture refresh's change signal here (one HTTP probe)
            # and feed it straight into ``_emit_list_changed`` below, rather
            # than re-probing via ``_maybe_emit_list_changed_for``.
            # R001-BB001: refresh also stays non-raising for auth errors
            # (recording them queryably instead); we surface them HERE as an
            # MCP error so "unauthorized" is never silently degraded to an
            # empty "no capabilities" answer.
            def _probe():
                changed = mirror.refresh(device_id)
                auth_err = mirror.auth_error(device_id)
                return mirror.schemas(device_id), changed, auth_err

            schemas, changed, auth_err = await anyio.to_thread.run_sync(_probe)

            if auth_err is not None:
                raise _bridge_error_to_mcp(auth_err)

            # Drive list_changed from this request's context (session is
            # reachable here — see module docstring spike note). Best-effort:
            # §5.5 ① (every tools/list recomputes) is the main consistency
            # path; this notification is the SHOULD-tier convenience.
            if changed:
                await self._emit_list_changed()

            return _schemas_to_jsonable(schemas)

        async def h_get_state(args):
            return await _run(client.read, args["device_id"], ["state"])

        async def h_subscribe_events(args):
            device_id = args["device_id"]
            event_types = args.get("event_types")

            def _drain():
                events = []
                it = client.events(device_id, event_types)
                # Bounded drain: collect up to N events or until the quiet
                # timeout. The iterator is from BridgeClient.events (SSE
                # → structured DebugEvent); we do NOT hold it open forever
                # (stdio is request/response, see _SUBSCRIBE_EVENT_BATCH).
                deadline = time.monotonic() + _SUBSCRIBE_EVENT_TIMEOUT_S
                for ev in it:
                    events.append(ev)
                    if len(events) >= _SUBSCRIBE_EVENT_BATCH:
                        break
                    if time.monotonic() >= deadline:
                        break
                return events

            try:
                events = await anyio.to_thread.run_sync(_drain)
            except (BridgeError, DeviceUnreachable) as exc:
                raise _bridge_error_to_mcp(exc) from exc

            return [_event_to_jsonable(ev) for ev in events]

        # -- device-management tools (DevicePool + LanScan) --------------
        async def h_list_devices(args):
            def _list():
                return [_device_record_to_jsonable(r) for r in pool.list_all()]
            return await anyio.to_thread.run_sync(_list)

        async def h_discover_devices(args):
            # force: today neither UsbIdentity nor LanScan has a cache, so the
            # flag is a no-op at runtime; we still log it so the assembly point
            # is visible (BF004/006 will own cache bypass when they land).
            force = bool(args.get("force", False))
            if force:
                logger.info(
                    "discover_devices force=True "
                    "(cache bypass reserved for BF004/006)"
                )
            def _discover():
                vpn_immune = VpnImmune()
                lan_scan = LanScan(vpn_immune=vpn_immune)
                # BF004 UsbIdentity (Android adb + iOS flutter — never xcrun
                # devicectl per memory ios16-device-devicectl-pitfall).
                usb_identity = UsbIdentity()
                usb_candidates = usb_identity.all_candidates()
                lan_candidates = lan_scan.scan()

                # BF006 CrossIdentify: D7 layered fallback chain. Returns
                # DeviceRecords with device_id from USB identity (D9) —
                # ambiguous devices are marked and still upserted so the
                # AI/developer can see them and resolve via register_device.
                cross = CrossIdentify()
                records = cross.identify(usb_candidates, lan_candidates)

                # LAN-only fallback: a device that's reachable on LAN but has
                # no USB candidate (cable unplugged, iOS over WiFi-only, etc.)
                # shouldn't be invisible. The D9 identity source for these is
                # the LAN /hello.deviceId (NOT USB) — this is the documented
                # "LAN-only" degrade path. We synthesize a record keyed on
                # the LAN host so the device is addressable; the AI can still
                # operate it via the normal device_id → resolve_ip → forward
                # chain. (Identity collision across devices with the same
                # R019-fixed deviceId is the known limitation here, which is
                # exactly why USB-first is preferred when available.)
                bound_hosts = {rec.last_known_host for rec in records}
                for cand in lan_candidates:
                    if cand.host in bound_hosts:
                        continue
                    nt = cand.network_target
                    rec = DeviceRecord(
                        device_id=nt.device_id or f"lan-{cand.host}",
                        label=nt.device_name or cand.host,
                        source="auto",
                        last_known_host=cand.host,
                        last_seen=time.time(),
                        hardware_name=nt.hardware_name,
                        machine_id=nt.machine_id,
                        platform=nt.platform,
                        network_target=nt,
                    )
                    records.append(rec)

                # CrossIdentify leaves last_seen=None on USB+LAN paired
                # records by design (it's pure / time-free — see
                # cross_identify.py _merge). The LAN-only fallback branch
                # above already stamps last_seen=time.time() on its
                # synthesized records; without the same treatment here, the
                # D9 *preferred* path (USB+LAN paired) becomes un-operable
                # right after discover: resolve_ip → is_ip_fresh sees
                # last_seen=None → False → stale → TTL expired on the very
                # next connect/dpad/get_state. USB+LAN pairing means the
                # host just answered /hello, so stamping now is semantically
                # correct. (R020 BF012 e2e fix.)
                now = time.time()
                for rec in records:
                    if rec.last_seen is None and rec.last_known_host is not None:
                        rec.last_seen = now
                    pool.upsert(rec)
                return records

            try:
                records = await anyio.to_thread.run_sync(_discover)
            except BridgeError as exc:
                raise _bridge_error_to_mcp(exc) from exc
            except Exception as exc:  # noqa: BLE001 — discovery may hit env errors
                # Wrap non-bridge discovery failures (subnet parse, command
                # exec, ...) so the AI still gets a structured error rather
                # than the server crashing.
                raise McpError(types.ErrorData(
                    code=-32603,
                    message=f"discovery failed: {exc}",
                )) from exc

            # Discovery likely changed the pool; refresh every known device's
            # schema and notify (§5.5 ②③).
            await self._maybe_emit_list_changed_all()
            return [_device_record_to_jsonable(r) for r in records]

        async def h_register_device(args):
            host = args["host"]
            port = int(args.get("port", _DEFAULT_PORT))
            # Validate port range up-front so an out-of-range value is a clean
            # local error rather than an opaque HTTP connect failure later.
            if not (1 <= port <= 65535):
                raise ValueError(f"port out of range: {port}")
            label = args.get("label")
            note = f"port={port}" if port != _DEFAULT_PORT else None

            # BF007 ManualRegistry owns the probe + identity + pool upsert.
            # It accepts a LanScan instance for forward-compat (per BF007
            # design — register does NOT call scan(), it only does a single-
            # host probe via probe_hello). A failed probe returns
            # RegisterResult(ok=False) with a DeviceUnreachable, which we
            # translate into the MCP device_unreachable error (analysis L3:
            # a failed register must NOT leave a phantom entry in the pool —
            # ManualRegistry honors this by construction: it only upserts on
            # a successful probe).
            def _register():
                lan_scan = LanScan(vpn_immune=VpnImmune())
                registry = ManualRegistry(
                    pool=pool, lan_scan=lan_scan, port=port,
                )
                return registry.register(host, label=label, note=note)

            result = await anyio.to_thread.run_sync(_register)
            if not result.ok:
                # ManualRegistry returned ok=False → probe failed, pool is
                # untouched (no phantom entry). Surface as device_unreachable
                # via the standard BridgeError → McpError translation so the
                # AI gets the discover/register hint.
                raise _bridge_error_to_mcp(result.error)  # type: ignore[arg-type]

            await self._maybe_emit_list_changed_for(result.record.device_id)
            return _device_record_to_jsonable(result.record)

        return {
            # ★ BF008-010 (Contract §0.1): 业务 async handler 注入接口合并.
            # main() 不注入(tool_handlers=None)则为空 dict — 平面 server 零
            # 业务 handler;业务装配(console-script)注入产品 handler(归
            # R021-CLEANUP)。
            **self._tool_handlers,
            # meta tools (BF008 forward)
            "invoke_command": h_invoke_command,
            "read_resource": h_read_resource,
            "list_capabilities": h_list_capabilities,
            "get_state": h_get_state,
            "subscribe_events": h_subscribe_events,
            # device management (DevicePool + LanScan)
            "list_devices": h_list_devices,
            "discover_devices": h_discover_devices,
            "register_device": h_register_device,
        }

    # ------------------------------------------------------------------
    # list_changed emission (§5.5 ②③; main path is ①, this is auxiliary)
    # ------------------------------------------------------------------

    async def _maybe_emit_list_changed_for(self, device_id: str) -> None:
        """Best-effort list_changed notification after a per-device change.

        Runs :meth:`CapabilityMirror.refresh` (idempotent; returns the
        change signal). On change, sends ``notifications/tools/list_changed``
        via the current request's session. Failures are swallowed: the main
        consistency path (§5.5 ① every tools/list recomputes) makes this a
        SHOULD, not a MUST — a missed notification just means the client
        re-lists on its own schedule.
        """
        try:
            def _refresh():
                return self._mirror.refresh(device_id)
            changed = await anyio.to_thread.run_sync(_refresh)
            if changed:
                await self._emit_list_changed()
        except Exception:  # noqa: BLE001
            logger.debug("list_changed emission failed", exc_info=True)

    async def _maybe_emit_list_changed_all(self) -> None:
        """Refresh every pooled device's schema + emit list_changed on change."""
        try:
            device_ids = [r.device_id for r in self._pool.list_all()]
            any_changed = False
            for device_id in device_ids:
                def _refresh(d=device_id):
                    return self._mirror.refresh(d)
                changed = await anyio.to_thread.run_sync(_refresh)
                any_changed = any_changed or changed
            if any_changed:
                await self._emit_list_changed()
        except Exception:  # noqa: BLE001
            logger.debug("list_changed bulk emission failed", exc_info=True)

    async def _emit_list_changed(self) -> None:
        """Send ``notifications/tools/list_changed`` if a session is active.

        ``request_ctx`` is only set inside an in-flight request handler
        (spike: ``Server._handle_request`` sets the contextvar, ``Server.run``
        holds the session as a local). Calling this outside a handler is a
        no-op, which is fine — list_changed is best-effort (design §5.5 D-1).
        """
        try:
            ctx = request_ctx.get()
        except LookupError:
            # Not inside a request (e.g. a hypothetical background poll). The
            # main consistency path (tools/list recompute) still holds.
            return
        session = ctx.session
        if session is not None:
            await session.send_tool_list_changed()

    # ------------------------------------------------------------------
    # SDK handler registration (lazy; called from run_stdio)
    # ------------------------------------------------------------------

    def _aggregate_tool_specs(self) -> list[ToolSpec]:
        """Build the global tool manifest for ``tools/list`` (design §5.5 ①).

        The MCP ``tools/list`` protocol carries no ``device_id`` (the AI asks
        for "everything you can do"), so we can't delegate to
        ``mirror.build_tools(device_id)`` directly. Instead we union:

          1. the static floor (meta + device-mgmt, always present)
          2. each pooled device's cached semantic-sugar tools

        de-duplicated by name (BF010 owns its namespace so collisions only
        happen if two devices expose the same same capability, in which case
        the tool is identical and the union is correct).

        Devices with no cached schema yet (never refreshed, or last refresh
        failed) contribute nothing — they degrade to the static floor, which
        is exactly the AC8 path. We skip them via the cheap no-I/O
        :meth:`CapabilityMirror.schemas` check: ``build_tools(device_id)`` on
        an uncached device returns the *whole static floor again*, so calling
        it for every pooled device would rebuild the floor N times (all
        immediately de-duped against ``seen_names`` — wasted work). Only
        devices whose cache is populated can contribute new tools.

        Factored out of the ``@app.list_tools()`` handler so the aggregation
        logic is directly unit-testable without booting the SDK.
        """
        specs = self._mirror.build_tools(None)
        seen_names = {s.name for s in specs}
        for record in self._pool.list_all():
            if not self._mirror.schemas(record.device_id):
                continue  # uncached → contributes only the floor (already in specs)
            for s in self._mirror.build_tools(record.device_id):
                if s.name not in seen_names:
                    specs.append(s)
                    seen_names.add(s.name)
        return specs

    def _make_app(self) -> Server:
        app = Server(self._server_name, version=self._server_version)
        self._dispatch = self._build_dispatch()
        dispatch = self._dispatch

        @app.list_tools()
        async def list_tools() -> list[types.Tool]:
            # Design §5.5 ① — recompute the entire manifest on every call.
            # The AI learns about new capabilities via ``list_capabilities``
            # (which refreshes the cache) + the ``list_changed`` notification
            # that follows (§5.5 ②③). Aggregation lives in
            # :meth:`_aggregate_tool_specs` so it's unit-testable.
            return [_tool_spec_to_mcp(s) for s in self._aggregate_tool_specs()]

        @app.call_tool()
        async def call_tool(name: str, arguments: dict):
            handler = dispatch.get(name)
            if handler is None:
                # §5.5 ④ fallback — an AI holding a stale tool name gets a
                # structured "unknown tool" error so it can self-correct.
                raise McpError(types.ErrorData(
                    code=-32602,
                    message=f"Unknown tool: {name}",
                ))
            # Handlers may raise McpError (BridgeError translation) OR a
            # ValueError from a handler's own arg validation (e.g. business
            # handler enum checks). Normalize ValueError into the same
            # isError path so the AI sees a clean local-error message rather
            # than a transport traceback.
            try:
                result = await handler(arguments or {})
            except ValueError as exc:
                raise McpError(types.ErrorData(
                    code=-32602,
                    message=f"invalid argument: {exc}",
                )) from exc

            # Result normalization: dict/list[Content]/CallToolResult/scalar.
            return _normalize_tool_result(result)

        return app

    # ------------------------------------------------------------------
    # Lifecycle (design §4.4 — run_stdio blocks on the AI session)
    # ------------------------------------------------------------------

    async def _serve(self) -> None:
        app = self._make_app()
        self._app = app
        init_opts = app.create_initialization_options(
            notification_options=NotificationOptions(tools_changed=True)
        )
        async with stdio_server() as (read_stream, write_stream):
            await app.run(
                read_stream,
                write_stream,
                init_opts,
                # raise_exceptions=False keeps the server alive when a
                # handler raises something we didn't translate — the SDK
                # turns it into an error response instead of crashing the
                # process (matches the §5.5 ④ "never crash" intent).
                raise_exceptions=False,
            )

    def run_stdio(self) -> None:
        """Block on stdio until the AI client closes stdin (design §4.4).

        Synchronous entry point for ``main()`` and the console script. The
        process exits when ``stdio_server`` observes EOF on stdin, which
        happens when the AI session ends — this is NOT a daemon (design S7,
        AC verified by the smoke test: subprocess stdin close → clean exit).
        """
        anyio.run(self._serve)

    # ------------------------------------------------------------------
    # Test accessors (used by unit tests; not part of the public surface)
    # ------------------------------------------------------------------

    def dispatch_for_test(self) -> dict[str, Any]:
        """Return the name → handler map for unit testing (no server start).

        Lets tests exercise the dispatch logic (business/meta/device-mgmt
        routing + error translation) without booting a stdio subprocess.
        """
        if not self._dispatch:
            self._dispatch = self._build_dispatch()
        return self._dispatch

    def call_handler_for_test(self, name: str):
        """Resolve a handler by name (raises KeyError if unknown)."""
        if not self._dispatch:
            self._dispatch = self._build_dispatch()
        return self._dispatch[name]


# ---------------------------------------------------------------------------
# Result normalization (handler return → MCP content blocks)
# ---------------------------------------------------------------------------


def _normalize_tool_result(result: Any) -> Any:
    """Coerce a handler's return value into an MCP call_tool result.

    The SDK's ``@app.call_tool()`` handler accepts several shapes; we
    standardize on:

      * already a ``CallToolResult`` → returned as-is.
      * list of ``Content`` blocks → returned as-is.
      * ``dict`` / ``list`` / primitive → wrapped as a single TextContent
        with a JSON dump (and the dict also passed as structuredContent
        when it's a dict, so AI clients that prefer structured output see
        it too).
    """
    # Already-shaped results pass through. We require the *whole* list to be
    # ContentBlocks — an empty list is ambiguous (could be data: "no devices"),
    # so we treat it as data and JSON-encode it below (otherwise the SDK would
    # treat it as "no content" and the AI would see an empty response).
    if isinstance(result, types.CallToolResult):
        return result
    if isinstance(result, list) and result and all(_is_content_block(b) for b in result):
        return result

    # Plain data → JSON text (+ structuredContent for dicts).
    # Pydantic models, dataclasses, and other structured values are JSON'd
    # via _json_default (which handles model_dump / asdict / frozenset /
    # tuple). We deliberately include these here rather than falling through
    # to str(), so the AI sees structured JSON (e.g. a NetworkTarget) instead
    # of an opaque Python repr.
    import dataclasses as _dc
    import json
    is_struct = (
        isinstance(result, (dict, list, bool, int, float, str))
        or result is None
        or hasattr(result, "model_dump")  # pydantic v2
        or _dc.is_dataclass(result)
    )
    if is_struct:
        text = json.dumps(result, default=_json_default, ensure_ascii=False)
        content = [types.TextContent(type="text", text=text)]
        if isinstance(result, dict):
            return types.CallToolResult(
                content=content, structuredContent=result, isError=False
            )
        return content

    # Fallback: stringify anything else.
    return [types.TextContent(type="text", text=str(result))]


def _is_content_block(obj: Any) -> bool:
    return isinstance(
        obj,
        (
            types.TextContent,
            types.ImageContent,
            types.AudioContent,
            types.ResourceLink,
            types.EmbeddedResource,
        ),
    )


def _json_default(obj: Any) -> Any:
    """JSON serializer for objects the stdlib json can't handle."""
    # Frozen dataclasses / pydantic models (NetworkTarget, DebugEvent, ...).
    if hasattr(obj, "model_dump"):
        return obj.model_dump()
    import dataclasses
    if dataclasses.is_dataclass(obj):
        return dataclasses.asdict(obj)
    # Frozenset → sorted list (deterministic for capabilities).
    if isinstance(obj, (frozenset, set)):
        return sorted(obj)
    # Tuple → list.
    if isinstance(obj, tuple):
        return list(obj)
    raise TypeError(f"not JSON serializable: {type(obj).__name__}")


# ---------------------------------------------------------------------------
# JSON-able views (avoid leaking internal state to the AI)
# ---------------------------------------------------------------------------


def _device_record_to_jsonable(rec: DeviceRecord) -> dict[str, Any]:
    """Return a public view of a DeviceRecord (design §4.2.1 — sanitized).

    The MCP client never sees internal TTL / last_seen timestamps; it sees
    the identity + display fields it needs to address a device (device_id,
    label, source, platform, hardware_name, machine_id, connected flag).
    """
    return {
        "device_id": rec.device_id,
        "label": rec.label,
        "source": rec.source,
        "platform": rec.platform,
        "hardware_name": rec.hardware_name,
        "machine_id": rec.machine_id,
        "connected": rec.network_target.virtual_connected if rec.network_target else None,
    }


def _schemas_to_jsonable(schemas) -> list[dict[str, Any]]:
    """Serialize CapabilitySchema[] for the ``list_capabilities`` tool."""
    import dataclasses
    out: list[dict[str, Any]] = []
    for sch in schemas:
        entry: dict[str, Any] = {
            "capability_id": sch.capability_id,
            "resources": [dataclasses.asdict(r) for r in sch.resources],
            "commands": [dataclasses.asdict(c) for c in sch.commands],
            "scope": sch.scope,
        }
        if sch.description is not None:
            entry["description"] = sch.description
        if sch.page_id is not None:
            entry["pageId"] = sch.page_id
        if sch.page_name is not None:
            entry["pageName"] = sch.page_name
        if sch.scope_revision is not None:
            entry["scopeRevision"] = sch.scope_revision
        out.append(entry)
    return out


def _event_to_jsonable(ev) -> dict[str, Any]:
    """Serialize a DebugEvent for the ``subscribe_events`` tool."""
    import dataclasses
    return dataclasses.asdict(ev)


# ---------------------------------------------------------------------------
# main() — design §4.4 assembly chain (verbatim)
# ---------------------------------------------------------------------------


def main() -> None:
    """Assemble the adapter layer and run the stdio server (design §4.4).

    Construction order follows the design's dependency chain (each line takes
    the previous as a constructor arg, single-direction dependency §3.4):

        DevicePool → BridgeClient → CapabilityMirror → McpServer → run_stdio
    """
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    pool = DevicePool(persist_path=Path.home() / ".debug-control-plane" / "devices.json")
    client = BridgeClient(pool=pool)
    mirror = CapabilityMirror(client=client)
    server = McpServer(mirror=mirror, client=client, pool=pool)
    server.run_stdio()  # blocks; exits when the AI client closes stdin


if __name__ == "__main__":
    main()
