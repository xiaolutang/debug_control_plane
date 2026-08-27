# Changelog

## 0.4.0 - 2026-08-27

- Protocol: capabilities now carry app/page dual scope metadata
  (`scope`/`pageId`/`scopeRevision` in `/hello.registeredCapabilities`,
  default `app` — old fixtures stay valid).
- Scoped selector dispatch: `X-DCP-Capability-*` headers route page-scoped
  calls; invoking a capability whose page has closed returns
  `410 page_capability_gone` with an explicit refresh hint.
- Kotlin/Dart/Python: isomorphic scoped capability keys; page lifecycle
  registration (open → register, leave → release) verified end-to-end on an
  Android 16 real device.
- Python MCP: tools/list_changed refresh and stale page-tool convergence
  (gone/expired).
- Flutter plugin: `PageCapabilityScope` helper + `Page Scope Demo` acceptance
  pages; CI gains the `[9] r003-scope-cross-stack` cross-stack guard.

## 0.3.0 - 2026-08-25

- Kotlin/Flutter: add Android auth acceptance flow coverage and stabilize the
  Flutter example's native plane startup/teardown for repeated real-device
  integration runs.
- Flutter plugin: align the Android dependency to Kotlin core `0.3.0`.
- Release: restore a single aligned version line across Kotlin core, Dart core,
  Flutter plugin, and Python after the Kotlin-only `0.2.1` patch.

## 0.2.1 - 2026-08-19

- Kotlin: publish public ABI dependencies (`NanoHTTPD` and
  `kotlinx-coroutines-core`) as compile-scope API dependencies so Android
  native consumers no longer see missing-supertype warnings for
  `HttpSseTransport`.
- Docs: clarify Android lifecycle ownership. The app or Service that starts the
  plane must call `plane.stop()` when its owner lifecycle ends; closing an
  Activity does not release the fixed `18080` port while the process or Service
  remains alive.

## 0.1.2 - 2026-08-13

- Dart: add `GETTING_STARTED.md` integration guide (5-step integration + capability authoring + platform matrix + pitfalls).

## 0.1.1 - 2026-08-13

- Clean public release. The previously published 0.1.0 artifact carried internal
  residue; 0.1.1 is the first clean release — prefer it.
- Python: declare `anyio` explicitly in `pyproject.toml`; device-pool persistence
  path moved to `~/.debug-control-plane/devices.json`.
- CI: repo-level zero-business-dependency gate (dart analyze + python AST
  allowlist + ruff fatal-level).

## 0.1.0 - 2026-08-09

- Initial release: Dart package (pub.dev) + Python package (PyPI).
- Three-layer skeleton: Transport / ControlPlane / Capability.
- `device_discovery` (USB / LAN / cross-identify) + `mcp_plane` (stdio MCP server).
