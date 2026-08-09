"""Endpoint parsing and /hello probing for network targets."""

from __future__ import annotations

import json
import re
import socket
import subprocess
import urllib.error
import urllib.request
from collections.abc import Callable, Iterable
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from ipaddress import IPv4Address, IPv4Network

from .protocol import NetworkTarget

UrlOpen = Callable[[urllib.request.Request, float], object]
LocalIpv4Provider = Callable[[], list[str]]
CommandRunner = Callable[[list[str], float], str]


@dataclass(frozen=True)
class Endpoint:
    host: str
    port: int = 18080

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    @classmethod
    def parse(cls, value: str, default_port: int = 18080) -> Endpoint:
        raw = value.strip()
        if raw.startswith("http://"):
            raw = raw[len("http://") :]
        if raw.startswith("https://"):
            raw = raw[len("https://") :]
        raw = raw.split("/", 1)[0]
        if not raw:
            raise ValueError("endpoint is empty")
        if ":" in raw:
            host, port_text = raw.rsplit(":", 1)
            if not host:
                raise ValueError("endpoint host is empty")
            return cls(host=host, port=int(port_text))
        return cls(host=raw, port=default_port)


def default_urlopen(request: urllib.request.Request, timeout: float) -> object:
    return urllib.request.urlopen(request, timeout=timeout)


def probe_hello(
    endpoint: Endpoint,
    *,
    timeout: float = 1.0,
    urlopen: UrlOpen = default_urlopen,
) -> NetworkTarget | None:
    request = urllib.request.Request(
        f"{endpoint.base_url}/hello",
        method="GET",
        headers={"Accept": "application/json"},
    )
    try:
        with urlopen(request, timeout) as response:
            body = response.read().decode("utf-8")
    except (OSError, urllib.error.URLError, TimeoutError, ValueError):
        return None
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    return NetworkTarget.from_hello(data, host=endpoint.host, port=endpoint.port)


def local_ipv4_addresses() -> list[str]:
    return sorted(_default_route_ipv4_addresses())


def discover_default_endpoints(
    *,
    local_ipv4_addresses: LocalIpv4Provider = local_ipv4_addresses,
    default_port: int = 18080,
) -> list[Endpoint]:
    endpoints: list[Endpoint] = []
    seen: set[str] = set()
    for address in local_ipv4_addresses():
        if not _is_lan_ipv4(address):
            continue
        network = IPv4Network(f"{address}/24", strict=False)
        for host in network.hosts():
            host_text = str(host)
            if host_text == address or host_text in seen:
                continue
            seen.add(host_text)
            endpoints.append(Endpoint(host_text, default_port))
    return endpoints


def discover_targets(
    endpoints: Iterable[Endpoint],
    *,
    timeout: float = 1.0,
    urlopen: UrlOpen = default_urlopen,
    max_workers: int = 64,
) -> list[NetworkTarget]:
    endpoint_list = list(endpoints)
    if not endpoint_list:
        return []
    if len(endpoint_list) == 1:
        target = probe_hello(endpoint_list[0], timeout=timeout, urlopen=urlopen)
        return [target] if target is not None else []

    targets_by_endpoint: dict[Endpoint, NetworkTarget] = {}
    with ThreadPoolExecutor(
        max_workers=min(max_workers, len(endpoint_list))
    ) as executor:
        futures = {
            executor.submit(
                probe_hello,
                endpoint,
                timeout=timeout,
                urlopen=urlopen,
            ): endpoint
            for endpoint in endpoint_list
        }
        for future in as_completed(futures):
            endpoint = futures[future]
            try:
                target = future.result()
            except Exception:
                target = None
            if target is not None:
                targets_by_endpoint[endpoint] = target
    targets: list[NetworkTarget] = []
    for endpoint in endpoint_list:
        target = targets_by_endpoint.get(endpoint)
        if target is not None:
            targets.append(target)
    return targets


def _is_lan_ipv4(address: str) -> bool:
    try:
        ip = IPv4Address(address)
    except ValueError:
        return False
    return ip.is_private and not ip.is_loopback and not ip.is_link_local


def _default_route_ipv4_addresses() -> set[str]:
    addresses: set[str] = set()
    for probe_host in ("1.1.1.1", "8.8.8.8"):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect((probe_host, 80))
                address = sock.getsockname()[0]
        except OSError:
            continue
        if _is_lan_ipv4(address):
            addresses.add(address)
    return addresses


# ---------------------------------------------------------------------------
# R020-BF002: VPN-immune LAN CIDR discovery (route-table based).
#
# 新增独立函数,不改任何旧签名(旧 _default_route_ipv4_addresses/
# local_ipv4_addresses/discover_default_endpoints 保持原状供 GUI 复用)。
# 供经 sys.path 复用。
# 设计见 .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md §5.4
# ---------------------------------------------------------------------------


def _run_command_default(command: list[str], timeout: float) -> str:
    """Run a system command and return stdout (raises OSError on failure)."""
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            return output.decode("utf-8", errors="replace")
        return output
    if result.returncode != 0:
        raise OSError(result.stderr.strip() or f"command failed: {' '.join(command)}")
    return result.stdout


def _default_route_interface(
    run_command: CommandRunner = _run_command_default,
) -> str | None:
    """`route -n get default` → interface name (e.g. en0).

    macOS-only; returns None if route command unavailable or no default route.
    网段来源改读路由表(替代旧 socket 出口法),避开全局 VPN TUN 污染:
    TUN 接口(utun1024 等)绑定具体 198.18.x.x IP,默认出口接口仍是物理 en0。
    """
    try:
        output = run_command(["route", "-n", "get", "default"], 3.0)
    except OSError:
        return None
    match = re.search(r"^\s*interface:\s*(\S+)\s*$", output, re.MULTILINE)
    return match.group(1) if match else None


def _interface_ipv4(
    interface: str,
    run_command: CommandRunner = _run_command_default,
) -> str | None:
    """`ipconfig getifaddr <interface>` → IPv4 address."""
    try:
        output = run_command(["ipconfig", "getifaddr", interface], 3.0)
    except OSError:
        return None
    address = output.strip()
    return address if _is_lan_ipv4(address) else None


def vpn_immune_lan_cidrs(
    *,
    run_command: CommandRunner = _run_command_default,
    cidr_prefix_len: int = 24,
) -> list[str]:
    """VPN-immune LAN CIDRs via route table (R020-BF002).

    流程:
    1. `route -n get default` → 默认出口接口(物理 en0,非 utun)
    2. `ipconfig getifaddr <if>` → 接口 IPv4(真实 LAN,非 198.18.x VPN TUN)
    3. /<prefix> CIDR

    任一步失败 → fallback 旧 `_default_route_ipv4_addresses()`(socket 出口法)。

    Args:
        run_command: 可注入命令执行器(默认 subprocess.run),便于 mock 测试
        cidr_prefix_len: CIDR 前缀长度(默认 /24,与 discover_default_endpoints 一致)

    Returns:
        CIDR 字符串列表(如 ["192.168.1.0/24"]);空列表表示无 LAN 可达
    """
    cidrs, _source = _resolve_lan_cidrs(
        run_command=run_command, cidr_prefix_len=cidr_prefix_len
    )
    return cidrs


def vpn_immune_lan_cidrs_traced(
    *,
    run_command: CommandRunner = _run_command_default,
    cidr_prefix_len: int = 24,
) -> tuple[list[str], str]:
    """VPN-immune LAN CIDRs + source 标记 (R020-BF003 可观测性变体)。

    与 :func:`vpn_immune_lan_cidrs` 同源 (都委托 :func:`_resolve_lan_cidrs`),
    额外返回 source 字符串供上层服务 (VpnImmune) 记录 fallback 事件。

    Args:
        run_command: 可注入命令执行器(默认 subprocess.run)
        cidr_prefix_len: CIDR 前缀长度(默认 /24)

    Returns:
        (cidrs, source) 元组:
          - cidrs: CIDR 字符串列表(与 vpn_immune_lan_cidrs 完全一致)
          - source: ``"route_table"`` (路由表成功) 或
                    ``"socket_fallback"`` (路由表失败, 回退 socket 出口法,
                    可能受 VPN TUN 污染)
    """
    return _resolve_lan_cidrs(
        run_command=run_command, cidr_prefix_len=cidr_prefix_len
    )


def _resolve_lan_cidrs(
    *,
    run_command: CommandRunner,
    cidr_prefix_len: int,
) -> tuple[list[str], str]:
    """VPN-immune LAN CIDR 解析核心 (R020-BF002/BF003 共享实现).

    返回 (cidrs, source), source 标记走了哪条路径:

    * ``route_table`` — 路由表 + ipconfig 成功(真实 LAN, VPN TUN 不污染)
    * ``socket_fallback`` — 任一步失败回退旧 socket 出口法(可能受 VPN TUN 污染)

    旧 :func:`vpn_immune_lan_cidrs` 和新 :func:`vpn_immune_lan_cidrs_traced`
    都委托本函数 — 保证两条调用路径输出完全一致(零破坏 BF002 测试).
    """
    interface = _default_route_interface(run_command)
    if interface is None:
        return _fallback_lan_cidrs(cidr_prefix_len), "socket_fallback"

    address = _interface_ipv4(interface, run_command)
    if address is None:
        return _fallback_lan_cidrs(cidr_prefix_len), "socket_fallback"

    network = IPv4Network(f"{address}/{cidr_prefix_len}", strict=False)
    return [str(network)], "route_table"


def _fallback_lan_cidrs(cidr_prefix_len: int) -> list[str]:
    """VPN-immune 失败时回退旧 socket 出口法 (design §5.4 fallback)。"""
    addresses = _default_route_ipv4_addresses()
    cidrs: list[str] = []
    for address in addresses:
        network = IPv4Network(f"{address}/{cidr_prefix_len}", strict=False)
        cidr = str(network)
        if cidr not in cidrs:
            cidrs.append(cidr)
    return cidrs
