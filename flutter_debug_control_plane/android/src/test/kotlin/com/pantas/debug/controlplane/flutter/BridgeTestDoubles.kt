package com.pantas.debug.controlplane.flutter

import com.pantas.debug.controlplane.ControlPlane
import com.pantas.debug.controlplane.RouteContext
import com.pantas.debug.controlplane.Transport
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Shared JVM test doubles for the FF001 plugin suite (zero business deps). */

/**
 * Fake [MethodChannel] replacement: records reverse `invokeMethod` calls and
 * lets tests answer them asynchronously (simulating the Dart side).
 *
 * The production code only touches [MethodChannel.invokeMethod] and
 * [MethodChannel.setMethodCallHandler] — both are overridden here, so the
 * fake is behaviorally sufficient without a Flutter engine.
 */
class FakeMethodChannel : MethodChannel(
    FakeBinaryMessenger(),
    ChannelProtocol.METHOD_CHANNEL,
) {

    /** Reverse invokes recorded natively -> "Dart". */
    val invokes = mutableListOf<RecordedInvoke>()

    /** The handler the plugin installed (the "Dart" side entry). */
    @Volatile
    var handler: MethodChannel.MethodCallHandler? = null

    /** Programmed Dart-side answer for a reverse invoke (by method name). */
    var dartAnswer: suspend (RecordedInvoke) -> Unit = { }

    class RecordedInvoke(
        val method: String,
        val arguments: Map<String, Any?>,
        val result: ResultRecorder,
    ) {
        val reqId: Long get() = (arguments["reqId"] as Number).toLong()
        val capId: String get() = arguments["capId"] as String
    }

    class ResultRecorder {
        var replied: Any? = null
            private set
        var repliedFlag = false
            private set

        fun reply(value: Any?) {
            replied = value
            repliedFlag = true
        }
    }

    override fun invokeMethod(method: String, arguments: Any?, callback: MethodChannel.Result?) {
        @Suppress("UNCHECKED_CAST")
        val args = (arguments as? Map<String, Any?>) ?: emptyMap()
        val recorder = ResultRecorder()
        val record = RecordedInvoke(method, args, recorder)
        synchronized(invokes) { invokes += record }
        val answer = dartAnswer
        scope.launch {
            answer(record)
        }
    }

    override fun setMethodCallHandler(handler: MethodChannel.MethodCallHandler?) {
        this.handler = handler
    }

    /** Suspend until [count] reverse invokes have been recorded. */
    suspend fun awaitInvokeCount(count: Int) {
        kotlinx.coroutines.withTimeout(2_000) {
            while (synchronized(invokes) { invokes.size } < count) {
                kotlinx.coroutines.delay(10)
            }
        }
    }

    companion object {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}

/** Build a [MethodCall] with a Map payload the way the codec would decode it. */
fun methodCall(method: String, args: Map<String, Any?>): MethodCall = MethodCall(method, args)

/** Recording [MethodChannel.Result] for forward (Dart -> native) calls. */
class RecordingResult : MethodChannel.Result {
    var successValue: Any? = null
        private set
    var errorCode: String? = null
        private set
    var errorMessage: String? = null
        private set
    var notImplementedFlag = false
        private set
    val done get() = successValue != null || errorCode != null || notImplementedFlag

    override fun success(result: Any?) {
        successValue = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        this.errorCode = errorCode
        this.errorMessage = errorMessage
    }

    override fun notImplemented() {
        notImplementedFlag = true
    }
}

/** In-memory transport for plane-level tests (no NanoHTTPD socket). */
class FakeTransport : Transport {
    var handler: (suspend (com.pantas.debug.controlplane.RouteRequest) -> com.pantas.debug.controlplane.RouteResult)? = null
    val broadcasts = mutableListOf<com.pantas.debug.controlplane.DebugEvent>()

    override suspend fun bind(port: Int): java.net.URI = java.net.URI("http://0.0.0.0:$port/")
    override fun listen(handler: suspend (com.pantas.debug.controlplane.RouteRequest) -> com.pantas.debug.controlplane.RouteResult) {
        this.handler = handler
    }

    override suspend fun serverInfo(request: Any?): Map<String, Any?> = emptyMap()
    override fun broadcast(event: com.pantas.debug.controlplane.DebugEvent) {
        broadcasts += event
    }

    override suspend fun close() {}
}

/** Minimal no-op BinaryMessenger so [FakeMethodChannel] can be constructed. */
class FakeBinaryMessenger : io.flutter.plugin.common.BinaryMessenger {
    override fun send(channel: String, message: java.nio.ByteBuffer?, callback: io.flutter.plugin.common.BinaryMessenger.BinaryReply?) = Unit
    override fun send(channel: String, message: java.nio.ByteBuffer?) = Unit
    override fun setMessageHandler(channel: String, handler: io.flutter.plugin.common.BinaryMessenger.BinaryMessageHandler?) = Unit
}
