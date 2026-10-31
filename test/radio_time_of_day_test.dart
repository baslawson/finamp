import 'dart:math';

import 'package:finamp/services/listening_hour.dart';
import 'package:finamp/services/radio_clock_settings.dart';
import 'package:finamp/services/radio_time_of_day.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  test('local hour bands meet at their boundaries and night wraps midnight', () {
    expect([0, 4, 22, 23].map(listeningHour), everyElement(ListeningHour.night));
    expect([5, 8].map(listeningHour), everyElement(ListeningHour.morning));
    expect([9, 16].map(listeningHour), everyElement(ListeningHour.daytime));
    expect([17, 21].map(listeningHour), everyElement(ListeningHour.evening));
  });

  test('morning and night favour lower energy; evening favours higher energy', () {
    for (final hour in [2, 6, 23]) {
      final clock = RadioTimeOfDay(hour: hour);
      expect(clock.weight(trackId: 'calm', energy: -28), greaterThan(clock.weight(trackId: 'loud', energy: -8)));
    }
    final evening = RadioTimeOfDay(hour: 19);
    expect(evening.weight(trackId: 'loud', energy: -8), greaterThan(evening.weight(trackId: 'calm', energy: -28)));
    expect(RadioTimeOfDay(hour: 12).weight(trackId: 'a', energy: -28), 1);
    expect(RadioTimeOfDay(hour: 12).weight(trackId: 'b', energy: -8), 1);
    expect(evening.weight(trackId: 'unknown'), 1);
    expect(evening.weight(trackId: 'invalid', energy: double.nan), 1);
  });

  test('skips softly reduce the song, artist and energy band without filtering', () {
    final clock = RadioTimeOfDay(
      hour: 12,
      skips: [(trackId: 'skipped', artist: 'The Artist', energy: -8.0, weight: 3.0)],
    );
    final song = clock.weight(trackId: 'skipped', artist: 'the artist', energy: -8);
    final artist = clock.weight(trackId: 'other', artist: 'The Artist feat. Guest', energy: -8);
    final energy = clock.weight(trackId: 'another', artist: 'Someone Else', energy: -8);
    expect(song, lessThan(artist));
    expect(artist, lessThan(energy));
    expect(energy, lessThan(1));
    expect(song, greaterThan(0));
    expect(clock.weight(trackId: 'calm', artist: 'Someone Else', energy: -28), 1);
  });

  test('legacy skips contribute their latest hour once, not their whole lifetime count', () {
    final now = DateTime(2026, 10, 24, 23);
    final record = SkipRecord.fromJson({'id': 'song', 'c': 50, 't': now.millisecondsSinceEpoch});
    expect(record.hourWeight(ListeningHour.night, now), 1);
    expect(record.hourWeight(ListeningHour.morning, now), 0);
    expect(record.hourWeight(ListeningHour.night, now.add(const Duration(days: 60))), closeTo(0.5, 1e-9));
  });

  test('hour counters keep separate histories and survive JSON round trips', () {
    final night = DateTime(2026, 10, 23, 23), morning = DateTime(2026, 10, 24, 6);
    final record = SkipRecord(trackId: 'song', name: '', artist: 'Artist', count: 1, last: night);
    record.addHourSkip(morning);
    record.count++;
    record.last = morning;
    final saved = SkipRecord.fromJson(record.toJson());
    expect(saved.hourWeight(ListeningHour.morning, morning), 1);
    expect(saved.hourWeight(ListeningHour.night, morning), closeTo(1, 0.01));
    expect(saved.hourWeight(ListeningHour.evening, morning), 0);
    saved.addHourSkip(morning.add(const Duration(days: 60)));
    expect(saved.hourWeight(ListeningHour.morning, morning.add(const Duration(days: 60))), closeTo(1.5, 1e-9));
  });

  test('time weights combine with harmonic scores and Randomness retains variety', () {
    final clock = RadioTimeOfDay(hour: 23);
    final tracks = ['calm', 'loud'];
    double score(String track) => clock.weight(trackId: track, energy: track == 'calm' ? -28 : -8);
    expect(RadioTuning.weightedShuffle(tracks, score, randomness: 0, weightedRandom: true), tracks);
    var calmFirst = 0;
    for (var i = 0; i < 1000; i++) {
      final result = RadioTuning.weightedShuffle(
        tracks,
        score,
        randomness: 100,
        weightedRandom: true,
        random: Random(i),
      );
      expect(result.toSet(), tracks.toSet());
      if (result.first == 'calm') calmFirst++;
    }
    expect(calmFirst, inInclusiveRange(550, 750));
    // A large harmonic advantage still outweighs the small clock preference.
    double harmonicScore(String track) => score(track) / (track == 'calm' ? 5 : 1);
    expect(RadioTuning.weightedShuffle(tracks, harmonicScore, randomness: 0, weightedRandom: true).first, 'loud');
  });

  test('the Radio clock setting defaults on and is remembered', () async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    expect(await RadioClockSettings.load(), true);
    await RadioClockSettings.save(false);
    expect(await RadioClockSettings.load(), false);
    await RadioClockSettings.save(true);
    expect(await RadioClockSettings.load(), true);
  });
}
