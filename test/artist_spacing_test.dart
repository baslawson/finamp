import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:flutter_test/flutter_test.dart';

BaseItemDto _track(String id, String? artist) =>
    BaseItemDto(id: BaseItemId(id), name: id, artists: artist == null ? null : [artist], type: "Audio");

QueueItemSource _source({
  String id = "smartShuffle",
  QueueItemSourceType type = QueueItemSourceType.unknown,
  bool repeat = false,
}) => QueueItemSource.rawId(
  type: type,
  id: id,
  name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Mix"),
  allowArtistRepeats: repeat,
);

int _repeats(List<String> artists, {String? previous}) {
  var count = 0;
  for (final artist in artists) {
    if (artist == previous) count++;
    previous = artist;
  }
  return count;
}

void main() {
  test('a deliberately picked first song stays pinned while its followers are spaced', () {
    final picked = _track('picked', 'A');
    final result = ArtistSpacing.generated(
      [picked, _track('a1', 'A'), _track('b1', 'B'), _track('b2', 'B'), _track('a2', 'A')],
      _source(type: QueueItemSourceType.radio),
      previous: _track('playing', 'A'),
      keepFirst: true,
    );
    expect(result.first, same(picked));
    expect(_repeats(result.map((item) => ArtistSpacing.artistKey(item)!).toList()), 0);
  });

  test("uses separators before a dominant artist becomes an avoidable repeated tail", () {
    final input = ["b1", "c1", "a1", "a2", "a3"];
    final result = ArtistSpacing.order(input, (track) => track[0], keepFirst: false, dropUnavoidable: true);
    expect(result, ["a1", "b1", "a2", "c1", "a3"]);
    expect(input, ["b1", "c1", "a1", "a2", "a3"]);
  });

  test("strict generated mixes leave out an unavoidable repeated tail", () {
    final input = [
      for (var i = 0; i < 7; i++) _track("a$i", "A"),
      _track("b1", "B"),
      _track("b2", "B"),
      _track("c1", "C"),
    ];
    final result = ArtistSpacing.generated(input, _source());
    expect(result, hasLength(7));
    expect(_repeats(result.map((track) => ArtistSpacing.artistKey(track)!).toList()), 0);
    expect(result.map((track) => track.id).toSet(), hasLength(result.length));
  });

  test("a new batch avoids the artist at the existing queue's end", () {
    final result = ArtistSpacing.generated(
      [_track("a1", "A"), _track("b1", "B"), _track("a2", "A"), _track("b2", "B")],
      _source(type: QueueItemSourceType.radio),
      previous: _track("current", "A"),
    );
    expect(result.map((track) => track.artists!.single), ["B", "A", "B", "A"]);
    expect(ArtistSpacing.generated([_track("a1", "A")], _source(), previous: _track("current", "A")), isEmpty);
  });

  test("all app-generated sources use artist spacing", () {
    for (final id in [
      "aiDj",
      "smartShuffle",
      "rightNow",
      "onThisDay",
      "smartPlaylist",
      "vibe",
      "alarm",
      "lyricsSearch",
      "yearInMusic",
      "running",
    ]) {
      expect(ArtistSpacing.appliesTo(_source(id: id)), isTrue, reason: id);
    }
    for (final type in [
      QueueItemSourceType.allTracks,
      QueueItemSourceType.favorites,
      QueueItemSourceType.trackMix,
      QueueItemSourceType.artistMix,
      QueueItemSourceType.albumMix,
      QueueItemSourceType.genreMix,
      QueueItemSourceType.collectionMix,
      QueueItemSourceType.radio,
    ]) {
      expect(ArtistSpacing.appliesTo(_source(type: type)), isTrue, reason: type.name);
    }
    expect(ArtistSpacing.appliesTo(_source(type: QueueItemSourceType.genre), shuffled: true), isTrue);
    expect(ArtistSpacing.appliesTo(_source(type: QueueItemSourceType.playlist), shuffled: true), isTrue);
  });

  test("explicit artist requests and normal album or playlist order are preserved", () {
    final tracks = [_track("a1", "A"), _track("a2", "A"), _track("b1", "B")];
    for (final source in [
      _source(id: "aiDj", repeat: true),
      _source(type: QueueItemSourceType.artist),
      _source(type: QueueItemSourceType.album),
      _source(id: "playlist", type: QueueItemSourceType.playlist),
    ]) {
      expect(ArtistSpacing.generated(tracks, source), tracks);
      expect(ArtistSpacing.prepareStart(tracks, source).items, tracks);
    }
    expect(ArtistSpacing.appliesTo(_source(id: "aiDj", repeat: true), shuffled: true), isFalse);
  });

  test("track artists take precedence over compilation album artists", () {
    final track = BaseItemDto(id: const BaseItemId("1"), artists: ["AC/DC"], albumArtist: "Various Artists");
    final other = BaseItemDto(id: const BaseItemId("2"), artists: ["  acdc  "], albumArtist: "Compilation");
    expect(ArtistSpacing.artistKey(track), ArtistSpacing.artistKey(other));
    expect(
      ArtistSpacing.artistKey(
        BaseItemDto(id: const BaseItemId("3"), artists: ["", "Queen"], albumArtist: "Various Artists"),
      ),
      "queen",
    );
    expect(ArtistSpacing.artistKey(BaseItemDto(id: const BaseItemId("4"), artists: ["Queen feat. Guest"])), "queen");
    expect(
      ArtistSpacing.artistKey(BaseItemDto(id: const BaseItemId("5"), artists: ["Earth, Wind & Fire"])),
      "earthwindfire",
    );
    expect(ArtistSpacing.artistKey(BaseItemDto(id: const BaseItemId("6"), albumArtist: "Bon Jovi")), "bonjovi");
  });

  test("unknown artists don't become one artificial artist group", () {
    final tracks = [for (var i = 0; i < 4; i++) _track("$i", null)];
    expect(ArtistSpacing.generated(tracks, _source()), tracks);
    expect(ArtistSpacing.artistKey(_track("unknown", "Unknown Artist")), isNull);
  });

  test("generated shuffle starts from a feasible artist instead of fixing a bad random first track", () {
    final input = [_track("b1", "B"), _track("c1", "C"), _track("a1", "A"), _track("a2", "A"), _track("a3", "A")];
    final prepared = ArtistSpacing.prepareStart(input, _source());
    expect(prepared.startingIndex, 0);
    expect(ArtistSpacing.artistKey(prepared.items.first), "a");
    expect(prepared.items, hasLength(input.length));
  });

  test("an explicitly selected starting track and its history keep their positions", () {
    final input = [
      _track("history", "Z"),
      _track("selected", "B"),
      _track("a1", "A"),
      _track("a2", "A"),
      _track("a3", "A"),
    ];
    final prepared = ArtistSpacing.prepareStart(input, _source(), startingIndex: 1);
    expect(prepared.startingIndex, 1);
    expect(prepared.items.take(2), input.take(2));
    expect(prepared.items.map((track) => track.name), ["history", "selected", "a1"]);
  });

  test("incoming randomness survives artist spacing", () {
    final orders = <String>{};
    for (var seed = 0; seed < 30; seed++) {
      final input = ["a1", "a2", "b1", "b2", "c1", "c2"]..shuffle(Random(seed));
      final result = ArtistSpacing.order(input, (track) => track[0], keepFirst: false);
      expect(_repeats(result.map((track) => track[0]).toList()), 0);
      orders.add(result.join(","));
    }
    expect(orders.length, greaterThan(10));
  });

  test("all small artist distributions retain every track with the fewest possible repeats", () {
    for (var a = 0; a <= 4; a++) {
      for (var b = 0; b <= 4; b++) {
        for (var c = 0; c <= 4; c++) {
          final input = [...List.filled(a, "a"), ...List.filled(b, "b"), ...List.filled(c, "c")];
          for (final previous in <String?>[null, "a", "b"]) {
            final shuffled = [...input]..shuffle(Random(a * 100 + b * 10 + c));
            final result = ArtistSpacing.order(shuffled, (artist) => artist, previousKey: previous, keepFirst: false);
            var minimum = 0;
            for (final (artist, count) in [("a", a), ("b", b), ("c", c)]) {
              minimum = max(minimum, 2 * count - input.length - 1 + (previous == artist ? 1 : 0));
            }
            expect(result, unorderedEquals(input));
            expect(_repeats(result, previous: previous), minimum, reason: "$a/$b/$c after $previous: $result");
          }
        }
      }
    }
  });

  test("strict mode builds a longest valid list even when starting after another song", () {
    final memo = <String, int>{};
    int longest(int a, int b, int c, String? previous) {
      final state = "$a/$b/$c/$previous";
      return memo.putIfAbsent(state, () {
        var length = 0;
        if (a > 0 && previous != "a") length = max(length, 1 + longest(a - 1, b, c, "a"));
        if (b > 0 && previous != "b") length = max(length, 1 + longest(a, b - 1, c, "b"));
        if (c > 0 && previous != "c") length = max(length, 1 + longest(a, b, c - 1, "c"));
        return length;
      });
    }

    for (var a = 0; a <= 3; a++) {
      for (var b = 0; b <= 3; b++) {
        for (var c = 0; c <= 3; c++) {
          for (final previous in <String?>[null, "a", "b"]) {
            final input = [...List.filled(a, "a"), ...List.filled(b, "b"), ...List.filled(c, "c")]
              ..shuffle(Random(a * 100 + b * 10 + c));
            final result = ArtistSpacing.order(
              input,
              (artist) => artist,
              previousKey: previous,
              keepFirst: false,
              dropUnavoidable: true,
            );
            expect(_repeats(result, previous: previous), 0);
            expect(result.length, longest(a, b, c, previous), reason: "$a/$b/$c after $previous: $result");
          }
        }
      }
    }
  });

  test("large queues preserve every unique item", () {
    final input = List.generate(10000, (index) => (id: index, artist: index % 100))..shuffle(Random(9));
    final result = ArtistSpacing.order(input, (track) => track.artist, keepFirst: false);
    expect(result.map((track) => track.id).toSet(), hasLength(input.length));
    for (var i = 1; i < result.length; i++) {
      expect(result[i].artist, isNot(result[i - 1].artist));
    }
  });
}
