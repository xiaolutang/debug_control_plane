package com.pantas.debug.controlplane

import org.json.JSONArray
import org.json.JSONObject

/**
 * `$$unstable:<reason>` normalization for BF003 cross-language consistency
 * tests (fixtures/README.md "归一化标记" section).
 *
 * Semantic-level fixtures mark fields whose values are environment-dependent
 * (`serverHost` / `serverPort` / `localIps` / appMeta injections /
 * `error.toString()` ...) with the placeholder string `"$$unstable:<reason>"`.
 * The comparator replaces the ACTUAL wire value at those positions with the
 * same placeholder before comparing, so environment drift never fails the
 * assertion while shape/type mismatches still do.
 *
 * Companion implementation: `dart/test/fixtures/normalize.dart` — the two
 * MUST stay logically identical (rules below), otherwise cross-language
 * comparison produces false positives.
 *
 * Rules (single source: fixtures/README.md):
 *  1. Keys starting with `_` (e.g. `_fixture_meta`) are fixture
 *     self-description metadata — skipped entirely, never compared.
 *  2. When the EXPECTED value is the exact string `$$unstable:<reason>`:
 *     - the actual value must still be present (non-missing) and, when the
 *     reason implies a type, type-compatible (`bound-port` / `sequence` →
 *     JSON number; `request-host` / `network-ips` → string / array of
 *     string; the rest accept any non-null JSON value);
 *     - both sides are then replaced by the placeholder itself.
 *  3. Everything else compares for JSON-equality (numbers by long/double
 *     value, booleans, strings, nested objects recursively, arrays
 *     element-wise in order).
 */
object FixtureNormalize {

    private const val MARKER_PREFIX = "\$\$unstable:"

    /** The closed set of `<reason>` values allowed after `$$unstable:` (fixtures/README.md table). */
    val UNSTABLE_REASONS: Set<String> = setOf(
        "request-host",
        "bound-port",
        "network-ips",
        "sequence",
        "app-injected",
        "exception-toString",
        "adb-serial",
        "usbmuxd-id",
    )

    /**
     * Normalize a parsed JSON value: drop `_`-prefixed keys recursively and
     * replace `$$unstable:<reason>` placeholder positions so [normalizedEquals]
     * sees comparable shapes.
     */
    fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> {
            val out = JSONObject()
            for (key in value.keys()) {
                if (key.startsWith("_")) continue
                out.put(key, normalize(value.get(key)))
            }
            out
        }
        is JSONArray -> {
            val out = JSONArray()
            for (i in 0 until value.length()) out.put(normalize(value.get(i)))
            out
        }
        else -> value
    }

    /** Structural equality on [normalize]d values (order-sensitive arrays). */
    fun normalizedEquals(expected: Any?, actual: Any?): Boolean {
        val e = unwrap(expected)
        val a = unwrap(actual)
        if (e is String && e.startsWith(MARKER_PREFIX)) {
            val reason = e.removePrefix(MARKER_PREFIX)
            check(reason in UNSTABLE_REASONS) {
                "unknown unstable reason '$reason' (allowed: $UNSTABLE_REASONS)"
            }
            if (a == null) return false
            // Type guards per reason family (mirrors dart/test/fixtures/normalize.dart).
            return when (reason) {
                "bound-port", "sequence" -> a is Int || a is Long || a is Double || a is Float
                "request-host", "exception-toString", "adb-serial", "usbmuxd-id" -> a is String
                "network-ips" -> a is JSONArray && (0 until a.length()).all { a.get(it) is String }
                else -> true // app-injected: any non-null JSON value
            }
        }
        if (a is String && a.startsWith(MARKER_PREFIX)) return false
        return when {
            e is JSONObject && a is JSONObject -> {
                val eKeys = e.keys().asSequence().filterNot { it.startsWith("_") }.toList()
                val aKeys = a.keys().asSequence().filterNot { it.startsWith("_") }.toList()
                if (eKeys.sorted() != aKeys.sorted()) return false
                eKeys.all { normalizedEquals(e.get(it), a.get(it)) }
            }
            e is JSONArray && a is JSONArray -> {
                if (e.length() != a.length()) return false
                (0 until e.length()).all { normalizedEquals(e.get(it), a.get(it)) }
            }
            else -> jsonScalarEquals(e, a)
        }
    }

    /** Compare scalars with number tolerance (org.json parses ints as Int/Long, decimals as Double). */
    private fun jsonScalarEquals(e: Any?, a: Any?): Boolean = when {
        e is Number && a is Number -> e.toLong() == a.toLong() || e.toDouble() == a.toDouble()
        else -> e == a
    }

    /** org.json returns JSONObject.NULL for JSON null — normalize it to Kotlin null. */
    private fun unwrap(value: Any?): Any? = if (value == JSONObject.NULL) null else value
}
