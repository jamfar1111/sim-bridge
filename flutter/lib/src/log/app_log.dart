/// In-app file logger: the app writes its own diagnostic log so a
/// crash can be diagnosed without logcat access.
///
/// The log lives at `<external files dir>/sim_bridge.log` — the same
/// file the Kotlin uncaught-exception handler writes to
/// (`SimBridgeApplication`), so Dart logs and native crashes end up
/// in ONE file the user can share from the Link tab.
///
/// Writes are synchronous with `flush: true` (crash-safe: a line is
/// on disk before the call returns). Rotation keeps one backup:
/// when the file passes [maxBytes] it is renamed to
/// `sim_bridge.log.1` and a fresh file starts.
///
/// All methods are safe to call before [init] or when init failed:
/// they no-op (except an in-memory fallback note in debug mode).
library;

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';

/// The shared log file name (also used by the Kotlin crash handler).
const String appLogFileName = 'sim_bridge.log';

/// The rotated backup file name.
const String appLogBackupFileName = 'sim_bridge.log.1';

class AppLogger {
  AppLogger._();

  static File? _file;
  static int _maxBytes = 2 * 1024 * 1024;

  /// Channel to the Kotlin Downloads mirror (`com.simbridge/log`).
  static const MethodChannel _mirrorChannel =
      MethodChannel('com.simbridge/log');

  /// Last successful mirror attempt, to avoid hammering MediaStore
  /// when errors arrive in a burst (a crash loop can log several
  /// errors per second; one mirror every few seconds is enough).
  static DateTime? _lastMirror;

  /// Minimum gap between automatic mirrors (the manual "copy to
  /// Downloads" button ignores this and always mirrors).
  static const Duration mirrorThrottle = Duration(seconds: 5);

  /// Whether a log file is open for writing.
  static bool get isReady => _file != null;

  /// Absolute path of the log file, or `null` when not initialised.
  static String? get path => _file?.path;

  /// Current size of the log file in bytes (0 when not initialised).
  static int get sizeBytes {
    final f = _file;
    if (f == null) return 0;
    try {
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Opens the log file. Resolves the directory through
  /// `path_provider` (external files dir on Android — the same
  /// directory the Kotlin side uses) unless [directory] is given
  /// (tests). Falls back to the app documents directory, and gives
  /// up silently when neither works: logging then no-ops instead of
  /// crashing startup.
  static Future<void> init({
    Directory? directory,
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    _maxBytes = maxBytes;
    try {
      final dir = directory ??
          await getExternalStorageDirectory().catchError(
            (_) => getApplicationDocumentsDirectory(),
          );
      if (dir == null) return;
      await dir.create(recursive: true);
      _file = File('${dir.path}/$appLogFileName');
      // Mirror the previous run's log into Downloads right away:
      // if this launch crashes again before the user can open the
      // Link tab, the log is already reachable in Files → Downloads.
      unawaited(mirrorToDownloads(force: true));
    } catch (_) {
      // No log file: logging no-ops. Startup must never fail here.
      _file = null;
    }
  }

  /// Copies the current log file into the public Downloads folder
  /// (MediaStore, `sim_bridge.log`) so the user can find it in
  /// Files → Downloads even when Android/data is not browsable and
  /// even when the app never opens. Never throws; returns false when
  /// mirroring is unavailable (non-Android, no channel, no log yet).
  /// Set [force] to ignore the throttle (the manual copy button).
  static Future<bool> mirrorToDownloads({bool force = false}) async {
    if (!Platform.isAndroid) return false;
    if (_file == null) return false;
    if (!force) {
      final last = _lastMirror;
      if (last != null &&
          DateTime.now().difference(last) < mirrorThrottle) {
        return false;
      }
    }
    return _mirrorNow();
  }

  static Future<bool> _mirrorNow() async {
    _lastMirror = DateTime.now();
    try {
      final ok = await _mirrorChannel.invokeMethod<bool>('mirrorLog');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Test-only reset: forgets the open file so another test can
  /// [init] with its own directory.
  static void reset() {
    _file = null;
    _lastMirror = null;
  }

  /// Appends one timestamped line. Never throws.
  static void log(String tag, String message, {bool error = false}) {
    final line = _format(tag, message, error: error);
    final f = _file;
    if (f == null) {
      if (kDebugMode) {
        // ignore: avoid_print
        print(line);
      }
      return;
    }
    try {
      _rotateIfNeeded(f);
      f.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never crash the app.
    }
    if (error) {
      // An error line may be the last thing before a crash: push a
      // copy to Downloads now (throttled, fire-and-forget).
      unawaited(mirrorToDownloads());
    }
  }

  /// Info-level line.
  static void i(String tag, String message) => log(tag, message);

  /// Warning-level line: something non-critical failed and the app
  /// is continuing without it (unlike [e], it does not mirror the
  /// log to Downloads — there is no crash to capture).
  static void w(String tag, String message) => log(tag, message);

  /// Error-level line (message may carry a stack trace after \n).
  static void e(String tag, String message) =>
      log(tag, message, error: true);

  /// The last [lines] of the log file (newest last), or empty when
  /// there is no log yet. Reads synchronously; the file is capped
  /// at ~2 MB, so this stays cheap.
  static List<String> tail({int lines = 5}) {
    final f = _file;
    if (f == null) return const [];
    try {
      if (!f.existsSync()) return const [];
      final all = f.readAsLinesSync();
      if (all.length <= lines) return all;
      return all.sublist(all.length - lines);
    } catch (_) {
      return const [];
    }
  }

  /// Truncates the log file (keeps the file itself so the path
  /// stays valid). The backup is left alone.
  static Future<void> clear() async {
    final f = _file;
    if (f == null) return;
    try {
      if (await f.exists()) await f.writeAsString('', flush: true);
    } catch (_) {}
  }

  static void _rotateIfNeeded(File f) {
    try {
      if (!f.existsSync()) return;
      if (f.lengthSync() <= _maxBytes) return;
      final backup = File('${f.parent.path}/$appLogBackupFileName');
      if (backup.existsSync()) backup.deleteSync();
      f.renameSync(backup.path);
    } catch (_) {
      // Rotation failure must not lose the new line: the append
      // below still runs against the (oversized) file.
    }
  }

  static String _format(String tag, String message,
      {required bool error}) {
    final ts = DateTime.now().toIso8601String();
    final level = error ? 'ERROR' : 'INFO';
    // Stack traces stay readable: continuation lines are indented.
    final body = message.replaceAll('\n', '\n  ');
    return '$ts [$level] $tag: $body';
  }
}
