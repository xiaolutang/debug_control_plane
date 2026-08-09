"""device_discovery — 设备发现平面 (网络 DTO + 设备池 + 发现逻辑).

模块职责:
  - protocol / endpoint / device_candidates: 网络 DTO 与探测
  - device_pool (认身份不认地址)
  - discovery/ 5 模块 (USB / LAN / 手动 / 交叉识别)
  - DeviceUnreachable 定义于 protocol (网络平面异常, 直继承 Exception)

零业务依赖: 不 import 任何业务包.
纯 stdlib + 同包相对 import, 可独立 pip install.
"""
from .device_candidates import (
    CommandRunner,
    ConnectedDeviceEndpoint,
    ConnectedDeviceInventory,
    IosDeviceCandidate,
    discover_connected_device_endpoints,
    discover_connected_device_inventory,
    discover_connected_devices,
    discover_ios_flutter_candidates,
)
from .device_pool import DevicePool, DeviceRecord
from .discovery.cross_identify import CrossIdentify
from .discovery.lan_scan import LanCandidate, LanScan
from .discovery.manual_registry import ManualRegistry
from .discovery.usb_identity import UsbCandidate, UsbIdentity
from .discovery.vpn_immune import VpnImmune
from .endpoint import (
    Endpoint,
    UrlOpen,
    default_urlopen,
    discover_default_endpoints,
    discover_targets,
    local_ipv4_addresses,
    probe_hello,
)
from .protocol import (
    ControllerProfile,
    DebugEvent,
    DeviceUnreachable,
    NetworkState,
    NetworkTarget,
)

__all__ = [
    # protocol (BF006 network DTO + AD-B9 DeviceUnreachable)
    "NetworkTarget",
    "NetworkState",
    "DebugEvent",
    "ControllerProfile",
    "DeviceUnreachable",
    # endpoint (BF006 network probe)
    "Endpoint",
    "UrlOpen",
    "default_urlopen",
    "probe_hello",
    "discover_targets",
    "discover_default_endpoints",
    "local_ipv4_addresses",
    # device_candidates (BF006 connected-device inventory)
    "CommandRunner",
    "ConnectedDeviceEndpoint",
    "ConnectedDeviceInventory",
    "IosDeviceCandidate",
    "discover_connected_device_endpoints",
    "discover_connected_device_inventory",
    "discover_connected_devices",
    "discover_ios_flutter_candidates",
    # device_pool (BF006 认身份不认地址)
    "DevicePool",
    "DeviceRecord",
    # discovery (BF006 USB/LAN/手动/交叉)
    "LanScan",
    "LanCandidate",
    "UsbIdentity",
    "UsbCandidate",
    "ManualRegistry",
    "VpnImmune",
    "CrossIdentify",
]
