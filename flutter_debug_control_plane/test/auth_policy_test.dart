import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart';

/// R006-FF001 T1-T4: AuthPolicy wire 映射 + start() 参数透传序列化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Route outgoing platform messages into [sent]; reply to plane.start with
  /// a minimal uri map so `Uri.parse` in `start()` never throws.
  void capture(List<MethodCall> sent) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel(kMethodChannel),
      (call) async {
        sent.add(call);
        if (call.method == kMethodPlaneStart) {
          return <String, Object?>{'uri': 'http://127.0.0.1:1'};
        }
        return null;
      },
    );
  }

  group('T1: wireName mapping', () {
    test('three values map to lowercase wire literals', () {
      expect(AuthPolicy.defaultPolicy.wireName, 'default');
      expect(AuthPolicy.auto.wireName, 'auto');
      expect(AuthPolicy.none.wireName, 'none');
    });
  });

  group('T2: start() without authPolicy is byte-compatible', () {
    test('channel args contain NO authPolicy key when omitted', () async {
      final sent = <MethodCall>[];
      capture(sent);

      final bridge = NativeControlPlaneBridge();
      await bridge.start(address: '127.0.0.1', port: 18080);

      final call = sent.firstWhere((c) => c.method == kMethodPlaneStart);
      final args = (call.arguments as Map).cast<String, Object?>();
      expect(args.containsKey('authPolicy'), isFalse,
          reason: '0.5.1 byte compatibility: absent param must stay absent');
      await bridge.dispose();
    });
  });

  group('T3: start() with authPolicy serializes wireName', () {
    test('channel args carry authPolicy:"auto"', () async {
      final sent = <MethodCall>[];
      capture(sent);

      final bridge = NativeControlPlaneBridge();
      await bridge.start(
        address: '127.0.0.1',
        port: 18080,
        authPolicy: AuthPolicy.auto,
      );

      final call = sent.firstWhere((c) => c.method == kMethodPlaneStart);
      final args = (call.arguments as Map).cast<String, Object?>();
      expect(args['authPolicy'], 'auto');
      await bridge.dispose();
    });
  });

  group('T4: fromWire', () {
    test('null -> defaultPolicy (0.5.1 absent-param semantics)', () {
      expect(AuthPolicy.fromWire(null), AuthPolicy.defaultPolicy);
    });

    test('unknown wire value throws ArgumentError', () {
      expect(() => AuthPolicy.fromWire('bogus'), throwsArgumentError);
    });

    test('legal wire values roundtrip', () {
      for (final policy in AuthPolicy.values) {
        expect(AuthPolicy.fromWire(policy.wireName), policy);
      }
    });
  });
}
