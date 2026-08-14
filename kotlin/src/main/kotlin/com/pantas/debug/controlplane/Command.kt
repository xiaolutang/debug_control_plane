package com.pantas.debug.controlplane

/**
 * Command declaration marker — see [Resource.kt] for the [Command] data
 * class (it lives next to [Resource] because both implement [RouteDecl]).
 *
 * NOTE: `Command` carries `method` + `path` (JSON-array form) per
 * PROTOCOL.md §2.2 / fixtures/route-decl.json — the tasks.md sketch's
 * `Command(name, argsSchema)` shape cannot produce the wire schema and was
 * reconciled in favor of the protocol truth source.
 */
