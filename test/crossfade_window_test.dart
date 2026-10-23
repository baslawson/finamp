import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/crossfade_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  test('initialization retires the saved manual offset without clearing other settings', () async {
    final originalPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    try {
      final prefs = SharedPreferencesAsync();
      await prefs.setInt('crossfadeSyncOffsetMs', 300);
      await prefs.setInt('crossfadeSeconds', 0);
      await prefs.setBool('crossfadeKeepAlbumsGapless', false);

      await CrossfadeService.initialize();

      expect(await prefs.containsKey('crossfadeSyncOffsetMs'), isFalse);
      expect(await prefs.getInt('crossfadeSeconds'), 0);
      expect(await prefs.getBool('crossfadeKeepAlbumsGapless'), isFalse);
      expect(await CrossfadeService.loadSettings(), (seconds: 0, keepAlbumsGapless: false));

      // Subsequent launches work with the legacy preference already absent.
      await CrossfadeService.initialize();
      expect(await prefs.containsKey('crossfadeSyncOffsetMs'), isFalse);
    } finally {
      SharedPreferencesAsyncPlatform.instance = originalPrefs;
    }
  });

  test('native mixing covers ordinary tails but advances before an incoming song can end', () {
    expect(
      CrossfadeService.canCoverNativeTail(
        untilBoundary: const Duration(seconds: 12),
        incomingDuration: const Duration(minutes: 3),
      ),
      isTrue,
    );
    expect(
      CrossfadeService.canCoverNativeTail(
        untilBoundary: const Duration(minutes: 2),
        incomingDuration: const Duration(minutes: 1),
      ),
      isFalse,
    );
    expect(
      CrossfadeService.canCoverNativeTail(
        untilBoundary: const Duration(seconds: 8),
        incomingDuration: const Duration(seconds: 10),
      ),
      isFalse,
    );
    expect(
      CrossfadeService.canCoverNativeTail(untilBoundary: const Duration(seconds: 8), incomingDuration: null),
      isFalse,
    );
  });
  test("the fade ends where the song's sound ends, not at the end of the file", () {
    final window = CrossfadeService.crossfadeWindow(
      duration: 214.33,
      length: 8,
      current: const TrackAnalysis(duration: 214.33, end: 208.5),
    )!;
    expect(window.end, 208.5);
    expect(window.start, closeTo(200.5, 0.001));
  });

  test("the next song's leading silence plays under the fade", () {
    final window = CrossfadeService.crossfadeWindow(
      duration: 200,
      length: 6,
      current: const TrackAnalysis(duration: 200, end: 198),
      next: const TrackAnalysis(start: 1.5),
    )!;
    expect(window.start, closeTo(190.5, 0.001));
    // Never more than 3 s of it.
    final long = CrossfadeService.crossfadeWindow(
      duration: 200,
      length: 6,
      current: const TrackAnalysis(duration: 200, end: 198),
      next: const TrackAnalysis(start: 9),
    )!;
    expect(long.start, closeTo(189, 0.001));
  });

  test('with harmonic mixing the next song comes in on one of this song\'s bars', () {
    // 120 BPM, last beat at 197.25 s, so bars start every 2 s counted back from there.
    final window = CrossfadeService.crossfadeWindow(
      duration: 200,
      length: 8,
      current: const TrackAnalysis(duration: 200, end: 199, beatBpm: 120, lastBeat: 197.25),
      next: const TrackAnalysis(start: 0, firstBeat: 0.8),
      bars: true,
    )!;
    final beatsBack = (197.25 - (window.start + 0.8)) / 0.5;
    expect(beatsBack.round() % 4, 0);
    expect((beatsBack - beatsBack.round()).abs(), lessThan(1e-6));
    expect((window.start - 191).abs(), lessThanOrEqualTo(1.0), reason: 'at most two beats from the plain start');
  });

  test("the next song's first beat lands on one of this song's beats", () {
    // 120 BPM: a beat every 0.5 s, the last at 197.25 s. The next song's first beat comes 0.8 s in.
    final window = CrossfadeService.crossfadeWindow(
      duration: 200,
      length: 8,
      current: const TrackAnalysis(duration: 200, end: 199, beatBpm: 120, lastBeat: 197.25),
      next: const TrackAnalysis(start: 0, firstBeat: 0.8),
    )!;
    final firstBeatAt = window.start + 0.8;
    expect(((197.25 - firstBeatAt) / 0.5 - ((197.25 - firstBeatAt) / 0.5).round()).abs(), lessThan(1e-6));
    // Moved by at most a beat from where it would start otherwise.
    expect((window.start - 191).abs(), lessThanOrEqualTo(0.5));
  });

  test("no beat matching when this song's beats stop long before the fade", () {
    // "It's A Long Way To The Top": the beat tracker's last beat is 45 s before the end (the bagpipe outro).
    final window = CrossfadeService.crossfadeWindow(
      duration: 312.16,
      length: 8,
      current: const TrackAnalysis(duration: 312.16, end: 310.31, bpm: 136, beatBpm: 129.2, lastBeat: 264.89),
      next: const TrackAnalysis(start: 0.65, firstBeat: 0.79),
    )!;
    expect(window.start, closeTo(310.31 - 8 - 0.65, 0.001));
  });

  test("analysis that doesn't fit the song as it plays isn't used", () {
    // Another file (a different length) or no end found.
    expect(
      CrossfadeService.crossfadeWindow(duration: 200, length: 8, current: const TrackAnalysis(duration: 230, end: 228)),
      isNull,
    );
    expect(
      CrossfadeService.crossfadeWindow(duration: 200, length: 8, current: const TrackAnalysis(duration: 200)),
      isNull,
    );
    // An end in the first half would cut the song short: the analysis must be wrong.
    expect(
      CrossfadeService.crossfadeWindow(duration: 200, length: 8, current: const TrackAnalysis(duration: 200, end: 80)),
      isNull,
    );
  });
}
