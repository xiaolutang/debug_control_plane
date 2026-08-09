# Changelog

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
