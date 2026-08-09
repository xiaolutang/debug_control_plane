"""device_discovery.discovery — 设备发现逻辑子包 (USB / LAN / 手动 / 交叉识别).

BF006 自旧 discovery 目录迁入。原 sibling 平级 flat import (device_pool /
discovery.X / 协议层 client) 全部改写为同包相对 import。公共符号由父包
``device_discovery`` re-export, 本子包顶层不重复声明 ``__all__``
(避免循环 / 命名重复)。

模块:
  - lan_scan: LAN /24 并发 probe /hello 扫描 (LanScan / LanCandidate)
  - usb_identity: USB serial → device_id 身份源 (UsbIdentity / UsbCandidate)
  - manual_registry: 手动 / USB 配对注册 (ManualRegistry, AD-B9 DeviceUnreachable)
  - vpn_immune: VPN TUN 不污染的 LAN CIDR 计算 (VpnImmune)
  - cross_identify: USB×LAN 交叉识别合并 (CrossIdentify / MatchReason)
"""
