---
type: analysis
slice_id: S02-python-file-token-provider
date: 2026-08-31
---

# R004 S02 — Python FileTokenProvider（token 跨进程存活）

## 概述

本片实现 Python 客户端侧的 `DebugAuthTokenProvider` 正式实现 `FileTokenProvider`：token 明文落 `~/.debug-control-plane/tokens.json`（0600），以 device_id 为键，跨 MCP server 进程重启存活。并在 `server.py main()` 组装点注入。

边界：
- **S01（app store）**：App 侧 token 存储（DataStore 加密/明文红线）归 S01；本片只做 Python 端，客户端存明文已被用户确认接受（开发机文件 + 0600）。
- **S03（TTL+脚本）**：TTL 从短时效提升为 7 天归 S03；本片 provider 只需正确读 `expiresAt` 并判定过期与否，不关心具体时长。
- 明确不做：keyring、加密、多用户。

## 一、交互链（用户平面）

场景 **SCN-PY-TOKEN-SURVIVE-RESTART**：

1. **首次**：tokens.json 不存在或无该 device 行 → `_auth_headers()` 返 `{}` → 手机返 401 `authorization_required` → AI 走 `auth_request` → 人 approve → `auth_claim` 返回 `{token, tokenId, expiresAt}` → `bridge_client.py:496-505` 自动 `save_token` → `FileTokenProvider` 落盘 tokens.json（0600）。
2. **Python 重启**：新进程 `main()` 注入新 provider 实例 → 首次 `get_token` 懒加载读盘 → device_id 命中且 `expiresAt >= now` → 请求直接带 `Authorization: Bearer ...`，200，不重新走 auth 链、不弹窗。核心验收点。
3. **过期**：`get_token` 判定 `expiresAt < now` → 返回 `None`（等价无 token）→ `_auth_headers` 返 `{}` → 手机 401 → 重新授权链。过期行在下次 `save_token`（重新 claim 后覆盖）或 `clear_token`（手机返 token_expired）时清理；读时不回写。
4. **401 清理联动**：手机返 `token_expired` / `token_revoked` / `invalid_token`（`_CLEAR_TOKEN_AUTH_CODES`，bridge_client.py:685-691）→ `_http_error` 调 `clear_token(device_id, reason)` → 落盘文件同步删除该行（重写 tokens.json）。`authorization_required`/`forbidden` 等不清（现状语义保持）。
5. **边界**：手动删 tokens.json → 等价首次；JSON 损坏 → 回退空 dict（注意：这里**不对齐** device_pool 的 fail-fast ValueError——token 是可再生凭证，损坏静默重来比重启崩掉更合理；version 不匹配同理回退空）。

## 二、逻辑树（系统平面）

### FileTokenProvider 类设计

落点：新文件 `python/debug_control_plane/mcp_plane/token_provider.py`（mcp_plane 包内，紧邻 bridge_client，不污染 device_discovery）。

**构造**：`FileTokenProvider(path: Path | None = None)`；默认 `Path.home() / ".debug-control-plane" / "tokens.json"`。懒加载：构造只存 path，首次 get/save/clear 才 `_load()`（`self._loaded` 标志）。内存态 `dict[str, dict]`。

**数据结构**：
```json
{"version": 1, "tokens": {"<device_id>": {"token": "...", "tokenId": "...", "expiresAt": "..."}}}
```
metadata 字段全部来自 `auth_claim` 透传的 `("tokenId", "expiresAt")`（bridge_client.py:499-503），save 时把 metadata 整体并入行（只存 str 值，防御性过滤非 str）。tokenId 供调试/对账，expiresAt 供过期判定。

**0600 权限（安全顺序）**：
- 推荐 `os.open(tmp, os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)` + `os.fdopen` 写 + `os.replace`。用 open mode 创建即带 0600，绕过 umask（umask 只会收紧不会放宽，`write_text` 默认 0666&~umask 通常得 0644，之后 chmod 有竞态窗口：文件已以 0644 短暂存在）。
- 由于走 tmp + replace，正确的做法是 **tmp 文件以 0o600 创建**，replace 后权限随 tmp 文件。首次创建后无需再 chmod；对已存在文件 replace 原子替换权限也随之更新。
- 目录 `~/.debug-control-plane/` 已由 DevicePool 的 `mkdir(parents=True, exist_ok=True)` 保证存在（devices.json 同目录）；provider 写盘前同样 `mkdir(exist_ok=True)` 幂等防御。
- 补充：`Path.touch` 后 chmod 或 write 后 chmod 都有 0644 窗口，不采用。

**原子写**：对齐 device_pool `_flush`：写 `tokens.json.tmp` → `os.replace` 到 `tokens.json`。损坏/半写永不留下坏 store。

**expiresAt 判定**：
- App 侧 Instant.toString() 产出 ISO-8601 带 `Z` 后缀（如 `2026-08-20T14:00:00Z`，见 test_bridge_client.py:555）。
- Python 3.11+ `datetime.fromisoformat` 原生支持 `Z`；项目 target py310 → 统一 `fromisoformat(value.replace("Z", "+00:00"))` 兼容两版本。
- 解析失败/缺失 expiresAt → 视为未过期（token 仍可用；解析 bug 不应打断授权链，手机 401 是最终裁判）。
- aware（带 Z）与 naive 混比问题：解析出的 datetime 若 naive（无时区后缀的极端情况），用 `datetime.now(timezone.utc)` 对 aware now 比较会抛 TypeError——naive 时补 `astimezone()` 或直接视为未过期，选后者（简单 + 安全回退）。

**get_token 过期清理策略**：**读时判定、不回写**。返回 None 即可；下次该 device 重新 claim 时 `save_token` 整行覆盖，旧过期行自然消失。理由：读路径在网络请求热路径上（每次 invoke 都调），回写引入额外磁盘 IO + 竞态面，收益仅是磁盘卫生；`clear_token`（401 联动）已兜底大部分清理。

**线程模型**：**不加锁**。MCP server 是 asyncio 单线程（server.run_stdio），BridgeClient 全同步调用，provider 三方法只会从事件循环线程串行进入；`_FakeTokenProvider` 测试同样单线程。与 DevicePool 的"NOT thread-safe, 单线程"声明一致。类 docstring 写明此假设。

### server.py main() 注入

```python
client = BridgeClient(pool=pool, token_provider=FileTokenProvider())
```
（server.py L1055，DevicePool → BridgeClient 组装点；默认 path 即 `~/.debug-control-plane/tokens.json`。）

### 与 devices.json 的关系

同目录两文件，schema 完全独立、互不引用。DevicePool 红线（"must not be used to persist bearer tokens"，bridge_client.py:149-154 与 device_pool 注释）不违反：token 走独立 provider 独立文件。device 移除（`DevicePool.remove`）不级联删 token——残留 token 过期或被 401 清理自然消亡，不做跨文件耦合。

## 三、功能编号与网络定位

本片 Python 端，归 **BF** 序列（S01 的 FF 是 app/Kotlin 侧，无冲突）。

| 编号 | 能力 | 文件落点 | 验收要点 |
|---|---|---|---|
| BF001 | FileTokenProvider 持久化实现 + main() 注入 | `python/debug_control_plane/mcp_plane/token_provider.py`（新）、`python/debug_control_plane/mcp_plane/server.py`（main 注入）、`python/debug_control_plane/mcp_plane/bridge_client.py`（不动，仅 import 关系） | save→新实例 get roundtrip；0600 权限；过期 get 返 None；损坏/版本不符回退空；clear 后盘上行消失；401 三码联动删盘 |
| BF001-T | 单测 | `python/tests/test_token_provider.py`（新，tmp_path fixture） | roundtrip 跨实例；`stat().st_mode & 0o777 == 0o600`；expiresAt 过去/未来/Z 后缀/非法值；clear 同步删盘重写；损坏 JSON→空；metadata 并入行；与 `_FakeTokenProvider` 协议兼容（structurally 满足 Protocol，无需继承） |

## 四、边界接口

- `DebugAuthTokenProvider` Protocol 三方法签名不变（get_token/save_token/clear_token）；`FileTokenProvider` 结构化实现即可，不 import Protocol 也可（duck typing），但显式声明更清晰。
- `auth_claim` 的自动 save（含 metadata 透传 tokenId/expiresAt）不动——现有测试 test_auth_request_status_claim_helpers... 已锁定该契约。
- `_CLEAR_TOKEN_AUTH_CODES` 三码清理联动不动；provider 只需保证 clear_token 落盘重写。
- tokens.json 与 devices.json schema 独立（version 字段各自维护，本片 `TOKENS_SCHEMA_VERSION = 1`），互不引用、互不级联。

## 五、结论

**实现顺序**：
1. `token_provider.py`：FileTokenProvider（懒加载 + 0600 原子写 + 过期判定 + 损坏回退）。
2. `test_token_provider.py`：BF001-T 全量单测。
3. `server.py` main() 一行注入。
4. 手工验收：真机 auth claim → 重启 python server → 请求不弹窗直达。

**风险点**：
- **0600 umask**：必须 `os.open(..., 0o600)` 创建 tmp，不能 write 后 chmod（有 0644 窗口）；注意 `os.replace` 后权限取自 tmp 文件。
- **'Z' 后缀兼容**：py310 `fromisoformat` 不认 `Z`，统一 `replace('Z', '+00:00')`；naive datetime 比较会 TypeError，防御性回退"未过期"。
- **懒加载时序**：首次 get 触发读盘，若此时文件正被外部编辑（半写）→ JSONDecodeError → 回退空（与损坏容错同路径），不会崩 server；但同一进程内 `_loaded` 已置 True，之后不再重读——外部修复后需重启进程，可接受（token 生命周期本就以进程为单位管理）。
- **残留 token**：device 移除不删 token 行（有意解耦），最长残留 7 天（TTL 后过期）或下次 401 清理。
