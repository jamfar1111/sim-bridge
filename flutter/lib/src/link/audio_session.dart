/// Call audio session: who the call audio flows to, and the actual
/// Opus / PCMU path between the Android phone's call and the peer.
///
/// A Dart model of Tether's Android `Hub.kt` `AudioSession`. The
/// ownership rules are protocol §5.1: exactly one owner — the client
/// that answered, dialed or took the call; if nobody claimed it
/// (answered on the Android phone itself), the client used most
/// recently, else the iPhone.
///
/// The session has two halves:
/// - the *intent* (`owner` / `target` / `running`): which client
///   should have the audio. [reconcile] keeps it valid against the
///   live connections and whether a call wants audio; it is purely
///   synchronous, so tests can assert it without native code.
/// - the *native path*: when an [AudioBridge] is attached, reconcile
///   also drives the shell helper (capture), the Opus codec, the
///   Android mic mute and the BLE priority, and sends `audio.start` /
///   `audio.stop` to the owner. Without a bridge (tests) the intent
///   is tracked but no audio flows.
///
/// Codec choice follows the peer: Opus when the client lists it
/// (16 kHz, 32 kbps), else G.711 µ-law (8 kHz). The Android phone
/// encodes the downlink and decodes the uplink; the iPhone does the
/// same on its side (see `ios_audio.dart`).
library;

import 'dart:async';

import '../protocol/audio.dart';
import '../protocol/messages.dart';
import 'channels.dart';
import 'connection.dart';

/// The platform audio path the session drives.
///
/// Android: the shell helper (uid 2000) captures the call downlink
/// and injects the uplink, and the native side holds the Opus codec
/// (Dart has no Opus implementation). Implemented by
/// [AndroidAudioBridge] over [CallAudioBridge].
abstract class AudioBridge {
  /// Starts the helper if needed. Returns its state document, or
  /// `null` when it did not answer (the session retries on the next
  /// reconcile tick).
  Future<Map<String, dynamic>?> ensureHelperRunning();

  /// Starts capturing the downlink and injecting the uplink.
  Future<void> startCapture({
    required int rate,
    required String method,
    required String inject,
  });

  Future<void> stopCapture();

  /// Injects one 20 ms uplink PCM frame (16-bit little-endian mono).
  Future<void> injectUplink(List<int> pcmBytes);

  /// Encodes 20 ms PCM frames to Opus. Returns the encoded frames
  /// (usually one).
  Future<List<List<int>>> opusEncode(List<int> pcmBytes);

  /// Decodes one Opus frame to PCM bytes (16-bit little-endian mono).
  Future<List<int>> opusDecode(List<int> frame);

  /// Downlink PCM frames (16-bit little-endian mono, 20 ms each)
  /// from the helper.
  Stream<List<int>> get downlink;
}

/// [AudioBridge] over the Android [CallAudioBridge] channel.
class AndroidAudioBridge implements AudioBridge {
  AndroidAudioBridge(this._bridge);

  final CallAudioBridge _bridge;

  @override
  Future<Map<String, dynamic>?> ensureHelperRunning() =>
      _bridge.ensureHelperRunning();

  @override
  Future<void> startCapture({
    required int rate,
    required String method,
    required String inject,
  }) =>
      _bridge.startCapture(rate: rate, method: method, inject: inject);

  @override
  Future<void> stopCapture() => _bridge.stopCapture();

  @override
  Future<void> injectUplink(List<int> pcmBytes) =>
      _bridge.injectUplink(pcmBytes);

  @override
  Future<List<List<int>>> opusEncode(List<int> pcmBytes) =>
      _bridge.opusEncode(pcmBytes);

  @override
  Future<List<int>> opusDecode(List<int> frame) =>
      _bridge.opusDecode(frame);

  @override
  Stream<List<int>> get downlink => _bridge.downlink;
}

/// Which client the call audio flows to, and the native audio path.
///
/// Replaces the intent-only `AudioOwnership`: the same fields and
/// [reconcile] contract, plus the `audio.start` / `audio.stop`
/// messages, helper control, Opus/PCMU encode/decode, mic muting and
/// BLE tuning.
class AudioSession {
  AudioSession({
    this.bridge,
    this.telecom,
    this.ble,
    this.injectMethod = 'auto',
  });

  /// The platform audio path, or `null` when there is none (tests):
  /// then only the intent is tracked.
  final AudioBridge? bridge;

  /// Mutes the Android phone's own microphone while bridged.
  final TelecomBridge? telecom;

  /// Asks for high connection priority / 2M PHY while a call runs.
  final BleLink? ble;

  /// The helper injection method (`auto` / `intercept` / ...).
  final String injectMethod;

  /// Client that should have the call audio (answered / dialed / took
  /// it), `null` when there is no call.
  LinkConnection? owner;

  /// Client the call audio currently flows to.
  LinkConnection? target;

  bool running = false;
  bool uplinkMuted = false;

  /// Codec in use: `'opus'` / `'pcmu'`, or `null` when audio is off.
  String? codec;

  /// Client the audio was last announced to (audio.start sent).
  LinkConnection? _announcedTarget;

  /// Whether the native path is up (helper capturing).
  bool _started = false;

  /// Paused for a self-test (the helper is checked again after).
  bool _paused = false;

  int _seq = 0;
  int _lastUpSeq = -1;
  int _backwards = 0;

  /// Instrumentation (see README "Latency" in Tether).
  int downFrames = 0;
  int upFrames = 0;
  int upLost = 0;

  StreamSubscription<List<int>>? _downlinkSub;
  bool _applying = false;
  bool _applyPending = false;
  List<LinkConnection>? _lastLive;
  bool _lastCallWantsAudio = false;

  /// A client answered, dialed or asked to move the call to itself.
  /// Call [reconcile] after this (the Hub does): claiming alone does
  /// not start audio.
  void claim(LinkConnection c) {
    c.lastAction = DateTime.now();
    owner = c;
  }

  /// A client reconnected (new link replacing its old one): the call
  /// audio follows it.
  void handOver(LinkConnection old, LinkConnection replacement) {
    if (owner == old) owner = replacement;
    if (target == old) target = replacement;
    if (_announcedTarget == old) _announcedTarget = replacement;
  }

  /// Keeps [owner] valid against the live connections and whether a
  /// call wants audio, then drives the native path. Returns true
  /// when the owner changed.
  bool reconcile(List<LinkConnection> live, {required bool callWantsAudio}) {
    _lastLive = live;
    _lastCallWantsAudio = callWantsAudio;
    final before = owner;
    if (owner != null && !live.contains(owner)) owner = null;
    if (!callWantsAudio) {
      // Keep a claim made a moment ago (dial in flight, answer not
      // yet active).
      if (owner != null &&
          DateTime.now().difference(owner!.lastAction).inSeconds > 5) {
        owner = null;
      }
    } else if (owner == null) {
      LinkConnection? best;
      for (final c in live) {
        if (best == null || c.lastAction.isAfter(best.lastAction)) {
          best = c;
        }
      }
      owner = best ?? (live.isNotEmpty ? live.first : null);
    }
    running = owner != null && owner!.isUp && callWantsAudio && !_paused;
    if (running) {
      target = owner;
    } else {
      target = null;
    }
    if (bridge != null) unawaited(_apply());
    return owner != before;
  }

  /// Pauses the audio path (self-test): the helper keeps running,
  /// but no audio flows until [resume].
  void pause() {
    _paused = true;
    _recomputeLast();
    if (bridge != null) unawaited(_apply());
  }

  void resume() {
    _paused = false;
    _recomputeLast();
    if (bridge != null) unawaited(_apply());
  }

  /// Re-runs the intent computation with the inputs from the last
  /// [reconcile] (used by pause/resume, which have no fresh inputs).
  void _recomputeLast() {
    if (_lastLive == null) return;
    running = owner != null &&
        owner!.isUp &&
        _lastCallWantsAudio &&
        !_paused;
    target = running ? owner : null;
  }

  /// Stops the native path entirely (service shutdown). The intent
  /// (`owner` / `running`) is left alone; callers clear it through
  /// [reconcile].
  Future<void> shutdown() async {
    if (_started) await _stopNative(sendStop: true);
  }

  void dispose() {
    unawaited(_downlinkSub?.cancel());
    _downlinkSub = null;
  }

  /// Drives the native path to match the intent. Serialised: a
  /// reconcile during an apply re-runs afterwards.
  Future<void> _apply() async {
    if (_applying) {
      _applyPending = true;
      return;
    }
    _applying = true;
    try {
      final t = target;
      if (running && t != null && t.isUp) {
        if (_started && _announcedTarget == t) {
          // Already flowing to the right client: keep the mic muted
          // and the link fast.
          _muteLocalMic(true);
          _tune(t.transport.address, high: true);
        } else if (_started) {
          await _retarget(t);
        } else {
          await _start(t);
        }
      } else if (_started) {
        await _stopNative(sendStop: true);
      }
    } finally {
      _applying = false;
      if (_applyPending) {
        _applyPending = false;
        unawaited(_apply());
      }
    }
  }

  String _codecFor(LinkConnection c) =>
      c.codecs.contains('opus') ? 'opus' : 'pcmu';

  int _rateFor(String codecName) => codecName == 'opus' ? 16000 : 8000;

  int _codecId(String codecName) =>
      codecName == 'opus' ? AudioFrame.opus : AudioFrame.pcmu;

  Future<void> _start(LinkConnection c) async {
    final b = bridge;
    if (b == null) return;
    // Never wait for the helper here holding anything up: if it is
    // not running yet, kick it (ensureHelperRunning starts it) and
    // let the next 1 s reconcile try again.
    final state = await b.ensureHelperRunning();
    if (state == null) return;
    final codecName = _codecFor(c);
    final rate = _rateFor(codecName);
    codec = codecName;
    _seq = 0;
    _lastUpSeq = -1;
    _backwards = 0;
    uplinkMuted = false;
    _started = true;
    _announcedTarget = c;
    _downlinkSub?.cancel();
    _downlinkSub = b.downlink.listen(
      _onDownlink,
      onError: (_) {},
      cancelOnError: false,
    );
    await b.startCapture(rate: rate, method: 'auto', inject: injectMethod);
    c.sendUrgent(Message(MessageType.audioStart, b: {
      'codec': codecName,
      'rate': rate,
      'ms': 20,
      'up': true,
      'bitrate': codecName == 'opus' ? 32000 : 64000,
    }));
    _muteLocalMic(true);
    _tune(c.transport.address, high: true);
  }

  /// Moves running call audio to another client; the helper (and the
  /// Android phone's muting) keep running.
  Future<void> _retarget(LinkConnection c) async {
    final old = _announcedTarget;
    final codecName = _codecFor(c);
    codec = codecName;
    _seq = 0;
    _lastUpSeq = -1;
    _backwards = 0;
    uplinkMuted = false;
    _announcedTarget = c;
    old?.sendUrgent(const Message(MessageType.audioStop));
    if (old != null) _tune(old.transport.address, high: false);
    c.sendUrgent(Message(MessageType.audioStart, b: {
      'codec': codecName,
      'rate': _rateFor(codecName),
      'ms': 20,
      'up': true,
      'bitrate': codecName == 'opus' ? 32000 : 64000,
    }));
    _tune(c.transport.address, high: true);
  }

  Future<void> _stopNative({required bool sendStop}) async {
    if (!_started) return;
    _started = false;
    await _downlinkSub?.cancel();
    _downlinkSub = null;
    final b = bridge;
    if (b != null) {
      await b.stopCapture().catchError((_) {});
    }
    final t = _announcedTarget;
    if (sendStop) t?.sendUrgent(const Message(MessageType.audioStop));
    codec = null;
    _announcedTarget = null;
    _muteLocalMic(false);
    if (t != null) _tune(t.transport.address, high: false);
  }

  /// While bridged, only the peer's microphone may reach the call:
  /// mute the Android phone's own mic through Telecom.
  void _muteLocalMic(bool on) {
    unawaited(telecom?.muteCall(on).catchError((_) {}));
  }

  /// Asks the link for high connection priority / 2M PHY while a
  /// call runs (peripheral side).
  void _tune(String address, {required bool high}) {
    unawaited(ble?.tune(address, high: high).catchError((_) {}));
  }

  /// Downlink PCM from the helper: encode and send to the owner.
  Future<void> _onDownlink(List<int> pcmBytes) async {
    final b = bridge;
    final t = target;
    final codecName = codec;
    if (b == null || t == null || codecName == null || !_started) return;
    final frames = codecName == 'opus'
        ? await b.opusEncode(pcmBytes).catchError((_) => <List<int>>[])
        : <List<int>>[_pcmBytesToUlaw(pcmBytes)];
    for (final frame in frames) {
      final audioFrame = AudioFrame(_codecId(codecName), _seq, frame);
      _seq = (_seq + 1) & 0xffff;
      downFrames++;
      t.sendAudio(audioFrame.encoded());
    }
  }

  /// Uplink audio frame from the owner: decode and inject into the
  /// call. Frames from other clients are ignored (the Hub only
  /// forwards the owner's).
  Future<void> onUplink(LinkConnection c, List<int> payload) async {
    final b = bridge;
    final codecName = codec;
    if (b == null || c != target || codecName == null || !_started) return;
    final frame = AudioFrame.parse(payload);
    if (frame == null || frame.codec != _codecId(codecName)) return;
    // A gap in the sequence (frames dropped for lateness): conceal
    // up to 2 frames instead of a hard gap.
    final gap = _lastUpSeq < 0 ? 1 : ((frame.seq - _lastUpSeq) & 0xffff);
    if (gap == 0 || gap > 0x8000) {
      // Duplicate / late. Several "late" frames in a row mean the
      // client restarted its counter (its audio engine restarted
      // after a route change): follow it instead of dropping its
      // voice until it catches up.
      if (gap == 0 || ++_backwards < 3) return;
    }
    _backwards = 0;
    _lastUpSeq = frame.seq;
    if (gap >= 2 && gap <= 3) {
      for (var i = 0; i < gap - 1; i++) {
        final concealed = _conceal(codecName);
        if (concealed != null) {
          await b.injectUplink(concealed).catchError((_) {});
        }
        upLost++;
      }
    }
    final List<int> pcm;
    if (codecName == 'opus') {
      pcm = await b.opusDecode(frame.payload).catchError((_) => <int>[]);
      if (pcm.isEmpty) return;
    } else {
      pcm = _samplesToBytes(G711.decode(_bytesToSamples(frame.payload)));
    }
    upFrames++;
    await b
        .injectUplink(uplinkMuted ? List<int>.filled(pcm.length, 0) : pcm)
        .catchError((_) {});
  }

  /// Packet-loss concealment for a missing frame. Opus PLC needs the
  /// native decoder and is not exposed by the plugin, so Opus gaps
  /// are skipped (the iPhone's playout buffer conceals them); µ-law
  /// silence is 0xFF per byte.
  List<int>? _conceal(String codecName) {
    if (codecName == 'opus') return null;
    return List<int>.filled(160, 0xff); // 20 ms @ 8 kHz µ-law
  }

  static List<int> _bytesToSamples(List<int> bytes) {
    final samples = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      var s = (bytes[i] & 0xff) | ((bytes[i + 1] & 0xff) << 8);
      if (s >= 0x8000) s -= 0x10000;
      samples.add(s);
    }
    return samples;
  }

  static List<int> _samplesToBytes(List<int> samples) {
    final bytes = <int>[];
    for (final s in samples) {
      bytes.add(s & 0xff);
      bytes.add((s >> 8) & 0xff);
    }
    return bytes;
  }

  static List<int> _pcmBytesToUlaw(List<int> pcmBytes) =>
      G711.encode(_bytesToSamples(pcmBytes));
}
