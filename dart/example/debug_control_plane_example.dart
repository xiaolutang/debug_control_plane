// Minimal runnable assembly of the debug control plane.
// 调试控制平面最小可运行装配示例。
//
// Run / 运行: `dart example/debug_control_plane_example.dart`
//
// Then hit / 然后访问:
//   GET  http://localhost:18080/hello        discovery handshake / 发现握手
//   GET  http://localhost:18080/state        aggregated state / 聚合状态
//   GET  http://localhost:18080/ping/count   → {count: 0}
//   POST http://localhost:18080/ping/bump    → {ok: true, count: 1}  (+ event on /events)
//   GET  http://localhost:18080/events       SSE event stream / SSE 事件流

import 'dart:async';

import 'package:debug_control_plane/debug_control_plane.dart';

/// A toy capability: one GET resource + one POST command + an event stream.
/// 示例能力：一个 GET 资源 + 一个 POST 命令 + 一个事件流。
class PingCapability implements Capability {
  PingCapability();

  final StreamController<DebugEvent> _events =
      StreamController<DebugEvent>.broadcast();
  int _count = 0;

  @override
  String get id => 'ping';

  @override
  List<Resource> get resources => <Resource>[
        Resource(
          method: 'GET',
          path: const ['ping', 'count'],
          description: 'Current ping count.',
          handler: (RouteContext ctx) async => <String, Object?>{'count': _count},
        ),
      ];

  @override
  List<Command> get commands => <Command>[
        Command(
          method: 'POST',
          path: const ['ping', 'bump'],
          description: 'Increment the count and emit an event.',
          handler: (RouteContext ctx) async {
            _count++;
            // `sequence` is reassigned by the plane's event bus; pass 0 here.
            // `sequence` 由平面事件总线重新赋值，这里传 0 即可。
            _events.add(DebugEvent(
              type: 'ping/bumped',
              sequence: 0,
              payload: <String, Object?>{'count': _count},
            ));
            return <String, Object?>{'ok': true, 'count': _count};
          },
        ),
      ];

  @override
  Stream<DebugEvent> get events => _events.stream;

  @override
  Map<String, Object?> state() => <String, Object?>{'ping.count': _count};
}

Future<void> main() async {
  final plane = ControlPlane(
    transport: HttpSseTransport(),
    // App identity is injected here; the framework itself stays business-agnostic.
    // 应用身份在此注入；框架本体保持业务无关。
    appMeta: () => <String, Object?>{'app': 'debug_control_plane_example'},
  )..register(PingCapability());

  final uri = await plane.start(address: '0.0.0.0', port: 18080);
  print('debug control plane listening on $uri');
  print('press Ctrl+C to stop');
}
