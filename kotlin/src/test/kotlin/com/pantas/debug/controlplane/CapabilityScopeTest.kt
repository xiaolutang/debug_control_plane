package com.pantas.debug.controlplane

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class CapabilityScopeTest {

    private val fixturesDir: File =
        File(System.getProperty("user.dir")!!).resolve("../fixtures")

    @Test
    fun capability_defaultsToAppScope() {
        val capability = object : Capability {
            override val id = "legacy-capability"
            override fun resources() = emptyList<Resource>()
            override fun commands() = emptyList<Command>()
            override fun events() = kotlinx.coroutines.flow.emptyFlow<DebugEvent>()
            override suspend fun handleResource(resource: Resource, context: RouteContext) = emptyMap<String, Any?>()
            override suspend fun handleCommand(command: Command, context: RouteContext) = emptyMap<String, Any?>()
            override suspend fun state() = emptyMap<String, Any?>()
        }

        assertEquals(CapabilityScopeType.APP, capability.scope.type)
        assertEquals("app", capability.scope.type.wireValue)
        assertEquals(null, capability.scope.pageId)
        assertEquals(null, capability.scope.pageName)
        assertEquals(null, capability.scope.revision)
    }

    @Test
    fun pageScopeRetainsPageMetadata() {
        val scope = CapabilityScope.page(
            pageId = "page-a",
            pageName = "Page A",
            revision = 7L,
        )

        assertEquals(CapabilityScopeType.PAGE, scope.type)
        assertEquals("page", scope.type.wireValue)
        assertEquals("page-a", scope.pageId)
        assertEquals("Page A", scope.pageName)
        assertEquals(7L, scope.revision)
    }

    @Test
    fun pageScopeRejectsNullEmptyAndBlankPageId() {
        listOf<String?>(null, "", "   ", "\t\n").forEach { invalidPageId ->
            val error = try {
                CapabilityScope.page(pageId = invalidPageId)
                throw AssertionError("expected IllegalArgumentException for pageId=$invalidPageId")
            } catch (e: IllegalArgumentException) {
                e
            }

            assertTrue(
                "error message must identify pageId, was: ${error.message}",
                error.message?.contains("pageId") == true,
            )
            assertTrue(
                "error message must identify non-blank requirement, was: ${error.message}",
                error.message?.contains("non-blank") == true,
            )
        }
    }

    @Test
    fun fakeCapabilityCanOverrideScopeWithoutChangingId() {
        val pageA = FakeCapability(
            id = "sample.page.form",
            scope = CapabilityScope.page(pageId = "page-a", pageName = "Page A", revision = 4L),
        )
        val pageB = FakeCapability(
            id = "sample.page.form",
            scope = CapabilityScope.page(pageId = "page-b", pageName = "Different Display Name", revision = 4L),
        )

        assertEquals("sample.page.form", pageA.id)
        assertEquals(pageA.id, pageB.id)
        assertEquals("page-a", pageA.scope.pageId)
        assertEquals("page-b", pageB.scope.pageId)
        assertEquals("Different Display Name", pageB.scope.pageName)
    }

    @Test
    fun helloPageScopeFixtureUsesProtocolScopeFieldsAndPathArrays() {
        val fixture = loadFixtureJson("hello-page-scope.json")
        val capabilities = fixture.getJSONArray("registeredCapabilities")
        val app = capabilities.findObject("id", "sample.app")
        val page = capabilities.findObject("id", "sample.page.panel")

        assertEquals("app", app.getString("scope"))
        assertEquals(1L, app.getLong("scopeRevision"))
        assertFalse(app.has("pageId"))
        assertFalse(app.has("pageName"))
        assertFalse(app.has("revision"))

        assertEquals("page", page.getString("scope"))
        assertEquals("page-a", page.getString("pageId"))
        assertEquals("Page A", page.getString("pageName"))
        assertEquals(2L, page.getLong("scopeRevision"))
        assertFalse(page.has("revision"))
        assertEquals(listOf("panel", "state"), page.getJSONArray("resources").getJSONObject(0).getJSONArray("path").toList())
        assertEquals(listOf("panel", "refresh"), page.getJSONArray("commands").getJSONObject(0).getJSONArray("path").toList())
    }

    @Test
    fun helloMultiPageScopeFixtureKeepsSameIdDistinctPageIdsAndPathArrays() {
        val fixture = loadFixtureJson("hello-multi-page-scope.json")
        val pages = fixture.getJSONArray("registeredCapabilities")
            .objects()
            .filter { it.optString("id") == "sample.page.form" && it.optString("scope") == "page" }

        assertEquals(2, pages.size)
        assertEquals(listOf("page-a", "page-b"), pages.map { it.getString("pageId") }.sorted())
        assertEquals(listOf("Page A", "Page B"), pages.map { it.getString("pageName") }.sorted())
        pages.forEach { page ->
            assertEquals("sample.page.form", page.getString("id"))
            assertEquals(4L, page.getLong("scopeRevision"))
            assertFalse(page.has("revision"))
            assertEquals(listOf("form", "state"), page.getJSONArray("resources").getJSONObject(0).getJSONArray("path").toList())
            assertEquals(listOf("form", "submit"), page.getJSONArray("commands").getJSONObject(0).getJSONArray("path").toList())
        }
    }

    @Test
    fun scopeTypeMapsFromWireValues() {
        assertEquals(CapabilityScopeType.APP, CapabilityScopeType.fromWire("app"))
        assertEquals(CapabilityScopeType.PAGE, CapabilityScopeType.fromWire("page"))
    }

    private fun loadFixtureJson(name: String): JSONObject =
        JSONObject(fixturesDir.resolve(name).readText(Charsets.UTF_8))

    private fun JSONArray.findObject(key: String, value: String): JSONObject =
        objects().firstOrNull { it.optString(key) == value }
            ?: throw AssertionError("missing object with $key=$value")

    private fun JSONArray.objects(): List<JSONObject> =
        (0 until length()).map { getJSONObject(it) }
}
