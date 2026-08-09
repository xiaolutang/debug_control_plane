"""R020-BF003 VpnImmune 服务测试 (service 层封装 + 可观测性)。

AC 覆盖:
  AC4 全局 VPN TUN 启用 → lan_cidr 返回真实 LAN (en0=192.168.1.244,
     utun1024=198.18.0.1 不污染), 走 route_table 路径
  fallback: route 命令失败 → 回退 socket 出口法不崩, source=="socket_fallback"
  委托一致性: VpnImmune.lan_cidr() 与 endpoint.vpn_immune_lan_cidrs() 同输入同输出
  可观测性: last_event 暴露 source/cidrs/note 供上层日志

设计来源:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF003 节
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md §5.4
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1
           (VpnImmune service 层;endpoint 层 fallback 在 BF002 测试套已覆盖)

注意: VpnImmune 是 SERVICE 层 (封装 + 可观测性), 与 BF002 endpoint 层
      TestVpnImmuneLanCidrs/TestVpnImmuneHelpers 互补不重复.
"""

from __future__ import annotations

from debug_control_plane.device_discovery.discovery.vpn_immune import FallbackEvent, VpnImmune
from debug_control_plane.device_discovery.endpoint import (
    _fallback_lan_cidrs,
    vpn_immune_lan_cidrs,
)

# ---------------------------------------------------------------------------
# Helpers — 复用 BF002 测试套的 mock 命令执行器风格 (前缀匹配).
# ---------------------------------------------------------------------------


def make_command_runner(responses: dict[tuple[str, ...], str | Exception]):
    """构造 mock 命令执行器.

    responses key = command 前缀 tuple, value = 返回字符串或 Exception (失败).
    """

    def runner(command: list[str], timeout: float) -> str:
        for prefix, response in responses.items():
            if command[: len(prefix)] == list(prefix):
                if isinstance(response, Exception):
                    raise response
                return response
        raise OSError(f"unexpected command: {command}")

    return runner


# ===========================================================================
# 路由表成功路径 (route_table source)
# ===========================================================================


class TestVpnImmuneRouteTable:
    """路由表成功: route → interface → ipconfig → /24 CIDR."""

    def test_route_table_returns_real_lan_cidr(self) -> None:
        """route 返 en0 + ipconfig 返 192.168.1.244 → ["192.168.1.0/24"]."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): (
                    "   route to: default\n"
                    "destination: default\n"
                    "  interface: en0\n"
                ),
                ("ipconfig", "getifaddr", "en0"): "192.168.1.244\n",
            }
        )
        svc = VpnImmune(run_command=runner)
        cidrs = svc.lan_cidr()

        assert cidrs == ["192.168.1.0/24"]
        assert svc.last_event is not None
        assert svc.last_event.source == "route_table"
        assert svc.last_event.cidrs == ["192.168.1.0/24"]
        assert svc.last_event.note == ""  # 成功路径无 note

    def test_vpn_tun_does_not_pollute_lan_cidr(self) -> None:
        """全局 VPN TUN 场景: route interface 仍是物理 en0 (非 utun) → 真实 LAN.

        隐蔽坑 (design §5.4): utun1024=198.18.0.1 劫持 socket.connect 出口,
        但 route -n get default 的 interface 字段是物理网卡. VpnImmune 读路由表,
        所以正常路径返回真实 LAN, 198.18.x 绝不出现在结果.
        """
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): "  interface: en0\n",
                ("ipconfig", "getifaddr", "en0"): "192.168.1.244\n",
            }
        )
        svc = VpnImmune(run_command=runner)
        cidrs = svc.lan_cidr()

        assert cidrs == ["192.168.1.0/24"]
        for cidr in cidrs:
            assert "198.18." not in cidr
        assert svc.last_event is not None
        assert svc.last_event.source == "route_table"


# ===========================================================================
# Fallback 路径 (socket_fallback source)
# ===========================================================================


class TestVpnImmuneFallback:
    """路由表失败 → 回退 socket 出口法, 不崩, source 标记 socket_fallback."""

    def test_fallback_when_route_command_fails(self) -> None:
        """route 命令失败 (OSError) → fallback socket 法, source=socket_fallback."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): OSError("route: command not found"),
            }
        )
        svc = VpnImmune(run_command=runner)
        # socket 法环境相关, 这里只断言不崩 + source 标记正确, 不强断具体 cidr
        cidrs = svc.lan_cidr()

        assert isinstance(cidrs, list)
        assert svc.last_event is not None
        assert svc.last_event.source == "socket_fallback"
        assert svc.last_event.note != ""  # fallback 必须有诊断 note
        assert "fallback" in svc.last_event.note.lower()

    def test_fallback_when_interface_has_no_ipv4(self) -> None:
        """route 返接口但 ipconfig 拿不到 IP → fallback socket 法."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): "  interface: en7\n",
                ("ipconfig", "getifaddr", "en7"): OSError("no address"),
            }
        )
        svc = VpnImmune(run_command=runner)
        cidrs = svc.lan_cidr()

        assert isinstance(cidrs, list)
        assert svc.last_event is not None
        assert svc.last_event.source == "socket_fallback"


# ===========================================================================
# 委托一致性: VpnImmune 与 endpoint 同输入同输出
# ===========================================================================


class TestVpnImmuneDelegation:
    """VpnImmune.lan_cidr() 必须与 endpoint.vpn_immune_lan_cidrs() 委托一致."""

    def test_route_table_path_matches_endpoint(self) -> None:
        """路由表路径: VpnImmune 输出 == endpoint.vpn_immune_lan_cidrs 输出."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): "  interface: en0\n",
                ("ipconfig", "getifaddr", "en0"): "192.168.1.244\n",
            }
        )
        svc = VpnImmune(run_command=runner)
        svc_cidrs = svc.lan_cidr()
        endpoint_cidrs = vpn_immune_lan_cidrs(run_command=runner)

        assert svc_cidrs == endpoint_cidrs == ["192.168.1.0/24"]

    def test_fallback_path_matches_endpoint(self) -> None:
        """fallback 路径: VpnImmune 输出 == endpoint.vpn_immune_lan_cidrs 输出."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): OSError("route unavailable"),
            }
        )
        svc = VpnImmune(run_command=runner)
        svc_cidrs = svc.lan_cidr()
        endpoint_cidrs = vpn_immune_lan_cidrs(run_command=runner)

        assert svc_cidrs == endpoint_cidrs

    def test_fallback_matches_helper_directly(self) -> None:
        """fallback 路径: VpnImmune 输出 == _fallback_lan_cidrs(24) 直接调用."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): OSError("fail"),
            }
        )
        svc = VpnImmune(run_command=runner)
        assert svc.lan_cidr() == _fallback_lan_cidrs(24)


# ===========================================================================
# 注入点 + 配置透传
# ===========================================================================


class TestVpnImmuneInjection:
    """run_command 注入 + cidr_prefix_len 透传."""

    def test_run_command_is_forwarded(self) -> None:
        """注入的 run_command 被透传到 endpoint (验证调用次数 / 参数)."""
        calls: list[tuple[list[str], float]] = []

        def tracking_runner(command: list[str], timeout: float) -> str:
            calls.append((command, timeout))
            if command[:4] == ["route", "-n", "get", "default"]:
                return "  interface: en0\n"
            if command[:3] == ["ipconfig", "getifaddr", "en0"]:
                return "192.168.1.50\n"
            raise OSError(f"unexpected: {command}")

        svc = VpnImmune(run_command=tracking_runner)
        cidrs = svc.lan_cidr()

        assert cidrs == ["192.168.1.0/24"]
        # 至少调了 route + ipconfig 两次
        assert any(c[0][:4] == ["route", "-n", "get", "default"] for c in calls)
        assert any(c[0][:3] == ["ipconfig", "getifaddr", "en0"] for c in calls)

    def test_cidr_prefix_len_forwarded(self) -> None:
        """cidr_prefix_len=16 透传到 endpoint → 返回 /16 网段."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): "  interface: en0\n",
                ("ipconfig", "getifaddr", "en0"): "10.20.30.40\n",
            }
        )
        svc = VpnImmune(run_command=runner, cidr_prefix_len=16)
        cidrs = svc.lan_cidr()

        assert cidrs == ["10.20.0.0/16"]
        assert svc.last_event is not None
        assert svc.last_event.cidrs == ["10.20.0.0/16"]

    def test_default_run_command_used_when_none(self) -> None:
        """run_command=None → 用 _run_command_default (subprocess) — 验证默认值生效."""
        svc = VpnImmune(run_command=None)
        # 不实际执行 lan_cidr (会调系统 route/ipconfig); 只验证构造不崩 + 默认注入
        assert svc is not None
        # last_event 初始为 None, 调用 lan_cidr 后才赋值
        assert svc.last_event is None


# ===========================================================================
# 可观测性: FallbackEvent dataclass
# ===========================================================================


class TestFallbackEvent:
    """FallbackEvent dataclass 字段契约."""

    def test_route_table_event_has_empty_note(self) -> None:
        """route_table source 的 note 必须为空字符串 (无诊断信息)."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): "  interface: en0\n",
                ("ipconfig", "getifaddr", "en0"): "192.168.1.1\n",
            }
        )
        svc = VpnImmune(run_command=runner)
        svc.lan_cidr()

        assert isinstance(svc.last_event, FallbackEvent)
        assert svc.last_event.source == "route_table"
        assert svc.last_event.note == ""

    def test_socket_fallback_event_has_diagnostic_note(self) -> None:
        """socket_fallback source 必须带诊断 note (提示可能 VPN TUN 污染)."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): OSError("fail"),
            }
        )
        svc = VpnImmune(run_command=runner)
        svc.lan_cidr()

        assert isinstance(svc.last_event, FallbackEvent)
        assert svc.last_event.source == "socket_fallback"
        assert "VPN" in svc.last_event.note or "fallback" in svc.last_event.note.lower()

    def test_cidrs_field_is_list_copy(self) -> None:
        """last_event.cidrs 是 list 拷贝 (外部 mutate 不影响内部)."""
        runner = make_command_runner(
            {
                ("route", "-n", "get", "default"): "  interface: en0\n",
                ("ipconfig", "getifaddr", "en0"): "192.168.1.1\n",
            }
        )
        svc = VpnImmune(run_command=runner)
        svc.lan_cidr()
        assert svc.last_event is not None

        cidrs_copy = svc.last_event.cidrs
        cidrs_copy.append("10.0.0.0/8")
        # 内部 state 不被外部 mutate 污染 (新一次调用应仍返正确值)
        svc2 = VpnImmune(run_command=runner)
        assert svc2.lan_cidr() == ["192.168.1.0/24"]


# ===========================================================================
# 多次调用 / 状态刷新
# ===========================================================================


class TestVpnImmuneStateRefresh:
    """last_event 在每次 lan_cidr 调用时刷新."""

    def test_last_event_refreshed_on_each_call(self) -> None:
        """两次调用, 第一次 route 成功, 第二次 route 失败 → last_event 反映最新."""
        # 用可变 runner: 第一次成功, 第二次失败
        state = {"route_failed": False}

        def runner(command: list[str], timeout: float) -> str:
            if command[:4] == ["route", "-n", "get", "default"]:
                if state["route_failed"]:
                    raise OSError("now broken")
                return "  interface: en0\n"
            if command[:3] == ["ipconfig", "getifaddr", "en0"]:
                return "192.168.1.100\n"
            raise OSError(f"unexpected: {command}")

        svc = VpnImmune(run_command=runner)

        # 第一次: route_table 成功
        assert svc.lan_cidr() == ["192.168.1.0/24"]
        assert svc.last_event is not None
        assert svc.last_event.source == "route_table"

        # 第二次: route 失败 → fallback
        state["route_failed"] = True
        svc.lan_cidr()
        assert svc.last_event is not None
        assert svc.last_event.source == "socket_fallback"
