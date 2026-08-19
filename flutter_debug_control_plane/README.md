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
| `plane.start` | `{address, port, appMeta?}` | `{uri: String?}` or PlatformException `bind_failed` (→ Dart `SocketException` errorCode=98, FF002-3) |
| `plane.stop` | `{}` | `null` |
| `capability.register` | `{capId, resources: [Decl], commands: [Decl]}` | `null`; duplicate id → error `duplicate` |
| `capability.unregister` | `{capId}` | `null` |
| `events.emit` | `{capId, event: {type, payload}}` | `null` (sequence assigned natively, §3.1) |
| `capability.state.update` | `{capId, state: Map}` | `null` (cache + push, §3.2.4 — no runBlocking) |
| `capability.invoke.result` | `{reqId, result \| error: {statusCode, code, message}}` | `null` |

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

The Kotlin core is consumed via the JitPack coordinate
`com.github.xiaolutang:debug_control_plane:0.2.0` — the whole ecosystem
(kotlin core / dart core / this plugin) shares one version line
(see [../README.md](../README.md)).
