import 'dart:async';

import 'package:debug_control_plane/debug_control_plane.dart';
import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart';
import 'package:flutter_test/flutter_test.dart';

/// FF001-3 test doubles: a Dart core shaped capability (closure handlers).
class _FakeCapability implements Capability {
  _FakeCapability(this.id);

  @override
  final String id;

  final StreamController<DebugEvent> _events =
      StreamController<DebugEvent>.broadcast();

  final List<Object?> resourceCalls = [];
  final List<Object?> commandCalls = [];

  @override
  List<Resource> get resources => [
        Resource(
          method: 'GET',
          path: const ['virtual', 'state'],
          description: 'virtual state',
          handler: (ctx) async {
            resourceCalls.add(ctx.pathParams);
            return {'ok': true, 'params': ctx.pathParams};
          },
        ),
      ];

  @override
  List<Command> get commands => [
        Command(
          method: 'POST',
          path: const ['virtual', 'press'],
          handler: (ctx) async {
            commandCalls.add(ctx.body);
            return {'ok': true, 'body': ctx.body};
          },
        ),
      ];

  @override
  Map<String, Object?> state() => {'connected': true};

  @override
  Stream<DebugEvent> get events => _events.stream;
}

void main() {
  test('BridgeCapability forwards id/resources/commands/state from inner', () {
    final inner = _FakeCapability('gamepad');
    final bridge = BridgeCapability(inner);

    expect(bridge.id, 'gamepad');
    expect(bridge.resources.map((r) => r.path), [
      ['virtual', 'state']
    ]);
    expect(bridge.commands.map((c) => c.path), [
      ['virtual', 'press']
    ]);
    expect(bridge.state(), {'connected': true});
  });

  test('D2 single-subscription: first events access returns the stream',
      () async {
    final inner = _FakeCapability('gamepad');
    final bridge = BridgeCapability(inner);

    final received = <DebugEvent>[];
    final sub = bridge.events.listen(received.add);
    inner._events.add(const DebugEvent(type: 't', sequence: 0, payload: {}));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(received, hasLength(1));
    expect(received.single.type, 't');
  });

  test('D2 single-subscription: second events access throws StateError', () {
    final inner = _FakeCapability('gamepad');
    final bridge = BridgeCapability(inner);

    expect(bridge.events, isA<Stream<DebugEvent>>());
    expect(
      () => bridge.events,
      throwsA(isA<StateError>()),
    );
  });

  test('D2 single-subscription: throws even if first stream never listened',
      () {
    final inner = _FakeCapability('gamepad');
    final bridge = BridgeCapability(inner);

    // Access once (occupied), do not listen.
    // ignore: unnecessary_statements
    bridge.events;

    expect(() => bridge.events, throwsA(isA<StateError>()));
  });
}
