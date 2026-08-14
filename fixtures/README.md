# fixtures/ — 跨语言黄金 fixture（语言无关真理源）

> 本目录是 `debug_control_plane` 协议的**可执行投影**——把 PROTOCOL.md 描述的契约固化成具体的字节/JSON 样例，供 BF003 跨语言一致性测试（Kotlin JVM unit test + Dart test + Python client）做断言输入。
>
> **fixture 是真理源，代码迁就 fixture**（不是反过来）。故意改 fixture 一个字段 → 三端测试都红。

## 分层

| 层 | 扩展名 | 比对方式 | 说明 |
|---|---|---|---|
| **字节级** | `.bin` | 原样比对，不归一化 | SSE 帧（`: connected\n\n` + `event:/data:` 帧），逐字节相等 |
| **语义级** | `.json` | `$$unstable:<reason>` 归一化后比对 | JSON 响应体（`/hello` `/state` 错误体等），忽略不可控字段 |

## `$$unstable:<reason>` 归一化标记

语义级 fixture 中，**值不稳定**的字段（如 `serverHost` 依赖请求 Host 头、`serverPort` 绑定随机端口、`localIps` 依赖机器网卡、`sequence` 单调递增）用 `"$$unstable:<reason>"` 占位符标记。BF003 的归一化工具（`dart/test/fixtures/normalize.dart` + `kotlin/.../FixtureNormalize.kt`）扫到该标记时，把实际值替换成同一个占位符再做比对，从而忽略环境差异。

另一条全局规则：**以 `_` 开头的键（如每个 fixture 的 `_fixture_meta`）是 fixture 自描述元数据，不对应任何线上字段，比对时一律跳过**（不必逐字段看各 fixture 的 notes，规则在此处单点声明）。

两端归一化逻辑必须**完全一致**（否则跨语言比对假阳性）。

### 支持的 `<reason>` 枚举

| reason | 适用字段 | 说明 |
|---|---|---|
| `request-host` | `serverHost` | 来自 HTTP 请求 `Host` 头解析，测试环境各异 |
| `bound-port` | `serverPort` | 绑定端口（生产 18080 固定，但测试常用 0 随机分配） |
| `network-ips` | `localIps` | 本机网卡 IPv4 列表，机器各异 |
| `sequence` | `DebugEvent.sequence` | 进程级单调递增，重启归零 |
| `app-injected` | `app`/`deviceId`/`deviceName`/`platform`/`capabilities`/`hardwareName`/`machineId` | appMeta 业务注入，不同 app 不同 |
| `exception-toString` | 500 错误体 `message` | `error.toString()` 跨语言/跨环境各异（`error-500.json`） |
| `adb-serial` / `usbmuxd-id` | `discovery-python.json` 的 device_id 样例值 | USB 身份由宿主环境设备决定（发现期望 fixture，非响应体比对） |

## 文件清单

| 文件 | 类型 | 对应契约 | 断言要点 |
|---|---|---|---|
| `hello.json` | 语义级 | §1.2 `/hello` | protocolVersion=1、eventsEndpoint、profileRevision=1、registeredCapabilities schema、path 是 JSON 数组 |
| `state-empty.json` | 语义级 | §1.3 `/state` 空载 | **无 ok 包裹**、空 object `{}` |
| `state-with-cap.json` | 语义级 | §1.3 `/state` 含 capability | 扁平聚合、后注册覆盖、无 ok |
| `sse-connected.bin` | 字节级 | §3.4 首帧 | `: connected\n\n`（13 字节） |
| `sse-event-frame.bin` | 字节级 | §3.3 事件帧 | `event: <type>\ndata: <json>\n\n`，data 是整个 toJson。**注意**：`sequence:0` 是样例值（假定是进程启动后第一个事件），.bin 原样比对时 BF003-1 需同样用首事件构造帧 |
| `error-404.json` | 语义级 | §4.2 路由未命中 | `{ok:false, code:"not_found", message:"Endpoint was not found."}` |
| `error-400.json` | 语义级 | §4.2 POST body 非法 | `{ok:false, code:"invalid_request", ...}` |
| `error-500.json` | 语义级 | §4.2 handler 异常 | `{ok:false, code:"internal_error", ...}` |
| `route-decl.json` | 语义级 | §2.2 + §2.3 capability 路由声明 | path 是 JSON 数组 `["profiles","{id}"]`、description 可选 |
| `discovery-python.json` | 语义级 | §5 客户端发现 | 端口 18080、protocolVersion=1、device_id 来自 USB 非 /hello.deviceId |

## 零业务依赖

fixtures 是**纯协议数据**，不得含任何业务字段（gamepad/input/profile 的具体语义）。事件 type/payload 键均用中性占位（`sample_state_changed` / `aKey1` 等，与 hello.json 的 state 键示例一致）；框架透传这些字段但不规定语义。
