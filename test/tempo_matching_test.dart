import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/crossfade_service.dart';
import 'package:finamp/services/tempo_matching.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  test('only nearby tempos match, including half and double time', () {
    expect(TempoMatch.ratio(120, 126), closeTo(120 / 126, 1e-9));
    expect(TempoMatch.ratio(120, 63), closeTo(120 / 126, 1e-9));
    expect(TempoMatch.ratio(60, 126), closeTo(120 / 126, 1e-9));
    expect(TempoMatch.ratio(100, 106), closeTo(100 / 106, 1e-9));
    expect(TempoMatch.ratio(100, 94), closeTo(100 / 94, 1e-9));
    expect(TempoMatch.ratio(100, 106.01), isNull);
    expect(TempoMatch.ratio(100, 93.99), isNull);
    for (final bpm in [0.0, -100.0, double.nan, double.infinity, null]) {
      expect(TempoMatch.ratio(100, bpm), isNull);
      expect(TempoMatch.ratio(bpm, 100), isNull);
    }
  });

  test('speed approaches one monotonically and stays there after the ramp', () {
    for (final initial in [0.95, 1.05]) {
      final match = TempoMatch(initialSpeed: initial, rampLength: 8);
      expect(match.speedAt(-1), initial);
      expect(match.speedAt(0), initial);
      expect(match.speedAt(4), closeTo((initial + 1) / 2, 1e-9));
      expect(match.speedAt(8), 1);
      expect(match.speedAt(100), 1);
    }
  });

  test('adjusted elapsed time agrees with numerical integration for fast and slow ramps', () {
    for (final initial in [0.95, 1.0, 1.05]) {
      final match = TempoMatch(initialSpeed: initial, rampLength: 8);
      for (final position in [0.8, 4.0, 8.0, 12.0]) {
        var elapsed = 0.0;
        const steps = 10000;
        final step = position / steps;
        for (var i = 0; i < steps; i++) {
          elapsed += step / match.speedAt((i + 0.5) * step);
        }
        expect(match.elapsedAt(position), closeTo(elapsed, 1e-7));
      }
      expect(match.elapsedAt(-1), 0);
    }
  });

  test('the incoming pulse matches at its first beat, then eases over the following bars', () {
    final match = TempoMatch.plan(outgoingBpm: 120, incomingBpm: 126, availableSeconds: 12, firstBeat: 0.8)!;
    expect(match.speedAt(0.8) * 126, closeTo(120, 1e-9));
    expect(match.elapsedAt(0.8), closeTo(0.8 / match.initialSpeed, 1e-9));
    expect(match.speedAt(match.rampEnd), 1);
    expect(match.elapsedAt(match.rampEnd) + 0.75, lessThanOrEqualTo(12));
    expect(match.elapsedAt(match.rampEnd + 2) - match.elapsedAt(match.rampEnd), closeTo(2, 1e-9));
  });

  test('ramps finish before hand-over and short fades keep their ordinary speed', () {
    final long = TempoMatch.plan(outgoingBpm: 120, incomingBpm: 126, availableSeconds: 12)!;
    expect(long.rampLength, closeTo(16 * 60 / 126, 1e-9));
    final short = TempoMatch.plan(outgoingBpm: 120, incomingBpm: 126, availableSeconds: 6)!;
    expect(short.rampLength, closeTo(8 * 60 / 126, 1e-9));
    expect(short.elapsedAt(short.rampLength), lessThan(6 - 0.75));
    expect(TempoMatch.plan(outgoingBpm: 120, incomingBpm: 126, availableSeconds: 2), isNull);
    expect(TempoMatch.plan(outgoingBpm: 120, incomingBpm: 120, availableSeconds: 12), isNull);
    expect(TempoMatch.plan(outgoingBpm: null, incomingBpm: 126, availableSeconds: 12), isNull);
  });

  test('incoming first beat lands on the outgoing grid while its speed changes', () {
    for (final incoming in [114.0, 126.0, 63.0]) {
      final match = TempoMatch.plan(outgoingBpm: 120, incomingBpm: incoming, availableSeconds: 12, firstBeat: 0.8)!;
      for (final bars in [false, true]) {
        final elapsed = match.elapsedAt(0.8);
        final window = CrossfadeService.crossfadeWindow(
          duration: 200,
          length: 10,
          current: const TrackAnalysis(duration: 200, end: 199, beatBpm: 120, lastBeat: 197.25),
          next: TrackAnalysis(firstBeat: 0.8, beatBpm: incoming),
          nextBeatElapsed: elapsed,
          bars: bars,
        )!;
        final beatsBack = (197.25 - window.start - elapsed) / 0.5;
        expect(beatsBack, closeTo(beatsBack.round(), 1e-8));
        if (bars) expect(beatsBack.round() % 4, 0);
        expect(elapsed, isNot(closeTo(0.8, 0.001)));
      }
    }
  });

  test('tempo matching is off by default and remembered separately from fade length', () async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    expect(await CrossfadeService.loadTempoMatching(), false);
    await CrossfadeService.saveTempoMatching(true);
    expect(await CrossfadeService.loadTempoMatching(), true);
    expect((await CrossfadeService.loadSettings()).seconds, 0);
    await CrossfadeService.saveTempoMatching(false);
    expect(await CrossfadeService.loadTempoMatching(), false);
  });
}
