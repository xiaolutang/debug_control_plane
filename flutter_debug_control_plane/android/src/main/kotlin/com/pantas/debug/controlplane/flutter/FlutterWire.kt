package com.pantas.debug.controlplane.flutter

import org.json.JSONArray
import org.json.JSONObject

/**
 * R026 e2e defect #2: org.json types must never cross the MethodChannel
 * boundary.
 *
 * The Kotlin core parses POST bodies with org.json
 * (HttpSseTransport.parseJsonObjectBody), so nested values inside
 * `RouteContext.body` arrive here as [JSONObject]/[JSONArray].
 * `StandardMessageCodec.writeValue` only accepts codec-safe JVM types
 * (null/Boolean/Integer/Long/Float/Double/BigInteger/CharSequence/byte[]/
 * List/Map) and throws IllegalArgumentException on org.json types — FATAL
 * on the Android main thread when `channel.invokeMethod` encodes the args.
 *
 * Conversion lives in the PLUGIN module (never the Kotlin core — the core
 * must stay Flutter-agnostic): the reverse-invoke outgoing boundary is the
 * only direction that can carry core-parsed org.json values. Forward calls
 * (Dart -> native `onMethodCall`) are decoded by the codec and are already
 * plain types.
 */
internal fun Map<String, Any?>.toFlutterWire(): Map<String, Any?> =
    mapValues { it.value.toFlutterWireValue() }

/** Recursive org.json -> codec-safe conversion of a single value. */
private fun Any?.toFlutterWireValue(): Any? = when (this) {
    JSONObject.NULL -> null
    is JSONObject -> {
        val out = LinkedHashMap<String, Any?>(length())
        for (key in keys()) out[key] = get(key).toFlutterWireValue()
        out
    }
    is JSONArray -> {
        val out = ArrayList<Any?>(length())
        for (i in 0 until length()) out += get(i).toFlutterWireValue()
        out
    }
    // Plain Kotlin containers recurse too — RouteContext.body is a plain
    // LinkedHashMap that HOLDS JSONObject/JSONArray values; skipping this
    // would pass the map through untouched with org.json still inside.
    is Map<*, *> -> {
        val out = LinkedHashMap<String, Any?>(size)
        for ((k, v) in this) out[k.toString()] = v.toFlutterWireValue()
        out
    }
    is Collection<*> -> {
        val out = ArrayList<Any?>(size)
        for (v in this) out += v.toFlutterWireValue()
        out
    }
    // Float is NOT codec-safe (StandardMessageCodec has no Float case) —
    // widen defensively; unreachable today (org.json yields Double) but a
    // future Kotlin-side value producer would FATAL the main thread again.
    is Float -> toDouble()
    // Codec-safe scalars pass through untouched (Double stays Double — no
    // precision loss; Long/Int/Boolean/String are natively supported).
    else -> this
}
