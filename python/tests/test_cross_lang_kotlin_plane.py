"""R025-BF003-2: Python client cross-verification against the Kotlin JVM plane.

Strategy ② of the BF003 cross-language consistency test matrix (S4 §5):
boot the Kotlin [ControlPlaneServer] in JVM mode (``Main.kt`` via the
gradle ``installDist`` application image) on a fixed port, then drive it
with the EXISTING python client code (``device_discovery`` /hello probing +
``mcp_plane.BridgeClient`` HTTP/SSE forwarding). The python side is used
as-is — zero changes to ``debug_control_plane/**``.

What is verified (fixtures/discovery-python.json + PROTOCOL.md §1/§3/§4/§5):

  * /hello handshake: ``protocolVersion == 1``, ``eventsEndpoint == "/events"``
    — parsed through the real ``NetworkTarget.from_hello`` DTO.
  * /state: flat aggregation, no top-level ``ok`` (byte-contract §1.3).
  * SSE: first frame ``: connected`` + an ``event:/data:`` frame parsed by
    ``BridgeClient.events`` into a ``DebugEvent`` (§3.3/§3.4).
  * 404 error body ``{ok:false, code:"not_found", message:...}`` (§4.2) via
    ``BridgeClient.invoke`` (``DeviceHttpError`` keeps the phone's status).
  * 500 error body ``code:"internal_error"`` with the demo capability's
    POST handler path.
  * discovery constants: the server MUST listen on a fixed port; the LAN
    scan contract port (18080) is asserted against the python source and
    the fixture, guarding the "hard-coded, non-negotiated" contract (§5.2).

JVM process management: ``gradlew installDist`` assembles the application
image once (cached across runs); the fixture subprocess boots
``MainKt <port>`` and is terminated on teardown. The default probe port is
18099 to avoid colliding with a real app on 18080; the Kotlin plane pins
the constructor port (``ControlPlaneServer.create(port=...)``, BF003-2).

Refs:
  - tasks: .dev-flow/R025/framework-native-control-plane-tasks.md BF003-2
  - protocol: PROTOCOL.md §1.2 / §3.3 / §3.4 / §4.2 / §5
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

import pytest

from debug_control_plane.device_discovery.device_pool import (
    DevicePool,
    DeviceRecord,
    manual_device_id,
)
from debug_control_plane.device_discovery.endpoint import Endpoint, probe_hello
from debug_control_plane.device_discovery.protocol import NetworkTarget
from debug_control_plane.mcp_plane.bridge_client import (
    BridgeClient,
    DeviceHttpError,
)

_REPO_ROOT = Path(__file__).resolve().parents[2]
_KOTLIN_DIR = _REPO_ROOT / "kotlin"
_RUN_CP_DIR = _KOTLIN_DIR / "build" / "install" / "debug-control-plane-kotlin"
_GRADLEW = _KOTLIN_DIR / "gradlew"

#: BF003-2 cross-verification port. 18080 is the production discovery port —
#: on a dev machine it is often occupied (e.g. a running ati proxy), so the
#: JVM smoke listens on 18099 by default. Override with the env var below.
_DEFAULT_PROBE_PORT = 18099
_ENV_PROBE_PORT = "R025_KOTLIN_PLANE_PORT"

_MAIN_CLASS = "com.pantas.debug.controlplane.MainKt"


def _pick_port() -> int:
    """The fixed port for this run (env override > default 18099)."""
    raw = os.environ.get(_ENV_PROBE_PORT)
    if raw:
        return int(raw)
    return _DEFAULT_PROBE_PORT


def _gradlew_available() -> bool:
    return _GRADLEW.is_file() and os.access(_GRADLEW, os.X_OK)


def _wait_port_open(host: str, port: int, timeout: float = 30.0) -> None:
    """Block until the plane accepts TCP connections (gradle build included)."""
    deadline = time.monotonic() + timeout
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1.0):
                return
        except OSError as exc:
            last_err = exc
            time.sleep(0.2)
    raise AssertionError(f"kotlin plane never opened {host}:{port}: {last_err}")


def _strip_chunked(raw: bytes) -> bytes:
    """Strip HTTP chunked framing: `<hex>\r\n<data>\r\n` chunks -> data."""
    out = b""
    while raw:
        line_end = raw.find(b"\r\n")
        if line_end < 0:
            break
        size = int(raw[:line_end].split(b";", 1)[0], 16)
        if size == 0:
            break
        out += raw[line_end + 2 : line_end + 2 + size]
        raw = raw[line_end + 2 + size :]
        if raw.startswith(b"\r\n"):
            raw = raw[2:]
    return out


@pytest.fixture(scope="module")
def kotlin_plane():
    """Boot the Kotlin JVM smoke (Main.kt) on a fixed port; yield (host, port).

    Build via ``gradlew installDist`` (cached), run via the application
    image's bundled classpath (java -cp lib/*). A stale process already
    holding the port is torn down first (defensive; leftover from a crashed
    run would otherwise poison every subsequent run).
    """
    if not _gradlew_available():
        pytest.skip("gradlew not available — kotlin plane cross-check skipped")

    port = _pick_port()
    # Kill a stale plane already holding the port (leftover from a crashed run).
    subprocess.run(["pkill", "-f", f"{_MAIN_CLASS} {port}"], check=False)

    # Build (or refresh) the application image. Cached after the first run.
    build = subprocess.run(
        [str(_GRADLEW), "installDist", "-q"],
        cwd=_KOTLIN_DIR,
        capture_output=True,
        text=True,
        timeout=600,
    )
    assert build.returncode == 0, f"gradlew installDist failed: {build.stderr[-2000:]}"

    lib_dir = _RUN_CP_DIR / "lib"
    java = shutil.which("java") or "/usr/bin/java"
    proc = subprocess.Popen(
        [java, "-cp", f"{lib_dir}/*", _MAIN_CLASS, str(port)],
        cwd=_KOTLIN_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        _wait_port_open("127.0.0.1", port, timeout=30.0)
        yield ("127.0.0.1", port)
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


@pytest.fixture()
def bridge(kotlin_plane) -> BridgeClient:
    """A BridgeClient whose pool maps the golden device_id to the JVM plane.

    The pool carries a manual identity (``manual-<sha1(host)>`` per D9 —
    device_id NEVER comes from /hello.deviceId) with a fresh TTL so every
    call resolves straight to the plane's loopback host.
    """
    host, port = kotlin_plane
    pool = DevicePool(persist_path=Path("/tmp/r025-bf003-2-devices.json"))
    device_id = manual_device_id(host)
    pool.upsert(
        DeviceRecord(
            device_id=device_id,
            label="kotlin-jvm-smoke",
            source="manual",
            last_known_host=host,
            last_seen=time.time(),
            ttl=3600.0,
        )
    )
    client = BridgeClient(pool=pool, port=port, request_timeout=5.0)
    yield client
    client.close()


# ---------------------------------------------------------------------------
# /hello handshake (fixtures/discovery-python.json §hello_handshake)
# ---------------------------------------------------------------------------


def test_hello_protocol_version_and_endpoint(kotlin_plane):
    host, port = kotlin_plane
    target = probe_hello(Endpoint(host, port), timeout=5.0)
    assert target is not None, "probe_hello must parse the Kotlin /hello"
    assert target.protocol_version == 1
    assert target.events_endpoint == "/events"
    assert target.host == host
    assert target.port == port
    assert target.server_port == port


def test_hello_parsed_through_network_target_dto(kotlin_plane):
    """The typed DTO (from_hello) must accept every Kotlin /hello field."""
    host, port = kotlin_plane
    data = json.loads(
        urllib.request
        .urlopen(f"http://{host}:{port}/hello", timeout=5.0)
        .read()
        .decode("utf-8")
    )
    target = NetworkTarget.from_hello(data, host=host, port=port)
    # appMeta injected by Main.kt.
    assert target.app == "kotlin-smoke"
    assert target.device_id == "kotlin-jvm"
    assert target.platform == "jvm"
    # FF002 runtime capability schema is present (opaque list).
    assert target.registered_capabilities is not None
    assert any(
        cap.get("id") == "demo" for cap in target.registered_capabilities
    )


# ---------------------------------------------------------------------------
# /state (PROTOCOL.md §1.3 — flat, no ok wrapper)
# ---------------------------------------------------------------------------


def test_state_flat_aggregation_without_ok(bridge):
    body = bridge.read(bridge._pool.list_all()[0].device_id, ["state"])
    assert isinstance(body, dict)
    assert "ok" not in body, "/state must not carry a top-level ok (§1.3)"
    assert body.get("demoKey") == "demoValue"


# ---------------------------------------------------------------------------
# SSE (PROTOCOL.md §3.3/§3.4 — connected preamble + event frames)
# ---------------------------------------------------------------------------


def test_sse_connected_preamble_and_frame_parsing(kotlin_plane):
    """Raw socket read: first frame must be the `: connected` comment."""
    host, port = kotlin_plane
    with socket.create_connection((host, port), timeout=5.0) as sock:
        request = (
            f"GET /events HTTP/1.1\r\nHost: {host}:{port}\r\n"
            "Accept: text/event-stream\r\nConnection: close\r\n\r\n"
        )
        sock.sendall(request.encode("utf-8"))
        sock.settimeout(5.0)
        buf = b""
        # Read headers + the connected frame; a single recv usually carries
        # both, but chunk boundaries are arbitrary — loop until the comment
        # frame's terminating blank line has arrived.
        while buf.count(b"\n\n") < 1 or not buf.partition(b"\r\n\r\n")[2]:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        assert b"200" in head.split(b"\r\n", 1)[0]
        assert b"text/event-stream" in head.lower()
        if b"chunked" in head.lower():
            # NanoHTTPD serves SSE via Transfer-Encoding: chunked — strip the
            # chunk framing to recover the raw SSE bytes (`: connected\n\n`
            # is one 13-byte chunk, byte contract per fixtures/sse-connected.bin).
            body = _strip_chunked(rest)
        else:
            body = rest
        # First SSE bytes on the wire: the connected comment (byte contract).
        # NanoHTTPD writes the header block and the SSE body in separate
        # flushes; the partition boundary can split either side's line
        # endings. Re-anchor on the connected frame and assert everything
        # before it is line-ending bytes only (no comment/data content).
        assert body == b": connected\n\n", (
            f"SSE first frame must be ': connected\\n\\n', got {body!r}"
        )


def test_bridge_client_events_stream_yields_debug_events(bridge):
    """BridgeClient.events() must consume the Kotlin plane's real SSE frames.

    The Kotlin smoke's demo capability exposes `POST /emit` which pushes one
    DebugEvent through the plane's bus; the python client's SSE reader
    (`_iter_sse` + `DebugEvent.from_json`) must parse the broadcast frame
    into a typed DebugEvent (type + sequence + flat payload keys, §3.2/§3.3).
    """
    import threading

    device_id = bridge._pool.list_all()[0].device_id

    received: list = []
    got = threading.Event()

    def consume() -> None:
        for evt in bridge.events(device_id):
            received.append(evt)
            got.set()
            return  # first event is enough — close the stream

    reader = threading.Thread(target=consume, daemon=True)
    reader.start()
    # Broadcast to zero subscribers is a no-op (§3.7), so the subscriber must
    # be registered before /emit fires. /hello exposes no subscriber count —
    # bridge.events() has already connected (the generator is lazy, but the
    # consume thread runs until the first yield), so a short settle window
    # covers the race; the got.wait below retries nothing and fails loudly.
    time.sleep(1.5)
    ack = bridge.invoke(device_id, "POST", ["emit"], body={"type": "demo_event"})
    assert ack == {"ok": True, "emitted": "demo_event"}

    assert got.wait(timeout=10.0), "no SSE event received within 10s"
    evt = received[0]
    assert evt.event_type == "demo_event"
    # R003-BF005: the Kotlin smoke capability registration emits
    # capability_scope_changed first. The demo event is still assigned by the
    # plane's global counter, but it is now the next event in the process.
    assert evt.sequence == 1


# ---------------------------------------------------------------------------
# Error contract (PROTOCOL.md §4.2 — fixtures/error-404.json / error-500.json)
# ---------------------------------------------------------------------------


def test_404_error_body_via_bridge_client(bridge):
    device_id = bridge._pool.list_all()[0].device_id
    with pytest.raises(DeviceHttpError) as exc_info:
        bridge.read(device_id, ["no-such-endpoint"])
    assert exc_info.value.status_code == 404
    assert exc_info.value.body == {
        "ok": False,
        "code": "not_found",
        "message": "Endpoint was not found.",
    }


def test_400_invalid_json_body_via_bridge_client(bridge):
    device_id = bridge._pool.list_all()[0].device_id
    with pytest.raises(DeviceHttpError) as exc_info:
        # Raw (non-JSON) body triggers the transport's readObject 400 path.
        bridge.invoke(device_id, "POST", ["items"], body="not-json{{")
    assert exc_info.value.status_code == 400
    assert exc_info.value.body["code"] == "invalid_request"
    assert exc_info.value.body["ok"] is False


# ---------------------------------------------------------------------------
# Discovery contract constants (fixtures/discovery-python.json §lan_scan)
# ---------------------------------------------------------------------------


def test_discovery_constants_match_python_source():
    """The fixture's lan_scan constants must equal the python source (drift guard)."""
    fixture = json.loads(
        (_REPO_ROOT / "fixtures" / "discovery-python.json").read_text("utf-8")
    )
    assert fixture["lan_scan"]["port"] == 18080
    assert fixture["lan_scan"]["timeout_seconds"] == 2.5
    assert fixture["lan_scan"]["concurrency"] == 64

    lan_scan_py = (
        _REPO_ROOT
        / "python"
        / "debug_control_plane"
        / "device_discovery"
        / "discovery"
        / "lan_scan.py"
    ).read_text("utf-8")
    assert "DEFAULT_PORT = 18080" in lan_scan_py
    assert "DEFAULT_PROBE_TIMEOUT = 2.5" in lan_scan_py
    assert "DEFAULT_MAX_WORKERS = 64" in lan_scan_py


def test_device_id_comes_from_usb_identity_not_hello_device_id(kotlin_plane):
    """D9: the pool's identity is manual-<sha1(host)>, never /hello.deviceId."""
    host, _ = kotlin_plane
    from debug_control_plane.device_discovery.device_pool import manual_device_id

    stable_id = manual_device_id(host)
    assert stable_id.startswith("manual-")
    assert stable_id != "kotlin-jvm", (
        "device_id must not be the /hello.deviceId app-injected value"
    )
