package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.DebugAuth
import com.pantas.debug.controlplane.DebugAuthDecision
import com.pantas.debug.controlplane.DebugAuthRequest
import com.pantas.debug.controlplane.DebugAuthRouteResult
import kotlinx.coroutines.runBlocking
import java.time.Instant
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PluginDebugAuthManagerTest {

    @Test
    fun `request approve claim is one-time and stores hash only`() = runBlocking {
        val channel = FakeMethodChannel()
        val bridge = NativeControlPlaneBridge(channel, FakeMethodChannel.scope)
        val store = InMemoryPluginDebugAuthStore()
        val manager = PluginDebugAuthManager(bridge, store)

        val request = manager.requestAuthorization(
            mapOf(
                "clientNonce" to "nonce-1",
                "clientLabel" to "devtool",
                "requestedMethod" to "GET",
                "requestedPath" to "/state",
            ),
        ) as DebugAuthRouteResult.Ok
        val requestId = request.body["requestId"] as String
        assertEquals(202, request.statusCode)
        assertEquals(ChannelProtocol.AUTH_REQUEST, channel.invokes.single().method)
        assertEquals(0, bridge.pending.size)

        val approve = manager.approve(requestId, ttlSeconds = 60, clientLabel = "host")
        val token = approve["token"] as String
        val tokenId = approve["tokenId"] as String
        val stored = store.token(tokenId)
        assertNotNull(stored)
        assertEquals(DebugAuth.tokenHash(token), stored!!.tokenHash)
        assertFalse("plaintext token must not be persisted", stored.tokenHash.contains(token))

        val claim = manager.claimAuthorization(
            mapOf("requestId" to requestId, "clientNonce" to "nonce-1"),
        ) as DebugAuthRouteResult.Ok
        assertEquals(token, claim.body["token"])
        assertNull("plaintext token must be cleared after the one-time claim", store.pending(requestId)!!.tokenPlaintext)

        val repeat = manager.claimAuthorization(
            mapOf("requestId" to requestId, "clientNonce" to "nonce-1"),
        ) as DebugAuthRouteResult.Denied
        assertEquals("invalid_token", repeat.code)
    }

    @Test
    fun `claim rejects nonce mismatch and expired pending request`() = runBlocking {
        val currentTime = AtomicReference(Instant.parse("2026-08-24T08:00:00Z"))
        val manager = PluginDebugAuthManager(
            NativeControlPlaneBridge(FakeMethodChannel(), FakeMethodChannel.scope),
            InMemoryPluginDebugAuthStore(),
            now = { currentTime.get() },
            defaultPendingTtlSeconds = 1,
            defaultTokenTtlSeconds = 60,
        )
        val request = manager.requestAuthorization(mapOf("clientNonce" to "nonce-a")) as DebugAuthRouteResult.Ok
        val requestId = request.body["requestId"] as String
        manager.approve(requestId, ttlSeconds = 1, clientLabel = null)

        val mismatch = manager.claimAuthorization(
            mapOf("requestId" to requestId, "clientNonce" to "nonce-b"),
        ) as DebugAuthRouteResult.Denied
        assertEquals("invalid_token", mismatch.code)

        currentTime.set(Instant.parse("2026-08-24T08:00:02Z"))
        val expired = manager.claimAuthorization(
            mapOf("requestId" to requestId, "clientNonce" to "nonce-a"),
        ) as DebugAuthRouteResult.Denied
        assertEquals("token_expired", expired.code)
    }

    @Test
    fun `deny status and claim reflect authorization denied`() = runBlocking {
        val manager = PluginDebugAuthManager(
            NativeControlPlaneBridge(FakeMethodChannel(), FakeMethodChannel.scope),
            InMemoryPluginDebugAuthStore(),
        )
        val request = manager.requestAuthorization(mapOf("clientNonce" to "nonce-2")) as DebugAuthRouteResult.Ok
        val requestId = request.body["requestId"] as String

        manager.deny(requestId, "cancelled")
        val duplicateApprove = try {
            manager.approve(requestId, ttlSeconds = 60, clientLabel = null)
            null
        } catch (e: IllegalArgumentException) {
            e
        }
        assertNotNull(duplicateApprove)

        assertEquals("denied", manager.status(requestId)["status"])
        val claim = manager.claimAuthorization(
            mapOf("requestId" to requestId, "clientNonce" to "nonce-2"),
        ) as DebugAuthRouteResult.Denied
        assertEquals(403, claim.statusCode)
        assertEquals("authorization_denied", claim.code)
    }

    @Test
    fun `revoke rejects authorize and store survives manager recreation`() = runBlocking {
        val channel = FakeMethodChannel()
        val bridge = NativeControlPlaneBridge(channel, FakeMethodChannel.scope)
        val store = InMemoryPluginDebugAuthStore()
        val manager = PluginDebugAuthManager(bridge, store)
        val request = manager.requestAuthorization(mapOf("clientNonce" to "nonce-3")) as DebugAuthRouteResult.Ok
        val requestId = request.body["requestId"] as String
        val approve = manager.approve(requestId, ttlSeconds = 60, clientLabel = null)
        val token = approve["token"] as String
        val tokenId = approve["tokenId"] as String

        val recreated = PluginDebugAuthManager(bridge, store)
        assertEquals(
            DebugAuthDecision.Authorized,
            recreated.authorize(DebugAuthRequest("GET", listOf("state"), bearerToken = token)),
        )

        recreated.revoke(tokenId, all = false)
        val revoked = recreated.authorize(DebugAuthRequest("GET", listOf("state"), bearerToken = token))
            as DebugAuthDecision.Denied
        assertEquals("token_revoked", revoked.code)

        val second = manager.requestAuthorization(mapOf("clientNonce" to "nonce-4")) as DebugAuthRouteResult.Ok
        val secondId = second.body["requestId"] as String
        val secondApprove = recreated.approve(secondId, ttlSeconds = 60, clientLabel = null)
        recreated.revoke(tokenId = null, all = true)
        val allRevoked = recreated.authorize(
            DebugAuthRequest("GET", listOf("state"), bearerToken = secondApprove["token"] as String),
        ) as DebugAuthDecision.Denied
        assertEquals("token_revoked", allRevoked.code)
    }

    @Test
    fun `status does not expose token plaintext`() = runBlocking {
        val manager = PluginDebugAuthManager(
            NativeControlPlaneBridge(FakeMethodChannel(), FakeMethodChannel.scope),
            InMemoryPluginDebugAuthStore(),
        )
        val request = manager.requestAuthorization(mapOf("clientNonce" to "nonce-5")) as DebugAuthRouteResult.Ok
        val requestId = request.body["requestId"] as String
        manager.approve(requestId, ttlSeconds = 60, clientLabel = null)

        val status = manager.status(requestId)
        assertEquals("approved", status["status"])
        assertNull(status["token"])
    }
}
