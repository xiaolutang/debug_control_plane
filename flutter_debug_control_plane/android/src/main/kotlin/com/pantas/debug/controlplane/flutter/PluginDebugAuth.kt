package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.DebugAuth
import com.pantas.debug.controlplane.DebugAuthDecision
import com.pantas.debug.controlplane.DebugAuthManager
import com.pantas.debug.controlplane.DebugAuthRequest
import com.pantas.debug.controlplane.DebugAuthRouteResult
import com.pantas.debug.controlplane.DebugAuthTokenRecord
import java.security.SecureRandom
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File

interface PluginDebugAuthStore {
    fun pending(requestId: String): PluginDebugAuthPending?
    fun pendingByNonceHash(nonceHash: String): PluginDebugAuthPending?
    fun putPending(pending: PluginDebugAuthPending)
    fun token(tokenId: String): DebugAuthTokenRecord?
    fun tokenByHash(tokenHash: String): DebugAuthTokenRecord?
    fun putToken(record: DebugAuthTokenRecord)
    fun markRevoked(tokenId: String, revokedAt: Instant)
    fun markAllRevoked(revokedAt: Instant)
}

data class PluginDebugAuthPending(
    val requestId: String,
    val clientNonceHash: String,
    val clientLabel: String?,
    val requestedMethod: String?,
    val requestedPath: String?,
    val pairingCode: String,
    val createdAt: Instant,
    val expiresAt: Instant,
    val status: String = "pending",
    val tokenId: String? = null,
    val tokenPlaintext: String? = null,
    val claimedAt: Instant? = null,
    val deniedReason: String? = null,
)

class InMemoryPluginDebugAuthStore : PluginDebugAuthStore {
    private val pending = ConcurrentHashMap<String, PluginDebugAuthPending>()
    private val tokens = ConcurrentHashMap<String, DebugAuthTokenRecord>()

    /** R004-FF001: full token-set snapshot for persistence/migration consumers. */
    fun snapshotTokens(): List<DebugAuthTokenRecord> = tokens.values.toList()

    override fun pending(requestId: String): PluginDebugAuthPending? = pending[requestId]

    override fun pendingByNonceHash(nonceHash: String): PluginDebugAuthPending? =
        pending.values.firstOrNull { it.clientNonceHash == nonceHash }

    override fun putPending(pending: PluginDebugAuthPending) {
        this.pending[pending.requestId] = pending
    }

    override fun token(tokenId: String): DebugAuthTokenRecord? = tokens[tokenId]

    override fun tokenByHash(tokenHash: String): DebugAuthTokenRecord? =
        tokens.values.firstOrNull { it.tokenHash == tokenHash }

    override fun putToken(record: DebugAuthTokenRecord) {
        tokens[record.tokenId] = record
    }

    override fun markRevoked(tokenId: String, revokedAt: Instant) {
        val record = tokens[tokenId] ?: return
        tokens[tokenId] = record.copy(revokedAt = revokedAt)
    }

    override fun markAllRevoked(revokedAt: Instant) {
        tokens.keys.forEach { markRevoked(it, revokedAt) }
    }
}

/**
 * R004-FF001: persistent decorator over [PluginDebugAuthStore] (design §3.1).
 *
 * The wrapped [delegate] (an [InMemoryPluginDebugAuthStore] working set) keeps
 * authoritative in-memory state; token-group writes (putToken/markRevoked/
 * markAllRevoked) are mirrored to a JSON file in the app-private directory via
 * tmp+rename atomic replace.
 *
 * Red line (design §6): pending records (which carry tokenPlaintext and the
 * pairingCode) are NEVER persisted — pending-group methods are pure
 * pass-through and the persistence data source is only the token map (hash
 * records; the plaintext token itself is never known to this store).
 *
 * Persistence is fail-soft: a corrupt/unreadable file logs a warning and falls
 * back to empty (the attach path must never throw); an IO failure during
 * persist logs a warning and leaves memory untouched (self-heals on the next
 * write).
 *
 * Primary constructor takes a [dir] so pure-JVM unit tests can use a temp
 * directory; the [context] factory variant resolves `context.filesDir`.
 */
class FileBackedPluginDebugAuthStore internal constructor(
    private val dir: File,
    private val delegate: InMemoryPluginDebugAuthStore = InMemoryPluginDebugAuthStore(),
    private val now: () -> Instant = Instant::now,
    private val logger: (String) -> Unit = { android.util.Log.w("FileBackedPluginDebugAuthStore", it) },
) : PluginDebugAuthStore {

    constructor(
        context: android.content.Context,
        delegate: InMemoryPluginDebugAuthStore = InMemoryPluginDebugAuthStore(),
    ) : this(File(context.filesDir, STORE_DIR_NAME), delegate)

    private val persistLock = Any()
    private val file: File get() = File(dir, FILE_NAME)
    private val tmpFile: File get() = File(dir, TMP_NAME)

    init {
        try {
            dir.mkdirs()
        } catch (e: Exception) {
            logger("failed to create store dir ${dir.path}: $e")
        }
        load()
    }

    // --- pending group: pure pass-through, never persisted (red line) ---

    override fun pending(requestId: String): PluginDebugAuthPending? = delegate.pending(requestId)

    override fun pendingByNonceHash(nonceHash: String): PluginDebugAuthPending? =
        delegate.pendingByNonceHash(nonceHash)

    override fun putPending(pending: PluginDebugAuthPending) {
        delegate.putPending(pending)
    }

    // --- token group: reads pass through, writes persist ---

    override fun token(tokenId: String): DebugAuthTokenRecord? = delegate.token(tokenId)

    override fun tokenByHash(tokenHash: String): DebugAuthTokenRecord? = delegate.tokenByHash(tokenHash)

    override fun putToken(record: DebugAuthTokenRecord) {
        synchronized(persistLock) {
            delegate.putToken(record)
            persistLocked()
        }
    }

    override fun markRevoked(tokenId: String, revokedAt: Instant) {
        synchronized(persistLock) {
            delegate.markRevoked(tokenId, revokedAt)
            persistLocked()
        }
    }

    override fun markAllRevoked(revokedAt: Instant) {
        synchronized(persistLock) {
            delegate.markAllRevoked(revokedAt)
            persistLocked()
        }
    }

    /**
     * R004-FF001 attach wiring helper: flush the current in-memory token set
     * to disk (the attach wiring re-uses the pre-upgrade InMemory working set
     * as this store's [delegate], so its records are already here — the
     * "migration" is a zero-copy delegate handoff, not a record copy). Pending
     * records never reach disk (red line).
     */
    fun persistNow() {
        synchronized(persistLock) {
            persistLocked()
        }
    }

    // --- persistence internals ---

    private fun load() {
        val records = try {
            val raw = file.readText()
            if (raw.isBlank()) {
                emptyList()
            } else {
                parseTokens(raw)
            }
        } catch (e: Exception) {
            logger("failed to load ${file.path}, falling back to empty store: $e")
            emptyList()
        }
        val currentTime = now()
        val expired = mutableListOf<DebugAuthTokenRecord>()
        records.forEach { record ->
            if (record.expiresAt.isBefore(currentTime)) {
                expired += record
            } else {
                delegate.putToken(record)
            }
        }
        if (expired.isNotEmpty()) {
            logger("dropping ${expired.size} expired token record(s)")
            persistLocked()
        }
    }

    /** Must be called under [persistLock]. Re-collects the snapshot inside the critical section. */
    private fun persistLocked() {
        try {
            val snapshot = delegate.snapshotTokens()
            tmpFile.writeText(encodeTokens(snapshot))
            if (!tmpFile.renameTo(file)) {
                logger("atomic rename failed: ${tmpFile.path} -> ${file.path}")
            }
        } catch (e: Exception) {
            logger("failed to persist ${file.path}, memory state kept: $e")
        }
    }

    companion object {
        private const val STORE_DIR_NAME = "debug_control_plane"
        private const val FILE_NAME = "debug_auth_tokens.json"
        private const val TMP_NAME = "debug_auth_tokens.json.tmp"

        /** Must be called under [persistLock]-free init only (single load). */
        internal fun parseTokens(raw: String): List<DebugAuthTokenRecord> {
            val json = JSONObject(raw)
            val version = json.optInt("version", -1)
            if (version != 1) {
                throw JSONException("unsupported version: $version")
            }
            val tokens = json.optJSONArray("tokens") ?: return emptyList()
            return (0 until tokens.length()).map { index ->
                val entry = tokens.getJSONObject(index)
                DebugAuthTokenRecord(
                    tokenId = entry.getString("tokenId"),
                    tokenHash = entry.getString("tokenHash"),
                    createdAt = Instant.parse(entry.getString("createdAt")),
                    expiresAt = Instant.parse(entry.getString("expiresAt")),
                    revokedAt = if (entry.has("revokedAt") && !entry.isNull("revokedAt")) {
                        Instant.parse(entry.getString("revokedAt"))
                    } else {
                        null
                    },
                    clientLabel = if (entry.has("clientLabel") && !entry.isNull("clientLabel")) {
                        entry.getString("clientLabel")
                    } else {
                        null
                    },
                )
            }
        }

        internal fun encodeTokens(records: List<DebugAuthTokenRecord>): String {
            val tokens = JSONArray()
            records.forEach { record ->
                val entry = JSONObject()
                entry.put("tokenId", record.tokenId)
                entry.put("tokenHash", record.tokenHash)
                entry.put("createdAt", record.createdAt.toString())
                entry.put("expiresAt", record.expiresAt.toString())
                entry.put("revokedAt", record.revokedAt ?: JSONObject.NULL)
                entry.put("clientLabel", record.clientLabel ?: JSONObject.NULL)
                tokens.put(entry)
            }
            val root = JSONObject()
            root.put("version", 1)
            root.put("tokens", tokens)
            return root.toString()
        }
    }
}

class PluginDebugAuthManager(
    private val bridge: NativeControlPlaneBridge,
    private val store: PluginDebugAuthStore,
    private val now: () -> Instant = { Instant.now() },
    private val random: SecureRandom = SecureRandom(),
    private val defaultPendingTtlSeconds: Long = 300,
    private val defaultTokenTtlSeconds: Long = 3600,
) : DebugAuthManager {

    override suspend fun authorize(request: DebugAuthRequest): DebugAuthDecision {
        val token = request.bearerToken
        val record = token?.let { store.tokenByHash(DebugAuth.tokenHash(it)) }
        return DebugAuth.validateToken(token, record, now())
    }

    override suspend fun helloAuthState(token: String?): Map<String, Any?> {
        val record = token?.let { store.tokenByHash(DebugAuth.tokenHash(it)) }
        val decision = DebugAuth.validateToken(token, record, now())
        return when (decision) {
            DebugAuthDecision.Authorized -> mapOf(
                "authRequired" to true,
                "authStatus" to "authorized",
                "tokenId" to record?.tokenId,
                "expiresAt" to record?.expiresAt?.toString(),
                "clientLabel" to record?.clientLabel,
            )

            is DebugAuthDecision.Denied -> mapOf(
                "authRequired" to true,
                "authStatus" to decision.code,
                "authEndpoints" to mapOf(
                    "request" to "/auth/request",
                    "status" to "/auth/status",
                    "claim" to "/auth/claim",
                ),
            )
        }
    }

    override suspend fun requestAuthorization(body: Map<String, Any?>): DebugAuthRouteResult {
        val nonce = body["clientNonce"] as? String
            ?: return invalid("missing clientNonce")
        val nonceHash = DebugAuth.tokenHash(nonce)
        val currentTime = now()
        val existing = store.pendingByNonceHash(nonceHash)
        val pending = if (existing != null && currentTime.isBefore(existing.expiresAt)) {
            existing
        } else {
            PluginDebugAuthPending(
                requestId = "auth-${UUID.randomUUID()}",
                clientNonceHash = nonceHash,
                clientLabel = body["clientLabel"] as? String,
                requestedMethod = body["requestedMethod"] as? String,
                requestedPath = body["requestedPath"] as? String,
                pairingCode = pairingCode(),
                createdAt = currentTime,
                expiresAt = currentTime.plusSeconds(defaultPendingTtlSeconds),
            ).also(store::putPending)
        }
        bridge.requestAuthorization(pending.toWireStatus())
        return DebugAuthRouteResult.Ok(pending.toRouteStatus(), statusCode = 202)
    }

    override suspend fun authorizationStatus(body: Map<String, Any?>): DebugAuthRouteResult {
        val pending = matchingPending(body) ?: return invalid("unknown requestId")
        val status = effectiveStatus(pending)
        return DebugAuthRouteResult.Ok(pending.copy(status = status).toRouteStatus())
    }

    override suspend fun claimAuthorization(body: Map<String, Any?>): DebugAuthRouteResult {
        val pending = matchingPending(body) ?: return invalid("unknown requestId")
        val currentTime = now()
        if (!currentTime.isBefore(pending.expiresAt)) return denied(401, "token_expired", "Debug authorization token expired.")
        if (pending.status == "denied") return denied(403, "authorization_denied", pending.deniedReason ?: "Debug authorization was denied.")
        if (pending.status != "approved") return denied(401, "authorization_required", "Debug authorization is pending.")
        if (pending.claimedAt != null || pending.tokenPlaintext == null || pending.tokenId == null) {
            return denied(401, "invalid_token", "Debug authorization claim is no longer available.")
        }
        store.putPending(pending.copy(claimedAt = currentTime, tokenPlaintext = null))
        val tokenRecord = store.token(pending.tokenId)
        return DebugAuthRouteResult.Ok(
            mapOf(
                "token" to pending.tokenPlaintext,
                "tokenId" to pending.tokenId,
                "expiresAt" to (tokenRecord?.expiresAt ?: currentTime).toString(),
                "status" to "authorized",
            ),
        )
    }

    fun approve(requestId: String, ttlSeconds: Int?, clientLabel: String?): Map<String, Any?> {
        val current = store.pending(requestId) ?: throw IllegalArgumentException("unknown requestId")
        if (current.status != "pending") throw IllegalArgumentException("request is not pending")
        val currentTime = now()
        val token = "dcp_${randomTokenPart(32)}"
        val tokenId = "tok-${UUID.randomUUID()}"
        val tokenTtlSeconds = ttlSeconds?.toLong() ?: defaultTokenTtlSeconds
        val expiresAt = currentTime.plusSeconds(tokenTtlSeconds.coerceAtLeast(1L))
        val label = clientLabel ?: current.clientLabel
        store.putToken(
            DebugAuthTokenRecord(
                tokenId = tokenId,
                tokenHash = DebugAuth.tokenHash(token),
                createdAt = currentTime,
                expiresAt = expiresAt,
                clientLabel = label,
            ),
        )
        store.putPending(
            current.copy(
                status = "approved",
                tokenId = tokenId,
                tokenPlaintext = token,
                expiresAt = expiresAt,
                clientLabel = label,
            ),
        )
        return mapOf(
            "token" to token,
            "tokenId" to tokenId,
            "expiresAt" to expiresAt.toString(),
            "status" to "authorized",
        )
    }

    fun deny(requestId: String, reason: String?) {
        val current = store.pending(requestId) ?: throw IllegalArgumentException("unknown requestId")
        store.putPending(current.copy(status = "denied", deniedReason = reason))
    }

    fun revoke(tokenId: String?, all: Boolean) {
        if (tokenId == null && !all) throw IllegalArgumentException("missing tokenId or all=true")
        val currentTime = now()
        if (all) {
            store.markAllRevoked(currentTime)
        } else {
            store.markRevoked(tokenId!!, currentTime)
        }
    }

    fun status(requestId: String?): Map<String, Any?> {
        val pending = requestId?.let(store::pending)
        return if (pending == null) {
            mapOf("status" to "unknown")
        } else {
            pending.copy(status = effectiveStatus(pending)).toRouteStatus()
        }
    }

    private fun matchingPending(body: Map<String, Any?>): PluginDebugAuthPending? {
        val requestId = body["requestId"] as? String ?: return null
        val clientNonce = body["clientNonce"] as? String ?: return null
        val pending = store.pending(requestId) ?: return null
        return pending.takeIf { it.clientNonceHash == DebugAuth.tokenHash(clientNonce) }
    }

    private fun effectiveStatus(pending: PluginDebugAuthPending): String =
        if (pending.status == "pending" && !now().isBefore(pending.expiresAt)) {
            "expired"
        } else {
            pending.status
        }

    private fun PluginDebugAuthPending.toWireStatus(): Map<String, Any?> = toRouteStatus() +
        mapOf(
            "method" to requestedMethod,
            "endpoint" to requestedPath,
        ).filterValues { it != null }

    private fun PluginDebugAuthPending.toRouteStatus(): Map<String, Any?> =
        mapOf(
            "requestId" to requestId,
            "pairingCode" to pairingCode,
            "status" to status,
            "expiresAt" to expiresAt.toString(),
            "clientLabel" to clientLabel,
        ).filterValues { it != null }

    private fun pairingCode(): String = (100_000 + random.nextInt(900_000)).toString()

    private fun randomTokenPart(byteCount: Int): String {
        val bytes = ByteArray(byteCount)
        random.nextBytes(bytes)
        return bytes.joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun invalid(message: String): DebugAuthRouteResult.Denied =
        denied(401, "invalid_token", message)

    private fun denied(statusCode: Int, code: String, message: String): DebugAuthRouteResult.Denied =
        DebugAuthRouteResult.Denied(statusCode, code, message)
}
