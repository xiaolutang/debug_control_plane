package com.pantas.debug.controlplane

import java.security.MessageDigest
import java.time.Instant

/** Route auth class used by the debug-plane auth gate. */
enum class DebugAuthRouteClass {
    HELLO_BOOTSTRAP,
    AUTH_BOOTSTRAP,
    SENSITIVE,
}

/** Request facts needed by a pure JVM [DebugAuthManager]. */
data class DebugAuthRequest(
    val method: String,
    val segments: List<String>,
    val routeClass: DebugAuthRouteClass = DebugAuth.classifyRoute(method, segments),
    val bearerToken: String? = null,
    val body: Map<String, Any?> = emptyMap(),
    val request: Any? = null,
)

/** Token metadata stored by the App side. Plaintext tokens must not be stored here. */
data class DebugAuthTokenRecord(
    val tokenId: String,
    val tokenHash: String,
    val createdAt: Instant,
    val expiresAt: Instant,
    val revokedAt: Instant? = null,
    val clientLabel: String? = null,
)

/** Authorization decision shared by future route and SSE gates. */
sealed class DebugAuthDecision {
    data object Authorized : DebugAuthDecision()

    data class Denied(
        val statusCode: Int,
        val code: String,
        val message: String,
    ) : DebugAuthDecision()
}

/** Pluggable App-side authorizer. */
interface DebugAuthManager {
    suspend fun authorize(request: DebugAuthRequest): DebugAuthDecision

    suspend fun helloAuthState(token: String?): Map<String, Any?>
}

/** Compatibility manager used when the host has not enabled debug auth. */
object NoOpDebugAuthManager : DebugAuthManager {
    override suspend fun authorize(request: DebugAuthRequest): DebugAuthDecision =
        DebugAuthDecision.Authorized

    override suspend fun helloAuthState(token: String?): Map<String, Any?> =
        mapOf(
            "authRequired" to false,
            "authStatus" to "disabled",
        )
}

/** Pure helpers for auth route classification, Bearer parsing, and token validation. */
object DebugAuth {
    fun classifyRoute(method: String, segments: List<String>): DebugAuthRouteClass {
        val normalizedMethod = method.uppercase()
        return when {
            normalizedMethod == "GET" && segments == listOf("hello") ->
                DebugAuthRouteClass.HELLO_BOOTSTRAP

            normalizedMethod == "POST" &&
                segments.size == 2 &&
                segments[0] == "auth" &&
                segments[1] in AUTH_BOOTSTRAP_ACTIONS ->
                DebugAuthRouteClass.AUTH_BOOTSTRAP

            else -> DebugAuthRouteClass.SENSITIVE
        }
    }

    fun bearerToken(headers: Map<String, String>): String? {
        val value = headers.entries.firstOrNull { (key, _) ->
            key.equals("Authorization", ignoreCase = true)
        }?.value
        return bearerToken(value)
    }

    fun bearerToken(headerValue: String?): String? {
        if (headerValue == null) return null
        if (!headerValue.startsWith("Bearer ")) return null
        val token = headerValue.removePrefix("Bearer ")
        if (token.isBlank()) return null
        if (token.any { it.isWhitespace() }) return null
        return token
    }

    fun tokenHash(token: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(token.toByteArray(Charsets.UTF_8))
        return digest.joinToString(separator = "") { byte -> "%02x".format(byte) }
    }

    fun validateToken(
        token: String?,
        record: DebugAuthTokenRecord?,
        now: Instant,
    ): DebugAuthDecision {
        if (token.isNullOrBlank()) return authorizationRequired()
        if (record == null) return invalidToken()
        if (record.revokedAt != null) return tokenRevoked()
        if (!now.isBefore(record.expiresAt)) return tokenExpired()
        if (tokenHash(token) != record.tokenHash) return invalidToken()
        return DebugAuthDecision.Authorized
    }

    fun authorizationRequired(): DebugAuthDecision.Denied =
        DebugAuthDecision.Denied(401, "authorization_required", "Debug authorization is required.")

    fun invalidToken(): DebugAuthDecision.Denied =
        DebugAuthDecision.Denied(401, "invalid_token", "Debug authorization token is invalid.")

    fun tokenExpired(): DebugAuthDecision.Denied =
        DebugAuthDecision.Denied(401, "token_expired", "Debug authorization token expired.")

    fun tokenRevoked(): DebugAuthDecision.Denied =
        DebugAuthDecision.Denied(401, "token_revoked", "Debug authorization token was revoked.")

    private val AUTH_BOOTSTRAP_ACTIONS = setOf("request", "status", "claim")
}
