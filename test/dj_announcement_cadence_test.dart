import 'dart:math';

import 'package:finamp/services/dj_announcement_cadence.dart';
import 'package:flutter_test/flutter_test.dart';

class _Random extends Fake implements Random {
  int calls = 0;
  @override
  int nextInt(int max) => calls++ % max;
}

void main() {
  test('one random interval stays fixed across playback ticks and unrelated preference saves', () {
    final random = _Random();
    final cadence = DjAnnouncementCadence(random: random);
    cadence.configure(randomTiming: true, fixedEvery: 10);
    expect(cadence.every, 2);
    for (var tick = 0; tick < 100; tick++) {
      cadence.configure(randomTiming: true, fixedEvery: 10);
      expect(cadence.every, 2);
    }
    expect(random.calls, 1);
    cadence.announced();
    expect(cadence.every, 3);
    expect(random.calls, 2);
  });

  test('random timing spans two to five songs and restores the saved fixed frequency', () {
    final cadence = DjAnnouncementCadence(random: _Random());
    cadence.configure(randomTiming: true, fixedEvery: 8);
    final intervals = <int>[];
    for (var announcement = 0; announcement < 8; announcement++) {
      intervals.add(cadence.every);
      cadence.announced();
    }
    expect(intervals, [2, 3, 4, 5, 2, 3, 4, 5]);
    cadence.configure(randomTiming: false, fixedEvery: 8);
    expect(cadence.every, 8);
    cadence.announced();
    expect(cadence.every, 8);
  });

  test('switching modes or stations chooses a fresh random interval', () {
    final cadence = DjAnnouncementCadence(random: _Random());
    cadence.configure(randomTiming: true, fixedEvery: 1);
    expect(cadence.every, 2);
    cadence.configure(randomTiming: true, fixedEvery: 1, reset: true);
    expect(cadence.every, 3);
    cadence.configure(randomTiming: false, fixedEvery: 1);
    expect(cadence.every, 1);
    cadence.configure(randomTiming: true, fixedEvery: 1);
    expect(cadence.every, 4);
  });
}
