package com.pantas.debug.controlplane.flutter

/**
 * FF001-1: channel protocol constants (Kotlin side).
 *
 * MUST stay string-identical with the Dart side
 * `lib/src/channel_protocol.dart` (verified by ChannelProtocolAlignmentTest).
 * Wire truth source: repo-root PROTOCOL.md (HTTP/SSE layer) + this pair
 * (channel layer).
 *
 * ⚠️ Zero business dependencies: this module may import `io.flutter.*`
 * (the plugin itself needs it) and `com.pantas.debug.controlplane.*`
 * (the Kotlin core) — nothing else.
 */
object ChannelProtocol {
    /** MethodChannel name. */
    const val METHOD_CHANNEL = "debug_control_plane/method"

    /** EventChannel name (default OFF — YAGNI, contract reserved). */
    const val EVENT_CHANNEL = "debug_control_plane/event"

    // -----------------------------------------------------------------------
    // Dart -> native forward methods (11)
    // -----------------------------------------------------------------------

    /** Start the native plane. args `{address, port, appMeta?}` -> `{uri}`. */
    const val PLANE_START = "plane.start"

    /** Stop the native plane. args `{}` -> null. */
    const val PLANE_STOP = "plane.stop"

    /**
     * Register a capability. args `{capId, resources: [Decl], commands:
     * [Decl]}`. Decl `path` is a JSON **array** (PROTOCOL.md §2.3 pitfall).
     * Duplicate id -> PlatformException code [ERROR_DUPLICATE].
     */
    const val CAPABILITY_REGISTER = "capability.register"

    /** Unregister a capability. args `{capId}` -> null. */
    const val CAPABILITY_UNREGISTER = "capability.unregister"

    /**
     * Events upstream (per-frame Dart -> native). args `{capId, event:
     * {type, payload}}`. The sequence is assigned natively (§3.1); Dart-side
     * sequence values are discarded.
     */
    const val EVENTS_EMIT = "events.emit"

    /**
     * State snapshot push (design §3.2.4: cached snapshot + Dart push, no
     * runBlocking). args `{capId, state: Map}` -> null.
     */
    const val CAPABILITY_STATE_UPDATE = "capability.state.update"

    /**
     * Dart fills in the reverse-invoke result. args `{reqId, result | error:
     * {statusCode, code, message}}` -> null.
     */
    const val CAPABILITY_INVOKE_RESULT = "capability.invoke.result"

    /** Approve a pending debug authorization request. */
    const val AUTH_APPROVE = "auth.approve"

    /** Deny a pending debug authorization request. */
    const val AUTH_DENY = "auth.deny"

    /** Revoke an authorized debug token. */
    const val AUTH_REVOKE = "auth.revoke"

    /** Query current debug authorization status. */
    const val AUTH_STATUS = "auth.status"

    // -----------------------------------------------------------------------
    // native -> Dart reverse invokes
    // -----------------------------------------------------------------------

    /**
     * Reverse invoke (handlers live on the Dart side — closures don't cross
     * the channel). args `{reqId, capId, routeKind, routeIndex, pathParams,
     * body}`. [routeIndex] locates the handler by registration-list index
     * (no second path-string match). Timeout 30s -> 500 internal_error (B4).
     */
    const val CAPABILITY_INVOKE = "capability.invoke"

    /** Ask Dart/host UI to handle a pending debug authorization request. */
    const val AUTH_REQUEST = "auth.request"

    /** Rare native-side state pull. args `{reqId, capId}`. */
    const val CAPABILITY_STATE_PULL = "capability.state.pull"

    /** Fill-in method name for [CAPABILITY_STATE_PULL]. */
    const val CAPABILITY_STATE_RESULT = "capability.state.result"

    // -----------------------------------------------------------------------
    // routeKind literals
    // -----------------------------------------------------------------------

    const val ROUTE_KIND_RESOURCE = "resource"
    const val ROUTE_KIND_COMMAND = "command"

    // -----------------------------------------------------------------------
    // PlatformException codes
    // -----------------------------------------------------------------------

    /** Duplicate registration (mirrors Dart StateError / Kotlin require). */
    const val ERROR_DUPLICATE = "duplicate"

    /**
     * R006-BF001: invalid channel argument value (e.g. an unknown authPolicy).
     * Fail-fast — the plane is NOT started, no silent default fallback (D5).
     */
    const val ERROR_INVALID_ARGUMENTS = "invalid_arguments"

    // -----------------------------------------------------------------------
    // authPolicy (R006): plane.start optional argument + wire values
    // -----------------------------------------------------------------------

    /** Optional `plane.start` argument name. Absent means [AUTH_POLICY_DEFAULT]. */
    const val AUTH_POLICY = "authPolicy"

    /** Default policy: the existing host-mediated approve/deny flow. */
    const val AUTH_POLICY_DEFAULT = "default"

    /** Auto policy: pending requests are approved instantly (R006 autoApprove). */
    const val AUTH_POLICY_AUTO = "auto"

    /** None policy: no auth gate — the plane mounts with a null auth manager. */
    const val AUTH_POLICY_NONE = "none"

    /** Legal [AUTH_POLICY] wire values. */
    val AUTH_POLICY_VALUES = setOf(AUTH_POLICY_DEFAULT, AUTH_POLICY_AUTO, AUTH_POLICY_NONE)

    /** Unknown capability id. */
    const val ERROR_NOT_REGISTERED = "not_registered"

    /** Bind failure (FF002-3 maps this to Dart SocketException code 98). */
    const val ERROR_BIND_FAILED = "bind_failed"

    /** Reverse-invoke timeout (B4): 30s withTimeout -> 500 internal_error. */
    const val INVOKE_TIMEOUT_MS = 30_000L
}
