"""R020-BF007 ManualRegistry 服务测试 (人工告知兜底通道).

AC 覆盖:
  AC5 register_device(host=192.168.1.34) → probe 成功 → 入池 source=manual
     → 可操作 (DevicePool.list_all 能查到, last_known_host 已填, label 默认 host)
  analysis L3 probe 失败 → 不入池 (返回 DeviceUnreachable / None, 池为空)
  D9 守护 — device_id 派生 manual-<sha1(host)[:16]>, 绝不读 /hello.deviceId
     (R019 固定字符串 gmacro-virtual-iOS 多设备冲突)

设计来源:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF007 节 (行 472-497)
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
            §3.4 ManualRegistry / §4.3 devices.json / §4.2.1 register_device tool
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1

注意: ManualRegistry 复用 BF005 endpoint.probe_hello (单点 probe, D8 零重写);
      device_id 复用 BF001 manual_device_id helper (host-derived sha1, 不读
      /hello.deviceId); 失败不污染池 (probe 返 None → 不 upsert).
"""

from __future__ import annotations

import json
from io import BytesIO
from pathlib import Path

import pytest

from debug_control_plane.device_discovery.device_pool import DevicePool, manual_device_id
from debug_control_plane.device_discovery.discovery.lan_scan import LanScan
from debug_control_plane.device_discovery.discovery.manual_registry import (
    DEFAULT_PROBE_TIMEOUT,
    ManualRegistry,
    RegisterResult,
)

# AD-B9: DeviceUnreachable 已下沉 device_discovery.protocol(BF006),
# 不再从 bridge_client import(mcp_plane 反向依赖断开)。
from debug_control_plane.device_discovery.protocol import DeviceUnreachable

# ---------------------------------------------------------------------------
# Mock helpers — 复用 BF005 _FakeResponse 风格 (urllib 签名 + BytesIO).
# ---------------------------------------------------------------------------


class _FakeResponse:
    """urllib HTTP 响应替身 (支持 context manager + read)."""

    def __init__(self, body: bytes, status: int = 200) -> None:
        self._buf = BytesIO(body)
        self.status = status

    def __enter__(self) -> _FakeResponse:
        return self

    def __exit__(self, *exc) -> None:
        self._buf.close()

    def read(self) -> bytes:
        return self._buf.getvalue()


def make_urlopen(body_by_host: dict[str, bytes | Exception] | bytes | Exception):
    """构造 mock urlopen, 按 host 返不同 body (或固定 body/Exception).

    与 test_discovery_lan_scan.make_urlopen 同形, 故意独立保留以避免跨文件
    fixture 耦合 (BF005 测试也是各自独立).
    """

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


def _hello_body(
    *,
    device_id: str = "gmacro-virtual-iOS",
    device_name: str = "iPhone X",
    hardware_name: str | None = "iPhone X",
    machine_id: str | None = "iPhone10,3",
    platform: str = "ios",
) -> bytes:
    """构造 /hello JSON body (R019 + FF001/FF002 扩展字段)."""
    payload: dict = {
        "deviceId": device_id,
        "deviceName": device_name,
        "platform": platform,
        "protocolVersion": 2,
        "capabilities": ["virtual", "state", "events"],
        "activeSource": "none",
        "virtualConnected": False,
        "realControllerActive": False,
        "profileRevision": 0,
    }
    if hardware_name is not None:
        payload["hardwareName"] = hardware_name
    if machine_id is not None:
        payload["machineId"] = machine_id
    return json.dumps(payload).encode("utf-8")


@pytest.fixture
def pool(tmp_path: Path) -> DevicePool:
    """空 DevicePool, 持久化到 tmp_path/devices.json."""
    return DevicePool(tmp_path / "devices.json")


@pytest.fixture
def lan_scan() -> LanScan:
    """LanScan 实例 (ManualRegistry 注入但 register 不调 scan, 仅满足骨架)."""
    # VpnImmune 真实实例 (register 不会调 lan_cidr), 测试只验 register 路径.
    from debug_control_plane.device_discovery.discovery.vpn_immune import VpnImmune

    return LanScan(VpnImmune())


# ---------------------------------------------------------------------------
# AC5: probe 成功 → 入池 source=manual → 可操作
# ---------------------------------------------------------------------------


class TestRegisterSuccess:
    """probe /hello 成功 → DeviceRecord 入池, source=manual, 可被 list_all 查到."""

    def test_register_returns_record_with_manual_source(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        urlopen = make_urlopen({"192.168.1.34": _hello_body()})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        result = registry.register("192.168.1.34")

        assert isinstance(result, RegisterResult)
        assert result.ok is True
        assert result.record is not None
        assert result.record.source == "manual"

    def test_register_persists_to_pool(self, pool: DevicePool, lan_scan: LanScan) -> None:
        urlopen = make_urlopen({"192.168.1.34": _hello_body()})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34")

        records = pool.list_all()
        assert len(records) == 1
        rec = records[0]
        assert rec.source == "manual"
        assert rec.last_known_host == "192.168.1.34"
        assert rec.last_seen is not None  # probe 成功即填时间戳

    def test_register_label_defaults_to_host_when_none(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        urlopen = make_urlopen({"192.168.1.34": _hello_body()})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34")

        rec = pool.list_all()[0]
        assert rec.label == "192.168.1.34"

    def test_register_label_user_supplied_takes_priority(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        urlopen = make_urlopen({"192.168.1.34": _hello_body()})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34", label="工位A iPhone")

        rec = pool.list_all()[0]
        assert rec.label == "工位A iPhone"

    def test_register_fills_runtime_bridge_fields(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        """probe 拿到的 hardwareName/machineId/platform 填进 DeviceRecord 内存态."""
        urlopen = make_urlopen({"192.168.1.34": _hello_body()})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34")

        rec = pool.list_all()[0]
        assert rec.hardware_name == "iPhone X"
        assert rec.machine_id == "iPhone10,3"
        assert rec.platform == "ios"

    def test_register_idempotent_upsert_same_host(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        """同 host 二次 register → 同 device_id, 池中仍 1 条 (upsert 不增)."""
        urlopen = make_urlopen({"192.168.1.34": _hello_body()})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34", label="第一次")
        registry.register("192.168.1.34", label="第二次")

        records = pool.list_all()
        assert len(records) == 1
        assert records[0].label == "第二次"

    def test_register_custom_port_used_in_probe(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        """port 参数透传到 probe URL (默认 18080, 可覆盖)."""
        probed_urls: list[str] = []

        def urlopen(request, timeout):  # noqa: ANN001
            probed_urls.append(request.full_url)
            return _FakeResponse(_hello_body())

        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34", port=9999)

        assert any(":9999/" in url for url in probed_urls)


# ---------------------------------------------------------------------------
# D9 守护: device_id 派生 manual-<sha1(host)[:16]>, 绝不读 /hello.deviceId
# ---------------------------------------------------------------------------


class TestDeviceIdDerivation:
    """device_id 必须是 manual-<sha1(host)[:16]>, 与 /hello.deviceId 无关.

    红线: R019 /hello.deviceId 是固定字符串 'gmacro-virtual-iOS', 多设备冲突
    (memory D9 + BF001 manual_device_id helper 注释). ManualRegistry 必须用
    host 派生, 不能透传 /hello.deviceId.
    """

    def test_device_id_is_manual_prefixed_hash_of_host(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        urlopen = make_urlopen({"192.168.1.34": _hello_body()})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34")

        rec = pool.list_all()[0]
        assert rec.device_id == manual_device_id("192.168.1.34")
        assert rec.device_id.startswith("manual-")

    def test_device_id_never_uses_hello_device_id(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        """/hello.deviceId='gmacro-virtual-iOS' 绝不能出现在 device_id 里."""
        urlopen = make_urlopen(
            {"192.168.1.34": _hello_body(device_id="gmacro-virtual-iOS")}
        )
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34")

        rec = pool.list_all()[0]
        assert "gmacro" not in rec.device_id
        assert "virtual-iOS" not in rec.device_id
        assert rec.device_id != "gmacro-virtual-iOS"

    def test_two_hosts_produce_distinct_device_ids(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        """两个不同 host → 两个不同 device_id (多设备场景)."""
        urlopen = make_urlopen(
            {
                "192.168.1.34": _hello_body(device_name="iPhone X"),
                "192.168.1.50": _hello_body(device_name="Pixel 7"),
            }
        )
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34")
        registry.register("192.168.1.50")

        records = pool.list_all()
        assert len(records) == 2
        ids = {r.device_id for r in records}
        assert len(ids) == 2
        assert all(i.startswith("manual-") for i in ids)


# ---------------------------------------------------------------------------
# analysis L3: probe 失败 → 不入池
# ---------------------------------------------------------------------------


class TestProbeFailureNoPollution:
    """probe 失败 (超时/拒绝/JSON 错) → 池保持空, 返回 unreachable 结果."""

    def test_probe_connection_refused_no_upsert(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        import urllib.error

        urlopen = make_urlopen({"192.168.1.34": urllib.error.URLError("refused")})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        result = registry.register("192.168.1.34")

        assert result.ok is False
        assert result.record is None
        assert isinstance(result.error, DeviceUnreachable)
        assert pool.list_all() == []

    def test_probe_timeout_no_upsert(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        urlopen = make_urlopen({"192.168.1.34": TimeoutError("probe timed out")})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        result = registry.register("192.168.1.34")

        assert result.ok is False
        assert result.record is None
        assert pool.list_all() == []

    def test_probe_invalid_json_no_upsert(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        urlopen = make_urlopen({"192.168.1.34": b"not-json-at-all"})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        result = registry.register("192.168.1.34")

        assert result.ok is False
        assert pool.list_all() == []

    def test_probe_non_object_json_no_upsert(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        """/hello 返合法 JSON 但非 object (list/str) → probe_hello 返 None."""
        urlopen = make_urlopen({"192.168.1.34": b'["not", "an", "object"]'})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        result = registry.register("192.168.1.34")

        assert result.ok is False
        assert pool.list_all() == []

    def test_probe_failure_does_not_touch_pool(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        """失败后 devices.json 不应被创建 (或为空)."""
        urlopen = make_urlopen({"192.168.1.34": OSError("down")})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34")

        # pool 内部 _store 为空 (无 upsert 发生)
        assert pool.list_all() == []
        # 持久化文件可能不存在 (DevicePool 不预写空池)
        # 或存在但 devices 列表为空 — 两者都合规


# ---------------------------------------------------------------------------
# 异常容忍: probe 抛非预期异常也不崩
# ---------------------------------------------------------------------------


class TestExceptionTolerance:
    """ManualRegistry 永不向调用者抛未捕获异常 (与 BF003/BF005/BF008 同模式)."""

    def test_unexpected_exception_returns_unreachable(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        """probe 抛 RuntimeError 等非 OSError → 仍返 unreachable, 不崩."""

        def urlopen(request, timeout):  # noqa: ANN001
            raise RuntimeError("unexpected boom")

        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        result = registry.register("192.168.1.34")

        assert result.ok is False
        assert isinstance(result.error, DeviceUnreachable)
        assert pool.list_all() == []

    def test_register_returns_result_not_raises(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        urlopen = make_urlopen({"192.168.1.34": OSError("net down")})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        # 不应抛 — register 必须返 RegisterResult
        result = registry.register("192.168.1.34")
        assert result is not None


# ---------------------------------------------------------------------------
# BF007.3: 经 DevicePool 持久化 (devices.json identity-only)
# ---------------------------------------------------------------------------


class TestPersistenceDelegation:
    """BF007 不直接写 devices.json, 全部经 DevicePool.upsert (BF001.3 只存身份)."""

    def test_register_persists_identity_only(
        self, tmp_path: Path, lan_scan: LanScan
    ) -> None:
        """devices.json 只存 device_id/label/source/note, 不存 IP/hardware."""
        persist_path = tmp_path / "devices.json"
        pool = DevicePool(persist_path)
        urlopen = make_urlopen({"192.168.1.34": _hello_body()})
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34", label="工位A", note="测试机")

        # 文件已写
        assert persist_path.exists()
        raw = json.loads(persist_path.read_text(encoding="utf-8"))
        assert raw["version"] == 1
        devices = raw["devices"]
        assert len(devices) == 1
        entry = devices[0]
        # identity-only: 只这四个键 (note 可选)
        assert set(entry.keys()) <= {"device_id", "label", "source", "note"}
        assert entry["source"] == "manual"
        assert entry["label"] == "工位A"
        # IP/hardware 绝不持久化 (BF001.3 核心不变式)
        assert "last_known_host" not in entry
        assert "hardware_name" not in entry

    def test_reload_pool_keeps_manual_identity(
        self, tmp_path: Path, lan_scan: LanScan
    ) -> None:
        """重启 (重载 DevicePool) → manual 设备身份仍在, IP 丢失 (内存态)."""
        persist_path = tmp_path / "devices.json"
        pool1 = DevicePool(persist_path)
        urlopen = make_urlopen({"192.168.1.34": _hello_body()})
        registry1 = ManualRegistry(pool1, lan_scan, urlopen=urlopen)
        registry1.register("192.168.1.34", label="工位A")

        # 模拟重启: 新建 DevicePool 读同一文件
        pool2 = DevicePool(persist_path)
        records = pool2.list_all()
        assert len(records) == 1
        rec = records[0]
        assert rec.device_id == manual_device_id("192.168.1.34")
        assert rec.label == "工位A"
        assert rec.source == "manual"
        # IP/bridge 字段重置 (内存态, BF001.3)
        assert rec.last_known_host is None
        assert rec.hardware_name is None


# ---------------------------------------------------------------------------
# 边界: 老 /hello 无 FF001 字段 (向后兼容)
# ---------------------------------------------------------------------------


class TestBackwardCompatOldHello:
    """老 /hello 响应无 hardwareName/machineId → 字段 None, 但仍入池."""

    def test_old_hello_without_bridge_fields_still_registers(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        urlopen = make_urlopen(
            {"192.168.1.34": _hello_body(hardware_name=None, machine_id=None)}
        )
        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)

        registry.register("192.168.1.34")

        rec = pool.list_all()[0]
        assert rec.source == "manual"
        assert rec.hardware_name is None
        assert rec.machine_id is None
        # device_id 仍 host-derived (不依赖 hardwareName)
        assert rec.device_id == manual_device_id("192.168.1.34")


# ---------------------------------------------------------------------------
# 默认值与构造
# ---------------------------------------------------------------------------


class TestDefaults:
    def test_default_port_is_18080(self, pool: DevicePool, lan_scan: LanScan) -> None:
        assert ManualRegistry(pool, lan_scan)._port == 18080

    def test_default_probe_timeout(
        self, pool: DevicePool, lan_scan: LanScan
    ) -> None:
        assert ManualRegistry(pool, lan_scan)._probe_timeout == DEFAULT_PROBE_TIMEOUT

    def test_endpoint_used_for_probe(self, pool: DevicePool, lan_scan: LanScan) -> None:
        """register 内部构造 Endpoint(host, port) — 间接验经 probed URL."""
        captured: list[str] = []

        def urlopen(request, timeout):  # noqa: ANN001
            captured.append(request.full_url)
            return _FakeResponse(_hello_body())

        registry = ManualRegistry(pool, lan_scan, urlopen=urlopen)
        registry.register("10.0.0.5", port=18080)

        assert captured, "probe should have been called"
        assert "10.0.0.5" in captured[0]
        assert ":18080/hello" in captured[0]
