"""device_candidates.py 单元测试 (iOS flutter 解析 + Android adb 解析).

AC 覆盖:
  iOS: _parse_flutter_devices_machine / discover_ios_flutter_candidates
  Android: discover_connected_devices / _android_connected_devices
  新增: IosDeviceCandidate dataclass 契约 + _ios_inventory_devices 旧路径兼容

迁移来源:
  - 业务侧 test_network_r020_bf002.py
    TestIosFlutterDevices (12 tests) + TestAndroidUsbIdentity (2 tests)

设计来源:
  - .dev-flow/R021/analysis/2026-08-09--test-ownership-fix-design.md §4.1
"""
from __future__ import annotations

# ===========================================================================
# Imports
# ===========================================================================
from debug_control_plane.device_discovery.device_candidates import (
    IosDeviceCandidate,
    _ios_inventory_devices,
    _parse_flutter_devices_machine,
    discover_connected_devices,
    discover_ios_flutter_candidates,
)

# ---------------------------------------------------------------------------
# Helpers — 复用 debug_control_plane 测试惯例的 mock 命令执行器
# ---------------------------------------------------------------------------


def make_command_runner(responses: dict[tuple[str, ...], str | Exception]):
    """构造 mock 命令执行器。

    responses key = command 前缀 tuple, value = 返回字符串或 Exception (失败).
    命令前 N 项与 key 一致即命中 (避免硬编码 timeout 参数).
    """

    def runner(command: list[str], timeout: float) -> str:
        for prefix, response in responses.items():
            if command[: len(prefix)] == list(prefix):
                if isinstance(response, Exception):
                    raise response
                return response
        raise OSError(f"unexpected command: {command}")

    return runner


_FLUTTER_DEVICES_MACHINE_SAMPLE = """[
  {
    "name": "iPhone X",
    "id": "3992f440f538798c0d49a6efb883cc4bd55df501",
    "isConnected": true,
    "targetPlatform": "ios",
    "emulator": false,
    "category": "mobile",
    "platform": "ios",
    "platformType": "ios",
    "sdk": "iOS 16.7"
  },
  {
    "name": "iPhone 15 Pro",
    "id": "abcdef1234567890",
    "isConnected": true,
    "targetPlatform": "ios",
    "emulator": true,
    "category": "mobile",
    "platform": "ios"
  },
  {
    "name": "Pixel 7",
    "id": "emulator-5554",
    "isConnected": true,
    "targetPlatform": "android-x86",
    "emulator": true,
    "category": "mobile"
  },
  {
    "name": "macOS",
    "id": "macos",
    "isConnected": false,
    "targetPlatform": "darwin",
    "emulator": false,
    "category": "desktop"
  }
]"""


# ===========================================================================
# iOS flutter 解析 (迁移 TestIosFlutterDevices 12 tests)
# ===========================================================================


class TestIosFlutterDevices:
    """iOS flutter devices 解析: flutter devices --machine → IosDeviceCandidate.

    迁移自 test_network_r020_bf002.py::TestIosFlutterDevices.
    """

    def test_parse_extracts_ios_physical_device(self) -> None:
        """真机 iPhone X (emulator=false, ios) 被解析, emulator/simulator 排除。"""
        candidates = _parse_flutter_devices_machine(_FLUTTER_DEVICES_MACHINE_SAMPLE)
        # 排除 emulator (iPhone 15 Pro) / android (Pixel) / desktop (macOS)
        assert len(candidates) == 1
        iphone = candidates[0]
        assert isinstance(iphone, IosDeviceCandidate)
        assert iphone.device_id == "3992f440f538798c0d49a6efb883cc4bd55df501"
        assert iphone.model == "iPhone X"
        assert iphone.platform == "ios"

    def test_parse_excludes_simulator_category(self) -> None:
        """category 含 simulator 被排除 (防御性)。"""
        sample = """[
          {"name": "iPhone 14 Simulator", "id": "sim-id", "targetPlatform": "ios",
           "emulator": false, "category": "iOS Simulator", "platform": "ios"}
        ]"""
        candidates = _parse_flutter_devices_machine(sample)
        assert candidates == []

    def test_parse_excludes_android_and_desktop(self) -> None:
        """非 iOS platform (android/darwin) 被排除。"""
        sample = """[
          {"name": "Pixel", "id": "pixel-id", "targetPlatform": "android", "emulator": false},
          {"name": "macOS", "id": "macos", "targetPlatform": "darwin", "emulator": false}
        ]"""
        candidates = _parse_flutter_devices_machine(sample)
        assert candidates == []

    def test_parse_invalid_json_returns_empty(self) -> None:
        assert _parse_flutter_devices_machine("not json") == []
        assert _parse_flutter_devices_machine("") == []

    def test_parse_non_list_returns_empty(self) -> None:
        assert _parse_flutter_devices_machine('{"key": "value"}') == []

    def test_parse_missing_id_skipped(self) -> None:
        """缺 id 字段的条目被跳过。"""
        sample = """[
          {"name": "iPhone", "targetPlatform": "ios", "emulator": false, "category": "mobile"}
        ]"""
        candidates = _parse_flutter_devices_machine(sample)
        assert candidates == []

    def test_parse_non_string_id_skipped(self) -> None:
        """id 非 string 的条目被跳过 (防御)。"""
        sample = """[
          {"name": "iPhone", "id": 12345, "targetPlatform": "ios",
           "emulator": false, "category": "mobile"}
        ]"""
        candidates = _parse_flutter_devices_machine(sample)
        assert candidates == []

    def test_parse_missing_name_uses_id_as_model(self) -> None:
        """缺 name 字段时 model 回退到 device_id (防御)。"""
        sample = """[
          {"id": "abc123", "targetPlatform": "ios", "emulator": false, "category": "mobile"}
        ]"""
        candidates = _parse_flutter_devices_machine(sample)
        assert len(candidates) == 1
        assert candidates[0].device_id == "abc123"
        assert candidates[0].model == "abc123"

    def test_discover_candidates_uses_flutter_command(self) -> None:
        """discover_ios_flutter_candidates 调 flutter devices --machine, 不调 devicectl。

        关键断言: 绝不调 xcrun devicectl (memory ios16-device-devicectl-pitfall).
        """
        calls: list[list[str]] = []

        def runner(command: list[str], timeout: float) -> str:
            calls.append(command)
            if command[:3] == ["flutter", "devices", "--machine"]:
                return _FLUTTER_DEVICES_MACHINE_SAMPLE
            raise OSError(f"unexpected: {command}")

        candidates = discover_ios_flutter_candidates(run_command=runner)
        assert len(candidates) == 1
        assert candidates[0].device_id == "3992f440f538798c0d49a6efb883cc4bd55df501"
        # 关键: 绝不调 xcrun devicectl
        flat = " ".join(" ".join(c) for c in calls)
        assert "devicectl" not in flat
        assert "flutter devices --machine" in flat

    def test_discover_candidates_flutter_unavailable_falls_back_to_candidates(self) -> None:
        """flutter 不可用时, 尝试候选命令 (fvm/homebrew), 最终返回空列表。"""
        runner = make_command_runner(
            {
                ("flutter", "devices", "--machine"): OSError("flutter: command not found"),
                ("/usr/local/bin/flutter", "devices", "--machine"): OSError("not found"),
                ("/opt/homebrew/bin/flutter", "devices", "--machine"): OSError("not found"),
                ("fvm", "devices", "--machine"): OSError("not found"),
            }
        )
        candidates = discover_ios_flutter_candidates(run_command=runner)
        assert candidates == []

    def test_discover_candidates_no_devices_returns_empty(self) -> None:
        runner = make_command_runner({("flutter", "devices", "--machine"): "[]"})
        candidates = discover_ios_flutter_candidates(run_command=runner)
        assert candidates == []

    def test_discover_candidates_invalid_output_returns_empty(self) -> None:
        runner = make_command_runner({("flutter", "devices", "--machine"): "not json"})
        candidates = discover_ios_flutter_candidates(run_command=runner)
        assert candidates == []


# ===========================================================================
# Android adb 解析 (迁移 TestAndroidUsbIdentity 2 tests)
# ===========================================================================


class TestAndroidConnectedDevices:
    """Android adb 解析: adb devices -l → serial+model+IP.

    迁移自 test_network_r020_bf002.py::TestAndroidUsbIdentity.
    """

    def test_android_serial_and_model_parsed(self) -> None:
        """mock adb devices -l + ip route → discover_connected_devices 解析 serial+model+IP。

        断言要点:
        - endpoint.host == "192.168.1.55"
        - label == "SM-G991B" (model 来自 _metadata_value)
        - platform == "android"
        """
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): (
                    "List of devices attached\n"
                    "R58M1234567     device usb:1-1 product:sm-g991 model:SM-G991B device:o1s\n"
                    "\n"
                ),
                ("adb", "-s", "R58M1234567", "shell", "ip", "route", "get", "1.1.1.1"): (
                    "1.1.1.1 via 192.168.1.1 dev wlan0  src 192.168.1.55\n"
                    "    cache\n"
                ),
            }
        )
        devices = discover_connected_devices(run_command=runner, default_port=18080)
        assert len(devices) == 1
        d = devices[0]
        assert d.endpoint.host == "192.168.1.55"
        assert d.endpoint.port == 18080
        assert d.label == "SM-G991B"  # model 来自 _metadata_value(parts, "model")
        assert d.platform == "android"

    def test_android_unauthorized_device_skipped(self) -> None:
        """adb devices 状态非 'device' (unauthorized/offline) 被跳过。"""
        runner = make_command_runner(
            {
                ("adb", "devices", "-l"): (
                    "List of devices attached\n"
                    "R58M1234567 offline\n"
                    "R58M9999999 unauthorized\n"
                    "\n"
                ),
            }
        )
        devices = discover_connected_devices(run_command=runner)
        assert devices == []


# ===========================================================================
# 新增测试 (2 tests)
# ===========================================================================


class TestIosDeviceCandidateDataclass:
    """IosDeviceCandidate dataclass 字段契约验证。"""

    def test_ios_device_candidate_fields(self) -> None:
        """验证 IosDeviceCandidate dataclass 字段 (device_id, model, platform).

        断言要点:
        - isinstance(candidate, IosDeviceCandidate)
        - 字段值正确赋值
        """
        candidate = IosDeviceCandidate(
            device_id="3992f440f538798c0d49a6efb883cc4bd55df501",
            model="iPhone X",
            platform="ios",
        )
        assert isinstance(candidate, IosDeviceCandidate)
        assert candidate.device_id == "3992f440f538798c0d49a6efb883cc4bd55df501"
        assert candidate.model == "iPhone X"
        assert candidate.platform == "ios"


class TestLegacyIosInventoryDevices:
    """_ios_inventory_devices 旧 devicectl 路径 (GUI 兼容)。"""

    def test_ios_inventory_devices_fallback_to_empty_on_xcrun_unavailable(self) -> None:
        """xcrun devicectl 不可用时返回空列表 (GUI 兼容, 不崩)。

        断言要点: mock devicectl 失败 → result == []
        """
        runner = make_command_runner(
            {("xcrun", "devicectl", "list", "devices"): OSError("xcrun unavailable")}
        )
        result = _ios_inventory_devices(runner)
        assert result == []
