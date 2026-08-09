"""DTO parsing for the App debug controller HTTP/SSE protocol."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

JsonMap = dict[str, Any]


def _string(data: JsonMap, key: str, default: str = "") -> str:
    value = data.get(key, default)
    return value if isinstance(value, str) else default


def _bool(data: JsonMap, key: str, default: bool = False) -> bool:
    value = data.get(key, default)
    return value if isinstance(value, bool) else default


def _int(data: JsonMap, key: str, default: int = 0) -> int:
    value = data.get(key, default)
    return value if isinstance(value, int) else default


def _strings(data: JsonMap, key: str) -> tuple[str, ...]:
    value = data.get(key, [])
    if not isinstance(value, list):
        return ()
    return tuple(item for item in value if isinstance(item, str) and item)


def _opt_string(data: JsonMap, key: str) -> str | None:
    """Optional string: returns None when key missing or value not a str.

    Used for R020 FF001 bridge fields (hardwareName/machineId) that older
    /hello responses may omit — backward compatible.
    """
    value = data.get(key)
    return value if isinstance(value, str) and value else None


def _opt_json_list(data: JsonMap, key: str) -> tuple[JsonMap, ...] | None:
    """Optional list-of-objects: returns None when key missing/invalid.

    Used for R020 FF002 ``registeredCapabilities`` — older /hello without
    FF001/FF002 returns None; valid array of objects returns a frozen tuple
    of dict copies (immutable snapshot). Non-list or non-object items are
    filtered; an explicitly empty array yields ``()`` (present-but-empty).
    """
    if key not in data:
        return None
    value = data.get(key)
    if not isinstance(value, list):
        return None
    items: list[JsonMap] = []
    for item in value:
        if isinstance(item, dict):
            items.append(dict(item))
    return tuple(items)


@dataclass(frozen=True)
class NetworkTarget:
    device_id: str
    device_name: str
    platform: str
    host: str
    port: int
    protocol_version: int
    capabilities: frozenset[str]
    active_source: str
    virtual_connected: bool
    profile_id: str | None
    real_controller_active: bool
    last_error: str | None
    profile_revision: int
    app: str = ""
    server_host: str = ""
    server_port: int = 0
    local_ips: tuple[str, ...] = ()
    events_endpoint: str = "/events"
    # --- R020 FF001/FF002 bridge fields (optional, backward compatible) ---
    # Older /hello responses omit these; they default to None so existing GUI
    # / R019 contract behavior is unchanged. Consumed by the MCP plane
    # BF005 LanCandidate / BF006 cross_identify for device disambiguation.
    hardware_name: str | None = None
    machine_id: str | None = None
    registered_capabilities: tuple[JsonMap, ...] | None = None

    @classmethod
    def from_hello(cls, data: JsonMap, *, host: str, port: int) -> NetworkTarget:
        capabilities = data.get("capabilities", [])
        if not isinstance(capabilities, list):
            capabilities = []
        profile_id = data.get("profileId")
        last_error = data.get("lastError")
        return cls(
            device_id=_string(data, "deviceId", f"{host}:{port}"),
            device_name=_string(data, "deviceName", f"{host}:{port}"),
            platform=_string(data, "platform", "unknown"),
            host=host,
            port=port,
            protocol_version=_int(data, "protocolVersion", 0),
            capabilities=frozenset(str(item) for item in capabilities),
            active_source=_string(data, "activeSource", "none"),
            virtual_connected=_bool(data, "virtualConnected"),
            profile_id=profile_id if isinstance(profile_id, str) else None,
            real_controller_active=_bool(data, "realControllerActive"),
            last_error=last_error if isinstance(last_error, str) else None,
            profile_revision=_int(data, "profileRevision", 0),
            app=_string(data, "app"),
            server_host=_string(data, "serverHost", host),
            server_port=_int(data, "serverPort", port),
            local_ips=_strings(data, "localIps"),
            events_endpoint=_string(data, "eventsEndpoint", "/events"),
            hardware_name=_opt_string(data, "hardwareName"),
            machine_id=_opt_string(data, "machineId"),
            registered_capabilities=_opt_json_list(data, "registeredCapabilities"),
        )


@dataclass(frozen=True)
class NetworkState:
    active_source: str
    virtual_connected: bool
    profile_id: str | None
    real_controller_active: bool
    last_error: str | None
    profile_revision: int

    @classmethod
    def from_json(cls, data: JsonMap) -> NetworkState:
        profile_id = data.get("profileId")
        last_error = data.get("lastError")
        return cls(
            active_source=_string(data, "activeSource", "none"),
            virtual_connected=_bool(data, "virtualConnected"),
            profile_id=profile_id if isinstance(profile_id, str) else None,
            real_controller_active=_bool(data, "realControllerActive"),
            last_error=last_error if isinstance(last_error, str) else None,
            profile_revision=_int(data, "profileRevision", 0),
        )


@dataclass(frozen=True)
class DebugEvent:
    event_type: str
    sequence: int
    active_source: str | None = None
    real_controller_active: bool | None = None
    virtual_connected: bool | None = None
    profile_id: str | None = None
    profile_revision: int | None = None
    error_code: str | None = None

    @classmethod
    def from_json(cls, data: JsonMap) -> DebugEvent:
        return cls(
            event_type=_string(data, "type", "unknown"),
            sequence=_int(data, "sequence", 0),
            active_source=data.get("activeSource") if isinstance(data.get("activeSource"), str) else None,
            real_controller_active=data.get("realControllerActive") if isinstance(data.get("realControllerActive"), bool) else None,
            virtual_connected=data.get("virtualConnected") if isinstance(data.get("virtualConnected"), bool) else None,
            profile_id=data.get("profileId") if isinstance(data.get("profileId"), str) else None,
            profile_revision=data.get("profileRevision") if isinstance(data.get("profileRevision"), int) else None,
            error_code=data.get("errorCode") if isinstance(data.get("errorCode"), str) else None,
        )


@dataclass(frozen=True)
class ControllerActionPayload:
    action_id: str
    display_label: str
    capabilities: frozenset[str]
    frame: JsonMap

    @classmethod
    def from_json(cls, action_id: str, data: JsonMap) -> ControllerActionPayload:
        capabilities = data.get("capabilities", [])
        if not isinstance(capabilities, list):
            capabilities = []
        frame = data.get("frame", {})
        if not isinstance(frame, dict):
            frame = {}
        return cls(
            action_id=_string(data, "actionId", action_id),
            display_label=_string(data, "displayLabel", action_id),
            capabilities=frozenset(str(item) for item in capabilities),
            frame=dict(frame),
        )


@dataclass(frozen=True)
class ControllerProfile:
    profile_id: str
    name: str
    platform: str
    connection_mode: str
    created_at: str
    actions: dict[str, ControllerActionPayload]

    @classmethod
    def from_json(cls, data: JsonMap) -> ControllerProfile:
        actions_raw = data.get("actions", {})
        actions: dict[str, ControllerActionPayload] = {}
        if isinstance(actions_raw, dict):
            for action_id, payload in actions_raw.items():
                if isinstance(action_id, str) and isinstance(payload, dict):
                    actions[action_id] = ControllerActionPayload.from_json(action_id, payload)
        return cls(
            profile_id=_string(data, "id"),
            name=_string(data, "name"),
            platform=_string(data, "platform"),
            connection_mode=_string(data, "connectionMode"),
            created_at=_string(data, "createdAt"),
            actions=actions,
        )


# ---------------------------------------------------------------------------
# AD-B9: DeviceUnreachable 下沉 (device_discovery 网络平面异常)
# ---------------------------------------------------------------------------
#: AD-B9: 网络平面异常 (设备不可达/设备池未识别 device_id)。直继承 ``Exception``,
#: 不继承 MCP 协议层 ``BridgeError`` 基类 —— 避免网络层反向依赖 mcp_plane。
#: BF006 + BF007 后, ``bridge_client.py`` 改为
#: ``from debug_control_plane.device_discovery.protocol import DeviceUnreachable``
#: 正向 import (单一真源)。
class DeviceUnreachable(Exception):
    """The device_id is unknown to the pool (连手机失败, 网络平面异常)."""
