package com.pantas.debug.controlplane

/**
 * Common declaration shape shared by [Resource] and [Command], mirrored into
 * `/hello.registeredCapabilities` (PROTOCOL.md §2.2).
 */
interface RouteDecl {
    /** HTTP method, upper-cased (`GET` for resources, `POST` for commands). */
    val method: String

    /**
     * Path segments with optional `{name}` placeholders.
     *
     * ⚠️ Cross-language pitfall (PROTOCOL.md §2.3): `path` is a JSON array
     * (`["items", "{id}"]`), NOT a `/`-joined string. Kotlin keeps it as
     * [List] so encoding is array-form by construction.
     */
    val path: List<String>

    /**
     * Optional human-readable description. Surfaced in
     * `/hello.registeredCapabilities[].resources[].description`; the key is
     * OMITTED from the schema when null (decision D3, backward compatible).
     */
    val description: String?
}

/**
 * A GET resource declared by a [Capability].
 *
 * Pure declaration data — no handler closure (unlike Dart) so it can be
 * transported over the FF001 MethodChannel; dispatch calls back into
 * [Capability.handleResource] with the matched instance.
 */
data class Resource(
    override val method: String = "GET",
    override val path: List<String>,
    override val description: String? = null,
) : RouteDecl

/**
 * A POST command declared by a [Capability]. Same matching semantics as
 * [Resource].
 */
data class Command(
    override val method: String = "POST",
    override val path: List<String>,
    override val description: String? = null,
) : RouteDecl
