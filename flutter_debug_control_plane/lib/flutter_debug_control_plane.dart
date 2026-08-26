/// FF001-3: Flutter bridge for the debug_control_plane Kotlin core
/// (Android only).
///
/// Public surface:
/// * [NativeControlPlaneBridge] — Dart-side plane facade over MethodChannel
///   (register / unregister / start / stop / events upstream / state push /
///   reverse-invoke dispatch).
/// * [BridgeCapability] — adapts a Dart core `Capability` for registration
///   (single-subscription events, D2).
/// * [PageCapabilityScope] — page-level capability lifecycle registrar
///   (R003-FB001): explicit `scope='page'` register/dispose so the business
///   side never hand-assembles channel payloads.
/// * Channel protocol constants ([kMethodChannel], ...).
///
/// Zero business dependencies: only `debug_control_plane` (Dart core,
/// untouched) + the Flutter SDK. The Dart core Capability interface is a
/// hard zero-change constraint — this package only consumes it.
library flutter_debug_control_plane;

export 'src/bridge_capability.dart';
export 'src/channel_protocol.dart';
export 'src/page_capability_scope.dart';
export 'src/native_control_plane_bridge.dart';
