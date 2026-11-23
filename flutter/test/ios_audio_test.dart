// Tests for the iOS audio bridge wrapper (finding 8): method names
// and argument shapes against the Swift AudioPlugin, plus the
// captured-frame event stream. No native code runs here — the channels
// are faked.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/link/ios_audio.dart';
import 'package:sim_bridge/src/protocol/audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IosAudioBridge', () {
    late IosAudioBridge bridge;
    late List<MethodCall> calls;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      calls = [];
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/audio'), (call) async {
        calls.add(call);
        return switch (call.method) {
          'supportedCodecs' => ['opus', 'pcmu'],
          'opusEncode' => Uint8List.fromList([0x11, 0x22]),
          'opusDecode' => Uint8List.fromList([1, 0, 2, 0]),
          _ => null,
        };
      });
      bridge = IosAudioBridge();
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/audio'), null);
    });

    test('audioStart sends codec, rate and bitrate', () async {
      await bridge.audioStart(codec: 'opus', rate: 16000, bitrate: 32000);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'audioStart');
      final args = Map<String, dynamic>.from(calls.single.arguments as Map);
      expect(args['codec'], 'opus');
      expect(args['rate'], 16000);
      expect(args['bitrate'], 32000);
    });

    test('audioStop, playFrame, setMuted, setRingback', () async {
      await bridge.audioStop();
      await bridge.playFrame(codec: AudioFrame.opus, seq: 7, payload: [9, 9]);
      await bridge.setMuted(true);
      await bridge.setRingback(true);
      expect(calls.map((c) => c.method),
          ['audioStop', 'playFrame', 'setMuted', 'setRingback']);
      final play = Map<String, dynamic>.from(calls[1].arguments as Map);
      expect(play['codec'], AudioFrame.opus);
      expect(play['seq'], 7);
      expect((play['payload'] as Uint8List).toList(), [9, 9]);
      expect((calls[2].arguments as Map)['on'], isTrue);
      expect((calls[3].arguments as Map)['on'], isTrue);
    });

    test('supportedCodecs lists opus first', () async {
      expect(await bridge.supportedCodecs(), ['opus', 'pcmu']);
    });

    test('opusEncode / opusDecode round-trip bytes', () async {
      expect(await bridge.opusEncode([1, 0, 2, 0]), [0x11, 0x22]);
      expect(await bridge.opusDecode([0x11, 0x22]), [1, 0, 2, 0]);
    });

    test('captured events parse to frames', () async {
      final frames = <CapturedAudioFrame>[];
      final sub = bridge.captured.listen(frames.add);
      await messenger.handlePlatformMessage(
        'com.simbridge/audio/events',
        const StandardMethodCodec().encodeSuccessEnvelope({
          't': 'captured',
          'codec': AudioFrame.opus,
          'seq': 3,
          'payload': Uint8List.fromList([5, 6, 7]),
        }),
        (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(frames, hasLength(1));
      expect(frames.single.codec, AudioFrame.opus);
      expect(frames.single.seq, 3);
      expect(frames.single.payload, [5, 6, 7]);
      await sub.cancel();
    });
  });
}
