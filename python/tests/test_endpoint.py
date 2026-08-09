"""endpoint.py 单元测试 (LAN 扫描骨架 + IP 地址获取).

AC 覆盖:
  probe_hello / discover_targets (迁移)
  local_ipv4_addresses / _default_route_ipv4_addresses (新增)

迁移来源:
  - 业务侧 test_network_r020_bf002.py
    TestLanScanSkeleton (5 tests, 拆分为 TestProbeHello 2 + TestDiscoverTargets 3)

设计来源:
  - .dev-flow/R021/analysis/2026-08-09--test-ownership-fix-design.md §4.2
"""
from __future__ import annotations

# ===========================================================================
# Imports
# ===========================================================================
from io import BytesIO

from debug_control_plane.device_discovery.endpoint import (
    Endpoint,
    _default_route_ipv4_addresses,
    discover_targets,
    local_ipv4_addresses,
    probe_hello,
)

# ---------------------------------------------------------------------------
# Helpers — 复用 debug_control_plane 测试惯例的 mock urlopen
# ---------------------------------------------------------------------------


class _FakeResponse:
    """urllib HTTP 响应替身 (支持 context manager + read)."""

    def __init__(self, body: bytes) -> None:
        self._buf = BytesIO(body)

    def __enter__(self) -> _FakeResponse:
        return self

    def __exit__(self, *exc) -> None:
        self._buf.close()

    def read(self) -> bytes:
        return self._buf.getvalue()


def make_urlopen(body_by_host: dict[str, bytes] | bytes):
    """构造 mock urlopen, 按 host 返回不同 body (或固定 body)."""

    def urlopen(request, timeout):  # noqa: ANN001
        url = request.full_url
        if isinstance(body_by_host, (bytes, str)):
            body = body_by_host
            if isinstance(body, str):
                body = body.encode("utf-8")
            return _FakeResponse(body)
        for host, body in body_by_host.items():
            if host in url:
                return _FakeResponse(body)
        raise OSError(f"no mock for url: {url}")

    return urlopen


# ===========================================================================
# probe_hello (迁移 2 tests)
# ===========================================================================


class TestProbeHello:
    """probe_hello 单元测试.

    迁移自 test_network_r020_bf002.py::TestLanScanSkeleton.
    """

    _HELLO_BODY = (
        b'{"deviceId":"gmacro-virtual-iOS","deviceName":"iPhone X",'
        b'"platform":"ios","protocolVersion":1,'
        b'"capabilities":["virtual_input","profiles","sse"],'
        b'"activeSource":"game","virtualConnected":false,'
        b'"localIps":["192.168.1.34"]}'
    )

    def test_probe_hello_returns_target_with_bridge_fields(self) -> None:
        """mock /hello 响应 → probe_hello 返回 NetworkTarget (含 deviceId/localIps).

        断言要点:
        - target.device_id == "gmacro-virtual-iOS"
        - target.device_name == "iPhone X"
        - target.platform == "ios"
        - "192.168.1.34" in target.local_ips
        """
        endpoint = Endpoint("192.168.1.34", 18080)
        target = probe_hello(endpoint, urlopen=make_urlopen(self._HELLO_BODY))
        assert target is not None
        assert target.device_id == "gmacro-virtual-iOS"
        assert target.device_name == "iPhone X"
        assert target.platform == "ios"
        assert "192.168.1.34" in target.local_ips

    def test_probe_hello_returns_none_on_connection_refused(self) -> None:
        """设备离线 → urlopen 抛 OSError → probe_hello 返回 None (不崩)."""

        def urlopen(request, timeout):  # noqa: ANN001
            raise OSError("connection refused")

        endpoint = Endpoint("192.168.1.99", 18080)
        assert probe_hello(endpoint, urlopen=urlopen) is None


# ===========================================================================
# discover_targets (迁移 3 tests)
# ===========================================================================


class TestDiscoverTargets:
    """discover_targets 单元测试.

    迁移自 test_network_r020_bf002.py::TestLanScanSkeleton.
    """

    _HELLO_BODY = (
        b'{"deviceId":"gmacro-virtual-iOS","deviceName":"iPhone X",'
        b'"platform":"ios","protocolVersion":1,'
        b'"capabilities":["virtual_input","profiles","sse"],'
        b'"activeSource":"game","virtualConnected":false,'
        b'"localIps":["192.168.1.34"]}'
    )

    def test_discover_targets_concurrent_scan_finds_responding_host(self) -> None:
        """并发扫描多 endpoint, 只有响应 /hello 的 endpoint 被发现。

        断言要点:
        - endpoints = [Endpoint("192.168.1.33", 18080), Endpoint("192.168.1.34", 18080), ...]
        - 只有 192.168.1.34 响应 → len(targets) == 1
        - targets[0].device_id == "gmacro-virtual-iOS"
        """
        endpoints = [
            Endpoint("192.168.1.33", 18080),
            Endpoint("192.168.1.34", 18080),  # 这个响应
            Endpoint("192.168.1.35", 18080),
        ]
        urlopen = make_urlopen({"192.168.1.34": self._HELLO_BODY})
        targets = discover_targets(endpoints, urlopen=urlopen, timeout=0.5)
        assert len(targets) == 1
        assert targets[0].device_id == "gmacro-virtual-iOS"
        assert targets[0].host == "192.168.1.34"

    def test_discover_targets_single_endpoint_short_circuit(self) -> None:
        """单 endpoint 走快速路径 (无 ThreadPoolExecutor) → 现有行为不破坏。"""
        endpoint = Endpoint("192.168.1.34", 18080)
        urlopen = make_urlopen(self._HELLO_BODY)
        targets = discover_targets([endpoint], urlopen=urlopen, timeout=0.5)
        assert len(targets) == 1
        assert targets[0].device_id == "gmacro-virtual-iOS"

    def test_discover_targets_empty_returns_empty(self) -> None:
        """空 endpoint 列表 → 返回空 (边界)."""
        assert discover_targets([], urlopen=make_urlopen(b"{}")) == []


# ===========================================================================
# 新增测试 (3 tests)
# ===========================================================================


class TestLocalIpv4Addresses:
    """local_ipv4_addresses 单元测试 (新增)."""

    def test_local_ipv4_addresses_returns_sorted_list(self) -> None:
        """local_ipv4_addresses() 返回 sorted list[str] (非 set).

        断言要点:
        - result == sorted(result)
        - 所有元素是合法 IPv4 地址
        """
        result = local_ipv4_addresses()
        assert isinstance(result, list)
        assert result == sorted(result)
        # 验证 IPv4 合法性（非空且可被 ipaddress 解析）
        for addr in result:
            assert isinstance(addr, str)
            # 简单格式验证（避免引入 ipaddress 依赖）
            parts = addr.split(".")
            assert len(parts) == 4
            assert all(p.isdigit() for p in parts)


class TestDefaultRouteIpv4Addresses:
    """_default_route_ipv4_addresses 单元测试 (新增).

    注意: 此函数是 VPN-immune fallback 依赖的旧 socket 出口法, 应保证正确性.
    """

    def test_default_route_ipv4_addresses_returns_set(self) -> None:
        """_default_route_ipv4_addresses() 返回 set[str] (签名契约)."""
        result = _default_route_ipv4_addresses()
        assert isinstance(result, set)
        for addr in result:
            assert isinstance(addr, str)

    def test_default_route_ipv4_addresses_no_crash_on_empty_lan(self) -> None:
        """无 LAN IP 时不崩, 返回空 set (测试环境常见)."""
        # 无法控制真机 socket 出口, 只验证不崩 + 返回 set
        result = _default_route_ipv4_addresses()
        assert isinstance(result, set)
