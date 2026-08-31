"""Unit tests for FileTokenProvider (R004-BF001).

Covers the 7 BF001-T scenarios from test §2:
  1. roundtrip-cross-instance: save → new instance get hits disk.
  2. 0600-permission: file mode == 0o600 after save.
  3. expired-past-future-Z-invalid: expiresAt four-state judgement.
  4. clear-deletes-row: clear_token rewrites file without the row.
  5. corrupt-fallback: invalid JSON → silent empty fallback.
  6. metadata-merge: metadata str values merged into the row.
  7. version-mismatch: version != 1 → silent empty fallback.

All tests use tmp_path — the real ~/.debug-control-plane/ is never touched.
"""

from __future__ import annotations

import json
import stat
from datetime import datetime, timedelta, timezone
from pathlib import Path

from debug_control_plane.mcp_plane.token_provider import FileTokenProvider


def _provider(tmp_path: Path) -> FileTokenProvider:
    return FileTokenProvider(path=tmp_path / "tokens.json")


def _write_raw(tmp_path: Path, payload: dict) -> Path:
    p = tmp_path / "tokens.json"
    p.write_text(json.dumps(payload), encoding="utf-8")
    return p


# ---------------------------------------------------------------------------
# 1. roundtrip-cross-instance
# ---------------------------------------------------------------------------

def test_roundtrip_cross_instance(tmp_path: Path) -> None:
    p1 = _provider(tmp_path)
    p1.save_token(
        "device-1",
        "dcp_tok_1",
        {"tokenId": "tid-1", "expiresAt": "2099-01-01T00:00:00+00:00"},
    )
    # A new instance must see the token (persistence, not memory).
    p2 = _provider(tmp_path)
    assert p2.get_token("device-1") == "dcp_tok_1"


# ---------------------------------------------------------------------------
# 2. 0600-permission
# ---------------------------------------------------------------------------

def test_file_mode_0600(tmp_path: Path) -> None:
    provider = _provider(tmp_path)
    provider.save_token("device-1", "dcp_tok_1", {"tokenId": "tid-1"})
    mode = stat.S_IMODE(provider._path.stat().st_mode)  # noqa: SLF001
    assert mode == 0o600


# ---------------------------------------------------------------------------
# 3. expired four states
# ---------------------------------------------------------------------------

def test_expired_past_returns_none(tmp_path: Path) -> None:
    past = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    provider = _provider(tmp_path)
    provider.save_token("d", "t", {"expiresAt": past})
    assert provider.get_token("d") is None


def test_not_expired_future(tmp_path: Path) -> None:
    future = (datetime.now(timezone.utc) + timedelta(days=6)).isoformat()
    provider = _provider(tmp_path)
    provider.save_token("d", "t", {"expiresAt": future})
    assert provider.get_token("d") == "t"


def test_not_expired_z_suffix(tmp_path: Path) -> None:
    future = (
        datetime.now(timezone.utc) + timedelta(days=6)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    provider = _provider(tmp_path)
    provider.save_token("d", "t", {"expiresAt": future})
    assert provider.get_token("d") == "t"


def test_invalid_expiresat_treated_as_not_expired(tmp_path: Path) -> None:
    provider = _provider(tmp_path)
    provider.save_token("d", "t", {"expiresAt": "not-a-date"})
    assert provider.get_token("d") == "t"


def test_naive_expiresat_treated_as_not_expired(tmp_path: Path) -> None:
    provider = _provider(tmp_path)
    provider.save_token("d", "t", {"expiresAt": "2099-01-01T00:00:00"})
    assert provider.get_token("d") == "t"


# ---------------------------------------------------------------------------
# 4. clear-deletes-row
# ---------------------------------------------------------------------------

def test_clear_deletes_row_on_disk(tmp_path: Path) -> None:
    provider = _provider(tmp_path)
    provider.save_token("d1", "t1", {"tokenId": "tid-1"})
    provider.save_token("d2", "t2", {"tokenId": "tid-2"})
    provider.clear_token("d1", reason="token_expired")
    assert provider.get_token("d1") is None
    assert provider.get_token("d2") == "t2"
    # A fresh instance sees the same on-disk state.
    assert _provider(tmp_path).get_token("d1") is None


def test_clear_missing_device_is_noop(tmp_path: Path) -> None:
    provider = _provider(tmp_path)
    provider.clear_token("ghost", reason="token_expired")  # must not raise
    assert provider.get_token("ghost") is None


# ---------------------------------------------------------------------------
# 5. corrupt-fallback
# ---------------------------------------------------------------------------

def test_corrupt_file_silent_fallback(tmp_path: Path) -> None:
    p = tmp_path / "tokens.json"
    p.write_text("{not valid json", encoding="utf-8")
    provider = FileTokenProvider(path=p)
    assert provider.get_token("d") is None  # no raise, empty
    # After a save the file becomes valid again (self-heal).
    provider.save_token("d", "t", {"tokenId": "tid"})
    assert json.loads(p.read_text(encoding="utf-8"))["version"] == 1


# ---------------------------------------------------------------------------
# 6. metadata-merge
# ---------------------------------------------------------------------------

def test_metadata_merged_into_row(tmp_path: Path) -> None:
    provider = _provider(tmp_path)
    provider.save_token("d", "t", {"tokenId": "tid-1", "expiresAt": "x", "count": 3})
    row = json.loads((tmp_path / "tokens.json").read_text(encoding="utf-8"))[
        "tokens"
    ]["d"]
    assert row["token"] == "t"
    assert row["tokenId"] == "tid-1"
    assert row["expiresAt"] == "x"
    # Non-str metadata values are stringified (schema keeps str values only).
    assert isinstance(row["count"], str)


# ---------------------------------------------------------------------------
# 7. version-mismatch
# ---------------------------------------------------------------------------

def test_version_mismatch_fallback(tmp_path: Path) -> None:
    _write_raw(
        tmp_path,
        {"version": 2, "tokens": {"d": {"token": "t", "tokenId": "tid"}}},
    )
    provider = _provider(tmp_path)
    assert provider.get_token("d") is None
    # Save under v1 schema after the fallback.
    provider.save_token("d", "t2", {})
    data = json.loads((tmp_path / "tokens.json").read_text(encoding="utf-8"))
    assert data["version"] == 1
    assert data["tokens"]["d"]["token"] == "t2"
