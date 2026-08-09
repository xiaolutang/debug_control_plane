"""Import sanity — 捕获 BF007 16+ 文件 import 改写遗漏(AD-B8).

验证:
  (1) device_discovery 顶层可达(BF006 落地);
  (2) mcp_plane 顶层可达(McpServer/BridgeClient/CapabilityMirror/SemanticProvider);
  (3) mcp_plane 子模块 server/bridge_client/capability_mirror 可直接 import;
  (4) mcp_plane 零 gamepad_bridge.network 残留(import sanity, AC-B3);
  (5) mcp_plane 零 LEGACY_GAMEPAD/GAMEPAD_CAPABILITY 常量(AD-B1, AC-B5)。
"""
from __future__ import annotations

import subprocess
from pathlib import Path


def test_import_device_discovery():
    """BF006 落地的 device_discovery 顶层可达(import 不报错)."""
    from debug_control_plane.device_discovery import (
        CrossIdentify,
        DebugEvent,
        DevicePool,
        DeviceUnreachable,
        Endpoint,
        LanScan,
        ManualRegistry,
        NetworkTarget,
        UsbIdentity,
        VpnImmune,
    )
    # 静默 ruff 未使用告警(语义:符号可解析即 PASS)
    _ = (
        CrossIdentify, DebugEvent, DevicePool, DeviceUnreachable,
        Endpoint, LanScan, ManualRegistry, NetworkTarget,
        UsbIdentity, VpnImmune,
    )


def test_import_mcp_plane():
    """BF007 落地的 mcp_plane 顶层可达(import 不报错, 边界 1 降级有效)."""
    from debug_control_plane.mcp_plane import (
        BridgeClient,
        BridgeError,
        CapabilityMirror,
        CapabilitySchema,
        CommandDecl,
        DeviceHttpError,
        DeviceStale,
        McpServer,
        ResourceDecl,
        SemanticProvider,
        ToolSpec,
    )
    _ = (
        BridgeClient, CapabilityMirror, CapabilitySchema, CommandDecl,
        BridgeError, DeviceHttpError, DeviceStale, McpServer,
        ResourceDecl, SemanticProvider, ToolSpec,
    )


def test_import_mcp_plane_submodules():
    """mcp_plane 子模块 server/bridge_client/capability_mirror 可直接 import."""
    from debug_control_plane.mcp_plane import bridge_client, capability_mirror, server
    assert hasattr(server, "main")
    assert hasattr(server, "McpServer")
    assert hasattr(bridge_client, "BridgeClient")
    assert hasattr(capability_mirror, "CapabilityMirror")


def test_no_gamepad_bridge_network_residual():
    """mcp_plane 零 gamepad_bridge.network 残留(import sanity, AC-B3)."""
    repo_root = Path(__file__).resolve().parent.parent
    mcp_plane_dir = repo_root / "debug_control_plane" / "mcp_plane"
    result = subprocess.run(
        ["grep", "-rn", "gamepad_bridge.network", str(mcp_plane_dir)],
        capture_output=True,
        text=True,
    )
    assert result.stdout == "", (
        f"mcp_plane 残留 gamepad_bridge.network import:\n{result.stdout}"
    )


def test_no_legacy_gamepad_constants_in_mcp_plane():
    """AD-B1: mcp_plane 零 LEGACY_GAMEPAD_TAG/GAMEPAD_CAPABILITY_ID 常量(AC-B5).

    注:capability_mirror.py + bridge_client.py 必须 100% 干净;
    server.py 边界 1 降级段允许 gamepad_handlers/GamepadSemanticProvider
    变量名(BF008-010 收尾删),本 test 只验 LEGACY/GAMEPAD_CAPABILITY 常量名
    全域零命中(降级段不含此两常量)。
    """
    repo_root = Path(__file__).resolve().parent.parent
    mcp_plane_dir = repo_root / "debug_control_plane" / "mcp_plane"
    result = subprocess.run(
        ["grep", "-rni", "LEGACY_GAMEPAD\\|GAMEPAD_CAPABILITY", str(mcp_plane_dir)],
        capture_output=True,
        text=True,
    )
    assert result.stdout == "", (
        f"mcp_plane 残留 gamepad 常量:\n{result.stdout}"
    )
