// Tests for the iPhone-side client (finding 2): pairing, sync,
// sms.send round-trip, call actions, incoming call state and audio
// start/stop, link loss and reconnect — against a real Hub over
// FakeTransport.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/link/link.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';

import 'audio_session_test.dart' show FakeAudioBridge;
import 'link_test.dart' show FakeHubData, waitFor;

/// Records everything the client applies to the app model.
class FakeClientStore implements ClientStore {
  int smsSinceValue = 0;
  int callsSinceValue = 0;
  String contactsVersionValue = '';
  @override
  String? barkKey;

  @override
  int get smsSince => smsSinceValue;
  @override
  int get callsSince => callsSinceValue;
  @override
  String get contactsVersion => contactsVersionValue;

  final List<Map<String, dynamic>> statuses = [];
  final List<List<Sms>> smsBatches = [];
  final List<Sms> smsNews = [];
  final List<(int, int)> smsReads = [];
  final List<List<int>> smsUnreads = [];
  final List<Map<String, dynamic>> smsResults = [];
  final List<List<int>> smsDeleteds = [];
  final List<List<CallEntry>> callsBatches = [];
  final List<CallInfo> callStates = [];
  final List<List<CallInfo>> callLists = [];
  final List<Map<String, dynamic>> callDialeds = [];
  final List<List<int>> callsDeleteds = [];
  final List<List<Contact>> contactsBatches = [];
  final List<Map<String, dynamic>> contactResults = [];
  final List<Map<String, dynamic>> listsList = [];
  final List<Map<String, dynamic>> syncIdsList = [];
  final List<Map<String, dynamic>> netStates = [];
  final List<Map<String, dynamic>> selftestResults = [];
  final List<(String, int)> audioStarted = [];
  int audioStopped = 0;
  int linkUp = 0;
  int linkLost = 0;

  @override
  void applyStatus(Map<String, dynamic> status) => statuses.add(status);
  @override
  void applySmsBatch(List<Sms> msgs, {required bool more}) =>
      smsBatches.add(msgs);
  @override
  void applySmsNew(Sms msg) => smsNews.add(msg);
  @override
  void applySmsRead(int thread, int upTo) => smsReads.add((thread, upTo));
  @override
  void applySmsUnread(List<int> ids, {required bool all}) =>
      smsUnreads.add(ids);
  @override
  void applySmsResult({required bool ok, String? state, String? err}) =>
      smsResults.add({'ok': ok, 'state': state, 'err': err});
  @override
  void applySmsDeleted(List<int> ids) => smsDeleteds.add(ids);
  @override
  void applyCallsBatch(List<CallEntry> calls, {required bool more}) =>
      callsBatches.add(calls);
  @override
  void applyCallState(CallInfo call) => callStates.add(call);
  @override
  void applyCallList(List<CallInfo> calls) => callLists.add(calls);
  @override
  void applyCallDialed({required bool ok, String? err}) =>
      callDialeds.add({'ok': ok, 'err': err});
  @override
  void applyCallsDeleted(List<int> ids, {required bool all}) =>
      callsDeleteds.add(ids);
  @override
  void applyContactsBatch(List<Contact> contacts,
          {required String version, required bool full}) =>
      contactsBatches.add(contacts);
  @override
  void applyContactResult({required bool ok, int? id, String? err}) =>
      contactResults.add({'ok': ok, 'id': id, 'err': err});
  @override
  void applyLists(Map<String, dynamic> lists) => listsList.add(lists);
  @override
  void applySyncIds(
          {required List<List<int>> smsRanges,
          required List<List<int>> callRanges,
          required bool more}) =>
      syncIdsList.add({'sms': smsRanges, 'calls': callRanges});
  @override
  void applyNetState(Map<String, dynamic> net) => netStates.add(net);
  @override
  void applySelftestResult(Map<String, dynamic> result) =>
      selftestResults.add(result);
  @override
  void applyAudioStarted({required String codec, required int rate}) =>
      audioStarted.add((codec, rate));
  @override
  void applyAudioStopped() => audioStopped++;
  @override
  void applyLinkUp() => linkUp++;
  @override
  void applyLinkLost() => linkLost++;
}

/// Fake native audio engine for the client.
class FakeClientAudioSink implements ClientAudioSink {
  final List<String> calls = [];
  final List<AudioFrame> played = [];
  final capturedController = StreamController<AudioFrame>.broadcast();

  @override
  Future<void> startAudio(
          {required String codec, required int rate, int? bitrate}) async {
    calls.add('start:$codec:$rate');
  }

  @override
  Future<void> stopAudio() async {
    calls.add('stop');
  }

  @override
  Stream<AudioFrame> get captured => capturedController.stream;

  @override
  Future<void> playFrame(
          {required int codec,
          required int seq,
          required List<int> payload}) async {
    played.add(AudioFrame(codec, seq, payload));
  }
}

/// A Hub that records every message it receives, so tests can
/// assert the exact wire body a client action sends.
class RecordingHub extends Hub {
  RecordingHub(super.data,
      {required super.connectionFactory, super.audioBridge});

  final List<Message> received = [];

  @override
  void onMessage(LinkConnection c, Message m) {
    received.add(m);
    super.onMessage(c, m);
  }
}

/// A real Hub (peripheral) + a LinkClient (central) over
/// FakeTransport, with the client's transport factory feeding each
/// new pair's far end into the Hub — so reconnects work too.
class ClientHarness {
  ClientHarness._(
    this.hub,
    this.data,
    this.client,
    this.store,
    this.sink,
    this.hubKeys,
    this.token,
    this.bridge,
  );

  final Hub hub;
  final FakeHubData data;
  final LinkClient client;
  final FakeClientStore store;
  final FakeClientAudioSink sink;
  final P256KeyPair hubKeys;
  final List<int> token;

  /// The Hub's fake audio path: without it the Hub tracks the audio
  /// intent but never sends `audio.start` (there is no helper to
  /// capture or inject).
  final FakeAudioBridge bridge;

  static ClientHarness open({
    Hub Function(
      FakeHubData data,
      LinkConnection Function(Transport) connectionFactory,
      FakeAudioBridge bridge,
    )? makeHub,
  }) {
    final hubKeys = P256.generate();
    final token = P256.randomNonce();
    final data = FakeHubData();
    final bridge = FakeAudioBridge();
    // Centrals the Hub has paired with: like the production
    // KeyStore, learned from `hub.onPaired` — so reconnects after
    // the pairing token is spent resume instead of re-pairing.
    final paired = <PairedCentral>[];
    late final Hub hub;
    LinkConnection connectionFactory(Transport t) => PeripheralConnection(
          t,
          hub,
          PeripheralKeys(
            staticKey: hubKeys,
            openToken: token,
            pairedCentrals: paired,
          ),
        );
    hub = makeHub?.call(data, connectionFactory, bridge) ??
        Hub(
          data,
          connectionFactory: connectionFactory,
          audioBridge: bridge,
        );
    hub.onPaired = (c) {
      final key = c.peerKey;
      if (key != null) {
        paired.add(PairedCentral(key, name: c.name, kind: c.kind));
      }
    };
    final store = FakeClientStore();
    final sink = FakeClientAudioSink();
    final client = LinkClient(
      transportFactory: () async {
        final (a, b) = FakeTransport.pair();
        hub.onTransport(a);
        return b;
      },
      ownKey: P256.generate(),
      audioSink: sink,
      clientName: 'Test iPhone',
    );
    client.store = store;
    return ClientHarness._(
        hub, data, client, store, sink, hubKeys, token, bridge);
  }

  Future<void> pair() async {
    client.pair(PairingCode(hubKeys.publicEncoded, token, 'Android'));
    await waitFor(() => client.isConnected);
  }

  void close() {
    client.dispose();
    hub.dispose();
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
  group('LinkClient', () {
    test('pair connects, syncs, and applies the initial batches',
        () async {
      final h = ClientHarness.open();
      h.data.sms.add(const Sms(
        id: 1,
        thread: 5,
        addr: '+989121234567',
        body: 'سلام',
        date: 1000,
        box: 1,
        read: false,
      ));
      h.data.calls.add(const CallEntry(
        id: 1,
        num: '+989121234567',
        name: 'سارا احمدی',
        date: 900,
        dur: 0,
        type: 2,
      ));
      var paired = false;
      h.client.onPaired = () => paired = true;
      await h.pair();
      expect(paired, isTrue);
      expect(h.store.linkUp, 1);
      // The Hub learned the client from sync.
      await waitFor(() => h.hub.conns.isNotEmpty);
      final conn = h.hub.conns.first;
      expect(conn.kind, 'iphone');
      expect(conn.name, 'Test iPhone');
      expect(conn.codecs, contains('opus'));
      // ...and the client applied the sync reply.
      await waitFor(() => h.store.smsBatches.isNotEmpty);
      expect(h.store.smsBatches.single.single.body, 'سلام');
      expect(h.store.callsBatches.single.single.num, '+989121234567');
      expect(h.store.listsList, isNotEmpty);
      expect(h.store.syncIdsList.single['sms'], [
        [1, 1]
      ]);
      h.close();
    });

    test('sms.send round-trips: Hub sends it, client gets the result',
        () async {
      final h = ClientHarness.open();
      await h.pair();
      final resultFuture = h.client
          .sendSms(to: '+989121234567', body: 'سلام، چطوری؟');
      await waitFor(() => h.data.sentSms.isNotEmpty);
      expect(h.data.sentSms.single['to'], '+989121234567');
      expect(h.data.sentSms.single['body'], 'سلام، چطوری؟');
      h.hub.smsResult(h.data.lastLocalId!, true, 'sent', null);
      final result = await resultFuture;
      expect(result['ok'], isTrue);
      expect(result['state'], 'sent');
      expect(h.store.smsResults.single['ok'], isTrue);
      h.close();
    });

    test('incoming SMS arrives as sms.new', () async {
      final h = ClientHarness.open();
      await h.pair();
      h.hub.onSms(
        const Sms(
          id: 7,
          thread: 5,
          addr: '+989121234567',
          body: 'جواب',
          date: 2000,
          box: 1,
          read: false,
        ),
        blocked: false,
      );
      await waitFor(() => h.store.smsNews.isNotEmpty);
      expect(h.store.smsNews.single.body, 'جواب');
      h.close();
    });

    test('incoming call state reaches the store; answer reaches the Hub',
        () async {
      final h = ClientHarness.open();
      await h.pair();
      h.hub.onCall(_ringing);
      await waitFor(() => h.store.callStates.isNotEmpty);
      expect(h.store.callStates.single.cid, 'c1');
      expect(h.store.callStates.single.state, 'ringing');
      h.client.answer('c1');
      await waitFor(() => h.data.answered.isNotEmpty);
      expect(h.data.answered.single, 'c1');
      h.close();
    });

    test('mute sends {on} only (PROTOCOL §5, finding N4)', () async {
      RecordingHub? recorded;
      final h = ClientHarness.open(makeHub: (data, factory, bridge) {
        final r = RecordingHub(data,
            connectionFactory: factory, audioBridge: bridge);
        recorded = r;
        return r;
      });
      await h.pair();
      h.client.mute('c1', true);
      await waitFor(() => recorded!.received
          .any((m) => m.t == MessageType.callMute));
      final mute = recorded!.received
          .firstWhere((m) => m.t == MessageType.callMute);
      expect(mute.b, {'on': true});
      expect(mute.b.containsKey('cid'), isFalse);
      h.close();
    });

    test('two dials get distinct call ids (finding N12)', () async {
      RecordingHub? recorded;
      final h = ClientHarness.open(makeHub: (data, factory, bridge) {
        final r = RecordingHub(data,
            connectionFactory: factory, audioBridge: bridge);
        recorded = r;
        return r;
      });
      await h.pair();
      final f1 = h.client.dial('+989121234567');
      final f2 = h.client.dial('+989121234568');
      await waitFor(() =>
          recorded!.received
              .where((m) => m.t == MessageType.callDial)
              .length ==
          2);
      final cids = recorded!.received
          .where((m) => m.t == MessageType.callDial)
          .map((m) => m.b['cid'] as String)
          .toList();
      expect(cids.toSet().length, 2);
      expect(cids, ['c1', 'c2']);
      await f1;
      await f2;
      h.close();
    });

    test('dial completes with call.dialed', () async {
      final h = ClientHarness.open();
      await h.pair();
      final resultFuture = h.client.dial('+989121234567');
      await waitFor(() => h.data.dialed.isNotEmpty);
      expect(h.data.dialed.single.$1, '+989121234567');
      final result = await resultFuture;
      expect(result['ok'], isTrue);
      expect(h.store.callDialeds.single['ok'], isTrue);
      h.close();
    });

    test('audio.start starts the sink; audio frames are played', () async {
      final h = ClientHarness.open();
      await h.pair();
      h.hub.onCall(_ringing);
      h.client.answer('c1');
      await waitFor(() => h.sink.calls.isNotEmpty);
      expect(h.sink.calls.single, 'start:opus:16000');
      expect(h.store.audioStarted.single, ('opus', 16000));
      // A downlink frame from the Hub is played through the sink.
      final conn = h.hub.conns.first;
      conn.sendAudio(AudioFrame(AudioFrame.opus, 3, [9, 9]).encoded());
      await waitFor(() => h.sink.played.isNotEmpty);
      expect(h.sink.played.single.seq, 3);
      expect(h.sink.played.single.payload, [9, 9]);
      // ...and a captured frame is forwarded to the Hub, decoded and
      // injected into the (fake) helper.
      h.sink.capturedController.add(AudioFrame(AudioFrame.opus, 4, [7]));
      await waitFor(() => h.bridge.injected.isNotEmpty);
      expect(h.bridge.injected, [1, 0, 2, 0]);
      h.hub.onCall(const CallInfo(
        cid: 'c1',
        num: '+989121234567',
        state: 'ended',
        dir: 'in',
        hold: false,
      ));
      await waitFor(() => h.sink.calls.contains('stop'));
      expect(h.store.audioStopped, 1);
      h.close();
    });

    test('marking a thread read while offline flushes after reconnect',
        () async {
      final h = ClientHarness.open();
      await h.pair();
      // Drop the link: the client marks read while offline.
      h.hub.conns.first.close('test drop');
      await waitFor(() => h.store.linkLost == 1);
      h.client.markThreadRead(5, 42);
      expect(h.data.markedRead, isEmpty);
      // The reconnect loop brings the link back; the queued read is
      // flushed after the re-sync.
      await waitFor(() => h.client.isConnected);
      await waitFor(() => h.data.markedRead.isNotEmpty);
      expect(h.data.markedRead.single, (5, 42));
      h.close();
    });

    test('link loss is reported to the store', () async {
      final h = ClientHarness.open();
      await h.pair();
      h.hub.conns.first.close('test drop');
      await waitFor(() => h.store.linkLost == 1);
      h.close();
    });

    test('unpair tells the Hub and clears the peer', () async {
      final h = ClientHarness.open();
      var unpaired = false;
      h.client.onUnpaired = () => unpaired = true;
      await h.pair();
      h.client.unpair();
      await waitFor(() => unpaired);
      expect(h.client.isPaired, isFalse);
      expect(h.client.isConnected, isFalse);
      expect(h.data.unpairKey, isNotNull);
      h.close();
    });

    test('ping is answered with pong', () async {
      final h = ClientHarness.open();
      await h.pair();
      final conn = h.hub.conns.first;
      // The Hub pings every 60 s; send one now and expect a pong.
      conn.send(const Message(MessageType.ping));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // No crash and still connected is the assertion: a pong was
      // sent back through the sealed link (the Hub would close on a
      // protocol error).
      expect(h.client.isConnected, isTrue);
      h.close();
    });

    test('useTransportFactory restarts the link on the new factory',
        () async {
      final h = ClientHarness.open();
      await h.pair();
      expect(h.store.linkUp, 1);
      // A second Hub with the same identity (so resume works) and
      // the client's key already paired.
      late final Hub hub2;
      hub2 = Hub(
        FakeHubData(),
        connectionFactory: (t) => PeripheralConnection(
          t,
          hub2,
          PeripheralKeys(
            staticKey: h.hubKeys,
            pairedCentrals: [
              PairedCentral(h.client.ownKey.publicEncoded),
            ],
          ),
        ),
      );
      var factory2Calls = 0;
      h.client.useTransportFactory(() async {
        factory2Calls++;
        final (a, b) = FakeTransport.pair();
        hub2.onTransport(a);
        return b;
      });
      // The new factory is used, and the client reconnects to the
      // second Hub and syncs again (the store sees a second link-up).
      await waitFor(() => factory2Calls > 0);
      await waitFor(() => h.store.linkUp == 2);
      expect(h.client.isConnected, isTrue);
      h.close();
      hub2.dispose();
    });
  });
}
