// Tests for the link layer: transports, handshake + sealed records
// above any transport, and Hub routing. No native code, no Gradle:
// everything runs on the Dart VM.
import 'dart:io' show InternetAddress, ServerSocket;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/bark/bark.dart';
import 'package:sim_bridge/src/link/link.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';

Future<void> waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A listener that records everything, for tests.
class CollectingListener implements ConnectionListener {
  final List<(LinkConnection, bool)> established = [];
  final List<(LinkConnection, Message)> messages = [];
  final List<(LinkConnection, List<int>)> audio = [];
  final List<LinkConnection> closed = [];

  @override
  bool admits(LinkConnection c) => true;

  @override
  void onEstablished(LinkConnection c, bool newlyPaired) {
    established.add((c, newlyPaired));
  }

  @override
  void onMessage(LinkConnection c, Message m) {
    messages.add((c, m));
  }

  @override
  void onAudio(LinkConnection c, List<int> payload) {
    audio.add((c, payload));
  }

  @override
  void onClosed(LinkConnection c) {
    closed.add(c);
  }
}

/// A transport wrapper that can inspect / mutate outgoing bytes.
class TapTransport implements Transport {
  TapTransport(this.inner);

  final FakeTransport inner;

  List<int> Function(List<int> bytes)? tapWrite;

  @override
  String get label => inner.label;

  @override
  String get address => inner.address;

  @override
  bool get dry => inner.dry;

  @override
  void start(void Function(List<int> bytes, int length) onBytes,
          void Function() onClosed) =>
      inner.start(onBytes, onClosed);

  @override
  void write(List<int> bytes) {
    final out = tapWrite?.call(List<int>.of(bytes)) ?? bytes;
    inner.write(out);
  }

  @override
  void close() => inner.close();
}

void main() {
  // Needed for the CallKit / secure-storage channel mocks below.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FakeTransport', () {
    test('pair round-trips bytes', () async {
      final (a, b) = FakeTransport.pair();
      final received = <List<int>>[];
      var closed = false;
      b.start((bytes, n) => received.add(bytes.sublist(0, n)), () {
        closed = true;
      });
      a.start((_, _) {}, () {});
      a.write([1, 2, 3]);
      a.write([4, 5]);
      await waitFor(() => received.length == 2);
      expect(received[0], [1, 2, 3]);
      expect(received[1], [4, 5]);
      expect(closed, isFalse);
    });

    test('closing one side notifies the other', () async {
      final (a, b) = FakeTransport.pair();
      var bClosed = false;
      var aClosed = false;
      a.start((_, _) {}, () {
        aClosed = true;
      });
      b.start((_, _) {}, () {
        bClosed = true;
      });
      a.close();
      await waitFor(() => bClosed && aClosed);
      expect(a.isClosed, isTrue);
      expect(() => a.write([1]), throwsStateError);
    });
  });

  group('TcpTransport', () {
    test('round-trips bytes over loopback', () async {
      final server =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final client = await TcpTransport.connect(
          '127.0.0.1', server.port);
      final serverSide = TcpTransport.fromSocket(await accepted);
      final serverReceived = <List<int>>[];
      final clientReceived = <List<int>>[];
      serverSide.start(
          (b, n) => serverReceived.add(b.sublist(0, n)), () {});
      client.start((b, n) => clientReceived.add(b.sublist(0, n)), () {});
      client.write([9, 8, 7]);
      serverSide.write([1, 2]);
      await waitFor(
          () => serverReceived.isNotEmpty && clientReceived.isNotEmpty);
      expect(serverReceived.first, [9, 8, 7]);
      expect(clientReceived.first, [1, 2]);
      client.close();
      serverSide.close();
      await server.close();
    });
  });

  group('handshake over FakeTransport', () {
    late P256KeyPair peripheralKeys;
    late P256KeyPair centralKeys;
    late List<int> token;

    setUp(() {
      peripheralKeys = P256.generate();
      centralKeys = P256.generate();
      token = P256.randomNonce();
    });

    Future<(PeripheralConnection, CentralConnection, CollectingListener,
        CollectingListener)> openPair() async {
      final (a, b) = FakeTransport.pair();
      final pListener = CollectingListener();
      final cListener = CollectingListener();
      final peripheral = PeripheralConnection(
        a,
        pListener,
        PeripheralKeys(
            staticKey: peripheralKeys, openToken: token),
      );
      final central = CentralConnection(
        b,
        cListener,
        CentralKeys(
          staticKey: centralKeys,
          peerStatic: peripheralKeys.publicEncoded,
          token: token,
        ),
      );
      peripheral.start();
      central.start();
      await waitFor(() => peripheral.isUp && central.isUp);
      return (peripheral, central, pListener, cListener);
    }

    test('pair mode establishes both directions', () async {
      final (peripheral, central, pListener, cListener) = await openPair();
      expect(pListener.established, hasLength(1));
      expect(pListener.established.first.$2, isTrue); // newly paired
      expect(cListener.established, hasLength(1));
      expect(peripheral.peerKey, centralKeys.publicEncoded);
      expect(central.peerKey, peripheralKeys.publicEncoded);
      peripheral.close();
      central.close();
    });

    test('sealed control messages flow both ways', () async {
      final (peripheral, central, pListener, cListener) = await openPair();
      central.send(Message(MessageType.ping, b: {'ts': 42}, id: 7));
      await waitFor(() => pListener.messages.isNotEmpty);
      final received = pListener.messages.single.$2;
      expect(received.t, MessageType.ping);
      expect(received.b['ts'], 42);
      expect(received.id, 7);
      peripheral.send(Message(MessageType.pong, b: {'ts': 42}, re: 7));
      await waitFor(() => cListener.messages.isNotEmpty);
      expect(cListener.messages.single.$2.t, MessageType.pong);
      expect(cListener.messages.single.$2.re, 7);
      peripheral.close();
      central.close();
    });

    test('audio frames arrive on the audio channel', () async {
      final (peripheral, central, pListener, _) = await openPair();
      central.sendAudio([1, 0, 5, 10, 20, 30]);
      await waitFor(() => pListener.audio.isNotEmpty);
      expect(pListener.audio.single.$2, [1, 0, 5, 10, 20, 30]);
      peripheral.close();
      central.close();
    });

    test('unknown message type is delivered, link stays up', () async {
      final (peripheral, central, pListener, _) = await openPair();
      central.send(const Message('no.such.type'));
      await waitFor(() => pListener.messages.isNotEmpty);
      // The link layer delivers every control message to its
      // listener; ignoring unknown types is the Hub's job (its
      // `default:` case). The link itself must stay up.
      expect(pListener.messages.single.$2.t, 'no.such.type');
      expect(peripheral.isUp, isTrue);
      expect(central.isUp, isTrue);
      peripheral.close();
      central.close();
    });

    test('resume mode works for a paired central', () async {
      final (a, b) = FakeTransport.pair();
      final pListener = CollectingListener();
      final cListener = CollectingListener();
      final peripheral = PeripheralConnection(
        a,
        pListener,
        PeripheralKeys(
          staticKey: peripheralKeys,
          pairedCentrals: [PairedCentral(centralKeys.publicEncoded)],
        ),
      );
      final central = CentralConnection(
        b,
        cListener,
        CentralKeys(
          staticKey: centralKeys,
          peerStatic: peripheralKeys.publicEncoded,
        ),
      );
      peripheral.start();
      central.start();
      await waitFor(() => peripheral.isUp && central.isUp);
      expect(pListener.established.single.$2, isFalse);
      peripheral.close();
      central.close();
    });

    test('pair mode with no token is rejected', () async {
      final (a, b) = FakeTransport.pair();
      final pListener = CollectingListener();
      final cListener = CollectingListener();
      final peripheral = PeripheralConnection(
        a,
        pListener,
        PeripheralKeys(staticKey: peripheralKeys),
      );
      final central = CentralConnection(
        b,
        cListener,
        CentralKeys(
          staticKey: centralKeys,
          peerStatic: peripheralKeys.publicEncoded,
          token: token,
        ),
      );
      peripheral.start();
      central.start();
      await waitFor(() => cListener.closed.isNotEmpty);
      expect(peripheral.isUp, isFalse);
      expect(central.isUp, isFalse);
      expect(cListener.established, isEmpty);
      peripheral.close();
    });

    test('tampered sealed record closes the link', () async {
      final (rawA, rawB) = FakeTransport.pair();
      final tap = TapTransport(rawB);
      var sealedSeen = 0;
      tap.tapWrite = (bytes) {
        // Flip a byte inside the first sealed record's ciphertext.
        if (bytes.length > 3 &&
            bytes[2] == RecordKind.sealed &&
            sealedSeen++ == 0) {
          final tampered = List<int>.of(bytes);
          tampered[tampered.length - 5] ^= 0xff;
          return tampered;
        }
        return bytes;
      };
      final pListener = CollectingListener();
      final cListener = CollectingListener();
      final peripheral = PeripheralConnection(
        rawA,
        pListener,
        PeripheralKeys(
            staticKey: peripheralKeys, openToken: token),
      );
      final central = CentralConnection(
        tap,
        cListener,
        CentralKeys(
          staticKey: centralKeys,
          peerStatic: peripheralKeys.publicEncoded,
          token: token,
        ),
      );
      peripheral.start();
      central.start();
      // The FIN is the first sealed record: tampering breaks its auth
      // tag, so the peripheral must drop the link.
      await waitFor(() => pListener.closed.isNotEmpty);
      expect(peripheral.isUp, isFalse);
      central.close();
    });

    test('replayed sealed record closes the link', () async {
      final (rawA, rawB) = FakeTransport.pair();
      final tap = TapTransport(rawB);
      final captured = <List<int>>[];
      tap.tapWrite = (bytes) {
        if (bytes.length > 3 && bytes[2] == RecordKind.sealed) {
          captured.add(List<int>.of(bytes));
        }
        return bytes;
      };
      final pListener = CollectingListener();
      final cListener = CollectingListener();
      final peripheral = PeripheralConnection(
        rawA,
        pListener,
        PeripheralKeys(
            staticKey: peripheralKeys, openToken: token),
      );
      final central = CentralConnection(
        tap,
        cListener,
        CentralKeys(
          staticKey: centralKeys,
          peerStatic: peripheralKeys.publicEncoded,
          token: token,
        ),
      );
      peripheral.start();
      central.start();
      await waitFor(() => peripheral.isUp && central.isUp);
      expect(captured, isNotEmpty);
      // Replay the first sealed record (the FIN): its counter is
      // already spent, so the peripheral must reject it.
      tap.tapWrite = null;
      rawB.write(captured.first);
      await waitFor(() => pListener.closed.isNotEmpty);
      expect(peripheral.isUp, isFalse);
      central.close();
    });

    test('handshake timeout closes a silent peer', () async {
      final (a, b) = FakeTransport.pair();
      final pListener = CollectingListener();
      final peripheral = PeripheralConnection(
        a,
        pListener,
        PeripheralKeys(staticKey: peripheralKeys, openToken: token),
        handshakeTimeout: const Duration(milliseconds: 200),
      );
      peripheral.start();
      // b is never started: no HELLO ever arrives.
      await waitFor(() => pListener.closed.isNotEmpty);
      expect(peripheral.isUp, isFalse);
      b.close();
    });
  });

  group('Backoff', () {
    test('exponential with cap, resets', () {
      final backoff = Backoff(
        base: const Duration(seconds: 1),
        max: const Duration(seconds: 5),
      );
      expect(backoff.next(), const Duration(seconds: 1));
      expect(backoff.next(), const Duration(seconds: 2));
      expect(backoff.next(), const Duration(seconds: 4));
      expect(backoff.next(), const Duration(seconds: 5));
      expect(backoff.next(), const Duration(seconds: 5));
      backoff.reset();
      expect(backoff.next(), const Duration(seconds: 1));
    });
  });

  group('ReconnectingLink', () {
    test('reconnects after a drop, then stops', () async {
      final peripheralKeys = P256.generate();
      final centralKeys = P256.generate();
      final token = P256.randomNonce();
      // The peripheral side: one long-lived listener/connection.
      final (pA, pB) = FakeTransport.pair();
      final pListener = CollectingListener();
      final peripheral = PeripheralConnection(
        pA,
        pListener,
        PeripheralKeys(staticKey: peripheralKeys, openToken: token),
      );
      peripheral.start();
      var attempts = 0;
      final peers = <FakeTransport>[];
      final link = ReconnectingLink(
        transportFactory: () async {
          attempts++;
          // Fresh pair per attempt; the peer side is never started,
          // so each attempt dies on the (short) handshake timeout
          // and the loop retries. This proves the retry loop and
          // stop() — a real reconnect over one pipe needs a shared
          // transport, which FakeTransport pairs cannot express.
          final (a, b) = FakeTransport.pair();
          peers.add(b);
          return a;
        },
        connectionFactory: (t) => CentralConnection(
          t,
          CollectingListener(),
          CentralKeys(
            staticKey: centralKeys,
            peerStatic: peripheralKeys.publicEncoded,
            token: token,
          ),
          handshakeTimeout: const Duration(milliseconds: 200),
        ),
        listener: CollectingListener(),
      );
      link.start();
      await waitFor(() => attempts >= 2);
      expect(link.isUp, isFalse);
      link.stop();
      final attemptsAtStop = attempts;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(attempts, attemptsAtStop);
      peripheral.close();
      pB.close();
      for (final peer in peers) {
        peer.close();
      }
    });
  });

  hubTests();
  hubNetTests();
  callKitHubTests();
  barkHubTests();
}

/// Fake phone-side data for Hub tests.
class FakeHubData implements HubData {
  List<Sms> sms = [];
  List<CallEntry> calls = [];
  List<Contact> contacts = [];
  String version = 'v1';
  List<int> unread = [];

  /// When true, `unreadSmsIds` returns null (provider unreadable).
  bool unreadNull = false;
  Map<String, dynamic> status = {'device': 'test'};
  Map<String, dynamic> lists = {
    'blocked': <String>[],
    'muted': <int>[],
    'system': false,
  };

  final List<String> answered = [];
  final List<String> rejected = [];
  final List<String> ended = [];
  final List<(String, bool)> held = [];
  final List<(String, String)> dialed = [];
  final List<(String, String)> dtmfs = [];
  final List<Map<String, dynamic>> sentSms = [];
  final List<(int, int)> markedRead = [];
  int? lastLocalId;
  List<int>? unpairKey;

  @override
  Future<List<Sms>> smsSince(int sinceId) async =>
      sms.where((s) => s.id > sinceId).toList();

  @override
  Future<List<CallEntry>> callsSince(int sinceId) async =>
      calls.where((c) => c.id > sinceId).toList();

  @override
  Future<List<Contact>> contactsAll() async => List.of(contacts);

  @override
  String contactsVersion() => version;

  @override
  Future<List<int>> smsAllIds() async => sms.map((s) => s.id).toList();

  @override
  Future<List<int>> callAllIds() async =>
      calls.map((c) => c.id).toList();

  @override
  Future<List<int>?> unreadSmsIds() async =>
      unreadNull ? null : List.of(unread);

  @override
  Future<Map<String, dynamic>> statusJson() async =>
      Map<String, dynamic>.of(status);

  @override
  Future<String?> sendSms({
    required String to,
    required String body,
    int? sub,
    required int localId,
    bool dry = false,
  }) async {
    lastLocalId = localId;
    sentSms.add({'to': to, 'body': body, 'sub': sub, 'dry': dry});
    return null;
  }

  @override
  Future<int> markSmsRead(int thread, int upTo) async {
    markedRead.add((thread, upTo));
    return 1;
  }

  @override
  Future<List<int>?> deleteSms(List<int> ids, int? thread) async =>
      List.of(ids);

  @override
  Future<int> deleteCalls(List<int>? ids) async => ids?.length ?? 0;

  /// Rows changed by the last star/unstar (-1 = refused); the test
  /// sets it to fail the next star.
  int starResult = 1;

  @override
  Future<int> setContactStarred(int id, bool on) async => starResult;

  @override
  Future<int> addContact(
          String name, List<Phone> phones, List<String> emails) async =>
      99;

  @override
  Future<String?> updateContact(
          int id, String name, List<Phone> phones, List<String> emails) async =>
      null;

  @override
  Future<Map<String, dynamic>> listsJson() async =>
      Map<String, dynamic>.of(lists);

  @override
  Future<Map<String, dynamic>> setLists(String what,
          {String? num, int? thread, required bool on}) async =>
      Map<String, dynamic>.of(lists);

  @override
  Future<void> answerCall(String cid) async {
    answered.add(cid);
  }

  @override
  Future<void> rejectCall(String cid) async {
    rejected.add(cid);
  }

  @override
  Future<void> endCall(String cid) async {
    ended.add(cid);
  }

  @override
  Future<void> holdCall(String cid, bool on) async {
    held.add((cid, on));
  }

  @override
  Future<String?> dial(String num, int? sub) async {
    dialed.add((num, sub?.toString() ?? ''));
    return null;
  }

  @override
  Future<void> dtmf(String cid, String digit) async {
    dtmfs.add((cid, digit));
  }

  /// Every netControl call, in order (for the net.set tests).
  final List<Map<String, dynamic>> netControls = [];

  @override
  Future<Map<String, dynamic>?> netControl({
    String? what,
    bool on = false,
    int? sub,
    int? slot,
    String? mode,
  }) async {
    netControls.add({
      'what': what,
      'on': on,
      'sub': sub,
      'slot': slot,
      'mode': mode,
    });
    return {'share': false, 'proxy': <String, dynamic>{}};
  }

  @override
  Future<Map<String, dynamic>> selftest() async => {'methods': []};

  @override
  void unpair(List<int> peerKey) {
    unpairKey = peerKey;
  }
}

/// A Hub wired to a central-side test client over fake transports.
class HubHarness {
  HubHarness._(this.hub, this.client, this.clientListener, this.data,
      this.peripheral, this.central);

  final Hub hub;
  final CentralConnection client;
  final CollectingListener clientListener;
  final FakeHubData data;
  final PeripheralConnection peripheral;
  final CentralConnection central;

  static Future<HubHarness> open({
    FarWakeNotifier? farWake,
    CallKitBridge? callKit,
    Duration airplaneFailSafeInterval = const Duration(seconds: 15),
    Duration airplaneFailSafeGrace = const Duration(seconds: 90),
    AirplaneFailSafeStore? airplaneStore,
  }) async {
    final peripheralKeys = P256.generate();
    final centralKeys = P256.generate();
    final token = P256.randomNonce();
    final data = FakeHubData();
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
      farWake: farWake,
      callKit: callKit,
      airplaneFailSafeInterval: airplaneFailSafeInterval,
      airplaneFailSafeGrace: airplaneFailSafeGrace,
      airplaneStore: airplaneStore,
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
    return HubHarness._(
        hub, central, clientListener, data, peripheral!, central);
  }

  Future<void> close() async {
    hub.stopTimers();
    central.close();
    peripheral.close();
  }
}

void hubTests() {
  group('Hub routing', () {
    test('ping is answered with pong', () async {
      final h = await HubHarness.open();
      h.client.send(Message(MessageType.ping, b: {'ts': 123}, id: 7));
      await waitFor(() => h.clientListener.messages
          .any((e) => e.$2.t == MessageType.pong));
      final pong = h.clientListener.messages
          .firstWhere((e) => e.$2.t == MessageType.pong)
          .$2;
      expect(pong.t, MessageType.pong);
      expect(pong.b['ts'], 123);
      expect(pong.re, 7);
      await h.close();
    });

    test('unknown message type is ignored by the Hub', () async {
      final h = await HubHarness.open();
      final before = h.clientListener.messages.length;
      h.client.send(const Message('no.such.type'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(h.clientListener.messages.length, before);
      expect(h.peripheral.isUp, isTrue);
      await h.close();
    });

    test('sync sends sms/calls/contacts batches and ids', () async {
      final h = await HubHarness.open();
      h.data.sms = [
        const Sms(
            id: 1,
            thread: 1,
            addr: '+98912',
            body: 'hi',
            date: 1000,
            box: 1,
            read: false),
        const Sms(
            id: 2,
            thread: 1,
            addr: '+98912',
            body: 'yo',
            date: 2000,
            box: 1,
            read: false),
      ];
      h.data.calls = [
        const CallEntry(
            id: 5, num: '+98912', date: 1000, dur: 30, type: 1),
      ];
      h.data.contacts = [
        const Contact(
            id: 1,
            name: 'Ali',
            phones: [Phone('+98912', 'mobile')],
            emails: [],
            starred: false),
      ];
      h.client.send(Message(MessageType.sync, b: {
        'sms': 0,
        'calls': 0,
        'contacts': '',
        'codecs': ['opus', 'pcmu'],
        'client': {'kind': 'iphone', 'name': 'Test iPhone'},
      }));
      await waitFor(() => h.clientListener.messages.length >= 6);
      final types =
          h.clientListener.messages.map((e) => e.$2.t).toList();
      expect(types, contains(MessageType.smsBatch));
      expect(types, contains(MessageType.callsBatch));
      expect(types, contains(MessageType.contactsBatch));
      expect(types, contains(MessageType.syncIds));
      expect(types, contains(MessageType.lists));
      expect(types, contains(MessageType.smsUnread));
      final smsBatch = h.clientListener.messages
          .firstWhere((e) => e.$2.t == MessageType.smsBatch)
          .$2;
      expect((smsBatch.b['items'] as List).length, 2);
      expect(smsBatch.b['more'], isFalse);
      await h.close();
    });

    test('sync sends no sms.unread when the provider is unreadable',
        () async {
      final h = await HubHarness.open();
      h.data.unreadNull = true;
      h.client.send(Message(MessageType.sync, b: {
        'sms': 0,
        'calls': 0,
        'contacts': '',
        'codecs': ['opus', 'pcmu'],
        'client': {'kind': 'iphone', 'name': 'Test iPhone'},
      }));
      await waitFor(() => h.clientListener.messages.length >= 5);
      final types =
          h.clientListener.messages.map((e) => e.$2.t).toList();
      // Everything else still syncs — only the unread list is
      // withheld, so the iPhone does not mark every text read.
      expect(types, contains(MessageType.smsBatch));
      expect(types, contains(MessageType.lists));
      expect(types, isNot(contains(MessageType.smsUnread)));
      await h.close();
    });

    test('sync skips unchanged contacts', () async {
      final h = await HubHarness.open();
      h.client.send(Message(MessageType.sync, b: {
        'sms': 0,
        'calls': 0,
        'contacts': 'v1',
      }));
      await waitFor(() => h.clientListener.messages.length >= 4);
      final types =
          h.clientListener.messages.map((e) => e.$2.t).toList();
      expect(types, isNot(contains(MessageType.contactsBatch)));
      await h.close();
    });

    test('call state is pushed and answer is routed', () async {
      final h = await HubHarness.open();
      const info = CallInfo(
        cid: 'c1',
        num: '+98912',
        state: 'ringing',
        dir: 'in',
        hold: true,
      );
      h.hub.onCall(info);
      await waitFor(() => h.clientListener.messages
          .any((e) => e.$2.t == MessageType.callState));
      final state = h.clientListener.messages
          .firstWhere((e) => e.$2.t == MessageType.callState)
          .$2;
      expect(state.t, MessageType.callState);
      expect(state.b['cid'], 'c1');
      expect(state.b['state'], 'ringing');
      h.client.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await waitFor(() => h.data.answered.contains('c1'));
      expect(h.hub.audio.owner, h.peripheral);
      await h.close();
    });

    test('ended call is announced once', () async {
      final h = await HubHarness.open();
      const info = CallInfo(
        cid: 'c9',
        num: '+98912',
        state: 'ended',
        dir: 'in',
        hold: false,
      );
      h.hub.onCall(info);
      h.hub.onCall(info);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final ended = h.clientListener.messages
          .where((e) => e.$2.t == MessageType.callState)
          .toList();
      expect(ended, hasLength(1));
      await h.close();
    });

    test('sms.send is tracked and sms.result answers', () async {
      final h = await HubHarness.open();
      h.client.send(Message(MessageType.smsSend,
          b: {'to': '+98912', 'body': 'hello'}, id: 3));
      await waitFor(() => h.data.sentSms.isNotEmpty);
      expect(h.data.sentSms.single['to'], '+98912');
      final localId = h.data.lastLocalId!;
      h.hub.smsResult(localId, true, 'sent', null);
      await waitFor(() => h.clientListener.messages
          .any((e) => e.$2.t == MessageType.smsResult));
      final result = h.clientListener.messages
          .firstWhere((e) => e.$2.t == MessageType.smsResult)
          .$2;
      expect(result.t, MessageType.smsResult);
      expect(result.re, 3);
      expect(result.b['state'], 'sent');
      await h.close();
    });

    test('sms.read marks read and notifies other clients', () async {
      final h = await HubHarness.open();
      h.client.send(Message(MessageType.smsRead,
          b: {'thread': 4, 'upTo': 42}));
      await waitFor(() => h.data.markedRead.isNotEmpty);
      expect(h.data.markedRead.single, (4, 42));
      await h.close();
    });

    test('dial claims audio and reports dialed', () async {
      final h = await HubHarness.open();
      h.client.send(Message(MessageType.callDial,
          b: {'num': '+98912'}, id: 11));
      await waitFor(() => h.data.dialed.isNotEmpty);
      expect(h.data.dialed.single.$1, '+98912');
      expect(h.hub.audio.owner, h.peripheral);
      await waitFor(() => h.clientListener.messages
          .any((e) => e.$2.t == MessageType.callDialed));
      final dialed = h.clientListener.messages
          .firstWhere((e) => e.$2.t == MessageType.callDialed)
          .$2;
      expect(dialed.t, MessageType.callDialed);
      expect(dialed.b['ok'], isTrue);
      expect(dialed.re, 11);
      await h.close();
    });

    test('dry transport cannot answer calls', () async {
      final peripheralKeys = P256.generate();
      final centralKeys = P256.generate();
      final token = P256.randomNonce();
      final data = FakeHubData();
      final (a, b) = FakeTransport.pair(dry: true);
      late final Hub hub;
      hub = Hub(
        data,
        connectionFactory: (t) => PeripheralConnection(
          t,
          hub,
          PeripheralKeys(staticKey: peripheralKeys, openToken: token),
        ),
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
      await waitFor(
          () => hub.conns.isNotEmpty && hub.conns.first.isUp);
      central.send(Message(MessageType.callAnswer, b: {'cid': 'c1'}));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(data.answered, isEmpty);
      central.close();
      hub.conns.first.close();
    });

    test('status is pushed once per change', () async {
      final h = await HubHarness.open();
      await h.hub.pushStatus();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final first = h.clientListener.messages
          .where((e) => e.$2.t == MessageType.status)
          .length;
      expect(first, 1);
      await h.hub.pushStatus();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final second = h.clientListener.messages
          .where((e) => e.$2.t == MessageType.status)
          .length;
      expect(second, 1); // unchanged: not re-sent
      h.data.status = {'device': 'test2'};
      await h.hub.pushStatus();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final third = h.clientListener.messages
          .where((e) => e.$2.t == MessageType.status)
          .length;
      expect(third, 2);
      await h.close();
    });

    test('contact.star reports success, and refusal carries an err',
        () async {
      final h = await HubHarness.open();
      Future<Map<String, dynamic>> star(int id) async {
        final before = h.clientListener.messages.length;
        h.client.send(
            Message(MessageType.contactStar, b: {'id': id, 'on': true}));
        await waitFor(() => h.clientListener.messages
            .skip(before)
            .any((e) => e.$2.t == MessageType.contactResult));
        return h.clientListener.messages
            .skip(before)
            .firstWhere((e) => e.$2.t == MessageType.contactResult)
            .$2
            .b;
      }

      final ok = await star(3);
      expect(ok['ok'], isTrue);
      expect(ok['id'], 3);
      expect(ok.containsKey('err'), isFalse);
      // Android refused the change (rows -1): the reply says so.
      h.data.starResult = -1;
      final refused = await star(3);
      expect(refused['ok'], isFalse);
      expect(refused['err'], 'Android refused the change');
      await h.close();
    });
  });
}

/// Sends one net.set from the test client and returns the netState
/// reply body.
Future<Map<String, dynamic>> netSet(
    HubHarness h, Map<String, dynamic> b) async {
  final before = h.clientListener.messages.length;
  h.client.send(Message(MessageType.netSet, b: b));
  await waitFor(() => h.clientListener.messages
      .skip(before)
      .any((e) => e.$2.t == MessageType.netState));
  return h.clientListener.messages
      .skip(before)
      .firstWhere((e) => e.$2.t == MessageType.netState)
      .$2
      .b;
}

void hubNetTests() {
  group('Hub net.set validation', () {
    test('unknown switch is refused and never reaches the helper',
        () async {
      final h = await HubHarness.open();
      final body = await netSet(h, {'what': 'wifi', 'on': true});
      expect(body['err'], 'unknown switch');
      expect(h.data.netControls, isEmpty);
      await h.close();
    });

    test('dataSub needs a currently active SIM', () async {
      final h = await HubHarness.open();
      h.data.status = {
        'sims': [
          {'sub': 3},
          {'sub': 2},
        ],
      };
      final refused = await netSet(h, {'what': 'dataSub', 'sub': 9});
      expect(refused['err'], 'unknown SIM');
      expect(h.data.netControls, isEmpty);
      final ok = await netSet(h, {'what': 'dataSub', 'sub': 2});
      expect(ok['err'], isNull);
      expect(h.data.netControls.single['sub'], 2);
      await h.close();
    });

    test('rat needs a valid slot and mode', () async {
      final h = await HubHarness.open();
      expect(
          (await netSet(h, {'what': 'rat', 'slot': 2, 'mode': '4G'}))['err'],
          'unknown network mode');
      expect(
          (await netSet(h, {'what': 'rat', 'slot': 0, 'mode': '6G'}))['err'],
          'unknown network mode');
      expect(h.data.netControls, isEmpty);
      final ok =
          await netSet(h, {'what': 'rat', 'slot': 1, 'mode': '5G'});
      expect(ok['err'], isNull);
      expect(h.data.netControls.single,
          {'what': 'rat', 'on': false, 'sub': null, 'slot': 1, 'mode': '5G'});
      await h.close();
    });

    test('share is refused, the proxy is not implemented', () async {
      final h = await HubHarness.open();
      final body = await netSet(h, {'what': 'share', 'on': true});
      expect(body['err'], 'Share-VPN proxy is not available yet');
      expect(h.data.netControls, isEmpty);
      await h.close();
    });

    test('airplane fail-safe switches it back off with no client',
        () async {
      final h = await HubHarness.open(
        airplaneFailSafeInterval: const Duration(milliseconds: 20),
        airplaneFailSafeGrace: const Duration(milliseconds: 100),
      );
      final body = await netSet(h, {'what': 'airplane', 'on': true});
      expect(body['err'], isNull);
      expect(h.data.netControls.single['what'], 'airplane');
      // The link dies with airplane mode: drop the client, and the
      // fail-safe must turn airplane mode back off.
      h.central.close('test drop');
      await waitFor(() => h.data.netControls.any(
          (e) => e['what'] == 'airplane' && e['on'] == false));
      await h.close();
    });

    test('airplane fail-safe persists and re-arms on restart (N10)',
        () async {
      final store = MemoryAirplaneFailSafeStore();
      final h = await HubHarness.open(
        airplaneStore: store,
        airplaneFailSafeInterval: const Duration(milliseconds: 20),
        airplaneFailSafeGrace: const Duration(milliseconds: 100),
      );
      final body = await netSet(h, {'what': 'airplane', 'on': true});
      expect(body['err'], isNull);
      // The armed state is persisted at once (the write is
      // fire-and-forget, so give it a tick).
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await store.readArmed(), isTrue);
      // The app is killed: a fresh Hub over the same store re-arms
      // from the persisted state (the first Hub stays alive here —
      // its client is still connected, so its own check never
      // fires; only the fresh Hub's behaviour is asserted).
      final h2 = await HubHarness.open(
        airplaneStore: store,
        airplaneFailSafeInterval: const Duration(milliseconds: 20),
        airplaneFailSafeGrace: const Duration(milliseconds: 100),
      );
      await h2.hub.restoreAirplaneFailSafe();
      // The link dies with airplane mode: drop the client, and the
      // re-armed fail-safe must turn airplane mode back off.
      h2.central.close('test drop');
      await waitFor(() => h2.data.netControls.any(
          (e) => e['what'] == 'airplane' && e['on'] == false));
      await h.close();
      await h2.close();
    });

    test('airplane fail-safe stays disarmed when never armed (N10)',
        () async {
      final store = MemoryAirplaneFailSafeStore();
      final h = await HubHarness.open(
        airplaneStore: store,
        airplaneFailSafeInterval: const Duration(milliseconds: 20),
        airplaneFailSafeGrace: const Duration(milliseconds: 100),
      );
      await h.hub.restoreAirplaneFailSafe();
      h.central.close('test drop');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.data.netControls, isEmpty);
      await h.close();
    });
  });
}

/// Mocks the com.simbridge/callkit channels, so Hub tests can drive
/// CallKit actions and observe what the Hub reports to CallKit.
class CallKitChannelMocks {
  CallKitChannelMocks() {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async => null);
  }

  static const methods = MethodChannel('com.simbridge/callkit');
  static const events = MethodChannel('com.simbridge/callkit/events');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every method call the Hub (or bridge) made, in order.
  final calls = <MethodCall>[];

  /// Delivers one raw event map to the bridge's event stream.
  Future<void> sendEvent(Map<String, dynamic> event) async {
    await messenger.handlePlatformMessage(
      'com.simbridge/callkit/events',
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  void dispose() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  }
}

void callKitHubTests() {
  group('Hub CallKit wiring', () {
    late CallKitChannelMocks mocks;

    setUp(() {
      mocks = CallKitChannelMocks();
    });

    tearDown(() {
      mocks.dispose();
    });

    const ringing = CallInfo(
      cid: 'c1',
      num: '+989121234567',
      name: 'سارا احمدی',
      state: 'ringing',
      dir: 'in',
      hold: true,
    );

    test('a CallKit answer is routed like a message from the client',
        () async {
      final h = await HubHarness.open(callKit: CallKitBridge());
      addTearDown(h.hub.detachCallKit);
      await mocks.sendEvent({'t': 'answer', 'cid': 'c1'});
      await waitFor(() => h.data.answered.contains('c1'));
      expect(h.hub.audio.owner, h.peripheral);
      await h.close();
    });

    test('a CallKit dial dials and the client gets call.dialed',
        () async {
      final h = await HubHarness.open(callKit: CallKitBridge());
      addTearDown(h.hub.detachCallKit);
      await mocks.sendEvent(
          {'t': 'dial', 'num': '+989121234567', 'sub': 2});
      await waitFor(() => h.data.dialed.isNotEmpty);
      expect(h.data.dialed.single, ('+989121234567', '2'));
      await waitFor(() => h.clientListener.messages
          .any((e) => e.$2.t == MessageType.callDialed));
      final dialed = h.clientListener.messages
          .firstWhere((e) => e.$2.t == MessageType.callDialed)
          .$2;
      expect(dialed.b['ok'], isTrue);
      await h.close();
    });

    test('hold / dtmf / take / mute / reject / end reach HubData',
        () async {
      final h = await HubHarness.open(callKit: CallKitBridge());
      addTearDown(h.hub.detachCallKit);
      h.hub.onCall(ringing);
      await mocks.sendEvent({'t': 'answer', 'cid': 'c1'});
      await waitFor(() => h.data.answered.contains('c1'));
      await mocks.sendEvent({'t': 'hold', 'cid': 'c1', 'on': true});
      await waitFor(() => h.data.held.contains(('c1', true)));
      await mocks.sendEvent({'t': 'dtmf', 'cid': 'c1', 'd': '5'});
      await waitFor(() => h.data.dtmfs.contains(('c1', '5')));
      // take moves the audio and re-broadcasts the calls: CallKit
      // is reconciled with the live list.
      mocks.calls.clear();
      await mocks.sendEvent({'t': 'take', 'cid': 'c1'});
      await waitFor(
          () => mocks.calls.any((c) => c.method == 'reconcile'));
      final reconcile =
          mocks.calls.firstWhere((c) => c.method == 'reconcile');
      final live =
          (reconcile.arguments as Map)['calls'] as List;
      expect(live, hasLength(1));
      expect((live.single as Map)['cid'], 'c1');
      expect(h.hub.audio.target, h.peripheral);
      await mocks.sendEvent({'t': 'mute', 'cid': 'c1', 'on': true});
      await waitFor(() => h.hub.audio.uplinkMuted);
      await mocks.sendEvent({'t': 'reject', 'cid': 'c1'});
      await waitFor(() => h.data.rejected.contains('c1'));
      await mocks.sendEvent({'t': 'end', 'cid': 'c1'});
      await waitFor(() => h.data.ended.contains('c1'));
      await h.close();
    });

    test('call state is mirrored into CallKit', () async {
      final h = await HubHarness.open(callKit: CallKitBridge());
      addTearDown(h.hub.detachCallKit);
      h.hub.onCall(ringing);
      await waitFor(
          () => mocks.calls.any((c) => c.method == 'reportCall'));
      final report =
          mocks.calls.firstWhere((c) => c.method == 'reportCall');
      final call = Map<String, dynamic>.from(
          (report.arguments as Map)['call'] as Map);
      expect(call['cid'], 'c1');
      expect(call['state'], 'ringing');
      expect(call['num'], '+989121234567');
      await h.close();
    });

    test('a fresh link reconciles CallKit on establish', () async {
      final peripheralKeys = P256.generate();
      final centralKeys = P256.generate();
      final token = P256.randomNonce();
      final data = FakeHubData();
      final (a, b) = FakeTransport.pair();
      late final Hub hub;
      hub = Hub(
        data,
        connectionFactory: (t) => PeripheralConnection(
          t,
          hub,
          PeripheralKeys(staticKey: peripheralKeys, openToken: token),
        ),
        callKit: CallKitBridge(),
      );
      addTearDown(hub.detachCallKit);
      final central = CentralConnection(
        b,
        CollectingListener(),
        CentralKeys(
          staticKey: centralKeys,
          peerStatic: peripheralKeys.publicEncoded,
          token: token,
        ),
      );
      hub.onTransport(a);
      central.start();
      await waitFor(() => hub.conns.isNotEmpty && hub.conns.first.isUp);
      await waitFor(
          () => mocks.calls.any((c) => c.method == 'reconcile'));
      final reconcile =
          mocks.calls.firstWhere((c) => c.method == 'reconcile');
      expect((reconcile.arguments as Map)['calls'], isEmpty);
      final conn = hub.conns.first;
      central.close();
      conn.close();
      hub.stopTimers();
    });

    test('the last link dropping ends the mirrored calls', () async {
      final h = await HubHarness.open(callKit: CallKitBridge());
      addTearDown(h.hub.detachCallKit);
      h.central.close();
      await waitFor(
          () => mocks.calls.any((c) => c.method == 'linkLost'));
      await h.close();
    });

    test('a dry transport ignores CallKit actions', () async {
      final peripheralKeys = P256.generate();
      final centralKeys = P256.generate();
      final token = P256.randomNonce();
      final data = FakeHubData();
      final (a, b) = FakeTransport.pair(dry: true);
      late final Hub hub;
      hub = Hub(
        data,
        connectionFactory: (t) => PeripheralConnection(
          t,
          hub,
          PeripheralKeys(staticKey: peripheralKeys, openToken: token),
        ),
        callKit: CallKitBridge(),
      );
      addTearDown(hub.detachCallKit);
      final central = CentralConnection(
        b,
        CollectingListener(),
        CentralKeys(
          staticKey: centralKeys,
          peerStatic: peripheralKeys.publicEncoded,
          token: token,
        ),
      );
      hub.onTransport(a);
      central.start();
      await waitFor(() => hub.conns.isNotEmpty && hub.conns.first.isUp);
      await mocks.sendEvent({'t': 'answer', 'cid': 'c1'});
      await mocks.sendEvent({'t': 'dial', 'num': '+98912'});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(data.answered, isEmpty);
      expect(data.dialed, isEmpty);
      final conn = hub.conns.first;
      central.close();
      conn.close();
      hub.stopTimers();
    });
  });
}

void barkHubTests() {
  group('Hub Bark fallback', () {
    final posted = <(Uri, Map<String, dynamic>)>[];
    late FarWakeNotifier farWake;

    setUp(() {
      posted.clear();
      farWake = FarWakeNotifier(
        clientFactory: (key) => BarkClient(
          deviceKey: key,
          poster: (uri, body) async {
            posted.add((uri, body));
            return {'code': 200, 'message': 'success'};
          },
        ),
      );
    });

    const ringing = CallInfo(
      cid: 'c1',
      num: '+989121234567',
      name: 'سارا احمدی',
      state: 'ringing',
      dir: 'in',
      hold: true,
    );
    const sms = Sms(
      id: 42,
      thread: 7,
      addr: '+989121234567',
      body: 'سلام!',
      date: 1000,
      box: 1,
      read: false,
    );

    /// Opens a harness, teaches the Hub the iPhone's Bark key via
    /// sync, then drops the link — the far-mode state.
    Future<HubHarness> openFar() async {
      final h = await HubHarness.open(farWake: farWake);
      h.client.send(Message(MessageType.sync, b: {
        'sms': 0,
        'calls': 0,
        'contacts': '',
        'client': {
          'kind': 'iphone',
          'name': 'Test iPhone',
          'barkKey': 'iphone-bark-key',
        },
      }));
      await waitFor(() => h.hub.conns.first.barkKey == 'iphone-bark-key');
      expect(farWake.client?.deviceKey, 'iphone-bark-key');
      h.central.close();
      await waitFor(() => h.hub.conns.isEmpty);
      return h;
    }

    test('a ringing call with no link pushes a Bark alert', () async {
      final h = await openFar();
      h.hub.onCall(ringing);
      await waitFor(() => posted.isNotEmpty);
      expect(posted, hasLength(1));
      final body = posted.single.$2;
      expect(body['device_key'], 'iphone-bark-key');
      expect(body['title'], 'تماس ورودی');
      expect(body['body'], 'سارا احمدی');
      expect(body['url'], 'simbridge://call?cid=c1');
      await h.close();
    });

    test('the same ringing call is pushed once', () async {
      final h = await openFar();
      h.hub.onCall(ringing);
      h.hub.onCall(ringing);
      await waitFor(() => posted.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(posted, hasLength(1));
      await h.close();
    });

    test('an SMS with no link pushes once, with the text', () async {
      final h = await openFar();
      h.hub.onSms(sms, blocked: false);
      h.hub.onSms(sms, blocked: false);
      await waitFor(() => posted.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(posted, hasLength(1));
      final body = posted.single.$2;
      expect(body['title'], '+989121234567');
      expect(body['body'], 'سلام!');
      expect(body['url'], 'simbridge://sms?thread=7');
      await h.close();
    });

    test('a ringing call with a live link does not push', () async {
      final h = await HubHarness.open(farWake: farWake);
      h.client.send(Message(MessageType.sync, b: {
        'sms': 0,
        'calls': 0,
        'contacts': '',
        'client': {'kind': 'iphone', 'name': 'T', 'barkKey': 'k'},
      }));
      await waitFor(() => h.hub.conns.first.barkKey == 'k');
      h.hub.onCall(ringing);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(posted, isEmpty);
      await h.close();
    });

    test('without a Bark key nothing is pushed', () async {
      final h = await HubHarness.open(farWake: farWake);
      // Sync without a barkKey: the notifier stays keyless.
      h.client.send(Message(MessageType.sync, b: {
        'sms': 0,
        'calls': 0,
        'contacts': '',
        'client': {'kind': 'iphone', 'name': 'T'},
      }));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(farWake.client, isNull);
      h.central.close();
      await waitFor(() => h.hub.conns.isEmpty);
      h.hub.onCall(ringing);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(posted, isEmpty);
      await h.close();
    });

    test('dry-run records the push and sends nothing', () async {
      farWake.dryRun = true;
      final h = await openFar();
      h.hub.onCall(ringing);
      await waitFor(() => farWake.dryRunSent.isNotEmpty);
      expect(posted, isEmpty);
      expect(farWake.dryRunSent.single.title, 'تماس ورودی');
      expect(farWake.dryRunSent.single.url, 'simbridge://call?cid=c1');
      await h.close();
    });
  });
}
