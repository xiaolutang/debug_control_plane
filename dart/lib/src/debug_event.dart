/// A debug event flowing through the control plane event bus.
///
/// Promoted from a legacy private `_DebugEvent` (internal debug runtime).
/// The JSON shape is byte-level compatible:
///
/// ```json
/// {"type": "controller_state_changed", "sequence": 12, ...payload}
/// ```
///
/// Payloads are uniformly `Map<String, Object?>` (decision D3) so the
/// framework never needs to know business types.
final class DebugEvent {
  /// Create a debug event.
  const DebugEvent({
    required this.type,
    required this.sequence,
    required this.payload,
  });

  /// Event type, e.g. `controller_state_changed`, `error`.
  final String type;

  /// Monotonic sequence number assigned by the control plane event bus.
  final int sequence;

  /// Event payload. Spread into [toJson] after `type` / `sequence`.
  final Map<String, Object?> payload;

  /// Serialize to a JSON-compatible map.
  ///
  /// Shape: `{type, sequence, ...payload}` — byte-level compatible with the
  /// legacy runtime SSE encoding.
  Map<String, Object?> toJson() {
    return <String, Object?>{'type': type, 'sequence': sequence, ...payload};
  }

  @override
  String toString() =>
      'DebugEvent(type: $type, sequence: $sequence, payload: $payload)';
}
