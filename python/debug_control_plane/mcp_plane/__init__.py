"""mcp_plane — MCP 适配平面(server/bridge_client/capability_mirror).

模块职责:
  - server.py: MCP stdio server, R019 8 端点 handler
  - bridge_client.py: HTTP + SSE 客户端
  - capability_mirror.py: Capability 镜像 (动态 tools)
  - semantic_provider.py: BF002 SemanticProvider Protocol (字符串前向引用)

零业务依赖: 不 import 任何业务包(留业务).
mcp_plane → device_discovery 单向正向依赖.
"""
from .bridge_client import (
    BridgeClient,
    BridgeError,
    DeviceHttpError,
    DeviceStale,
)
from .capability_mirror import (
    CapabilityMirror,
    CapabilitySchema,
    CommandDecl,
    ResourceDecl,
    ToolSpec,
)
from .semantic_provider import SemanticProvider
from .server import McpServer

__all__ = [
    # bridge_client
    "BridgeClient",
    "BridgeError",
    "DeviceHttpError",
    "DeviceStale",
    # capability_mirror
    "CapabilityMirror",
    "CapabilitySchema",
    "CommandDecl",
    "ResourceDecl",
    "ToolSpec",
    # semantic_provider (BF002)
    "SemanticProvider",
    # server
    "McpServer",
]
