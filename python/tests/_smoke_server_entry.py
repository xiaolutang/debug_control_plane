"""Smoke-test server entry point.

R020-BF011 subprocess smoke helper. Used *only* by ``test_server.py``'s
``test_smoke_stdio_baseline`` — it boots the real server.py over stdio with
a *temporary empty* DevicePool (via ``DEBUG_CONTROL_PLANE_POOL`` env var), so
the AC1 baseline (empty pool → no gamepad tools) is deterministic without
touching ``~/.debug-control-plane/devices.json``.

This file lives in tests/ (not at package root) so it's never installed
and never imported by server.py — it's a pure subprocess entrypoint.

BF007: sys.path 注入删除(AD-B2),改正经包 import(pip install -e . 装入)。
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

# Silence INFO logs so they don't pollute the stdio MCP wire (server logs go
# to stderr by default, but INFO can be noisy during a smoke run).
logging.disable(logging.CRITICAL)

from debug_control_plane.device_discovery.device_pool import DevicePool  # noqa: E402
from debug_control_plane.mcp_plane.bridge_client import BridgeClient  # noqa: E402
from debug_control_plane.mcp_plane.capability_mirror import CapabilityMirror  # noqa: E402
from debug_control_plane.mcp_plane.server import McpServer  # noqa: E402

pool_path = Path(
    os.environ.get("DEBUG_CONTROL_PLANE_POOL")
    or (Path.home() / ".debug-control-plane" / "devices.json")
)
pool = DevicePool(persist_path=pool_path)
client = BridgeClient(pool=pool)
mirror = CapabilityMirror(client=client)
srv = McpServer(mirror=mirror, client=client, pool=pool)
srv.run_stdio()
