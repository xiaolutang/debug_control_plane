"""R020-BF005 LanScan 服务测试 (并发 probe /hello 扫网段)。

AC 覆盖:
  AC2/AC3 VPN-immune 网段内并发 probe /hello 命中手机 (实测 192.168.1.34)
     — mock VpnImmune.lan_cidr 返 ["192.168.1.0/24"], mock urlopen 对该 host
     返 /hello JSON → scan() 返含该 host 的 LanCandidate, network_target 解析正确
  AC4 全局 VPN TUN 启用扫描不受污染 — scan 只扫注入 vpn_immune 返的真实网段,
     不扫 198.18.x
  §4.4 probe 超时/拒绝不崩 — mock urlopen 抛 URLError/OSError → scan() 返 []

设计来源:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF005 节
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md §3.4/§5.4
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §4.4

注意: LanScan 是 SERVICE 层 (网段来源 + 并发扫描), 与 BF002 endpoint 层
      discover_targets/probe_hello 互补不重复. 并发 + 异常吞由 endpoint
      discover_targets 内置 (BF002 已验证); LanScan 只负责把 cidr → endpoints
      → LanCandidate[], 以及把 urlopen/vpn_immune 注入拼起来.
"""

from __future__ import annotations

import urllib.error
from io import BytesIO

from debug_control_plane.device_discovery.discovery.lan_scan import (
    DEFAULT_PORT,
    DEFAULT_PROBE_TIMEOUT,
    LanCandidate,
    LanScan,
)
from debug_control_plane.device_discovery.discovery.vpn_immune import VpnImmune

# ---------------------------------------------------------------------------
# Mock helpers — urlopen 按 host 返不同 body; VpnImmune 替身返固定 cidr.
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


def make_urlopen(body_by_host: dict[str, bytes | Exception] | bytes | Exception):
    """构造 mock urlopen, 按 host 返不同 body (或固定 body/Exception)."""

    def urlopen(request, timeout):  # noqa: ANN001 (urllib 签名)
        url = request.full_url
        if isinstance(body_by_host, (bytes, str)):
            body = body_by_host
            if isinstance(body, str):
                body = body.encode("utf-8")
            return _FakeResponse(body)
        if isinstance(body_by_host, Exception):
            raise body_by_host
        for host, body in body_by_host.items():
            if host in url:
                if isinstance(body, Exception):
                    raise body
                return _FakeResponse(body)
        raise OSError(f"no mock for url: {url}")

    return urlopen


class _StubVpnImmune:
    """VpnImmune 替身: 返固定 cidr 列表, 不调系统命令."""

    def __init__(self, cidrs: list[str]) -> None:
        self._cidrs = cidrs
        self.call_count = 0

    def lan_cidr(self) -> list[str]:
        self.call_count += 1
        return list(self._cidrs)


# /hello 响应 fixtures — 新版含 hardwareName/machineId/registeredCapabilities,
# 老版只有 deviceId/deviceName/capabilities/localIps (向后兼容).
HELLO_BODY_FULL = (
    b'{"deviceId":"gmacro-virtual-iOS","deviceName":"iPhone X",'
    b'"platform":"ios","protocolVersion":1,'
    b'"capabilities":["virtual_input","profiles","sse"],'
    b'"activeSource":"game","virtualConnected":false,'
    b'"localIps":["192.168.1.34"],'
    b'"hardwareName":"iPhone X","machineId":"iPhone10,3",'
    b'"registeredCapabilities":['
    b'{"id":"gamepad","resources":[{"method":"GET","path":["profiles"]}],'
    b'"commands":[{"method":"POST","path":["virtual","connect"]}]}'
    b"]}"
)

HELLO_BODY_LEGACY = (
    b'{"deviceId":"gmacro-virtual-iOS","deviceName":"iPhone X",'
    b'"platform":"ios","protocolVersion":1,'
    b'"capabilities":["virtual_input","profiles","sse"],'
    b'"activeSource":"game","virtualConnected":false,'
    b'"localIps":["192.168.1.34"]}'
)


# ===========================================================================
# AC2/AC3: 命中场景 — 并发 probe 网段, 命中手机
# ===========================================================================


class TestLanScanHit:
    """scan() 命中 /hello 响应的 host → 返 LanCandidate."""

    def test_scan_finds_responding_host_in_cidr(self) -> None:
        """vpn_immune 返 /24, 某 host 响应 /hello → scan 返含该 host 的 candidate."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30"])  # 4 IP, hosts() = 2
        urlopen = make_urlopen({"192.168.1.1": HELLO_BODY_FULL})
        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)

        candidates = scanner.scan()

        assert len(candidates) == 1
        cand = candidates[0]
        assert cand.host == "192.168.1.1"
        assert cand.port == DEFAULT_PORT
        assert isinstance(cand, LanCandidate)
        # network_target 解析正确 (基础字段 + R020 扩展字段)
        assert cand.network_target.device_id == "gmacro-virtual-iOS"
        assert cand.network_target.device_name == "iPhone X"
        assert cand.network_target.host == "192.168.1.1"
        assert "192.168.1.34" in cand.network_target.local_ips
        # R020 FF001/FF002 扩展字段
        assert cand.network_target.hardware_name == "iPhone X"
        assert cand.network_target.machine_id == "iPhone10,3"
        assert cand.network_target.registered_capabilities is not None
        assert len(cand.network_target.registered_capabilities) == 1
        assert cand.network_target.registered_capabilities[0]["id"] == "gamepad"

    def test_scan_uses_vpn_immune_lan_cidr(self) -> None:
        """scan 调用注入的 vpn_immune.lan_cidr() 拿网段."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30"])
        scanner = LanScan(vpn_immune, urlopen=make_urlopen(HELLO_BODY_FULL))
        assert vpn_immune.call_count == 0
        scanner.scan()
        assert vpn_immune.call_count == 1


class TestLanScanMultipleHits:
    """多 host 并发 probe, 部分命中部分超时 → 只返命中的."""

    def test_scan_returns_only_responding_hosts(self) -> None:
        """3 个 host (4 IP /30 → 2 hosts), 1 个响应 /hello, 1 个超时."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30"])  # hosts: .1, .2
        urlopen = make_urlopen({"192.168.1.1": HELLO_BODY_LEGACY})
        # 192.168.1.2 无 mock → urlopen 抛 OSError → probe_hello 返 None
        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)

        candidates = scanner.scan()

        assert len(candidates) == 1
        assert candidates[0].host == "192.168.1.1"

    def test_scan_multiple_cidrs_aggregated(self) -> None:
        """两个 /30 网段, 各 1 个 host 响应 → 返 2 个 candidate (顺序保 endpoints 顺序)."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30", "192.168.2.0/30"])
        urlopen = make_urlopen(
            {
                "192.168.1.1": HELLO_BODY_LEGACY,
                "192.168.2.1": HELLO_BODY_FULL,
            }
        )
        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)

        candidates = scanner.scan()

        assert len(candidates) == 2
        hosts = [c.host for c in candidates]
        assert "192.168.1.1" in hosts
        assert "192.168.2.1" in hosts


# ===========================================================================
# §4.4: 故障注入 — 手机离线 (probe 全失败)
# ===========================================================================


class TestLanScanAllFail:
    """probe 全失败 (手机离线) → scan() 返 [] 不崩."""

    def test_scan_returns_empty_when_all_timeout(self) -> None:
        """所有 host urlopen 抛 OSError → scan() 返空 list."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30"])
        urlopen = make_urlopen(OSError("connection refused"))
        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)

        candidates = scanner.scan()

        assert candidates == []

    def test_scan_returns_empty_when_all_urlerror(self) -> None:
        """所有 host urlopen 抛 URLError → scan() 返空 list (URLError 是 OSError 子类)."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30"])
        urlopen = make_urlopen(urllib.error.URLError("timeout"))
        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)

        candidates = scanner.scan()

        assert candidates == []

    def test_scan_returns_empty_when_no_cidr(self) -> None:
        """vpn_immune 返空 cidr (无 LAN 可达) → scan 返空 list, 不调 urlopen."""
        vpn_immune = _StubVpnImmune([])
        urlopen_calls: list = []

        def urlopen(request, timeout):  # noqa: ANN001
            urlopen_calls.append(request)
            return _FakeResponse(HELLO_BODY_LEGACY)

        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)
        candidates = scanner.scan()

        assert candidates == []
        assert urlopen_calls == []


# ===========================================================================
# AC4: VPN TUN 不污染 — scan 只扫注入 vpn_immune 返的网段
# ===========================================================================


class TestLanScanVpnTunImmune:
    """scan 不读系统路由表, 只扫注入 vpn_immune.lan_cidr() 返的网段."""

    def test_scan_does_not_touch_vpn_tun_range(self) -> None:
        """vpn_immune 返真实 LAN (192.168.1.0/30), scan 绝不扫 198.18.x."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30"])
        scanned_hosts: list[str] = []

        def urlopen(request, timeout):  # noqa: ANN001
            url = request.full_url
            for octet in ("1", "2"):
                host = f"192.168.1.{octet}"
                if host in url:
                    scanned_hosts.append(host)
                    return _FakeResponse(HELLO_BODY_LEGACY)
            # 任何其他 host (含 198.18.x) 触发断言失败
            raise AssertionError(f"scan must not probe outside real LAN: {url}")

        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)
        scanner.scan()

        # 验证只扫了真实 LAN 网段内的 host
        for host in scanned_hosts:
            assert host.startswith("192.168.1.")
        assert all("198.18." not in h for h in scanned_hosts)

    def test_scan_would_probe_vpn_range_if_vpn_immune_returned_it(self) -> None:
        """反向验证: 若 vpn_immune 返 198.18.x (被污染), scan 会扫它 —
        证明 scan 不自带过滤, 完全信任 vpn_immune 的网段来源 (职责分离).
        """
        vpn_immune = _StubVpnImmune(["198.18.0.0/30"])  # VPN TUN 网段
        urlopen = make_urlopen({"198.18.0.1": HELLO_BODY_LEGACY})
        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)

        candidates = scanner.scan()

        # scan 信任 vpn_immune, 命中了 VPN 网段的 host — 这是设计预期
        # (网段正确性由 VpnImmune 保证, 不由 LanScan)
        assert len(candidates) == 1
        assert candidates[0].host == "198.18.0.1"


# ===========================================================================
# 配置透传 — port / probe_timeout / max_workers
# ===========================================================================


class TestLanScanConfigForwarding:
    """port / probe_timeout / max_workers 透传到 endpoint.discover_targets."""

    def test_custom_port_used_in_endpoints(self) -> None:
        """port=19999 → scan 扫的 endpoints 都用 19999."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30"])
        probed_ports: list[int] = []

        def urlopen(request, timeout):  # noqa: ANN001
            url = request.full_url
            # url 形如 http://192.168.1.1:19999/hello
            if ":19999/" in url:
                probed_ports.append(19999)
                # 只让 .1 命中, .2 模拟超时 (返 OSError)
                if "192.168.1.1" in url:
                    return _FakeResponse(HELLO_BODY_LEGACY)
                raise OSError("timeout")
            raise OSError(f"wrong port in url: {url}")

        scanner = LanScan(
            vpn_immune, port=19999, urlopen=urlopen, probe_timeout=0.5
        )
        candidates = scanner.scan()

        assert len(candidates) == 1
        assert candidates[0].port == 19999
        # /30 → 2 hosts (.1, .2), 都用 19999 端口被探测
        assert probed_ports == [19999, 19999]

    def test_probe_timeout_forwarded(self) -> None:
        """probe_timeout=3.3 透传到 urlopen 的 timeout 参数."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30"])
        seen_timeouts: list[float] = []

        def urlopen(request, timeout):  # noqa: ANN001
            seen_timeouts.append(timeout)
            return _FakeResponse(HELLO_BODY_LEGACY)

        scanner = LanScan(
            vpn_immune, urlopen=urlopen, probe_timeout=3.3
        )
        scanner.scan()

        assert all(t == 3.3 for t in seen_timeouts)
        assert len(seen_timeouts) >= 1

    def test_max_workers_forwarded(self) -> None:
        """max_workers=4 透传到 discover_targets (验证属性 + 不崩)."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30"])
        scanner = LanScan(
            vpn_immune,
            urlopen=make_urlopen(HELLO_BODY_LEGACY),
            max_workers=4,
        )
        assert scanner.max_workers == 4
        # 不强断并发数 (内部细节), 只断言 scan 正常工作
        candidates = scanner.scan()
        assert len(candidates) >= 1

    def test_default_constants(self) -> None:
        """DEFAULT_PORT=18080, DEFAULT_PROBE_TIMEOUT 在合理范围 (2-3s per design)."""
        assert DEFAULT_PORT == 18080
        assert 2.0 <= DEFAULT_PROBE_TIMEOUT <= 3.0

    def test_malformed_cidr_skipped_not_crash(self) -> None:
        """畸形 CIDR 字符串被跳过 (不崩), 只扫合法网段."""
        vpn_immune = _StubVpnImmune(["not-a-cidr", "192.168.1.0/30"])
        urlopen = make_urlopen({"192.168.1.1": HELLO_BODY_LEGACY})
        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)

        candidates = scanner.scan()

        # 畸形 cidr 跳过, 合法网段照常扫
        assert len(candidates) == 1
        assert candidates[0].host == "192.168.1.1"

    def test_duplicate_hosts_across_cidrs_deduped(self) -> None:
        """两个相同网段 (重复输入) → host 去重, 只扫一次每个 IP."""
        vpn_immune = _StubVpnImmune(["192.168.1.0/30", "192.168.1.0/30"])
        probe_calls: list[str] = []

        def urlopen(request, timeout):  # noqa: ANN001
            url = request.full_url
            for host in ("192.168.1.1", "192.168.1.2"):
                if f"//{host}:" in url:
                    probe_calls.append(host)
                    return _FakeResponse(HELLO_BODY_LEGACY)
            raise OSError("unexpected")

        scanner = LanScan(vpn_immune, urlopen=urlopen, probe_timeout=0.5)
        candidates = scanner.scan()

        # 两个 host 各被探测 1 次 (去重生效, 不是 4 次)
        assert sorted(c.host for c in candidates) == ["192.168.1.1", "192.168.1.2"]
        # 每个 host 只被 probe 1 次 (去重 — 如果不去重 /30 × 2 = 4 calls)
        assert len(probe_calls) == 2


# ===========================================================================
# 真实 VpnImmune 注入 (集成契约, 不调系统命令)
# ===========================================================================


class TestLanScanVpnImmuneInjection:
    """LanScan 接受真实 VpnImmune (BF003), 但本测试用 stub 验证集成契约."""

    def test_accepts_real_vpn_immune_instance(self) -> None:
        """LanScan 接受真实 VpnImmune 实例 (类型契约, 不实际调系统命令)."""
        # 构造真实 VpnImmune 但注入失败的 runner (不依赖系统状态)
        def failing_runner(command, timeout):  # noqa: ANN001
            raise OSError("test isolation")

        vpn_immune = VpnImmune(run_command=failing_runner)
        scanner = LanScan(
            vpn_immune, urlopen=make_urlopen(OSError("no probe")), probe_timeout=0.5
        )
        # scan 不崩 (vpn_immune fallback 返可能空的 list, urlopen 全失败)
        candidates = scanner.scan()
        assert isinstance(candidates, list)


# ===========================================================================
# LanCandidate dataclass 契约
# ===========================================================================


class TestLanCandidateDataclass:
    """LanCandidate dataclass 字段契约 (host/port/network_target)."""

    def test_lan_candidate_fields(self) -> None:
        """LanCandidate 携带 host + port + network_target."""
        from debug_control_plane.device_discovery.protocol import NetworkTarget

        target = NetworkTarget.from_hello(
            {
                "deviceId": "dev-1",
                "deviceName": "Pixel",
                "platform": "android",
                "capabilities": [],
            },
            host="10.0.0.5",
            port=18080,
        )
        cand = LanCandidate(host="10.0.0.5", port=18080, network_target=target)

        assert cand.host == "10.0.0.5"
        assert cand.port == 18080
        assert cand.network_target is target
        assert cand.network_target.device_id == "dev-1"


# ===========================================================================
# NetworkTarget.from_hello R020 扩展字段 (方案 A 向后兼容)
# ===========================================================================


class TestNetworkTargetR020Fields:
    """方案 A: from_hello 解析 hardwareName/machineId/registeredCapabilities,
    老 /hello (无新字段) 向后兼容 (None 默认)."""

    def test_from_hello_parses_r020_fields(self) -> None:
        """新版 /hello (含 hardwareName/machineId/registeredCapabilities) → 解析."""
        from debug_control_plane.device_discovery.protocol import NetworkTarget

        data = {
            "deviceId": "dev",
            "hardwareName": "iPhone X",
            "machineId": "iPhone10,3",
            "registeredCapabilities": [
                {"id": "gamepad", "resources": [], "commands": []},
            ],
        }
        target = NetworkTarget.from_hello(data, host="1.2.3.4", port=18080)

        assert target.hardware_name == "iPhone X"
        assert target.machine_id == "iPhone10,3"
        assert target.registered_capabilities is not None
        assert target.registered_capabilities[0]["id"] == "gamepad"

    def test_from_hello_legacy_without_r020_fields(self) -> None:
        """老版 /hello (无 R020 字段) → 3 个新字段默认 None (向后兼容)."""
        from debug_control_plane.device_discovery.protocol import NetworkTarget

        target = NetworkTarget.from_hello(
            {"deviceId": "dev", "deviceName": "X", "capabilities": []},
            host="1.2.3.4",
            port=18080,
        )

        assert target.hardware_name is None
        assert target.machine_id is None
        assert target.registered_capabilities is None
        # 既有字段不受影响
        assert target.device_id == "dev"
        assert target.device_name == "X"

    def test_from_hello_registered_capabilities_empty_array(self) -> None:
        """registeredCapabilities 显式空数组 → 返空 tuple (非 None)."""
        from debug_control_plane.device_discovery.protocol import NetworkTarget

        target = NetworkTarget.from_hello(
            {"deviceId": "dev", "registeredCapabilities": []},
            host="1.2.3.4",
            port=18080,
        )

        assert target.registered_capabilities == ()

    def test_from_hello_registered_capabilities_filters_non_objects(self) -> None:
        """registeredCapabilities 含非 dict 项 → 过滤掉, 只留 dict."""
        from debug_control_plane.device_discovery.protocol import NetworkTarget

        target = NetworkTarget.from_hello(
            {
                "deviceId": "dev",
                "registeredCapabilities": [
                    {"id": "ok"},
                    "not-a-dict",
                    42,
                    {"id": "ok2"},
                ],
            },
            host="1.2.3.4",
            port=18080,
        )

        assert target.registered_capabilities is not None
        assert len(target.registered_capabilities) == 2
        ids = [item["id"] for item in target.registered_capabilities]
        assert ids == ["ok", "ok2"]

    def test_from_hello_registered_capabilities_wrong_type(self) -> None:
        """registeredCapabilities 非 list 类型 → 返 None (容错)."""
        from debug_control_plane.device_discovery.protocol import NetworkTarget

        target = NetworkTarget.from_hello(
            {"deviceId": "dev", "registeredCapabilities": "not-a-list"},
            host="1.2.3.4",
            port=18080,
        )

        assert target.registered_capabilities is None
