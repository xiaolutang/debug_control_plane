"""VPN-immune LAN CIDR service (R020-BF003).

封装 :mod:`device_discovery.endpoint` 的路由表网段计算, 对上层
(LanScan / DevicePool) 暴露稳定的 ``lan_cidr()`` 接口, 同时记录 fallback
事件 (路由表失败 → socket 出口法) 供上层日志 / 诊断.

设计参考:
  - design §5.4 VPN-immune 网段计算 (route -n get default → en0 → ipconfig
    getifaddr → /24 CIDR; 失败 fallback socket 出口法, 仅兜底不主导)
  - design §4.2 BF003 角色: VpnImmune 在 LanScan 上游提供网段来源
  - tasks BF003: 封装 endpoint.vpn_immune_lan_cidrs + 暴露 fallback 可观测性

隐蔽坑 (design §5.4): 全局 VPN (Surge/ClashX TUN 模式 ``utun1024=198.18.0.1``)
劫持 ``socket.connect((1.1.1.1,80))`` 出口, 返回 198.18.x 而非真实 LAN. 本服务
依赖 endpoint 的路由表法 (读 route 输出的 interface 行), 默认路径避开 TUN 污染;
fallback 路径会暴露 ``socket_fallback`` source + 诊断 note 提示上层注意.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..endpoint import (
    CommandRunner,
    _run_command_default,
    vpn_immune_lan_cidrs_traced,
)

#: 路由表成功 source 标记 (design §5.4 主路径).
SOURCE_ROUTE_TABLE = "route_table"

#: socket 出口法 fallback source 标记 (design §5.4 兜底路径, 可能受 VPN TUN 污染).
SOURCE_SOCKET_FALLBACK = "socket_fallback"

#: fallback 路径的诊断 note (供上层日志提示运维者注意 VPN TUN 风险).
_FALLBACK_NOTE = (
    "route table unavailable, socket fallback (may be VPN TUN polluted)"
)


@dataclass
class FallbackEvent:
    """VpnImmune 网段解析事件 (供上层日志 / 诊断).

    每次 :meth:`VpnImmune.lan_cidr` 调用后刷新 ``VpnImmune.last_event``.

    Attributes:
        source: ``"route_table"`` (路由表成功) 或 ``"socket_fallback"``
            (回退 socket 出口法, 可能受 VPN TUN 污染).
        cidrs: 本次返回的 CIDR 列表 (与 ``lan_cidr()`` 返回值一致, 拷贝).
        note: 诊断说明; route_table 路径为空字符串, socket_fallback 路径
            含 VPN TUN 污染风险提示.
    """

    source: str
    cidrs: list[str]
    note: str = ""


@dataclass
class VpnImmune:
    """VPN-immune LAN 网段服务 (design §5.4).

    封装 endpoint 的路由表法, 对上层暴露 ``lan_cidr() → list[str]``; 记录
    fallback 事件 (路由表失败 → socket 出口法) 供诊断.

    Example::

        svc = VpnImmune()
        cidrs = svc.lan_cidr()           # ["192.168.1.0/24"]
        event = svc.last_event           # FallbackEvent(source="route_table", ...)
        if event.source == "socket_fallback":
            log.warning("LAN scan may be polluted by VPN TUN: %s", event.note)

    Args:
        run_command: 可注入命令执行器 (默认 ``_run_command_default`` 即 subprocess.run);
            测试时注入 mock runner (前缀匹配 command → 返回字符串或抛 OSError).
        cidr_prefix_len: CIDR 前缀长度 (默认 24, 与 discover_default_endpoints 一致).
    """

    run_command: CommandRunner = _run_command_default
    cidr_prefix_len: int = 24
    last_event: FallbackEvent | None = field(default=None, init=False)

    def lan_cidr(self) -> list[str]:
        """返回真实 LAN 网段列表 (路由表法, VPN TUN 不污染).

        Returns:
            CIDR 字符串列表 (如 ``["192.168.1.0/24"]``); 空列表表示无 LAN 可达.
            路由表失败时回退 socket 出口法, 不抛异常 (返回可能含 198.18.x).

        Side effects:
            刷新 :attr:`last_event` — 上层可读 ``source`` / ``note`` 做诊断.
        """
        cidrs, source = vpn_immune_lan_cidrs_traced(
            run_command=self.run_command, cidr_prefix_len=self.cidr_prefix_len
        )
        note = "" if source == SOURCE_ROUTE_TABLE else _FALLBACK_NOTE
        # 拷贝 cidrs 避免外部 mutate 污染内部 state (dataclass 默认可变默认值陷阱)
        self.last_event = FallbackEvent(
            source=source, cidrs=list(cidrs), note=note
        )
        return cidrs
