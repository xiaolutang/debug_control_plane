package com.pantas.debug.controlplane

import fi.iki.elonen.NanoHTTPD
import fi.iki.elonen.NanoHTTPD.Response
import org.json.JSONArray
import org.json.JSONObject

/**
 * Result type mirroring Dart `transport.dart` `RouteResult` (statusCode int +
 * JSON body map — protocol-agnostic, decoupled from NanoHTTPD status enum).
 *
 * `toNanoResponse()` is the HTTP wire adapter: [AnyToJson] converts the body
 * map (lists, nested maps, scalars) into org.json types — needed because
 * `/hello.registeredCapabilities[].resources[].path` is a JSON array
 * (PROTOCOL.md §2.3) and `localIps` is a string array.
 *
 * Factory parity with Dart: [ok] is 200 + body; [error] spreads
 * `{ok:false, code, message}` (PROTOCOL.md §4.1).
 */
sealed class RouteResult {
    abstract fun toNanoResponse(): Response

    data class Ok(
        val body: Map<String, Any?>,
        val status: Int = 200,
    ) : RouteResult() {
        override fun toNanoResponse(): Response =
            NanoHTTPD.newFixedLengthResponse(
                Response.Status.lookup(status), "application/json",
                AnyToJson.encodeObject(body)
            )
    }

    data class Error(
        val statusCode: Int,
        val code: String,
        val message: String,
    ) : RouteResult() {
        override fun toNanoResponse(): Response {
            // Manual key-order-preserving encoding: Dart jsonEncode emits
            // insertion order (`ok, code, message` — fixtures/error-*.json),
            // while org.json's JSONObject is backed by an unordered HashMap.
            val encoded = """{"ok":false,"code":${JSONObject.quote(code)},"message":${JSONObject.quote(message)}}"""
            return NanoHTTPD.newFixedLengthResponse(
                Response.Status.lookup(statusCode), "application/json", encoded
            )
        }
    }

    companion object {
        /** A 200 success with the given JSON body. */
        fun ok(body: Map<String, Any?>) = Ok(body)

        /** An error result with `{ok:false, code, message}` body shape. */
        fun error(statusCode: Int, code: String, message: String) =
            Error(statusCode, code, message)
    }
}

/** Recursively convert Kotlin collection/scalar values into org.json types. */
internal object AnyToJson {
    fun convert(value: Any?): Any? = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> {
            val obj = JSONObject()
            for ((k, v) in value) obj.put(k.toString(), convert(v))
            obj
        }
        is Collection<*> -> JSONArray().apply { for (v in value) put(convert(v)) }
        is Array<*> -> JSONArray().apply { for (v in value) put(convert(v)) }
        else -> value
    }

    /** Encode a top-level object map to a JSON string. */
    fun encodeObject(body: Map<String, Any?>): String =
        (convert(body) as JSONObject).toString()
}
