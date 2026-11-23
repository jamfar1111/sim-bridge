// Deep-link routing tests (`simbridge://…`): the Bark alert tap
// opens the app through its URL scheme (registered in
// `ios/Runner/Info.plist`), and [DeepLinkHandler] routes it to the
// call screen or an SMS thread. No plugin, no native code: the
// link stream and the initial link are injected.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/ui/ui.dart';

void main() {
  group('DeepLinkHandler', () {
    test('call link opens the call screen for a live call', () {
      final model = AppModel.demo();
      model.simulateIncomingCall(number: '+989121234567', name: 'Sara');
      final cid = model.liveCalls.keys.single;
      final handler = DeepLinkHandler(model);
      handler.handleUri(Uri.parse('simbridge://call?cid=$cid'));
      expect(model.showCallScreen, isTrue);
      model.endCall(model.callScreen!.uuid);
    });

    test('call link for an unknown call shows a notice', () {
      final model = AppModel.demo();
      final handler = DeepLinkHandler(model);
      handler.handleUri(Uri.parse('simbridge://call?cid=nope'));
      expect(model.showCallScreen, isFalse);
      expect(model.notice, isNotNull);
    });

    test('sms link switches to the Messages tab and queues the thread',
        () {
      final model = AppModel.demo();
      final handler = DeepLinkHandler(model);
      handler.handleUri(Uri.parse('simbridge://sms?thread=2'));
      expect(model.tabIndex, 3);
      expect(model.pendingThread, 2);
    });

    test('sms link with an unparseable thread shows a notice (N11)',
        () {
      final model = AppModel.demo();
      final handler = DeepLinkHandler(model);
      handler.handleUri(Uri.parse('simbridge://sms?thread=abc'));
      expect(model.tabIndex, 0);
      expect(model.pendingThread, isNull);
      expect(model.notice, 'پیوند پیامک معتبر نیست.');
    });

    test('unknown schemes and hosts are ignored', () {
      final model = AppModel.demo();
      final handler = DeepLinkHandler(model);
      handler.handleUri(Uri.parse('https://example.com/call?cid=x'));
      handler.handleUri(Uri.parse('simbridge://unknown'));
      expect(model.tabIndex, 0);
      expect(model.pendingThread, isNull);
      expect(model.showCallScreen, isFalse);
    });

    test('start handles the initial link and the stream', () async {
      final model = AppModel.demo();
      final links = StreamController<Uri>();
      addTearDown(links.close);
      final handler = DeepLinkHandler(
        model,
        linkStream: links.stream,
        initialLink: () async => Uri.parse('simbridge://sms?thread=1'),
      );
      await handler.start();
      expect(model.tabIndex, 3);
      expect(model.pendingThread, 1);
      model.pendingThread = null;
      links.add(Uri.parse('simbridge://sms?thread=4'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(model.pendingThread, 4);
      await handler.stop();
    });
  });
}
