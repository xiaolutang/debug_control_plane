/// R006-FF001: 授权策略（authPolicy）——Dart 侧类型面。
///
/// 授权策略是**装配时决策**（design §1）：在 `plane.start` 时一次性传入，
/// 由 native 装配层（R006-BF001 `ensurePlane`）决定 ControlPlane 以哪种
/// 鉴权形态挂载，运行期不可切换。
///
/// 三值语义：
///
/// | 值 | wire 字符串 | 语义 | 装配结果 |
/// |---|---|---|---|
/// | [AuthPolicy.defaultPolicy] | `default` | 现状（0.5.1）：每次请求弹授权确认 | `PluginDebugAuthManager(autoApprove=false)` |
/// | [AuthPolicy.auto] | `auto` | 自动批准：落库即 approve，宿主仍收到审计通知 | `PluginDebugAuthManager(autoApprove=true)` |
/// | [AuthPolicy.none] | `none` | 无鉴权：纯平面，python 直连零 token | `authManager=null`（与纯 Dart 宿主同构） |
///
/// **缺席 = 现状**：`start()` 不传 `authPolicy` 时参数表中不含该键，
/// native 侧走 default 分支——对 0.5.1 字节兼容。
///
/// `defaultPolicy` 命名回避 Dart 保留字 `default`（design D7）。
enum AuthPolicy {
  /// 现状策略（0.5.1）：每次授权请求等待宿主确认。
  defaultPolicy('default'),

  /// 自动批准：pending 落库后立即 approve（宿主通知仍发出，审计可见）。
  auto('auto'),

  /// 无鉴权：装配时不挂 authManager（与纯 Dart 宿主 ControlPlane 同构）。
  none('none');

  const AuthPolicy(this.wireName);

  /// Channel wire 字符串（与 Kotlin `ChannelProtocol.AUTH_POLICY_*`
  /// 逐字对齐，alignment test 守护）。
  final String wireName;

  /// Channel 缺席语义：null / `'default'` → [AuthPolicy.defaultPolicy]
  ///（向后兼容 0.5.1）。未知 wire 值抛 [ArgumentError]——封闭 enum 使
  /// Dart 侧非法值不可构造，此方法兜底反序列化路径。
  static AuthPolicy fromWire(String? wire) => switch (wire) {
        null || 'default' => AuthPolicy.defaultPolicy,
        'auto' => AuthPolicy.auto,
        'none' => AuthPolicy.none,
        _ => throw ArgumentError.value(
            wire, 'authPolicy', 'unknown authPolicy wire value'),
      };
}
