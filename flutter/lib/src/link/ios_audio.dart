/// iOS call-audio bridge: the AVAudioEngine side of `com.simbridge/audio`.
///
/// The iOS audio channel has **different methods** from Android's (no
/// shell helper): the engine is configured with the codec the Android
/// phone chose (`audioStart`), plays received frames (`playFrame`),
/// and emits the microphone's encoded frames on [captured]. The engine
/// itself starts/stops with the CallKit audio session
/// (`CallKitManager` drives `sessionActivated`/`sessionDeactivated`);
/// Dart does not start the engine directly — it only configures it
/// when the `audio.start` message arrives and feeds it frames.
///
/// iOS only. On Android the same channel name carries the helper
/// methods (see [CallAudioBridge]).
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../protocol/audio.dart';

/// One encoded 20 ms microphone frame from the iOS audio engine, for
/// Dart to send to the Android phone as an audio record.
class CapturedAudioFrame {
  const CapturedAudioFrame({
    required this.codec,
    required this.seq,
    required this.payload,
  });

  /// Codec id ([AudioFrame.opus] / [AudioFrame.pcmu]).
  final int codec;

  /// Sequence number (keeps counting for the whole call).
  final int seq;

  /// The encoded frame bytes.
  final List<int> payload;

  static CapturedAudioFrame? parse(dynamic event) {
    if (event is! Map) return null;
    final map = Map<String, dynamic>.from(event);
    if (map['t'] != 'captured') return null;
    final raw = map['payload'];
    final payload = raw is Uint8List
        ? raw.toList()
        : raw is List
            ? List<int>.from(raw)
            : null;
    if (payload == null) return null;
    return CapturedAudioFrame(
      codec: (map['codec'] as num?)?.toInt() ?? AudioFrame.opus,
      seq: (map['seq'] as num?)?.toInt() ?? 0,
      payload: payload,
    );
  }
}

/// The iOS audio engine bridge (iOS only).
class IosAudioBridge {
  IosAudioBridge({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _methods = methodChannel ??
            const MethodChannel('com.simbridge/audio'),
        _events = eventChannel ??
            const EventChannel('com.simbridge/audio/events');

  final MethodChannel _methods;
  final EventChannel _events;

  /// Selects the codec for the call. Call it when the `audio.start`
  /// message arrives (Dart knows the codec from the Android phone).
  Future<void> audioStart({
    required String codec,
    required int rate,
    int? bitrate,
  }) =>
      _methods.invokeMethod<void>('audioStart', {
        'codec': codec,
        'rate': rate,
        'bitrate': ?bitrate,
      });

  /// Stops the engine.
  Future<void> audioStop() => _methods.invokeMethod<void>('audioStop');

  /// Decodes a received audio frame and queues it in the playout
  /// buffer.
  Future<void> playFrame({
    required int codec,
    required int seq,
    required List<int> payload,
  }) =>
      _methods.invokeMethod<void>('playFrame', {
        'codec': codec,
        'seq': seq,
        'payload': Uint8List.fromList(payload),
      });

  /// Microphone mute.
  Future<void> setMuted(bool on) =>
      _methods.invokeMethod<void>('setMuted', {'on': on});

  /// Local ringback (the engine plays a 425 Hz ringback while
  /// dialing until the far end is heard).
  Future<void> setRingback(bool on) =>
      _methods.invokeMethod<void>('setRingback', {'on': on});

  /// Codecs the device can encode/decode: `['opus', 'pcmu']`, or
  /// `['pcmu']` when AudioToolbox Opus is unavailable.
  Future<List<String>> supportedCodecs() async {
    final result =
        await _methods.invokeMethod<List<dynamic>>('supportedCodecs');
    if (result == null) return const ['pcmu'];
    return result.map((e) => e.toString()).toList();
  }

  /// Encodes one 20 ms PCM frame to a single Opus frame.
  Future<List<int>> opusEncode(List<int> pcm) async {
    final result = await _methods.invokeMethod<Uint8List>(
        'opusEncode', {'pcm': Uint8List.fromList(pcm)});
    return result?.toList() ?? const [];
  }

  /// Decodes one Opus frame to PCM bytes (16-bit little-endian mono).
  Future<List<int>> opusDecode(List<int> frame) async {
    final result = await _methods.invokeMethod<Uint8List>(
        'opusDecode', {'frame': Uint8List.fromList(frame)});
    return result?.toList() ?? const [];
  }

  /// Encoded 20 ms microphone frames, for Dart to send as audio
  /// records.
  Stream<CapturedAudioFrame> get captured => _events
      .receiveBroadcastStream()
      .map(CapturedAudioFrame.parse)
      .where((e) => e != null)
      .cast<CapturedAudioFrame>();
}
