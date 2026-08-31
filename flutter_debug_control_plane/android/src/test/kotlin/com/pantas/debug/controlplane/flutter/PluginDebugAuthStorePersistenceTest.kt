package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.DebugAuthTokenRecord
import java.io.File
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * R004-FF001: FileBackedPluginDebugAuthStore persistence unit tests (design
 * §3.1, test plan FF001-T). Pure JVM — the store is constructed over a
 * [TemporaryFolder] directory, no android.content.Context involved.
 */
class PluginDebugAuthStorePersistenceTest {

    @get:Rule
    val tempDir = TemporaryFolder()

    private fun newStore(
        dir: File = tempDir.newFolder("store"),
        now: () -> Instant = Instant::now,
    ) = FileBackedPluginDebugAuthStore(dir, InMemoryPluginDebugAuthStore(), now, logger = {})

    private fun tokenFile(dir: File) = File(dir, "debug_auth_tokens.json")

    private fun record(
        tokenId: String = "tok-1",
        now: Instant = Instant.parse("2026-08-31T10:00:00Z"),
        ttlSeconds: Long = 3600,
        revokedAt: Instant? = null,
        clientLabel: String? = "devtool",
        tokenHash: String = "hash-${tokenId}",
    ) = DebugAuthTokenRecord(
        tokenId = tokenId,
        tokenHash = tokenHash,
        createdAt = now,
        expiresAt = now.plusSeconds(ttlSeconds),
        revokedAt = revokedAt,
        clientLabel = clientLabel,
    )

    private fun pending(
        requestId: String = "auth-1",
        tokenPlaintext: String? = "dcp_secret_plaintext",
        pairingCode: String = "123456",
    ) = PluginDebugAuthPending(
        requestId = requestId,
        clientNonceHash = "nonce-hash",
        clientLabel = "devtool",
        requestedMethod = "GET",
        requestedPath = "/state",
        pairingCode = pairingCode,
        createdAt = Instant.parse("2026-08-31T10:00:00Z"),
        expiresAt = Instant.parse("2026-08-31T10:05:00Z"),
        tokenPlaintext = tokenPlaintext,
    )

    // 1. roundtrip -----------------------------------------------------------

    @Test
    fun `token records survive a store restart (roundtrip)`() {
        val dir = tempDir.newFolder("store")
        val now = Instant.parse("2026-08-31T10:00:00Z")
        newStore(dir, { now }).putToken(record(tokenId = "tok-a", now = now))

        val reloaded = newStore(dir, { now })
        assertEquals("hash-tok-a", reloaded.token("tok-a")!!.tokenHash)
        assertEquals("devtool", reloaded.token("tok-a")!!.clientLabel)
        assertEquals(record(tokenId = "tok-a", now = now), reloaded.token("tok-a"))
        assertNotNull(reloaded.tokenByHash("hash-tok-a"))
    }

    // 2. corrupt-fallback ----------------------------------------------------

    @Test
    fun `corrupt file falls back to empty instead of throwing`() {
        val dir = tempDir.newFolder("store")
        tokenFile(dir).writeText("{\"version\":1,\"tokens\":[{\"tokenId\":") // truncated JSON

        val store = newStore(dir)
        assertNull(store.token("anything"))
        // store stays usable: a new write replaces the corrupt file
        val now = Instant.parse("2026-08-31T10:00:00Z")
        store.putToken(record(tokenId = "tok-b", now = now))
        assertEquals(record(tokenId = "tok-b", now = now), newStore(dir, { now }).token("tok-b"))
    }

    @Test
    fun `unknown schema version falls back to empty`() {
        val dir = tempDir.newFolder("store")
        tokenFile(dir).writeText("{\"version\":99,\"tokens\":[]}")
        assertNull(newStore(dir).token("tok-a"))
    }

    // 3. nullable-roundtrip --------------------------------------------------

    @Test
    fun `nullable revokedAt and clientLabel survive a roundtrip`() {
        val dir = tempDir.newFolder("store")
        val now = Instant.parse("2026-08-31T10:00:00Z")
        newStore(dir, { now }).putToken(record(tokenId = "tok-n", now = now, clientLabel = null, revokedAt = null))

        val reloaded = newStore(dir, { now }).token("tok-n")!!
        assertNull(reloaded.revokedAt)
        assertNull(reloaded.clientLabel)

        // and the non-null variants too
        val revokedAt = Instant.parse("2026-08-31T10:01:00Z")
        newStore(dir, { now }).putToken(record(tokenId = "tok-r", now = now, revokedAt = revokedAt))
        assertEquals(revokedAt, newStore(dir, { now }).token("tok-r")!!.revokedAt)
    }

    // 4. revoked-persist -----------------------------------------------------

    @Test
    fun `markRevoked and markAllRevoked are persisted`() {
        val dir = tempDir.newFolder("store")
        val now = Instant.parse("2026-08-31T10:00:00Z")
        val store = newStore(dir, { now })
        store.putToken(record(tokenId = "tok-1", now = now))
        store.putToken(record(tokenId = "tok-2", now = now))

        val revokedAt = Instant.parse("2026-08-31T11:00:00Z")
        store.markRevoked("tok-1", revokedAt)
        assertEquals(revokedAt, newStore(dir, { now }).token("tok-1")!!.revokedAt)
        assertNull(newStore(dir, { now }).token("tok-2")!!.revokedAt)

        val allRevokedAt = Instant.parse("2026-08-31T12:00:00Z")
        store.markAllRevoked(allRevokedAt)
        val reloaded = newStore(dir, { now })
        assertEquals(allRevokedAt, reloaded.token("tok-1")!!.revokedAt)
        assertEquals(allRevokedAt, reloaded.token("tok-2")!!.revokedAt)
    }

    // 5. expired-cleanup -----------------------------------------------------

    @Test
    fun `expired token records are dropped and rewritten on load`() {
        val dir = tempDir.newFolder("store")
        val t0 = Instant.parse("2026-08-31T10:00:00Z")
        newStore(dir, { t0 }).putToken(record(tokenId = "tok-fresh", now = t0, ttlSeconds = 3600))
        newStore(dir, { t0 }).putToken(record(tokenId = "tok-stale", now = t0, ttlSeconds = 60))

        val tLater = Instant.parse("2026-08-31T11:00:00Z") // fresh still valid, stale expired
        val reloaded = newStore(dir, { tLater })
        assertNotNull(reloaded.token("tok-fresh"))
        assertNull(reloaded.token("tok-stale"))
        // rewritten on disk: a fresh reload sees the same pruned state
        assertNull(newStore(dir, { tLater }).token("tok-stale"))
        assertFalse(tokenFile(dir).readText().contains("tok-stale"))
    }

    // 6. atomic-write --------------------------------------------------------

    @Test
    fun `persist is atomic - no tmp file residue and target always parses`() {
        val dir = tempDir.newFolder("store")
        val now = Instant.parse("2026-08-31T10:00:00Z")
        val store = newStore(dir, { now })
        repeat(25) { i -> store.putToken(record(tokenId = "tok-$i", now = now)) }

        val names = dir.list()!!.toList()
        assertEquals(listOf("debug_auth_tokens.json"), names)
        // every intermediate state was a complete, parseable document
        assertEquals(25, newStore(dir, { now }).let { s -> (0 until 25).count { s.token("tok-$it") != null } })
    }

    // 7. concurrent-persist --------------------------------------------------

    @Test
    fun `concurrent writers never corrupt the file`() {
        val dir = tempDir.newFolder("store")
        val now = Instant.parse("2026-08-31T10:00:00Z")
        val store = newStore(dir, { now })
        val threads = 8
        val perThread = 25
        val pool = Executors.newFixedThreadPool(threads)
        val ready = CountDownLatch(1)
        val done = CountDownLatch(threads)
        repeat(threads) { t ->
            pool.submit {
                ready.await()
                repeat(perThread) { i ->
                    store.putToken(record(tokenId = "tok-$t-$i", now = now))
                    if (i % 5 == 0) store.markRevoked("tok-$t-0", now)
                }
                done.countDown()
            }
        }
        ready.countDown()
        assertTrue(done.await(30, TimeUnit.SECONDS))
        pool.shutdown()

        // final file parses and holds the full consistent state
        val reloaded = newStore(dir, { now })
        val expected = threads * perThread
        val present = (0 until threads).sumOf { t -> (0 until perThread).count { reloaded.token("tok-$t-$it") != null } }
        assertEquals(expected, present)
    }

    // 8. plaintext-redline ---------------------------------------------------

    @Test
    fun `pending records with plaintext token never reach the file`() {
        val dir = tempDir.newFolder("store")
        val now = Instant.parse("2026-08-31T10:00:00Z")
        val store = newStore(dir, { now })

        val plaintext = "dcp_secret_plaintext"
        store.putPending(pending(requestId = "auth-secret", tokenPlaintext = plaintext))
        store.putToken(record(tokenId = "tok-p", now = now, tokenHash = "only-the-hash"))
        store.markAllRevoked(now)

        val persisted = tokenFile(dir).readText()
        assertFalse("plaintext token must never be persisted", persisted.contains(plaintext))
        assertFalse("pairing code must never be persisted", persisted.contains("123456"))
        assertFalse("request id must never be persisted", persisted.contains("auth-secret"))
        assertTrue(persisted.contains("only-the-hash"))
        // pending stays memory-only and readable in-process
        assertEquals("auth-secret", store.pending("auth-secret")!!.requestId)
    }
}
