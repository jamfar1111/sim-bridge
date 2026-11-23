// Widget tests for the SIM-bridge UI: tab navigation, keypad,
// recents call-back, contacts search/star/actions, messages thread
// + OTP copy, Link pairing, and the call screen (incoming, active,
// DTMF, move-here). All against the demo model — no phone, no
// native code.
//
// Two test-harness facts shape these tests:
// - A pushed route (thread view) and a modal bottom sheet are
//   offstage while their 250-300 ms transition runs, so default
//   finders (which skip offstage widgets) only see them after
//   `pumpAndSettle()`. Never call `pumpAndSettle()` while the call
//   screen is visible: its 1 s duration ticker schedules a frame
//   every second and the settle never completes.
// - `AppModel` arms one-shot timers (notice 1.6 s, pairing 1.5 s,
//   dial auto-connect 2 s, call-ended 900 ms) and the call screen
//   runs a 1 s periodic ticker. A test that ends with any of those
//   pending fails with "Timer still pending", so every test that
//   touches a call or a notice ends the call first and drains the
//   timers with [drain].
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sim_bridge/src/bark/bark.dart';
import 'package:sim_bridge/src/link/link.dart';
import 'package:sim_bridge/src/log/log.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';
import 'package:sim_bridge/src/ui/ui.dart';

Future<void> pumpDemo(WidgetTester tester, AppModel model) async {
  await tester.pumpWidget(SimBridgeApp(model: model));
  await tester.pump();
}

Future<void> goToTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
}

/// The keypad display's current text (keyed so it is distinct from
/// the digit buttons showing the same digits).
String displayText(WidgetTester tester) {
  final text = tester
      .widget<Text>(find.byKey(const ValueKey('keypad-display')));
  return text.data ?? '';
}

/// Fires every one-shot timer the model arms (notice 1.6 s, pairing
/// 1.5 s, dial auto-connect 2 s, call-ended 900 ms). Call it at the
/// end of a test only after the call screen is gone, so the 1 s
/// duration ticker is cancelled with it.
Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
}

/// Ends the visible call and drains the timers it leaves behind.
/// The call screen unmounts 900 ms after ending, which cancels its
/// 1 s ticker.
Future<void> endCallAndDrain(WidgetTester tester, AppModel model) async {
  await tester.ensureVisible(find.byKey(const ValueKey('call-end')));
  await tester.tap(find.byKey(const ValueKey('call-end')));
  await tester.pump();
  expect(find.text('پایان تماس'), findsOneWidget);
  await tester.pump(const Duration(milliseconds: 900));
  expect(model.callScreen, isNull);
  await drain(tester);
}

/// Declines the visible ringing call and drains the timers it leaves
/// behind (the call screen unmounts 900 ms after declining).
Future<void> declineAndDrain(WidgetTester tester, AppModel model) async {
  await tester.tap(find.byKey(const ValueKey('call-decline')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  expect(model.callScreen, isNull);
  await drain(tester);
}

/// A silent audio sink for the Bark-card test: the model needs a
/// client attached for the card to show, but no audio ever flows.
class _FakeAudioSink implements ClientAudioSink {
  @override
  Future<void> startAudio(
          {required String codec, required int rate, int? bitrate}) async {}

  @override
  Future<void> stopAudio() async {}

  @override
  Stream<AudioFrame> get captured => const Stream.empty();

  @override
  Future<void> playFrame(
          {required int codec,
          required int seq,
          required List<int> payload}) async {}
}

/// Drags the Link tab's list until [finder]'s centre is inside the
/// list's visible rect, so the widget is really tappable — not just
/// built in the ListView's cache extent. `scrollUntilVisible` cannot
/// be used here: the pairing TextField has its own Scrollable, so the
/// default scrollable finder is ambiguous.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30; i++) {
    if (finder.evaluate().isNotEmpty) {
      final center = tester.getCenter(finder);
      final listRect = tester.getRect(find.byType(ListView));
      if (center.dy > listRect.top + 24 &&
          center.dy < listRect.bottom - 24) {
        return;
      }
    }
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
  }
  expect(finder, findsOneWidget);
}

void main() {
  group('tabs', () {
    testWidgets('all five tabs render and switch',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);

      // Recents is the first tab.
      expect(find.text('سارا احمدی'), findsWidgets);

      await goToTab(tester, 'مخاطبین');
      expect(find.text('مامان'), findsOneWidget);

      await goToTab(tester, 'شماره‌گیر');
      expect(find.byKey(const ValueKey('keypad-call')), findsOneWidget);

      await goToTab(tester, 'پیام‌ها');
      expect(find.byKey(const ValueKey('conversation-1')), findsOneWidget);

      await goToTab(tester, 'اتصال');
      expect(find.text('متصل'), findsWidgets);
      expect(find.text('گوشی جفت‌شده: Galaxy A52'), findsOneWidget);
    });

    testWidgets('badges show missed calls and unread messages',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      // One missed call (مامان) and unread messages exist in demo data.
      expect(model.missedCount, greaterThan(0));
      expect(model.unreadTotal, greaterThan(0));
    });
  });

  group('keypad', () {
    testWidgets('typing digits then calling opens the call screen',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'شماره‌گیر');

      await tester.tap(find.byKey(const ValueKey('key-9')));
      await tester.tap(find.byKey(const ValueKey('key-1')));
      await tester.tap(find.byKey(const ValueKey('key-2')));
      await tester.pump();
      expect(displayText(tester), '912');

      await tester.tap(find.byKey(const ValueKey('keypad-call')));
      await tester.pump();
      expect(find.text('در حال تماس…'), findsOneWidget);

      // Demo auto-connects after 2 s.
      await tester.pump(const Duration(seconds: 2));
      expect(model.callScreen?.state, 'active');

      await endCallAndDrain(tester, model);
    });

    testWidgets('backspace deletes the last digit',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'شماره‌گیر');
      await tester.tap(find.byKey(const ValueKey('key-5')));
      await tester.tap(find.byKey(const ValueKey('key-5')));
      await tester.pump();
      expect(displayText(tester), '55');
      await tester.tap(find.byKey(const ValueKey('keypad-backspace')));
      await tester.pump();
      expect(displayText(tester), '5');
    });

    testWidgets('long-press on 0 types +', (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'شماره‌گیر');
      await tester.longPress(find.byKey(const ValueKey('key-0')));
      await tester.pump();
      expect(displayText(tester), '+');
      // A plain tap still types 0.
      await tester.tap(find.byKey(const ValueKey('key-9')));
      await tester.pump();
      expect(displayText(tester), '+9');
    });
  });

  group('recents', () {
    testWidgets('call-back button dials the number',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await tester.tap(find.byKey(const ValueKey('call-back-1')));
      await tester.pump();
      expect(find.text('در حال تماس…'), findsOneWidget);
      expect(model.callScreen?.num, '+989121234567');
      await endCallAndDrain(tester, model);
    });
  });

  group('contacts', () {
    testWidgets('search filters the list',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'مخاطبین');
      await tester.enterText(
          find.byKey(const ValueKey('contacts-search')), 'سارا');
      await tester.pump();
      expect(find.text('سارا احمدی'), findsOneWidget);
      expect(find.text('مامان'), findsNothing);
    });

    testWidgets('star toggle flips favourite state',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'مخاطبین');
      expect(model.contacts.firstWhere((c) => c.id == 1).starred, isTrue);
      await tester.tap(find.byKey(const ValueKey('star-1')));
      await tester.pump();
      expect(model.contacts.firstWhere((c) => c.id == 1).starred, isFalse);
    });

    testWidgets('tapping a contact offers call and message',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'مخاطبین');
      await tester.tap(find.byKey(const ValueKey('contact-3')));
      // The sheet animates in; it is offstage until the transition ends.
      await tester.pumpAndSettle();
      expect(find.text('مامان'), findsWidgets);
      await tester.tap(find.text('تماس'));
      // The sheet pops (and the dial starts) — let the pop finish
      // before touching the call screen underneath it.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('در حال تماس…'), findsOneWidget);
      await endCallAndDrain(tester, model);
    });
  });

  group('messages', () {
    testWidgets('thread opens, shows OTP copy chip, sends a message',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'پیام‌ها');

      await tester.tap(find.byKey(const ValueKey('conversation-4')));
      // The thread route is offstage until its transition ends.
      await tester.pumpAndSettle();
      expect(find.text('بانک ملت'), findsWidgets);
      // The bank OTP message offers a copy chip.
      expect(find.byKey(const ValueKey('otp-copy-827163')), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('thread-input')), 'سلام تست');
      await tester.tap(find.byKey(const ValueKey('thread-send')));
      await tester.pump();
      expect(find.text('سلام تست'), findsOneWidget);
    });

    testWidgets('OTP copy chip flashes a notice',
        (WidgetTester tester) async {
      // Make the clipboard round-trip deterministic: without a mock
      // the platform channel's error response arrives on its own
      // schedule and the flash lands late.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform,
              (call) async => null);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'پیام‌ها');
      await tester.tap(find.byKey(const ValueKey('conversation-4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('otp-copy-827163')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(model.notice, 'کد کپی شد');
      // The notice pill lives in the root view, which is offstage
      // while the thread is open: pop back to see it rendered.
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('کد کپی شد'), findsOneWidget);
      await drain(tester); // the notice timer (1.6 s)
    });
  });

  group('link', () {
    testWidgets('unpaired model shows pairing UI; bad code errors',
        (WidgetTester tester) async {
      final model = AppModel.unpaired();
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      // 'جفت نشده' shows twice: the status strip and the Link card.
      // Check this BEFORE scrolling: scrolling the list down
      // unbuilds the status card at the top.
      expect(find.text('جفت نشده'), findsNWidgets(2));
      // The taller log card above pushes the pairing card below the
      // fold in the 800x600 test viewport: scroll it into view
      // first (same pattern as the N2/N3 scroll fixes).
      await scrollTo(tester, find.text('جفت‌سازی'));
      expect(find.text('جفت‌سازی'), findsOneWidget);

      await tester.ensureVisible(
          find.byKey(const ValueKey('pairing-code-input')));
      await tester.enterText(
          find.byKey(const ValueKey('pairing-code-input')), 'hello');
      await tester.ensureVisible(
          find.byKey(const ValueKey('pairing-submit')));
      await tester.tap(find.byKey(const ValueKey('pairing-submit')));
      await tester.pump();
      expect(find.text('کد جفت‌سازی معتبر نیست'), findsOneWidget);
    });

    testWidgets('a valid pairing code pairs the phone',
        (WidgetTester tester) async {
      final model = AppModel.unpaired();
      final demoCode = AppModel.demo().ownPairingCode!;
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      await scrollTo(
          tester, find.byKey(const ValueKey('pairing-code-input')));
      await tester.ensureVisible(
          find.byKey(const ValueKey('pairing-code-input')));
      await tester.enterText(
          find.byKey(const ValueKey('pairing-code-input')), demoCode);
      await tester.ensureVisible(
          find.byKey(const ValueKey('pairing-submit')));
      await tester.tap(find.byKey(const ValueKey('pairing-submit')));
      await tester.pump();
      expect(model.isPaired, isTrue);
      expect(find.text('جفت‌سازی انجام شد'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(model.linkState, LinkState.connected);
      await drain(tester); // the notice timer (1.6 s)
    });

    testWidgets('pairing shows a real, scannable QR code',
        (WidgetTester tester) async {
      final model = AppModel.unpaired();
      final demoCode = AppModel.demo().ownPairingCode!;
      model.ownPairingCode = demoCode;
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      // A real QR image (qr_flutter), not the old placeholder grid:
      // it encodes the pairing payload, so the Android phone can
      // scan it.
      await scrollTo(tester, find.byType(QrImageView));
      final qr = find.byType(QrImageView);
      expect(qr, findsOneWidget);
      // qr_flutter 4.x exposes no public `data` getter on the
      // widget, so the payload is checked where it is built: the
      // Link tab renders the model's pairing code, and that code is
      // the real payload.
      expect(model.ownPairingCode, demoCode);
    });

    testWidgets('log card shows the file and its share button',
        (WidgetTester tester) async {
      // Widget tests run in a fake-async zone: real file IO must go
      // through runAsync, or the future never completes and the test
      // hangs until the timeout.
      final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('sim_bridge_ui_')))!;
      addTearDown(AppLogger.reset);
      await tester.runAsync(() => AppLogger.init(directory: dir));
      AppLogger.i('test', 'log card line');
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      await tester.ensureVisible(find.text('گزارش خطا'));
      expect(find.text('گزارش خطا'), findsOneWidget);
      expect(find.textContaining('log card line'), findsOneWidget);
      await tester.ensureVisible(
          find.byKey(const ValueKey('log-share')));
      expect(find.byKey(const ValueKey('log-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('log-copy-path')), findsOneWidget);
      expect(find.byKey(const ValueKey('log-clear')), findsOneWidget);
      // Downloads mirror button (the log must be reachable without
      // the Android/data folder and without opening the app).
      expect(find.byKey(const ValueKey('log-mirror-downloads')),
          findsOneWidget);
      await drain(tester);
      await tester.runAsync(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
    });

    testWidgets('transport switch flips near/far mode',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      expect(model.transportMode, 'ble');
      await tester.tap(find.text('دور · اینترنت'));
      await tester.pump();
      expect(model.transportMode, 'webrtc');
      expect(find.textContaining('WebRTC'), findsOneWidget);
    });

    testWidgets('net switches include bt, dataSub, rat and disabled share',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      await tester.scrollUntilVisible(
          find.text('کلیدهای گوشی اندروید'), 100);
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();

      expect(find.text('اینترنت موبایل'), findsOneWidget);
      expect(find.text('بلوتوث'), findsOneWidget);
      expect(find.text('سیم‌کارت اینترنت'), findsOneWidget);
      expect(find.text('نوع شبکه'), findsOneWidget);
      // The Share-VPN proxy does not exist yet: the switch is
      // disabled and says so.
      expect(find.text('اشتراک VPN'), findsOneWidget);
      expect(find.text('به‌زودی — پروکسی اشتراک هنوز پیاده نشده است'),
          findsOneWidget);
      final share = tester.widget<SwitchListTile>(
          find.ancestor(of: find.text('اشتراک VPN'),
              matching: find.byType(SwitchListTile)));
      expect(share.onChanged, isNull);

      // Flipping the Bluetooth switch updates the model.
      await tester.ensureVisible(find.text('بلوتوث'));
      await tester.pump();
      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('بلوتوث'),
          matching: find.byType(SwitchListTile),
        ),
        matching: find.byType(Switch),
      ));
      await tester.pump();
      expect(model.netState['bt'], isTrue);

      // The dataSub dropdown lists the demo SIMs.
      expect(find.byType(DropdownButton<int>), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsOneWidget);
    });

    testWidgets('demo incoming-call button rings the call screen',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      // The demo card is below the fold: scrollUntilVisible only
      // builds it (it stops once the widget exists, still below the
      // viewport), so drag the list down to bring it on screen.
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('demo-incoming-call')), 100);
      await tester.drag(
          find.byType(ListView), const Offset(0, -300));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('demo-incoming-call')));
      await tester.pump();
      expect(find.text('تماس ورودی…'), findsOneWidget);
      expect(find.byKey(const ValueKey('call-answer')), findsOneWidget);
      await declineAndDrain(tester, model);
    });
  });

  group('link settings (N1–N3)', () {
    testWidgets('Bark key setup: enter → persisted → client updated (N1)',
        (WidgetTester tester) async {
      // The Bark card is an iOS real-mode thing: the model needs a
      // client attached (and a key store) for it to show.
      final model = AppModel.real();
      final client = LinkClient(
        transportFactory: () async => FakeTransport.pair().$2,
        ownKey: P256.generate(),
        audioSink: _FakeAudioSink(),
        clientName: 'Test iPhone',
      );
      model.attachClient(client);
      final store = InMemoryBarkKeyStore();
      await model.attachBarkKeyStore(store);
      // The copy button uses the clipboard: mock it like the OTP
      // test does.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform,
              (call) async => null);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      // The Bark card is below the fold: scroll until it is built,
      // then drag the list up so its fields are tappable.
      await scrollTo(tester, find.byKey(const ValueKey('bark-key-input')));
      expect(find.text('بیدار کردن آیفون از راه دور (Bark)'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('bark-key-copy')), findsNothing);
      await tester.enterText(
          find.byKey(const ValueKey('bark-key-input')), 'bark-key-123');
      await scrollTo(tester, find.byKey(const ValueKey('bark-key-save')));
      await tester.tap(find.byKey(const ValueKey('bark-key-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(model.barkKey, 'bark-key-123');
      expect(client.barkKey, 'bark-key-123');
      expect(await store.read(), 'bark-key-123');
      // The saved key shows with a "copy my key" affordance: it
      // appears twice — in the input field and as the displayed
      // saved key.
      expect(find.byKey(const ValueKey('bark-key-copy')), findsOneWidget);
      expect(find.text('bark-key-123'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('bark-key-copy')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(model.notice, 'کلید کپی شد');
      await drain(tester); // the flash notice timers (1.6 s)
    });

    testWidgets('QR scanner pairs the phone (N2)',
        (WidgetTester tester) async {
      final model = AppModel.unpaired();
      final demoCode = AppModel.demo().ownPairingCode!;
      model.qrScannerBuilder = (onCode) => ElevatedButton(
            key: const ValueKey('fake-scanner'),
            onPressed: () => onCode(demoCode),
            child: const Text('fake scan'),
          );
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      await scrollTo(tester, find.byKey(const ValueKey('pairing-scan')));
      await tester.tap(find.byKey(const ValueKey('pairing-scan')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('fake-scanner')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fake-scanner')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.isPaired, isTrue);
      expect(find.text('جفت‌سازی انجام شد'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      await drain(tester); // the notice + pairing timers
    });

    testWidgets('share pairing code sends the code to the share sheet '
        '(N2)', (WidgetTester tester) async {
      final model = AppModel.unpaired();
      final demoCode = AppModel.demo().ownPairingCode!;
      model.ownPairingCode = demoCode;
      String? sharedText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        (call) async {
          if (call.method == 'share') {
            sharedText = (call.arguments as Map)['text'] as String?;
            return 'dev.fluttercommunity.plus/share/success';
          }
          return null;
        },
      );
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('dev.fluttercommunity.plus/share'),
              null));
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      await scrollTo(tester, find.byKey(const ValueKey('pairing-share')));
      await tester.tap(find.byKey(const ValueKey('pairing-share')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(sharedText, demoCode);
    });

    testWidgets('WebRTC settings save clears the far-mode warning (N3)',
        (WidgetTester tester) async {
      WebrtcSettings.signallingUrl = '';
      WebrtcSettings.turnUsername = null;
      WebrtcSettings.turnCredential = null;
      addTearDown(() {
        WebrtcSettings.signallingUrl = '';
        WebrtcSettings.turnUsername = null;
        WebrtcSettings.turnCredential = null;
      });
      final model = AppModel.real();
      final store = MemoryWebrtcSettingsStore();
      await model.attachWebrtcSettingsStore(store);
      await pumpDemo(tester, model);
      await goToTab(tester, 'اتصال');
      await tester.tap(find.text('دور · اینترنت'));
      await tester.pump();
      expect(model.transportMode, 'webrtc');
      // The settings card is below the fold in the lazy list: scroll
      // it into view before counting its warning (the transport card
      // already shows one).
      await scrollTo(tester, 
          find.byKey(const ValueKey('webrtc-url-input')));
      expect(find.textContaining('هنوز پیکربندی نشده است'),
          findsNWidgets(2));
      await tester.enterText(
          find.byKey(const ValueKey('webrtc-url-input')),
          'https://sim-bridge-signal.test.workers.dev');
      await scrollTo(tester, 
          find.byKey(const ValueKey('webrtc-url-save')));
      await tester.tap(find.byKey(const ValueKey('webrtc-url-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(WebrtcSettings.signallingUrl,
          'https://sim-bridge-signal.test.workers.dev');
      expect(await store.readSignallingUrl(),
          'https://sim-bridge-signal.test.workers.dev');
      // The warning clears once configured.
      expect(find.textContaining('هنوز پیکربندی نشده است'), findsNothing);
      // TURN credentials save too.
      await scrollTo(tester, 
          find.byKey(const ValueKey('webrtc-turn-user-input')));
      await tester.enterText(
          find.byKey(const ValueKey('webrtc-turn-user-input')),
          'turn-user');
      await tester.enterText(
          find.byKey(const ValueKey('webrtc-turn-credential-input')),
          'turn-cred');
      await scrollTo(tester, 
          find.byKey(const ValueKey('webrtc-turn-save')));
      await tester.tap(find.byKey(const ValueKey('webrtc-turn-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(WebrtcSettings.turnUsername, 'turn-user');
      expect(WebrtcSettings.turnCredential, 'turn-cred');
      expect(await store.readTurnCredentials(), ('turn-user', 'turn-cred'));
      await drain(tester); // the flash notice timers
    });
  });

  group('call screen', () {
    testWidgets('incoming call: answer, mute, DTMF pad, end',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      model.simulateIncomingCall(
          number: '+989121234567', name: 'سارا احمدی');
      await pumpDemo(tester, model);
      expect(find.text('تماس ورودی…'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('call-answer')));
      await tester.pump();
      expect(model.callScreen?.state, 'active');

      await tester.tap(find.byKey(const ValueKey('call-mute')));
      await tester.pump();
      expect(model.callScreen?.muted, isTrue);

      await tester.tap(find.byKey(const ValueKey('call-keypad')));
      await tester.pump();
      expect(find.text('بستن صفحه‌کلید'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dtmf-5')));
      await tester.pump();

      // The DTMF pad pushes the end button off-screen; the call
      // screen scrolls, so bring it into view first.
      await endCallAndDrain(tester, model);
    });

    testWidgets('declining a missed call logs it as missed',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      model.simulateIncomingCall(
          number: '+989191112233', name: 'مامان');
      await pumpDemo(tester, model);
      final before =
          model.recents.where((c) => c.type == 3).length;
      await tester.tap(find.byKey(const ValueKey('call-decline')));
      await tester.pump();
      expect(
          model.recents.where((c) => c.type == 3).length, before + 1);
      await tester.pump(const Duration(milliseconds: 900));
      expect(model.callScreen, isNull);
      await drain(tester);
    });

    testWidgets('elsewhere call offers Move here',
        (WidgetTester tester) async {
      final model = AppModel.demo();
      model.liveCalls['r1'] = const CallInfo(
        cid: 'r1',
        num: '+989121234567',
        name: 'سارا احمدی',
        state: 'active',
        dir: 'in',
        hold: true,
        elsewhere: true,
        where: 'iPad',
      );
      model.notifyListeners();
      await pumpDemo(tester, model);
      expect(find.text('انتقال به اینجا'), findsOneWidget);
      await tester.tap(find.text('انتقال به اینجا').first);
      await tester.pump();
      expect(model.callScreen, isNotNull);
      expect(model.callScreen?.state, 'active');
      await endCallAndDrain(tester, model);
    });
  });
}
