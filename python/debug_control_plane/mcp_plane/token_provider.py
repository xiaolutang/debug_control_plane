"""File-backed debug auth token provider (R004-BF001).

FileTokenProvider is the production implementation of
:class:`debug_control_plane.mcp_plane.bridge_client.DebugAuthTokenProvider`.
It persists per-device bearer tokens to ``~/.debug-control-plane/tokens.json``
so tokens survive python process restarts (design R004 §3.2).

Schema (independent from devices.json — no shared structure or imports)::

    {"version": 1, "tokens": {device_id: {"token": ..., "tokenId": ...,
                                           "expiresAt": ...}}}

Concurrency model: lazy-loaded, single-threaded. This provider assumes it is
only used from the asyncio event-loop thread (the MCP server's threading
model). No locking is performed — the design explicitly accepted this
asyncio-single-thread assumption.

Security: plaintext tokens on the developer machine with 0600 permissions
(user-approved decision). The 0600 mode is guaranteed by creating the tmp
file via ``os.open(..., 0o600)`` (bypassing umask, so no 0644 window exists)
followed by an atomic ``os.replace``.

Corruption policy: a corrupt file or an unknown ``version`` silently falls
back to an empty store — tokens are regenerable and the server must not
crash on load.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

_SCHEMA_VERSION = 1
_DEFAULT_PATH = Path.home() / ".debug-control-plane" / "tokens.json"


def _is_expired(value: str) -> bool:
    """Return True if ``value`` is a tz-aware ISO timestamp in the past.

    Parse failures and naive timestamps are treated as *not* expired: the
    phone's 401 is the final arbiter, and a parsing bug must not break the
    auth chain (design §5). Evaluated at read time; never written back.
    """
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return False
    if parsed.tzinfo is None:
        return False
    return parsed <= datetime.now(timezone.utc)


class FileTokenProvider:
    """File-backed token store implementing the DebugAuthTokenProvider protocol."""

    def __init__(self, path: Path | None = None) -> None:
        self._path = path or _DEFAULT_PATH
        self._loaded = False
        self._tokens: dict[str, dict[str, str]] = {}

    # ------------------------------------------------------------------
    # Protocol surface
    # ------------------------------------------------------------------

    def get_token(self, device_id: str) -> str | None:
        """Return the stored token for ``device_id`` if present and unexpired."""
        self._ensure_loaded()
        row = self._tokens.get(device_id)
        if row is None:
            return None
        expires_at = row.get("expiresAt", "")
        if expires_at and _is_expired(expires_at):
            return None
        return row.get("token")

    def save_token(
        self, device_id: str, token: str, metadata: Mapping[str, Any]
    ) -> None:
        """Store ``token`` for ``device_id`` and persist (full file rewrite)."""
        self._ensure_loaded()
        row: dict[str, str] = {"token": token}
        for key, value in metadata.items():
            row[key] = value if isinstance(value, str) else str(value)
        self._tokens[device_id] = row
        self._flush()

    def clear_token(self, device_id: str, reason: str) -> None:
        """Drop the row for ``device_id`` and persist (rewrite without it)."""
        self._ensure_loaded()
        if device_id in self._tokens:
            del self._tokens[device_id]
            self._flush()

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _ensure_loaded(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return  # missing or corrupt → silent empty fallback
        if not isinstance(data, dict) or data.get("version") != _SCHEMA_VERSION:
            return  # unknown schema → silent empty fallback
        tokens = data.get("tokens")
        if not isinstance(tokens, dict):
            return
        self._tokens = {
            device_id: row
            for device_id, row in tokens.items()
            if isinstance(row, dict)
        }

    def _flush(self) -> None:
        """Atomically write the store with 0600 permissions."""
        payload = json.dumps(
            {"version": _SCHEMA_VERSION, "tokens": self._tokens},
            indent=2,
            ensure_ascii=False,
        )
        self._path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self._path.with_name(self._path.name + ".tmp")
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(payload)
                f.flush()
                os.fsync(f.fileno())
        except BaseException:
            tmp_path.unlink(missing_ok=True)
            raise
        os.replace(tmp_path, self._path)
