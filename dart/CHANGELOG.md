# Changelog

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
