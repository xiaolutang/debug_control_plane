# 接入指南 / Getting Started

> 新项目如何接入 `debug_control_plane`(Dart/Flutter 包),在 app 进程内嵌一个调试控制平面。
>
> How a new Flutter project embeds a debug control plane (HTTP server) in-app.

## 这是什么 / What it is

在 Flutter app 内起一个 HTTP server(默认 `0.0.0.0:18080`),对外暴露:

| 端点 | 方法 | 说明 |
|------|------|------|
| `/hello` | GET | 发现握手:app 身份 + 能力清单(供外部工具/AI 自动发现) |
| `/state` | GET | 聚合状态:所有能力的状态快照 |
| `/events` | GET | SSE 事件流:能力变更实时推 |
| `/<cap>/<resource\|command>` | GET/POST | 你注册的能力路由 |

外部(curl / AI / 桌面工具)通过这套 HTTP 协议读 app 状态、写指令、订阅事件。典型用途:调试期让 AI 全链路操控 app,或让桌面工具实时观测 app。

## 平台支持 / Platform support

| 平台 | 支持 | 说明 |
|------|------|------|
| iOS / Android | ✅ | 手机端主力场景 |
| **macOS / Windows / Linux** | ✅ | `dart:io` 跨平台,桌面 Flutter app 同一套 API |
| Web | ❌ | `dart:io`(`HttpServer`)在 web 不可用 |

桌面与手机**同一套 API,不区分端**。

**平台注意(非本包特有,Flutter 通性):**
- **macOS**:若 app 走 App Sandbox(如 Mac App Store 分发),bind 网络服务器需 network entitlement;debug 工具通常非 sandbox,无影响。
- **iOS / macOS**:明文 HTTP server 需 ATS 例外(`NSAllowsLocalNetworking`)。

## 接入 5 步 / 5-step integration

### 1. 加依赖 / Add dependency

```yaml
# pubspec.yaml
dependencies:
  debug_control_plane: ^0.2.0   # 与生态同版本线(kotlin JitPack/flutter 插件同号)
```

或命令行:`flutter pub add debug_control_plane`。

### 2. import

```dart
import 'package:debug_control_plane/debug_control_plane.dart';
```

### 3. 实现一个 Capability / Implement a capability

Capability 是自包含的调试特性,声明它拥有的 GET 资源 / POST 命令 / 事件流 / 状态快照。所有 payload 用 `Map<String, Object?>`(框架不感知业务类型)。

```dart
class CounterCapability implements Capability {
  final StreamController<DebugEvent> _events =
      StreamController<DebugEvent>.broadcast();
  int _count = 0;

  @override
  String get id => 'counter';

  @override
  List<Resource> get resources => [
        Resource(
          method: 'GET',
          path: const ['counter', 'value'],   // → GET /counter/value
          description: 'Current counter value.',
          handler: (ctx) async => {'value': _count},
        ),
      ];

  @override
  List<Command> get commands => [
        Command(
          method: 'POST',
          path: const ['counter', 'increment'],  // → POST /counter/increment
          description: 'Increment counter and emit an event.',
          handler: (ctx) async {
            _count++;
            _events.add(DebugEvent(
              type: 'counter/incremented',
              sequence: 0,   // 由平面事件总线重新赋值,这里传 0
              payload: {'value': _count},
            ));
            return {'ok': true, 'value': _count};
          },
        ),
      ];

  @override
  Stream<DebugEvent> get events => _events.stream;

  @override
  Map<String, Object?> state() => {'counter.value': _count};
}
```

- **路径占位符**:`path: ['profiles', '{id}']` 匹配 `/profiles/abc`,`ctx.pathParams['id'] == 'abc'`。
- **读 body**:POST 的 JSON body 在 `ctx.body`(`Map<String, Object?>`)。
- **`description`**:可选,会进 `/hello.registeredCapabilities`,供 AI/工具渲染。

### 4. 装配 + 启动 / Assemble + start

```dart
Future<void> main() async {
  final plane = ControlPlane(
    transport: HttpSseTransport(),
    appMeta: () => {            // 注入 app 身份(/hello 用);框架保持业务无关
      'app': 'my_app',
      'deviceId': 'my-mac-001',
      'platform': 'macos',
    },
  )..register(CounterCapability());

  await plane.start(address: '0.0.0.0', port: 18080);
  // app 继续正常运行;debug server 在后台监听
}
```

### 5. 验证 / Verify

```bash
curl http://localhost:18080/hello                       # 发现握手 + 能力清单
curl http://localhost:18080/state                       # {"counter.value":0}
curl http://localhost:18080/counter/value               # {"value":0}
curl -X POST http://localhost:18080/counter/increment   # {"ok":true,"value":1}
curl http://localhost:18080/events                      # SSE 事件流
```

完整可运行示例见 [`example/debug_control_plane_example.dart`](example/debug_control_plane_example.dart)。

## API 速查 / API reference

| 符号 | 说明 |
|------|------|
| `ControlPlane({required Transport transport, Map<String,Object?> Function()? appMeta})` | 门面:`register(cap)` / `unregister(id)` / `start({address, port})` / `stop()` |
| `Capability` | 插件契约:`id` / `resources` / `commands` / `events` / `state()` |
| `Resource` / `Command` | `{method, path, handler, description?}` |
| `RouteContext` | handler 入参:`pathParams` / `body` / `request` |
| `DebugEvent` | `{type, sequence, payload}`,sequence 由平面赋 |
| `HttpSseTransport` | REST + SSE 生产传输(默认) |
| `Transport` | 协议无关契约(预留 WS / MCP) |
| `RouteFailure(statusCode, code, message)` | 结构化错误(handler 抛出) |

## 常见坑 / Pitfalls

1. **同 id 重复 register 抛 `StateError`** —— id 必须唯一(运行时 register/unregister 支持,但重复 id 拒绝)。
2. **`DebugEvent.sequence` 传 0** —— 由平面事件总线重新赋值,能力里传 0。
3. **`/hello` 的 app 身份靠 `appMeta` 注入** —— 框架不硬编码 `app` / `deviceId`,必须你提供;不提供则该块为空(但 `protocolVersion` + 能力清单仍返回)。
4. **handler 异常处理** —— 抛 `RouteFailure` 返回结构化错误;其他异常 → 500 `internal_error`。
5. **路径 flat 匹配,无前缀** —— `/counter/value` 直接匹配,不需要 `/capabilities/...` 前缀。
6. **Web 不支持** —— `dart:io` `HttpServer` 在 web 不可用;Web build 会失败(仅非 web 平台)。

## 许可证 / License

MIT —— 见 [LICENSE](LICENSE)。
