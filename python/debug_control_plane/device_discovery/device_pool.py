"""Unified device pool — recognize identity, not address (R020-BF001 / BF003).

Implements the "identity stable / IP ephemeral" contract:

  * **Persistent state** (devices.json): only ``{device_id, label, source, note?}``.
    IP-related fields are NEVER persisted. This is the core invariant (AC6).
  * **In-memory state**: ``last_known_host`` / ``last_seen`` / ``ttl`` plus the
    FF001 bridge fields (``hardware_name`` / ``machine_id``). Lost on process
    restart; re-discovered lazily via :meth:`DevicePool.resolve_ip`.

Design references:
  - backend §4.1 (DeviceRecord / DevicePool fields)
  - backend §4.3 (devices.json schema)
  - backend §5.3 (IP TTL re-discovery flow)
  - backend §6 D4 (mixed TTL + on-failure re-discovery) / D8 (reuse NetworkTarget)
    / D9 (device_id from USB identity, not /hello.deviceId)

``NetworkTarget`` (from ``.protocol``) is an OPTIONAL
runtime tag wrapped by ``DeviceRecord``. The core persistence/TTL logic does
NOT depend on it — ``NetworkTarget`` is imported lazily so this module works
standalone (no ``protocol`` loaded at runtime) for unit testing and reuse.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:  # pragma: no cover - typing only
    from .protocol import NetworkTarget


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: Schema version written to devices.json. Bump only on breaking schema change.
DEVICES_SCHEMA_VERSION = 1

#: Default IP cache TTL in seconds (backend D4). Within this window
#: ``resolve_ip`` returns the cached host directly; outside it, the caller
#: must re-discover via BF002 LanScan.
DEFAULT_TTL: float = 60.0


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class DeviceRecord:
    """A single device's identity + runtime IP state.

    Persistent (written to devices.json):
        ``device_id``, ``label``, ``source``, ``note``

    Memory-only (NEVER persisted; reset on restart):
        ``last_known_host``, ``last_seen``, ``ttl``,
        ``hardware_name``, ``machine_id``, ``platform``,
        ``network_target``

    The split enforces "identity stable / IP ephemeral" (backend §4.1, AC6):
    a device keeps its identity across IP changes (DHCP, WiFi switch), while
    the IP is always treated as a transient runtime fact.
    """

    device_id: str
    """Stable identity. USB serial (Android) / usbmuxd id (iOS) for auto-discovered
    devices; ``manual-<hash>`` (host-derived) for human-registered devices.
    Never sourced from ``/hello.deviceId`` (R019 fixed string, collides across
    devices — backend D9)."""

    label: str
    """Human-readable label (e.g. "Pixel 7 (工位A)")."""

    source: str
    """``"auto"`` (discovered via BF002 USB+LAN) or ``"manual"`` (human-registered)."""

    # --- memory-only IP state ---
    last_known_host: str | None = None
    """Last confirmed reachable host. Memory-only — re-discovered on restart."""
    last_seen: float | None = None
    """Unix timestamp of when ``last_known_host`` was last confirmed reachable."""
    ttl: float = DEFAULT_TTL
    """IP cache TTL in seconds (backend D4). Defaults to 60s."""

    # --- memory-only FF001 bridge fields (cross-identification, backend §4.1) ---
    hardware_name: str | None = None
    """Device hardware name (e.g. UIDevice.name / Build.MODEL). FF001 bridge field."""
    machine_id: str | None = None
    """Machine model id (e.g. "iPhone10,3"). FF001 bridge field."""
    platform: str = ""
    """``"android"`` / ``"ios"`` / etc. Informational, used for cross-identify."""

    # --- optional runtime tag ---
    network_target: NetworkTarget | None = field(default=None, repr=False)
    """Last ``/hello`` parsed target (``.protocol.NetworkTarget``).
    Runtime-only, never persisted. Used to expose capabilities / state to the
    MCP layer (BF001). ``None`` until first /hello probe."""

    note: str | None = None
    """Optional human annotation (only meaningful for source="manual").
    Persisted as part of identity (backend §4.3)."""

    def __post_init__(self) -> None:
        if self.source not in ("auto", "manual"):
            raise ValueError(
                f"DeviceRecord.source must be 'auto' or 'manual', got {self.source!r}"
            )

    def is_ip_fresh(self, *, now: float | None = None) -> bool:
        """Return True iff the cached IP is within its TTL window.

        A record with no ``last_known_host`` or no ``last_seen`` is never fresh
        — the caller must discover first.
        """
        if self.last_known_host is None or self.last_seen is None:
            return False
        current = time.time() if now is None else now
        return (self.last_seen + self.ttl) > current


@dataclass(frozen=True)
class ResolveResult:
    """Outcome of :meth:`DevicePool.resolve_ip`.

    Three orthogonal signals let the caller (BF002 LanScan / BridgeClient)
    decide what to do without guessing:

    * ``found``: whether ``device_id`` is known to the pool at all.
    * ``host``: the cached host (may be ``None`` if never discovered).
    * ``is_stale``: whether the caller MUST re-discover before using ``host``.
      ``True`` when the device is unknown, has no host, or its TTL has expired.
    """

    host: str | None
    is_stale: bool
    found: bool


# ---------------------------------------------------------------------------
# Pool
# ---------------------------------------------------------------------------


class DevicePool:
    """In-memory index of devices with identity-only persistence.

    The pool is the single meeting point of "stable identity" (``device_id``,
    persisted) and "ephemeral IP" (``last_known_host``, memory-only). Every
    capability operation in the MCP layer routes through here to translate a
    ``device_id`` into a current host (backend §3.4 / §5.3).

    Thread-safety: NOT thread-safe. The MCP server is single-threaded stdio;
    if concurrency is introduced later, wrap ``upsert``/``resolve_ip`` in a
    lock at the call site.
    """

    def __init__(self, persist_path: Path) -> None:
        self._persist_path: Path = persist_path
        self._store: dict[str, DeviceRecord] = {}
        self._load()

    # ------------------------------------------------------------------
    # Public read API
    # ------------------------------------------------------------------

    def get(self, device_id: str) -> DeviceRecord | None:
        """Return the record for ``device_id`` or ``None`` if unknown."""
        return self._store.get(device_id)

    def list_all(self) -> list[DeviceRecord]:
        """Return all known device records (insertion order)."""
        return list(self._store.values())

    def resolve_ip(self, device_id: str, *, now: float | None = None) -> ResolveResult:
        """Resolve ``device_id`` to a current host, applying the TTL policy.

        This method does NOT perform network/USB discovery — that is BF002
        LanScan's job. It only decides whether the cached host is still
        trustworthy:

          * Device unknown                 -> ``ResolveResult(None, True,  False)``
          * No host ever recorded          -> ``ResolveResult(None, True,  True)``
          * Host cached & within TTL       -> ``ResolveResult(host, False, True)``
          * Host cached but TTL expired    -> ``ResolveResult(host, True,  True)``

        When ``is_stale`` is True the caller MUST re-discover (BF002). The
        (possibly stale) ``host`` is returned for logging / fallback, but
        must not be trusted without reconfirmation.

        Args:
            device_id: stable device identity.
            now: optional override for ``time.time()`` (testing / clock injection).
        """
        rec = self._store.get(device_id)
        if rec is None:
            return ResolveResult(host=None, is_stale=True, found=False)
        if rec.is_ip_fresh(now=now):
            return ResolveResult(host=rec.last_known_host, is_stale=False, found=True)
        # Stale: cached host (if any) is informational; caller must re-discover.
        return ResolveResult(host=rec.last_known_host, is_stale=True, found=True)

    # ------------------------------------------------------------------
    # Public write API
    # ------------------------------------------------------------------

    def upsert(self, rec: DeviceRecord) -> None:
        """Insert or update ``rec`` in memory, then persist identity-only.

        Identity fields (``device_id``/``label``/``source``/``note``) are
        written through to devices.json. IP/bridge fields stay in memory and
        are NOT persisted — they are reconstructed on demand via
        :meth:`resolve_ip` + BF002.

        Updating an existing device_id replaces the whole record (memory state
        included); to preserve IP state across an identity-only refresh, read
        the existing record first and merge.
        """
        self._store[rec.device_id] = rec
        self._flush()

    def remove(self, device_id: str) -> bool:
        """Remove ``device_id`` from memory and persistence.

        Returns True if a device was removed, False if it was not present.
        """
        if device_id not in self._store:
            return False
        del self._store[device_id]
        self._flush()
        return True

    # ------------------------------------------------------------------
    # Persistence (identity-only — the core invariant)
    # ------------------------------------------------------------------

    def _load(self) -> None:
        """Load identity fields from devices.json.

        IP/bridge fields are intentionally NOT loaded — they remain at their
        dataclass defaults (``None``) and are populated lazily by BF002
        discovery / :meth:`resolve_ip`.

        Failures:
          * Missing file: empty pool (first run).
          * Corrupt JSON: ``ValueError`` (fail-fast; never silently drop data).
          * Wrong schema version: ``ValueError`` (explicit upgrade gate).
        """
        if not self._persist_path.exists():
            return
        try:
            raw = self._persist_path.read_text(encoding="utf-8")
        except OSError:
            # Unreadable file is treated as missing — caller can re-register.
            return
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError(
                f"devices.json at {self._persist_path} is corrupt: {exc}"
            ) from exc

        if not isinstance(data, dict):
            raise ValueError(
                f"devices.json at {self._persist_path}: expected object, got {type(data).__name__}"
            )

        version = data.get("version")
        if version != DEVICES_SCHEMA_VERSION:
            raise ValueError(
                f"devices.json schema version {version!r} unsupported "
                f"(expected {DEVICES_SCHEMA_VERSION}) at {self._persist_path}"
            )

        entries = data.get("devices", [])
        if not isinstance(entries, list):
            raise ValueError(
                f"devices.json 'devices' must be a list at {self._persist_path}"
            )

        for entry in entries:
            if not isinstance(entry, dict):
                continue
            device_id = entry.get("device_id")
            label = entry.get("label")
            source = entry.get("source")
            if not (isinstance(device_id, str) and isinstance(label, str)
                    and isinstance(source, str)):
                # Skip malformed entry rather than crash — but log nothing here
                # (no logger dependency); caller validates by list_all().
                continue
            note = entry.get("note") if isinstance(entry.get("note"), str) else None
            # Identity-only load: IP/bridge fields stay at their defaults.
            record = DeviceRecord(
                device_id=device_id,
                label=label,
                source=source,
                note=note,
            )
            self._store[device_id] = record

    def _flush(self) -> None:
        """Write identity-only state to devices.json.

        **Core invariant**: ONLY ``device_id`` / ``label`` / ``source`` /
        ``note`` are written. IP fields (``last_known_host`` / ``last_seen`` /
        ``ttl``) and bridge fields (``hardware_name`` / ``machine_id`` /
        ``platform`` / ``network_target``) MUST NEVER be persisted.

        The whole file is rewritten atomically (write to .tmp then replace)
        so a partial write never leaves a corrupt store.
        """
        devices: list[dict[str, Any]] = []
        for rec in self._store.values():
            entry: dict[str, Any] = {
                "device_id": rec.device_id,
                "label": rec.label,
                "source": rec.source,
            }
            if rec.note is not None:
                entry["note"] = rec.note
            devices.append(entry)

        payload = {"version": DEVICES_SCHEMA_VERSION, "devices": devices}

        # Atomic write: tmp file + os.replace.
        self._persist_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self._persist_path.with_suffix(self._persist_path.suffix + ".tmp")
        tmp_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        tmp_path.replace(self._persist_path)


# ---------------------------------------------------------------------------
# Convenience: derive a stable device_id from a manual host
# ---------------------------------------------------------------------------


def manual_device_id(host: str, *, _hash=None) -> str:
    """Derive a stable device_id for a manually-registered host.

    Per backend D9, manual entries use ``manual-<sha1(host)>`` so the same
    host re-registered yields the same id (idempotent upsert) without leaking
    the host into the identity string.

    The hash is SHA-1 truncated to 16 hex chars — collision-resistant for the
    small device counts in scope, and shorter than full SHA-1 for readability.
    """
    import hashlib

    digest = hashlib.sha1(host.encode("utf-8")).hexdigest()[:16]
    return f"manual-{digest}"


__all__ = [
    "DEFAULT_TTL",
    "DEVICES_SCHEMA_VERSION",
    "DevicePool",
    "DeviceRecord",
    "ResolveResult",
    "manual_device_id",
]
