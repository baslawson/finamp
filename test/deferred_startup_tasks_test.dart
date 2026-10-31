import 'package:finamp/services/deferred_startup_tasks.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('optional jobs wait for a frame, run once and continue after an optional failure', (tester) async {
    final frames = <VoidCallback>[], completed = <String>[], failures = <String>[];
    final tasks = DeferredStartupTasks(onError: (name, _, _) => failures.add(name));
    tasks.add('widget', () async {
      completed.add('widget');
    });
    tasks.add('unavailable server', () async {
      throw StateError('offline');
    });
    tasks.add('concerts', () async {
      completed.add('concerts');
    });
    tasks.schedule(afterFrame: frames.add);
    tasks.schedule(afterFrame: frames.add);
    await tester.pump(const Duration(seconds: 1));
    expect(completed, isEmpty);
    expect(frames, hasLength(1));
    frames.single();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(completed, ['widget', 'concerts']);
    expect(failures, ['unavailable server']);
    await tester.pump(const Duration(seconds: 3));
    expect(completed, hasLength(2));
  });

  testWidgets('a launch without a UI frame still starts optional services after the fallback delay', (tester) async {
    final frames = <VoidCallback>[];
    var runs = 0;
    final tasks = DeferredStartupTasks(onError: (_, error, _) => fail('$error'));
    tasks.add('sync', () async {
      runs++;
    });
    tasks.schedule(afterFrame: frames.add);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 1));
    expect(runs, 1);
    frames.single();
    await tester.pump();
    expect(runs, 1);
  });
}
