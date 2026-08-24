/// FF001-1: 双 channel 协议常量（Dart 端）。
///
/// 真理源：repo 根 [PROTOCOL.md]（HTTP/SSE 层）+ 本文件（channel 层）。
/// Kotlin 端对应文件 `ChannelProtocol.kt` 与本文件字符串**逐字对齐**
///（两端 diff 必须零差异，见 FF001-1 test）。
///
/// Channel 组合（design §3.2.2）：
/// - [kMethodChannel]：命令双向（Dart→native 正向 11 个方法 + native→Dart
///   反向 3 个 invoke）。
/// - [kEventChannel]：native→Dart 事件广播，**默认不订阅**（YAGNI——Dart
///   是事件生产者非消费者；契约预留，onListen 时才订阅 native eventBus）。

/// MethodChannel 名。
const String kMethodChannel = 'debug_control_plane/method';

/// EventChannel 名（默认 off，YAGNI）。
const String kEventChannel = 'debug_control_plane/event';

// ---------------------------------------------------------------------------
// Dart → native 正向方法（11 个）
// ---------------------------------------------------------------------------

/// 启动 native ControlPlane。args: `{address, port, appMeta?}`。
///
/// reply: `{uri: String?}`；bind 失败经 PlatformException 回
/// SocketException 语义（FF002-3 R024 降级承接，code=`bind_failed`）。
const String kMethodPlaneStart = 'plane.start';

/// 停止 native ControlPlane。args: `{}`，reply: `null`。
const String kMethodPlaneStop = 'plane.stop';

/// 注册 capability。args:
/// `{capId, resources: [Decl], commands: [Decl]}`。
///
/// Decl schema（**path 是 JSON 数组**，跨语言坑 PROTOCOL.md §2.3）：
/// ```jsonc
/// {"method": "GET", "path": ["profiles", "{id}"], "description": "..."}
/// ```
/// 重复 id → error `duplicate`。
const String kMethodCapabilityRegister = 'capability.register';

/// 注销 capability。args: `{capId}`，reply: `null`。
const String kMethodCapabilityUnregister = 'capability.unregister';

/// events 上行（Dart→native 每帧通知）。args:
/// `{capId, event: {type, payload}}`，reply: `null`（sequence 由 native
/// 分配，Dart 侧 sequence 被丢弃，PROTOCOL.md §3.1）。
const String kMethodEventsEmit = 'events.emit';

/// state 缓存主动 push（design §3.2.4：state 拉取 = 缓存快照 + Dart 主动
/// push，避免 runBlocking ANR）。args: `{capId, state: Map}`，reply: `null`。
const String kMethodCapabilityStateUpdate = 'capability.state.update';

/// Dart 回填反向调用结果。args:
/// `{reqId, result | error: {statusCode, code, message}}`，reply: `null`。
const String kMethodCapabilityInvokeResult = 'capability.invoke.result';

/// 同意调试授权请求。args: auth approve payload，reply: token/status。
const String kMethodAuthApprove = 'auth.approve';

/// 拒绝调试授权请求。args: auth deny payload，reply: status。
const String kMethodAuthDeny = 'auth.deny';

/// 撤销已授权 token。args: auth revoke payload，reply: status。
const String kMethodAuthRevoke = 'auth.revoke';

/// 查询调试授权状态。args: auth status payload，reply: auth status。
const String kMethodAuthStatus = 'auth.status';

// ---------------------------------------------------------------------------
// native → Dart 反向 invoke（MethodChannel 反向 invokeMethod）
// ---------------------------------------------------------------------------

/// 反向调用（resource/command handler 留在 Dart 侧——闭包不可序列化）。
/// args:
/// `{reqId, capId, routeKind: "resource"|"command", routeIndex, pathParams, body}`。
///
/// [routeIndex] 定位 handler（register 时声明的列表下标），避免 path
/// 字符串二次匹配。Dart 处理完回填 [kMethodCapabilityInvokeResult]。
/// 超时：native 侧 30s withTimeout 未回填 → 500 `internal_error`（B4）。
const String kMethodCapabilityInvoke = 'capability.invoke';

/// native 请求 Dart/宿主展示授权确认 UI。args:
/// `{reqId, requestId, clientLabel?, endpoint?, method?, createdAt}`。
const String kMethodAuthRequest = 'auth.request';

/// native 主动拉 state（rare；默认走 Dart 主动 push 缓存）。args:
/// `{reqId, capId}`，Dart 回填 `capability.state.result`。
const String kMethodCapabilityStatePull = 'capability.state.pull';

/// [kMethodCapabilityStatePull] 的回填方法名。
const String kMethodCapabilityStateResult = 'capability.state.result';

// ---------------------------------------------------------------------------
// routeKind 枚举（channel 字面量）
// ---------------------------------------------------------------------------

/// routeKind：resource（GET）。
const String kRouteKindResource = 'resource';

/// routeKind：command（POST）。
const String kRouteKindCommand = 'command';

// ---------------------------------------------------------------------------
// PlatformException code（正向方法错误）
// ---------------------------------------------------------------------------

/// 重复注册 capability（映射 Dart 核心 ControlPlane.register 的 StateError）。
const String kErrorCodeDuplicate = 'duplicate';

/// capability 未注册（unregister 未知 id / emit 未知 capId）。
const String kErrorCodeNotRegistered = 'not_registered';

/// bind 失败（FF002-3 映射成 Dart SocketException(errorCode=98) 的来源）。
const String kErrorCodeBindFailed = 'bind_failed';
