"""Unit tests for DevicePool/DeviceRecord (R020-BF001).

Covers the three BF003 scenarios from test §2.1:
  1. Persistence stores identity only (no IP).
  2. TTL cache: in-window direct return; expired -> stale marker.
  3. IP change -> re-discovery handoff.

Plus AC12 (multi-device no cross-talk) and AC6 (restart keeps identity, loses IP).

All tests are pure-logic: no network, no USB, no subprocess. Each test uses
pytest's tmp_path to isolate the devices.json store.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

from debug_control_plane.device_discovery.device_pool import (
    DEFAULT_TTL,
    DevicePool,
    DeviceRecord,
    ResolveResult,
)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def pool(tmp_path: Path) -> DevicePool:
    """A DevicePool backed by an isolated tmp devices.json."""
    return DevicePool(persist_path=tmp_path / "devices.json")


def _record(
    device_id: str = "android-abcdef01",
    *,
    label: str = "Pixel 7",
    source: str = "auto",
    host: str | None = "192.168.1.34",
    last_seen: float | None = None,
    ttl: float = DEFAULT_TTL,
    hardware_name: str | None = "Pixel 7",
    machine_id: str | None = "Pixel7-pro",
    platform: str = "android",
) -> DeviceRecord:
    return DeviceRecord(
        device_id=device_id,
        label=label,
        source=source,
        last_known_host=host,
        last_seen=last_seen,
        ttl=ttl,
        hardware_name=hardware_name,
        machine_id=machine_id,
        platform=platform,
    )


# ---------------------------------------------------------------------------
# Scenario 1: Persistence stores identity only (no IP) — AC6 / test §2.1 row 1
# ---------------------------------------------------------------------------


def test_persist_only_identity(pool: DevicePool, tmp_path: Path) -> None:
    """upsert a record WITH IP fields -> flush -> JSON contains ONLY identity."""
    pool.upsert(_record(host="192.168.1.34", last_seen=time.time()))

    raw = (tmp_path / "devices.json").read_text(encoding="utf-8")

    # Hard invariants: IP-related fields must NEVER be persisted.
    assert "last_known_host" not in raw, (
        f"persisted JSON must not contain last_known_host, got: {raw}"
    )
    assert "last_seen" not in raw, (
        f"persisted JSON must not contain last_seen, got: {raw}"
    )
    assert "ttl" not in raw, (
        f"persisted JSON must not contain ttl, got: {raw}"
    )

    data = json.loads(raw)
    assert data["version"] == 1
    assert len(data["devices"]) == 1
    entry = data["devices"][0]
    assert entry["device_id"] == "android-abcdef01"
    assert entry["label"] == "Pixel 7"
    assert entry["source"] == "auto"
    # Identity keys are the ONLY allowed keys.
    allowed = {"device_id", "label", "source", "note"}
    assert set(entry.keys()).issubset(allowed), (
        f"persisted entry has unexpected keys: {set(entry.keys()) - allowed}"
    )


def test_persist_manual_source_preserves_note(pool: DevicePool, tmp_path: Path) -> None:
    """Manual entries may carry a human note (per backend §4.3 schema)."""
    rec = DeviceRecord(
        device_id="manual-deadbeef",
        label="iPhone X (小明)",
        source="manual",
        note="工位 B 的测试机",
    )
    pool.upsert(rec)

    data = json.loads((tmp_path / "devices.json").read_text(encoding="utf-8"))
    assert data["devices"][0]["note"] == "工位 B 的测试机"


# ---------------------------------------------------------------------------
# Scenario 2: TTL cache — AC7 / test §2.1 row 2
# ---------------------------------------------------------------------------


def test_resolve_ip_within_ttl_returns_host(pool: DevicePool) -> None:
    """last_seen + ttl > now -> resolve_ip returns host, is_stale=False."""
    now = time.time()
    pool.upsert(_record(host="192.168.1.34", last_seen=now, ttl=60.0))

    result = pool.resolve_ip("android-abcdef01")

    assert isinstance(result, ResolveResult)
    assert result.host == "192.168.1.34"
    assert result.is_stale is False


def test_resolve_ip_expired_marks_stale(pool: DevicePool) -> None:
    """last_seen + ttl <= now -> resolve_ip returns stale marker (is_stale=True)."""
    now = time.time()
    # last_seen well past TTL window.
    pool.upsert(_record(host="192.168.1.34", last_seen=now - 120.0, ttl=60.0))

    result = pool.resolve_ip("android-abcdef01")

    assert isinstance(result, ResolveResult)
    # Stale: caller (BF002 LanScan) must re-discover. Host may still be the old
    # value (informational) but is_stale=True is the authoritative signal.
    assert result.is_stale is True
    assert result.host == "192.168.1.34"


def test_resolve_ip_unknown_device_returns_not_found(pool: DevicePool) -> None:
    """device_id not in pool -> ResolveResult(host=None, is_stale=True, found=False)."""
    result = pool.resolve_ip("does-not-exist")

    assert isinstance(result, ResolveResult)
    assert result.host is None
    assert result.is_stale is True
    assert result.found is False


def test_resolve_ip_no_known_host_marks_stale(pool: DevicePool) -> None:
    """Record exists but last_known_host is None -> must be (re-)discovered."""
    pool.upsert(_record(host=None, last_seen=time.time()))

    result = pool.resolve_ip("android-abcdef01")

    assert result.host is None
    assert result.is_stale is True


# ---------------------------------------------------------------------------
# Scenario 3: Restart keeps identity, loses IP — AC6 / test §2.1 row 1
# ---------------------------------------------------------------------------


def test_restart_identity_lost_ip(tmp_path: Path) -> None:
    """Simulate process restart: new DevicePool loads identity, IP fields empty."""
    persist = tmp_path / "devices.json"

    # First "process": write a record with full runtime state.
    p1 = DevicePool(persist_path=persist)
    p1.upsert(_record(host="192.168.1.34", last_seen=time.time(), hardware_name="X", machine_id="Y"))

    # Second "process": brand-new pool reads the same file.
    p2 = DevicePool(persist_path=persist)
    rec = p2.get("android-abcdef01")

    assert rec is not None
    # Identity survived.
    assert rec.device_id == "android-abcdef01"
    assert rec.label == "Pixel 7"
    assert rec.source == "auto"
    # IP fields did NOT survive (memory-only).
    assert rec.last_known_host is None
    assert rec.last_seen is None
    # TTL keeps its default (config survives, not a secret).
    assert rec.ttl == DEFAULT_TTL
    # FF001 bridge fields also reset (not persisted).
    assert rec.hardware_name is None
    assert rec.machine_id is None


def test_load_missing_file_is_empty_pool(tmp_path: Path) -> None:
    """First run: no devices.json -> empty pool, no crash."""
    pool = DevicePool(persist_path=tmp_path / "nonexistent.json")
    assert pool.list_all() == []


def test_load_unreadable_file_is_empty_pool(tmp_path: Path) -> None:
    """File exists but unreadable (e.g. permission denied) -> treated as missing.

    Covers the OSError branch in _load: an unreadable store must not crash the
    pool — the caller can re-register devices. This locks the contract that
    only "missing OR unreadable" both degrade to empty, while corrupt JSON
    (test_load_corrupt_file_raises) fails fast.
    """
    persist = tmp_path / "devices.json"
    persist.write_text(
        json.dumps({"version": 1, "devices": []}), encoding="utf-8"
    )
    persist.chmod(0o000)  # strip all permissions -> read() raises PermissionError
    try:
        pool = DevicePool(persist_path=persist)
        assert pool.list_all() == []
    finally:
        # Restore so tmp_path cleanup can remove the file (Windows/test CI).
        persist.chmod(0o644)


def test_load_corrupt_file_raises(tmp_path: Path) -> None:
    """Corrupt JSON -> ValueError (fail-fast, do not silently lose devices)."""
    persist = tmp_path / "devices.json"
    persist.write_text("{ not valid json", encoding="utf-8")
    with pytest.raises(ValueError):
        DevicePool(persist_path=persist)


def test_load_wrong_version_raises(tmp_path: Path) -> None:
    """Schema version mismatch -> ValueError (explicit upgrade gate)."""
    persist = tmp_path / "devices.json"
    persist.write_text(
        json.dumps({"version": 999, "devices": []}), encoding="utf-8"
    )
    with pytest.raises(ValueError):
        DevicePool(persist_path=persist)


# ---------------------------------------------------------------------------
# AC12: Multi-device no cross-talk
# ---------------------------------------------------------------------------


def test_multi_device_no_cross_talk(pool: DevicePool) -> None:
    """Two devices in the same pool: each device_id independent, ops targeted."""
    rec_a = _record(device_id="android-aaa", host="10.0.0.1", last_seen=time.time())
    rec_b = _record(device_id="ios-bbb", host="10.0.0.2", last_seen=time.time())
    pool.upsert(rec_a)
    pool.upsert(rec_b)

    assert {r.device_id for r in pool.list_all()} == {"android-aaa", "ios-bbb"}

    # Targeted get: each id returns its own record, not the other's.
    assert pool.get("android-aaa").last_known_host == "10.0.0.1"
    assert pool.get("ios-bbb").last_known_host == "10.0.0.2"

    # Targeted resolve: returns each device's own host.
    assert pool.resolve_ip("android-aaa").host == "10.0.0.1"
    assert pool.resolve_ip("ios-bbb").host == "10.0.0.2"

    # Updating one does not corrupt the other.
    pool.upsert(_record(device_id="android-aaa", host="10.0.0.99", last_seen=time.time()))
    assert pool.get("android-aaa").last_known_host == "10.0.0.99"
    assert pool.get("ios-bbb").last_known_host == "10.0.0.2"  # untouched


def test_upsert_replaces_same_id(pool: DevicePool) -> None:
    """upsert on existing device_id replaces (not appends)."""
    pool.upsert(_record(device_id="X", label="old"))
    pool.upsert(_record(device_id="X", label="new", host="1.2.3.4", last_seen=time.time()))

    rec = pool.get("X")
    assert rec.label == "new"
    assert rec.last_known_host == "1.2.3.4"
    assert len(pool.list_all()) == 1


# ---------------------------------------------------------------------------
# Edge: flush is idempotent + atomic-ish (rewrite whole file each upsert)
# ---------------------------------------------------------------------------


def test_remove_device(pool: DevicePool, tmp_path: Path) -> None:
    """Removing a device drops it from both memory and persistence."""
    pool.upsert(_record(device_id="gone"))
    assert pool.get("gone") is not None

    removed = pool.remove("gone")
    assert removed is True
    assert pool.get("gone") is None

    data = json.loads((tmp_path / "devices.json").read_text(encoding="utf-8"))
    assert all(d["device_id"] != "gone" for d in data["devices"])


def test_remove_unknown_returns_false(pool: DevicePool) -> None:
    assert pool.remove("never-was") is False


# ---------------------------------------------------------------------------
# Defensive contracts
# ---------------------------------------------------------------------------


def test_device_record_rejects_invalid_source() -> None:
    """source must be 'auto' or 'manual' — typo / future values fail fast."""
    with pytest.raises(ValueError):
        DeviceRecord(device_id="x", label="y", source="bogus")


def test_manual_device_id_is_stable_and_host_redacted() -> None:
    """Same host -> same id; id does NOT embed the raw host (privacy / D9)."""
    from debug_control_plane.device_discovery.device_pool import manual_device_id

    a = manual_device_id("192.168.1.34")
    b = manual_device_id("192.168.1.34")
    c = manual_device_id("10.0.0.5")

    assert a == b, "same host must yield same id (idempotent upsert)"
    assert a != c, "different hosts must yield different ids"
    assert "192.168.1.34" not in a, "id must not embed the raw host"
    assert a.startswith("manual-"), "manual id prefix per backend D9"


def test_load_skips_malformed_entry_keeps_valid_ones(tmp_path: Path) -> None:
    """A single malformed entry must not poison the whole pool."""
    persist = tmp_path / "devices.json"
    persist.write_text(
        json.dumps(
            {
                "version": 1,
                "devices": [
                    {"device_id": "good-1", "label": "G1", "source": "auto"},
                    {"device_id": 123, "label": "bad-id-type", "source": "auto"},
                    {"label": "missing-id", "source": "auto"},
                    {"device_id": "good-2", "label": "G2", "source": "manual",
                     "note": "ok"},
                ],
            }
        ),
        encoding="utf-8",
    )
    pool = DevicePool(persist_path=persist)
    ids = {r.device_id for r in pool.list_all()}
    assert ids == {"good-1", "good-2"}
    assert pool.get("good-2").note == "ok"


def test_load_non_object_payload_raises(tmp_path: Path) -> None:
    """Top-level JSON array / number is a schema violation."""
    persist = tmp_path / "devices.json"
    persist.write_text(json.dumps([1, 2, 3]), encoding="utf-8")
    with pytest.raises(ValueError):
        DevicePool(persist_path=persist)


def test_load_devices_not_list_raises(tmp_path: Path) -> None:
    persist = tmp_path / "devices.json"
    persist.write_text(
        json.dumps({"version": 1, "devices": {"not": "a list"}}),
        encoding="utf-8",
    )
    with pytest.raises(ValueError):
        DevicePool(persist_path=persist)


def test_resolve_ip_with_injected_clock(pool: DevicePool) -> None:
    """resolve_ip accepts a `now` override for deterministic TTL tests."""
    pool.upsert(_record(host="1.1.1.1", last_seen=1000.0, ttl=60.0))
    # now=1050 -> within TTL (1000+60=1060 > 1050)
    fresh = pool.resolve_ip("android-abcdef01", now=1050.0)
    assert fresh.is_stale is False
    assert fresh.host == "1.1.1.1"
    # now=1100 -> expired
    stale = pool.resolve_ip("android-abcdef01", now=1100.0)
    assert stale.is_stale is True


def test_persistence_file_is_atomically_rewritten(tmp_path: Path) -> None:
    """No .tmp file is left behind after upsert (atomic replace)."""
    pool = DevicePool(persist_path=tmp_path / "devices.json")
    pool.upsert(_record(device_id="X"))
    assert not (tmp_path / "devices.json.tmp").exists()
    assert (tmp_path / "devices.json").exists()
