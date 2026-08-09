"""Manual device registry — human-told fallback channel (R020-BF007).

Role (design §3.4 ManualRegistry / §4.2.1 register_device tool / §4.3 devices.json):
    When auto-discovery (BF002 USB + BF005 LAN scan) misses a device the AI
    knows about (e.g. the phone is on a different subnet, behind a VPN the
    host can't see, or simply not yet probed), the human can explicitly tell
    the bridge ``register_device(host=192.168.1.34)``. This service probes
    that single host's ``/hello``, and on success registers a
    :class:`DeviceRecord` with ``source="manual"`` in :class:`DevicePool`.

Three concerns kept separate (design §3.4 single-direction dependency):

  * **Identity** (``device_id``) is host-derived — ``manual-<sha1(host)[:16]>``
    via :func:`device_pool.manual_device_id`. **NEVER** sourced from
    ``/hello.deviceId`` (R019 fixed string ``gmacro-virtual-iOS`` collides
    across devices — backend D9, enforced by BF001 ``manual_device_id``).
  * **Reachability** is verified by reusing :func:`endpoint.probe_hello`
    (BF002, design D8 zero-rewrite). A failed probe does NOT pollute the
    pool (analysis L3) — the caller sees ``RegisterResult(ok=False)`` with a
    :class:`DeviceUnreachable` error (BF008 exception model, shared vocab).
  * **Persistence** is delegated to :meth:`DevicePool.upsert` (BF001.3
    identity-only — this module never touches devices.json directly).

Why inject ``LanScan`` if ``register`` only uses ``probe_hello``? The task
skeleton (tasks.md BF007) specifies ``__init__(self, pool, lan_scan)`` for
forward-compat with BF011 server wiring (the server already holds a LanScan
instance). Holding it is cheap; not calling ``scan()`` from ``register``
keeps single-host registration O(1) (no /24 sweep).

Design references:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF007 (L472-497)
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
            §3.4 ManualRegistry / §4.2.1 / §4.3
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import TYPE_CHECKING

from ..device_pool import DevicePool, DeviceRecord, manual_device_id
from ..endpoint import Endpoint, UrlOpen, default_urlopen, probe_hello

# AD-B9: DeviceUnreachable 定义于 device_discovery/protocol.
from ..protocol import DeviceUnreachable

if TYPE_CHECKING:  # pragma: no cover - typing only
    from ..protocol import NetworkTarget
    from .lan_scan import LanScan


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: R019 debug plane HTTP port (mobile app listens here). Matches BF005/BF008.
DEFAULT_PORT = 18080

#: probe /hello timeout. Single-host probe — slightly more generous than
#: BF005's 2.5s sweep default, since a single explicit host deserves one
#: full timeout window before we declare it unreachable.
DEFAULT_PROBE_TIMEOUT = 3.0


# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RegisterResult:
    """Outcome of :meth:`ManualRegistry.register`.

    Two-state result (never raises — :meth:`register` catches all probe
    failures and returns ``ok=False``). The caller dispatches:

      * ``ok=True``  → use ``record`` (already in the pool).
      * ``ok=False`` → inspect ``error`` (always :class:`DeviceUnreachable`
        for probe failures); the pool is untouched.

    Why a result object instead of raising? Two reasons:
      1. The MCP ``register_device`` tool wants to translate probe failures
         into the ``device_unreachable`` MCP error, not a Python traceback —
         a result object makes that translation explicit at the call site.
      2. ``register`` must be total: a typo'd host or a powered-off phone is
         a normal input, not an exceptional state (analysis L3 "人工告知也可能
         告知错误").
    """

    ok: bool
    record: DeviceRecord | None = None
    error: DeviceUnreachable | None = None


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------


class ManualRegistry:
    """Human-told device registration service (design §3.4 / analysis L3).

    Wraps :func:`endpoint.probe_hello` + :meth:`DevicePool.upsert` into a
    single ``register(host, port, label)`` call that:

      1. Probes ``http://{host}:{port}/hello`` (reuses BF002 ``probe_hello``,
         D8 zero-rewrite). On failure returns ``RegisterResult(ok=False)``
         with :class:`DeviceUnreachable` — the pool is NOT modified.
      2. Derives ``device_id = manual_device_id(host)`` (BF001 helper,
         ``manual-<sha1(host)[:16]>``). Independent of ``/hello.deviceId``
         (backend D9).
      3. Builds a :class:`DeviceRecord` with ``source="manual"`` and the
         probe's runtime fields (hardware_name/machine_id/platform +
         last_known_host/last_seen), then :meth:`DevicePool.upsert` it.
         Persistence (devices.json) is delegated to DevicePool — this module
         never writes the file directly (BF001.3 identity-only).

    Args:
        pool: BF001 DevicePool — identity store + persistence (never None).
        lan_scan: BF005 LanScan — held for forward-compat with BF011 server
            wiring; ``register`` does NOT call ``scan()`` (single-host probe
            only). Accepting it here lets the server pass its existing
            LanScan instance without a second constructor.
        port: default port (18080, R019 debug plane). Per-call ``port``
            override in :meth:`register` takes precedence.
        probe_timeout: single-host probe timeout (default 3.0s).
        urlopen: injectable urlopen for testing (defaults to
            ``endpoint.default_urlopen`` = ``urllib.request.urlopen``).
    """

    def __init__(
        self,
        pool: DevicePool,
        lan_scan: LanScan,
        *,
        port: int = DEFAULT_PORT,
        probe_timeout: float = DEFAULT_PROBE_TIMEOUT,
        urlopen: UrlOpen | None = None,
    ) -> None:
        self._pool = pool
        self._lan_scan = lan_scan
        self._port = port
        self._probe_timeout = probe_timeout
        self._urlopen: UrlOpen = urlopen if urlopen is not None else default_urlopen

    def register(
        self,
        host: str,
        *,
        port: int | None = None,
        label: str | None = None,
        note: str | None = None,
    ) -> RegisterResult:
        """Probe ``host`` and register it as a manual device on success.

        Args:
            host: target IPv4 (or hostname) the human told us about.
            port: override the registry's default port (default None → use
                ``self._port``).
            label: human-readable label. Defaults to ``host`` when None.
            note: optional human annotation persisted with the identity
                (BF001.3 ``note`` field; meaningful only for source="manual").

        Returns:
            :class:`RegisterResult`. ``ok=True`` + ``record`` on success;
            ``ok=False`` + ``error`` (DeviceUnreachable) on any probe failure.
            Never raises — all probe exceptions are caught and surfaced as
            ``ok=False`` (analysis L3: 人工告知也可能告知错误).
        """
        effective_port = self._port if port is None else port
        endpoint = Endpoint(host, effective_port)
        target = self._safe_probe(endpoint)
        if target is None:
            return RegisterResult(
                ok=False,
                error=DeviceUnreachable(
                    f"probe /hello failed for {host}:{effective_port} "
                    f"(host unreachable, timed out, or returned invalid /hello)"
                ),
            )

        record = self._build_record(host, target, label=label, note=note)
        self._pool.upsert(record)
        return RegisterResult(ok=True, record=record)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _safe_probe(self, endpoint: Endpoint) -> NetworkTarget | None:
        """Probe ``/hello`` and never raise.

        ``probe_hello`` (BF002) already swallows OSError/URLError/TimeoutError
        /JSONDecodeError → None. We additionally catch any unexpected
        exception (defensive — a buggy urlopen shouldn't crash the registry)
        and return None, so :meth:`register` always returns a
        :class:`RegisterResult`.
        """
        try:
            return probe_hello(
                endpoint,
                timeout=self._probe_timeout,
                urlopen=self._urlopen,
            )
        except Exception:  # noqa: BLE001 (defensive — never crash register)
            return None

    @staticmethod
    def _build_record(
        host: str,
        target: NetworkTarget,
        *,
        label: str | None,
        note: str | None,
    ) -> DeviceRecord:
        """Assemble the DeviceRecord from a successful probe.

        Identity: ``device_id`` is host-derived (NEVER ``target.device_id``);
        ``label`` falls back to ``host`` when the human didn't supply one.
        Runtime: ``last_known_host``/``last_seen`` record the probe moment
        (memory-only per BF001.3); ``hardware_name``/``machine_id``/
        ``platform`` come straight from /hello (may be None on old phones).
        """
        return DeviceRecord(
            device_id=manual_device_id(host),
            label=label if label else host,
            source="manual",
            last_known_host=host,
            last_seen=time.time(),
            hardware_name=target.hardware_name,
            machine_id=target.machine_id,
            platform=target.platform,
            network_target=target,
            note=note,
        )


__all__ = [
    "DEFAULT_PORT",
    "DEFAULT_PROBE_TIMEOUT",
    "ManualRegistry",
    "RegisterResult",
]
