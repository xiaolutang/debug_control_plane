"""LAN 并发 probe /hello 扫描服务 (R020-BF005).

职责 (design §3.4): VPN-immune 网段内并发 probe ``/hello`` (复用
``endpoint.probe_hello`` / ``discover_targets``), 把命中的 host 包装成
``LanCandidate`` 返回给上层 (BF006 cross_identify / BF007 manual_registry).

设计要点 (design §5.4):
  * **网段来源**: ``VpnImmune.lan_cidr()`` (BF003, 路由表法, VPN TUN 不污染).
    LanScan 完全信任注入的网段来源 — 网段正确性由 VpnImmune 保证, 本服务
    不自带任何 IP 过滤 (职责分离).
  * **并发 + 异常吞**: 复用 ``endpoint.discover_targets`` (BF002 已内置
    ``ThreadPoolExecutor`` 并发 + future 异常吞 None). LanScan 不重写并发
    逻辑 (design D8 零重写).
  * **超时短**: 默认 2.5s (design §5.4: 2-3s), 避免扫描 /24 网段时累计太长.
  * **故障注入容错** (test §4.4): probe 超时/拒绝/JSON 错都不崩, 由
    ``discover_targets`` 内部吞异常返 None, LanScan 收到空 list.

``NetworkTarget`` (BF005 复用, 方案 A): ``from_hello`` 解析全部 /hello 字段,
含 R020 FF001/FF002 扩展字段 (``hardware_name``/``machine_id``/
``registered_capabilities``). 老 /hello 无这些字段默认 None, 向后兼容.
LanCandidate.network_target 是单一真相源, BF006 cross_identify 直接消费,
不需再独立解析 hello meta.

设计来源:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF005 节
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
            §3.4 LanScan 职责 / §5.4 VPN-immune 流程
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §4.4
"""

from __future__ import annotations

from dataclasses import dataclass
from ipaddress import IPv4Network
from typing import TYPE_CHECKING

from ..endpoint import (
    Endpoint,
    UrlOpen,
    discover_targets,
)
from ..protocol import NetworkTarget

if TYPE_CHECKING:  # pragma: no cover - typing only
    from .vpn_immune import VpnImmune


#: R019 debug plane HTTP 端口 (mobile app 固定监听此端口).
DEFAULT_PORT = 18080

#: probe /hello 超时 (design §5.4: 2-3s). 短超时避免 /24 网段累计太长;
#: discover_targets 并发 64 worker, 254 host 实际约 4 轮, 总耗时 < 10s.
DEFAULT_PROBE_TIMEOUT = 2.5

#: discover_targets 并发 worker 数 (与 BF002 endpoint 默认一致).
DEFAULT_MAX_WORKERS = 64


@dataclass(frozen=True)
class LanCandidate:
    """单个 LAN 命中候选 (probe /hello 成功的 host).

    携带 ``host`` + ``port`` + ``network_target`` (from_hello 解析的完整
    /hello 响应, 含 R020 FF001/FF002 扩展字段). BF006 cross_identify 用
    ``hardware_name``/``machine_id``/``local_ips`` 做交叉识别.

    Attributes:
        host: 命中设备的 IPv4 地址 (来自 endpoint.host).
        port: probe 用的端口 (DEFAULT_PORT 或注入的 port).
        network_target: ``NetworkTarget.from_hello`` 解析结果, 含全部
            /hello 字段 (deviceId/capabilities/localIps + R020 扩展字段).
    """

    host: str
    port: int
    network_target: NetworkTarget


class LanScan:
    """LAN 并发 probe /hello 扫描服务 (design §3.4 / §5.4).

    网段来源 ``VpnImmune.lan_cidr()`` (路由表法, VPN TUN 不污染); 并发 probe
    复用 ``endpoint.discover_targets`` (D8 零重写, 已内置 ThreadPoolExecutor
    + 异常吞). 超时短 (默认 2.5s).

    Example::

        from .vpn_immune import VpnImmune

        scanner = LanScan(VpnImmune())
        candidates = scanner.scan()
        for cand in candidates:
            print(cand.host, cand.network_target.device_id,
                  cand.network_target.hardware_name)

    Args:
        vpn_immune: BF003 VpnImmune 服务实例 (提供真实 LAN 网段).
        port: probe 端口 (默认 18080, R019 debug plane).
        probe_timeout: 单次 probe /hello 超时秒数 (默认 2.5s, design §5.4).
        urlopen: 可注入的 urlopen (默认 ``endpoint.default_urlopen``, 即
            ``urllib.request.urlopen``); 测试时注入 mock (按 host 返不同 body).
        max_workers: 并发 worker 数 (默认 64, 与 endpoint 默认一致).
    """

    def __init__(
        self,
        vpn_immune: VpnImmune,
        *,
        port: int = DEFAULT_PORT,
        probe_timeout: float = DEFAULT_PROBE_TIMEOUT,
        urlopen: UrlOpen | None = None,
        max_workers: int = DEFAULT_MAX_WORKERS,
    ) -> None:
        self._vpn_immune = vpn_immune
        self._port = port
        self._probe_timeout = probe_timeout
        self._urlopen = urlopen
        self.max_workers = max_workers

    def scan(self) -> list[LanCandidate]:
        """并发 probe ``VpnImmune.lan_cidr()`` 网段内所有 host 的 /hello.

        Returns:
            ``LanCandidate`` 列表 (保持 endpoints 顺序, 即网段 IP 升序);
            空 list 表示无设备响应 (手机离线 / 网段无 host / probe 全失败).
            永不抛异常 — probe 超时/拒绝/JSON 错都由 discover_targets 吞掉.

        Side effects:
            调用 ``self._vpn_immune.lan_cidr()`` (可能刷新 VpnImmune.last_event).
        """
        cidrs = self._vpn_immune.lan_cidr()
        endpoints = self._endpoints_from_cidrs(cidrs)
        if not endpoints:
            return []
        kwargs: dict[str, object] = {
            "timeout": self._probe_timeout,
            "max_workers": self.max_workers,
        }
        if self._urlopen is not None:
            kwargs["urlopen"] = self._urlopen
        targets = discover_targets(endpoints, **kwargs)
        return [
            LanCandidate(host=target.host, port=target.port, network_target=target)
            for target in targets
        ]

    def _endpoints_from_cidrs(self, cidrs: list[str]) -> list[Endpoint]:
        """把 CIDR 列表展开成 ``Endpoint`` 列表 (IP 升序, 去重).

        复用 ``discover_default_endpoints`` 的 /24 枚举模式 (BF002), 但网段
        来源是注入的 cidrs 而非 socket 出口法 — 保证 VPN TUN 不污染.

        Args:
            cidrs: CIDR 字符串列表 (如 ``["192.168.1.0/24"]``).

        Returns:
            ``Endpoint`` 列表, 每个 CIDR 用 ``IPv4Network.hosts()`` 枚举
            (去掉网络号 + 广播地址); 跨 CIDR 去重 host.
        """
        endpoints: list[Endpoint] = []
        seen: set[str] = set()
        for cidr in cidrs:
            try:
                network = IPv4Network(cidr, strict=False)
            except ValueError:
                # 畸形 CIDR 跳过 (VpnImmune 应保证格式, 但容错不崩)
                continue
            for host in network.hosts():
                host_text = str(host)
                if host_text in seen:
                    continue
                seen.add(host_text)
                endpoints.append(Endpoint(host_text, self._port))
        return endpoints


__all__ = [
    "DEFAULT_MAX_WORKERS",
    "DEFAULT_PORT",
    "DEFAULT_PROBE_TIMEOUT",
    "LanCandidate",
    "LanScan",
]
