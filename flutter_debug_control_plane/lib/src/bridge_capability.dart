import 'package:debug_control_plane/debug_control_plane.dart';

/// FF001-3: 把 Dart 核心形态的 [Capability] 适配为可注册进
/// [NativeControlPlaneBridge] 的桥接 capability。
///
/// **D2 承接（单订阅契约）**：`events` 是热源（Dart 业务侧生产、native
/// ControlPlane 侧消费一次，等价于 Kotlin `callbackFlow` 的单订阅语义）。
/// 第一次访问 [events] 返回底层流；第二次访问直接抛 [StateError]——
/// 多订阅者在 channel 上会产生消息分发歧义，契约上禁止。
///
/// handler 闭包留在 Dart 侧（闭包不可序列化，PROTOCOL.md channel 层）：
/// native dispatch 命中声明后经 `capability.invoke` 反向调用，
/// [NativeControlPlaneBridge] 按 `routeIndex` 查回此处包装的声明并调
/// `handler`。
class BridgeCapability implements Capability {
  /// Create a bridge capability wrapping [inner].
  BridgeCapability(this._inner);

  final Capability _inner;
  bool _eventsTaken = false;

  @override
  String get id => _inner.id;

  @override
  List<Resource> get resources => _inner.resources;

  @override
  List<Command> get commands => _inner.commands;

  @override
  Map<String, Object?> state() => _inner.state();

  /// 单订阅 events（D2）：只允许被收集一次。
  ///
  /// 返回底层 capability 的 events 流；第二次访问抛 [StateError]。注意
  /// 「访问即占用」——即使第一次返回的流从未被 listen，第二次访问也会
  /// 抛错（与 Kotlin `callbackFlow` 只允许一个 collector 的语义一致）。
  @override
  Stream<DebugEvent> get events {
    if (_eventsTaken) {
      throw StateError(
        'BridgeCapability.events is single-subscription (D2): '
        'already collected for capability "${id}".',
      );
    }
    _eventsTaken = true;
    return _inner.events;
  }
}
