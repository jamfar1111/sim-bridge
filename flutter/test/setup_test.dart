// Tests for the Android first-launch setup flow (2026-11-23): the
// permission / Bluetooth / dialer / battery controller and the Link
// tab's setup card. All native calls are faked — no system dialogs.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:sim_bridge/src/link/link.dart';
import 'package:sim_bridge/src/setup/setup.dart';
import 'package:sim_bridge/src/ui/ui.dart';

/// Scriptable [SetupPermissions] fake: grants everything unless a
/// permission is in [requestDenied], reports [initiallyDenied] as
/// denied from [statuses], and records the call order (into [log]
/// when one is shared with the channel mocks, for timeline asserts).
class FakeSetupPermissions implements SetupPermissions {
  FakeSetupPermissions({
    this.initiallyDenied = const {},
    this.requestDenied = const {},
    this.permanentlyDeniedSet = const {},
    this.batteryExempt = false,
    List<String>? log,
  }) : _log = log ?? [];

  /// Permissions [statuses] reports as denied.
  final Set<ph.Permission> initiallyDenied;

  /// Permissions [requestAll] reports as denied.
  final Set<ph.Permission> requestDenied;

  /// Permissions reported as permanently denied.
  final Set<ph.Permission> permanentlyDeniedSet;

  bool batteryExempt;

  /// Permissions currently granted (stateful: [requestAll] grants
  /// everything except [requestDenied], so a later [statuses] call
  /// sees the grants — like the real system).
  late final Set<ph.Permission> _granted =
      Set.of(setupRuntimePermissions)..removeAll(initiallyDenied);

  /// Call order, for asserting the full flow runs in order.
  final List<String> calls = [];

  final List<String> _log;

  int settingsOpened = 0;

  Map<ph.Permission, bool> _all(bool Function(ph.Permission) f) =>
      {for (final p in setupRuntimePermissions) p: f(p)};

  @override
  Future<Map<ph.Permission, bool>> requestAll() async {
    calls.add('requestAll');
    _log.add('permissions.requestAll');
    _granted
      ..removeAll(requestDenied)
      ..addAll(setupRuntimePermissions
          .where((p) => !requestDenied.contains(p)));
    return _all((p) => _granted.contains(p));
  }

  @override
  Future<Map<ph.Permission, bool>> statuses() async {
    calls.add('statuses');
    _log.add('permissions.statuses');
    return _all((p) => _granted.contains(p));
  }

  @override
  Future<List<ph.Permission>> permanentlyDenied() async {
    calls.add('permanentlyDenied');
    _log.add('permissions.permanentlyDenied');
    return permanentlyDeniedSet.toList();
  }

  @override
  Future<bool> requestBatteryExemption() async {
    calls.add('requestBatteryExemption');
    _log.add('permissions.requestBatteryExemption');
    batteryExempt = true;
    return batteryExempt;
  }

  @override
  Future<bool> batteryExemptionGranted() async {
    calls.add('batteryExemptionGranted');
    _log.add('permissions.batteryExemptionGranted');
    return batteryExempt;
  }

  @override
  Future<void> openSettings() async {
    calls.add('openSettings');
    _log.add('permissions.openSettings');
    settingsOpened++;
  }
}

AndroidSetup makeSetup({
  FakeSetupPermissions? permissions,
  MemorySetupFlagStore? flagStore,
  Map<String, dynamic>? bleState,
  Map<String, dynamic>? telecomState,
}) {
  return AndroidSetup(
    ble: BleLink(),
    telecom: TelecomBridge(),
    permissions: permissions ?? FakeSetupPermissions(),
    flagStore: flagStore ?? MemorySetupFlagStore(),
  );
}

/// Installs mock handlers for the `com.simbridge/ble` and
/// `com.simbridge/telecom` channels used by [AndroidSetup].
/// `bleState` / `telecomState` hold the scripted answers
/// (`isBluetoothOn`, `requestEnableBluetooth`, `isDefaultDialer`,
/// `requestDefaultDialer`); every call is recorded in `calls`.
/// Stateful like the real system: a successful enable/request
/// sticks, so a later state read sees it.
void mockSetupChannels(
  Map<String, dynamic> bleState,
  Map<String, dynamic> telecomState,
  List<String> calls,
) {
  var btOn = bleState['isBluetoothOn'] as bool? ?? false;
  var dialerOn = telecomState['isDefaultDialer'] as bool? ?? false;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('com.simbridge/ble'), (call) async {
    calls.add('ble.${call.method}');
    return switch (call.method) {
      'isBluetoothOn' => btOn,
      'requestEnableBluetooth' => btOn =
          bleState['requestEnableBluetooth'] as bool? ?? false,
      _ => null,
    };
  });
  messenger.setMockMethodCallHandler(
      const MethodChannel('com.simbridge/telecom'), (call) async {
    calls.add('telecom.${call.method}');
    return switch (call.method) {
      'isDefaultDialer' => dialerOn,
      'requestDefaultDialer' => dialerOn =
          telecomState['requestDefaultDialer'] as bool? ?? false,
      _ => null,
    };
  });
}

void clearSetupChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('com.simbridge/ble'), null);
  messenger.setMockMethodCallHandler(
      const MethodChannel('com.simbridge/telecom'), null);
}

void main() {
  group('AndroidSetup controller', () {
    late List<String> calls;

    setUp(() {
      calls = [];
    });

    tearDown(clearSetupChannels);

    test('refresh reads all four states', () async {
      mockSetupChannels(
        {'isBluetoothOn': true, 'requestEnableBluetooth': true},
        {'isDefaultDialer': true, 'requestDefaultDialer': true},
        calls,
      );
      final setup = makeSetup(
        permissions: FakeSetupPermissions(batteryExempt: true),
      );
      await setup.refresh();
      expect(setup.permissionsGranted, isTrue);
      expect(setup.bluetoothOn, isTrue);
      expect(setup.isDialer, isTrue);
      expect(setup.batteryExempt, isTrue);
      expect(setup.isComplete, isTrue);
    });

    test('refresh tolerates a throwing channel', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/ble'), (call) async {
        throw PlatformException(code: 'boom');
      });
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/telecom'), (call) async {
        return switch (call.method) {
          'isDefaultDialer' => true,
          _ => null,
        };
      });
      final setup = makeSetup(
        permissions: FakeSetupPermissions(batteryExempt: true),
      );
      await setup.refresh();
      // Bluetooth stays missing, the rest still computed.
      expect(setup.bluetoothOn, isFalse);
      expect(setup.isDialer, isTrue);
      expect(setup.batteryExempt, isTrue);
      expect(setup.isComplete, isFalse);
    });

    test('requestPermissions records denials', () async {
      mockSetupChannels({}, {}, calls);
      final setup = makeSetup(
        permissions: FakeSetupPermissions(
          requestDenied: {ph.Permission.sms, ph.Permission.camera},
          permanentlyDeniedSet: {ph.Permission.camera},
        ),
      );
      final ok = await setup.requestPermissions();
      expect(ok, isFalse);
      expect(setup.permissionsGranted, isFalse);
      expect(setup.permanentlyDeniedPermissions,
          contains(ph.Permission.camera));
    });

    test('runFullFlow requests only the missing items, in order',
        () async {
      mockSetupChannels(
        {'isBluetoothOn': false, 'requestEnableBluetooth': true},
        {'isDefaultDialer': false, 'requestDefaultDialer': true},
        calls,
      );
      final permissions = FakeSetupPermissions(
        initiallyDenied: Set.of(setupRuntimePermissions),
        log: calls,
      );
      final setup = makeSetup(permissions: permissions);
      await setup.runFullFlow();
      expect(setup.isComplete, isTrue);
      // The four action calls, in order, across both surfaces:
      // permissions → Bluetooth → dialer → battery.
      final actions = calls
          .where((c) =>
              c == 'permissions.requestAll' ||
              c == 'ble.requestEnableBluetooth' ||
              c == 'telecom.requestDefaultDialer' ||
              c == 'permissions.requestBatteryExemption')
          .toList();
      expect(actions, [
        'permissions.requestAll',
        'ble.requestEnableBluetooth',
        'telecom.requestDefaultDialer',
        'permissions.requestBatteryExemption',
      ]);
    });

    test('runFullFlow skips already-granted items', () async {
      mockSetupChannels(
        {'isBluetoothOn': true, 'requestEnableBluetooth': true},
        {'isDefaultDialer': true, 'requestDefaultDialer': true},
        calls,
      );
      final permissions =
          FakeSetupPermissions(batteryExempt: true);
      final setup = makeSetup(permissions: permissions);
      await setup.runFullFlow();
      expect(setup.isComplete, isTrue);
      expect(permissions.calls, isNot(contains('requestAll')));
      expect(
          permissions.calls, isNot(contains('requestBatteryExemption')));
      expect(calls, isNot(contains('ble.requestEnableBluetooth')));
      expect(calls, isNot(contains('telecom.requestDefaultDialer')));
    });

    test('a failing step does not stop the flow', () async {
      // Stateful mocks: granting the dialer role sticks, so the
      // final refresh still sees it; Bluetooth enable throws.
      var dialerGranted = false;
      const btOn = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/ble'), (call) async {
        calls.add('ble.${call.method}');
        if (call.method == 'requestEnableBluetooth') {
          throw PlatformException(code: 'bt-off');
        }
        if (call.method == 'isBluetoothOn') return btOn;
        return null;
      });
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.simbridge/telecom'), (call) async {
        calls.add('telecom.${call.method}');
        return switch (call.method) {
          'isDefaultDialer' => dialerGranted,
          'requestDefaultDialer' => dialerGranted = true,
          _ => null,
        };
      });
      final setup = makeSetup();
      await setup.runFullFlow();
      // Bluetooth failed, but dialer + battery still completed.
      expect(setup.bluetoothOn, isFalse);
      expect(setup.isDialer, isTrue);
      expect(setup.batteryExempt, isTrue);
      expect(setup.isComplete, isFalse);
    });

    test('auto-run flag: runs once, then never again', () async {
      final flagStore = MemorySetupFlagStore();
      final setup = makeSetup(flagStore: flagStore);
      expect(await setup.shouldAutoRun(), isTrue);
      await setup.markAutoRunComplete();
      expect(await setup.shouldAutoRun(), isFalse);
    });

    test('openSettings delegates to the permissions surface', () async {
      mockSetupChannels({}, {}, calls);
      final permissions = FakeSetupPermissions();
      final setup = makeSetup(permissions: permissions);
      await setup.openSettings();
      expect(permissions.settingsOpened, 1);
    });
  });

  group('Setup card (Link tab)', () {
    late List<String> calls;

    setUp(() {
      calls = [];
    });

    tearDown(clearSetupChannels);

    Future<void> pumpSetupCard(
      WidgetTester tester,
      AndroidSetup setup,
    ) async {
      final model = AppModel.real();
      model.attachSetup(setup);
      await tester.pumpWidget(SimBridgeApp(model: model));
      await tester.pump();
      await tester.tap(find.text('اتصال'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('shows the four items with actions', (tester) async {
      mockSetupChannels(
        {'isBluetoothOn': false, 'requestEnableBluetooth': false},
        {'isDefaultDialer': false, 'requestDefaultDialer': false},
        calls,
      );
      final setup = makeSetup(
        permissions: FakeSetupPermissions(
          initiallyDenied: Set.of(setupRuntimePermissions),
        ),
      );
      await pumpSetupCard(tester, setup);
      expect(find.text('راه‌اندازی'), findsOneWidget);
      expect(find.text('دسترسی‌های لازم'), findsOneWidget);
      expect(find.text('بلوتوث روشن'), findsOneWidget);
      expect(find.text('شماره‌گیر پیش‌فرض'), findsOneWidget);
      expect(find.text('معافیت باتری'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-request-all')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('setup-open-settings')),
          findsOneWidget);
      // Nothing granted yet: no green checks.
      expect(find.byIcon(Icons.check_circle), findsNothing);
    });

    testWidgets('request-all grants everything and completes the card',
        (tester) async {
      mockSetupChannels(
        {'isBluetoothOn': false, 'requestEnableBluetooth': true},
        {'isDefaultDialer': false, 'requestDefaultDialer': true},
        calls,
      );
      final setup = makeSetup(
        permissions: FakeSetupPermissions(
          initiallyDenied: Set.of(setupRuntimePermissions),
        ),
      );
      await pumpSetupCard(tester, setup);
      await tester.ensureVisible(
          find.byKey(const ValueKey('setup-request-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('setup-request-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(setup.isComplete, isTrue);
      expect(find.byIcon(Icons.check_circle), findsNWidgets(4));
      // The flash notice timer (1.6 s) must be drained.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('per-item action grants just that item', (tester) async {
      mockSetupChannels(
        {'isBluetoothOn': false, 'requestEnableBluetooth': true},
        {'isDefaultDialer': false, 'requestDefaultDialer': false},
        calls,
      );
      final setup = makeSetup(
        permissions: FakeSetupPermissions(
          initiallyDenied: Set.of(setupRuntimePermissions),
        ),
      );
      await pumpSetupCard(tester, setup);
      await tester.ensureVisible(
          find.byKey(const ValueKey('setup-bluetooth-action')));
      await tester.pump();
      await tester.tap(find.byKey(
          const ValueKey('setup-bluetooth-action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(setup.bluetoothOn, isTrue);
      expect(setup.isComplete, isFalse);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('failed dialer names the dialer role, not app settings',
        (tester) async {
      mockSetupChannels(
        {'isBluetoothOn': true, 'requestEnableBluetooth': true},
        {'isDefaultDialer': false, 'requestDefaultDialer': false},
        calls,
      );
      final setup = makeSetup(
        permissions: FakeSetupPermissions(batteryExempt: true),
      );
      await pumpSetupCard(tester, setup);
      // Only the dialer is missing; "request all" fails on it.
      await tester.ensureVisible(
          find.byKey(const ValueKey('setup-request-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('setup-request-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('راه‌اندازی کامل نشد؛ هنوز مانده: شماره‌گیر پیش‌فرض.'),
        findsOneWidget,
      );
      // The per-item dialer action names the role too, with no
      // "permanently denied" settings hint.
      await tester.ensureVisible(
          find.byKey(const ValueKey('setup-dialer-action')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('setup-dialer-action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('انتخاب شماره‌گیر پیش‌فرض کامل نشد؛ از دکمه‌اش در '
            'همین کارت دوباره امتحان کنید.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('card hidden without a setup controller', (tester) async {
      final model = AppModel.real();
      await tester.pumpWidget(SimBridgeApp(model: model));
      await tester.pump();
      await tester.tap(find.text('اتصال'));
      await tester.pump();
      expect(find.text('راه‌اندازی'), findsNothing);
    });
  });
}
