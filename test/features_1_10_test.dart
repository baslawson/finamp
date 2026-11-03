import 'dart:math';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/karaoke_screen.dart';
import 'package:finamp/services/library_health_service.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/services/right_now_service.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:finamp/services/sleep_sounds_service.dart';
import 'package:finamp/services/stats_widget_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _second = 10000000;

ListenEntry _listen(DateTime time, String id, {String artist = "A", int minutes = 3}) => ListenEntry(
  time: time,
  listened: Duration(minutes: minutes),
  trackId: id,
  track: id,
  artist: artist,
);

BaseItemDto _track(String name, {String artist = "Artist", int seconds = 200, String? album, int? bitrate}) =>
    BaseItemDto(
      id: BaseItemId("$name$album$seconds$bitrate"),
      name: name,
      albumArtist: artist,
      artists: [artist],
      album: album,
      runTimeTicks: seconds * _second,
      mediaSources: bitrate == null
          ? null
          : [
              MediaSourceInfo(
                protocol: "File",
                type: "Default",
                isRemote: false,
                supportsTranscoding: true,
                supportsDirectStream: true,
                supportsDirectPlay: true,
                isInfiniteStream: false,
                requiresOpening: false,
                requiresClosing: false,
                requiresLooping: false,
                supportsProbing: true,
                readAtNativeFramerate: false,
                ignoreDts: false,
                ignoreIndex: false,
                genPtsInput: false,
                mediaStreams: const [],
                container: "mp3",
                bitrate: bitrate,
              ),
            ],
    );

void main() {
  group("skips", () {
    test("only early skips of real songs count", () {
      expect(SkipService.isSkip(const Duration(seconds: 10), const Duration(minutes: 4)), isTrue);
      expect(SkipService.isSkip(const Duration(seconds: 1), const Duration(minutes: 4)), isFalse);
      expect(SkipService.isSkip(const Duration(seconds: 50), const Duration(minutes: 4)), isFalse);
      // Short interludes aren't judged.
      expect(SkipService.isSkip(const Duration(seconds: 5), const Duration(seconds: 30)), isFalse);
    });

    test("skips fade over time", () {
      final now = DateTime(2026, 10, 17);
      final recent = SkipRecord(trackId: "a", name: "a", artist: null, count: 4, last: now);
      final old = SkipRecord(
        trackId: "b",
        name: "b",
        artist: null,
        count: 4,
        last: now.subtract(const Duration(days: 120)),
      );
      expect(SkipService.weightOf(recent, now), 4);
      expect(SkipService.weightOf(old, now), closeTo(1, 0.01));
    });

    test("weighted shuffle favours heavier items", () {
      var heavyFirst = 0;
      for (var i = 0; i < 400; i++) {
        final order = RadioTuning.weightedShuffle(
          ["heavy", "light"],
          (item) => item == "heavy" ? 1.0 : 0.15,
          random: Random(i),
        );
        if (order.first == "heavy") heavyFirst++;
      }
      expect(heavyFirst, greaterThan(300));
    });
  });

  group("right now", () {
    test("names the part of the day", () {
      expect(RightNowService.dayPart(DateTime(2026, 1, 1, 8)), DayPart.morning);
      expect(RightNowService.dayPart(DateTime(2026, 1, 1, 23)), DayPart.night);
    });

    test("ranks what's played at this time of day first", () {
      final now = DateTime(2026, 10, 14, 8); // A Wednesday morning.
      final listens = [
        for (var day = 1; day <= 5; day++) _listen(DateTime(2026, 10, 14 - day, 8, 10), "morning song"),
        for (var day = 1; day <= 5; day++) _listen(DateTime(2026, 10, 14 - day, 21), "evening song"),
      ];
      expect(RightNowService.rank(listens, now).first, "morning song");
      expect(
        RightNowService.relevance(DateTime(2026, 10, 13, 8), now),
        greaterThan(RightNowService.relevance(DateTime(2026, 10, 13, 20), now)),
      );
    });
  });

  group("karaoke", () {
    final lines = [
      LyricLine(text: "Hello world", start: 10 * _second),
      LyricLine(text: "Second line", start: 20 * _second),
    ];

    test("finds the current line", () {
      expect(KaraokeTiming.lineAt(lines, 5 * _second), -1);
      expect(KaraokeTiming.lineAt(lines, 12 * _second), 0);
      expect(KaraokeTiming.lineAt(lines, 25 * _second), 1);
    });

    test("estimates sung characters without word timings", () {
      expect(KaraokeTiming.sungCharacters(lines[0], lines[1], 10 * _second), 0);
      final halfway = KaraokeTiming.sungCharacters(lines[0], lines[1], 10 * _second + 8 * _second ~/ 10);
      expect(halfway, inInclusiveRange(4, 8));
      expect(KaraokeTiming.sungCharacters(lines[0], lines[1], 19 * _second), "Hello world".length);
    });

    test("uses word timings when present", () {
      final line = LyricLine(
        text: "Hello world",
        start: 10 * _second,
        cues: [
          LyricLineCue(position: 0, start: 10 * _second, endPosition: 6),
          LyricLineCue(position: 6, start: 14 * _second, endPosition: 11),
        ],
      );
      expect(KaraokeTiming.sungCharacters(line, lines[1], 13 * _second), lessThanOrEqualTo(6));
      expect(KaraokeTiming.sungCharacters(line, lines[1], 14 * _second), 6);
    });
  });

  test("sleep sounds loop and stay within range", () {
    for (final sound in SleepSound.values) {
      final pcm = SleepSoundsService.generate(sound, seconds: 3, sampleRate: 8000);
      expect(pcm.length, 2 * 8000 * 2, reason: sound.name); // 3 s minus the 1 s blended into the start.
    }
  });

  test("stats count today, the week and the streak", () {
    final now = DateTime(2026, 10, 17, 12); // Saturday.
    final stats = StatsWidgetService.compute([
      _listen(DateTime(2026, 10, 12, 9), "a", artist: "Monday artist", minutes: 10),
      _listen(DateTime(2026, 10, 15, 9), "b", artist: "Big artist", minutes: 30),
      _listen(DateTime(2026, 10, 16, 9), "c", artist: "Big artist", minutes: 30),
      _listen(DateTime(2026, 10, 17, 9), "d", minutes: 5),
      _listen(DateTime(2026, 10, 5, 9), "old", minutes: 60),
    ], now);
    expect(stats.today, const Duration(minutes: 5));
    expect(stats.week, const Duration(minutes: 75));
    expect(stats.topArtist, "Big artist");
    expect(stats.streakDays, 3);
  });

  test("library health finds duplicates and low bitrates", () {
    final report = LibraryHealthService.analyze([
      _track("Song", album: "Album", seconds: 200),
      _track("Song (Remastered)", album: "Best of", seconds: 201),
      _track("Song", album: "Live", seconds: 260),
      _track("Quiet", bitrate: 128000),
      _track("Fine", bitrate: 320000),
    ], []);
    expect(report.duplicates, hasLength(1));
    expect(report.duplicates.first, hasLength(2));
    expect(report.lowQuality.map((track) => track.name), ["Quiet"]);
  });

  test("duplicate titles keep versions apart but ignore remaster tags", () {
    expect(LibraryHealthService.duplicateTitle("Song (2011 Remaster)"), "song");
    expect(LibraryHealthService.duplicateTitle("Song - Remastered 2009"), "song");
    expect(LibraryHealthService.duplicateTitle("Don't Stop"), "dont stop");
    expect(
      LibraryHealthService.duplicateTitle("905 (Glyn Johns Mix)"),
      isNot(LibraryHealthService.duplicateTitle("905")),
    );
    expect(
      LibraryHealthService.duplicateTitle("One Wish (Recorded 2006)"),
      isNot(LibraryHealthService.duplicateTitle("One Wish")),
    );
  });
}
