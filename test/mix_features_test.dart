import 'dart:math';

import 'package:finamp/components/mix_feel.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/good_match.dart';
import 'package:finamp/services/mix_export.dart';
import 'package:finamp/services/mix_map.dart';
import 'package:finamp/services/smart_shuffle.dart';
import 'package:finamp/services/mix_export_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BaseItemDto _track(String id, String artist, {int minutes = 4, String? path}) => BaseItemDto(
  id: BaseItemId(id),
  name: id,
  artists: [artist],
  type: "Audio",
  runTimeTicks: minutes * 60 * 10000000,
  path: path,
);

final _source = QueueItemSource.rawId(
  type: QueueItemSourceType.allTracks,
  id: "smartShuffle",
  name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Smart Shuffle"),
);

TrackAnalysis _song(String camelot, double bpm) => TrackAnalysis(camelot: camelot, bpm: bpm);

void main() {
  group("Mix map", () {
    test("grades transitions by key and tempo", () {
      expect(MixMap.grade(_song("8A", 120), _song("9A", 121)), TransitionGrade.smooth);
      expect(MixMap.grade(_song("8A", 120), _song("10A", 122)), TransitionGrade.fine);
      expect(MixMap.grade(_song("8A", 120), _song("2B", 150)), TransitionGrade.rough);
      expect(MixMap.grade(_song("8A", 120), null), TransitionGrade.unknown);
      expect(MixMap.grade(_song("8A", 120), const TrackAnalysis(energy: 0.5)), TransitionGrade.unknown);
      // Half and double time mix fine.
      expect(MixMap.grade(_song("8A", 120), _song("8A", 60)), TransitionGrade.smooth);
    });

    test("moves a later song in between a clash when the whole mix flows better", () {
      final songs = [_song("8A", 120), _song("2B", 150), _song("3B", 151), _song("9A", 121)];
      expect(MixMap.grade(songs[0], songs[1]), TransitionGrade.rough);
      final fix = MixMap.bestFix(songs, 0)!;
      expect((fix.from, fix.to), (3, 1));
      final fixed = MixMap.apply(songs, fix);
      expect(fixed, [songs[0], songs[3], songs[1], songs[2]]);
      double total(List<TrackAnalysis?> order) => [
        for (var i = 0; i + 1 < order.length; i++) DjTransitionService.transitionCost(order[i], order[i + 1]),
      ].fold(0.0, (a, b) => a + b);
      expect(total(fixed), lessThan(total(songs)));
    });

    test("a fix is dropped once the queue has moved on from what was drawn", () {
      const fix = (from: 3, to: 1, gain: 2.0);
      const drawn = ["playing", "a", "b", "c"];
      bool applies(List<String> now, {int firstMovable = 1}) =>
          MixMap.stillApplies(fix, drawn: drawn, drawnFirstMovable: 1, now: now, nowFirstMovable: firstMovable);
      expect(applies(drawn), isTrue);
      // The next song started: every offset now points one song further on.
      expect(applies(["a", "b", "c", "d"]), isFalse);
      expect(applies(["playing", "a"]), isFalse);
      expect(applies(drawn, firstMovable: 2), isFalse);
    });

    test("a song past the ones drawn counts as the moved song's successor but isn't moved itself", () {
      // Drawn: the first four. Moving the last one drawn would open a clash with the fifth, which scoring must count.
      final songs = [_song("8A", 120), _song("2B", 150), _song("3B", 151), _song("9A", 121), _song("9A", 121)];
      final fix = MixMap.bestFix(songs, 0, movableBefore: 4);
      expect(fix, isNotNull);
      expect(fix!.from, lessThan(4));
      final withoutNext = MixMap.bestFix(songs.take(4).toList(), 0)!;
      // Without the fifth song the move looks better than it is.
      expect(withoutNext.gain, greaterThan(fix.gain));
      expect(MixMap.bestFix(songs, 0, movableBefore: 3), isNotNull);
    });

    test("only moves songs in the main queue, never in among Next Up", () {
      final songs = [_song("8A", 120), _song("2B", 150), _song("3B", 151), _song("9A", 121)];
      // Songs 1 and 2 are Next Up: the clash after the playing song can't take a queued song in between.
      expect(MixMap.bestFix(songs, 0, firstMovable: 3), isNull);
      expect(MixMap.bestFix(songs, 0, firstMovable: 1), isNotNull);
    });

    test("offers nothing when no move helps, or at the end of the mix", () {
      final songs = [_song("8A", 120), _song("2B", 150), _song("2B", 150)];
      expect(MixMap.bestFix(songs, 0), isNull);
      expect(MixMap.bestFix(songs, 1), isNull);
      expect(MixMap.bestFix([_song("8A", 120), _song("2B", 150), null], 0), isNull);
    });
  });

  group("Good match", () {
    test("ranks by how well songs follow on, skipping queued ones", () {
      final analysis = {
        "close": _song("9A", 121),
        "clash": _song("2B", 150),
        "same": _song("8A", 120),
        "queued": _song("8A", 120),
        "unknown": null,
      };
      final ranked = GoodMatch.rank(
        _song("8A", 120),
        ["clash", "unknown", "close", "queued", "same"],
        analysis: (id) => analysis[id],
        skip: (id) => id == "queued",
      );
      expect(ranked, ["same", "close", "clash", "unknown"]);
    });

    test("keeps the analyzer's order when the playing song isn't analysed", () {
      expect(GoodMatch.rank<String>(null, ["a", "b", "c"], analysis: (_) => _song("8A", 120)), ["a", "b", "c"]);
    });

    test("leaves out other copies of the song playing, of queued songs, and of each other", () {
      BaseItemDto copy(String id, String name, String artist) =>
          BaseItemDto(id: BaseItemId(id), name: name, albumArtist: artist, artists: [artist], type: "Audio");
      final playing = copy("p", "Song", "Band");
      final candidates = GoodMatch.candidates(
        [copy("p2", "Song", "Band"), copy("o1", "Other", "Band"), copy("o2", "Other", "Band"), copy("n", "New", "Act")],
        [playing],
      );
      expect([for (final track in candidates) track.id.raw], ["o1", "n"]);
    });

    test("offers at most five", () {
      expect(GoodMatch.rank(null, List.generate(9, (i) => "$i"), analysis: (_) => null), hasLength(GoodMatch.count));
    });
  });

  group("M3U export", () {
    test("writes each song's file with its length and name, leaving out songs without one", () {
      final export = MixExport.m3u("Friday\nnight", [
        _track("One", "A", minutes: 3, path: "/music/A/One.flac"),
        _track("Two", "B"),
        _track("Three", "C", path: "/music/C/Three.mp3"),
      ]);
      expect(export.skipped, 1);
      expect(
        export.text,
        "#EXTM3U\n#PLAYLIST:Friday night\n"
        "#EXTINF:180,A - One\n/music/A/One.flac\n"
        "#EXTINF:240,C - Three\n/music/C/Three.mp3\n",
      );
    });

    test("uses paths looked up for songs that don't carry one", () {
      final export = MixExport.m3u("Mix", [_track("Two", "B")], pathOf: (_) => "/music/B/Two.ogg");
      expect(export.skipped, 0);
      expect(export.text, contains("/music/B/Two.ogg"));
    });

    test("makes a safe file name", () {
      expect(MixExport.fileName('Smart Shuffle: 1980s / "Rock"'), "Smart Shuffle 1980s Rock.m3u");
      expect(MixExport.fileName("  "), "Mix.m3u");
    });
  });

  group("Energy shapes", () {
    test("waves rise and fall twice", () {
      final items = List.generate(9, (i) => i / 8);
      final waved = DjTransitionService.shapeOrder(items, (level) => level, EnergyShape.wave);
      expect(waved.first, lessThan(0.3));
      expect(waved[2], greaterThan(0.6));
      expect(waved[4], lessThan(0.5));
      expect(waved[6], greaterThan(0.6));
      expect(waved.last, lessThan(0.5));
    });

    test("a shaped Smart Shuffle fills the length first, then runs along the shape, spaced by artist", () {
      final tracks = [for (var i = 0; i < 20; i++) _track("t$i", "artist${i % 5}")];
      final intensity = {for (var i = 0; i < 20; i++) "t$i": (i * 7 % 20) / 19};
      final mix = shapeSmartShuffle(
        tracks,
        _source,
        shape: EnergyShape.build,
        intensity: (track) => intensity[track.id.raw],
        minutes: 30,
        random: Random(1),
      )!;
      expect(mix.length, 8);
      for (var i = 1; i < mix.length; i++) {
        expect(ArtistSpacing.artistKey(mix[i]), isNot(ArtistSpacing.artistKey(mix[i - 1])));
      }
      // Calm to intense overall.
      final levels = [for (final track in mix) intensity[track.id.raw]!];
      expect(levels.first, lessThan(levels.last));
      final queued = ArtistSpacing.prepareStart(mix, _source, startingIndex: 0).items;
      expect(queued, orderedEquals(mix));
    });

    test("a shaped Smart Shuffle starts with an artist the rest can be spaced around, so none are dropped", () {
      // Three A songs and two calmer B songs: calm-first would start with B and leave A twice at the end.
      final tracks = [_track("a1", "A"), _track("a2", "A"), _track("a3", "A"), _track("b1", "B"), _track("b2", "B")];
      final intensity = {"a1": 0.6, "a2": 0.7, "a3": 0.8, "b1": 0.1, "b2": 0.2};
      final mix = shapeSmartShuffle(
        tracks,
        _source,
        shape: EnergyShape.build,
        intensity: (track) => intensity[track.id.raw],
        minutes: 18,
      )!;
      expect(mix, hasLength(5));
      final queued = ArtistSpacing.prepareStart(mix, _source, startingIndex: 0).items;
      expect(queued, orderedEquals(mix));
      for (var i = 1; i < mix.length; i++) {
        expect(ArtistSpacing.artistKey(mix[i]), isNot(ArtistSpacing.artistKey(mix[i - 1])));
      }
    });

    test("a shaped Smart Shuffle keeps every song when the pool starts with a minority artist", () {
      final tracks = [_track("b1", "B"), _track("a1", "A"), _track("a2", "A"), _track("a3", "A"), _track("b2", "B")];
      final mix = shapeSmartShuffle(tracks, _source, shape: EnergyShape.build, intensity: (track) => 0.5, minutes: 20)!;
      expect(mix, hasLength(5));
      expect(ArtistSpacing.prepareStart(mix, _source, startingIndex: 0).items, orderedEquals(mix));
    });

    test("an Ai DJ or shaped order is spaced from a first artist the rest can go around, keeping every song", () {
      // The AI or the shape put the minority artist first: kept there, A would play twice at the end.
      final order = [_track("b1", "B"), _track("a1", "A"), _track("b2", "B"), _track("a2", "A"), _track("a3", "A")];
      final spaced = DjTransitionService.spreadArtistsFreely(order);
      expect(spaced, unorderedEquals(order));
      for (var i = 1; i < spaced.length; i++) {
        expect(ArtistSpacing.artistKey(spaced[i]), isNot(ArtistSpacing.artistKey(spaced[i - 1])));
      }
      expect(DjTransitionService.spreadArtists(order).length, 5);
      expect(ArtistSpacing.prepareStart(spaced, _source, startingIndex: 0).items, hasLength(5));
      expect(
        ArtistSpacing.prepareStart(DjTransitionService.spreadArtists(order), _source, startingIndex: 0).items,
        hasLength(4),
      );
    });

    test("a shaped Smart Shuffle gives up when too few songs are measured", () {
      final tracks = [for (var i = 0; i < 10; i++) _track("t$i", "artist$i")];
      expect(
        shapeSmartShuffle(
          tracks,
          _source,
          shape: EnergyShape.peak,
          intensity: (track) => track.id.raw == "t0" ? 0.5 : null,
        ),
        isNull,
      );
    });
  });

  group("Mix feel", () {
    test("reads percentages off the pad, with strength rising upwards", () {
      expect(mixFeelPercentAt(0, 200), 0);
      expect(mixFeelPercentAt(100, 200), 50);
      expect(mixFeelPercentAt(250, 200), 100);
      expect(mixFeelPercentAt(-5, 200), 0);
      expect(mixFeelPercentAt(0, 140, flipped: true), 100);
      expect(mixFeelPercentAt(140, 140, flipped: true), 0);
      expect(mixFeelPercentAt(10, 0), 0);
    });

    test("names a preset only when both values match", () {
      expect(mixFeelPresetOf(50, 75), mixFeelPresets[1]);
      expect(mixFeelPresetOf(50, 76), isNull);
    });
  });

  testWidgets("the share sheet points at the button that asked, as iPad needs", (tester) async {
    Rect? origin;
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 40, top: 20),
            child: Builder(
              builder: (context) =>
                  SizedBox(width: 48, height: 30, child: GestureDetector(onTap: () => origin = shareOriginOf(context))),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(GestureDetector));
    expect(origin, const Rect.fromLTWH(40, 20, 48, 30));
  });
}
