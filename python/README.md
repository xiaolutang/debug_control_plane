# debug-control-plane (Python)

Multi-product reusable debug control plane — Python slice.
多产品复用的调试控制平面——Python 切片。

Provides / 提供：
- **device_discovery**: USB/WiFi device discovery + cross-identity pairing (USB identity source / LAN scan / VPN-immune subnet / device pool with TTL).
  USB/WiFi 设备发现 + 跨身份配对（USB 身份源 / LAN 扫描 / VPN 免疫网段 / 带 TTL 的设备池）。
- **mcp_plane**: MCP adapter over the R019 8-endpoint debug HTTP protocol — capability mirror (dynamic tools), bridge client, bare server, and a `SemanticProvider` protocol hook for product semantic sugar.
  建立在 R019 8 端点调试 HTTP 协议之上的 MCP 适配器——能力镜像（动态 tools）、桥客户端、裸服务端，以及供产品语义糖接入的 `SemanticProvider` 协议钩子。

## Dependency direction / 依赖方向

```
business apps   业务应用
        │  depends on (downward)                     依赖（向下）
        ▼
debug_control_plane (this package)                        本包
        │  depends on (downward)                     依赖（向下）
        ▼
  mcp (SDK) · httpx (HTTP client)
```

This package is **pure infrastructure**: it MUST NOT import any business package. Business apps depend on this package; never the reverse.
本包是**纯基础设施**：绝不 import 任何业务包。业务应用依赖本包，反之禁止。

## Install / 安装

```bash
# editable install — picks up source changes without reinstall
# 可编辑安装——源码改动即时生效，无需重装
python -m pip install -e .

# import sanity check / 导入自检
python -c "import debug_control_plane; print(debug_control_plane.__version__)"
```

## Layout / 结构

```
python/
├── pyproject.toml                  # single-package, two sub-packages / 单包双子包
├── README.md                       # this file
├── LICENSE                         # MIT
└── debug_control_plane/
    ├── __init__.py                 # __version__ = "0.5.2"
    ├── device_discovery/           # USB/LAN device discovery + device pool
    │   ├── device_candidates.py
    │   ├── device_pool.py          # identity-keyed pool, TTL expiry / 身份键池，TTL 过期
    │   ├── endpoint.py
    │   ├── protocol.py
    │   └── discovery/
    │       ├── usb_identity.py     # USB identity source (adb / flutter devices) / USB 身份源
    │       ├── lan_scan.py         # LAN /hello probe / LAN /hello 探测
    │       ├── vpn_immune.py       # VPN-immune subnet calc / VPN 免疫网段计算
    │       ├── cross_identify.py   # USB ⊕ LAN cross pairing / USB ⊕ LAN 交叉配对
    │       └── manual_registry.py  # manually-told devices / 人工告知设备
    └── mcp_plane/                  # MCP adapter
        ├── capability_mirror.py    # dynamic tools from /hello / 由 /hello 动态镜像 tools
        ├── bridge_client.py        # HTTP bridge client / HTTP 桥客户端
        ├── server.py               # bare stdio MCP server / 裸 stdio MCP 服务端
        └── semantic_provider.py    # SemanticProvider Protocol (product hook) / 语义糖协议钩子
```

## Console script / 控制台脚本

```
debug-control-plane-server
```

Points at `debug_control_plane.mcp_plane.server:main` — a bare server (no business capability assembly) for debugging / plane self-testing.
指向 `debug_control_plane.mcp_plane.server:main`——裸服务端（无业务能力装配），用于调试 / 平面自测。

## Version / 版本

`0.5.2` — aligned with Kotlin/Dart/Flutter `0.5.2`, API unstable.
`0.5.2` —— 与 Kotlin/Dart/Flutter `0.5.2` 对齐，API 不稳定。

## License / 许可证

Licensed under the MIT License — see [LICENSE](LICENSE).
采用 MIT 许可证授权——见 [LICENSE](LICENSE)。
