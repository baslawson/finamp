import 'package:finamp/services/exit_reasons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Map<String, Object?> _exit(int timestamp, int reason, {int importance = 125, int pss = 204800, String? description}) =>
    {"timestamp": timestamp, "reason": reason, "importance": importance, "pss": pss, "description": description};

void main() {
  late List<LogRecord> logged;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    Logger.root.level = Level.ALL;
    logged = [];
    final listening = Logger("ExitReasons").onRecord.listen(logged.add);
    addTearDown(listening.cancel);
  });

  Future<void> run(List<Map<String, Object?>> exits) async {
    ExitReasons.read = () async => exits;
    await ExitReasons.logNew();
    await pumpEventQueue();
  }

  test("says why the app ended and what it was doing", () {
    final text = ExitReasons.describe(_exit(1000, 3, description: "lmk"));
    expect(text, contains("low memory"));
    expect(text, contains("foreground service"));
    expect(text, contains("200 MB"));
    expect(text, contains("(lmk)"));
  });

  test("an unknown reason still gets logged", () {
    expect(
      ExitReasons.describe(_exit(1000, 99, importance: 7)),
      allOf(contains("reason 99"), contains("importance 7")),
    );
  });

  test("each ending is logged once, oldest first", () async {
    await run([_exit(2000, 16), _exit(1000, 10)]);
    expect(logged.map((record) => record.message), [contains("the user asking"), contains("an app update")]);

    logged.clear();
    await run([_exit(2000, 16), _exit(1000, 10)]);
    expect(logged, isEmpty);

    await run([_exit(3000, 3), _exit(2000, 16), _exit(1000, 10)]);
    expect(logged.single.message, contains("low memory"));
  });

  test("the app failing is an error, so the logs get uploaded", () async {
    await run([_exit(1000, 4), _exit(2000, 5), _exit(3000, 6), _exit(4000, 7)]);
    expect(logged.map((record) => record.level), everyElement(Level.SEVERE));
  });

  test("the system or the user ending it is only information", () async {
    await run([_exit(1000, 3), _exit(2000, 10), _exit(3000, 16), _exit(4000, 13)]);
    expect(logged.map((record) => record.level), everyElement(Level.INFO));
  });

  test("not being able to read them changes nothing", () async {
    ExitReasons.read = () async => throw StateError("No channel");
    await expectLater(ExitReasons.logNew(), completes);
    await pumpEventQueue();
    expect(logged.single.level, Level.INFO);
  });
}
