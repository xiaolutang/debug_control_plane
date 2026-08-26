import 'package:debug_control_plane/debug_control_plane.dart';

import 'bridge_capability.dart';
import 'native_control_plane_bridge.dart';

/// R003-FB001: page-level capability lifecycle registrar for the Flutter
/// business side.
///
/// A page constructs one instance with its stable [pageId] (and optional
/// display-only [pageName]), calls [registerAll] once on open with the page's
/// capabilities, and calls [dispose] on close. The helper sends explicit
/// `scope='page'` payloads over the bridge — the business side never assembles
/// channel payloads by hand.
///
/// Semantics (contract KD-2, two-phase):
/// * Pre-check phase — terminal state ([registerAll] after [dispose]),
///   duplicate capIds inside the input list, and conflicts against this
///   page's already-registered capIds all throw [StateError] BEFORE any
///   channel traffic (zero messages, zero side effects).
/// * Send phase — each capability is registered one-by-one via
///   `bridge.register(cap, scope: _scope)`. A bridge-side failure is accepted
///   as a partial registration: it is wrapped in a [StateError] whose message
///   lists the successfully registered capIds; no undo is performed, but this
///   helper's internal list stays consistent with what is actually registered.
/// * Idempotent replay — re-invoking [registerAll] with a list whose capId
///   sequence deep-equals the currently registered sequence is a no-op (zero
///   channel messages). Any other sequence (new members or reordered) throws
///   [StateError] — no incremental registration within a page lifetime.
///
/// Multiple pages coexist safely: disposing page A only removes the
/// `(page, A, id)` keys — `(page, B, id)` and `(app, id)` are untouched
/// because the exact same [CapabilityScope] instance is passed to both
/// register and unregister (never the app-only default).
final class PageCapabilityScope {
  /// Create a page scope for [pageId].
  ///
  /// [pageId] must be a non-blank string ([ArgumentError] otherwise) — the
  /// check happens at construction time so malformed identity never produces
  /// channel traffic. The full validation invariants stay owned by the
  /// `CapabilityScope.page()` factory, which is invoked once here and reused
  /// for every register/unregister call.
  PageCapabilityScope({
    required NativeControlPlaneBridge bridge,
    required String pageId,
    String? pageName,
  })  : _bridge = bridge,
        _scope = CapabilityScope.page(pageId: pageId, pageName: pageName);

  final NativeControlPlaneBridge _bridge;
  final CapabilityScope _scope;

  /// This page's successfully registered capIds, in registration order —
  /// the state source backing [registeredCount] and the pre-check/idempotence
  /// comparisons.
  final List<String> _registeredCapIds = <String>[];

  bool _disposed = false;

  /// The stable page identity used in every payload and registry key.
  String get pageId => _scope.pageId!;

  /// Number of capabilities currently registered under this page's scope.
  ///
  /// During a partially failed [registerAll] this reflects the actually
  /// successful subset (KD-2 send-phase consistency).
  int get registeredCount => _registeredCapIds.length;

  /// Whether [dispose] has completed for this scope (terminal state — the
  /// scope cannot be revived).
  bool get isDisposed => _disposed;

  /// Register [capabilities] under this page's page scope
  /// (`capability.register` with `scope='page'`, `pageId`, `pageName?`).
  ///
  /// See the class doc for the two-phase error semantics.
  Future<void> registerAll(List<BridgeCapability> capabilities) async {
    // ---- Pre-check phase: zero channel messages on any failure -------------
    if (_disposed) {
      throw StateError(
        'PageCapabilityScope($pageId) is disposed; '
        'cannot register capabilities.',
      );
    }
    final seen = <String>{};
    for (final cap in capabilities) {
      if (!seen.add(cap.id)) {
        throw StateError(
          'Duplicate capability id "${cap.id}" inside the input list '
          'for page "$pageId".',
        );
      }
    }
    final current = List<String>.of(_registeredCapIds);
    var sameSequence = current.length == capabilities.length;
    for (var i = 0; sameSequence && i < current.length; i++) {
      if (current[i] != capabilities[i].id) sameSequence = false;
    }
    if (sameSequence) {
      // Idempotent replay of the identical list — no-op, zero messages.
      return;
    }
    for (final capId in capabilities) {
      if (current.contains(capId.id)) {
        throw StateError(
          'Capability "$capId" is already registered for page "$pageId"; '
          'incremental registration is not supported.',
        );
      }
    }

    // ---- Send phase: one-by-one await, partial failure accepted (no undo) --
    for (final cap in capabilities) {
      try {
        await _bridge.register(cap, scope: _scope);
      } catch (error) {
        throw StateError(
          'Failed to register capability "${cap.id}" for page "$pageId": '
          '$error. Successfully registered before the failure: '
          '${current.isEmpty ? '<none>' : current.join(', ')}',
        );
      }
      current.add(cap.id);
      _registeredCapIds.add(cap.id);
    }
  }

  /// Unregister every capability registered by this page scope
  /// (`capability.unregister` with `scope='page'` + `pageId` — explicitly
  /// scoped, never the app-only default).
  ///
  /// Idempotent: calling again after completion is a no-op with zero channel
  /// messages.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final capId in List<String>.of(_registeredCapIds)) {
      await _bridge.unregister(capId, scope: _scope);
    }
    _registeredCapIds.clear();
  }
}
