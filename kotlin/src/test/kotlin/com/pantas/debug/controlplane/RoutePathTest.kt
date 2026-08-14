package com.pantas.debug.controlplane

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [RoutePath] — mirrors Dart `ControlPlane._matchPath`
 * (control_plane.dart L294-311). Pure function, no HTTP coupling.
 */
class RoutePathTest {

    @Test
    fun literalMatchNoPlaceholder() {
        val params = mutableMapOf<String, String>()
        assertTrue(RoutePath.match(listOf("profiles"), listOf("profiles"), params))
        assertTrue(params.isEmpty())
    }

    @Test
    fun singleSegmentPlaceholderCaptures() {
        val params = mutableMapOf<String, String>()
        assertTrue(RoutePath.match(listOf("profiles", "{id}"), listOf("profiles", "abc"), params))
        assertEquals(mapOf("id" to "abc"), params)
    }

    @Test
    fun segmentCountMismatchFails() {
        val params = mutableMapOf<String, String>()
        // Declaration has 2 segments, actual has 1.
        assertFalse(RoutePath.match(listOf("profiles", "{id}"), listOf("profiles"), params))
        // And vice versa.
        assertFalse(RoutePath.match(listOf("profiles"), listOf("profiles", "abc"), params))
        assertTrue(params.isEmpty())
    }

    @Test
    fun literalSegmentMustEqualExactly() {
        val params = mutableMapOf<String, String>()
        assertFalse(RoutePath.match(listOf("profiles", "{id}"), listOf("settings", "abc"), params))
        assertTrue(params.isEmpty())
    }

    @Test
    fun placeholderAcceptsAnyNonBracketedToken() {
        val params = mutableMapOf<String, String>()
        // {id} matches even URL-reserved-ish segments (no percent-decode here —
        // segment comparison is literal, matching Dart pathSegments behavior
        // for already-decoded input).
        assertTrue(RoutePath.match(listOf("u", "{id}"), listOf("u", "user-1"), params))
        assertEquals("user-1", params["id"])
    }

    @Test
    fun segmentsSplitStripsLeadingTrailingSlash() {
        assertEquals(listOf("profiles"), RoutePath.segments("/profiles"))
        assertEquals(listOf("profiles", "{id}"), RoutePath.segments("/profiles/{id}"))
        assertEquals(listOf("profiles", "{id}"), RoutePath.segments("profiles/{id}/"))
        assertEquals(emptyList<String>(), RoutePath.segments("/"))
        assertEquals(emptyList<String>(), RoutePath.segments(""))
    }
}
