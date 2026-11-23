// Unit tests for the in-app file logger (AppLogger): writes,
// rotation, tail, clear, and the uninitialised no-op behaviour.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/log/log.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sim_bridge_log_');
    AppLogger.reset();
  });

  tearDown(() async {
    AppLogger.reset();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('writes timestamped lines to sim_bridge.log', () async {
    await AppLogger.init(directory: dir);
    AppLogger.i('test', 'hello world');
    AppLogger.e('test', 'something failed');
    final file = File('${dir.path}/sim_bridge.log');
    expect(await file.exists(), isTrue);
    final lines = await file.readAsLines();
    expect(lines, hasLength(2));
    expect(lines[0], contains('[INFO] test: hello world'));
    expect(lines[1], contains('[ERROR] test: something failed'));
    // ISO-8601 timestamp at the start of each line.
    expect(lines[0], startsWith('20'));
    expect(AppLogger.isReady, isTrue);
    expect(AppLogger.path, file.path);
    expect(AppLogger.sizeBytes, greaterThan(0));
  });

  test('rotates when the file exceeds maxBytes', () async {
    await AppLogger.init(directory: dir, maxBytes: 200);
    for (var i = 0; i < 20; i++) {
      AppLogger.i('test', 'line $i ${'x' * 40}');
    }
    final backup = File('${dir.path}/sim_bridge.log.1');
    expect(await backup.exists(), isTrue);
    expect((await backup.readAsLines()).isNotEmpty, isTrue);
    // The current file restarted fresh after rotation.
    expect(AppLogger.sizeBytes, lessThanOrEqualTo(200 + 100));
  });

  test('tail returns the last lines', () async {
    await AppLogger.init(directory: dir);
    for (var i = 0; i < 10; i++) {
      AppLogger.i('test', 'line $i');
    }
    final tail = AppLogger.tail(lines: 3);
    expect(tail, hasLength(3));
    expect(tail[0], contains('line 7'));
    expect(tail[2], contains('line 9'));
    expect(AppLogger.tail(lines: 50), hasLength(10));
  });

  test('clear truncates the log', () async {
    await AppLogger.init(directory: dir);
    AppLogger.i('test', 'something');
    expect(AppLogger.sizeBytes, greaterThan(0));
    await AppLogger.clear();
    expect(AppLogger.sizeBytes, 0);
    expect(AppLogger.tail(), isEmpty);
  });

  test('no-ops before init', () {
    // Must never throw: main() logs before init completes, and
    // widgets render the log card before the logger is ready.
    expect(() => AppLogger.i('test', 'early'), returnsNormally);
    expect(AppLogger.isReady, isFalse);
    expect(AppLogger.path, isNull);
    expect(AppLogger.sizeBytes, 0);
    expect(AppLogger.tail(), isEmpty);
  });

  test('mirrorToDownloads never throws without a channel', () async {
    await AppLogger.init(directory: dir);
    AppLogger.i('test', 'line');
    // No platform channel in the test env (and not Android): must
    // return false, never throw — including the forced path the
    // manual "copy to Downloads" button uses.
    expect(await AppLogger.mirrorToDownloads(force: true), isFalse);
    expect(await AppLogger.mirrorToDownloads(), isFalse);
    // Error writes trigger a mirror attempt: still must not throw.
    expect(() => AppLogger.e('test', 'boom'), returnsNormally);
  });

  test('mirrorToDownloads returns false before init', () async {
    expect(await AppLogger.mirrorToDownloads(force: true), isFalse);
  });
}
