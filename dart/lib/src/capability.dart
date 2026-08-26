import 'debug_event.dart';

/// Scope kind for a [Capability].
enum CapabilityScopeType {
  /// Application-wide capability.
  app,

  /// Page-scoped capability.
  page,
}

/// Immutable scope identity for a [Capability].
class CapabilityScope {
  /// Create an application-wide scope.
  const CapabilityScope.app()
      : type = CapabilityScopeType.app,
        pageId = null,
        pageName = null,
        revision = null;

  const CapabilityScope._({
    required this.type,
    required this.pageId,
    required this.pageName,
    required this.revision,
  });

  /// Create a page-scoped capability scope.
  factory CapabilityScope.page({
    String? pageId,
    String? pageName,
    int? revision,
  }) {
    if (pageId == null || pageId.trim().isEmpty) {
      throw ArgumentError.value(
        pageId,
        'pageId',
        'must be a non-blank string for page capability scope',
      );
    }
    return CapabilityScope._(
      type: CapabilityScopeType.page,
      pageId: pageId,
      pageName: pageName,
      revision: revision,
    );
  }

  /// Scope kind.
  final CapabilityScopeType type;

  /// Stable page identity for [CapabilityScopeType.page].
  final String? pageId;

  /// Optional display name for page metadata.
  final String? pageName;

  /// Optional scope revision metadata.
  final int? revision;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CapabilityScope &&
          other.type == type &&
          other.pageId == pageId &&
          other.pageName == pageName &&
          other.revision == revision;

  @override
  int get hashCode => Object.hash(type, pageId, pageName, revision);
}

/// Per-request context handed to a [Resource] / [Command] handler.
///
/// Protocol-agnostic: `request` is the opaque protocol handle (cast at the
/// capability side when needed). The control plane populates [pathParams]
/// from `{id}` placeholders in the declared path.
class RouteContext {
  /// Create a route context.
  const RouteContext({
    required this.pathParams,
    required this.body,
    required this.request,
  });

  /// Path parameters extracted from `{id}` placeholders.
  final Map<String, String> pathParams;

  /// Parsed JSON body (empty map for bodyless requests).
  final Map<String, Object?> body;

  /// Opaque protocol handle (e.g. `HttpRequest`). May be `null`.
  final Object? request;
}

/// A GET resource declared by a [Capability].
///
/// [path] is a list of segments; a segment of the form `{name}` matches any
/// single path segment and is captured into [RouteContext.pathParams] under
/// `name`. Example: `['profiles', '{id}']` matches `/profiles/abc` and
/// yields `pathParams = {'id': 'abc'}`.
class Resource {
  /// Create a resource declaration.
  ///
  /// [description] is an optional human-readable summary surfaced via
  /// `/hello.registeredCapabilities` (R020-FF001/FF002) for tooling that wants
  /// to render this resource to an AI/user. Defaults to `null` for backward
  /// compatibility — existing `Resource(method, path, handler)` call sites
  /// compile unchanged.
  const Resource({
    required this.method,
    required this.path,
    required this.handler,
    this.description,
  });

  /// HTTP method, upper-cased (`GET` by convention).
  final String method;

  /// Path segments with optional `{name}` placeholders.
  final List<String> path;

  /// Handler invoked when this resource matches.
  final Future<Map<String, Object?>> Function(RouteContext ctx) handler;

  /// Optional human-readable description. Surfaced in
  /// `/hello.registeredCapabilities[].resources[].description` (omitted from
  /// the schema when `null`).
  final String? description;
}

/// A POST command declared by a [Capability]. Same matching semantics as
/// [Resource].
class Command {
  /// Create a command declaration.
  ///
  /// [description] is an optional human-readable summary surfaced via
  /// `/hello.registeredCapabilities` (R020-FF001/FF002). See [Resource] for
  /// the backward-compatibility rationale.
  const Command({
    required this.method,
    required this.path,
    required this.handler,
    this.description,
  });

  /// HTTP method, upper-cased (`POST` by convention).
  final String method;

  /// Path segments with optional `{name}` placeholders.
  final List<String> path;

  /// Handler invoked when this command matches.
  final Future<Map<String, Object?>> Function(RouteContext ctx) handler;

  /// Optional human-readable description. See [Resource.description].
  final String? description;
}

/// Plugin contract. A capability declares the routes it owns (resources for
/// GET, commands for POST), an event stream, and a state snapshot.
///
/// All payloads are `Map<String, Object?>` (decision D3) — the framework
/// never sees business types.
abstract interface class Capability {
  /// Unique capability identifier (used as the registry key).
  String get id;

  /// GET resources owned by this capability.
  List<Resource> get resources;

  /// POST commands owned by this capability.
  List<Command> get commands;

  /// Event stream. The control plane subscribes once (per registration) and
  /// re-emits onto the global event bus with a sequence number assigned.
  Stream<DebugEvent> get events;

  /// State snapshot, aggregated into the `/state` system route.
  Map<String, Object?> state();
}

/// Optional capability contract for implementations that provide explicit
/// scope identity.
abstract interface class ScopedCapability implements Capability {
  /// Scope identity for this capability.
  CapabilityScope get scope;
}

/// Default scope access for [Capability].
extension CapabilityScopeDefault on Capability {
  /// Existing capability implementations default to application-wide scope.
  CapabilityScope get scope {
    final capability = this;
    if (capability is ScopedCapability) {
      return capability.scope;
    }
    return const CapabilityScope.app();
  }
}
