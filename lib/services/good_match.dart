import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/song_duplicates.dart';

/// Songs that would follow on well from one song: sounding alike, in a matching key and tempo.
class GoodMatch {
  GoodMatch._();

  /// How many matches are offered.
  static const count = 5;

  /// [similar] songs that could be a good match: without other copies of a song (an album and its reissue sound the
  /// same, so would rank first), or of anything [playing] or queued.
  static List<BaseItemDto> candidates(List<BaseItemDto> similar, List<BaseItemDto> playing) =>
      withoutDuplicateSongs(similar, already: playing);

  /// Up to [count] of [similar] (most alike first, from the analyzer) ranked by how well each follows [seed] in key
  /// and tempo, with how alike they sound breaking near-ties. Songs whose key and tempo aren't known come last, and
  /// [skip]ped ones (already queued, resting) not at all.
  static List<T> rank<T>(
    TrackAnalysis? seed,
    List<T> similar, {
    required TrackAnalysis? Function(T song) analysis,
    bool Function(T song)? skip,
    int limit = count,
  }) {
    final candidates = [
      for (final (place, song) in similar.indexed)
        if (!(skip?.call(song) ?? false)) (song: song, score: _score(seed, analysis(song), place / similar.length)),
    ];
    candidates.sort((a, b) => a.score.compareTo(b.score));
    return [for (final candidate in candidates.take(limit)) candidate.song];
  }

  /// Lower is better: the transition's roughness, plus up to 2 for sounding least alike of the lot.
  static double _score(TrackAnalysis? seed, TrackAnalysis? song, double unlikeness) {
    final known = seed != null && song != null && (song.camelot != null || song.bpm != null);
    // Unknown key and tempo rank after every known match, in the analyzer's order.
    return (known ? DjTransitionService.transitionCost(seed, song) : 1000) + unlikeness * 2;
  }
}
