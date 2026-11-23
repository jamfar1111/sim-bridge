// Tests for ChannelHubData (finding 3): every HubData method
// delegates to the right platform channel with the right arguments,
// and results / errors are translated back the way the Hub expects.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/link/link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <String, List<MethodCall>>{};

  dynamic smsHandler(MethodCall call) {
    switch (call.method) {
      case 'smsSince':
        return [
          {
            'id': 3,
            'thread': 5,
            'addr': '+989121234567',
            'body': 'سلام',
            'date': 1000,
            'box': 1,
            'read': false,
          },
        ];
      case 'callsSince':
        return [
          {
            'id': 2,
            'num': '+989121234567',
            'name': 'سارا',
            'date': 900,
            'dur': 60,
            'type': 1,
          },
        ];
      case 'contactsAll':
        return [
          {
            'id': 1,
            'name': 'سارا احمدی',
            'phones': [
              {'n': '+989121234567', 'type': 'mobile'}
            ],
            'emails': <String>[],
            'starred': false,
          },
        ];
      case 'contactsVersion':
        return 'v9';
      case 'smsAllIds':
        return [1, 2, 3];
      case 'callAllIds':
        return [1, 2];
      case 'unreadSmsIds':
        return [3];
      case 'statusJson':
        return {'device': 'test', 'battery': 80};
      case 'sendSms':
        return {'ok': true};
      case 'markRead':
        return 1;
      case 'deleteMessages':
        return [3];
      case 'deleteCalls':
        return 1;
      case 'setContactStarred':
        return 1;
      case 'addContact':
        return 99;
      case 'updateContact':
        return {'ok': true};
      case 'listsJson':
        return {
          'blocked': ['+989120000000'],
          'muted': <int>[],
          'system': false,
        };
      case 'setLists':
        return {
          'blocked': ['+989120000000', '+989121111111'],
          'muted': <int>[],
          'system': false,
        };
    }
    return null;
  }

  dynamic telecomHandler(MethodCall call) {
    switch (call.method) {
      case 'dial':
        return {'ok': true};
    }
    return null;
  }

  dynamic audioHandler(MethodCall call) {
    switch (call.method) {
      case 'netControl':
        return {'wifi': true};
      case 'selftest':
        return {'ok': true};
    }
    return null;
  }

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/sms'), (call) async {
      calls.putIfAbsent('sms', () => []).add(call);
      return smsHandler(call);
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/telecom'), (call) async {
      calls.putIfAbsent('telecom', () => []).add(call);
      return telecomHandler(call);
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/audio'), (call) async {
      calls.putIfAbsent('audio', () => []).add(call);
      return audioHandler(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/sms'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/telecom'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/audio'), null);
  });

  ChannelHubData makeData({void Function(List<int>)? onUnpair}) =>
      ChannelHubData(
        sms: SmsBridge(),
        telecom: TelecomBridge(),
        audio: CallAudioBridge(),
        onUnpair: onUnpair,
      );

  group('ChannelHubData', () {
    test('read paths delegate and parse', () async {
      final data = makeData();
      final sms = await data.smsSince(0);
      expect(sms.single.body, 'سلام');
      expect(calls['sms']!.first.method, 'smsSince');
      final history = await data.callsSince(0);
      expect(history.single.num, '+989121234567');
      final contacts = await data.contactsAll();
      expect(contacts.single.name, 'سارا احمدی');
      expect(await data.smsAllIds(), [1, 2, 3]);
      expect(await data.callAllIds(), [1, 2]);
      expect(await data.unreadSmsIds(), [3]);
      expect(await data.statusJson(), {'device': 'test', 'battery': 80});
      expect(await data.listsJson(), containsPair('system', false));
    });

    test('contacts version is cached and refreshed', () async {
      final data = makeData();
      expect(data.contactsVersion(), '');
      await data.refreshContactsVersion();
      expect(data.contactsVersion(), 'v9');
      // A contact mutation refreshes it again.
      await data.addContact('سارا احمدی', const [], const []);
      expect(calls['sms']!.map((c) => c.method),
          containsAll(['contactsVersion', 'addContact']));
    });

    test('sendSms translates ok/err and never sends when dry', () async {
      final data = makeData();
      final err = await data.sendSms(
        to: '+989121234567',
        body: 'سلام',
        localId: 123,
      );
      expect(err, isNull);
      final send = calls['sms']!
          .firstWhere((c) => c.method == 'sendSms');
      expect((send.arguments as Map)['to'], '+989121234567');
      expect((send.arguments as Map)['localId'], 123);
      final before = calls['sms']!.length;
      expect(
          await data.sendSms(
              to: '+989121234567', body: 'x', localId: 1, dry: true),
          isNull);
      expect(calls['sms']!.length, before);
    });

    test('sendSms failure returns the error string', () async {
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/sms'), (call) async {
        calls.putIfAbsent('sms', () => []).add(call);
        if (call.method == 'sendSms') return {'ok': false, 'err': 'no sim'};
        return smsHandler(call);
      });
      final data = makeData();
      expect(
          await data.sendSms(
              to: '+989121234567', body: 'x', localId: 1),
          'no sim');
    });

    test('mark / delete / lists delegate', () async {
      final data = makeData();
      expect(await data.markSmsRead(5, 42), 1);
      expect(await data.deleteSms([3], 5), [3]);
      expect(await data.deleteCalls([1, 2]), 1);
      final lists = await data.setLists('blocked',
          num: '+989121111111', on: true);
      expect(lists['blocked'], contains('+989121111111'));
      // The block list is pushed to the screening service.
      expect(
          calls['telecom']!
              .any((c) => c.method == 'setBlockedNumbers'),
          isTrue);
      final blockedCall = calls['telecom']!
          .firstWhere((c) => c.method == 'setBlockedNumbers');
      expect((blockedCall.arguments as Map)['numbers'],
          contains('+989121111111'));
    });

    test('call actions and dial delegate', () async {
      final data = makeData();
      await data.answerCall('c1');
      await data.rejectCall('c2');
      await data.endCall('c3');
      await data.holdCall('c1', true);
      await data.dtmf('c1', '5');
      expect(
          calls['telecom']!.map((c) => c.method),
          containsAll(
              ['answerCall', 'rejectCall', 'endCall', 'holdCall', 'dtmf']));
      expect(await data.dial('+989121234567', null), isNull);
      final dial = calls['telecom']!
          .firstWhere((c) => c.method == 'dial');
      expect((dial.arguments as Map)['num'], '+989121234567');
    });

    test('netControl and selftest delegate to the audio helper',
        () async {
      final data = makeData();
      expect(await data.netControl(what: 'wifi', on: true),
          {'wifi': true});
      expect(await data.selftest(), {'ok': true});
      expect(calls['audio']!.map((c) => c.method),
          containsAll(['netControl', 'selftest']));
    });

    test('unpair forwards the peer key', () {
      List<int>? unpaired;
      final data = makeData(onUnpair: (key) => unpaired = key);
      data.unpair([1, 2, 3]);
      expect(unpaired, [1, 2, 3]);
    });
  });
}
