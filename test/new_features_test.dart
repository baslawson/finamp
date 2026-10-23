import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/concert_service.dart';
import 'package:finamp/services/genre_eq_service.dart';
import 'package:finamp/services/headphone_eq_service.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:finamp/services/on_this_day_service.dart';
import 'package:finamp/services/quiz_service.dart';
import 'package:finamp/services/running_service.dart';
import 'package:finamp/services/voice_control_service.dart';
import 'package:flutter_test/flutter_test.dart';

BaseItemDto _track(String id, String name, {String artist = "Artist", int seconds = 200}) =>
    BaseItemDto(id: BaseItemId(id), name: name, albumArtist: artist, type: "Audio", runTimeTicks: seconds * 10000000);

void main() {
  group("on this day", () {
    test("only earlier years, within the window", () {
      final now = DateTime(2026, 10, 17);
      expect(OnThisDayService.isAround(DateTime(2024, 10, 17, 22), now, 0), isTrue);
      expect(OnThisDayService.isAround(DateTime(2024, 10, 19), now, 0), isFalse);
      expect(OnThisDayService.isAround(DateTime(2024, 10, 19), now, 3), isTrue);
      expect(OnThisDayService.isAround(DateTime(2026, 10, 17), now, 0), isFalse);
    });

    test("groups by year and song, most played first", () {
      final years = OnThisDayService.group([
        (time: DateTime(2023, 10, 17), title: "Song A", artist: "X", trackId: null),
        (time: DateTime(2024, 10, 17), title: "Song B", artist: "X", trackId: "b"),
        (time: DateTime(2024, 10, 17), title: "Song C", artist: "X", trackId: null),
        (time: DateTime(2024, 10, 17), title: "song c", artist: "x", trackId: "c"),
      ]);
      expect(years.map((year) => year.year), [2024, 2023]);
      expect(years.first.songs.first.title, "Song C");
      expect(years.first.songs.first.plays, 2);
      expect(years.first.songs.first.trackId, "c");
    });
  });

  group("quiz", () {
    test("faster right answers score more", () {
      expect(QuizService.points(correct: true, time: const Duration(seconds: 3)), 3);
      expect(QuizService.points(correct: true, time: const Duration(seconds: 8)), 2);
      expect(QuizService.points(correct: true, time: const Duration(seconds: 20)), 1);
      expect(QuizService.points(correct: false, time: const Duration(seconds: 1)), 0);
    });

    test("questions have four different titles including the answer, and skip short songs", () {
      final pool = [
        for (var i = 0; i < 10; i++) _track("$i", "Song $i"),
        _track("dup", "Song 1"),
        _track("short", "Jingle", seconds: 20),
      ];
      final questions = QuizService.build(pool, count: 20, random: Random(1));
      expect(questions, hasLength(10));
      for (final question in questions) {
        expect(question.choices, hasLength(4));
        expect(question.choices.map((choice) => choice.name).toSet(), hasLength(4));
        expect(question.choices, contains(question.answer));
        expect(question.answer.name, isNot("Jingle"));
        expect(question.clipStart, greaterThan(const Duration(seconds: 40)));
      }
    });

    test("too few songs make no quiz", () {
      expect(QuizService.build([_track("1", "A"), _track("2", "B"), _track("3", "C")]), isEmpty);
    });
  });

  test("genre EQ picks the first matching genre", () {
    expect(GenreEqService.presetFor(["Hip-Hop", "Rock"]), GenreEqPreset.hipHop);
    expect(GenreEqService.presetFor(["Alternative Rock"]), GenreEqPreset.rock);
    expect(GenreEqService.presetFor(["Podcast"]), GenreEqPreset.spoken);
    expect(GenreEqService.presetFor(["Gregorian"]), GenreEqPreset.flat);
    expect(GenreEqService.presetFor([]), GenreEqPreset.flat);
  });

  test("EQ curves add up", () {
    final combined = HeadphoneEqService.combine([(100, 2), (1000, 4)], [(100, 1), (1000, -1)]);
    expect(combined, [(100.0, 3.0), (1000.0, 3.0)]);
    expect(HeadphoneEqService.combine([], [(100, 1)]), [(100.0, 1.0)]);
  });

  group("voice control", () {
    test("player commands", () {
      expect((VoiceControlService.parse("Pause the music") as PlayerCommand).action, PlayerAction.pause);
      expect((VoiceControlService.parse("next song") as PlayerCommand).action, PlayerAction.next);
      expect((VoiceControlService.parse("turn it up") as PlayerCommand).action, PlayerAction.louder);
      expect((VoiceControlService.parse("set volume to 40%") as SetVolumeCommand).percent, 40);
      expect((VoiceControlService.parse("play my favorites") as ShuffleCommand).favorites, isTrue);
    });

    test("play requests", () {
      final album = VoiceControlService.parse("play the album Nevermind") as PlayCommand;
      expect((album.query, album.kind), ("nevermind", BaseItemDtoType.album));
      final song = VoiceControlService.parse("Play Hotel California by the Eagles") as PlayCommand;
      expect((song.query, song.artist, song.kind), ("hotel california", "the eagles", BaseItemDtoType.track));
      expect(VoiceControlService.parse("something chill for cooking"), isA<MixCommand>());
    });

    test("similar names", () {
      expect(VoiceControlService.similarity("the beatles", "The Beatles"), 1);
      expect(VoiceControlService.similarity("ac dc", "AC/DC"), greaterThan(0.9));
      expect(VoiceControlService.similarity("nevermind", "Abbey Road"), lessThan(0.5));
    });
  });

  group("running", () {
    test("cadence from step times", () {
      final steps = [for (var i = 0; i < 20; i++) i * 375]; // 160 steps a minute
      expect(RunningService.cadenceFrom(steps), closeTo(160, 0.5));
      expect(RunningService.cadenceFrom(steps.take(4).toList()), isNull);
    });

    test("half and double time match", () {
      expect(RunningService.mismatch(160, 160), 0);
      expect(RunningService.mismatch(80, 160), 0);
      expect(RunningService.mismatch(170, 85), 0);
      expect(RunningService.mismatch(120, 160), closeTo(0.25, 0.001));
    });

    test("picks songs close to the pace, without excluded ones", () {
      final pool = [for (var i = 0; i < 30; i++) _track("$i", "Song $i", artist: "Artist ${i % 3}")];
      final tempos = {for (var i = 0; i < 30; i++) "$i": 100.0 + i * 5}; // 100…245
      final picked = RunningService.pick(pool, tempos, 170, exclude: {"14"}, count: 3, random: Random(2));
      expect(picked, hasLength(3));
      for (final track in picked) {
        expect(track.id.raw, isNot("14"));
        expect(RunningService.mismatch(tempos[track.id.raw]!, 170), lessThanOrEqualTo(0.06));
      }
    });

    test("running widens the tempo pool to find different artists and respects the current artist", () {
      final pool = [
        for (var i = 0; i < 5; i++) _track("a$i", "Song A$i", artist: "A"),
        _track("b", "Song B", artist: "B"),
        _track("c", "Song C", artist: "C"),
      ];
      final tempos = {for (var i = 0; i < 5; i++) "a$i": 170.0, "b": 185.0, "c": 190.0};
      final picked = RunningService.pick(
        pool,
        tempos,
        170,
        exclude: {},
        count: 4,
        random: Random(2),
        previous: pool.first,
      );
      expect(picked, hasLength(4));
      var previous = "A";
      for (final track in picked) {
        expect(track.albumArtist, isNot(previous));
        previous = track.albumArtist!;
      }
    });

    test("a single-artist running pool makes a shorter mix rather than repeating the artist", () {
      final pool = [for (var i = 0; i < 5; i++) _track("$i", "Song $i")];
      final tempos = {for (var i = 0; i < 5; i++) "$i": 170.0};
      expect(RunningService.pick(pool, tempos, 170, exclude: {}, count: 4), hasLength(1));
    });
  });

  group("concerts", () {
    test("top artists by listening time in the last half year", () {
      final now = DateTime(2026, 10, 17);
      ListenEntry listen(String artist, int minutes, {int daysAgo = 1}) => ListenEntry(
        time: now.subtract(Duration(days: daysAgo)),
        listened: Duration(minutes: minutes),
        trackId: "t",
        track: "t",
        artist: artist,
      );
      final top = ConcertService.topArtists([
        listen("Radiohead", 10),
        listen("radiohead", 10),
        listen("Muse", 15),
        listen("ABBA", 100, daysAgo: 300),
      ], now);
      expect(top, ["Radiohead", "Muse"]);
    });

    test("only events by the artist", () {
      Map<String, dynamic> event(String id, String attraction) => {
        "id": id,
        "name": "Tour",
        "url": "https://example.com/$id",
        "dates": {
          "start": {"localDate": "2026-12-01"},
        },
        "_embedded": {
          "attractions": [
            {"name": attraction},
          ],
          "venues": [
            {
              "name": "Ziggo Dome",
              "city": {"name": "Amsterdam"},
            },
          ],
        },
      };
      final concerts = ConcertService.parse({
        "_embedded": {
          "events": [event("1", "Muse"), event("2", "Muse Tribute Band")],
        },
      }, "Muse");
      expect(concerts.map((concert) => concert.id), ["1"]);
      expect(concerts.single.venue, "Ziggo Dome");
      expect(concerts.single.city, "Amsterdam");
    });
  });
}
