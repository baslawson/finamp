import 'dart:math';

import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';

/// How well one song follows on from the one before it in key and tempo.
enum TransitionGrade {
  /// The same or a neighbouring key at about the same tempo.
  smooth,

  /// Noticeable, but fine in a mix.
  fine,

  /// A clash in key or tempo.
  rough,

  /// One of the two songs hasn't been analysed.
  unknown,
}

/// A move that makes a rough transition smoother: the song at [from] goes to [to], between the clashing pair.
typedef MixFix = ({int from, int to, double gain});

/// The queue drawn as a mix: how each song follows on, and moves that smooth out the clashes.
class MixMap {
  MixMap._();

  /// Up to this transition cost, songs flow smoothly (the same or a neighbouring key, within about 3% in tempo).
  static const smoothUpTo = 2.0;

  /// Up to this cost a transition is fine; above it, it clashes.
  static const fineUpTo = 4.5;

  /// How [to] follows on from [from].
  static TransitionGrade grade(TrackAnalysis? from, TrackAnalysis? to) {
    if (from == null ||
        to == null ||
        (from.camelot == null && from.bpm == null) ||
        (to.camelot == null && to.bpm == null)) {
      return TransitionGrade.unknown;
    }
    final cost = DjTransitionService.transitionCost(from, to);
    if (cost <= smoothUpTo) return TransitionGrade.smooth;
    if (cost <= fineUpTo) return TransitionGrade.fine;
    return TransitionGrade.rough;
  }

  /// The best move to smooth out the transition from [songs]`[clash]` to the song after it: a later song moved in
  /// between, if that makes the whole mix flow better, counting the gap it leaves behind. Null when nothing helps.
  /// The first song (the one playing) and the two songs of the clash stay where they are, and only songs from
  /// [firstMovable] on move (so a queued song doesn't land among Next Up songs before it), and only ones before
  /// [movableBefore]: songs after that are only there so a moved song's real successor counts.
  static MixFix? bestFix(List<TrackAnalysis?> songs, int clash, {int firstMovable = 1, int? movableBefore}) {
    if (clash < 0 || clash + 2 >= songs.length || clash + 1 < firstMovable) return null;
    final end = min(songs.length, movableBefore ?? songs.length);
    double cost(int a, int b) => DjTransitionService.transitionCost(songs[a], songs[b]);
    final next = clash + 1;
    MixFix? best;
    for (var k = next + 1; k < end; k++) {
      // Only songs whose key or tempo is known next to both songs of the clash.
      if (grade(songs[clash], songs[k]) == TransitionGrade.unknown ||
          grade(songs[k], songs[next]) == TransitionGrade.unknown) {
        continue;
      }
      final last = k + 1 >= songs.length;
      final leaving = cost(k - 1, k) + (last ? 0 : cost(k, k + 1)) - (last ? 0 : cost(k - 1, k + 1));
      final arriving = cost(clash, k) + cost(k, next) - cost(clash, next);
      final gain = leaving - arriving;
      if (gain > 0.5 && (best == null || gain > best.gain)) best = (from: k, to: next, gain: gain);
    }
    return best;
  }

  /// Whether [fix], worked out on the songs [drawn] (by id, the one playing first) with the main queue starting at
  /// [drawnFirstMovable], still moves the same songs in the queue as it is [now].
  static bool stillApplies(
    MixFix fix, {
    required List<String> drawn,
    required int drawnFirstMovable,
    required List<String> now,
    required int nowFirstMovable,
  }) =>
      drawnFirstMovable == nowFirstMovable &&
      fix.from < drawn.length &&
      fix.from < now.length &&
      now[fix.from] == drawn[fix.from] &&
      now[fix.to] == drawn[fix.to];

  /// [songs] in order after [fix].
  static List<T> apply<T>(List<T> songs, MixFix fix) {
    final moved = [...songs];
    final song = moved.removeAt(fix.from);
    moved.insert(fix.to, song);
    return moved;
  }
}
