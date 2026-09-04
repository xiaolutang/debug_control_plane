# flutter_debug_control_plane

Flutter bridge for the [debug_control_plane](../) Kotlin core (Android
only). HTTP/SSE truth source: [../PROTOCOL.md](../PROTOCOL.md) — this
document only specifies the **channel layer** (FF001-1).

## Channel composition (design §3.2.2)

| Channel | Name | Direction | Default |
|---|---|---|---|
| MethodChannel | `debug_control_plane/method` | bidirectional | on |
| EventChannel | `debug_control_plane/event` | native → Dart | **off** (YAGNI — Dart is an event producer, not consumer; contract reserved) |

## Dart → native (7)

| method | args | reply |
|---|---|---|
| `plane.start` | `{address, port, appMeta?, authPolicy?}` | `{uri: String?}` or PlatformException `bind_failed` (→ Dart `SocketException` errorCode=98, FF002-3) / `invalid_arguments` (unknown authPolicy, R006) |
| `plane.stop` | `{}` | `null` |
| `capability.register` | `{capId, resources: [Decl], commands: [Decl]}` | `null`; duplicate id → error `duplicate` |
| `capability.unregister` | `{capId}` | `null` |
| `events.emit` | `{capId, event: {type, payload}}` | `null` (sequence assigned natively, §3.1) |
| `capability.state.update` | `{capId, state: Map}` | `null` (cache + push, §3.2.4 — no runBlocking) |
| `capability.invoke.result` | `{reqId, result \| error: {statusCode, code, message}}` | `null` |

## Lifecycle ownership

The Android carrier owns the native plane lifecycle. If a foreground Service
mounts the plane, that Service must call `plane.stop()` from its own destroy
path and then cancel the owning coroutine scope. A Dart `plane.stop` only stops
a fallback plane created by the plugin itself; it intentionally does not stop a
Service-mounted carrier plane.

Closing Flutter pages, detaching an engine, or swiping the app from recents does
not guarantee process death on Android. While the owner process or Service is
alive, the fixed discovery port `18080` remains bound. If another debug app then
starts on the same device, it will receive `bind_failed` / `EADDRINUSE` until
the original owner stops its plane or the apps use distinct ports.

## native → Dart (2 reverse invokes)

| method | args | Dart fills in via |
|---|---|---|
| `capability.invoke` | `{reqId, capId, routeKind: "resource"\|"command", routeIndex, pathParams, body}` | `capability.invoke.result` |
| `capability.state.pull` | `{reqId, capId}` (rare — Dart pushes eagerly) | `capability.state.result` |

## Decl schema

```jsonc
{ "method": "GET", "path": ["profiles", "{id}"], "description": "..." }
```

⚠️ **`path` is a JSON array** (PROTOCOL.md §2.3 cross-language pitfall) —
never a `/`-joined string. `routeIndex` locates the handler by
registration-list index (no second path-string match). Reverse-invoke
timeout: 30s → 500 `internal_error` (decision B4).

## Authorization policy (authPolicy, R006)

Assembly-time decision: pass `AuthPolicy` to `NativeControlPlaneBridge.start()`
once; the native carrier (R006-BF001 `ensurePlane`) mounts the plane with the
selected auth shape. Absent param = current behavior (byte-compatible with
0.5.1).

| Policy | wire | Semantics | Assembly | Use case |
|---|---|---|---|---|
| `AuthPolicy.defaultPolicy` | `default` | Every request pops a host-side approval prompt (0.5.1 behavior) | `PluginDebugAuthManager(autoApprove=false)` | Production-adjacent debugging |
| `AuthPolicy.auto` | `auto` | Auto-approve on submit — pending lands, then instantly approved; the host notification still fires (auditable) | `PluginDebugAuthManager(autoApprove=true)` | CI / unattended device farms |
| `AuthPolicy.none` | `none` | No auth manager mounted — plain plane | `authManager=null` (isomorphic with a pure-Dart host) | Locked debug builds, local-only tools |

```dart
final uri = await bridge.start(
  address: '127.0.0.1',
  port: 18080,
  authPolicy: AuthPolicy.auto, // omit for 0.5.1 default behavior
);
```

- `auto`: existing python clients connect with zero changes — they still claim
  a token, and the claim resolves instantly.
- `none`: the plane is isomorphic with a pure-Dart host's `ControlPlane`
  (no token dance at all on the wire).
- Unknown wire values are impossible to construct from Dart (closed enum) and
  fail fast natively with `invalid_arguments` (plane not mounted).

## Constants

Dart `lib/src/channel_protocol.dart` and Kotlin
`android/.../ChannelProtocol.kt` must stay **string-identical** — guarded by
`test/channel_protocol_alignment_test.dart` (Dart side) which reads the
Kotlin file and asserts every literal.

## Standalone verification build (no Flutter host app)

```bash
../flutter_debug_control_plane/tool/fetch_flutter_artifacts.sh   # embedding jars into android/libs/
cd android && /path/to/kotlin/gradlew -p . testDebugUnitTest assembleDebug
```

This plugin release consumes Kotlin core
`com.github.xiaolutang:debug_control_plane:0.5.2` and is part of the aligned
`0.5.2` Kotlin/Dart/Flutter version line.
