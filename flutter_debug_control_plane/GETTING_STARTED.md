# flutter_debug_control_plane 接入指南

> Android Flutter 宿主接入 debug_control_plane 的快速上手。
> 通道层细节见 [README.md](README.md)，HTTP/SSE 真理源见 [../PROTOCOL.md](../PROTOCOL.md)。

## 快速开始

```dart
import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart';

final bridge = NativeControlPlaneBridge();
await bridge.attach();
final uri = await bridge.start(address: '127.0.0.1', port: 18080);
await bridge.register(BridgeCapability(myCapability));
```

## 授权策略（authPolicy）

授权策略是**装配时决策**：`start()` 时传入一次，native 装配层按策略挂载
鉴权形态，运行期不可切换。不传 = 现状（0.5.1 字节兼容，每次请求弹授权确认）。

| 策略 | wire 值 | 语义 | 装配结果 | 适用场景 |
|---|---|---|---|---|
| `AuthPolicy.defaultPolicy` | `default` | 每次请求弹授权确认（0.5.1 现状） | `PluginDebugAuthManager(autoApprove=false)` | 接近生产环境的调试 |
| `AuthPolicy.auto` | `auto` | 自动批准：请求落库即批准，宿主审计通知仍发出 | `PluginDebugAuthManager(autoApprove=true)` | CI / 无人值守设备农场 |
| `AuthPolicy.none` | `none` | 不挂鉴权管理器，纯平面 | `authManager=null`（与纯 Dart 宿主同构） | 锁定调试构建、本地工具 |

```dart
// 自动批准（推荐 CI 用）
final uri = await bridge.start(
  address: '127.0.0.1',
  port: 18080,
  authPolicy: AuthPolicy.auto,
);

// 无鉴权平面
final uri = await bridge.start(
  address: '127.0.0.1',
  port: 18080,
  authPolicy: AuthPolicy.none,
);

// 不传 = 现状（默认授权确认）
final uri = await bridge.start(address: '127.0.0.1', port: 18080);
```

### auto 与 python 客户端

`auto` 策略下**已有 python 客户端零改动直连**——仍走 claim token 流程，
但请求落库后立即批准，claim 即刻成功，无需宿主人工确认。

### none 与纯 Dart 宿主

`none` 装配出的平面与纯 Dart 宿主 `ControlPlane` **同构**——线上无任何
token 流程，客户端直连即用。适合已通过其他手段锁定调试面访问的场景。
