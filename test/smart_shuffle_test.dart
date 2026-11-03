import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/shuffle_randomness.dart';
import 'package:finamp/services/smart_shuffle.dart';
import 'package:flutter_test/flutter_test.dart';

BaseItemDto _track(String id, String artist) =>
    BaseItemDto(id: BaseItemId(id), name: id, artists: [artist], type: "Audio", runTimeTicks: 4 * 60 * 10000000);

final _source = QueueItemSource.rawId(
  type: QueueItemSourceType.allTracks,
  id: "smartShuffle",
  name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Smart Shuffle"),
);

Duration _duration(List<BaseItemDto> tracks) =>
    tracks.fold(Duration.zero, (total, track) => total + track.runTimeTicksDuration()!);

void _expectSpaced(List<BaseItemDto> tracks) {
  for (var i = 1; i < tracks.length; i++) {
    expect(ArtistSpacing.artistKey(tracks[i]), isNot(ArtistSpacing.artistKey(tracks[i - 1])));
  }
}

void main() {
  for (final harmonic in [true, false]) {
    test("fills 30 minutes after spacing the full ${harmonic ? 'harmonic' : 'shuffled'} pool", () {
      final tracks = [for (var i = 0; i < 7; i++) _track("a$i", "A"), for (var i = 0; i < 5; i++) _track("b$i", "B")];
      final mix = prepareSmartShuffle(tracks, _source, minutes: 30, harmonic: harmonic);
      expect(mix, hasLength(8));
      expect(_duration(mix), const Duration(minutes: 32));
      _expectSpaced(mix);
      final queued = ArtistSpacing.prepareStart(
        harmonic ? mix : ShuffleRandomness.libraryOrder(mix),
        _source,
        startingIndex: harmonic ? 0 : null,
      ).items;
      expect(queued, harmonic ? orderedEquals(mix) : unorderedEquals(mix));
      expect(_duration(queued), _duration(mix));
      expect(tracks, hasLength(12));
    });
  }

  test("a shuffled odd prefix keeps its length after library sorting and player shuffling", () {
    final tracks = [for (var i = 0; i < 5; i++) _track("z$i", "A"), for (var i = 0; i < 4; i++) _track("a$i", "B")];
    final mix = prepareSmartShuffle(tracks, _source, minutes: 18);
    final sorted = ShuffleRandomness.libraryOrder(mix);
    expect(ArtistSpacing.artistKey(sorted.first), "b");
    final queued = ArtistSpacing.prepareStart(sorted, _source).items;
    expect(queued, unorderedEquals(mix));
    expect(_duration(queued), const Duration(minutes: 20));
    for (final randomness in [0, 50, 100]) {
      final indices = ShuffleRandomness.indices(queued, ArtistSpacing.artistKey, randomness, random: Random(3));
      final played = [for (final index in indices) queued[index]];
      expect(played, unorderedEquals(mix));
      _expectSpaced(played);
    }
  });

  test("a harmonic mix keeps its first song when pruning an unavoidable tail", () {
    final tracks = [_track("b0", "B"), for (var i = 0; i < 5; i++) _track("a$i", "A"), _track("b1", "B")];
    final mix = prepareSmartShuffle(tracks, _source, minutes: 30, harmonic: true);
    expect(mix.first, same(tracks.first));
    expect(mix, hasLength(4));
    _expectSpaced(mix);
    expect(ArtistSpacing.prepareStart(mix, _source, startingIndex: 0).items, mix);
  });

  test("any length keeps the full spaced pool and short pools keep only playable songs", () {
    final tracks = [for (var i = 0; i < 7; i++) _track("a$i", "A"), _track("b0", "B")];
    for (final minutes in <int?>[null, 30]) {
      final mix = prepareSmartShuffle(tracks, _source, minutes: minutes);
      expect(mix, hasLength(3));
      _expectSpaced(mix);
    }
    expect(prepareSmartShuffle([], _source, minutes: 30), isEmpty);
  });
}
