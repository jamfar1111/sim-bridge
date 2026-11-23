/// First-launch setup for the Android hub: runtime permissions,
/// Bluetooth on, default-dialer role, battery-optimisation exemption.
///
/// The app declares 31 permissions in AndroidManifest.xml but never
/// asked for any of them at runtime — there was no permission package
/// in pubspec, no `requestPermission` call in `lib/`, and no
/// `ActivityCompat.requestPermissions` in the Kotlin code (2026-11-23:
/// the user reported the app never asks for permissions and never
/// turns Bluetooth on — that code simply did not exist). This is the
/// missing piece: [AndroidSetup] runs the whole flow once on first
/// real-mode launch, and the Link tab's setup card lets the user
/// re-run any step by hand.
///
/// Android only: the iPhone client never constructs this (its
/// permissions are the iOS ones, handled by the OS prompts of the
/// features that need them).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

import '../link/channels.dart';
import '../log/log.dart';

/// The four setup items the Link tab's setup card shows.
enum SetupItem { permissions, bluetooth, dialer, battery }

extension SetupItemX on SetupItem {
  String get labelFa {
    switch (this) {
      case SetupItem.permissions:
        return 'دسترسی‌های لازم';
      case SetupItem.bluetooth:
        return 'بلوتوث روشن';
      case SetupItem.dialer:
        return 'شماره‌گیر پیش‌فرض';
      case SetupItem.battery:
        return 'معافیت باتری';
    }
  }

  String get hintFa {
    switch (this) {
      case SetupItem.permissions:
        return 'بلوتوث، پیامک، مخاطبین، تماس، اعلان، دوربین';
      case SetupItem.bluetooth:
        return 'برای تبلیغ بلوتوث و پیدا شدن توسط آیفون';
      case SetupItem.dialer:
        return 'برای دیدن تماس‌های زنده و نمایش صفحه تماس';
      case SetupItem.battery:
        return 'تا اندروید برنامه را در پس‌زمینه نبندد';
    }
  }
}

/// Runtime permissions the hub needs, as one group: requesting them
/// shows one system dialog per permission group, in this order.
const List<ph.Permission> setupRuntimePermissions = <ph.Permission>[
  ph.Permission.bluetoothAdvertise,
  ph.Permission.bluetoothConnect,
  ph.Permission.bluetoothScan,
  ph.Permission.sms,
  ph.Permission.contacts,
  ph.Permission.phone,
  ph.Permission.notification,
  ph.Permission.camera,
];

/// The runtime-permission surface [AndroidSetup] talks to, so tests
/// can substitute a fake instead of the system dialogs.
abstract class SetupPermissions {
  /// Requests every permission in [setupRuntimePermissions] and
  /// returns grant state per permission.
  Future<Map<ph.Permission, bool>> requestAll();

  /// Current grant state per permission in [setupRuntimePermissions].
  Future<Map<ph.Permission, bool>> statuses();

  /// Permissions in [setupRuntimePermissions] that are permanently
  /// denied (the user ticked "don't ask again"): only the app
  /// settings screen can grant those now.
  Future<List<ph.Permission>> permanentlyDenied();

  /// Opens the system "ignore battery optimisations" prompt for
  /// this app. Returns whether the exemption is held afterwards.
  Future<bool> requestBatteryExemption();

  /// Whether the battery-optimisation exemption is held.
  Future<bool> batteryExemptionGranted();

  /// Opens the app's system settings screen.
  Future<void> openSettings();
}

/// [SetupPermissions] backed by `permission_handler`.
class PermissionHandlerPermissions implements SetupPermissions {
  @override
  Future<Map<ph.Permission, bool>> requestAll() async {
    final result = await setupRuntimePermissions.request();
    return {
      for (final entry in result.entries)
        entry.key: entry.value.isGranted,
    };
  }

  @override
  Future<Map<ph.Permission, bool>> statuses() async {
    final out = <ph.Permission, bool>{};
    for (final permission in setupRuntimePermissions) {
      out[permission] = (await permission.status).isGranted;
    }
    return out;
  }

  @override
  Future<List<ph.Permission>> permanentlyDenied() async {
    final out = <ph.Permission>[];
    for (final permission in setupRuntimePermissions) {
      if ((await permission.status).isPermanentlyDenied) {
        out.add(permission);
      }
    }
    return out;
  }

  @override
  Future<bool> requestBatteryExemption() async {
    await ph.Permission.ignoreBatteryOptimizations.request();
    return batteryExemptionGranted();
  }

  @override
  Future<bool> batteryExemptionGranted() async => (await ph
          .Permission.ignoreBatteryOptimizations.status)
      .isGranted;

  @override
  Future<void> openSettings() => ph.openAppSettings();
}

/// The persisted "first-launch setup already ran" flag, so the
/// automatic flow never re-prompts on later launches (the Link tab's
/// setup card stays available for manual re-runs).
abstract class SetupFlagStore {
  Future<bool> readAutoRunDone();
  Future<void> writeAutoRunDone();
}

/// [SetupFlagStore] backed by shared preferences (same pattern as
/// the WebRTC settings store).
class SharedPrefsSetupFlagStore implements SetupFlagStore {
  SharedPrefsSetupFlagStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  static const String autoRunDoneKey = 'sim_bridge_setup_done';

  final SharedPreferencesAsync _prefs;

  @override
  Future<bool> readAutoRunDone() async =>
      await _prefs.getBool(autoRunDoneKey) ?? false;

  @override
  Future<void> writeAutoRunDone() =>
      _prefs.setBool(autoRunDoneKey, true);
}

/// In-memory [SetupFlagStore], for tests.
class MemorySetupFlagStore implements SetupFlagStore {
  bool _done = false;

  @override
  Future<bool> readAutoRunDone() async => _done;

  @override
  Future<void> writeAutoRunDone() async {
    _done = true;
  }
}

/// The Android first-launch setup flow: owns the four item states,
/// runs the requests, and notifies the setup card.
///
/// Every native call is guarded: a throwing channel or a denied
/// permission must never crash startup or the Link tab — the item
/// just stays "missing" and the user can retry it from the card.
class AndroidSetup extends ChangeNotifier {
  AndroidSetup({
    required this.ble,
    required this.telecom,
    required this.permissions,
    required this.flagStore,
  });

  final BleLink ble;
  final TelecomBridge telecom;
  final SetupPermissions permissions;
  final SetupFlagStore flagStore;

  bool permissionsGranted = false;
  bool bluetoothOn = false;
  bool isDialer = false;
  bool batteryExempt = false;

  /// Permissions the user permanently denied (only app settings
  /// can grant them now).
  List<ph.Permission> permanentlyDeniedPermissions = const [];

  /// True while any setup action is running (dialogs on screen):
  /// the card disables its buttons.
  bool busy = false;

  bool get isComplete =>
      permissionsGranted && bluetoothOn && isDialer && batteryExempt;

  /// Setup items still missing, in card order — so failure
  /// messages can name them instead of blaming permissions.
  List<SetupItem> get missingItems =>
      SetupItem.values.where((i) => !done(i)).toList();

  /// Whether the three providers the local lists read from may be
  /// read right now (phone permission → call log, contacts →
  /// contacts, sms → SMS). The model skips the sections whose
  /// permission is still missing and retries after a later grant.
  Future<({bool calls, bool contacts, bool sms})>
      localDataPermissions() async {
    try {
      final statuses = await permissions.statuses();
      return (
        calls: statuses[ph.Permission.phone] ?? false,
        contacts: statuses[ph.Permission.contacts] ?? false,
        sms: statuses[ph.Permission.sms] ?? false,
      );
    } catch (e) {
      AppLogger.w('setup', 'local-data permission check failed: $e');
      return (calls: false, contacts: false, sms: false);
    }
  }

  bool done(SetupItem item) {
    switch (item) {
      case SetupItem.permissions:
        return permissionsGranted;
      case SetupItem.bluetooth:
        return bluetoothOn;
      case SetupItem.dialer:
        return isDialer;
      case SetupItem.battery:
        return batteryExempt;
    }
  }

  /// Whether the automatic first-launch flow still has to run.
  Future<bool> shouldAutoRun() async {
    try {
      return !(await flagStore.readAutoRunDone());
    } catch (e) {
      AppLogger.w('setup',
          'auto-run flag unreadable, assuming first run: $e');
      return true;
    }
  }

  Future<void> markAutoRunComplete() async {
    try {
      await flagStore.writeAutoRunDone();
    } catch (e) {
      AppLogger.w('setup', 'auto-run flag not persisted: $e');
    }
  }

  /// Re-reads all four item states from the system.
  Future<void> refresh() async {
    try {
      final statuses = await permissions.statuses();
      permissionsGranted = statuses.values.every((granted) => granted);
    } catch (e) {
      AppLogger.w('setup', 'permission statuses unreadable: $e');
    }
    try {
      permanentlyDeniedPermissions =
          await permissions.permanentlyDenied();
    } catch (e) {
      AppLogger.w('setup', 'permanently-denied check failed: $e');
    }
    try {
      bluetoothOn = await ble.isBluetoothOn;
    } catch (e) {
      AppLogger.w('setup', 'Bluetooth state unreadable: $e');
    }
    try {
      isDialer = await telecom.isDefaultDialer();
    } catch (e) {
      AppLogger.w('setup', 'dialer role unreadable: $e');
    }
    try {
      batteryExempt = await permissions.batteryExemptionGranted();
    } catch (e) {
      AppLogger.w('setup', 'battery exemption unreadable: $e');
    }
    notifyListeners();
  }

  /// Requests the runtime permission group. Returns whether all of
  /// them are granted now.
  Future<bool> requestPermissions() async {
    if (busy) return permissionsGranted;
    busy = true;
    notifyListeners();
    try {
      return await _requestPermissionsCore();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Opens the system "turn on Bluetooth" dialog. Returns whether
  /// Bluetooth is on after the user answers.
  Future<bool> enableBluetooth() async {
    if (busy) return bluetoothOn;
    busy = true;
    notifyListeners();
    try {
      return await _enableBluetoothCore();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Opens the system "set as default phone app" prompt. Returns
  /// whether the app holds the dialer role now.
  Future<bool> requestDialer() async {
    if (busy) return isDialer;
    busy = true;
    notifyListeners();
    try {
      return await _requestDialerCore();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Opens the system battery-optimisation exemption prompt.
  /// Returns whether the exemption is held now.
  Future<bool> requestBatteryExemption() async {
    if (busy) return batteryExempt;
    busy = true;
    notifyListeners();
    try {
      return await _requestBatteryExemptionCore();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Opens the app's system settings screen (for permanently
  /// denied permissions).
  Future<void> openSettings() async {
    try {
      await permissions.openSettings();
    } catch (e) {
      AppLogger.w('setup', 'open settings failed: $e');
    }
  }

  /// Runs the whole flow in order — permissions, then Bluetooth,
  /// then dialer, then battery. Each step is skipped when already
  /// done; a failing step is logged and the flow continues with
  /// the rest. Holds `busy` for the whole run.
  Future<void> runFullFlow() async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      await refresh();
      if (!permissionsGranted) await _requestPermissionsCore();
      if (!bluetoothOn) await _enableBluetoothCore();
      if (!isDialer) await _requestDialerCore();
      if (!batteryExempt) await _requestBatteryExemptionCore();
      await refresh();
      AppLogger.i('setup', 'full flow done: complete=$isComplete');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // The single-step methods above guard on `busy`; the cores below
  // do the work and are shared with [runFullFlow].
  Future<bool> _requestPermissionsCore() async {
    try {
      final granted = await permissions.requestAll();
      for (final entry in granted.entries) {
        AppLogger.i('setup', 'permission ${entry.key} granted='
            '${entry.value}');
      }
      permissionsGranted = granted.values.every((v) => v);
      if (!permissionsGranted) {
        AppLogger.w('setup', 'permissions denied: ${granted.entries
            .where((entry) => !entry.value)
            .map((entry) => entry.key)
            .toList()}');
        permanentlyDeniedPermissions =
            await permissions.permanentlyDenied().catchError(
                (_) => const <ph.Permission>[]);
      }
      return permissionsGranted;
    } catch (e, s) {
      AppLogger.e('setup', 'request permissions failed: $e\n$s');
      return false;
    }
  }

  Future<bool> _enableBluetoothCore() async {
    try {
      bluetoothOn = await ble.requestEnableBluetooth();
      AppLogger.i('setup', 'Bluetooth on=$bluetoothOn');
      return bluetoothOn;
    } catch (e, s) {
      AppLogger.e('setup', 'enable Bluetooth failed: $e\n$s');
      return false;
    }
  }

  Future<bool> _requestDialerCore() async {
    try {
      isDialer = await telecom.requestDefaultDialer();
      AppLogger.i('setup', 'dialer role=$isDialer');
      return isDialer;
    } catch (e, s) {
      AppLogger.e('setup', 'dialer role request failed: $e\n$s');
      return false;
    }
  }

  Future<bool> _requestBatteryExemptionCore() async {
    try {
      batteryExempt = await permissions.requestBatteryExemption();
      AppLogger.i('setup', 'battery exemption=$batteryExempt');
      return batteryExempt;
    } catch (e, s) {
      AppLogger.e('setup', 'battery exemption request failed: $e\n$s');
      return false;
    }
  }
}
