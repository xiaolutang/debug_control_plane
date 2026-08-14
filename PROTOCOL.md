# debug_control_plane — 协议契约（语言无关真理源）

> 本文档是 `debug_control_plane` 框架线上协议的**语言无关契约**，是 Kotlin / Dart / Python / 未来 Swift 三端对齐的共同真理源。每条契约都标注了 Dart 现状的源文件 + 行号，一切以代码为准（code-first），Kotlin/native 实现必须字节级或语义级对齐。
>
> 配套产物：`fixtures/` 目录（repo 根，与 `dart/` `python/` `kotlin/` 并列）承载黄金 fixture，供 BF003 跨语言一致性测试做断言输入。fixture 是协议的可执行投影，比任何描述性 schema 都硬。

---

## §0 契约边界与真理源声明

- **框架边界**：本契约只覆盖 `ControlPlane` 框架拥有的三类系统路由（`/hello`、`/state`、`/events`）+ capability 声明/分发规则 + SSE 编码 + 错误体格式 + 客户端发现握手。**不**覆盖任何业务 capability 的具体端点语义（如 `/input`、`/profiles/{id}` 的 body 字段）——那些是 capability 自己的 sub-contract，框架只负责路由到 handler。
- **代码真理源**（Kotlin/native 实现必须对齐这些文件的线线行为）：
  - Dart：`dart/lib/src/control_plane.dart`、`transport.dart`、`http_codec.dart`、`http_sse_transport.dart`、`capability.dart`、`route_failure.dart`、`debug_event.dart`
  - Python：`python/debug_control_plane/device_discovery/protocol.py`、`endpoint.py`、`discovery/lan_scan.py`、`discovery/cross_identify.py`、`device_pool.py`
- **传输基线**：REST + SSE（`HttpSseTransport`）。`Transport` 抽象接口预留 WS/MCP，但**当前线上只有一个实现**，本契约以 REST+SSE 为准。WS/MCP 是未来扩展，不进入当前契约硬约束。

---

## §1 系统路由

三条系统路由由 `ControlPlane` 自身处理，**优先级高于 capability 路由**（`control_plane.dart:129` `_matchSystemRoute` 先判，命中即返回，capability 分发不再跑）。三条系统路由**全部仅 GET**。

### 1.1 路由匹配总规则（先决约束）

| 约束 | 来源 | 说明 |
|---|---|---|
| 路径分段 | `transport.dart:63` `segments` | 请求路径按 `/` 切成段数组，如 `/profiles/abc` → `['profiles','abc']`。空尾段、重复斜杠的处理依赖各 HTTP 服务器的 `pathSegments`（Dart `Uri.pathSegments` 会去空段）。**native 实现必须复现"去空尾段"语义**，否则 `/hello/` 与 `/hello` 不等价会破坏契约。 |
| 方法大写 | `transport.dart:61` | method 统一大写比较（`GET`/`POST`）。 |
| 系统路由精确匹配 | `control_plane.dart:190-198` | 系统路由用 `_listEquals` 做**整段精确匹配**（长度 + 逐段字符串相等），不支持 `{id}` 占位符。`/hello` 必须恰好 `['hello']`。 |
| 系统优先 | `control_plane.dart:129-132` | 系统路由先判；命中后 capability 路由不再执行。即业务 capability 不得声明 `GET /hello`、`GET /state`、`GET /events`（会被框架截胡，声明了也不生效）。 |
| 系统路由仅 GET | `control_plane.dart:190-198` | 三条系统路由全部 `method == 'GET'`。POST `/hello` 等会落到 capability POST 分发，找不到则 404。 |

### 1.2 `GET /hello` — 发现握手 + 元数据聚合

**契约定位**：客户端（Python `device_discovery`）发现服务端的首要握手端点；也是 MCP bridge 拉取 runtime capability schema 的镜像源。

| 项 | 值 | 来源 |
|---|---|---|
| Method | `GET` | `control_plane.dart:190` |
| Path | `/hello`（段 `['hello']`） | `control_plane.dart:190` |
| Request body | 无（GET 不读 body；`http_sse_transport.dart:89-91` 仅 POST 调 `readObject`） | |
| Request headers | 无强制（Python 客户端发 `Accept: application/json`，服务端不校验） | |
| Response status | `200`（成功路径 `RouteResult.ok`） | `transport.dart:18` |
| Response Content-Type | `application/json`（`http_codec.dart:78` `ContentType.json`） | |
| Response body | JSON object，字段见下表 | `control_plane.dart:206-219` `_handleHello` |

**`/hello` 响应字段完整清单**（合并顺序见 `control_plane.dart:208-219`，后者 spread 覆盖前者同名字段）：

| key | 类型 | 来源/合并层 | 必含 | 说明 |
|---|---|---|---|---|
| `protocolVersion` | int (固定 `1`) | 框架常量 `control_plane.dart:10,209` | 是 | 协议版本，框架拥有（见 §6） |
| `app` | string | appMeta 注入（业务） | 否* | app 标识 |
| `deviceId` | string | appMeta 注入（业务） | 否* | app 内设备标识（**不稳定**，多设备撞同值，见 §5） |
| `deviceName` | string | appMeta 注入（业务） | 否* | 人类可读设备名 |
| `platform` | string | appMeta 注入（业务） | 否* | 如 `"ios"`/`"android"` |
| `capabilities` | string[] | appMeta 注入（业务） | 否* | 业务能力标签数组（语义由业务定义，框架透传） |
| `hardwareName` | string? | appMeta 注入（业务，FF001） | 否 | 真实设备名 |
| `machineId` | string? | appMeta 注入（业务，FF001） | 否 | 机型标识 |
| *(其他 appMeta 键)* | any | appMeta 注入 | 否 | 业务可自由扩展，框架只 spread |
| `serverHost` | string | `transport.serverInfo`（`http_sse_transport.dart:154`） | 是 | 客户端到达用的 host，来自 `Host` 头解析；无 Host 头时 `"0.0.0.0"` |
| `serverPort` | int | `transport.serverInfo`（`http_sse_transport.dart:155`） | 是 | 绑定端口；无 server 时 0 |
| `localIps` | string[] | `transport.serverInfo`（`http_sse_transport.dart:156`） | 是 | 本机非 loopback/非 link-local 的 IPv4 地址，升序 |
| `eventsEndpoint` | string (固定 `"/events"`) | 框架硬编码 `control_plane.dart:212` | 是 | SSE 端点路径常量 |
| `profileRevision` | int (固定 `1`) | 框架硬编码 `control_plane.dart:213` | 是 | 当前恒为 1（遗留字段，框架不维护递增） |
| *(state 聚合键)* | any | `_aggregateState()` spread `control_plane.dart:214,245-256` | 视 capability | 各 capability `state()` 返回的键值被**扁平 spread** 进 `/hello` 顶层（不嵌套）。后注册 capability 的同键覆盖先注册者（`control_plane.dart:251-253`） |
| `registeredCapabilities` | object[] | `_aggregateCapabilities()` spread `control_plane.dart:218,266-288` | 是 | runtime capability 镜像，schema 见 §2.2 |

\* `否*`：框架层不强制，但实际线上 app 的 appMeta 都会注入。Python 客户端 `NetworkTarget.from_hello` 对这些键有默认值兜底（缺 `deviceId` 时回退 `"{host}:{port}"`）。

**合并优先级**（同键后者覆盖前者）：`protocolVersion` → appMeta → serverInfo → `eventsEndpoint`/`profileRevision` → aggregateState → `registeredCapabilities`。`registeredCapabilities` 最后 spread，保证不被业务键冲掉。

### 1.3 `GET /state` — 实时状态快照

| 项 | 值 | 来源 |
|---|---|---|
| Method | `GET` | `control_plane.dart:193` |
| Path | `/state` | `control_plane.dart:193` |
| Request body | 无 | |
| Response status | `200` | |
| Response Content-Type | `application/json` | |
| Response body | **扁平聚合状态 object**（**无 `ok` 包裹**） | `control_plane.dart:222-229` |

**关键契约细节**：
- **无顶层 `ok` 字段**。`control_plane.dart:225-227` 明确注释：遗留 `/state` 返回扁平 aggregate state，加 `ok` 会偏离 TEST01 golden snapshot 契约。这是**字节级硬约束**——native 实现的 `/state` 响应必须**不**含 `ok:true`。
- body = `_aggregateState()`（`control_plane.dart:245-256`）：遍历所有已注册 capability，把每个 `cap.state()` 的 entries 扁平 spread 进顶层 object。后注册覆盖先注册（同键）。
- 空载（无 capability）时返回 `{}`（空 object，非空数组、非 null）。

### 1.4 `GET /events` — SSE 长连接（传输层劫持）

**特殊地位**：`/events` 在 `HttpSseTransport` 中**不经过 `dispatch` 路由**，而是被传输层**劫持**为长连接 SSE 流（`http_sse_transport.dart:73-79` 在进 handler 前就 hijack）。`control_plane.dart:231-243` 的 `_handleEvents` 是"非劫持传输"的内省兜底（返回 `{ok:true, note:'event_bus_is_stream', eventsEndpoint:'/events'}`），生产 HTTP 传输永远不会走到这里。

| 项 | 值 | 来源 |
|---|---|---|
| Method | `GET`（仅 GET 劫持） | `http_sse_transport.dart:74` |
| Path | `/events`（段 `['events']`，长度恰好 1） | `http_sse_transport.dart:73-76` |
| Response status | `200` | `http_sse_transport.dart:120` |
| Response Content-Type | `text/event-stream; charset=utf-8` | `http_sse_transport.dart:122` |
| Response headers | `Cache-Control: no-cache`、`Connection: keep-alive` | `http_sse_transport.dart:123-124` |
| Response body | SSE 流，帧格式见 §3 | |
| 连接生命周期 | 长连接，直到客户端断开（write 失败检测）或 `transport.close()` | `http_sse_transport.dart:131-133,166-170` |

**第一帧硬约束**：连接建立后**立即**写 `: connected\n\n`（SSE 注释行，`http_sse_transport.dart:128`）。这是客户端判定"连上了"的信号。TEST01 golden 要求第一行是 `: connected` 而非 JSON body——**native 实现必须复现此首帧**。

---

## §2 Capability 声明 + 路由分发

### 2.1 Capability 接口契约（`capability.dart:95-111`）

```
Capability {
  id: String                          // 唯一标识，注册表 key，重复抛 StateError（control_plane.dart:70-74）
  resources: List<Resource>           // GET 端点声明
  commands: List<Command>             // POST 端点声明
  events: Stream<DebugEvent>          // 事件流，框架订阅一次并加 sequence 后广播
  state(): Map<String,Object?>        // 状态快照，聚合进 /state 和 /hello
}
```

`Resource` / `Command` 声明（`capability.dart:32-60,64-88`）：

| 字段 | Resource (GET) | Command (POST) | 来源 |
|---|---|---|---|
| `method` | string（惯例 `"GET"`） | string（惯例 `"POST"`） | `capability.dart:48,76` |
| `path` | `List<String>` 段数组，支持 `{name}` 占位符 | 同左 | `capability.dart:50,77` |
| `handler` | `Future<Map<String,Object?>> Function(RouteContext)` | 同左 | `capability.dart:54,84` |
| `description` | string?（可选，`/hello.registeredCapabilities` 镜像用，null 时省略该键） | string? 同左 | `capability.dart:59,87` |

`RouteContext`（`capability.dart:8-24`）：`{pathParams: Map<String,String>, body: Map<String,Object?>, request: Object?}`。`request` 是不透明协议句柄（HTTP 传输下是 `HttpRequest`），框架从不自检，capability 需要时向下转型。

### 2.2 `/hello.registeredCapabilities` 镜像 schema（`control_plane.dart:266-288`）

runtime capability 注册表的动态镜像，供 MCP 工具层自动发现可调用端点。**这是跨语言对齐的关键 schema**——native 实现的 `/hello` 必须输出结构一致的 `registeredCapabilities`。

```jsonc
{
  "registeredCapabilities": [
    {
      "id": "<capability id>",
      "resources": [
        { "method": "GET", "path": ["profiles", "{id}"], "description": "..." }
      ],
      "commands": [
        { "method": "POST", "path": ["input"], "description": "..." }
      ]
    }
  ]
}
```

**字段级契约**：
- 顶层 key 固定 `registeredCapabilities`，值是数组（`control_plane.dart:267`）。
- 数组元素顺序 = 注册顺序（`_capabilities` 是 LinkedHashMap，`control_plane.dart:262` docstring 明确"Insertion order is preserved"；`aggregate_capabilities_test.dart:233-234` 实证注册序输出）。
- 每元素必有 `id`（string）、`resources`（array）、`commands`（array）三键。
- `resources`/`commands` 每元素必有 `method`（string）、`path`（array）；`description` 在非 null 时才出现（`control_plane.dart:275,282` 的 `if (r.description != null)`）。

### 2.3 ⚠️ `path` 是 JSON 数组（跨语言坑，关键约束）

**`path` 字段在 `/hello.registeredCapabilities[].resources[].path` 和 `.commands[].path` 中序列化为 JSON 数组**，**不是** `/`-joined 字符串。

- 内存表示：`Resource.path` / `Command.path` 是 `List<String>`（`capability.dart:50,77`）。
- 序列化：`control_plane.dart:274` 直接 `'path': r.path` 放进 map，Dart `jsonEncode` 输出 `["profiles","{id}"]`（带方括号的 JSON 数组）。
- Dart 现状测试验证：`aggregate_capabilities_test.dart:160` 断言 `expect(res['path'], <String>['profiles']);`——确认线上输出是数组。
- **跨语言对齐**：Kotlin 用 `List<String>`，Python 端 `_opt_json_list`（`protocol.py:43-60`）当 opaque list 存。三端（Dart/Kotlin/fixture）必须一致——fixture 的 `path` 也是 JSON 数组。

> 历史注记：slice-1 §7 U1 曾标记此点存疑（"是数组还是斜杠字符串"），现已由 Dart 现状测试 (`aggregate_capabilities_test.dart:160`) + Python 解析端 (`_opt_json_list`) 共同确认是**JSON 数组**。

### 2.4 路由分发规则（`control_plane.dart:136-166`）

**核心：扁平、无前缀匹配**（decision D6，`control_plane.dart:19`）。所有 capability 的 resources/commands 共享一个全局路由表，无 `/capabilities/<id>/...` 前缀。

分发算法（伪码，对应 `control_plane.dart:136-166`）：

```
dispatch(req):
  1. system = matchSystemRoute(req.method, req.segments)   # §1.2-1.4
     if system: return ok(system(req))
  2. if req.method == 'GET':
       for cap in capabilities.values (insertion order):    # 遍历顺序敏感
         for decl in cap.resources:
           if decl.method != req.method: continue
           pathParams = {}
           if matchPath(decl.path, req.segments, pathParams):
             return ok(decl.handler(RouteContext{pathParams, body, request}))
  3. else if req.method == 'POST':
       for cap in capabilities.values:
         for decl in cap.commands:
           if decl.method != req.method: continue
           pathParams = {}
           if matchPath(decl.path, req.segments, pathParams):
             return ok(decl.handler(RouteContext{pathParams, body, request}))
  4. return error(404, 'not_found', 'Endpoint was not found.')
```

**`matchPath` 语义**（`control_plane.dart:294-311`）：
- 声明段数 ≠ 实际段数 → 不匹配。
- 逐段比较：声明段形如 `{name}`（以 `{` 开头且以 `}` 结尾）→ 捕获为 `pathParams[name] = 实际段值`（任意非空段都匹配）。
- 否则逐字符精确相等。
- **首匹配胜出**：按 capability 注册顺序、再按 resources/commands 声明顺序遍历，第一个 matchPath 成功的声明处理请求。后续声明不再尝试。→ 业务声明路径不得冲突（冲突时静默被先注册者吃掉，框架不报错）。

**POST body 解析**（`http_sse_transport.dart:88-91` + `http_codec.dart:27-39`）：
- POST 请求必须带 JSON body 且顶层是 object。非 JSON / 非 object → `RouteFailure(400, 'invalid_request', 'Request body must be valid JSON object.')`。
- GET 请求 body 恒为 `{}`（`http_sse_transport.dart:89-91`）。

**handler 返回值**：`Future<Map<String,Object?>>`，直接作为 `RouteResult.ok` 的 body（`control_plane.dart:147,162`），**不**自动包 `ok:true`。handler 想加 `ok` 得自己加。handler 抛 `RouteFailure` → 走错误契约（§4）；抛其他异常 → 500 `internal_error`（`control_plane.dart:179-185`）。

---

## §3 SSE / 事件编码

### 3.1 事件总线与 sequence 分配（`control_plane.dart:86-94`）

- 每个 capability 的 `events` stream 在注册时被框架订阅一次（`control_plane.dart:76`）。
- 事件流入时，框架**重新构造**一个 `DebugEvent`，**分配全局递增 sequence**（`control_plane.dart:88-91`，`_nextSequence++` 从 0 开始，`control_plane.dart:52`）。capability 原始的 sequence **被丢弃**。
- 同一事件被两路广播：(a) 加进内部 `_eventBus` stream（供非 HTTP 传输消费）；(b) 调 `transport.broadcast(event)`（HTTP 下写到所有 SSE 订阅者，`http_sse_transport.dart:137-145`）。
- **sequence 是进程级单调递增**，跨 capability 共享一个计数器，从 0 起。重启归零。

### 3.2 `DebugEvent` 序列化 schema（`debug_event.dart:33-35`）

```jsonc
{ "type": "<event type>", "sequence": <int>, ...payload }
```

- 顶层必有 `type`（string）、`sequence`（int）。
- `payload`（`Map<String,Object?>`）被**展开**进顶层（`debug_event.dart:34` `{type, sequence, ...payload}`），**不嵌套**在 `payload` key 下。
- payload 键名是业务定义的 camelCase。框架不规定 payload 内容，只保证 `type`/`sequence` 前置 + payload 扁平展开。

### 3.3 SSE 事件帧编码（`http_sse_transport.dart:139-140`）

每一事件帧（SSE spec 兼容）：

```
event: <event.type>\n
data: <jsonEncode(event.toJson())>\n
\n
```

即：
- `event:` 行 = 事件的 `type` 字段（如 `event: controller_state_changed`）。
- `data:` 行 = 整个 `toJson()` 结果的**单行** JSON 字符串（`jsonEncode` 不换行）。注意是整个事件（含 type/sequence/payload）作为 data，不是只 payload。
- 帧以 `\n\n` 结束（一个空行）。
- **无 `id:` 字段**、**无 `retry:` 字段**。SSE Last-Event-ID 重连机制**未实现**（客户端断连重连后 sequence 不续传，从当前 `_nextSequence` 继续，丢中间事件）。

### 3.4 连接建立首帧（`http_sse_transport.dart:128`）

```
: connected\n
\n
```

SSE 注释行（以 `:` 开头），客户端忽略内容但可用于探测连接已建立。**这是首帧硬约束**——必须在写响应头后、flush 前**立即**写。

### 3.5 心跳 / keepalive

**当前框架不发心跳**。`broadcast` 仅在有事件时触发（`control_plane.dart:93`）。长时间无事件时 SSE 连接静默——靠 TCP keepalive 和客户端 write 失败检测断连。

### 3.6 Content-Type 与响应头（`http_sse_transport.dart:120-124`）

```
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache
Connection: keep-alive
```

`bufferOutput = false`（`http_sse_transport.dart:119`）——禁用缓冲，每帧立即 flush（`http_sse_transport.dart:129,186`）。

### 3.7 连接生命周期

- **建连**：客户端 GET `/events` → 服务端写头 + `: connected` + flush → 加入 `_sseSubscribers` 集合（`http_sse_transport.dart:126-129`）。
- **广播**：`broadcast` 遍历订阅者集合的**拷贝**（防止迭代中增删，`http_sse_transport.dart:142`），每订阅者 best-effort write；write 抛异常被吞（`http_sse_transport.dart:190-192`），靠 `response.done` 的 `whenComplete` 移除死订阅者（`http_sse_transport.dart:131-133`）。
- **断连**：客户端断开 → `response.done` 完成 → 从集合移除。或 `transport.close()` 主动关所有订阅者（`http_sse_transport.dart:166-169`）。

---

## §4 错误契约

### 4.1 错误响应体 schema（`transport.dart:22-37` `RouteResult.error` + `http_codec.dart:85-96` `writeError`）

```jsonc
{ "ok": false, "code": "<machine-readable code>", "message": "<human-readable>" }
```

- 顶层必有 `ok`（固定 `false`）、`code`（string）、`message`（string）。
- 可选 `extra` 键（`RouteResult.error` 的 `extra` 参数，`transport.dart:25-27`）被 spread 进顶层。当前框架自身错误不带 extra；业务 capability 可自带。
- Content-Type `application/json`，status code 由错误类型决定。

### 4.2 RouteFailure → HTTP 状态码映射

错误来源两类（`control_plane.dart:173-185`）：

| 来源 | 触发 | statusCode | code | message | 来源行号 |
|---|---|---|---|---|---|
| `RouteFailure` 抛出 | capability handler 或框架主动抛 | 由 `RouteFailure.statusCode` 决定 | 由 `RouteFailure.code` 决定 | 由 `RouteFailure.message` 决定 | `control_plane.dart:173-178` |
| 其他异常 | handler 抛非 RouteFailure | `500` | `"internal_error"` | `error.toString()` | `control_plane.dart:179-185` |
| 404 路由未命中 | 系统路由 + capability 都不匹配 | `404` | `"not_found"` | `"Endpoint was not found."` | `control_plane.dart:168-172` |
| POST body 非法 | JSON 解析失败 / 非 object | `400` | `"invalid_request"` | `"Request body must be valid JSON object."` 或 `"Expected object."` 或 `"Expected non-empty string."` | `http_codec.dart:33-61` |
| capability 重复注册 | `register` 同 id | —（抛 `StateError`，**不**走 HTTP，是启动期错误） | — | `"Capability already registered: <id>"` | `control_plane.dart:70-74` |

**框架内置的错误 code 枚举**（跨语言对齐用，native 必须用相同字符串）：
- `not_found`（404）
- `invalid_request`（400）
- `internal_error`（500）

业务 capability 可自定义 code（如 `real_controller_active`、`profile_not_found`），但框架层只保证这三个。

### 4.3 HTTP 层错误捕获（`http_sse_transport.dart:100-114`）

传输层在 `_handleRoute` 里 catch 两类：`RouteFailure` → `writeError`；其他 → 500 `internal_error`。这与 `dispatch` 内部的 catch（`control_plane.dart:173-185`）**双重兜底**——正常路径 dispatch 已把异常转成 `RouteResult.error`，传输层只在 dispatch 本身抛出时兜底。native 实现需保证 handler 异常不泄漏成传输层栈 trace。

---

## §5 客户端发现契约（Python `device_discovery`）

> **边界**：本节是"客户端如何发现并识别服务端"的契约。R025 明确"不动客户端发现层协议"，所以 native 实现的服务端必须让现有 Python 客户端**零改动**就能发现。这约束了 `/hello` 的字段稳定性。

### 5.1 发现机制总览

两条并行发现通道，结果交叉识别（`cross_identify.py`）：

| 通道 | 机制 | 产物 | 来源 |
|---|---|---|---|
| **LAN 扫描** | 并发 HTTP probe `/hello` 整个 /24 网段 | `LanCandidate(host, port, network_target)` | `lan_scan.py`、`endpoint.py` |
| **USB 身份** | 平台命令（adb/ios 相关）拿设备 serial/model | `UsbCandidate(device_id, platform, model, android_lan_ip?)` | `usb_identity.py` |
| **交叉识别** | 纯函数，USB 候选 ⊕ LAN 候选 → `DeviceRecord` | `DeviceRecord` 列表 | `cross_identify.py` |

### 5.2 LAN 扫描握手契约（`endpoint.py` `probe_hello`）

| 项 | 值 | 来源 |
|---|---|---|
| Method | `GET` | `endpoint.py` |
| URL | `http://<host>:<port>/hello` | `endpoint.py` |
| Headers | `Accept: application/json`（客户端发，服务端不强制） | `endpoint.py` |
| Timeout | 默认 1.0s（`probe_hello`），LanScan 用 2.5s（`DEFAULT_PROBE_TIMEOUT`） | |
| 成功判定 | HTTP 响应 body 是 JSON object → `NetworkTarget.from_hello` | `endpoint.py` |
| 失败容忍 | `OSError`/`URLError`/`TimeoutError`/`ValueError`/`JSONDecodeError`/非 dict → 返回 None（吞掉，不抛） | `endpoint.py` |
| 端口 | **固定 18080**（`DEFAULT_PORT`） | `lan_scan.py:49`、`endpoint.py:26` |
| 网段来源 | `VpnImmune.lan_cidr()`（路由表法，绕 VPN TUN 污染），fallback socket 出口法 | `lan_scan.py`、`endpoint.py` |
| 并发 | 64 worker，/24 网段 254 host 约 4 轮，总耗时 < 10s | `lan_scan.py` |

**关键**：服务端**必须**在 18080 端口监听，否则 LAN 扫描发现不到。这是硬编码约定，非协商。

### 5.3 device_id 来源契约（decision D9，跨语言关键）

**`DeviceRecord.device_id` 绝不来自 `/hello.deviceId`**（`device_pool.py:73-75`、`cross_identify.py:14-15`）。

原因：`/hello.deviceId` 是 app 注入的固定字符串（线上 iOS 是 `gmacro-virtual-ios`），**多台同平台设备撞同一个值**，无法区分。

device_id 真实来源（`cross_identify.py` `_merge`）：
- **Android**：USB 的 adb serial（`UsbCandidate.device_id`）。
- **iOS**：usbmuxd id。
- **manual 注册**：`manual-<sha1(host)[:16]>`（`device_pool.py:346-359`）。

→ **对 native 的约束**：native 实现的服务端 `/hello.deviceId` 可以继续输出 app 注入值（框架透传 appMeta），但**跨设备唯一性由 USB 身份保证，不依赖 `/hello.deviceId`**。

### 5.4 交叉识别分层兜底链（`cross_identify.py`）

5 层逐层抽取已匹配对，每层从剩余池移除已配项：

| 层 | 匹配键 | 适用 | reason 标签 |
|---|---|---|---|
| 2（先判） | `UsbCandidate.android_lan_ip == LanCandidate.host`（精确 IP） | Android 独有 | `android_ip` |
| 1 | 单 USB + 单 LAN 1对1 直接合并（退化兜底） | 两侧各剩一个 | `single_device` |
| 3 | `(hardwareName, machineId)` 桥梁字段联合键，要求 lan_pool 内唯一 | 多设备、有 FF001 字段 | `bridge_field` |
| 4/5 | 无法消歧 → `[ambiguous]` 标记，不强行猜 | iOS 同型号同名 | `ambiguous` |

→ **对 native 的约束**：若 native 实现要支持多设备发现，`/hello` 必须输出 `hardwareName` + `machineId`（FF001），否则只能走层 1/2。单设备场景可省。

---

## §6 protocolVersion（跨语言硬常量）

- **`protocolVersion = 1`** 是跨语言硬常量（`control_plane.dart:10` `kDebugControlPlaneProtocolVersion`）。
- **独立于包版本**：Dart pubspec 当前 `0.1.2`、Python `0.1.1`、Kotlin 未来 `0.2.0`——包版本各自演进，但 `protocolVersion` 三端必须同值 `1`。只有协议发生不兼容破坏性变更时才递增（如 SSE 帧格式改、`/hello` schema 删字段），向后兼容的字段新增**不**递增。
- **fixture 守卫**：`fixtures/hello.json` 的 `protocolVersion` 字段固定 `1`，BF004-3 的 `ci/protocol-version-guard.sh` 会校验三端（Dart 常量 / Kotlin 常量 / fixture 值）同值。

---

## §7 不确定点 / 已知历史包袱

以下点是 Dart 现状的已知行为，native 实现照搬即可，但标注以待未来决策：

- **U1（已消解）**：`registeredCapabilities[].resources[].path` 序列化格式——slice-1 曾存疑，现由 `aggregate_capabilities_test.dart:160` + Python `_opt_json_list` 确认是 **JSON 数组**（§2.3）。
- **U2**：SSE 心跳策略缺失。当前无应用层心跳，长时间无事件时连接静默。native（尤其 Android 的 NetworkCallback 网络切换）是否补 `: ping\n\n` 心跳待决策。
- **U3**：sequence 重连不续传。SSE 无 `id:` 字段，客户端断连重连无法用 `Last-Event-ID` 续传。
- **U4**：`/events` 内省兜底（`{ok:true, note:'event_bus_is_stream'}`）在生产 HTTP 传输下永远不可达（被 hijack）。native 若用不同传输实现，建议保留兜底（契约完整性），标注"仅非 SSE 传输可达"。
- **U5**：`profileRevision` 恒为 1（`control_plane.dart:213`）。遗留字段，框架不维护递增。Python 端解析它但无递增触发逻辑。native 照搬 `1`。
- **U6**：POST body 强制 object。空 body 会触发 JSON 解析失败 → 400 `invalid_request`。某些 capability command 语义上可能不需 body（如 `/reset`）——当前契约下也得发 `{}`。
- **U7**：path 段空尾处理依赖 HTTP 服务器实现。Dart `Uri.pathSegments` 去尾部空段（`/hello/` → `['hello']`）。native 必须复现"去空尾段"语义（spike-a 的 `RoutePath.segments()` 已对齐）。

---

## 附：契约字段速查表（跨语言对齐用）

| 契约点 | 确切值 | native 必须对齐 | fixture 参考 |
|---|---|---|---|
| 协议版本 | `protocolVersion = 1` | 是 | `fixtures/hello.json` |
| 系统路由 | `GET /hello`、`GET /state`、`GET /events` | 是 | `fixtures/hello.json` / `state-*.json` / `sse-*.bin` |
| `/events` 首帧 | `: connected\n\n` | 是（字节级） | `fixtures/sse-connected.bin` |
| SSE 事件帧 | `event: <type>\ndata: <json>\n\n` | 是（字节级） | `fixtures/sse-event-frame.bin` |
| `/state` 无 `ok` 包裹 | 扁平 object | 是 | `fixtures/state-empty.json` / `state-with-cap.json` |
| 错误体 | `{ok:false, code, message}` | 是 | `fixtures/error-*.json` |
| 错误 code 枚举 | `not_found`/`invalid_request`/`internal_error` | 是（字符串级） | `fixtures/error-404.json` / `error-400.json` / `error-500.json` |
| 端口 | 18080 | 是 | `fixtures/discovery-python.json` |
| `/hello.registeredCapabilities` schema | `[{id, resources:[{method,path,description?}], commands:[...]}]` | 是（结构级） | `fixtures/hello.json` |
| **`path` 是 JSON 数组** | `["profiles","{id}"]` 而非 `"/profiles/{id}"` | 是（跨语言坑） | `fixtures/route-decl.json` / `hello.json` |
| Content-Type (JSON) | `application/json` | 是 | — |
| Content-Type (SSE) | `text/event-stream; charset=utf-8` | 是 | — |
| SSE headers | `Cache-Control: no-cache`, `Connection: keep-alive` | 是 | — |
| 路由匹配 | 扁平、无前缀、首匹配胜出、`{name}` 占位符 | 是（语义级） | `fixtures/route-decl.json` |
| POST body 强制 object | 非 object → 400 | 是 | `fixtures/error-400.json` |
| `DebugEvent.toJson` | `{type, sequence, ...payload}` | 是 | `fixtures/sse-event-frame.bin` |
