"""R020-BF004 UsbIdentity 服务测试 (USB 身份源, Android adb / iOS flutter 分端).

AC 覆盖:
  AC2 Android: mock ``adb devices -l`` → 解析 serial + model + LAN IP
     (经 mock ``adb shell ip route get`` 拿精确 LAN IP)
  AC3 iOS:     mock ``flutter devices --machine`` → 解析 usbmuxd id + 机型;
               **不调 xcrun devicectl** (memory ios16-device-devicectl-pitfall,
               关键断言: run_command 调用列表无 ``devicectl``)
  android_lan_ip 字段: Android 精确拿 (``adb shell ip route``),
                       iOS 恒 None (USB 仅身份, LAN IP 由 BF005 在 LAN 侧发现)
  异常容忍:    adb/flutter 命令超时/失败 → [] 不抛
  USB 仅身份:  不调 ``adb forward`` / ``iproxy`` (BF004.3, 关键断言)

设计来源:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF004 节
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
            §3.4 UsbIdentity + D9 device_id 来源
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1
           (UsbIdentity Android / UsbIdentity iOS flutter 重建)

注意: UsbIdentity 是 SERVICE 层 (身份采集 + UsbCandidate 包装), 复用
      device_candidates 的解析函数 (_android_device_ip / discover_ios_flutter_candidates,
      D8 零重写); adb devices -l 的 serial+model 解析由 BF004 自行做
      (device_candidates._android_connected_devices 暴露的 ConnectedDeviceEndpoint
      丢失 serial, BF004 device_id=serial 需保留).
"""

from __future__ import annotations

from debug_control_plane.device_discovery.discovery.usb_identity import UsbCandidate, UsbIdentity

# ---------------------------------------------------------------------------
# Mock helpers — 命令执行器按 command 前缀 tuple 返预设输出 / 抛 Exception.
# 风格与 BF003 test_discovery_vpn_immune.py + BF002 test_network_r020_bf002.py 一致.
# ---------------------------------------------------------------------------


def make_command_runner(responses: dict[tuple[str, ...], str | Exception]):
    """构造 mock 命令执行器.

    responses key = command 前缀 tuple, value = 返回字符串或 Exception (失败).
    命令前缀匹配即返回; 无匹配抛 OSError (暴露意外调用, 测试 fail fast).

    同时记录所有调用到 ``calls`` 属性, 供测试断言 ``devicectl`` / ``adb forward``
    等关键约束 (AC3 iOS 不调 devicectl / BF004.3 不做数据通道).
    """

    calls: list[list[str]] = []

    def runner(command: list[str], timeout: float) -> str:
        calls.append(list(command))
        for prefix, response in responses.items():
            if command[: len(prefix)] == list(prefix):
                if isinstance(response, Exception):
                    raise response
                return response
        raise OSError(f"unexpected command: {command}")

    runner.calls = calls  # type: ignore[attr-defined]
    return runner


# ---------------------------------------------------------------------------
# Fixtures — adb devices -l / adb shell ip route / flutter devices --machine 真实输出.
# ---------------------------------------------------------------------------


#: ``adb devices -l`` 单设备输出 (serial=R58M1234567, model=SM-G991B).
ADB_DEVICES_SINGLE = (
    "List of devices attached\n"
    "R58M1234567     device usb:1-1 product:sm-g991 model:SM-G991B device:o1s\n"
    "\n"
)

#: ``adb devices -l`` 多设备输出.
ADB_DEVICES_MULTI = (
    "List of devices attached\n"
    "R58M1234567     device usb:1-1 product:sm-g991 model:SM-G991B device:o1s\n"
    "emulator-5554   device product:sdk_gphone64 model:sdk_gphone64_x86_64 device:emu64x\n"
    "ABCDEF012345    device usb:2-2 product:crosshatch model:Pixel 3 device:crosshatch\n"
    "\n"
)

#: ``adb devices -l`` 含非 device 状态 (offline / unauthorized) 的输出.
ADB_DEVICES_WITH_NON_DEVICE = (
    "List of devices attached\n"
    "R58M1234567     device usb:1-1 product:sm-g991 model:SM-G991B device:o1s\n"
    "OFFLINE001      offline usb:1-2\n"
    "UNAUTH002       unauthorized usb:1-3\n"
    "\n"
)

#: ``adb devices -l`` 无设备输出.
ADB_DEVICES_EMPTY = "List of devices attached\n\n"

#: ``adb shell ip route get 1.1.1.1`` 成功输出 (src=192.168.1.55).
ADB_IP_ROUTE_SERIAL_1 = (
    "1.1.1.1 via 192.168.1.1 dev wlan0  src 192.168.1.55\n" "    cache\n"
)
ADB_IP_ROUTE_SERIAL_2 = (
    "1.1.1.1 via 192.168.1.1 dev wlan0  src 192.168.1.66\n" "    cache\n"
)
ADB_IP_ROUTE_EMULATOR = (
    "1.1.1.1 via 10.0.2.2 dev eth0  src 10.0.2.15\n" "    cache\n"
)

#: ``flutter devices --machine`` 真机输出 (单 iPhone X, usbmuxd id=3992f440...).
FLUTTER_DEVICES_MACHINE_IPHONE = """[
  {"id":"3992f440f538798c0d49a6efb883cc4bd55df501","name":"iPhone X",
   "targetPlatform":"ios","emulator":false,"category":"mobile","platform":"ios"}
]"""

#: ``flutter devices --machine`` 含 simulator 的输出 (BF002 已排除 simulator).
FLUTTER_DEVICES_MACHINE_WITH_SIMULATOR = """[
  {"id":"3992f440f538798c0d49a6efb883cc4bd55df501","name":"iPhone X",
   "targetPlatform":"ios","emulator":false,"category":"mobile","platform":"ios"},
  {"id":"sim-abc123","name":"iPhone 14 Pro Simulator",
   "targetPlatform":"ios","emulator":true,"category":"web","platform":"ios"}
]"""

#: ``flutter devices --machine`` 无 iOS 真机输出 (仅 android-emulator).
FLUTTER_DEVICES_MACHINE_NO_IOS = """[
  {"id":"emulator-5554","name":"sdk gphone64 x86 64",
   "targetPlatform":"android-x64","emulator":true,"category":"mobile"}
]"""


# ===========================================================================
# AC2: Android USB 身份源 (adb devices -l + adb shell ip route)
# ===========================================================================


class TestAndroidUsbIdentity:
    """AC2 Android: adb devices -l → serial + model + LAN IP."""

    def test_single_device_parses_serial_model_and_lan_ip(self) -> None:
        """单设备: serial=R58M1234567, model=SM-G991B, lan_ip=192.168.1.55."""
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): ADB_DEVICES_SINGLE,
                ("adb", "-s", "R58M1234567", "shell", "ip", "route", "get", "1.1.1.1"): (
                    ADB_IP_ROUTE_SERIAL_1
                ),
            }
        )
        svc = UsbIdentity(run_command=runner)
        candidates = svc.android()

        assert len(candidates) == 1
        cand = candidates[0]
        assert cand.device_id == "R58M1234567"
        assert cand.model == "SM-G991B"
        assert cand.platform == "android"
        assert cand.android_lan_ip == "192.168.1.55"

    def test_multiple_devices_each_gets_own_lan_ip(self) -> None:
        """多设备: 每台设备各自调 adb shell ip route 拿独立 LAN IP."""
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): ADB_DEVICES_MULTI,
                ("adb", "-s", "R58M1234567", "shell", "ip", "route", "get", "1.1.1.1"): (
                    ADB_IP_ROUTE_SERIAL_1
                ),
                ("adb", "-s", "emulator-5554", "shell", "ip", "route", "get", "1.1.1.1"): (
                    ADB_IP_ROUTE_EMULATOR
                ),
                ("adb", "-s", "ABCDEF012345", "shell", "ip", "route", "get", "1.1.1.1"): (
                    ADB_IP_ROUTE_SERIAL_2
                ),
            }
        )
        svc = UsbIdentity(run_command=runner)
        candidates = svc.android()

        assert len(candidates) == 3
        # 顺序保持 (R58M, emulator, ABCDEF)
        assert candidates[0].device_id == "R58M1234567"
        assert candidates[0].android_lan_ip == "192.168.1.55"
        assert candidates[1].device_id == "emulator-5554"
        assert candidates[1].android_lan_ip == "10.0.2.15"
        assert candidates[2].device_id == "ABCDEF012345"
        assert candidates[2].android_lan_ip == "192.168.1.66"

    def test_non_device_states_skipped(self) -> None:
        """offline/unauthorized 状态行跳过, 只取 device 状态."""
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): ADB_DEVICES_WITH_NON_DEVICE,
                ("adb", "-s", "R58M1234567", "shell", "ip", "route", "get", "1.1.1.1"): (
                    ADB_IP_ROUTE_SERIAL_1
                ),
            }
        )
        svc = UsbIdentity(run_command=runner)
        candidates = svc.android()

        assert len(candidates) == 1
        assert candidates[0].device_id == "R58M1234567"

    def test_no_devices_returns_empty(self) -> None:
        """无设备 → []."""
        runner = make_command_runner({("adb", "devices", "-l"): ADB_DEVICES_EMPTY})
        svc = UsbIdentity(run_command=runner)
        assert svc.android() == []

    def test_adb_unavailable_returns_empty(self) -> None:
        """adb 命令不存在 / 失败 → [] 不抛."""
        runner = make_command_runner(
            {("adb", "devices", "-l"): OSError("adb: command not found")}
        )
        svc = UsbIdentity(run_command=runner)
        assert svc.android() == []

    def test_device_without_lan_ip_skipped(self) -> None:
        """adb shell ip route 失败 (拿不到 LAN IP) → 该设备跳过.

        与 device_candidates._android_connected_devices 一致: 没有可用 LAN IP
        的 Android 设备对 BF006 交叉识别无意义 (USB 身份在但无 LAN 锚点).
        """
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): ADB_DEVICES_SINGLE,
                ("adb", "-s", "R58M1234567", "shell", "ip", "route", "get", "1.1.1.1"): (
                    OSError("device offline")
                ),
            }
        )
        svc = UsbIdentity(run_command=runner)
        assert svc.android() == []

    def test_model_missing_falls_back_to_serial(self) -> None:
        """adb 输出行缺 model: 字段 → model 回退 serial (与 device_candidates 一致)."""
        no_model_output = (
            "List of devices attached\n"
            "R58M1234567     device usb:1-1\n"
            "\n"
        )
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): no_model_output,
                ("adb", "-s", "R58M1234567", "shell", "ip", "route", "get", "1.1.1.1"): (
                    ADB_IP_ROUTE_SERIAL_1
                ),
            }
        )
        svc = UsbIdentity(run_command=runner)
        candidates = svc.android()

        assert len(candidates) == 1
        assert candidates[0].device_id == "R58M1234567"
        assert candidates[0].model == "R58M1234567"  # 回退 serial

    def test_no_data_channel_forward_or_iproxy(self) -> None:
        """BF004.3 USB 仅身份不做数据通道: 调用列表无 adb forward / iproxy."""
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): ADB_DEVICES_SINGLE,
                ("adb", "-s", "R58M1234567", "shell", "ip", "route", "get", "1.1.1.1"): (
                    ADB_IP_ROUTE_SERIAL_1
                ),
            }
        )
        svc = UsbIdentity(run_command=runner)
        svc.android()

        flat = " ".join(" ".join(c) for c in runner.calls)
        assert "forward" not in flat  # 不做 adb forward
        assert "iproxy" not in flat   # 不做 iproxy


# ===========================================================================
# AC3: iOS USB 身份源 (flutter devices --machine, 绝不调 devicectl)
# ===========================================================================


class TestIosUsbIdentity:
    """AC3 iOS: flutter devices --machine → usbmuxd id + 机型, 不调 devicectl."""

    def test_single_iphone_parses_usbmuxd_id_and_model(self) -> None:
        """单 iPhone X: device_id=usbmuxd id, model=iPhone X, lan_ip=None."""
        runner = make_command_runner(
            {("flutter", "devices", "--machine"): FLUTTER_DEVICES_MACHINE_IPHONE}
        )
        svc = UsbIdentity(run_command=runner)
        candidates = svc.ios()

        assert len(candidates) == 1
        cand = candidates[0]
        assert cand.device_id == "3992f440f538798c0d49a6efb883cc4bd55df501"
        assert cand.model == "iPhone X"
        assert cand.platform == "ios"
        assert cand.android_lan_ip is None  # iOS LAN IP 由 BF005 在 LAN 侧发现

    def test_simulator_excluded(self) -> None:
        """flutter 输出含 simulator → 只取真机 (BF002.2 已排除 simulator)."""
        runner = make_command_runner(
            {("flutter", "devices", "--machine"): FLUTTER_DEVICES_MACHINE_WITH_SIMULATOR}
        )
        svc = UsbIdentity(run_command=runner)
        candidates = svc.ios()

        assert len(candidates) == 1
        assert candidates[0].device_id == "3992f440f538798c0d49a6efb883cc4bd55df501"
        assert "Simulator" not in candidates[0].model

    def test_no_ios_device_returns_empty(self) -> None:
        """flutter 输出仅 android-emulator, 无 iOS 真机 → []."""
        runner = make_command_runner(
            {("flutter", "devices", "--machine"): FLUTTER_DEVICES_MACHINE_NO_IOS}
        )
        svc = UsbIdentity(run_command=runner)
        assert svc.ios() == []

    def test_flutter_unavailable_returns_empty(self) -> None:
        """flutter 命令不存在 (所有候选命令都失败) → [] 不抛.

        device_candidates._try_flutter_devices_machine 内部尝试多个候选
        (flutter / /usr/local/bin/flutter / /opt/homebrew/bin/flutter / fvm),
        全失败返 None → discover_ios_flutter_candidates 返 [].
        """
        runner = make_command_runner(
            {
                ("flutter", "devices", "--machine"): OSError("command not found"),
                ("/usr/local/bin/flutter", "devices", "--machine"): OSError("not found"),
                ("/opt/homebrew/bin/flutter", "devices", "--machine"): OSError("not found"),
                ("fvm", "devices", "--machine"): OSError("not found"),
            }
        )
        svc = UsbIdentity(run_command=runner)
        assert svc.ios() == []

    def test_invalid_flutter_output_returns_empty(self) -> None:
        """flutter 输出非 JSON → [] 不抛."""
        runner = make_command_runner(
            {("flutter", "devices", "--machine"): "not json"}
        )
        svc = UsbIdentity(run_command=runner)
        assert svc.ios() == []

    def test_never_calls_devicectl(self) -> None:
        """关键 AC3: run_command 调用列表绝无 xcrun devicectl.

        memory ios16-device-devicectl-pitfall: iPhone X iOS 16, xcrun devicectl
        永远 unavailable. BF004 iOS 路径只走 flutter devices --machine (BF002.2
        discover_ios_flutter_candidates), 绝不调 devicectl.
        """
        runner = make_command_runner(
            {("flutter", "devices", "--machine"): FLUTTER_DEVICES_MACHINE_IPHONE}
        )
        svc = UsbIdentity(run_command=runner)
        svc.ios()

        flat = " ".join(" ".join(c) for c in runner.calls)
        assert "devicectl" not in flat
        assert "xcrun" not in flat
        # 确认走了 flutter 路径
        assert "flutter devices --machine" in flat

    def test_ios_does_not_call_adb(self) -> None:
        """iOS 路径不调 adb (与 android 路径隔离)."""
        runner = make_command_runner(
            {("flutter", "devices", "--machine"): FLUTTER_DEVICES_MACHINE_IPHONE}
        )
        svc = UsbIdentity(run_command=runner)
        svc.ios()

        flat = " ".join(" ".join(c) for c in runner.calls)
        assert "adb" not in flat


# ===========================================================================
# all_candidates: Android + iOS 合并
# ===========================================================================


class TestAllCandidates:
    """all_candidates() 合并 android() + ios(), android 在前."""

    def test_merges_android_and_ios(self) -> None:
        """android 1 台 + iOS 1 台 → 2 candidates (android 在前)."""
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): ADB_DEVICES_SINGLE,
                ("adb", "-s", "R58M1234567", "shell", "ip", "route", "get", "1.1.1.1"): (
                    ADB_IP_ROUTE_SERIAL_1
                ),
                ("flutter", "devices", "--machine"): FLUTTER_DEVICES_MACHINE_IPHONE,
            }
        )
        svc = UsbIdentity(run_command=runner)
        candidates = svc.all_candidates()

        assert len(candidates) == 2
        assert candidates[0].platform == "android"
        assert candidates[0].device_id == "R58M1234567"
        assert candidates[1].platform == "ios"
        assert candidates[1].device_id == "3992f440f538798c0d49a6efb883cc4bd55df501"

    def test_only_android_returns_just_android(self) -> None:
        """android 1 台 + iOS 0 → 仅 android."""
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): ADB_DEVICES_SINGLE,
                ("adb", "-s", "R58M1234567", "shell", "ip", "route", "get", "1.1.1.1"): (
                    ADB_IP_ROUTE_SERIAL_1
                ),
                ("flutter", "devices", "--machine"): FLUTTER_DEVICES_MACHINE_NO_IOS,
            }
        )
        svc = UsbIdentity(run_command=runner)
        candidates = svc.all_candidates()

        assert len(candidates) == 1
        assert candidates[0].platform == "android"

    def test_only_ios_returns_just_ios(self) -> None:
        """android 0 + iOS 1 → 仅 ios."""
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): ADB_DEVICES_EMPTY,
                ("flutter", "devices", "--machine"): FLUTTER_DEVICES_MACHINE_IPHONE,
            }
        )
        svc = UsbIdentity(run_command=runner)
        candidates = svc.all_candidates()

        assert len(candidates) == 1
        assert candidates[0].platform == "ios"

    def test_both_unavailable_returns_empty(self) -> None:
        """adb + flutter 都不可用 → []."""
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): OSError("not found"),
                ("flutter", "devices", "--machine"): OSError("not found"),
                ("/usr/local/bin/flutter", "devices", "--machine"): OSError("not found"),
                ("/opt/homebrew/bin/flutter", "devices", "--machine"): OSError("not found"),
                ("fvm", "devices", "--machine"): OSError("not found"),
            }
        )
        svc = UsbIdentity(run_command=runner)
        assert svc.all_candidates() == []


# ===========================================================================
# UsbCandidate dataclass 字段完整性
# ===========================================================================


class TestUsbCandidateDataclass:
    """UsbCandidate 字段完整性 (BF004.2)."""

    def test_android_candidate_default_lan_ip_none(self) -> None:
        """android_lan_ip 默认 None (dataclass field 默认值)."""
        cand = UsbCandidate(device_id="serial", model="model", platform="android")
        assert cand.android_lan_ip is None

    def test_ios_candidate_lan_ip_always_none(self) -> None:
        """iOS candidate 的 android_lan_ip 恒 None (语义: iOS 不在 USB 侧拿 LAN IP)."""
        cand = UsbCandidate(
            device_id="usbmuxd-id", model="iPhone X", platform="ios"
        )
        assert cand.android_lan_ip is None

    def test_frozen_dataclass_immutable(self) -> None:
        """UsbCandidate 是 frozen dataclass (不可变, 防 BF006 误改)."""
        cand = UsbCandidate(
            device_id="serial", model="model", platform="android", android_lan_ip="1.2.3.4"
        )
        try:
            cand.device_id = "other"  # type: ignore[misc]
        except AttributeError:
            return
        raise AssertionError("UsbCandidate should be frozen (immutable)")

    def test_all_fields_accessible(self) -> None:
        """四个字段都可读."""
        cand = UsbCandidate(
            device_id="R58M1234567",
            model="SM-G991B",
            platform="android",
            android_lan_ip="192.168.1.55",
        )
        assert cand.device_id == "R58M1234567"
        assert cand.model == "SM-G991B"
        assert cand.platform == "android"
        assert cand.android_lan_ip == "192.168.1.55"


# ===========================================================================
# 异常容忍: 命令超时 / 失败不抛
# ===========================================================================


class TestExceptionTolerance:
    """adb/flutter 命令超时 / 失败 → [] 不抛 (与 BF003/BF005/device_candidates 同模式)."""

    def test_adb_timeout_returns_empty(self) -> None:
        """adb devices 超时 (subprocess.TimeoutExpired 被 _run_command 转 OSError).

        测试注入 OSError (device_candidates._run_command 内部把
        subprocess.TimeoutExpired 的 stdout 返回, 但 returncode != 0 时抛 OSError;
        实际超时且无 stdout 时也走 OSError 路径).
        """

        def runner(command: list[str], timeout: float) -> str:
            raise OSError("timeout")

        svc = UsbIdentity(run_command=runner)
        assert svc.android() == []
