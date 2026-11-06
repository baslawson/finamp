import 'package:finamp/services/screen_wakelock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  late List<LogRecord> records;

  setUp(() {
    records = [];
    Logger.root.level = Level.ALL;
  });

  Future<void> run(Future<void> Function() body) async {
    final subscription = Logger.root.onRecord.listen(records.add);
    try {
      await body();
    } finally {
      await subscription.cancel();
    }
  }

  test('passes the wanted state on', () async {
    final asked = <bool>[];
    Future<void> toggle({required bool enable}) async => asked.add(enable);
    await run(() async {
      await keepScreenOn(true, toggle: toggle);
      await keepScreenOn(false, toggle: toggle);
    });
    expect(asked, [true, false]);
    expect(records.where((r) => r.loggerName == 'ScreenWakelock'), isEmpty);
  });

  test("Android refusing once the app's screen is gone is no error", () async {
    Future<void> toggle({required bool enable}) async =>
        throw PlatformException(code: 's', message: 'e2.s: wakelock requires a foreground activity');
    await run(() async {
      // The refusal must not escape: unawaited, it became an uncaught SEVERE error in the 2026-11-05 log.
      await expectLater(keepScreenOn(false, toggle: toggle), completes);
    });
    final logged = records.where((r) => r.loggerName == 'ScreenWakelock').toList();
    expect(logged, hasLength(1));
    expect(logged.single.level, Level.INFO);
    expect(logged.single.message, contains("Couldn't let the screen turn off"));
    expect(logged.single.message, contains('requires a foreground activity'));
  });

  test('a refusal to keep the screen on is no error either', () async {
    Future<void> toggle({required bool enable}) async => throw StateError('no activity');
    await run(() async {
      await expectLater(keepScreenOn(true, toggle: toggle), completes);
    });
    expect(records.single.message, contains("Couldn't keep the screen on"));
  });
}
