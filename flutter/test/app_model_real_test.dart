// Tests for AppModel real-mode routing (finding 4): the model
// implements ClientStore, routes actions through the LinkClient
// (iOS) — never the demo simulation — with real pairing, optimistic
// SMS, and reconnect. The peer is a real Hub over FakeTransport
// (see ClientHarness in client_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';
import 'package:sim_bridge/src/ui/app_model.dart';

import 'client_test.dart' show ClientHarness;
import 'link_test.dart' show waitFor;

void main() {
  group('AppModel real mode', () {
    late ClientHarness h;
    late AppModel model;

    setUp(() async {
      h = ClientHarness.open();
      model = AppModel.real();
      // The wiring main.dart does: the client's pairing callbacks
      // update the model, and the model is the client's store.
      h.client.onPaired = () {
        model.setPaired(h.client.peerName ?? 'Android');
      };
      h.client.onUnpaired = () {
        model.setUnpaired();
      };
      model.attachClient(h.client);
    });

    tearDown(() {
      model.dispose();
      h.close();
    });

    test('real pairing: QR code → link up, model paired', () async {
      final code = PairingCode(h.hubKeys.publicEncoded, h.token, 'Android');
      model.pair(code);
      expect(model.linkState, LinkState.connecting);
      await waitFor(() => h.client.isConnected);
      await waitFor(() => model.isPaired && model.linkState.isConnected);
      expect(model.peerName, 'Android');
      expect(h.hub.conns.length, 1);
    });

    test('sync applies SMS, calls and contacts to the model', () async {
      h.data.unread = [1];
      h.data.sms.add(const Sms(
        id: 1,
        thread: 5,
        addr: '+989121234567',
        body: 'سلام',
        date: 1000,
        box: 1,
        read: false,
      ));
      h.data.contacts.add(const Contact(
        id: 1,
        name: 'سارا احمدی',
        phones: [Phone('+989121234567', 'mobile')],
        emails: [],
        starred: true,
      ));
      await h.pair();
      await waitFor(() => model.sms.isNotEmpty);
      expect(model.sms.single.body, 'سلام');
      expect(model.conversations.single.address, '+989121234567');
      expect(model.unreadTotal, 1);
      await waitFor(() => model.contacts.isNotEmpty);
      expect(model.contacts.single.name, 'سارا احمدی');
      expect(model.nameFor('+989121234567'), 'سارا احمدی');
    });

    test('dial, answer and end go through the link', () async {
      await h.pair();
      model.dial('+989121234567');
      await waitFor(() => h.data.dialed.isNotEmpty);
      expect(h.data.dialed.single.$1, '+989121234567');
      // The dialed reply arrives: no error.
      await waitFor(() => model.lastError == null);
      // An incoming call rings on the model, then is answered.
      h.hub.onCall(const CallInfo(
        cid: 'c1',
        num: '+989121234567',
        name: 'سارا احمدی',
        state: 'ringing',
        dir: 'in',
        hold: true,
      ));
      await waitFor(() => model.callScreen != null);
      expect(model.callScreen!.state, 'ringing');
      expect(model.showCallScreen, isTrue);
      model.answerCall('c1');
      await waitFor(() => h.data.answered.isNotEmpty);
      expect(h.data.answered.single, 'c1');
      model.endCall('c1');
      await waitFor(() => h.data.ended.isNotEmpty);
      expect(h.data.ended.single, 'c1');
    });

    test('mute toggles the uplink mute on the Hub', () async {
      await h.pair();
      h.hub.onCall(const CallInfo(
        cid: 'c1',
        num: '+989121234567',
        state: 'ringing',
        dir: 'in',
        hold: true,
      ));
      await waitFor(() => model.callScreen != null);
      model.answerCall('c1');
      await waitFor(() => h.data.answered.isNotEmpty);
      model.toggleMute();
      expect(model.callScreen!.muted, isTrue);
      await waitFor(() => h.hub.audio.uplinkMuted);
      model.toggleMute();
      expect(model.callScreen!.muted, isFalse);
      await waitFor(() => !h.hub.audio.uplinkMuted);
    });

    test('sendSms is optimistic, then replaced by the real message',
        () async {
      await h.pair();
      model.sendSms('+989121234567', 'سلام، چطوری؟');
      // Optimistic outbox copy, visible at once.
      expect(model.sms.single.box, 4);
      expect(model.sms.single.body, 'سلام، چطوری؟');
      await waitFor(() => h.data.sentSms.isNotEmpty);
      h.hub.smsResult(h.data.lastLocalId!, true, 'sent', null);
      await waitFor(
          () => model.sms.any((m) => m.box == 2 && m.id < 0));
      // The phone reports the sent message: the temp copy is
      // replaced by the real one (same address/body, stamped now).
      h.hub.onSms(
        Sms(
          id: 42,
          thread: 5,
          addr: '+989121234567',
          body: 'سلام، چطوری؟',
          date: DateTime.now().millisecondsSinceEpoch,
          box: 2,
          read: true,
        ),
        blocked: false,
      );
      await waitFor(() => model.sms.any((m) => m.id == 42));
      expect(model.sms.where((m) => m.id < 0), isEmpty);
      expect(model.sms.singleWhere((m) => m.id == 42).body,
          'سلام، چطوری؟');
    });

    test('markThreadRead and toggleStar go through the link', () async {
      h.data.sms.add(const Sms(
        id: 1,
        thread: 5,
        addr: '+989121234567',
        body: 'سلام',
        date: 1000,
        box: 1,
        read: false,
      ));
      h.data.contacts.add(const Contact(
        id: 1,
        name: 'سارا احمدی',
        phones: [Phone('+989121234567', 'mobile')],
        emails: [],
        starred: false,
      ));
      await h.pair();
      await waitFor(() => model.sms.isNotEmpty);
      model.markThreadRead(5);
      await waitFor(() => h.data.markedRead.isNotEmpty);
      expect(h.data.markedRead.single, (5, 1));
      await waitFor(() => model.contacts.isNotEmpty);
      model.toggleStar(model.contacts.single);
      expect(model.contacts.single.starred, isTrue);
      // The contact.result reply keeps the optimistic flip.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(model.contacts.single.starred, isTrue);
    });

    test('setNet sends net.set; the reply updates the state', () async {
      await h.pair();
      model.setNet('hotspot', true);
      expect(model.netState['hotspot'], isTrue);
      await waitFor(() => model.netState.containsKey('share'));
      expect(model.netState['share'], isFalse);
    });

    test('take moves the call audio to this iPhone', () async {
      await h.pair();
      h.hub.onCall(const CallInfo(
        cid: 'c1',
        num: '+989121234567',
        state: 'ringing',
        dir: 'in',
        hold: true,
      ));
      await waitFor(() => model.callScreen != null);
      model.takeCall('c1');
      await waitFor(() => h.hub.audio.owner != null);
      expect(h.hub.audio.target, isNotNull);
    });

    test('link loss shows connecting; reconnect restores it', () async {
      await h.pair();
      await waitFor(() => model.linkState.isConnected);
      h.hub.conns.first.close('test drop');
      await waitFor(() => model.linkState == LinkState.connecting);
      await waitFor(() => model.linkState.isConnected);
    });

    test('unpair tells the Hub and clears the model', () async {
      await h.pair();
      model.unpair();
      await waitFor(() => h.data.unpairKey != null);
      expect(model.isPaired, isFalse);
      expect(model.linkState, LinkState.unpaired);
      expect(model.client?.isPaired, isFalse);
    });
  });

  group('AppModel ClientStore (no link)', () {
    test('sync.ids prunes deleted messages only on the last page',
        () {
      final model = AppModel.real();
      model.applySmsBatch(const [
        Sms(id: 1, thread: 1, addr: 'a', body: 'one', date: 1, box: 1, read: true),
        Sms(id: 2, thread: 1, addr: 'a', body: 'two', date: 2, box: 1, read: true),
        Sms(id: 3, thread: 1, addr: 'a', body: 'three', date: 3, box: 1, read: true),
      ], more: false);
      expect(model.sms.length, 3);
      model.applySyncIds(smsRanges: const [
        [1, 1]
      ], callRanges: const [], more: true);
      expect(model.sms.length, 3);
      model.applySyncIds(smsRanges: const [
        [3, 3]
      ], callRanges: const [], more: false);
      expect(model.sms.map((m) => m.id), [1, 3]);
      model.dispose();
    });

    test('call state ends the screen; unread ids mark read state', () {
      final model = AppModel.real();
      model.applySmsBatch(const [
        Sms(id: 1, thread: 5, addr: 'a', body: 'x', date: 1, box: 1, read: true),
        Sms(id: 2, thread: 5, addr: 'a', body: 'y', date: 2, box: 1, read: false),
      ], more: false);
      model.applySmsUnread([2], all: true);
      expect(model.sms.firstWhere((m) => m.id == 1).read, isTrue);
      expect(model.sms.firstWhere((m) => m.id == 2).read, isFalse);
      model.applyCallState(const CallInfo(
        cid: 'c1',
        num: '+989121234567',
        state: 'ringing',
        dir: 'in',
        hold: true,
      ));
      expect(model.callScreen!.state, 'ringing');
      model.applyCallState(const CallInfo(
        cid: 'c1',
        num: '+989121234567',
        state: 'ended',
        dir: 'in',
        hold: false,
      ));
      expect(model.liveCalls, isEmpty);
      expect(model.callScreen, isNull);
      model.dispose();
    });

    test('audio start/stop and status update the model', () {
      final model = AppModel.real();
      model.applyAudioStarted(codec: 'opus', rate: 16000);
      expect(model.audioActive, isTrue);
      expect(model.audioCodec, 'opus');
      model.applyAudioStopped();
      expect(model.audioActive, isFalse);
      model.applyStatus({'device': 'Galaxy A52', 'battery': 55});
      expect(model.battery, 55);
      model.dispose();
    });
  });
}
