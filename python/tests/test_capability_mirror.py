"""Unit tests for CapabilityMirror (R020-BF009).

Service-layer tests: BridgeClient is **mocked** (we never open an HTTP
socket — the /hello response is faked by stubbing ``client.hello`` to return
a pre-built ``NetworkTarget``). The gamepad semantic-sugar provider is also
faked with a stub :class:`SemanticProvider` so BF009 is exercised in
isolation from BF010.

Coverage targets (test analysis §2.1 four CapabilityMirror scenarios):

    * dynamic generation (AC8)        — stub provider matches structured schema
    * legacy degrade (AC8 old app)    — heuristic on static capabilities tag
    * unknown-cap fallback (AC10)     — no provider matches → meta-only
    * list_changed (AC8)              — refresh change-detection signal
    * /hello unreachable              — clear cache, static-only degrade
    * static meta + device-mgmt floor — always present, even with no device
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock

import pytest

from debug_control_plane.device_discovery.protocol import NetworkTarget
from debug_control_plane.mcp_plane.bridge_client import (
    BridgeError,
    DeviceAuthError,
    DeviceHttpError,
    DeviceStale,
    DeviceUnreachable,
)
from debug_control_plane.mcp_plane.capability_mirror import (
    CapabilityMirror,
    CapabilitySchema,
    CommandDecl,
    ResourceDecl,
    ToolSpec,
)

# test 自持字面量(AD-B1 后 capability_mirror 不再 export 两常量;
# E 方案 sentinel 验证用,业务 provider 内部按 tag 认领)。
LEGACY_GAMEPAD_TAG = "virtual_input"
GAMEPAD_CAPABILITY_ID = "gamepad"


# ---------------------------------------------------------------------------
# Fixtures / factories
# ---------------------------------------------------------------------------


def _target(
    *,
    registered: tuple[dict[str, Any], ...] | None = None,
    capabilities: frozenset[str] = frozenset(),
    device_id: str = "dev1",
    host: str = "192.168.1.34",
) -> NetworkTarget:
    """Build a NetworkTarget with the FF001/FF002 extension fields populated.

    Only the fields CapabilityMirror reads are set; the rest take defaults.
    """
    return NetworkTarget(
        device_id=device_id,
        device_name="iPhone X",
        platform="ios",
        host=host,
        port=18080,
        protocol_version=1,
        capabilities=capabilities,
        active_source="none",
        virtual_connected=False,
        profile_id=None,
        real_controller_active=False,
        last_error=None,
        profile_revision=0,
        registered_capabilities=registered,
    )


def _gamepad_schema_dict(
    *,
    resources: list[dict[str, Any]] | None = None,
    commands: list[dict[str, Any]] | None = None,
    description: str | None = None,
    scope: Any = None,
    page_id: Any = None,
    page_name: Any = None,
    scope_revision: Any = None,
) -> dict[str, Any]:
    """A registeredCapabilities entry shaped like FF002 gamepad output."""
    out: dict[str, Any] = {
        "id": GAMEPAD_CAPABILITY_ID,
        "resources": resources if resources is not None else [],
        "commands": commands if commands is not None else [],
    }
    if description is not None:
        out["description"] = description
    if scope is not None:
        out["scope"] = scope
    if page_id is not None:
        out["pageId"] = page_id
    if page_name is not None:
        out["pageName"] = page_name
    if scope_revision is not None:
        out["scopeRevision"] = scope_revision
    return out


def _mock_client_hello(target: NetworkTarget | None = None, *, raises: BaseException | None = None):
    """Build a BridgeClient mock whose .hello() returns ``target`` or raises.

    The returned mock records every hello() call (device_id arg) so tests can
    assert probe count.
    """
    client = MagicMock()
    client.hello = MagicMock()
    if raises is not None:
        client.hello.side_effect = raises
    else:
        client.hello.return_value = target
    return client


@dataclass
class _StubProvider:
    """Minimal SemanticProvider stub — matches a single capability id.

    Builds a single canned ToolSpec so tests can assert "the sugar tool got
    added". Records every matches()/build_tools() invocation for inspection.
    """

    capability_id: str
    legacy_tag: str | None = None
    matches_calls: list[Any] = None  # type: ignore[assignment]
    build_calls: list[CapabilitySchema] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        self.matches_calls = []
        self.build_calls = []

    def matches(
        self,
        schema: CapabilitySchema,
        *,
        legacy_capabilities: frozenset[str] | None = None,
    ) -> bool:
        # Capture for assertions; legacy_capabilities ignored unless tag set.
        self.matches_calls.append(schema)
        if schema.capability_id == self.capability_id:
            return True
        if (
            self.legacy_tag
            and legacy_capabilities
            and self.legacy_tag in legacy_capabilities
        ):
            return True
        return False

    def build_tools(self, schema: CapabilitySchema) -> list[ToolSpec]:
        self.build_calls.append(schema)
        return [
            ToolSpec(
                name=f"{self.capability_id}_stub_tool",
                description=f"stub sugar for {schema.capability_id}",
                input_schema={"type": "object"},
            )
        ]


# ---------------------------------------------------------------------------
# Static meta + device-mgmt floor (design §4.2.1 / §4.2.2)
# ---------------------------------------------------------------------------


class TestStaticFloor:
    """build_tools ALWAYS includes meta + device-mgmt, even with no device."""

    _META_NAMES = {
        "list_capabilities",
        "invoke_command",
        "read_resource",
        "get_state",
        "subscribe_events",
    }
    _MGMT_NAMES = {"list_devices", "discover_devices", "register_device"}

    def test_no_device_id_returns_static_only(self):
        client = _mock_client_hello(_target())
        mirror = CapabilityMirror(client=client)
        tools = mirror.build_tools(device_id=None)
        names = {t.name for t in tools}
        assert names == self._META_NAMES | self._MGMT_NAMES
        # And no probe happened (build_tools must stay cheap, no I/O).
        assert client.hello.call_count == 0

    def test_unknown_device_id_no_cache_returns_static_only(self):
        # device_id set but refresh() never called → no cache → static only.
        client = _mock_client_hello(_target())
        mirror = CapabilityMirror(client=client)
        tools = mirror.build_tools(device_id="dev1")
        names = {t.name for t in tools}
        assert names == self._META_NAMES | self._MGMT_NAMES
        # build_tools does NOT implicitly probe /hello (refresh owns that).
        assert client.hello.call_count == 0

    def test_tool_names_unique(self):
        client = _mock_client_hello(_target())
        mirror = CapabilityMirror(client=client)
        tools = mirror.build_tools(None)
        names = [t.name for t in tools]
        assert len(names) == len(set(names))

    @pytest.mark.parametrize("tool_name,path_key", [
        ("invoke_command", "command_path"),
        ("read_resource", "resource_path"),
    ])
    def test_meta_selector_schema_is_optional_and_closed(self, tool_name, path_key):
        client = _mock_client_hello(_target())
        mirror = CapabilityMirror(client=client)
        tool = next(t for t in mirror.build_tools(None) if t.name == tool_name)
        schema = tool.input_schema
        props = schema["properties"]
        assert "scope" in props
        assert props["scope"]["enum"] == ["app", "page"]
        assert "page_id" in props
        assert "scope_revision" in props
        assert schema["additionalProperties"] is False
        assert schema["required"] == ["device_id", "capability_id", path_key]


# ---------------------------------------------------------------------------
# Dynamic generation — new app (FF002) registeredCapabilities (AC8)
# ---------------------------------------------------------------------------


class TestDynamicGeneration:
    """mock /hello registeredCapabilities → build_tools reflects schema."""

    def test_gamepad_schema_with_matching_provider_adds_sugar(self):
        target = _target(
            registered=(_gamepad_schema_dict(),),
            capabilities=frozenset({LEGACY_GAMEPAD_TAG, "sse"}),
        )
        client = _mock_client_hello(target)
        provider = _StubProvider(capability_id=GAMEPAD_CAPABILITY_ID)
        mirror = CapabilityMirror(client=client, providers=[provider])

        assert mirror.refresh("dev1") is True  # empty cache → populated = change
        tools = mirror.build_tools("dev1")
        names = {t.name for t in tools}
        assert "gamepad_stub_tool" in names
        # Static tools still present alongside the sugar.
        assert "list_capabilities" in names
        assert "list_devices" in names
        # Provider hook fired exactly once (one schema, one match).
        assert len(provider.matches_calls) == 1
        assert provider.build_calls[0].capability_id == GAMEPAD_CAPABILITY_ID

    def test_new_app_no_gamepad_capability_no_sugar(self):
        # Schema with a non-gamepad capability → no provider match → no sugar.
        other_cap = {"id": "unknown_cap", "resources": [], "commands": []}
        target = _target(
            registered=(other_cap,),
            capabilities=frozenset({"sse"}),
        )
        client = _mock_client_hello(target)
        provider = _StubProvider(capability_id=GAMEPAD_CAPABILITY_ID)
        mirror = CapabilityMirror(client=client, providers=[provider])

        mirror.refresh("dev1")
        tools = mirror.build_tools("dev1")
        names = {t.name for t in tools}
        # The stub provider doesn't match unknown_cap → no sugar tool.
        assert "gamepad_stub_tool" not in names
        assert provider.build_calls == []
        # But the provider WAS asked (one matches() call per schema).
        assert len(provider.matches_calls) == 1

    def test_providers_empty_no_sugar_even_for_gamepad(self):
        # No providers registered → known capabilities degrade to meta-only.
        target = _target(registered=(_gamepad_schema_dict(),))
        client = _mock_client_hello(target)
        mirror = CapabilityMirror(client=client)  # providers=None

        mirror.refresh("dev1")
        tools = mirror.build_tools("dev1")
        names = {t.name for t in tools}
        assert "gamepad_stub_tool" not in names


# ---------------------------------------------------------------------------
# Unknown-cap fallback (AC10) — design §5.2 / D3
# ---------------------------------------------------------------------------


class TestUnknownCapabilityFallback:
    def test_unknown_capability_reachable_only_via_meta(self):
        unknown = {
            "id": "experimental_feature",
            "resources": [{"method": "GET", "path": ["status"]}],
            "commands": [{"method": "POST", "path": ["activate"]}],
        }
        target = _target(registered=(unknown,))
        client = _mock_client_hello(target)
        # Only a gamepad provider registered; unknown cap has no match.
        mirror = CapabilityMirror(
            client=client,
            providers=[_StubProvider(capability_id=GAMEPAD_CAPABILITY_ID)],
        )
        mirror.refresh("dev1")
        tools = mirror.build_tools("dev1")

        # The unknown cap contributes NO dedicated tool (D3 fallback). It
        # stays reachable via the meta invoke_command/read_resource tools.
        names = {t.name for t in tools}
        assert "invoke_command" in names
        assert "read_resource" in names
        assert not any("experimental_feature" in n for n in names if n != "invoke_command")


# ---------------------------------------------------------------------------
# Legacy degrade (AC8 old app) — design §5.2 ②
# ---------------------------------------------------------------------------


class TestLegacyDegrade:
    """Old app without FF002 → heuristic on static capabilities tag."""

    def test_no_registered_caps_but_virtual_input_tag_synthesizes_gamepad(self):
        # E 方案 sentinel(AD-B1,Contract §0.2):平面 _parse_schemas 对
        # target.capabilities 每 tag 生成 sentinel CapabilitySchema
        # (capability_id=tag 原值),交 provider.matches(schema) 认领。
        # 业务 provider(GAMEPAD_CAPABILITY_ID="gamepad")内部按 tag→capability
        # 映射认领;此处 _StubProvider 模拟业务 provider,认 sentinel tag
        # (capability_id=LEGACY_GAMEPAD_TAG="virtual_input")。
        target = _target(
            registered=None,
            capabilities=frozenset({LEGACY_GAMEPAD_TAG, "sse"}),
        )
        client = _mock_client_hello(target)
        provider = _StubProvider(capability_id=LEGACY_GAMEPAD_TAG)
        mirror = CapabilityMirror(client=client, providers=[provider])

        mirror.refresh("dev1")
        schemas = mirror.schemas("dev1")
        # E 方案对 2 个 tag(virtual_input + sse)各生成 1 个 sentinel。
        assert len(schemas) == 2
        # sentinel capability_id = tag 原值(E 方案,平面零业务知识)。
        schema_ids = {s.capability_id for s in schemas}
        assert LEGACY_GAMEPAD_TAG in schema_ids
        assert "sse" in schema_ids
        assert all(s.scope == "app" for s in schemas)
        assert all(s.page_id is None for s in schemas)
        assert all(s.page_name is None for s in schemas)
        assert all(s.scope_revision is None for s in schemas)
        # 业务 provider 认领 virtual_input sentinel,build_tools 产 sugar。
        tools = mirror.build_tools("dev1")
        assert any(t.name == "virtual_input_stub_tool" for t in tools)

    def test_no_registered_caps_no_virtual_input_tag_empty_schemas(self):
        # Truly empty /hello (or non-gamepad legacy app) → E 方案仍对每 tag
        # 生成 sentinel(平面零业务知识,不知 sse/profiles 是否 gamepad),
        # 但无业务 provider 认领 → build_tools 不产 sugar(仅 static floor)。
        target = _target(
            registered=None,
            capabilities=frozenset({"sse", "profiles"}),
        )
        client = _mock_client_hello(target)
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        # E 方案对 2 个 tag 各生成 1 个 sentinel(平面零业务知识)。
        assert len(mirror.schemas("dev1")) == 2
        tools = mirror.build_tools("dev1")
        # 无 provider 认领 → 无 sugar,仅 static floor。
        names = {t.name for t in tools}
        assert "list_capabilities" in names

    def test_empty_registered_caps_tuple_treated_as_new_app_empty(self):
        # registered=() means FF002 is present but phone registered nothing.
        # Distinct from registered=None (legacy): heuristic should NOT fire.
        target = _target(registered=(), capabilities=frozenset({LEGACY_GAMEPAD_TAG}))
        client = _mock_client_hello(target)
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        assert mirror.schemas("dev1") == []


# ---------------------------------------------------------------------------
# list_changed — refresh change detection (design §5.5 ③)
# ---------------------------------------------------------------------------


class TestListChanged:
    def test_first_refresh_after_empty_is_change(self):
        target = _target(registered=(_gamepad_schema_dict(),))
        client = _mock_client_hello(target)
        mirror = CapabilityMirror(client=client)
        assert mirror.refresh("dev1") is True

    def test_identical_refresh_no_change(self):
        target = _target(registered=(_gamepad_schema_dict(),))
        client = _mock_client_hello(target)
        mirror = CapabilityMirror(client=client)
        assert mirror.refresh("dev1") is True
        # Second refresh with identical schema → no change.
        assert mirror.refresh("dev1") is False

    def test_schema_grows_is_change(self):
        client = _mock_client_hello(_target(registered=(_gamepad_schema_dict(),)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        # Add a second capability.
        client.hello.return_value = _target(
            registered=(
                _gamepad_schema_dict(),
                {"id": "extra", "resources": [], "commands": []},
            )
        )
        assert mirror.refresh("dev1") is True
        assert len(mirror.schemas("dev1")) == 2

    def test_schema_shrinks_is_change(self):
        client = _mock_client_hello(
            _target(
                registered=(
                    _gamepad_schema_dict(),
                    {"id": "extra", "resources": [], "commands": []},
                )
            )
        )
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        # Drop the second capability.
        client.hello.return_value = _target(registered=(_gamepad_schema_dict(),))
        assert mirror.refresh("dev1") is True
        assert len(mirror.schemas("dev1")) == 1

    def test_page_unregister_is_change_and_removes_schema(self):
        page_a = _gamepad_schema_dict(
            scope="page",
            page_id="page-a",
            page_name="Page A",
            scope_revision=1,
        )
        page_b = _gamepad_schema_dict(
            scope="page",
            page_id="page-b",
            page_name="Page B",
            scope_revision=1,
        )
        client = _mock_client_hello(_target(registered=(page_a, page_b)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")

        client.hello.return_value = _target(registered=(page_b,))

        assert mirror.refresh("dev1") is True
        schemas = mirror.schemas("dev1")
        assert len(schemas) == 1
        assert schemas[0].page_id == "page-b"

    @pytest.mark.parametrize(
        "field,updated",
        [
            ("pageName", "Page A renamed"),
            ("pageId", "page-a2"),
            ("scopeRevision", 2),
        ],
    )
    def test_scope_metadata_change_is_diff(self, field, updated):
        original = _gamepad_schema_dict(
            scope="page",
            page_id="page-a",
            page_name="Page A",
            scope_revision=1,
        )
        changed = dict(original)
        changed[field] = updated
        client = _mock_client_hello(_target(registered=(original,)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")

        client.hello.return_value = _target(registered=(changed,))

        assert mirror.refresh("dev1") is True

    def test_resource_path_change_is_change(self):
        """Change detection compares the full schema, not just capability ids."""
        client = _mock_client_hello(
            _target(
                registered=(
                    _gamepad_schema_dict(
                        commands=[{"method": "POST", "path": ["virtual", "connect"]}]
                    ),
                )
            )
        )
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        # Mutate a path segment.
        client.hello.return_value = _target(
            registered=(
                _gamepad_schema_dict(
                    commands=[{"method": "POST", "path": ["virtual", "disconnect"]}]
                ),
            )
        )
        assert mirror.refresh("dev1") is True

    def test_change_detection_persists_across_refreshes(self):
        """After a reported change, identical subsequent refresh is stable."""
        client = _mock_client_hello(_target(registered=(_gamepad_schema_dict(),)))
        mirror = CapabilityMirror(client=client)
        assert mirror.refresh("dev1") is True
        assert mirror.refresh("dev1") is False
        assert mirror.refresh("dev1") is False


# ---------------------------------------------------------------------------
# /hello unreachable — degrade path (design §5.2 / AC8)
# ---------------------------------------------------------------------------


class TestHelloUnreachable:
    """Any /hello failure → clear cache + static-only degrade."""

    @pytest.mark.parametrize(
        "exc",
        [
            DeviceUnreachable("unknown"),
            DeviceStale("ttl"),
            DeviceHttpError(503, "busy"),
            DeviceHttpError(0, None, "transport: refused"),
            BridgeError("generic"),
        ],
    )
    def test_refresh_clears_cache_returns_truthy_if_had_cache(self, exc):
        # Pre-populate cache with a successful refresh, then make /hello fail.
        client = _mock_client_hello(_target(registered=(_gamepad_schema_dict(),)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        assert mirror.schemas("dev1") != []

        client.hello.side_effect = exc
        result = mirror.refresh("dev1")
        # Going from "had dynamic tools" to "static only" IS a change the AI
        # client must re-list for.
        assert result is True
        assert mirror.schemas("dev1") == []

    def test_refresh_failure_with_no_prior_cache_returns_false(self):
        # First refresh already fails → no prior manifest → False (no change).
        client = _mock_client_hello(raises=DeviceUnreachable("never worked"))
        mirror = CapabilityMirror(client=client)
        assert mirror.refresh("dev1") is False
        assert mirror.schemas("dev1") == []

    def test_build_tools_after_failure_is_static_only(self):
        client = _mock_client_hello(_target(registered=(_gamepad_schema_dict(),)))
        provider = _StubProvider(capability_id=GAMEPAD_CAPABILITY_ID)
        mirror = CapabilityMirror(client=client, providers=[provider])
        mirror.refresh("dev1")
        # Sugar was there.
        assert any(t.name == "gamepad_stub_tool" for t in mirror.build_tools("dev1"))

        # Now /hello fails.
        client.hello.side_effect = DeviceUnreachable("offline")
        mirror.refresh("dev1")
        tools = mirror.build_tools("dev1")
        # Sugar gone — AI is NOT lied to about a phone that's actually offline.
        assert not any(t.name == "gamepad_stub_tool" for t in tools)
        # Static floor intact.
        names = {t.name for t in tools}
        assert "list_capabilities" in names
        assert "list_devices" in names


# ---------------------------------------------------------------------------
# Auth error refresh policy (R001-BB001) — distinct from offline degrade
# ---------------------------------------------------------------------------


class TestRefreshAuthError:
    """DeviceAuthError ≠ offline: keep schema cache, record queryable auth
    state, stay poll-safe (refresh never raises)."""

    def _auth_client(self, code: str = "token_expired"):
        return _mock_client_hello(
            raises=DeviceAuthError(401, {"code": code}, code)
        )

    def test_refresh_auth_error_does_not_raise(self):
        """Poll safety: refresh must not raise on auth errors (poll callers
        like _maybe_emit_list_changed_* depend on this invariant)."""
        client = self._auth_client()
        mirror = CapabilityMirror(client=client)
        assert mirror.refresh("dev1") is False  # no exception

    def test_refresh_auth_error_keeps_schema_cache(self):
        """Auth error must NOT clear the cache (unlike offline): the phone is
        reachable, just unauthorized — capabilities are still valid."""
        client = _mock_client_hello(_target(registered=(_gamepad_schema_dict(),)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        cached = mirror.schemas("dev1")
        assert cached != []

        client.hello.side_effect = DeviceAuthError(
            401, {"code": "token_expired"}, "token_expired"
        )
        assert mirror.refresh("dev1") is False  # not a change
        assert mirror.schemas("dev1") == cached  # cache preserved

    def test_refresh_auth_error_no_had_cache_change_signal(self):
        """Even with a populated cache, auth error returns False (no spurious
        list_changed — offline returning had_cache=True is the contrast)."""
        client = _mock_client_hello(_target(registered=(_gamepad_schema_dict(),)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        client.hello.side_effect = DeviceAuthError(
            401, {"code": "authorization_required"}, "authorization_required"
        )
        assert mirror.refresh("dev1") is False

    def test_auth_error_queryable_per_device(self):
        """auth_error(device_id) exposes the last auth failure; None when
        healthy / offline; cleared on successful refresh."""
        client = self._auth_client()
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        err = mirror.auth_error("dev1")
        assert err is not None
        assert err.code == "token_expired"
        # Other devices unaffected.
        assert mirror.auth_error("other") is None

        # Successful refresh clears the auth state.
        client.hello.side_effect = None
        client.hello.return_value = _target(registered=(_gamepad_schema_dict(),))
        mirror.refresh("dev1")
        assert mirror.auth_error("dev1") is None

    def test_offline_error_not_recorded_as_auth_error(self):
        """Offline/stale/HTTP errors stay degrade-only — no auth state."""
        client = _mock_client_hello(raises=DeviceUnreachable("offline"))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        assert mirror.auth_error("dev1") is None
        assert mirror.schemas("dev1") == []  # offline still clears cache

    def test_offline_still_clears_cache_after_auth_error(self):
        """Auth error keeps cache; a subsequent offline error still clears it
        (degrade path unchanged regardless of prior auth state)."""
        client = _mock_client_hello(_target(registered=(_gamepad_schema_dict(),)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        client.hello.side_effect = DeviceAuthError(
            401, {"code": "token_expired"}, "token_expired"
        )
        mirror.refresh("dev1")
        assert mirror.schemas("dev1") != []
        client.hello.side_effect = DeviceUnreachable("now offline")
        assert mirror.refresh("dev1") is True  # had-cache degrade transition
        assert mirror.schemas("dev1") == []
        assert mirror.auth_error("dev1") is None


# ---------------------------------------------------------------------------
# CapabilitySchema parsing — design §4.1
# ---------------------------------------------------------------------------


class TestSchemaParsing:
    def test_parses_resources_and_commands_with_description(self):
        cap = {
            "id": GAMEPAD_CAPABILITY_ID,
            "resources": [
                {"method": "GET", "path": ["profiles"], "description": "list profiles"},
            ],
            "commands": [
                {"method": "POST", "path": ["virtual", "connect"], "description": "connect"},
                {"method": "POST", "path": ["input"]},  # description omitted
            ],
        }
        client = _mock_client_hello(_target(registered=(cap,)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        schemas = mirror.schemas("dev1")
        assert len(schemas) == 1
        s = schemas[0]
        assert s.capability_id == GAMEPAD_CAPABILITY_ID
        assert s.resources == (
            ResourceDecl(method="GET", path=("profiles",), description="list profiles"),
        )
        assert s.commands == (
            CommandDecl(method="POST", path=("virtual", "connect"), description="connect"),
            CommandDecl(method="POST", path=("input",), description=None),
        )
        assert s.scope == "app"
        assert s.page_id is None
        assert s.page_name is None
        assert s.scope_revision is None

    def test_parses_page_scope_metadata(self):
        cap = _gamepad_schema_dict(
            scope="page",
            page_id="page-a",
            page_name="Page A",
            scope_revision=3,
        )
        client = _mock_client_hello(_target(registered=(cap,)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")

        s = mirror.schemas("dev1")[0]

        assert s.scope == "page"
        assert s.page_id == "page-a"
        assert s.page_name == "Page A"
        assert s.scope_revision == 3

    def test_malformed_scope_metadata_downgrades_locally(self):
        cap = _gamepad_schema_dict(
            scope="popup",
            page_id=123,
            page_name={"bad": True},
            scope_revision=True,
        )
        client = _mock_client_hello(_target(registered=(cap,)))
        mirror = CapabilityMirror(client=client)

        assert mirror.refresh("dev1") is True
        s = mirror.schemas("dev1")[0]
        assert s.scope == "app"
        assert s.page_id is None
        assert s.page_name is None
        assert s.scope_revision is None
        assert mirror.auth_error("dev1") is None

    def test_same_capability_id_under_multiple_pages_coexists(self):
        cap_a = _gamepad_schema_dict(scope="page", page_id="page-a")
        cap_b = _gamepad_schema_dict(scope="page", page_id="page-b")
        client = _mock_client_hello(_target(registered=(cap_a, cap_b)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")

        schemas = mirror.schemas("dev1")

        assert len(schemas) == 2
        assert [s.capability_id for s in schemas] == [
            GAMEPAD_CAPABILITY_ID,
            GAMEPAD_CAPABILITY_ID,
        ]
        assert {s.page_id for s in schemas} == {"page-a", "page-b"}

    def test_provider_receives_full_page_schema(self):
        cap = _gamepad_schema_dict(
            scope="page",
            page_id="page-a",
            page_name="Page A",
            scope_revision=7,
        )
        client = _mock_client_hello(_target(registered=(cap,)))
        provider = _StubProvider(capability_id=GAMEPAD_CAPABILITY_ID)
        mirror = CapabilityMirror(client=client, providers=[provider])
        mirror.refresh("dev1")

        mirror.build_tools("dev1")

        assert provider.matches_calls[0].scope == "page"
        assert provider.matches_calls[0].page_id == "page-a"
        assert provider.matches_calls[0].page_name == "Page A"
        assert provider.matches_calls[0].scope_revision == 7
        assert provider.build_calls[0] == provider.matches_calls[0]

    def test_description_optional(self):
        cap = {"id": "bare", "resources": [{"method": "GET", "path": ["x"]}]}
        client = _mock_client_hello(_target(registered=(cap,)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        s = mirror.schemas("dev1")[0]
        assert s.resources[0].description is None

    def test_non_dict_resource_item_skipped(self):
        # resources[] containing a non-dict item → that item skipped, others kept.
        cap = {
            "id": "mixed",
            "resources": [
                "not-a-dict",  # skipped
                {"method": "GET", "path": ["ok"]},
            ],
        }
        client = _mock_client_hello(_target(registered=(cap,)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        s = mirror.schemas("dev1")[0]
        assert len(s.resources) == 1
        assert s.resources[0].path == ("ok",)

    def test_malformed_entry_skipped_not_raised(self):
        # One bad entry must not poison the whole parse.
        cap_list = (
            {"id": "good", "resources": [], "commands": []},
            {"id": "bad", "resources": "not-a-list"},  # malformed resources
            {"id": "bad2", "resources": [{"method": 1, "path": ["x"]}]},  # bad method
            {"id": "bad3", "resources": [{"method": "GET", "path": "not-a-list"}]},
            "not-a-dict",  # not even a dict
        )
        client = _mock_client_hello(_target(registered=cap_list))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        schemas = mirror.schemas("dev1")
        ids = [s.capability_id for s in schemas]
        # Dict entries parsed (defensive: bad resources/commands → empty
        # tuple); the str entry "not-a-dict" is skipped entirely.
        assert "good" in ids
        assert "bad" in ids
        assert "bad2" in ids
        assert "bad3" in ids
        assert "not-a-dict" not in ids  # str entry skipped
        # Malformed resources/commands degrade to empty tuples, not raise.
        bad = next(s for s in schemas if s.capability_id == "bad")
        assert bad.resources == ()
        assert bad.commands == ()
        bad3 = next(s for s in schemas if s.capability_id == "bad3")
        assert bad3.resources == ()  # bad path (non-list) → skipped

    def test_missing_id_yields_empty_capability_id(self):
        cap = {"resources": [], "commands": []}  # no id key
        client = _mock_client_hello(_target(registered=(cap,)))
        mirror = CapabilityMirror(client=client)
        mirror.refresh("dev1")
        s = mirror.schemas("dev1")[0]
        assert s.capability_id == ""


# ---------------------------------------------------------------------------
# Provider registration hook
# ---------------------------------------------------------------------------


class TestProviderRegistration:
    def test_register_provider_after_construction(self):
        client = _mock_client_hello(_target(registered=(_gamepad_schema_dict(),)))
        mirror = CapabilityMirror(client=client)  # no providers
        mirror.refresh("dev1")
        # No sugar yet.
        assert not any(
            "stub" in t.name for t in mirror.build_tools("dev1")
        )

        provider = _StubProvider(capability_id=GAMEPAD_CAPABILITY_ID)
        mirror.register_provider(provider)
        # Refresh to pick up the new provider in the manifest.
        mirror.refresh("dev1")
        tools = mirror.build_tools("dev1")
        assert any(t.name == "gamepad_stub_tool" for t in tools)

    def test_register_provider_idempotent(self):
        client = _mock_client_hello(_target())
        mirror = CapabilityMirror(client=client)
        provider = _StubProvider(capability_id=GAMEPAD_CAPABILITY_ID)
        mirror.register_provider(provider)
        mirror.register_provider(provider)  # duplicate no-op
        assert mirror._providers.count(provider) == 1

    def test_first_matching_provider_wins(self):
        # Two providers both match gamepad; the first-registered one wins.
        target = _target(registered=(_gamepad_schema_dict(),))
        client = _mock_client_hello(target)

        @dataclass
        class _NamedStub(_StubProvider):
            tool_name: str = "default"

            def build_tools(self, schema: CapabilitySchema) -> list[ToolSpec]:
                self.build_calls.append(schema)
                return [ToolSpec(name=self.tool_name, description="", input_schema={})]

        first = _NamedStub(capability_id=GAMEPAD_CAPABILITY_ID, tool_name="first_tool")
        second = _NamedStub(capability_id=GAMEPAD_CAPABILITY_ID, tool_name="second_tool")
        mirror = CapabilityMirror(client=client, providers=[first, second])
        mirror.refresh("dev1")
        tools = mirror.build_tools("dev1")
        names = {t.name for t in tools}
        assert "first_tool" in names
        assert "second_tool" not in names
