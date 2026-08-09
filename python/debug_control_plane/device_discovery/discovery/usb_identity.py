"""USB 设备身份源服务 (R020-BF004).

职责 (design §3.4 + analysis iOS/Android §USB 通道): 通过 USB 通道 (Android
``adb devices -l`` / iOS ``flutter devices``) 取设备**身份** (serial /
usbmuxd id / 机型 / LAN IP), 供下游 BF006 cross_identify 做 USB⊕LAN 交叉识别.

设计要点:
  * **USB 仅当身份源不当数据通道** (analysis backlog 红线 / BF004.3): 本服务
    只取身份字段, **绝不**做 ``adb forward`` / ``iproxy`` 数据通道转发.
    ``android_lan_ip`` 是身份辅助 (供 BF006 交叉识别用), 不是数据通道.
  * **分端策略** (memory ios16-device-devicectl-pitfall):
    - Android: ``adb devices -l`` → serial + model; LAN IP 经
      ``adb shell ip route get 1.1.1.1`` 精确拿 (供 BF006 交叉识别用).
    - iOS: **只**走 ``flutter devices --machine`` (BF002.2
      ``discover_ios_flutter_candidates``, 解析 usbmuxd id + 机型);
      **绝不**调 ``xcrun devicectl`` (iPhone X iOS 16 永远 unavailable).
  * **复用 device_candidates** (D8 + BF004 决策 1, 不改旧函数):
    - Android: 复用 ``_android_device_ip(serial, run_command)`` 拿精确 LAN IP;
      serial + model 自己解析 ``adb devices -l`` 输出 (device_candidates
      ``_android_connected_devices`` 内部已做此解析但暴露的 ConnectedDeviceEndpoint
      丢失 serial, 故 BF004 自行解析以保留 device_id=serial).
    - iOS: 直接调 ``discover_ios_flutter_candidates(run_command=...)`` 拿
      ``IosDeviceCandidate`` (device_id=usbmuxd id, model), 转 UsbCandidate.
  * **异常容忍** (与 device_candidates + BF003/BF005 同模式): adb/flutter 不可用
    (命令不存在 / 超时 / 无设备) → 返回空列表, 不抛异常.

设计来源:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF004 节
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
            §3.4 Discovery (UsbIdentity 角色) + D9 device_id 来源
  - analysis: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery.md
            §USB 通道 (USB 仅身份不数据通道) + §iOS/Android
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1
  - memory: ios16-device-devicectl-pitfall (iOS 16 devicectl 永远 unavailable)
"""

from __future__ import annotations

from dataclasses import dataclass

# device_candidates 是 device_discovery 顶层模块 (BF006 自旧 network 子包迁入).
# 复用其解析函数 (D8 零重写), 不改其旧函数.
from ..device_candidates import (
    CommandRunner,
    _android_device_ip,
    _metadata_value,
    _run_command,
    discover_ios_flutter_candidates,
)

# ---------------------------------------------------------------------------
# UsbCandidate dataclass (BF004.2)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class UsbCandidate:
    """USB 身份候选 (单台已连接的物理设备).

    跨平台统一身份容器: Android 来自 ``adb`` serial, iOS 来自 ``flutter``
    usbmuxd id. ``device_id`` 是稳定身份键 (BF006 cross_identify 用此匹配
    LAN 响应, design D9); ``android_lan_ip`` 是 Android 独有的身份辅助字段
    (经 ``adb shell ip route`` 精确拿, iOS 恒 None), 供 BF006 做交叉识别桥梁.

    Attributes:
        device_id: 稳定身份标识. Android = adb serial (如 ``R58M1234567``);
            iOS = usbmuxd id (如 ``3992f440...``, ``flutter devices --machine``
            的 ``id`` 字段).
        model: 机型显示名 (Android = ``model:`` 字段值如 ``SM-G991B``;
            iOS = ``flutter devices --machine`` 的 ``name`` 字段如 ``iPhone X``).
            弱唯一, 仅用于交叉识别 + 显示.
        platform: ``"android"`` 或 ``"ios"``.
        android_lan_ip: Android 经 ``adb shell ip route get 1.1.1.1`` 精确拿的
            LAN IP (供 BF006 交叉识别用); iOS 恒 ``None`` (USB 仅身份, iOS LAN
            IP 由 BF005 LanScan 在 LAN 侧发现, 不在 USB 侧拿).
    """

    device_id: str
    model: str
    platform: str
    android_lan_ip: str | None = None


# ---------------------------------------------------------------------------
# UsbIdentity 服务 (BF004.1)
# ---------------------------------------------------------------------------


class UsbIdentity:
    """USB 设备身份源服务 (Android ``adb`` / iOS ``flutter`` 分端).

    分端取 USB 已连接设备的身份 (serial / usbmuxd id / 机型 / LAN IP), 返回
    ``UsbCandidate`` 列表. **仅身份, 不做数据通道** (BF004.3, 不调
    ``adb forward`` / ``iproxy``).

    Example::

        svc = UsbIdentity()
        android = svc.android()        # [UsbCandidate(device_id="R58M...", ...)]
        ios = svc.ios()                # [UsbCandidate(device_id="3992f440...", ...)]
        all_devs = svc.all_candidates()  # android + ios 合并

    Args:
        run_command: 可注入的命令执行器 (默认 device_candidates._run_command,
            即 subprocess.run 封装); 测试时注入 mock runner (按 command 前缀
            返回预设输出或抛 OSError). 与 BF003/BF005/device_candidates 同模式.
    """

    def __init__(self, *, run_command: CommandRunner | None = None) -> None:
        self._run_command: CommandRunner = run_command or _run_command

    def android(self) -> list[UsbCandidate]:
        """Android USB 身份候选 (经 ``adb devices -l`` + ``adb shell ip route``).

        解析 ``adb devices -l`` 输出取 ``device`` 状态的 serial + model; 对每个
        serial 调 device_candidates ``_android_device_ip(serial)`` 经
        ``adb shell ip route get 1.1.1.1`` 拿精确 LAN IP (供 BF006 交叉识别).

        Returns:
            ``UsbCandidate`` 列表 (platform="android"); 空 list 表示 adb 不可用 /
            无设备 / 无 LAN IP (拿不到 LAN IP 的设备跳过, 与 device_candidates
            ``_android_connected_devices`` 一致). 永不抛异常.

        Side effects:
            调用 ``adb devices -l`` + 每台设备一次 ``adb shell ip route``.
        """
        try:
            output = self._run_command(["adb", "devices", "-l"], 5.0)
        except OSError:
            # adb 不可用 / 超时 / 命令失败 → 与 device_candidates 同模式返空
            return []
        candidates: list[UsbCandidate] = []
        for serial, model in _parse_adb_devices_output(output):
            lan_ip = _android_device_ip(serial, self._run_command)
            if lan_ip is None:
                # 拿不到 LAN IP 的设备跳过 (与 _android_connected_devices 一致:
                # 没有可用 LAN IP 的 Android 设备对 BF006 交叉识别无意义)
                continue
            candidates.append(
                UsbCandidate(
                    device_id=serial,
                    model=model,
                    platform="android",
                    android_lan_ip=lan_ip,
                )
            )
        return candidates

    def ios(self) -> list[UsbCandidate]:
        """iOS USB 身份候选 (经 ``flutter devices --machine``, 不调 devicectl).

        复用 BF002.2 ``discover_ios_flutter_candidates`` 解析 ``flutter devices
        --machine`` JSON, 取真机 (排除 simulator/emulator) 的 usbmuxd id + 机型;
        绝不调 ``xcrun devicectl`` (iPhone X iOS 16 永远 unavailable,
        memory ios16-device-devicectl-pitfall).

        Returns:
            ``UsbCandidate`` 列表 (platform="ios", android_lan_ip=None); 空 list
            表示 flutter 不可用 / 无真机 / 解析失败. 永不抛异常.

        Side effects:
            调用 ``flutter devices --machine`` (内部已处理多 flutter 候选命令
            ``flutter`` / ``/usr/local/bin/flutter`` / ``fvm`` 等).
        """
        ios_candidates = discover_ios_flutter_candidates(run_command=self._run_command)
        return [
            UsbCandidate(
                device_id=cand.device_id,
                model=cand.model,
                platform="ios",
                android_lan_ip=None,  # iOS LAN IP 由 BF005 LanScan 在 LAN 侧发现
            )
            for cand in ios_candidates
        ]

    def all_candidates(self) -> list[UsbCandidate]:
        """所有 USB 已连接设备 (Android + iOS 合并, Android 在前).

        Returns:
            ``UsbCandidate`` 列表 (先 android() 后 ios()); 两个端都不抛异常,
            任一端失败只贡献空列表.
        """
        return [*self.android(), *self.ios()]


# ---------------------------------------------------------------------------
# adb devices -l 解析 (BF004 自行解析以保留 serial, 不复用 _android_connected_devices
# 因其暴露的 ConnectedDeviceEndpoint 丢失 serial — BF004 device_id=serial 需保留)
# ---------------------------------------------------------------------------


#: ``adb devices -l`` 输出行的 ``device`` 状态标记 (其余 ``offline``/``unauthorized`` 跳过).
_ADB_DEVICE_STATE_CONNECTED = "device"


def _parse_adb_devices_output(output: str) -> list[tuple[str, str]]:
    """解析 ``adb devices -l`` 输出, 返回 ``[(serial, model), ...]``.

    只取状态为 ``device`` (已授权连接) 的行; ``offline`` / ``unauthorized`` /
    ``recovery`` 等状态跳过. model 来自 ``model:`` 元数据字段 (如
    ``model:SM-G991B``); 缺失则回退 serial (与 device_candidates
    ``_metadata_value(parts, "model") or serial`` 一致).

    Args:
        output: ``adb devices -l`` 的原始标准输出.

    Returns:
        ``[(serial, model), ...]`` 列表, 顺序与输入一致; 输出为空 / 全非 device
        状态 → 空列表.
    """
    results: list[tuple[str, str]] = []
    # 第一行是 "List of devices attached" 表头, 但稳妥起见逐行判断状态字段
    # (而非简单 splitlines()[1:], 防御空输出 / 单行输出).
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[1] != _ADB_DEVICE_STATE_CONNECTED:
            continue
        serial = parts[0]
        # 复用 device_candidates._metadata_value (D8 零重写, 同模块已 export).
        model = _metadata_value(parts, "model") or serial
        results.append((serial, model))
    return results


__all__ = [
    "UsbCandidate",
    "UsbIdentity",
]
