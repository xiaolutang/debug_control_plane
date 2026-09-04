package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.DebugAuthDecision
import com.pantas.debug.controlplane.DebugAuthRequest
import com.pantas.debug.controlplane.DebugAuthRouteResult
import com.pantas.debug.controlplane.RouteRequest
import com.pantas.debug.controlplane.RouteResult
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * R006-BF001: authPolicy channel plumbing + three-policy assembly +
 * fail-fast + autoApprove behavior (test design K1-K8).
 *
 * K1/K2: absent / explicit `default` — fallback plane mounts with the
 *        attach-time auth manager (hello carries authRequired).
 * K3:    `auto` — the mounted plane's auth manager approves instantly.
 * K4:    `none` — the mounted plane has no auth gate (hello has no
 *        authRequired field; a tokenless sensitive route passes).
 * K5:    bogus value — invalid_arguments error, plane NOT mounted.
 * K6:    autoApprove=true manager — 202 with status=approved, token record in
 *        store, host notification still emitted (D4).
 * K7:    autoApprove=false control group — 202 with status=pending.
 * K8:    auto — claim returns the token; the token authorizes.
 */
class PluginAuthPolicyTest {

    private lateinit var plugin: DebugControlPlaneFlutterPlugin
    private lateinit var channel: FakeMethodChannel
    private lateinit var authStore: InMemoryPluginDebugAuthStore
    private lateinit var bridge: NativeControlPlaneBridge

    @Before
    fun setUp() {
        plugin = DebugControlPlaneFlutterPlugin()
        channel = FakeMethodChannel()
        bridge = NativeControlPlaneBridge(channel, FakeMethodChannel.scope)
        authStore = InMemoryPluginDebugAuthStore()
        // Reflection wiring, same pattern as DebugControlPlaneFlutterPluginTest
        // (no Flutter engine on the JVM).
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("channel").apply {
            isAccessible = true; set(plugin, channel)
        }
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("scope").apply {
            isAccessible = true; set(plugin, FakeMethodChannel.scope)
        }
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("bridge").apply {
            isAccessible = true; set(plugin, bridge)
        }
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("authStore").apply {
            isAccessible = true; set(plugin, authStore)
        }
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("authManager").apply {
            isAccessible = true; set(plugin, PluginDebugAuthManager(bridge, authStore))
        }
        DebugControlPlaneFlutterPlugin::class.java.getDeclaredField("registry").apply {
            isAccessible = true; set(plugin, DartCapabilityRegistry(bridge))
        }
    }

    @After
    fun tearDown() {
        PlaneCarrier.unmount()
    }

    private suspend fun planeStart(args: Map<String, Any?>): RecordingResult {
        val result = RecordingResult()
        plugin.onMethodCall(
            methodCall(
                ChannelProtocol.PLANE_START,
                mapOf("address" to "0.0.0.0", "port" to 0) + args,
            ),
            result,
        )
        kotlinx.coroutines.withTimeout(2000) {
            while (!result.done) delay(10)
        }
        return result
    }

    private suspend fun hello(): Map<String, Any?> {
        val res = PlaneCarrier.plane!!.dispatch(
            RouteRequest(method = "GET", segments = listOf("hello")),
        ) as RouteResult.Ok
        return res.body
    }

    // ---- K1 / K2: default policy assembly -----------------------------------

    @Test
    fun `K1 absent authPolicy mounts fallback plane with default auth`() = runBlocking {
        val result = planeStart(emptyMap())

        assertNull(result.errorCode)
        assertNotNull("plane must be mounted", PlaneCarrier.plane)
        val body = hello()
        assertEquals(true, body["authRequired"])
        assertEquals("authorization_required", body["authStatus"])
    }

    @Test
    fun `K2 explicit default policy is identical to absent`() = runBlocking {
        val result = planeStart(mapOf(ChannelProtocol.AUTH_POLICY to ChannelProtocol.AUTH_POLICY_DEFAULT))

        assertNull(result.errorCode)
        assertNotNull(PlaneCarrier.plane)
        val body = hello()
        assertEquals(true, body["authRequired"])
    }

    // ---- K3: auto policy ------------------------------------------------------

    @Test
    fun `K3 auto policy assembles an autoApprove manager on the mounted plane`() = runBlocking {
        val result = planeStart(mapOf(ChannelProtocol.AUTH_POLICY to ChannelProtocol.AUTH_POLICY_AUTO))

        assertNull(result.errorCode)
        assertNotNull(PlaneCarrier.plane)

        val auth = PlaneCarrier.plane!!.dispatch(
            RouteRequest(
                method = "POST",
                segments = listOf("auth", "request"),
                body = mapOf("clientNonce" to "k3-nonce", "clientLabel" to "devtool"),
            ),
        ) as RouteResult.Ok
        assertEquals("auto must approve instantly", "approved", auth.body["status"])
        // D4: the host audit notification is still emitted.
        assertEquals(ChannelProtocol.AUTH_REQUEST, channel.invokes.single().method)
    }

    // ---- K4: none policy ------------------------------------------------------

    @Test
    fun `K4 none policy mounts plane without an auth gate`() = runBlocking {
        val result = planeStart(mapOf(ChannelProtocol.AUTH_POLICY to ChannelProtocol.AUTH_POLICY_NONE))

        assertNull(result.errorCode)
        assertNotNull(PlaneCarrier.plane)
        // No gate: /hello carries NO authRequired field (core null-authz semantics).
        val body = hello()
        assertFalse("none must drop authRequired", body.containsKey("authRequired"))
    }

    // ---- K5: fail-fast on bogus values ---------------------------------------

    @Test
    fun `K5 bogus authPolicy replies invalid_arguments and mounts nothing`() = runBlocking {
        val result = planeStart(mapOf(ChannelProtocol.AUTH_POLICY to "bogus"))

        assertEquals(ChannelProtocol.ERROR_INVALID_ARGUMENTS, result.errorCode)
        assertTrue(result.errorMessage!!.contains("bogus"))
        assertNull("plane must NOT be mounted on an invalid policy", PlaneCarrier.plane)
    }

    // ---- K6 / K7 / K8: PluginDebugAuthManager autoApprove behavior -----------

    @Test
    fun `K6 autoApprove true returns approved stores token and still notifies host`() = runBlocking {
        val manager = PluginDebugAuthManager(bridge, authStore, autoApprove = true)

        val res = manager.requestAuthorization(
            mapOf("clientNonce" to "k6-nonce", "clientLabel" to "devtool"),
        ) as DebugAuthRouteResult.Ok

        assertEquals(202, res.statusCode)
        assertEquals("approved", res.body["status"])
        val requestId = res.body["requestId"] as String
        // Token record already issued into the store.
        val pending = authStore.pending(requestId)!!
        assertEquals("approved", pending.status)
        assertNotNull(pending.tokenId)
        assertNotNull("token record must be in the store", authStore.token(pending.tokenId!!))
        // D4: audit notification still emitted to the host.
        assertEquals(ChannelProtocol.AUTH_REQUEST, channel.invokes.single().method)

        // Idempotent nonce replay: a second identical request returns the
        // already-approved pending without throwing.
        val replay = manager.requestAuthorization(
            mapOf("clientNonce" to "k6-nonce", "clientLabel" to "devtool"),
        ) as DebugAuthRouteResult.Ok
        assertEquals("approved", replay.body["status"])
        assertEquals(requestId, replay.body["requestId"])
    }

    @Test
    fun `K7 autoApprove false control group keeps pending`() = runBlocking {
        val manager = PluginDebugAuthManager(bridge, authStore, autoApprove = false)

        val res = manager.requestAuthorization(mapOf("clientNonce" to "k7-nonce"))
            as DebugAuthRouteResult.Ok

        assertEquals(202, res.statusCode)
        assertEquals("pending", res.body["status"])
        assertEquals(ChannelProtocol.AUTH_REQUEST, channel.invokes.single().method)
    }

    @Test
    fun `K8 auto request then claim yields a working bearer token`() = runBlocking {
        val manager = PluginDebugAuthManager(bridge, authStore, autoApprove = true)

        val request = manager.requestAuthorization(
            mapOf("clientNonce" to "k8-nonce", "clientLabel" to "devtool"),
        ) as DebugAuthRouteResult.Ok
        val requestId = request.body["requestId"] as String

        val claim = manager.claimAuthorization(
            mapOf("requestId" to requestId, "clientNonce" to "k8-nonce"),
        ) as DebugAuthRouteResult.Ok
        val token = claim.body["token"] as String
        assertEquals("authorized", claim.body["status"])

        val decision = manager.authorize(DebugAuthRequest("GET", listOf("state"), bearerToken = token))
        assertTrue("auto-claimed token must authorize", decision is DebugAuthDecision.Authorized)
    }
}
