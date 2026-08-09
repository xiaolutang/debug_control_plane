"""R020-BF006 CrossIdentify 服务测试 (USB ⊕ LAN 交叉识别纯函数).

AC 覆盖 (test §2.1 CrossIdentify 三场景 + BF006 验收门):
  AC2/AC3 单设备 USB 1 + LAN 1 → 合并 1 DeviceRecord (device_id=USB 身份, host=LAN host)
  AC12   多设备 + 桥梁字段 (hardware_name/machine_id) → 各自绑定
         iOS 同型号同名 + USB 都插 → ambiguous 标记 (不强行猜)
         Android serial 强匹配 (android_lan_ip ↔ host)
         iOS USB 物理优先 (插着的绑定, 未插的不配)
         桥梁字段缺失 (老 app 无 FF001) → 降级 (单设备仍工作, 多设备 ambiguous)
         device_id 取 USB 身份 (非 /hello.deviceId)
         source="auto"/platform/hardware_name/machine_id 字段完整填充
         不改输入 (frozen dataclass 保护)

设计来源:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF006 节
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
            §3.4 CrossIdentify + §5.1 + D7 分层兜底链 + D9 device_id 来源
  - analysis: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery.md
            §设备身份桥梁字段 (Android serial 强 / iOS 设备名+机型弱)
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1

注意: BF006 是纯函数 (输入 UsbCandidate + LanCandidate → DeviceRecord 输出),
      不触网不调命令. 所有 I/O 在 BF004 (USB) / BF005 (LAN) 已完成. 不 mock I/O.
"""

from __future__ import annotations

from debug_control_plane.device_discovery.device_pool import DeviceRecord
from debug_control_plane.device_discovery.discovery.cross_identify import CrossIdentify, MatchReason
from debug_control_plane.device_discovery.discovery.lan_scan import LanCandidate
from debug_control_plane.device_discovery.discovery.usb_identity import UsbCandidate
from debug_control_plane.device_discovery.protocol import NetworkTarget

# ---------------------------------------------------------------------------
# 工厂: 直接构造 frozen dataclass 字面量, 不 mock I/O (BF006 纯函数)
# ---------------------------------------------------------------------------


def _usb(
    device_id: str,
    *,
    model: str = "SM-G991B",
    platform: str = "android",
    android_lan_ip: str | None = None,
) -> UsbCandidate:
    """构造 USB 候选字面量 (frozen dataclass)."""
    return UsbCandidate(
        device_id=device_id,
        model=model,
        platform=platform,
        android_lan_ip=android_lan_ip,
    )


def _target(
    *,
    host: str,
    hardware_name: str | None = None,
    machine_id: str | None = None,
    platform: str = "android",
    device_id: str = "gmacro-virtual-iOS",  # R019 固定字符串 (D9 不用)
    local_ips: tuple[str, ...] = (),
) -> NetworkTarget:
    """构造 NetworkTarget 字面量 (含 R020 FF001 桥梁字段).

    默认 device_id 是 R019 写死的固定字符串, 多设备会撞 (D9 明确不用).
    BF006 必须忽略此字段, 用 USB 身份当 device_id.
    """
    return NetworkTarget(
        device_id=device_id,
        device_name=hardware_name or f"{host}-name",
        platform=platform,
        host=host,
        port=18080,
        protocol_version=1,
        capabilities=frozenset(),
        active_source="none",
        virtual_connected=False,
        profile_id=None,
        real_controller_active=False,
        last_error=None,
        profile_revision=0,
        local_ips=local_ips,
        hardware_name=hardware_name,
        machine_id=machine_id,
    )


def _lan(
    host: str,
    *,
    hardware_name: str | None = None,
    machine_id: str | None = None,
    platform: str = "android",
    local_ips: tuple[str, ...] = (),
) -> LanCandidate:
    """构造 LAN 候选字面量 (frozen dataclass)."""
    return LanCandidate(
        host=host,
        port=18080,
        network_target=_target(
            host=host,
            hardware_name=hardware_name,
            machine_id=machine_id,
            platform=platform,
            local_ips=local_ips,
        ),
    )


# ---------------------------------------------------------------------------
# 层 1: 单设备 USB 1对1 直接合并 (AC2/AC3)
# ---------------------------------------------------------------------------


class TestSingleDeviceOneToOne:
    """单设备 USB 1 + LAN 1 → 合并 1 DeviceRecord (层 1 主路径)."""

    def test_android_single_usb_plus_single_lan_merges_to_one_record(self) -> None:
        """AC2: Android 单 USB + 单 LAN → 合并, device_id=adb serial, host=LAN host."""
        usb = _usb("R58M1234567", model="SM-G991B", android_lan_ip="192.168.1.50")
        lan = _lan("192.168.1.50", hardware_name="Pixel 7", machine_id="SM-G991B")

        records = CrossIdentify().identify([usb], [lan])

        assert len(records) == 1
        rec = records[0]
        # D9: device_id 来自 USB 身份 (adb serial), 非 /hello.deviceId
        assert rec.device_id == "R58M1234567"
        # host 来自 LAN 候选
        assert rec.last_known_host == "192.168.1.50"
        # source 自动发现
        assert rec.source == "auto"
        # FF001 桥梁字段从双方填充
        assert rec.platform == "android"
        assert rec.hardware_name == "Pixel 7"
        assert rec.machine_id == "SM-G991B"

    def test_ios_single_usb_plus_single_lan_merges_to_one_record(self) -> None:
        """AC3: iPhone X 单 USB (usbmuxd id) + 单 LAN → 合并."""
        usb = _usb("3992f440f538", model="iPhone X", platform="ios")
        lan = _lan(
            "192.168.1.34",
            hardware_name="小明的 iPhone",
            machine_id="iPhone10,3",
            platform="ios",
        )

        records = CrossIdentify().identify([usb], [lan])

        assert len(records) == 1
        rec = records[0]
        # D9: device_id = usbmuxd id (iOS USB 身份)
        assert rec.device_id == "3992f440f538"
        assert rec.last_known_host == "192.168.1.34"
        assert rec.platform == "ios"
        assert rec.hardware_name == "小明的 iPhone"
        assert rec.machine_id == "iPhone10,3"

    def test_label_from_hardware_name_when_available(self) -> None:
        """label 优先用 hardware_name (FF001 真实设备名)."""
        usb = _usb("R58M1234567", android_lan_ip="192.168.1.50")
        lan = _lan("192.168.1.50", hardware_name="工位A Pixel")

        records = CrossIdentify().identify([usb], [lan])

        assert records[0].label == "工位A Pixel"

    def test_label_fallback_to_model_when_no_hardware_name(self) -> None:
        """老 app 无 FF001 hardware_name → label 回退 USB model."""
        usb = _usb("R58M1234567", model="SM-G991B", android_lan_ip="192.168.1.50")
        lan = _lan("192.168.1.50", hardware_name=None)  # 老 app 无桥梁字段

        records = CrossIdentify().identify([usb], [lan])

        assert records[0].label == "SM-G991B"


# ---------------------------------------------------------------------------
# 空输入 / 单边无候选不强行配
# ---------------------------------------------------------------------------


class TestEmptyInputs:
    """空输入 / 单边无候选 → [] (不强行配对)."""

    def test_both_empty_returns_empty(self) -> None:
        assert CrossIdentify().identify([], []) == []

    def test_usb_only_no_lan_returns_empty(self) -> None:
        """USB 插着但 LAN 没扫到 → 不入池 (无 IP 无法操作)."""
        usb = _usb("R58M1234567", android_lan_ip="192.168.1.50")
        assert CrossIdentify().identify([usb], []) == []

    def test_lan_only_no_usb_returns_empty(self) -> None:
        """LAN 扫到但 USB 没插 → 不入池 (无稳定身份, 交 BF007 人指认)."""
        lan = _lan("192.168.1.50", hardware_name="Pixel")
        assert CrossIdentify().identify([], [lan]) == []


# ---------------------------------------------------------------------------
# 层 2: Android serial 强匹配 (android_lan_ip ↔ host)
# ---------------------------------------------------------------------------


class TestAndroidSerialStrongMatch:
    """Android android_lan_ip ↔ LanCandidate.host 直接 IP 匹配 (最强层)."""

    def test_android_lan_ip_matches_host_binds(self) -> None:
        """Android 经 adb ip route 拿的 LAN IP 与 LAN 扫描 host 一致 → 绑定."""
        usb = _usb(
            "R58M1234567",
            model="SM-G991B",
            android_lan_ip="192.168.1.50",
        )
        # 另一台 LAN 设备也在扫到列表里, IP 不撞
        lan_a = _lan("192.168.1.50", hardware_name="Pixel-A", machine_id="SM-G991B")
        lan_b = _lan("192.168.1.51", hardware_name="Pixel-B", machine_id="SM-G991C")

        records = CrossIdentify().identify([usb], [lan_a, lan_b])

        assert len(records) == 1
        rec = records[0]
        assert rec.device_id == "R58M1234567"
        assert rec.last_known_host == "192.168.1.50"
        assert rec.hardware_name == "Pixel-A"

    def test_android_lan_ip_not_matching_any_host_returns_empty(self) -> None:
        """USB 报 IP 与所有 LAN host 都不符 (手机切了 WiFi 但 USB 未刷新) → 不强行配."""
        usb = _usb(
            "R58M1234567",
            model="SM-G991B",
            android_lan_ip="192.168.1.99",  # 此 host 不在 LAN 扫描结果里
        )
        lan = _lan("192.168.1.50", hardware_name="其他设备")

        # 单 USB 单 LAN 但 IP 不匹配 → 不强行猜, 不入池
        records = CrossIdentify().identify([usb], [lan])
        assert records == []

    def test_two_androids_serial_ip_strong_match(self) -> None:
        """两台 Android, 各自 android_lan_ip ↔ host 精确匹配 (AC12 多设备不串)."""
        usb_a = _usb("R58M111", model="SM-G991B", android_lan_ip="192.168.1.50")
        usb_b = _usb("R58M222", model="SM-G991C", android_lan_ip="192.168.1.51")
        lan_a = _lan("192.168.1.50", hardware_name="Pixel-A", machine_id="SM-G991B")
        lan_b = _lan("192.168.1.51", hardware_name="Pixel-B", machine_id="SM-G991C")

        records = CrossIdentify().identify([usb_a, usb_b], [lan_a, lan_b])

        assert len(records) == 2
        by_id = {r.device_id: r for r in records}
        assert by_id["R58M111"].last_known_host == "192.168.1.50"
        assert by_id["R58M222"].last_known_host == "192.168.1.51"
        # 不串扰: 各自配对
        assert by_id["R58M111"].hardware_name == "Pixel-A"
        assert by_id["R58M222"].hardware_name == "Pixel-B"


# ---------------------------------------------------------------------------
# 层 3: 多设备桥梁字段匹配 (hardware_name + machine_id)
# ---------------------------------------------------------------------------


class TestBridgeFieldMultiMatch:
    """多 USB + 多 LAN, 桥梁字段 (hardware_name/machine_id) 各异 → 各自绑定 (层 3)."""

    def test_two_ios_bridge_fields_unique_each_binds(self) -> None:
        """两台 iOS USB + 两台 LAN, hardware_name/machine_id 各异 → 各自绑定.

        iOS 无 android_lan_ip, 必须靠 FF001 桥梁字段匹配.
        """
        usb_a = _usb("aaa111", model="iPhone 13", platform="ios")
        usb_b = _usb("bbb222", model="iPhone 14", platform="ios")
        lan_a = _lan(
            "192.168.1.10",
            hardware_name="小明的 iPhone",
            machine_id="iPhone13,2",
            platform="ios",
        )
        lan_b = _lan(
            "192.168.1.11",
            hardware_name="小红的 iPhone",
            machine_id="iPhone14,1",
            platform="ios",
        )

        records = CrossIdentify().identify([usb_a, usb_b], [lan_a, lan_b])

        # 两台 hardware_name 不同 → 各自桥梁字段匹配
        assert len(records) == 2
        hosts = {r.last_known_host for r in records}
        assert hosts == {"192.168.1.10", "192.168.1.11"}

    def test_bridge_field_machine_id_distinguishes_same_name(self) -> None:
        """同名 (hardware_name 一样) 但 machine_id 不同 → 仍可区分绑定.

        场景: 两台都叫 "我的 iPhone" 但型号不同 (iPhone13 vs iPhone14).
        """
        usb_a = _usb("aaa111", model="iPhone 13", platform="ios")
        usb_b = _usb("bbb222", model="iPhone 14", platform="ios")
        lan_a = _lan(
            "192.168.1.10",
            hardware_name="我的 iPhone",
            machine_id="iPhone13,2",
            platform="ios",
        )
        lan_b = _lan(
            "192.168.1.11",
            hardware_name="我的 iPhone",
            machine_id="iPhone14,1",
            platform="ios",
        )

        records = CrossIdentify().identify([usb_a, usb_b], [lan_a, lan_b])

        # machine_id 不同 → 可区分 (USB model 与 machine_id 对应)
        assert len(records) == 2


# ---------------------------------------------------------------------------
# 层 4: iOS 同型号同名 USB 物理优先 / ambiguous
# ---------------------------------------------------------------------------


class TestIosAmbiguousSameModelSameName:
    """iOS 同型号同名 + USB 都插 → ambiguous 标记 (不强行猜, 层 4/5)."""

    def test_two_ios_same_model_same_name_both_plugged_ambiguous(self) -> None:
        """两台 iPhone X 同名, USB 都插, LAN 都响应 → 无桥梁字段可区分 → ambiguous.

        这是 D7 核心: 不强行猜, 交上层 (AI/开发者/BF007 人指认) 决策.
        """
        usb_a = _usb("aaa111", model="iPhone X", platform="ios")
        usb_b = _usb("bbb222", model="iPhone X", platform="ios")
        # 同名同机型, FF001 桥梁字段撞车
        lan_a = _lan(
            "192.168.1.10",
            hardware_name="小明的 iPhone",
            machine_id="iPhone10,3",
            platform="ios",
        )
        lan_b = _lan(
            "192.168.1.11",
            hardware_name="小明的 iPhone",
            machine_id="iPhone10,3",
            platform="ios",
        )

        records = CrossIdentify().identify([usb_a, usb_b], [lan_a, lan_b])

        # ambiguous 不强行猜: 至少有一个 record 带 ambiguous 标记
        # 但仍入池 (供上层决策), label 加 [ambiguous] 前缀
        assert len(records) >= 1
        ambiguous = [r for r in records if _is_ambiguous(r)]
        assert len(ambiguous) >= 1, (
            f"应至少有一个 ambiguous 标记的 record, 实际: {records}"
        )


def _is_ambiguous(rec: DeviceRecord) -> bool:
    """检查 DeviceRecord 是否带 ambiguous 标记 (label 前缀或 note)."""
    if rec.label and "[ambiguous]" in rec.label:
        return True
    if rec.note and "ambiguous" in rec.note.lower():
        return True
    return False


class TestIosUsbPhysicalPriority:
    """iOS 同名但只 1 个 USB 插 → 插着的绑定, 未插的不配 (层 4)."""

    def test_one_ios_plugged_one_lan_response_binds_plugged(self) -> None:
        """场景: LAN 扫到 1 台 (响应同名), USB 插着 1 台 → 1对1 绑定 (不算 ambiguous).

        这覆盖 iOS 单设备 fallback 路径.
        """
        usb = _usb("aaa111", model="iPhone X", platform="ios")
        lan = _lan(
            "192.168.1.10",
            hardware_name="小明的 iPhone",
            machine_id="iPhone10,3",
            platform="ios",
        )

        records = CrossIdentify().identify([usb], [lan])

        assert len(records) == 1
        assert records[0].device_id == "aaa111"
        assert records[0].last_known_host == "192.168.1.10"
        # 单设备 1对1 不算 ambiguous
        assert not _is_ambiguous(records[0])


# ---------------------------------------------------------------------------
# 桥梁字段缺失 (老 app 无 FF001) 降级
# ---------------------------------------------------------------------------


class TestBridgeFieldsMissing:
    """network_target.hardware_name/machine_id 是 None (老 app) → 降级."""

    def test_single_device_no_bridge_fields_still_works(self) -> None:
        """单设备 + 老 app 无 FF001 → 层 1 直接合并仍工作."""
        usb = _usb("R58M1234567", android_lan_ip="192.168.1.50")
        lan = _lan("192.168.1.50", hardware_name=None, machine_id=None)

        records = CrossIdentify().identify([usb], [lan])

        assert len(records) == 1
        rec = records[0]
        assert rec.device_id == "R58M1234567"
        assert rec.last_known_host == "192.168.1.50"
        # 无桥梁字段 → None
        assert rec.hardware_name is None
        assert rec.machine_id is None

    def test_multi_devices_no_bridge_fields_android_ip_still_matches(self) -> None:
        """多 Android + 老 app → 靠 android_lan_ip 强匹配仍工作 (不依赖 FF001)."""
        usb_a = _usb("R58M111", android_lan_ip="192.168.1.50")
        usb_b = _usb("R58M222", android_lan_ip="192.168.1.51")
        lan_a = _lan("192.168.1.50", hardware_name=None, machine_id=None)
        lan_b = _lan("192.168.1.51", hardware_name=None, machine_id=None)

        records = CrossIdentify().identify([usb_a, usb_b], [lan_a, lan_b])

        assert len(records) == 2
        by_id = {r.device_id: r for r in records}
        assert by_id["R58M111"].last_known_host == "192.168.1.50"
        assert by_id["R58M222"].last_known_host == "192.168.1.51"

    def test_multi_ios_no_bridge_fields_ambiguous(self) -> None:
        """多 iOS + 老 app 无 FF001 → 无桥梁字段 → ambiguous (不强行猜)."""
        usb_a = _usb("aaa111", model="iPhone X", platform="ios")
        usb_b = _usb("bbb222", model="iPhone X", platform="ios")
        lan_a = _lan(
            "192.168.1.10",
            hardware_name=None,
            machine_id=None,
            platform="ios",
        )
        lan_b = _lan(
            "192.168.1.11",
            hardware_name=None,
            machine_id=None,
            platform="ios",
        )

        records = CrossIdentify().identify([usb_a, usb_b], [lan_a, lan_b])

        # 无桥梁字段无法区分 → 不强行猜, 至少一个带 ambiguous 标记
        ambiguous = [r for r in records if _is_ambiguous(r)]
        assert len(ambiguous) >= 1


# ---------------------------------------------------------------------------
# D9: device_id 取 USB 身份, 非 /hello.deviceId
# ---------------------------------------------------------------------------


class TestDeviceIdFromUsbIdentity:
    """device_id 必须来自 USB 身份, 绝不用 R019 /hello.deviceId 固定字符串 (D9)."""

    def test_device_id_is_usb_serial_not_hello_device_id(self) -> None:
        """两台 iOS 的 /hello.deviceId 都是 R019 写死 'gmacro-virtual-iOS' (撞),

        但 USB 身份 (usbmuxd id) 各异 → DeviceRecord.device_id 取 USB 身份.
        """
        usb_a = _usb("aaa111", model="iPhone X", platform="ios")
        usb_b = _usb("bbb222", model="iPhone 14", platform="ios")
        # 两台 LAN 的 /hello.deviceId 都是 R019 写死的固定字符串 (默认值)
        lan_a = _lan(
            "192.168.1.10",
            hardware_name="A-iPhone",
            machine_id="iPhone10,3",
            platform="ios",
        )
        lan_b = _lan(
            "192.168.1.11",
            hardware_name="B-iPhone",
            machine_id="iPhone14,1",
            platform="ios",
        )

        records = CrossIdentify().identify([usb_a, usb_b], [lan_a, lan_b])

        device_ids = {r.device_id for r in records}
        # device_id 全部来自 USB 身份, 绝不出现 R019 写死的 'gmacro-virtual-iOS'
        assert "gmacro-virtual-iOS" not in device_ids
        assert "aaa111" in device_ids
        assert "bbb222" in device_ids


# ---------------------------------------------------------------------------
# DeviceRecord 字段完整性
# ---------------------------------------------------------------------------


class TestDeviceRecordFieldCompleteness:
    """合并后的 DeviceRecord 字段必须完整填充 (source/platform/桥梁字段等)."""

    def test_all_fields_populated_android(self) -> None:
        usb = _usb(
            "R58M1234567",
            model="SM-G991B",
            android_lan_ip="192.168.1.50",
        )
        lan = _lan(
            "192.168.1.50",
            hardware_name="工位A Pixel",
            machine_id="SM-G991B",
            platform="android",
        )

        records = CrossIdentify().identify([usb], [lan])

        assert len(records) == 1
        rec = records[0]
        assert rec.device_id == "R58M1234567"
        assert rec.source == "auto"
        assert rec.platform == "android"
        assert rec.hardware_name == "工位A Pixel"
        assert rec.machine_id == "SM-G991B"
        assert rec.last_known_host == "192.168.1.50"

    def test_match_reason_signal_android_ip(self) -> None:
        """MatchReason 标识用了哪一层匹配 (Android IP 强匹配层)."""
        usb = _usb("R58M111", android_lan_ip="192.168.1.50")
        lan = _lan("192.168.1.50", hardware_name="Pixel")

        results = CrossIdentify().identify_with_reason([usb], [lan])

        assert len(results) == 1
        rec, reason = results[0]
        assert rec.device_id == "R58M111"
        assert reason == MatchReason.ANDROID_IP

    def test_match_reason_signal_single_device(self) -> None:
        """单设备 1对1 → MatchReason.SINGLE_DEVICE."""
        usb = _usb("aaa111", platform="ios")
        lan = _lan("192.168.1.10", platform="ios")

        results = CrossIdentify().identify_with_reason([usb], [lan])

        assert len(results) == 1
        _, reason = results[0]
        assert reason == MatchReason.SINGLE_DEVICE


# ---------------------------------------------------------------------------
# 不改输入 (frozen dataclass 保护)
# ---------------------------------------------------------------------------


class TestNoInputMutation:
    """identify 不修改 usb/lan 输入列表 (frozen dataclass + 不在原列表上操作)."""

    def test_input_lists_unchanged_after_identify(self) -> None:
        usb = _usb("R58M111", android_lan_ip="192.168.1.50")
        lan = _lan("192.168.1.50")
        usb_list = [usb]
        lan_list = [lan]

        CrossIdentify().identify(usb_list, lan_list)

        # 列表元素身份不变 (== [usb] 已隐含 len==1, frozen dataclass)
        assert usb_list == [usb]
        assert lan_list == [lan]

    def test_frozen_dataclass_cannot_be_mutated(self) -> None:
        """frozen dataclass 字段不可改 (验证输入本身不可变)."""
        usb = _usb("R58M111")
        try:
            usb.device_id = "TAMPERED"  # type: ignore[misc]
        except Exception:
            return  # frozen 抛 FrozenInstanceError — 期望
        raise AssertionError("UsbCandidate 应是 frozen, 不允许改 device_id")
