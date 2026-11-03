import 'dart:async';

import 'package:finamp/utils/run_again.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('asking while it runs runs it once more afterwards, with what is latest then', () async {
    var latest = 1;
    final used = <int>[];
    final gate = Completer<void>();
    final task = RunAgain(() async {
      final value = latest;
      if (used.isEmpty) await gate.future;
      used.add(value);
      return value;
    });

    expect(task.running, false);
    final first = task(whileRunning: -1);
    expect(task.running, true);
    latest = 2;
    expect(await task(whileRunning: -1), -1);
    latest = 3;
    expect(await task(whileRunning: -1), -1);
    gate.complete();
    // Two asks while running make one more run, with the latest value.
    expect(await first, 3);
    expect(used, [1, 3]);
    expect(task.running, false);

    // Free again afterwards.
    expect(await task(whileRunning: -1), 3);
    expect(used, [1, 3, 3]);
  });

  test('the run again is skipped when it is no longer wanted', () async {
    var runs = 0;
    final gate = Completer<void>();
    final task = RunAgain(() async {
      runs++;
      if (runs == 1) await gate.future;
      return runs;
    });
    var wanted = true;
    final first = task(whileRunning: 0, wanted: () => wanted);
    unawaited(task(whileRunning: 0, wanted: () => wanted));
    wanted = false;
    gate.complete();
    expect(await first, 1);
    expect(runs, 1);
  });
}
