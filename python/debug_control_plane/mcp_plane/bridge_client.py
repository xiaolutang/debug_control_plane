"""HTTP forwarding client — translate MCP layer to phone debug plane 18080.

(R020-BF008)

Role (design §3.4 BridgeClient / §4.1 / §4.2.2 / §4.2.3):
    A thin HTTP client that translates a stable ``device_id`` (chosen by the
    caller) into the phone's *current* IP via :class:`DevicePool.resolve_ip`,
    then forwards the request to the phone's R019 debug plane on port 18080.
    It performs **byte-level pass-through** of the phone's 8 endpoints and
    never alters the phone protocol.

    Three orthogonal concerns are kept separate (design §3.4 单向依赖):

      * **Identity** (``device_id`` from USB) is stable — persisted by
        :class:`DevicePool` (BF001).
      * **IP** (``host``) is ephemeral — TTL-cached in DevicePool, re-discovered
        via BF002 LanScan when stale. This module never caches IPs itself; it
        always asks the pool on every call.
      * **HTTP forwarding** (this module) is the only outbound-to-phone arrow.

Public surface:
    * :class:`BridgeClient` — the service (invoke / read / hello / events).
    * :class:`BridgeError` + subclasses — failure taxonomy (caller dispatches
      on exception type; ``DeviceHttpError`` keeps the phone's original HTTP
      status code so the AI sees e.g. 409 ``real_controller_active``).

Design decisions (resolved during BF008):
    * **httpx** (not stdlib urllib) is the HTTP client. httpx 0.28+ ships
      ``MockTransport`` (clean unit-test isolation) and a streaming SSE reader
      via ``Client.stream()``. The "pure stdlib" constraint from BF001-BF005
      applies only to discovery/device_pool (they don't need HTTP); BF008 IS
      the HTTP forwarding core, so httpx is legitimate.
    * **path = list[str]** (URL segments). ``["virtual", "connect"]`` becomes
      ``/virtual/connect``. ``method`` is a free-form HTTP verb string
      (``"GET"`` / ``"POST"`` / ...); the caller is responsible for picking
      one the phone accepts (R019 8 endpoints).
    * **resolve() three-state** (BF001 ResolveResult semantics, AC7 TTL):
        - ``found=False``  → :class:`DeviceUnreachable` (unknown device)
        - ``is_stale=True`` → :class:`DeviceStale` (TTL expired; caller —
          BF009/BF011 — must re-discover via BF002 LanScan). We never silently
          use a stale IP (invariant: "认身份不认地址").
        - fresh            → return host, proceed with forwarding
    * **SSE → DebugEvent** structured: ``events()`` is a generator that reads
      the SSE stream line-by-line (``data: <json>\\n\\n`` per event, optional
      ``event: <type>`` prefix) and yields :class:`DebugEvent` parsed via
      ``DebugEvent.from_json``. ``event_types`` filters server-side.

Refs:
    - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF008
    - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
              §3.4 BridgeClient / §4.1 / §4.2.2 / §4.2.3
    - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1/§4.4
"""

from __future__ import annotations

from collections.abc import Iterator, Mapping
from typing import TYPE_CHECKING, Any, Protocol

import httpx

# BF007: 跨包 import 改 device_discovery.protocol(BF006 已迁);
# AD-B9: DeviceUnreachable forward import(本文件 line 99 旧定义删,
# device_discovery.protocol 下沉;直继承 Exception 脱离 BridgeError 反向依赖)。
from debug_control_plane.device_discovery.protocol import (
    DebugEvent,
    DeviceUnreachable,
    NetworkTarget,
)

if TYPE_CHECKING:  # pragma: no cover - typing only
    from debug_control_plane.device_discovery.device_pool import DevicePool


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: R019 debug plane HTTP port (mobile app listens here).
DEFAULT_PORT = 18080

#: Default request timeout for one-shot invoke/read/hello. Generous enough
#: for the phone's local processing but bounded so a hung phone surfaces fast.
DEFAULT_REQUEST_TIMEOUT = 5.0

#: Default SSE stream read timeout. Long-ish because the stream is expected
#: to stay open between events; the caller can override per-call.
DEFAULT_STREAM_TIMEOUT = 30.0


# ---------------------------------------------------------------------------
# Error taxonomy
# ---------------------------------------------------------------------------


class BridgeError(Exception):
    """Base class for all BridgeClient failures.

    Callers (BF009/BF011) dispatch on the concrete subclass to decide the
    MCP error code / recovery action. Keeping the taxonomy narrow lets the
    AI receive the *phone's* original signals (e.g. 409 real_controller_active)
    rather than a generic "something failed".
    """


class DeviceStale(BridgeError):
    """The cached IP for device_id is past its TTL (``is_stale=True``).

    The caller MUST re-discover via BF002 LanScan before retrying. We refuse
    to forward on a stale IP — see BF001 ``DevicePool.resolve_ip`` semantics
    and AC7 TTL re-discovery contract.
    """


class DeviceHttpError(BridgeError):
    """The phone returned an HTTP error (status >= 400) OR the connection failed.

    The phone's original status code is preserved verbatim so the AI can act
    on it (e.g. 409 ``real_controller_active`` → "let the real gamepad win").

    For transport-level failures (connect refused / timeout) we still raise
    this with a synthetic status (0 by convention) so the caller only catches
    one type for "phone-side problem".

    Attributes:
        status_code: HTTP status from the phone (0 if the request never got
            an HTTP response — transport failure).
        body: parsed body (dict/list for JSON, str for text, None if empty).
            Kept verbatim so structured error payloads (R019 ``errorCode``)
            survive to the AI.
    """

    def __init__(self, status_code: int, body: Any, message: str = "") -> None:
        self.status_code = status_code
        self.body = body
        prefix = f"[HTTP {status_code}]" if status_code else "[transport]"
        detail = message or (f" {body}" if body else "")
        super().__init__(f"{prefix}{detail}")


class DeviceAuthError(DeviceHttpError):
    """The phone returned a stable debug auth failure code."""

    def __init__(self, status_code: int, body: Any, code: str, message: str = "") -> None:
        self.code = code
        super().__init__(status_code, body, message or f" auth_code={code}")


class DebugAuthTokenProvider(Protocol):
    """Per-device debug auth token provider.

    Implementations own storage. DevicePool remains identity-only and must not
    be used to persist bearer tokens.
    """

    def get_token(self, device_id: str) -> str | None: ...

    def save_token(
        self, device_id: str, token: str, metadata: Mapping[str, Any]
    ) -> None: ...

    def clear_token(self, device_id: str, reason: str) -> None: ...


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------


class BridgeClient:
    """HTTP forwarding client: device_id → phone debug plane 18080.

    The BridgeClient is intentionally stateless w.r.t. IPs — every call asks
    :meth:`DevicePool.resolve_ip` for the current host, so IP TTL changes
    (AC7) are picked up immediately without restart. The injected
    :class:`httpx.Client` is shared across calls (connection pooling) and
    owned by the caller (so the server can close it on shutdown).

    Endpoint surface (design §4.2.2 / §4.2.3 — high-level):
        * :meth:`invoke` — generic verb/path/body forwarding (used by
          ``invoke_command`` meta-tool and the gamepad semantic sugar).
        * :meth:`read` — GET convenience for ``read_resource`` / ``get_state``.
        * :meth:`hello` — typed ``NetworkTarget`` for CapabilityMirror
          (BF009) — parses ``/hello`` including the FF001/FF002 extension
          fields (hardwareName/machineId/registeredCapabilities).
        * :meth:`events` — SSE → ``DebugEvent`` generator for
          ``subscribe_events``.

    Args:
        pool: BF001 DevicePool — identity→IP translation (never ``None``).
        port: phone debug plane port (default 18080, R019 fixed).
        client: optional pre-built :class:`httpx.Client` (tests inject
            ``httpx.MockTransport`` here). If omitted, a default client is
            created with the request/stream timeouts below. Either way the
            client is NOT closed by this class — caller owns the lifecycle.
        request_timeout: one-shot request timeout in seconds.
        stream_timeout: SSE stream read timeout in seconds.
    """

    def __init__(
        self,
        pool: DevicePool,
        *,
        port: int = DEFAULT_PORT,
        client: httpx.Client | None = None,
        request_timeout: float = DEFAULT_REQUEST_TIMEOUT,
        stream_timeout: float = DEFAULT_STREAM_TIMEOUT,
        token_provider: DebugAuthTokenProvider | None = None,
    ) -> None:
        self._pool = pool
        self._port = port
        if client is not None:
            self._client = client
            self._owns_client = False
        else:
            self._client = httpx.Client(timeout=request_timeout)
            self._owns_client = True
        self._request_timeout = request_timeout
        self._stream_timeout = stream_timeout
        self._token_provider = token_provider

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def close(self) -> None:
        """Close the underlying httpx.Client if this instance owns it.

        If a client was injected (tests / server-managed client) it is left
        open — the caller manages its lifetime.
        """
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> BridgeClient:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # ------------------------------------------------------------------
    # Identity → IP translation (BF001 ResolveResult three-state)
    # ------------------------------------------------------------------

    def resolve(self, device_id: str) -> str:
        """Resolve ``device_id`` to a current, TTL-fresh host.

        Implements the BF001 ``ResolveResult`` three-state contract (AC7):

          * ``found=False``  → :class:`DeviceUnreachable`
          * ``is_stale=True`` → :class:`DeviceStale` (caller re-discovers)
          * fresh           → returns ``host``

        We never return a stale host: forwarding on a stale IP would violate
        "认身份不认地址" and silently target the wrong device after a DHCP/WiFi
        switch. The caller (BF009/BF011) catches :class:`DeviceStale` and
        triggers BF002 LanScan re-discovery.
        """
        result = self._pool.resolve_ip(device_id)
        if not result.found:
            raise DeviceUnreachable(f"unknown device_id: {device_id!r}")
        if result.is_stale:
            raise DeviceStale(
                f"TTL expired for {device_id!r} "
                f"(last_known_host={result.host!r}); caller must re-discover"
            )
        # found and fresh — host is guaranteed non-None here, but be defensive.
        if not result.host:
            raise DeviceUnreachable(f"no host recorded for {device_id!r}")
        return result.host

    # ------------------------------------------------------------------
    # Forwarding primitives
    # ------------------------------------------------------------------

    def invoke(
        self,
        device_id: str,
        method: str,
        path: list[str],
        body: Any = None,
        *,
        capability_id: str | None = None,
        scope: str | None = None,
        page_id: str | None = None,
        scope_revision: int | None = None,
    ) -> Any:
        """Forward ``method path body`` to the phone (byte-level pass-through).

        Used by ``invoke_command`` (meta-tool) and the gamepad semantic sugar
        (``POST /virtual/connect`` etc.). The phone's R019 protocol is
        untouched — we only translate URL segments to a path and forward.

        Args:
            device_id: stable device identity (resolved via the pool).
            method: HTTP verb (``"GET"`` / ``"POST"`` / ...). The caller is
                responsible for matching R019 endpoint verbs.
            path: URL segments joined with ``/``. ``["virtual", "connect"]``
                → ``/virtual/connect``. Empty list → ``/`` (root).
            body: request body. If it's a dict/list it's sent as JSON
                (``json=``); otherwise it's sent raw (``content=``) and may
                be ``None``.
            capability_id/scope/page_id/scope_revision: optional R003
                selector metadata forwarded as ``X-DCP-*`` headers. Omitted
                values keep the legacy flat dispatch behavior.

        Returns:
            The phone's response body, parsed: dict/list for JSON, ``str``
            for non-JSON text, ``None`` for empty.

        Raises:
            DeviceUnreachable: unknown device_id.
            DeviceStale: cached IP past TTL — caller re-discovers.
            DeviceHttpError: phone returned status >= 400 (status_code +
                body preserved) OR transport failure (status_code=0).
        """
        host = self.resolve(device_id)
        url = self._build_url(host, path)
        headers = self._auth_headers(device_id)
        headers.update(
            selector_headers(
                capability_id=capability_id,
                scope=scope,
                page_id=page_id,
                scope_revision=scope_revision,
            )
        )
        try:
            if isinstance(body, (dict, list)):
                resp = self._client.request(method, url, json=body, headers=headers)
            else:
                resp = self._client.request(method, url, content=body, headers=headers)
        except httpx.HTTPError as exc:
            # Connect refused / DNS / timeout / etc — surface as transport
            # failure so the caller catches a single exception type.
            raise DeviceHttpError(0, None, f"transport: {exc!s}") from exc
        if resp.status_code >= 400:
            raise self._http_error(device_id, resp)
        return _safe_body(resp)

    def read(
        self,
        device_id: str,
        path: list[str],
        *,
        capability_id: str | None = None,
        scope: str | None = None,
        page_id: str | None = None,
        scope_revision: int | None = None,
    ) -> Any:
        """GET convenience for ``read_resource`` / ``get_state``.

        Equivalent to ``invoke(device_id, "GET", path, None)`` but signals
        intent at the call site. Returns the parsed phone body.
        """
        return self.invoke(
            device_id,
            "GET",
            path,
            None,
            capability_id=capability_id,
            scope=scope,
            page_id=page_id,
            scope_revision=scope_revision,
        )

    def hello(self, device_id: str) -> NetworkTarget:
        """Fetch ``/hello`` and parse to a typed :class:`NetworkTarget`.

        Used by CapabilityMirror (BF009) to build the tool list from the
        phone's runtime capability schema (FF001/FF002 extension fields
        included). The host/port are recorded on the returned target so the
        caller doesn't need to thread them separately.

        Raises:
            DeviceUnreachable / DeviceStale: see :meth:`resolve`.
            DeviceHttpError: phone returned non-200 or transport failure.
        """
        host = self.resolve(device_id)
        url = self._build_url(host, ["hello"])
        headers = self._auth_headers(device_id)
        try:
            resp = self._client.get(url, headers=headers)
        except httpx.HTTPError as exc:
            raise DeviceHttpError(0, None, f"transport: {exc!s}") from exc
        if resp.status_code != 200:
            raise self._http_error(device_id, resp)
        data = resp.json()
        if not isinstance(data, dict):
            raise DeviceHttpError(
                resp.status_code,
                data,
                f"/hello payload not an object: {type(data).__name__}",
            )
        return NetworkTarget.from_hello(data, host=host, port=self._port)

    def events(
        self,
        device_id: str,
        event_types: list[str] | None = None,
    ) -> Iterator[DebugEvent]:
        """Subscribe to the phone's ``/events`` SSE stream as DebugEvents.

        This is a generator: the caller iterates to consume events, and
        closing/exhausting the generator closes the underlying stream.

        The phone's R019 SSE format is standard Server-Sent Events:

            event: input\\n
            data: {"type":"input","sequence":42,...}\\n
            \\n

        We tolerate missing ``event:`` lines (the ``type`` lives inside the
        JSON ``data`` payload anyway, per ``DebugEvent.from_json``) and
        non-JSON data lines (yielded as ``event_type="unknown"`` — same
        fallback ``DebugEvent.from_json`` uses).

        Args:
            device_id: stable device identity.
            event_types: optional server-side filter. If ``None``, all event
                types are yielded. The match is against
                ``DebugEvent.event_type`` (parsed from the JSON ``type`` key).

        Yields:
            :class:`DebugEvent` instances, one per SSE event in stream order.

        Raises:
            DeviceUnreachable / DeviceStale: see :meth:`resolve`.
            DeviceHttpError: phone returned status >= 400 before streaming,
                or transport failure mid-stream (raised from inside the
                generator).
        """
        host = self.resolve(device_id)
        url = self._build_url(host, ["events"])
        headers = self._auth_headers(device_id)
        type_set = set(event_types) if event_types else None
        try:
            with self._client.stream(
                "GET", url, headers=headers, timeout=self._stream_timeout
            ) as resp:
                if resp.status_code >= 400:
                    # Read the body so the caller sees the error payload.
                    resp.read()
                    raise self._http_error(device_id, resp)
                for raw_data, _event_field in _iter_sse(resp):
                    try:
                        payload = _parse_json_object(raw_data)
                    except (ValueError, TypeError):
                        # Not valid JSON — DebugEvent.from_json handles by
                        # producing event_type="unknown". Wrap so it parses.
                        payload = {"type": "unknown", "data": raw_data}
                    evt = DebugEvent.from_json(payload)
                    if type_set is None or evt.event_type in type_set:
                        yield evt
        except DeviceHttpError:
            raise
        except httpx.HTTPError as exc:
            raise DeviceHttpError(0, None, f"transport: {exc!s}") from exc

    def auth_request(
        self,
        device_id: str,
        client_nonce: str,
        *,
        client_label: str | None = None,
        requested_method: str | None = None,
        requested_path: str | None = None,
    ) -> Any:
        """Create a pending App-side authorization request."""
        body: dict[str, Any] = {"clientNonce": client_nonce}
        if client_label is not None:
            body["clientLabel"] = client_label
        if requested_method is not None:
            body["requestedMethod"] = requested_method
        if requested_path is not None:
            body["requestedPath"] = requested_path
        return self.invoke(device_id, "POST", ["auth", "request"], body)

    def auth_status(self, device_id: str, request_id: str, client_nonce: str) -> Any:
        """Poll App-side authorization status."""
        return self.invoke(
            device_id,
            "POST",
            ["auth", "status"],
            {"requestId": request_id, "clientNonce": client_nonce},
        )

    def auth_claim(self, device_id: str, request_id: str, client_nonce: str) -> Any:
        """Claim an approved App-side authorization token and save it if present."""
        body = self.invoke(
            device_id,
            "POST",
            ["auth", "claim"],
            {"requestId": request_id, "clientNonce": client_nonce},
        )
        if isinstance(body, dict):
            token = body.get("token")
            if isinstance(token, str) and self._token_provider is not None:
                metadata = {
                    key: body[key]
                    for key in ("tokenId", "expiresAt")
                    if key in body
                }
                self._token_provider.save_token(device_id, token, metadata)
        return body

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _auth_headers(self, device_id: str) -> dict[str, str]:
        provider = self._token_provider
        if provider is None:
            return {}
        token = provider.get_token(device_id)
        if not token:
            return {}
        return {"Authorization": f"Bearer {token}"}

    def _http_error(self, device_id: str, resp: httpx.Response) -> DeviceHttpError:
        body = _safe_body(resp)
        code = _auth_error_code(resp.status_code, body)
        if code is None:
            return DeviceHttpError(resp.status_code, body)
        if code in _CLEAR_TOKEN_AUTH_CODES and self._token_provider is not None:
            self._token_provider.clear_token(device_id, reason=code)
        return DeviceAuthError(resp.status_code, body, code=code)

    def _build_url(self, host: str, path: list[str]) -> str:
        """Assemble ``http://{host}:{port}/{seg1}/{seg2}...``.

        Path segments are joined as-is. Empty path → ``/``. Trailing slashes
        are not added (R019 endpoints don't expect them).
        """
        if path:
            joined = "/".join(_quote_segment(seg) for seg in path)
            return f"http://{host}:{self._port}/{joined}"
        return f"http://{host}:{self._port}/"


# ---------------------------------------------------------------------------
# Module-level helpers (free functions for testability + reuse)
# ---------------------------------------------------------------------------


def _safe_body(resp: httpx.Response) -> Any:
    """Parse an HTTP response body defensively.

    R019 endpoints return JSON for structured data but may return plain text
    or empty bodies for some error paths. We never want to crash the caller
    on a parse error — instead we degrade to the raw text.

    Returns:
        * dict/list if the body is valid JSON and is a container,
        * str/int/... if the body is valid JSON but a scalar,
        * str (raw text) if the body is not valid JSON,
        * None if the body is empty.
    """
    if not resp.content:
        return None
    try:
        return resp.json()
    except (ValueError, TypeError):
        return resp.text


def selector_headers(
    *,
    capability_id: str | None = None,
    scope: str | None = None,
    page_id: str | None = None,
    scope_revision: int | None = None,
) -> dict[str, str]:
    """Build optional R003 selector headers for capability-scoped dispatch."""
    headers: dict[str, str] = {}
    if isinstance(capability_id, str) and capability_id:
        headers["X-DCP-Capability-Id"] = capability_id
    if scope in ("app", "page"):
        headers["X-DCP-Capability-Scope"] = scope
    if isinstance(page_id, str) and page_id:
        headers["X-DCP-Page-Id"] = page_id
    if isinstance(scope_revision, int) and not isinstance(scope_revision, bool):
        headers["X-DCP-Scope-Revision"] = str(scope_revision)
    return headers


def _quote_segment(seg: str) -> str:
    """URL-encode a single path segment (preserving ``/`` within a segment).

    We don't allow segments to contain ``/`` (caller splits first); if they
    do, we percent-encode so it stays one segment. This keeps ``invoke``
    semantics predictable: one list element == one URL segment.
    """
    # httpx/urllib quote: '/' encoded so it doesn't get treated as a separator.
    from urllib.parse import quote

    return quote(str(seg), safe="")


def _iter_sse(resp: httpx.Response) -> Iterator[tuple[str, str | None]]:
    """Yield ``(data, event_field)`` tuples from an SSE response stream.

    Standard SSE framing (W3C EventSource):
        * Lines separated by ``\\n`` or ``\\r\\n``.
        * A blank line dispatches the buffered event.
        * ``data: <text>`` appends to the data buffer (multiple data lines
          are joined with ``\\n``).
        * ``event: <name>`` sets the event type for the next dispatch.
        * ``: comment`` and unknown fields are ignored.

    Yields:
        ``(data, event_field)`` where ``data`` is the joined data payload
        (str) and ``event_field`` is the last ``event:`` value seen for
        this dispatch (or ``None``). The consumer (``events()``) only uses
        ``data``; ``event_field`` is returned for completeness/future use.
    """
    data_lines: list[str] = []
    event_field: str | None = None

    for raw_line in resp.iter_lines():
        # iter_lines strips the trailing newline; empty str == blank line.
        line = raw_line.rstrip("\r")
        if line == "":
            if data_lines:
                yield "\n".join(data_lines), event_field
                data_lines = []
                event_field = None
            continue
        if line.startswith(":"):
            # Comment line — ignore per SSE spec.
            continue
        if ":" in line:
            field, _, value = line.partition(":")
            if value.startswith(" "):
                value = value[1:]
        else:
            field = line
            value = ""
        if field == "data":
            data_lines.append(value)
        elif field == "event":
            event_field = value or None
        # Other fields (id:, retry:) are ignored.

    # Flush a trailing event if the stream closed without a blank line.
    if data_lines:
        yield "\n".join(data_lines), event_field


def _parse_json_object(raw: str) -> dict[str, Any]:
    """Parse a JSON object string, raising on invalid input.

    A thin wrapper around :func:`json.loads` that constrains the result to a
    dict — SSE data lines that aren't JSON objects are not useful to
    ``DebugEvent.from_json`` and the caller falls back to ``{"type":"unknown"}``.
    """
    import json

    parsed = json.loads(raw)
    if not isinstance(parsed, dict):
        raise ValueError(f"SSE data is not a JSON object: {type(parsed).__name__}")
    return parsed


def _auth_error_code(status_code: int, body: Any) -> str | None:
    if status_code not in (401, 403) or not isinstance(body, dict):
        return None
    code = body.get("code")
    if isinstance(code, str) and code in _AUTH_ERROR_CODES:
        return code
    return None


_AUTH_ERROR_CODES = frozenset(
    {
        "authorization_required",
        "invalid_token",
        "token_expired",
        "token_revoked",
        "authorization_denied",
        "forbidden",
    }
)

_CLEAR_TOKEN_AUTH_CODES = frozenset(
    {
        "invalid_token",
        "token_expired",
        "token_revoked",
    }
)


__all__ = [
    "DEFAULT_PORT",
    "DEFAULT_REQUEST_TIMEOUT",
    "DEFAULT_STREAM_TIMEOUT",
    "BridgeClient",
    "BridgeError",
    "DebugAuthTokenProvider",
    "DeviceAuthError",
    "DeviceHttpError",
    "DeviceStale",
    "selector_headers",
    # AD-B9: DeviceUnreachable 已下沉 device_discovery.protocol,
    # 本模块 forward import(BF007),不 re-export。
]
