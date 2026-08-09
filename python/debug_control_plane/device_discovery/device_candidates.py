"""Connected device endpoint discovery for Network mode."""

from __future__ import annotations

import json
import re
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .endpoint import Endpoint

CommandRunner = Callable[[list[str], float], str]


@dataclass(frozen=True)
class ConnectedDeviceEndpoint:
    endpoint: Endpoint
    label: str
    platform: str


@dataclass(frozen=True)
class ConnectedDeviceInventory:
    device_id: str
    label: str
    platform: str
    state: str
    endpoint: Endpoint | None = None


def discover_connected_device_endpoints(
    *,
    default_port: int = 18080,
    run_command: CommandRunner | None = None,
) -> list[Endpoint]:
    devices = discover_connected_devices(
        default_port=default_port,
        run_command=run_command,
    )
    return [device.endpoint for device in devices]


def discover_connected_device_inventory(
    *,
    default_port: int = 18080,
    run_command: CommandRunner | None = None,
) -> list[ConnectedDeviceInventory]:
    runner = run_command or _run_command
    devices: list[ConnectedDeviceInventory] = []

    for device in _android_connected_devices(runner, default_port):
        devices.append(
            ConnectedDeviceInventory(
                device_id=f"{device.endpoint.host}:{device.endpoint.port}",
                label=device.label,
                platform="android",
                state="connected",
                endpoint=device.endpoint,
            )
        )

    for device in _ios_inventory_devices(runner):
        if not any(
            existing.platform == "ios" and existing.label == device.label
            for existing in devices
        ):
            devices.append(device)

    return devices


def discover_connected_devices(
    *,
    default_port: int = 18080,
    run_command: CommandRunner | None = None,
) -> list[ConnectedDeviceEndpoint]:
    runner = run_command or _run_command
    devices: list[ConnectedDeviceEndpoint] = []
    seen: set[tuple[str, int]] = set()

    for device in _android_connected_devices(runner, default_port):
        key = (device.endpoint.host, device.endpoint.port)
        if key not in seen:
            seen.add(key)
            devices.append(device)

    return devices


def _android_connected_devices(
    run_command: CommandRunner,
    default_port: int,
) -> list[ConnectedDeviceEndpoint]:
    try:
        output = run_command(["adb", "devices", "-l"], 5.0)
    except OSError:
        return []
    devices: list[ConnectedDeviceEndpoint] = []
    for line in output.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 2 or parts[1] != "device":
            continue
        serial = parts[0]
        ip = _android_device_ip(serial, run_command)
        if ip is None:
            continue
        model = _metadata_value(parts, "model") or serial
        devices.append(
            ConnectedDeviceEndpoint(
                endpoint=Endpoint(ip, default_port),
                label=model,
                platform="android",
            )
        )
    return devices


def _android_device_ip(serial: str, run_command: CommandRunner) -> str | None:
    try:
        output = run_command(["adb", "-s", serial, "shell", "ip", "route", "get", "1.1.1.1"], 5.0)
    except OSError:
        return None
    match = re.search(r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)\b", output)
    return match.group(1) if match else None


def _ios_inventory_devices(run_command: CommandRunner) -> list[ConnectedDeviceInventory]:
    try:
        output = run_command(["xcrun", "devicectl", "list", "devices"], 8.0)
    except OSError:
        return []
    devices: list[ConnectedDeviceInventory] = []
    for line in output.splitlines():
        if ".coredevice.local" not in line:
            continue
        parsed = _parse_ios_device_line(line)
        if parsed is None:
            continue
        label, identifier, state = parsed
        if state != "connected":
            continue
        devices.append(
            ConnectedDeviceInventory(
                device_id=identifier,
                label=label,
                platform="ios",
                state=state,
                endpoint=None,
            )
        )
    return devices


def _parse_ios_device_line(line: str) -> tuple[str, str, str] | None:
    hostname = _extract_coredevice_hostname(line)
    if hostname is None:
        return None
    prefix, suffix = line.split(hostname, 1)
    parts = suffix.split()
    if len(parts) < 2:
        return None
    label = prefix.strip() or hostname
    identifier = parts[0]
    state = parts[1]
    return label, identifier, state


def _is_available_ios_device(line: str) -> bool:
    return " connected " in f" {line} "


def _extract_coredevice_hostname(line: str) -> str | None:
    match = re.search(r"([\w.-]+\.coredevice\.local)", line)
    return match.group(1) if match else None


def _metadata_value(parts: list[str], key: str) -> str | None:
    prefix = f"{key}:"
    for part in parts:
        if part.startswith(prefix):
            return part[len(prefix) :]
    return None


def _run_command(command: list[str], timeout: float) -> str:
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


# ---------------------------------------------------------------------------
# R020-BF002: iOS device discovery via `flutter devices` (USB identity source).
#
# 新增独立函数,不改旧 `_ios_inventory_devices`(xcrun devicectl 路径,保留供 GUI
# 兼容)。原因:iPhone X 真机 iOS 16,`xcrun devicectl` 永远 unavailable
# (memory ios16-device-devicectl-pitfall),`flutter devices` 是可用路径。
#
# 设计见 .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
#   §2「iOS 发现不可用」+ analysis iOS/Android §USB 通道
# ---------------------------------------------------------------------------


# macOS 上 flutter 不在默认 PATH,显式回退路径(防止子进程环境没装 fvm)
_FLUTTER_CANDIDATES: tuple[str, ...] = (
    "flutter",
    "/usr/local/bin/flutter",
    "/opt/homebrew/bin/flutter",
    "fvm",
)


@dataclass(frozen=True)
class IosDeviceCandidate:
    """iOS 设备身份候选(来自 `flutter devices` 解析)。

    供 USB 身份源消费(BF004 UsbCandidate 用此)。
    `device_id` = usbmuxd id(如 3992f440...,稳定身份源);
    `model` = 机型显示名(iPhone X / iPhone 14 Pro 等,弱唯一供交叉识别用)。
    """

    device_id: str            # usbmuxd id (`flutter devices --machine` id 字段)
    model: str                # 机型 (`flutter devices --machine` name 字段)
    platform: str = "ios"


def discover_ios_flutter_candidates(
    *,
    run_command: CommandRunner | None = None,
) -> list[IosDeviceCandidate]:
    """iOS 设备身份候选(经 `flutter devices`,不调 devicectl)。

    R020-BF002 落地:替代 iOS 16 不可用的 `_ios_inventory_devices`(devicectl 路径)。
    解析 `flutter devices --machine` 的 JSON 输出,只取真机(emulator/simulator 排除)。

    Args:
        run_command: 可注入命令执行器(默认 _run_command),便于 mock 测试

    Returns:
        IosDeviceCandidate 列表(空列表表示无真机或 flutter 不可用)
    """
    runner = run_command or _run_command
    output = _try_flutter_devices_machine(runner)
    if output is None:
        return []
    return _parse_flutter_devices_machine(output)


def _try_flutter_devices_machine(run_command: CommandRunner) -> str | None:
    """尝试多个 flutter 候选命令,返回首个成功的 `flutter devices --machine` 输出。

    所有候选都失败(或 _FLUTTER_CANDIDATES 为空)→ None。
    """
    for flutter in _FLUTTER_CANDIDATES:
        try:
            return run_command([flutter, "devices", "--machine"], 8.0)
        except OSError:
            continue
    return None


def _parse_flutter_devices_machine(output: str) -> list[IosDeviceCandidate]:
    """解析 `flutter devices --machine` JSON。

    `flutter devices --machine` 输出 JSON 数组,元素结构(节选):
      {
        "id": "<usbmuxd id 或 emulator-id>",
        "name": "iPhone X",
        "targetPlatform": "ios",
        "emulator": false,
        "category": "mobile",
        "platform": "ios" / "android-ios",
        ...
      }

    真机筛选:`emulator == false` 且 `targetPlatform`/`platform` 含 "ios"。
    """
    try:
        data = json.loads(output)
    except (json.JSONDecodeError, ValueError):
        return []
    if not isinstance(data, list):
        return []
    candidates: list[IosDeviceCandidate] = []
    for entry in data:
        if not isinstance(entry, dict):
            continue
        if not _is_ios_physical_device(entry):
            continue
        device_id = entry.get("id")
        model = entry.get("name") or entry.get("model")
        if not isinstance(device_id, str) or not device_id:
            continue
        if not isinstance(model, str):
            model = device_id
        candidates.append(IosDeviceCandidate(device_id=device_id, model=model))
    return candidates


def _is_ios_physical_device(entry: dict[str, Any]) -> bool:
    """判断 flutter devices 条目是否 iOS 物理真机(排除 simulator/emulator)。"""
    is_emulator = entry.get("emulator")
    if is_emulator is True:
        return False
    platform = str(entry.get("targetPlatform") or entry.get("platform") or "")
    if "ios" not in platform:
        return False
    # simulator 设备类别/id 形如 "iOS Simulator" / "ios-simulator"
    category = str(entry.get("category") or "")
    if "simulator" in category.lower():
        return False
    return True
