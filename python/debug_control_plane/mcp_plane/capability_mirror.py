"""Dynamic capability mirror — translate ``/hello`` into a tool manifest.

(R020-BF009)

Role (design §3.4 CapabilityMirror / §4.1 CapabilitySchema / §4.2 tools /
§5.2 dynamic-mirror decision flow / §5.5 tool-table consistency):

    The CapabilityMirror is the **adapter layer** between the phone's runtime
    capability schema (``/hello.registeredCapabilities``, FF002 output) and
    the MCP tool surface. It produces a *tool manifest* (name / description /
    JSON-schema input) that BF011 (McpServer) maps onto the MCP SDK.

    Three orthogonal concerns (design §3.4 single-direction dependency):

      * **Identity** (``device_id``) is stable — handled by :class:`DevicePool`.
      * **HTTP probe** (``/hello``) is the only outbound arrow — owned by
        :class:`BridgeClient.hello`.
      * **Mirror** (this module) is pure logic: ``NetworkTarget`` →
        ``list[ToolSpec]``. No SDK dependency, no I/O of its own.

Why a custom ToolSpec (not the mcp SDK ``Tool``)? BF009 is the **logic layer**
(the /hello → tool-list translation), BF011 is the **SDK integration layer**
(map ToolSpec → mcp Tool + register handler). Keeping them separate means
BF009 is unit-testable without booting a server and BF011 owns the single
SDK touchpoint (YAGNI + layered design).

Dynamic-mirror decision flow (design §5.2 — "app-not-running must not lie"):

    * pool empty / device_id unknown       → static meta + device-mgmt only
    * /hello unreachable (offline/stale/HTTP error)
                                            → clear cache, static only (degrade)
    * new app (registeredCapabilities)      → parse CapabilitySchema[]
        * known cap (a SemanticProvider matches)
                                            → semantic-sugar tools (BF010 gamepad)
        * unknown cap (no provider matches) → D3 fallback: reachable ONLY via
                                              the meta ``invoke_command`` tool
                                              (no extra tool added)
    * legacy app (no FF002, static ``capabilities`` only)
                                            → E 方案 sentinel:对每 capability
                                              tag 生成 sentinel schema 交
                                              provider.matches 认领(AC8 degrade)

Why SemanticProvider is pluggable (decoupling BF010):

    The gamepad semantic sugar is BF010's job. BF009 defines a *hook*
    (``SemanticProvider`` protocol + a provider registry on CapabilityMirror)
    so BF010 can register its gamepad provider without BF009 importing it.
    BF009 ships with **no built-in provider**; its own tests inject a stub
    provider to exercise the hook mechanism. This keeps BF009 free of any
    forward dependency on BF010.

list_changed via pure polling (design §5.5 ③, this iteration only):

    ``refresh(device_id)`` re-fetches /hello, parses the schema, and compares
    it against the cached snapshot via :meth:`_diff_changed`. If the manifest
    changed, the cache is rebuilt and ``True`` is returned so BF011 can emit
    ``notifications/tools/list_changed``. **This iteration does NOT implement
    the ``/events capability_changed`` real-time side channel** (R019
    register/unregister don't emit it; design §5.5 D-3 lists it as plan-TBD).
    BF009 only provides the change-detection signal; BF011 owns the actual
    notification send.

Refs:
    - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF009
    - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
              §3.4 CapabilityMirror / §4.1 CapabilitySchema / §4.2 / §5.2 / §5.5
    - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

from debug_control_plane.device_discovery.protocol import JsonMap, NetworkTarget

# BF007: 包内相对 bridge_client + 跨包 device_discovery.protocol(BF006 已迁)。
from .bridge_client import (
    BridgeClient,
    BridgeError,
    DeviceHttpError,
    DeviceStale,
    DeviceUnreachable,
)

# ---------------------------------------------------------------------------
# DTOs — capability schema mirror (design §4.1 CapabilitySchema)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ResourceDecl:
    """A single REST resource declared by a phone capability.

    Mirrors ``registeredCapabilities[].resources[]`` (FF002). ``description``
    is optional — legacy resources registered without a description yield
    ``None`` (FF002 D2 backward-compatible constructor).
    """

    method: str
    path: tuple[str, ...]
    description: str | None = None


@dataclass(frozen=True)
class CommandDecl:
    """A single command declared by a phone capability.

    Mirrors ``registeredCapabilities[].commands[]`` (FF002). ``description``
    is optional for the same reason as :class:`ResourceDecl`.
    """

    method: str
    path: tuple[str, ...]
    description: str | None = None


@dataclass(frozen=True)
class CapabilitySchema:
    """A single phone capability mirrored from ``/hello`` (design §4.1).

    Frozen + tuple-valued so two schemas parsed from identical JSON compare
    equal — :meth:`CapabilityMirror._diff_changed` relies on this for the
    list_changed change-detection signal (design §5.5 ③).

    Attributes:
        capability_id: the capability ``id`` (e.g. ``gamepad``).
        resources: declared REST resources (read side).
        commands: declared commands (write side).
        description: optional capability-level description (may be absent).
    """

    capability_id: str
    resources: tuple[ResourceDecl, ...] = ()
    commands: tuple[CommandDecl, ...] = ()
    description: str | None = None


# ---------------------------------------------------------------------------
# ToolSpec — manifest DTO (decoupled from mcp SDK, design D3)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ToolSpec:
    """A single tool's manifest entry (name + description + input schema).

    BF009 produces the *manifest*; BF011 maps each ToolSpec onto the MCP SDK
    (``Tool`` + handler registration). ``input_schema`` is a JSON Schema dict
    describing the tool's arguments (the MCP spec requires one per tool).
    """

    name: str
    description: str
    input_schema: dict[str, Any]


# ---------------------------------------------------------------------------
# SemanticProvider — pluggable hook for known-capability sugar (BF010)
# ---------------------------------------------------------------------------


class SemanticProvider(Protocol):
    """Builds semantic-sugar tools for a known capability.

    BF010 (gamepad) implements this protocol and registers its instance on
    :class:`CapabilityMirror` via the ``providers`` constructor arg. BF009
    ships no built-in provider — the hook itself is exercised by a stub in
    BF009's own tests.

    Contract:
        * :meth:`matches` is called once per parsed schema; return ``True`` if
          this provider owns the capability (it then gets to build tools for
          it). ``legacy_capabilities`` is the static ``/hello.capabilities``
          frozenset (legacy/degrade mode); providers may match on it when no
          structured schema is present (E 方案 sentinel 路径)。
        * :meth:`build_tools` returns the manifest entries for the matched
          capability. The schema is the structured mirror (when present) or a
          synthetic legacy schema (capability_id set, empty resources/commands)
          so providers don't have to special-case legacy mode.
    """

    def matches(
        self,
        schema: CapabilitySchema,
        *,
        legacy_capabilities: frozenset[str] | None = None,
    ) -> bool:
        """Return True if this provider owns the given capability."""
        ...

    def build_tools(self, schema: CapabilitySchema) -> list[ToolSpec]:
        """Return the semantic-sugar tools for the matched capability."""
        ...


# ---------------------------------------------------------------------------
# Static tool manifests — meta + device-management (design §4.2.1 / §4.2.2)
# ---------------------------------------------------------------------------

#: Common JSON-Schema fragment for the ``device_id`` parameter. Used across
#: all per-device tools so the spelling stays consistent.
_DEVICE_ID_PARAM: dict[str, Any] = {
    "type": "object",
    "properties": {
        "device_id": {
            "type": "string",
            "description": "Stable device identity (from list_devices).",
        },
    },
    "required": ["device_id"],
    "additionalProperties": False,
}

#: Generic meta tools reachable for ANY capability (design §4.2.2). Always
#: present in the manifest regardless of /hello state — this is the floor
#: the AI can rely on even when no phone app is running (AC8 degrade + AC10
#: unknown-cap fallback both route through ``invoke_command``).
_STATIC_META_TOOLS: tuple[ToolSpec, ...] = (
    ToolSpec(
        name="list_capabilities",
        description=(
            "List the device's runtime capabilities (mirrors /hello). "
            "Returns the capability schema array; each entry exposes "
            "resources/commands reachable via invoke_command/read_resource."
        ),
        input_schema=_DEVICE_ID_PARAM,
    ),
    ToolSpec(
        name="invoke_command",
        description=(
            "Forward an arbitrary capability command (unknown-capability "
            "fallback). Pass capability_id + command_path segments + args "
            "object; the phone's response is returned verbatim."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "device_id": {"type": "string"},
                "capability_id": {"type": "string"},
                "command_path": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "URL path segments, e.g. [virtual, connect].",
                },
                "args": {
                    "type": ["object", "null"],
                    "description": "Request body (object) or null.",
                    "additionalProperties": True,
                },
            },
            "required": ["device_id", "capability_id", "command_path"],
            "additionalProperties": False,
        },
    ),
    ToolSpec(
        name="read_resource",
        description=(
            "Read an arbitrary capability resource (unknown-capability "
            "fallback). Pass capability_id + resource_path segments; the "
            "phone's response is returned verbatim."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "device_id": {"type": "string"},
                "capability_id": {"type": "string"},
                "resource_path": {
                    "type": "array",
                    "items": {"type": "string"},
                },
                "params": {
                    "type": ["object", "null"],
                    "additionalProperties": True,
                },
            },
            "required": ["device_id", "capability_id", "resource_path"],
            "additionalProperties": False,
        },
    ),
    ToolSpec(
        name="get_state",
        description=(
            "Read the device's aggregated state (mobile /state endpoint)."
        ),
        input_schema=_DEVICE_ID_PARAM,
    ),
    ToolSpec(
        name="subscribe_events",
        description=(
            "Subscribe to the device's event stream (mobile /events SSE). "
            "Optional event_types filter restricts which event types are "
            "yielded."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "device_id": {"type": "string"},
                "event_types": {
                    "type": "array",
                    "items": {"type": "string"},
                },
            },
            "required": ["device_id"],
            "additionalProperties": False,
        },
    ),
)

#: Device-management tools (design §4.2.1). Always present; they let the AI
#: discover/register/list devices even before any phone app is reachable.
_DEVICE_MGMT_TOOLS: tuple[ToolSpec, ...] = (
    ToolSpec(
        name="list_devices",
        description="List all devices currently known to the pool.",
        input_schema={
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    ),
    ToolSpec(
        name="discover_devices",
        description=(
            "Trigger active USB + LAN device discovery and cross-identify "
            "candidates into the pool. Set force=True to bypass the cache."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "force": {"type": "boolean", "default": False},
            },
            "additionalProperties": False,
        },
    ),
    ToolSpec(
        name="register_device",
        description=(
            "Register a device manually by host (fallback when discovery "
            "can't find it). Probes /hello for the runtime label."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "host": {"type": "string"},
                "port": {"type": "integer", "default": 18080},
                "label": {"type": "string"},
            },
            "required": ["host"],
            "additionalProperties": False,
        },
    ),
)


# ---------------------------------------------------------------------------
# Service — CapabilityMirror
# ---------------------------------------------------------------------------


class CapabilityMirror:
    """Dynamic capability mirror: /hello → tool manifest (design §3.4 / §5.2).

    The mirror is **stateless w.r.t. IPs** — every :meth:`refresh` and
    :meth:`build_tools` call that needs /hello asks :class:`BridgeClient.hello`
    (which itself asks the pool per call). The only state held here is the
    parsed schema cache used for change detection (§5.5 ③).

    Lifecycle:
        * :meth:`refresh(device_id)` — re-fetch /hello, rebuild cache, signal
          whether the manifest changed (for list_changed). Idempotent; safe
          to call on a poll timer.
        * :meth:`schemas(device_id)` — read the cached schemas (no I/O).
        * :meth:`build_tools(device_id)` — snapshot-rebuild the manifest:
          static meta + device-mgmt + dynamic (semantic sugar / unknown-cap
          no-op fallback). ``device_id=None`` or no cache → static only
          (AC8 degrade path).

    Args:
        client: BF008 BridgeClient — the /hello probe goes through here.
        providers: optional list of :class:`SemanticProvider` (BF010
            registers gamepad here). ``None`` ⇒ no semantic sugar at all
            (every known capability degrades to the meta invoke_command).
    """

    def __init__(
        self,
        client: BridgeClient,
        *,
        providers: list[SemanticProvider] | None = None,
    ) -> None:
        self._client = client
        # Snapshot list — providers are registered at construction. BF010
        # will inject its gamepad instance; BF009's own tests use a stub.
        self._providers: list[SemanticProvider] = list(providers or [])
        # device_id → parsed schema snapshot. Runtime-only, never persisted
        # (design §4.1 note: capability schema is CapabilityMirror's runtime
        # mirror, NOT a DeviceRecord field).
        self._cache: dict[str, list[CapabilitySchema]] = {}

    # ------------------------------------------------------------------
    # Provider registry (BF010 registration hook)
    # ------------------------------------------------------------------

    def register_provider(self, provider: SemanticProvider) -> None:
        """Append a :class:`SemanticProvider` (BF010 registers gamepad here).

        Idempotent in identity (no duplicate insert) but not in behavior:
        registering after the first :meth:`build_tools` call does NOT
        retroactively refresh the manifest — call :meth:`refresh` to pick up
        the new provider.
        """
        if provider not in self._providers:
            self._providers.append(provider)

    # ------------------------------------------------------------------
    # /hello probe + change detection (design §5.5 ③)
    # ------------------------------------------------------------------

    def refresh(self, device_id: str) -> bool:
        """Re-probe /hello, rebuild cache, return True if manifest changed.

        Used by BF011 on a poll timer to drive ``notifications/tools/list_changed``
        (design §5.5 B/C). /hello failures are **degrade-only**: the cache is
        cleared and ``False`` is returned (no spurious list_changed). The next
        :meth:`build_tools` will fall back to static-only so the AI is never
        lied to about a phone that's actually offline.

        Returns:
            True iff the parsed schema differs from the cached snapshot
            (including "no cache → cache populated", which IS a change).
            False if /hello failed (cache cleared) or the schema is identical.
        """
        try:
            target = self._client.hello(device_id)
        except (DeviceUnreachable, DeviceStale, DeviceHttpError, BridgeError):
            # Any /hello failure → degrade. Clear cache so build_tools falls
            # to static-only and a later successful refresh re-signals the
            # transition back. We do NOT report a change here: list_changed
            # signals "the manifest grew/shrank", and going from "had tools"
            # to "static only" is a real change — but only if we actually had
            # a non-empty manifest before. Reporting False on a cache→empty
            # transition would be a lie, so we surface it honestly.
            had_cache = device_id in self._cache
            self._cache.pop(device_id, None)
            # Transition from "had dynamic tools" to "static only" IS a change
            # the AI client needs to know about (its cached tools are stale).
            return had_cache

        new_schemas = self._parse_schemas(target)
        old_schemas = self._cache.get(device_id)
        changed = old_schemas != new_schemas
        if changed:
            self._cache[device_id] = new_schemas
        return changed

    # ------------------------------------------------------------------
    # Cache access (no I/O)
    # ------------------------------------------------------------------

    def schemas(self, device_id: str) -> list[CapabilitySchema]:
        """Return the cached schemas for ``device_id`` (empty list if none).

        Does NOT probe /hello — call :meth:`refresh` first. Returns a *copy*
        so the caller can't mutate the cache via the returned reference.
        """
        cached = self._cache.get(device_id)
        return list(cached) if cached else []

    # ------------------------------------------------------------------
    # Manifest rebuild (design §5.5 ① snapshot rebuild)
    # ------------------------------------------------------------------

    def build_tools(self, device_id: str | None = None) -> list[ToolSpec]:
        """Snapshot-rebuild the tool manifest for ``device_id``.

        Combines (in order, so semantic-sugar names never collide with meta
        because BF010 owns its naming namespace):

            1. static meta tools (always present, design §4.2.2)
            2. device-management tools (always present, design §4.2.1)
            3. dynamic semantic-sugar tools (only when a provider matches)

        Unknown-capability fallback (design §5.2 / AC10): a parsed capability
        with no matching provider contributes NO extra tool — it stays
        reachable only via the meta ``invoke_command``/``read_resource``
        tools. This guarantees the AI can drive any capability even before
        BF010 lands a dedicated sugar for it.

        ``device_id=None`` or no cached schema → static meta + device-mgmt
        only (the AC8 degrade path: AI learns there's nothing to operate on
        and can discover/register first).

        Returns:
            A new list each call (snapshot — caller owns it). Tool names are
            unique within the result by construction.
        """
        tools: list[ToolSpec] = list(_STATIC_META_TOOLS) + list(_DEVICE_MGMT_TOOLS)

        if device_id is None:
            return tools

        cached = self._cache.get(device_id)
        if not cached:
            # No prior refresh (or last refresh failed) → degrade to static.
            # We do NOT implicitly probe /hello here: build_tools is called
            # on every tools/list and must stay cheap + never surprise the
            # caller with a network round-trip. refresh() owns the probe.
            return tools

        for schema in cached:
            tools.extend(self._build_sugar(schema))
        return tools

    def _build_sugar(self, schema: CapabilitySchema) -> list[ToolSpec]:
        """Ask registered providers for semantic-sugar tools for one schema.

        First-matching-provider wins (BF010 gamepad is the only realistic
        provider this iteration). If no provider matches, the schema is
        treated as "unknown capability" and contributes no tools (the D3
        fallback: reachable only via meta invoke_command/read_resource).
        """
        for provider in self._providers:
            if provider.matches(schema):
                return provider.build_tools(schema)
        return []

    # ------------------------------------------------------------------
    # /hello → CapabilitySchema parsing (design §4.1 CapabilitySchema)
    # ------------------------------------------------------------------

    def _parse_schemas(self, target: NetworkTarget) -> list[CapabilitySchema]:
        """Parse the phone's runtime capability schema into CapabilitySchema[].

        平面零 gamepad 业务知识(AD-B1)。两条路径:

          * **新 app**(FF002):``target.registered_capabilities`` 是 tuple
            of dicts,每 dict 形如 ``{id, resources[], commands[]}``,逐个
            解析为 :class:`CapabilitySchema`(description 可选)。
          * **Legacy app**(pre-FF002):``registered_capabilities`` 为 None,
            对 ``target.capabilities`` 每 tag 生成 **sentinel**
            :class:`CapabilitySchema`(``capability_id=tag``, 空
            ``resources``/``commands``),交 :meth:`SemanticProvider.matches`
            认领(E 方案 OI-B1 resolved)。平面不知 ``virtual_input``→
            ``gamepad`` 映射(业务知识,业务 provider 内部按 tag 认领)。
          * 两条信号均缺 → 空 schema list(build_tools 降级到 static-only)。
        """
        registered = target.registered_capabilities
        if registered is not None:
            return [
                self._parse_one(cap)
                for cap in registered
                if isinstance(cap, dict)
            ]

        # Legacy degrade path: E 方案 sentinel(AD-B1,平面零 gamepad 业务知识)。
        # 对 target.capabilities 每 tag 生成 sentinel CapabilitySchema,
        # 交 provider.matches(schema) 认领(业务 provider 内部按 tag→capability
        # 映射产 tools)。
        if target.capabilities:
            return [
                CapabilitySchema(
                    capability_id=tag,
                    resources=(),
                    commands=(),
                    description=None,
                )
                for tag in target.capabilities
            ]
        return []

    @staticmethod
    def _parse_one(cap: JsonMap) -> CapabilitySchema:
        """Parse a single registeredCapabilities entry into CapabilitySchema.

        Defensive against malformed entries: a missing/non-string ``id`` yields
        an empty-id schema (which won't match any provider, so it degrades to
        the unknown-capability fallback). Resources/commands lists default to
        empty when missing or malformed.
        """
        cap_id_raw = cap.get("id")
        cap_id = cap_id_raw if isinstance(cap_id_raw, str) and cap_id_raw else ""

        resources = _parse_decls(cap.get("resources"), ResourceDecl)
        commands = _parse_decls(cap.get("commands"), CommandDecl)
        description_raw = cap.get("description")
        description = (
            description_raw if isinstance(description_raw, str) and description_raw else None
        )
        return CapabilitySchema(
            capability_id=cap_id,
            resources=resources,
            commands=commands,
            description=description,
        )


# ---------------------------------------------------------------------------
# Module-level parsing helpers (pure functions for testability)
# ---------------------------------------------------------------------------


def _parse_decls(
    raw: Any,
    decl_cls: type[ResourceDecl] | type[CommandDecl],
) -> tuple[ResourceDecl, ...] | tuple[CommandDecl, ...]:
    """Parse a resources[]/commands[] list into frozen decl tuples.

    Each entry is expected to be ``{method, path, ?description}``. ``method``
    and ``path`` are required and coerced defensively: a non-string method or
    non-list path skips the entry (rather than raising) so one bad entry in
    the phone's payload can't crash the whole manifest build. ``description``
    is optional and stays ``None`` when absent or non-string.

    The decl_cls argument selects between ResourceDecl and CommandDecl so the
    same logic parses both; mypy can't follow the union return, so callers
    treat the result as a sequence of the matching decl type.
    """
    if not isinstance(raw, list):
        return ()  # type: ignore[return-value]
    out: list[Any] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        method = item.get("method")
        path = item.get("path")
        if not isinstance(method, str) or not isinstance(path, list):
            continue
        description = item.get("description")
        desc = description if isinstance(description, str) and description else None
        out.append(decl_cls(method=method, path=tuple(str(p) for p in path), description=desc))
    return tuple(out)  # type: ignore[return-value]


__all__ = [
    "CapabilityMirror",
    "CapabilitySchema",
    "CommandDecl",
    "ResourceDecl",
    "SemanticProvider",
    "ToolSpec",
]
