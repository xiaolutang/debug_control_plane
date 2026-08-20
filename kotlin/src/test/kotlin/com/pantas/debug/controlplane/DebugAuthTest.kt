package com.pantas.debug.controlplane

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class DebugAuthTest {
    private val now: Instant = Instant.parse("2026-08-20T10:00:00Z")

    @Test
    fun classifyRouteMarksHelloBootstrapOnlyForGetHello() {
        assertEquals(
            DebugAuthRouteClass.HELLO_BOOTSTRAP,
            DebugAuth.classifyRoute("GET", listOf("hello")),
        )
        assertEquals(
            DebugAuthRouteClass.SENSITIVE,
            DebugAuth.classifyRoute("POST", listOf("hello")),
        )
    }

    @Test
    fun classifyRouteMarksAuthBootstrapPostEndpoints() {
        for (action in listOf("request", "status", "claim")) {
            assertEquals(
                DebugAuthRouteClass.AUTH_BOOTSTRAP,
                DebugAuth.classifyRoute("POST", listOf("auth", action)),
            )
        }
        assertEquals(
            DebugAuthRouteClass.SENSITIVE,
            DebugAuth.classifyRoute("GET", listOf("auth", "request")),
        )
    }

    @Test
    fun classifyRouteDefaultsStateEventsAndCapabilitiesToSensitive() {
        assertEquals(DebugAuthRouteClass.SENSITIVE, DebugAuth.classifyRoute("GET", listOf("state")))
        assertEquals(DebugAuthRouteClass.SENSITIVE, DebugAuth.classifyRoute("GET", listOf("events")))
        assertEquals(DebugAuthRouteClass.SENSITIVE, DebugAuth.classifyRoute("GET", listOf("items", "1")))
        assertEquals(DebugAuthRouteClass.SENSITIVE, DebugAuth.classifyRoute("POST", listOf("invoke")))
        assertEquals(DebugAuthRouteClass.SENSITIVE, DebugAuth.classifyRoute("GET", listOf("unknown")))
    }

    @Test
    fun bearerTokenParsesCaseInsensitiveAuthorizationHeaderKey() {
        assertEquals(
            "test-token-not-real",
            DebugAuth.bearerToken(mapOf("authorization" to "Bearer test-token-not-real")),
        )
    }

    @Test
    fun bearerTokenRejectsMissingNonBearerEmptyAndMalformedValues() {
        assertNull(DebugAuth.bearerToken(emptyMap()))
        assertNull(DebugAuth.bearerToken("Basic abc"))
        assertNull(DebugAuth.bearerToken("Bearer "))
        assertNull(DebugAuth.bearerToken("Bearer   "))
        assertNull(DebugAuth.bearerToken("Bearer token extra"))
        assertNull(DebugAuth.bearerToken("bearer token"))
        assertNull(DebugAuth.bearerToken("token"))
    }

    @Test
    fun noOpManagerKeepsBareDebugPlaneAuthorized() = runTest {
        val decision = NoOpDebugAuthManager.authorize(
            DebugAuthRequest("GET", listOf("state"), bearerToken = null),
        )
        assertEquals(DebugAuthDecision.Authorized, decision)

        val helloState = NoOpDebugAuthManager.helloAuthState(null)
        assertEquals(false, helloState["authRequired"])
        assertEquals("disabled", helloState["authStatus"])
        assertFalse(helloState.containsKey("token"))
    }

    @Test
    fun tokenHashIsStableAndDoesNotExposePlaintext() {
        val hash = DebugAuth.tokenHash("test-token-plain")
        assertEquals(
            "be8217fb4cf1427bb9b3d9751a5fc2ff27bfec775e3e65d5559f0aa7ce10fde5",
            hash,
        )
        assertFalse(hash.contains("test-token-plain"))
    }

    @Test
    fun validateTokenAuthorizesMatchingHashBeforeExpiry() {
        val decision = DebugAuth.validateToken(
            token = "test-token-plain",
            record = record(expiresAt = now.plusSeconds(60)),
            now = now,
        )
        assertEquals(DebugAuthDecision.Authorized, decision)
    }

    @Test
    fun validateTokenRequiresMissingToken() {
        val decision = DebugAuth.validateToken(
            token = null,
            record = record(expiresAt = now.plusSeconds(60)),
            now = now,
        )
        assertDenied(decision, 401, "authorization_required")
    }

    @Test
    fun validateTokenRejectsUnknownOrMismatchedToken() {
        assertDenied(
            DebugAuth.validateToken("test-token-plain", null, now),
            401,
            "invalid_token",
        )
        assertDenied(
            DebugAuth.validateToken("wrong-token", record(expiresAt = now.plusSeconds(60)), now),
            401,
            "invalid_token",
        )
    }

    @Test
    fun validateTokenRejectsExpiredAndRevokedRecords() {
        assertDenied(
            DebugAuth.validateToken(
                "test-token-plain",
                record(expiresAt = now),
                now,
            ),
            401,
            "token_expired",
        )
        assertDenied(
            DebugAuth.validateToken(
                "test-token-plain",
                record(expiresAt = now.plusSeconds(60), revokedAt = now.minusSeconds(1)),
                now,
            ),
            401,
            "token_revoked",
        )
    }

    private fun record(
        expiresAt: Instant,
        revokedAt: Instant? = null,
    ): DebugAuthTokenRecord =
        DebugAuthTokenRecord(
            tokenId = "test-token-id-not-real",
            tokenHash = DebugAuth.tokenHash("test-token-plain"),
            createdAt = now.minusSeconds(60),
            expiresAt = expiresAt,
            revokedAt = revokedAt,
            clientLabel = "test-client",
        )

    private fun assertDenied(
        decision: DebugAuthDecision,
        statusCode: Int,
        code: String,
    ) {
        assertTrue(decision is DebugAuthDecision.Denied)
        val denied = decision as DebugAuthDecision.Denied
        assertEquals(statusCode, denied.statusCode)
        assertEquals(code, denied.code)
        assertTrue(denied.message.isNotBlank())
    }
}
