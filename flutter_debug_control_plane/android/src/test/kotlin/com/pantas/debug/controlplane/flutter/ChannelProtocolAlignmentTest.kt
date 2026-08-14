package com.pantas.debug.controlplane.flutter

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * FF001-1 mirror guard (Kotlin side): every Kotlin constant literal must be
 * present in the Dart side `lib/src/channel_protocol.dart` — the Dart side
 * runs the reciprocal test (`test/channel_protocol_alignment_test.dart`),
 * so drift in either direction fails CI.
 */
class ChannelProtocolAlignmentTest {

    private val dartFile: File = File(
        "src/../../lib/src/channel_protocol.dart",
    )

    private fun expectDartContains(dartLiteral: String, ktName: String) {
        val source = dartFile.readText()
        assertTrue(
            "Dart channel_protocol.dart drifted: literal '$dartLiteral' (Kotlin $ktName) missing",
            source.contains("const String ${toDartConstName(ktName)} = '$dartLiteral';"),
        )
    }

    /**
     * METHOD_CHANNEL -> kMethodChannel, PLANE_START -> kMethodPlaneStart,
     * ERROR_DUPLICATE -> kErrorCodeDuplicate (prefix-aware conversion —
     * mirrors the Dart naming scheme in channel_protocol.dart).
     */
    private fun toDartConstName(ktName: String): String = when (ktName) {
        "METHOD_CHANNEL" -> "kMethodChannel"
        "EVENT_CHANNEL" -> "kEventChannel"
        "PLANE_START" -> "kMethodPlaneStart"
        "PLANE_STOP" -> "kMethodPlaneStop"
        "CAPABILITY_REGISTER" -> "kMethodCapabilityRegister"
        "CAPABILITY_UNREGISTER" -> "kMethodCapabilityUnregister"
        "EVENTS_EMIT" -> "kMethodEventsEmit"
        "CAPABILITY_STATE_UPDATE" -> "kMethodCapabilityStateUpdate"
        "CAPABILITY_INVOKE_RESULT" -> "kMethodCapabilityInvokeResult"
        "CAPABILITY_INVOKE" -> "kMethodCapabilityInvoke"
        "CAPABILITY_STATE_PULL" -> "kMethodCapabilityStatePull"
        "CAPABILITY_STATE_RESULT" -> "kMethodCapabilityStateResult"
        "ROUTE_KIND_RESOURCE" -> "kRouteKindResource"
        "ROUTE_KIND_COMMAND" -> "kRouteKindCommand"
        "ERROR_DUPLICATE" -> "kErrorCodeDuplicate"
        "ERROR_NOT_REGISTERED" -> "kErrorCodeNotRegistered"
        "ERROR_BIND_FAILED" -> "kErrorCodeBindFailed"
        else -> throw IllegalArgumentException("unmapped constant $ktName")
    }


    @Test
    fun `channel names aligned`() {
        expectDartContains(ChannelProtocol.METHOD_CHANNEL, "METHOD_CHANNEL")
        expectDartContains(ChannelProtocol.EVENT_CHANNEL, "EVENT_CHANNEL")
    }

    @Test
    fun `forward methods aligned`() {
        expectDartContains(ChannelProtocol.PLANE_START, "PLANE_START")
        expectDartContains(ChannelProtocol.PLANE_STOP, "PLANE_STOP")
        expectDartContains(ChannelProtocol.CAPABILITY_REGISTER, "CAPABILITY_REGISTER")
        expectDartContains(ChannelProtocol.CAPABILITY_UNREGISTER, "CAPABILITY_UNREGISTER")
        expectDartContains(ChannelProtocol.EVENTS_EMIT, "EVENTS_EMIT")
        expectDartContains(ChannelProtocol.CAPABILITY_STATE_UPDATE, "CAPABILITY_STATE_UPDATE")
        expectDartContains(ChannelProtocol.CAPABILITY_INVOKE_RESULT, "CAPABILITY_INVOKE_RESULT")
    }

    @Test
    fun `reverse invokes aligned`() {
        expectDartContains(ChannelProtocol.CAPABILITY_INVOKE, "CAPABILITY_INVOKE")
        expectDartContains(ChannelProtocol.CAPABILITY_STATE_PULL, "CAPABILITY_STATE_PULL")
        expectDartContains(ChannelProtocol.CAPABILITY_STATE_RESULT, "CAPABILITY_STATE_RESULT")
    }

    @Test
    fun `routeKind literals aligned`() {
        expectDartContains(ChannelProtocol.ROUTE_KIND_RESOURCE, "ROUTE_KIND_RESOURCE")
        expectDartContains(ChannelProtocol.ROUTE_KIND_COMMAND, "ROUTE_KIND_COMMAND")
    }

    @Test
    fun `error codes aligned`() {
        expectDartContains(ChannelProtocol.ERROR_DUPLICATE, "ERROR_DUPLICATE")
        expectDartContains(ChannelProtocol.ERROR_NOT_REGISTERED, "ERROR_NOT_REGISTERED")
        expectDartContains(ChannelProtocol.ERROR_BIND_FAILED, "ERROR_BIND_FAILED")
    }
}
