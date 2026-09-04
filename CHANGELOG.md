# Changelog

## 0.5.2 - 2026-09-04

- Authorization policy assembly API (R006): authorization is an
  **assembly-time decision**, not a plugin implementation detail. The
  `plane.start` channel accepts an optional `authPolicy`
  ("default"/"auto"/"none"); absent = 0.5.1 behavior byte-for-byte
  (existing hosts are unaffected).
- Kotlin assembly layer: `PluginDebugAuthManager` gains an `autoApprove`
  flag (existing constructors unchanged) — `auto` approves each pending
  request on landing (existing issuance reused, host notification still
  fires, nonce replay idempotent); `none` mounts the plane without an
  auth manager (isomorphic with pure-Dart hosts, `/hello` has no
  `authRequired`); illegal wire values fail fast with `invalid_arguments`
  (plane never mounts, no silent fallback); JOIN does not rebuild.
- Flutter plugin Dart surface: `AuthPolicy` enum (`defaultPolicy` avoids
  the Dart reserved word; wire stays "default") + `start(authPolicy:)`
  pass-through + package export; alignment test extended (constants +
  error codes string-identical with Kotlin).
- Acceptance: JVM K1–K8 (89 tests, 0 failed); real-device e2e E1–E6 on
  Xiaomi Android 16 (auto approve chain / bearer / cold-restart
  persistence under auto / none parity — no `authRequired` field /
  bogus collapses to default + K5 fail-fast / default regression);
  iOS-simulator regression I1–I5 all PASS. Python MCP host: zero
  changes (version-line alignment only).

## 0.5.1 - 2026-09-03

- Dart-plane token persistence (R005): completes the 0.5.0 persistence work
  for Dart-plane hosts (iOS simulator / pure-Dart) — the approval dialog now
  appears only once per token lifetime on **all** plane types.
- dart core: new `DebugAuthStore` abstraction (exactly 5 methods) +
  `InMemoryDebugAuthStore` + `FileBackedDebugAuthStore` decorator (lazy load,
  corrupt-fallback-to-empty, expired rows dropped at load, atomic
  tmp+rename writes); hand-written pure-Dart SHA-256 (FIPS 180-4) with public
  `debugAuthTokenHash` alias — zero new dependencies. Only token **hashes**
  are persisted, never plaintext.
- flutter plugin Dart surface (API-compatible): example/acceptance hosts can
  inject a `DebugAuthStore`; default remains in-memory, with file-backed
  persistence mounted at the assembly layer (`main()`). Default token TTL
  15min → 7 days, aligning with the Kotlin side.
- Acceptance: iOS-simulator integration suite I1–I5 (cold-restart with old
  Bearer → 200 authorized and zero approval dialogs, corrupt-file self-heal,
  TTL window, wire regression) — verified on iPhone 16e iOS 18.5 simulator.

## 0.5.0 - 2026-09-01

- Token persistence (R004): debug-plane bearer tokens now survive process
  restarts on both ends — the approval dialog only appears once per token
  lifetime instead of once per process.
- Flutter plugin (Android): `FileBackedPluginDebugAuthStore` persists token
  **hash records** to `filesDir/debug_control_plane/debug_auth_tokens.json`
  (atomic tmp+rename, corrupt-fallback-to-empty, expired-row cleanup);
  plaintext tokens never touch disk. `onAttachedToEngine` upgrades the
  in-memory store lazily with zero-copy migration.
- Default token TTL raised from 1h to 7 days
  (`DEFAULT_TOKEN_TTL_SECONDS = 604800`; explicit `ttlSeconds` overrides
  unchanged).
- Python MCP: `FileTokenProvider` persists tokens to
  `~/.debug-control-plane/tokens.json` (0600 via `os.open`, atomic
  `os.replace`); claim auto-saves, Bearer auto-reuses, and 401
  token_expired/token_revoked/invalid_token auto-clear the row.
- Acceptance: install -r (keep-data) replaces unconditional uninstall in the
  e2e script; uninstall only via the `DELETE_AND_REINSTALL=1` escape hatch.
  Verified on Xiaomi HyperOS Android 16: 6/6 e2e cases pass (cold restart,
  reinstall, python restart, expiry re-auth, fresh-install reset).

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
