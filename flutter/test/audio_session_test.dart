// Tests for the call audio session (finding 1): audio.start /
// audio.stop to the owner, codec choice, retarget on take, stop on
// call end, downlink encode, uplink decode/inject, helper-not-ready
// retry. The native side is faked (FakeAudioBridge + mock method
// channels for the mic mute and BLE tuning).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/link/link.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';

import 'link_test.dart' show CollectingListener, FakeHubData, waitFor;

/// Fake platform audio path: records every call, controllable
/// helper readiness and downlink stream.
class FakeAudioBridge implements AudioBridge {
  bool helperReady = true;
  final List<String> calls = [];
  final List<int> injected = [];
  int encodeCalls = 0;
  final downlinkController = StreamController<List<int>>.broadcast();

  @override
  Future<Map<String, dynamic>?> ensureHelperRunning() async {
    calls.add('ensureHelperRunning');
    return helperReady ? {'state': 'running'} : null;
  }

  @override
  Future<void> startCapture({
    required int rate,
    required String method,
    required String inject,
  }) async {
    calls.add('startCapture:$rate:$method:$inject');
  }

  @override
  Future<void> stopCapture() async {
    calls.add('stopCapture');
  }

  @override
  Future<void> injectUplink(List<int> pcmBytes) async {
    injected.addAll(pcmBytes);
  }

  @override
  Future<List<List<int>>> opusEncode(List<int> pcmBytes) async {
    encodeCalls++;
    return [
      [0xaa]
    ];
  }

  @override
  Future<List<int>> opusDecode(List<int> frame) async =>
      [1, 0, 2, 0];

  @override
  Stream<List<int>> get downlink => downlinkController.stream;
}

/// A Hub wired to a central-side test client, with the audio session
/// attached to a fake bridge.
class AudioHarness {
  AudioHarness._(
    this.hub,
    this.client,
    this.clientListener,
    this.data,
    this.peripheral,
    this.central,
    this.bridge,
    this.peripheralKeys,
    this.token,
  );

  /// A second iPhone connecting to the same Hub (its own keys, the
  /// same open pairing token).
  Future<(CentralConnection, CollectingListener)> openSecond() async {
    final keys = P256.generate();
    final (a, b) = FakeTransport.pair();
    final listener = CollectingListener();
    final second = CentralConnection(
      b,
      listener,
      CentralKeys(
        staticKey: keys,
        peerStatic: peripheralKeys.publicEncoded,
        token: token,
      ),
    );
    hub.onTransport(a);
    second.start();
    await waitFor(() => second.isUp && hub.conns.length == 2);
    second.send(Message(MessageType.sync, b: {
      'sms': 0,
      'calls': 0,
      'contacts': '',
      'codecs': ['opus', 'pcmu'],
      'client': {'kind': 'iphone', 'name': 'Second iPhone'},
    }));
    await waitFor(
        () => hub.conns.any((c) => c.codecs.contains('opus')));
    return (second, listener);
  }

  final Hub hub;
  final CentralConnection client;
  final CollectingListener clientListener;
  final FakeHubData data;
  final PeripheralConnection peripheral;
  final CentralConnection central;
  final FakeAudioBridge bridge;
  final P256KeyPair peripheralKeys;
  final List<int> token;

  static Future<AudioHarness> open({List<String> codecs = const ['opus', 'pcmu']}) async {
    final peripheralKeys = P256.generate();
    final centralKeys = P256.generate();
    final token = P256.randomNonce();
    final data = FakeHubData();
    final bridge = FakeAudioBridge();
    final (a, b) = FakeTransport.pair();
    PeripheralConnection? peripheral;
    late final Hub hub;
    hub = Hub(
      data,
      connectionFactory: (t) {
        final c = PeripheralConnection(
          t,
          hub,
          PeripheralKeys(staticKey: peripheralKeys, openToken: token),
        );
        peripheral = c;
        return c;
      },
      audioBridge: bridge,
      telecom: TelecomBridge(),
      ble: BleLink(),
    );
    final clientListener = CollectingListener();
    final central = CentralConnection(
      b,
      clientListener,
      CentralKeys(
        staticKey: centralKeys,
        peerStatic: peripheralKeys.publicEncoded,
        token: token,
      ),
    );
    hub.onTransport(a);
    central.start();
    await waitFor(() => peripheral!.isUp && central.isUp);
    // The client announces its codecs, like a real sync.
    central.send(Message(MessageType.sync, b: {
      'sms': 0,
      'calls': 0,
      'contacts': '',
      'codecs': codecs,
      'client': {'kind': 'iphone', 'name': 'Test iPhone'},
    }));
    await waitFor(() => hub.conns.first.codecs.isNotEmpty);
    return AudioHarness._(
        hub, central, clientListener, data, peripheral!, central, bridge,
        peripheralKeys, token);
  }

  Future<void> close() async {
    hub.stopTimers();
    hub.dispose();
    central.close();
    peripheral.close();
    await bridge.downlinkController.close();
  }
}

const _ringing = CallInfo(
  cid: 'c1',
  num: '+989121234567',
  name: 'سارا احمدی',
  state: 'ringing',
  dir: 'in',
  hold: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final methodCalls = <MethodCall>[];

  setUp(() {
    methodCalls.clear();
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/telecom'), (call) async {
      methodCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/ble'), (call) async {
      methodCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/telecom'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/ble'), null);
  });

  Message? audioStartFor(AudioHarness h) {
    final found = h.clientListener.messages
        .where((e) => e.$2.t == MessageType.audioStart)
        .toList();
    return found.isEmpty ? null : found.last.$2;
  }

  group('AudioSession', () {
    test('answer starts audio: Opus start, capture, mic muted, BLE fast',
        () async {
      final h = await AudioHarness.open();
      h.hub.onCall(_ringing);
      h.client.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await waitFor(() => audioStartFor(h) != null);
      final start = audioStartFor(h)!;
      expect(start.b['codec'], 'opus');
      expect(start.b['rate'], 16000);
      expect(start.b['ms'], 20);
      expect(start.b['up'], isTrue);
      expect(start.b['bitrate'], 32000);
      expect(h.bridge.calls, contains('startCapture:16000:auto:auto'));
      expect(h.hub.audio.running, isTrue);
      expect(h.hub.audio.target, h.peripheral);
      expect(h.hub.audio.codec, 'opus');
      // Mic muted, BLE tuned high.
      expect(
          methodCalls.any((c) =>
              c.method == 'muteCall' && (c.arguments as Map)['on'] == true),
          isTrue);
      expect(
          methodCalls.any((c) =>
              c.method == 'tune' && (c.arguments as Map)['high'] == true),
          isTrue);
      await h.close();
    });

    test('PCMU fallback when the client has no Opus', () async {
      final h = await AudioHarness.open(codecs: ['pcmu']);
      h.hub.onCall(_ringing);
      h.client.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await waitFor(() => audioStartFor(h) != null);
      final start = audioStartFor(h)!;
      expect(start.b['codec'], 'pcmu');
      expect(start.b['rate'], 8000);
      expect(start.b['bitrate'], 64000);
      expect(h.bridge.calls, contains('startCapture:8000:auto:auto'));
      await h.close();
    });

    test('call end stops audio: audio.stop, capture stopped, mic back',
        () async {
      final h = await AudioHarness.open();
      h.hub.onCall(_ringing);
      h.client.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await waitFor(() => audioStartFor(h) != null);
      h.hub.onCall(const CallInfo(
        cid: 'c1',
        num: '+989121234567',
        state: 'ended',
        dir: 'in',
        hold: false,
      ));
      await waitFor(() => h.clientListener.messages
          .any((e) => e.$2.t == MessageType.audioStop));
      expect(h.bridge.calls, contains('stopCapture'));
      expect(h.hub.audio.running, isFalse);
      expect(h.hub.audio.target, isNull);
      expect(
          methodCalls.any((c) =>
              c.method == 'muteCall' && (c.arguments as Map)['on'] == false),
          isTrue);
      await h.close();
    });

    test('downlink PCM is encoded and sent to the owner', () async {
      final h = await AudioHarness.open();
      h.hub.onCall(_ringing);
      h.client.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await waitFor(() => audioStartFor(h) != null);
      h.bridge.downlinkController.add(List<int>.filled(640, 0));
      await waitFor(() => h.clientListener.audio.isNotEmpty);
      final frame = h.clientListener.audio.single.$2;
      expect(frame[0], AudioFrame.opus);
      expect(frame[1], 0); // seq high
      expect(frame[2], 0); // seq 0
      expect(frame.sublist(3), [0xaa]);
      expect(h.bridge.encodeCalls, 1);
      expect(h.hub.audio.downFrames, 1);
      await h.close();
    });

    test('uplink frames are decoded and injected', () async {
      final h = await AudioHarness.open();
      h.hub.onCall(_ringing);
      h.client.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await waitFor(() => audioStartFor(h) != null);
      h.client.sendAudio([AudioFrame.opus, 0, 5, 10, 20, 30]);
      await waitFor(() => h.bridge.injected.isNotEmpty);
      expect(h.bridge.injected, [1, 0, 2, 0]);
      expect(h.hub.audio.upFrames, 1);
      await h.close();
    });

    test('take retargets audio: old owner stops, its uplink is ignored',
        () async {
      final h = await AudioHarness.open();
      h.hub.onCall(_ringing);
      h.client.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await waitFor(() => audioStartFor(h) != null);
      final (second, secondListener) = await h.openSecond();
      second.send(Message(MessageType.callTake, b: {'cid': 'c1'}));
      await waitFor(() => secondListener.messages
          .any((e) => e.$2.t == MessageType.audioStart));
      // The old owner was told to stop.
      expect(
          h.clientListener.messages
              .any((e) => e.$2.t == MessageType.audioStop),
          isTrue);
      expect(h.hub.audio.target, isNot(h.peripheral));
      // Uplink from the old owner is ignored...
      h.client.sendAudio([AudioFrame.opus, 0, 9, 10]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(h.bridge.injected, isEmpty);
      // ...uplink from the new owner is decoded and injected.
      second.sendAudio([AudioFrame.opus, 0, 5, 10, 20, 30]);
      await waitFor(() => h.bridge.injected.isNotEmpty);
      expect(h.bridge.injected, [1, 0, 2, 0]);
      second.close();
      await h.close();
    });

    test('helper not ready: no start until the next reconcile', () async {
      final h = await AudioHarness.open();
      h.bridge.helperReady = false;
      h.hub.onCall(_ringing);
      h.client.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(audioStartFor(h), isNull);
      expect(h.bridge.calls, contains('ensureHelperRunning'));
      // The helper comes up: the next reconcile starts the audio.
      h.bridge.helperReady = true;
      h.hub.audio.reconcile(h.hub.targets(),
          callWantsAudio: true);
      await waitFor(() => audioStartFor(h) != null);
      expect(h.bridge.calls, contains('startCapture:16000:auto:auto'));
      await h.close();
    });

    test('pause stops audio, resume starts it again', () async {
      final h = await AudioHarness.open();
      h.hub.onCall(_ringing);
      h.client.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await waitFor(() => audioStartFor(h) != null);
      h.hub.audio.pause();
      await waitFor(() => h.clientListener.messages
          .any((e) => e.$2.t == MessageType.audioStop));
      h.hub.audio.resume();
      await waitFor(() => h.clientListener.messages
          .where((e) => e.$2.t == MessageType.audioStart)
          .length >= 2);
      await h.close();
    });
  });
}
