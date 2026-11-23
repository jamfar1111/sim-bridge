// Tests for the iOS CallKit bridge (lib/src/link/callkit.dart).
// No native code, no Gradle: the MethodChannel / EventChannel are
// faked through the test binding's binary messenger, and the
// expected method names / argument shapes are checked against
// `ios/Runner/SimBridgePlugins.swift` (`CallKitPlugin`) and the event
// shapes against `ios/Runner/CallKitManager.swift`.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/link/link.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.simbridge/callkit');
  const events = MethodChannel('com.simbridge/callkit/events');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every method call the bridge makes, in order.
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
    // The event channel's listen / cancel.
    messenger.setMockMethodCallHandler(events, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  CallInfo demoCall({String state = 'ringing'}) => CallInfo(
        cid: 'c1',
        num: '+989121234567',
        name: 'سارا احمدی',
        state: state,
        dir: 'in',
        hold: true,
      );

  /// Delivers one raw event map to the bridge's event stream.
  Future<void> sendEvent(Map<String, dynamic> event) async {
    await messenger.handlePlatformMessage(
      'com.simbridge/callkit/events',
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  group('methods', () {
    test('reportCall sends the CallInfo map', () async {
      final bridge = CallKitBridge();
      await bridge.reportCall(demoCall());

      expect(calls, hasLength(1));
      expect(calls.single.method, 'reportCall');
      final args =
          Map<String, dynamic>.from(calls.single.arguments as Map);
      final info = Map<String, dynamic>.from(args['call'] as Map);
      expect(info['cid'], 'c1');
      expect(info['num'], '+989121234567');
      expect(info['name'], 'سارا احمدی');
      expect(info['state'], 'ringing');
      expect(info['dir'], 'in');
      expect(info['hold'], isTrue);
    });

    test('reconcile sends the live call list', () async {
      final bridge = CallKitBridge();
      await bridge.reconcile(
          [demoCall(), demoCall(state: 'active')]);

      expect(calls.single.method, 'reconcile');
      final args =
          Map<String, dynamic>.from(calls.single.arguments as Map);
      final list = args['calls'] as List;
      expect(list, hasLength(2));
      expect((list[0] as Map)['state'], 'ringing');
      expect((list[1] as Map)['state'], 'active');
    });

    test('linkLost / dialAccepted take no arguments', () async {
      final bridge = CallKitBridge();
      await bridge.linkLost();
      await bridge.dialAccepted();

      expect(
          calls.map((c) => c.method).toList(),
          ['linkLost', 'dialAccepted']);
      expect(calls[0].arguments, isNull);
      expect(calls[1].arguments, isNull);
    });

    test('dialFailed carries the error', () async {
      final bridge = CallKitBridge();
      await bridge.dialFailed('no route');

      expect(calls.single.method, 'dialFailed');
      expect((calls.single.arguments as Map)['err'], 'no route');
    });

    test('startOutgoing carries num and optional sub', () async {
      final bridge = CallKitBridge();
      await bridge.startOutgoing('+989121234567', sub: 2);
      await bridge.startOutgoing('+989121234567');

      expect(calls, hasLength(2));
      expect(calls[0].method, 'startOutgoing');
      expect((calls[0].arguments as Map)['num'], '+989121234567');
      expect((calls[0].arguments as Map)['sub'], 2);
      expect(calls[1].method, 'startOutgoing');
      expect((calls[1].arguments as Map).containsKey('sub'), isFalse);
    });

    test('UI actions carry cid (and on / digit)', () async {
      final bridge = CallKitBridge();
      await bridge.answer('c1');
      await bridge.end('c1');
      await bridge.setMuted('c1', true);
      await bridge.setHeld('c1', false);
      await bridge.dtmf('c1', '5');
      await bridge.take('c1');
      await bridge.setSpeaker(true);

      expect(
          calls.map((c) => c.method).toList(),
          ['answer', 'end', 'setMuted', 'setHeld', 'dtmf', 'take',
           'setSpeaker']);
      expect((calls[0].arguments as Map)['cid'], 'c1');
      expect((calls[1].arguments as Map)['cid'], 'c1');
      expect((calls[2].arguments as Map)['on'], isTrue);
      expect((calls[3].arguments as Map)['on'], isFalse);
      expect((calls[4].arguments as Map)['d'], '5');
      expect((calls[5].arguments as Map)['cid'], 'c1');
      expect((calls[6].arguments as Map)['on'], isTrue);
    });
  });

  group('events', () {
    // Plain `test`, not `testWidgets`: the EventChannel stream is
    // driven through the binary messenger and needs no widget tree.
    // (A `testWidgets` version of this test hangs at runner shutdown
    // in this Flutter version — the FakeAsync zone never releases
    // the channel's broadcast stream.)
    test('CallKit actions parse from the event stream', () async {
      final bridge = CallKitBridge();
      final seen = <CallKitAction>[];
      final sub = bridge.actions.listen(seen.add);
      addTearDown(sub.cancel);

      await sendEvent({'t': 'answer', 'cid': 'c1'});
      await sendEvent({'t': 'reject', 'cid': 'c1'});
      await sendEvent({'t': 'end', 'cid': 'c1'});
      await sendEvent({'t': 'hold', 'cid': 'c1', 'on': true});
      await sendEvent({'t': 'mute', 'on': false});
      await sendEvent({'t': 'dtmf', 'cid': 'c1', 'd': '5'});
      await sendEvent({'t': 'dial', 'num': '+989121234567', 'sub': 2});
      await sendEvent({'t': 'take', 'cid': 'c1'});
      await sendEvent(
          {'t': 'dialFailed', 'num': '+989121234567', 'err': 'busy'});
      // Let the stream deliver (real time here, not fake async).
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
          seen.map((a) => a.kind).toList(),
          ['answer', 'reject', 'end', 'hold', 'mute', 'dtmf', 'dial',
           'take', 'dialFailed']);
      expect(seen[1].cid, 'c1');
      expect(seen[2].cid, 'c1');
      expect(seen[3].cid, 'c1');
      expect(seen[3].on, isTrue);
      // mute without a call id (the manager only adds cid when known).
      expect(seen[4].cid, isNull);
      expect(seen[4].on, isFalse);
      expect(seen[5].digit, '5');
      expect(seen[6].num, '+989121234567');
      expect(seen[6].sub, 2);
      expect(seen[7].cid, 'c1');
      expect(seen[8].num, '+989121234567');
      expect(seen[8].err, 'busy');
    });

    test('a non-map event parses to an empty action', () {
      expect(CallKitAction.parse('garbage').kind, '');
      expect(CallKitAction.parse(null).kind, '');
    });
  });

  group('toMessage', () {
    test('every action kind maps to its call.* message', () {
      final answer =
          CallKitAction.parse({'t': 'answer', 'cid': 'c1'}).toMessage();
      expect(answer?.t, 'call.answer');
      expect(answer?.b['cid'], 'c1');

      final end =
          CallKitAction.parse({'t': 'end', 'cid': 'c1'}).toMessage();
      expect(end?.t, 'call.end');
      expect(end?.b['cid'], 'c1');

      final reject =
          CallKitAction.parse({'t': 'reject', 'cid': 'c1'}).toMessage();
      expect(reject?.t, 'call.reject');

      final hold = CallKitAction.parse(
              {'t': 'hold', 'cid': 'c1', 'on': true})
          .toMessage();
      expect(hold?.t, 'call.hold');
      expect(hold?.b['on'], isTrue);

      final mute =
          CallKitAction.parse({'t': 'mute', 'on': false}).toMessage();
      expect(mute?.t, 'call.mute');
      expect(mute?.b['on'], isFalse);
      expect(mute?.b.containsKey('cid'), isFalse);

      // Even when a cid is known, `call.mute` carries only `on`
      // (PROTOCOL §5).
      final muteWithCid = CallKitAction.parse(
              {'t': 'mute', 'cid': 'c1', 'on': true})
          .toMessage();
      expect(muteWithCid?.t, 'call.mute');
      expect(muteWithCid?.b, {'on': true});

      final dtmf = CallKitAction.parse(
              {'t': 'dtmf', 'cid': 'c1', 'd': '5'})
          .toMessage();
      expect(dtmf?.t, 'call.dtmf');
      expect(dtmf?.b['d'], '5');

      final dial = CallKitAction.parse(
              {'t': 'dial', 'num': '+989121234567', 'sub': 2})
          .toMessage();
      expect(dial?.t, 'call.dial');
      expect(dial?.b['num'], '+989121234567');
      expect(dial?.b['sub'], 2);

      final take =
          CallKitAction.parse({'t': 'take', 'cid': 'c1'}).toMessage();
      expect(take?.t, 'call.take');
      expect(take?.b['cid'], 'c1');
    });

    test('dialFailed and unknown kinds map to null', () {
      expect(
          CallKitAction.parse(
                  {'t': 'dialFailed', 'num': 'x', 'err': 'busy'})
              .toMessage(),
          isNull);
      expect(CallKitAction.parse({'t': 'bogus'}).toMessage(), isNull);
      expect(CallKitAction.parse(null).toMessage(), isNull);
    });
  });
}
