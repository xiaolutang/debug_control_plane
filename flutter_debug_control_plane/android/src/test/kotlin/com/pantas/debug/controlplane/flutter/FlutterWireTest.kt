package com.pantas.debug.controlplane.flutter

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R026 e2e defect #2: org.json types must not cross the reverse-invoke
 * boundary.
 *
 * Real-device POST /input with a nested body (`{"frame":{"keys":[...]}}`)
 * crashed the app: `StandardMessageCodec.writeValue` rejects
 * org.json.JSONObject/JSONArray with IllegalArgumentException (FATAL on the
 * main thread). The Kotlin core parses bodies via org.json, so nested values
 * inside [com.pantas.debug.controlplane.RouteContext.body] arrive as
 * JSONObject/JSONArray; the plugin must convert them to plain
 * Map/List/scalars BEFORE channel.invokeMethod.
 */
class FlutterWireTest {

    /** Recursive assertion: no JSONObject/JSONArray anywhere in the tree. */
    private fun assertNoOrgJson(value: Any?) {
        when (value) {
            is JSONObject -> throw AssertionError("JSONObject leaked at $value")
            is JSONArray -> throw AssertionError("JSONArray leaked at $value")
            is Map<*, *> -> value.values.forEach { assertNoOrgJson(it) }
            is List<*> -> value.forEach { assertNoOrgJson(it) }
        }
    }

    @Test
    fun `nested JSONObject and JSONArray convert recursively to Map and List`() {
        val body = linkedMapOf<String, Any?>(
            "action" to "dpad_down",
            "frame" to JSONObject(
                """{"keys":["down","A"],"modifiers":{"double":true}}""",
            ),
            "hold" to 250.0,
            "seq" to JSONArray("""[1,2,{"nested":[]}]"""),
        )

        val converted = body.toFlutterWire() as Map<*, *>

        // Depth-1: plain values untouched.
        assertEquals("dpad_down", converted["action"])
        assertEquals(250.0, converted["hold"])
        // Depth-2: JSONObject -> Map.
        val frame = converted["frame"] as Map<*, *>
        assertEquals(listOf("down", "A"), frame["keys"])
        assertEquals(true, (frame["modifiers"] as Map<*, *>)["double"])
        // Depth-2 JSONArray -> List, containing a further nested JSONObject.
        val seq = converted["seq"] as List<*>
        // org.json parses JSON integers as Integer (both the JVM stub and
        // the Android platform impl) — the converter must pass them through.
        assertEquals(1, seq[0])
        assertEquals(2, seq[1])
        // Depth-3: JSONObject inside JSONArray, containing an empty JSONArray.
        assertEquals(mapOf("nested" to emptyList<Any?>()), seq[2])
        // Whole tree free of org.json types.
        assertNoOrgJson(converted)
    }

    @Test
    fun `JSONObject NULL converts to null and Double keeps full precision`() {
        val body = mapOf<String, Any?>(
            "absent" to JSONObject.NULL,
            "ratio" to 0.30000000000000004, // JS-ish float artifact, must survive
            "count" to 42L,
        )

        val converted = body.toFlutterWire() as Map<*, *>

        assertNull(converted["absent"])
        assertEquals(0.30000000000000004, converted["ratio"])
        assertEquals(java.lang.Double::class.java, converted["ratio"]!!.javaClass)
        assertEquals(42L, converted["count"])
        assertNoOrgJson(converted)
    }

    @Test
    fun `empty and scalar-only bodies pass through without regression`() {
        assertEquals(emptyMap<String, Any?>(), emptyMap<String, Any?>().toFlutterWire())
        val scalar = mapOf<String, Any?>("s" to "x", "i" to 1, "d" to 2.5, "b" to false, "n" to null)
        assertEquals(scalar, scalar.toFlutterWire())
        assertNoOrgJson(scalar.toFlutterWire())
    }
}
