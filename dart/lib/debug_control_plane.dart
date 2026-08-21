/// Debug control plane framework.
///
/// Three-layer skeleton:
/// * [ControlPlane] — capability registry + addressing/dispatch + SSE event
///   bus + discovery handshake (/hello).
/// * [Capability] — plugin contract (resources / commands / events / state).
/// * [Transport] — protocol-agnostic transport contract (bind / listen /
///   broadcast / serverInfo / close); `HttpSseTransport` is the REST + SSE
///   implementation, the contract is reserved for WS / MCP.
///
/// Zero business dependencies: this package only depends on the Flutter SDK
/// (decision D2). Capabilities declare routes; the framework routes by
/// `(method, segments)` with flat, prefix-less paths (decision D6).
library debug_control_plane;

export 'src/control_plane.dart';
export 'src/capability.dart';
export 'src/debug_auth.dart';
export 'src/transport.dart';
export 'src/http_sse_transport.dart';
export 'src/http_codec.dart';
export 'src/debug_event.dart';
export 'src/route_failure.dart';
