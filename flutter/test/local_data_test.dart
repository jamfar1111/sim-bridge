// Tests for the Android hub's local data load (2026-11-23): the
// phone's own call history, contacts and SMS shown in the Android
// UI itself. Before this, the Hub only read local data to send it
// to a paired iPhone — with no iPhone paired, Recents showed
// "هنوز تماسی نیست" and Contacts "مخاطبی پیدا نشد". The load runs
// after wiring (and again when the permissions are granted later),
// live SMS/call events keep the lists fresh, and pull-to-refresh
// reloads them.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:sim_bridge/src/link/link.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';
import 'package:sim_bridge/src/ui/app_model.dart';

import 'client_test.dart' show ClientHarness;
import 'link_test.dart' show waitFor;
import 'setup_test.dart'
    show FakeSetupPermissions, clearSetupChannels, makeSetup, mockSetupChannels;

void main() {
  group('local data load (hub)', () {
    late ClientHarness h;
    late AppModel model;

    setUp(() {
      h = ClientHarness.open();
      model = AppModel.real();
    });

    tearDown(() {
      model.dispose();
      h.close();
    });

    test('load populates recents, contacts and sms', () async {
      h.data.calls.add(const CallEntry(
        id: 1,
        num: '+989121234567',
        name: 'سارا احمدی',
        date: 1000,
        dur: 95,
        type: 1,
      ));
      h.data.contacts.add(const Contact(
        id: 1,
        name: 'سارا احمدی',
        phones: [Phone('+989121234567', 'mobile')],
        emails: [],
        starred: true,
      ));
      h.data.sms.add(const Sms(
        id: 1,
        thread: 5,
        addr: '+989121234567',
        body: 'سلام',
        date: 1000,
        box: 1,
        read: false,
      ));
      model.attachHub(h.hub);
      await model.loadLocalData();
      expect(model.localDataLoaded, isTrue);
      expect(model.recents.single.name, 'سارا احمدی');
      expect(model.contacts.single.name, 'سارا احمدی');
      expect(model.sms.single.body, 'سلام');
      expect(model.nameFor('+989121234567'), 'سارا احمدی');
    });

    test('load is bounded: newest 200 calls, newest 500 sms', () async {
      for (var i = 1; i <= 250; i++) {
        h.data.calls.add(CallEntry(
          id: i,
          num: '+989121234567',
          date: i * 1000,
          dur: 0,
          type: 1,
        ));
      }
      for (var i = 1; i <= 600; i++) {
        h.data.sms.add(Sms(
          id: i,
          thread: 1,
          addr: '+989121234567',
          body: 'msg $i',
          date: i * 1000,
          box: 1,
          read: true,
        ));
      }
      model.attachHub(h.hub);
      await model.loadLocalData();
      expect(model.recents.length, AppModel.maxLocalRecents);
      expect(model.recents.first.id, 250);
      expect(model.sms.length, AppModel.maxLocalSms);
      expect(model.sms.last.id, 600);
    });

    test('refresh reloads and drops deleted rows', () async {
      h.data.calls.add(const CallEntry(
        id: 1,
        num: '+989121234567',
        date: 1000,
        dur: 0,
        type: 1,
      ));
      model.attachHub(h.hub);
      await model.loadLocalData();
      expect(model.recents.length, 1);
      h.data.calls.add(const CallEntry(
        id: 2,
        num: '+989122223333',
        date: 2000,
        dur: 0,
        type: 2,
      ));
      await model.refreshLocalData();
      expect(model.recents.map((c) => c.id), [2, 1]);
      h.data.calls.removeWhere((c) => c.id == 1);
      await model.refreshLocalData();
      expect(model.recents.map((c) => c.id), [2]);
    });

    test('load waits for permissions, then runs on grant', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      mockSetupChannels(
        {'isBluetoothOn': true, 'requestEnableBluetooth': true},
        {'isDefaultDialer': true, 'requestDefaultDialer': true},
        [],
      );
      final permissions = FakeSetupPermissions(
        initiallyDenied: {
          ph.Permission.sms,
          ph.Permission.contacts,
          ph.Permission.phone,
        },
      );
      final setup = makeSetup(permissions: permissions);
      h.data.calls.add(const CallEntry(
        id: 1,
        num: '+989121234567',
        date: 1000,
        dur: 0,
        type: 1,
      ));
      h.data.contacts.add(const Contact(
        id: 1,
        name: 'سارا احمدی',
        phones: [Phone('+989121234567', 'mobile')],
        emails: [],
        starred: false,
      ));
      model.attachSetup(setup);
      model.attachHub(h.hub);
      await model.loadLocalData();
      // The data sections were skipped: nothing loaded yet.
      expect(model.recents, isEmpty);
      expect(model.contacts, isEmpty);
      expect(model.localDataLoaded, isFalse);
      // The user grants the permissions from the setup card: the
      // setup notifies, the model reloads on its own.
      await setup.requestPermissions();
      await waitFor(() => model.recents.isNotEmpty);
      expect(model.contacts.single.name, 'سارا احمدی');
      expect(model.localDataLoaded, isTrue);
      clearSetupChannels();
    });
  });

  group('live local updates (link service)', () {
    late List<dynamic> callRows;
    MockStreamHandlerEventSink? smsSink;
    MockStreamHandlerEventSink? telecomSink;
    late AndroidLinkService service;
    late AppModel model;

    dynamic smsHandler(MethodCall call) {
      switch (call.method) {
        case 'contactsVersion':
          return 'v1';
        case 'statusJson':
          return <String, dynamic>{'device': 'test'};
        case 'listsJson':
          return <String, dynamic>{
            'blocked': <String>[],
            'muted': <int>[],
            'system': false,
          };
        case 'callsSince':
          return callRows;
        case 'smsSince':
        case 'contactsAll':
        case 'smsAllIds':
        case 'callAllIds':
        case 'unreadSmsIds':
          return <dynamic>[];
      }
      return null;
    }

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      callRows = [];
      smsSink = null;
      telecomSink = null;
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/ble'), (call) async {
        return switch (call.method) {
          'startAdvertising' || 'ensureAdvertising' => true,
          _ => null,
        };
      });
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/sms'), (call) async {
        return smsHandler(call);
      });
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/telecom'),
          (call) async => null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/audio'), (call) async => null);
      messenger.setMockStreamHandler(
          const EventChannel('com.simbridge/sms/events'),
          MockStreamHandler.inline(
              onListen: (args, events) => smsSink = events));
      messenger.setMockStreamHandler(
          const EventChannel('com.simbridge/telecom/events'),
          MockStreamHandler.inline(
              onListen: (args, events) => telecomSink = events));
      final keyStore = KeyStore(backend: MemoryKeyStoreBackend());
      service = AndroidLinkService(
        ble: BleLink(),
        sms: SmsBridge(),
        telecom: TelecomBridge(),
        audio: CallAudioBridge(),
        keyStore: keyStore,
      );
      await service.start();
      model = AppModel.real();
      model.attachLinkService(service);
    });

    tearDown(() async {
      model.dispose();
      await service.stop();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/ble'), null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/sms'), null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/telecom'), null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/audio'), null);
      messenger.setMockStreamHandler(
          const EventChannel('com.simbridge/sms/events'), null);
      messenger.setMockStreamHandler(
          const EventChannel('com.simbridge/telecom/events'), null);
    });

    test('incoming SMS lands in Messages', () async {
      smsSink?.success({
        't': 'sms.new',
        'item': {
          'id': 7,
          'thread': 5,
          'addr': '+989121234567',
          'body': 'سلام',
          'date': 2000,
          'box': 1,
          'read': false,
        },
      });
      await waitFor(() => model.sms.any((m) => m.id == 7));
      expect(model.conversations.single.address, '+989121234567');
    });

    test('read-changed marks the thread read', () async {
      model.applySmsBatch(const [
        Sms(id: 1, thread: 5, addr: 'a', body: 'x', date: 1,
            box: 1, read: false),
      ], more: false);
      smsSink?.success({'t': 'sms.readChanged', 'ids': <int>[]});
      await waitFor(
          () => model.sms.firstWhere((m) => m.id == 1).read);
    });

    test('ended call lands in Recents', () async {
      callRows = [
        {
          'id': 9,
          'num': '+989121234567',
          'name': 'سارا احمدی',
          'date': 3000,
          'dur': 42,
          'type': 1,
        },
      ];
      telecomSink?.success({
        'cid': 'c1',
        'num': '+989121234567',
        'state': 'ended',
        'dir': 'in',
        'hold': false,
      });
      // The reload is delayed a second (call-log settle time).
      await waitFor(() => model.recents.any((c) => c.id == 9),
          timeout: const Duration(seconds: 5));
      expect(model.recents.single.name, 'سارا احمدی');
    });
  });
}
