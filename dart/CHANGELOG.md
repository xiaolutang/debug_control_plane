# Changelog

## 0.5.2 - 2026-09-04

- Version alignment only (no dart-core API changes this release): the
  authorization-policy assembly API (R006 `AuthPolicy`) lives in the
  Flutter plugin's bridge surface; dart core is consumed unchanged via
  the `^0.5.2` dependency line.

## 0.5.1 - 2026-09-03

- New token store API (R005): `DebugAuthStore` abstraction (exactly 5
  methods: tokenByHash/putToken/markRevoked/markAllRevoked/removeExpired) +
  `InMemoryDebugAuthStore` + `FileBackedDebugAuthStore` decorator — lazy
  load, corrupt/version-mismatch fallback to empty (never throws),
  expired rows dropped at load without rewrite, atomic tmp+rename persist.
  Mirrors the Kotlin `PluginDebugAuthStore` design; only token **hashes**
  are persisted.
- `TokenRecord` model (tokenId/tokenHash/createdAt/expiresAt/revokedAt/
  clientLabel) with ISO8601-UTC JSON round-trip, isomorphic to Kotlin
  `DebugAuthTokenRecord`.
- Hand-written pure-Dart SHA-256 (FIPS 180-4, 64-char lowercase hex) —
  **zero new dependencies**; public `debugAuthTokenHash(String)` alias.

## 0.5.0 - 2026-09-01

- Version alignment only (no Dart-core API changes this release): token
  persistence and the 7-day default TTL live in the Flutter plugin's Android
  side and the Python MCP host.

## 0.4.0 - 2026-08-27

- Capability scope model: `CapabilityScope.app()/page()` identity with
  `pageId`/`pageName`; scoped registry keys keep app and page registrations
  independent (same capId may live under different pages).
- `/hello.registeredCapabilities` mirror entries now carry
  `scope`/`pageId`/`scopeRevision` (optional, default `app` — backward
  compatible).
- Gone semantics: invoking a released page capability yields `410
  page_capability_gone` + refresh hint; protocol fixtures extended.
- Version alignment: `0.4.0` across Kotlin core / this package /
  `flutter_debug_control_plane` / Python.

## 0.3.0 - 2026-08-25

- Release alignment: Dart core, Kotlin core, and `flutter_debug_control_plane`
  share the `0.3.0` verified-compatible version line.

## 0.2.0 - 2026-08-18

- Version alignment: the whole debug_control_plane ecosystem now shares one
  version line (kotlin core 0.2.0 on JitPack, flutter_debug_control_plane
  0.2.0 on pub.dev, dart core 0.2.0). Same-version = verified-compatible set.
- Includes everything from 0.1.2 (unpublished): `GETTING_STARTED.md` guide.

## 0.1.2 - 2026-08-13 (skipped — folded into 0.2.0)

- Docs: add `GETTING_STARTED.md` — 5-step integration guide (dependency → import → capability → assemble → verify), capability authoring, platform support matrix (iOS/Android/macOS/Windows/Linux ✅, Web ❌), and common pitfalls.

## 0.1.1 - 2026-08-13

- Clean public release. The previously published 0.1.1 artifact is the first
  release free of internal residue; prefer it over 0.1.0.

## 0.1.0 - 2026-08-09

- Initial release: three-layer skeleton (Transport / ControlPlane / Capability).
- 8-endpoint debug HTTP protocol (byte-level stable).
