import 'dart:math';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/shuffle_randomness.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/services/running_service.dart';
import 'package:finamp/services/right_now_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('failed media preparation remaps shuffle indices and retains the selected song', () {
    final result = ShuffleRandomness.retainPlayableIndices([4, 1, 3, 0, 2], [0, 1, 3, 4], initialIndex: 4);
    expect(result.indices, [3, 1, 2, 0]);
    expect(result.initialIndex, 3);
    expect(result.nextUpLength, 0);
    expect(result.indices, unorderedEquals([0, 1, 2, 3]));
  });

  test('a failed selected song advances in shuffle order rather than playing history', () {
    final result = ShuffleRandomness.retainPlayableIndices([0, 3, 4, 1, 2], [0, 1, 2, 4], initialIndex: 3);
    expect(result.indices, [0, 3, 1, 2]);
    expect(result.initialIndex, 3); // Original song 4, after original current song 3.
  });

  test('failed tracks in Next Up shrink the pinned block without pinning regular queue songs', () {
    final result = ShuffleRandomness.retainPlayableIndices(
      [0, 1, 2, 3, 4, 5],
      [0, 2, 3, 5],
      initialIndex: 1,
      nextUpLength: 2,
    );
    expect(result.initialIndex, 1); // Original Next Up song 2 becomes current.
    expect(result.nextUpLength, 1); // Only original Next Up song 3 stays pinned.
    final missingNextUp = ShuffleRandomness.retainPlayableIndices(
      [0, 1, 2, 3, 4, 5],
      [0, 1, 4, 5],
      initialIndex: 1,
      nextUpLength: 2,
    );
    expect(missingNextUp.initialIndex, 1);
    expect(missingNextUp.nextUpLength, 0);
  });

  test('empty and wholly failed media pools produce no invalid shuffle indices', () {
    expect(ShuffleRandomness.indices(<String>[], (track) => track, 100), isEmpty);
    final result = ShuffleRandomness.retainPlayableIndices([0, 1, 2], [], initialIndex: 1, nextUpLength: 1);
    expect(result.indices, isEmpty);
    expect(result.initialIndex, 0);
    expect(result.nextUpLength, 0);
  });

  test('falling back to shuffled history never turns old songs into Next Up', () {
    final result = ShuffleRandomness.retainPlayableIndices([2, 1, 0, 3], [0, 1, 2], initialIndex: 3);
    expect(result.indices, [2, 1, 0]);
    expect(result.initialIndex, 0);
    expect(result.nextUpLength, 0);
  });

  test('Right Now varies familiar selections without changing the fresh share', () {
    final familiar = [for (var i = 0; i < 150; i++) BaseItemDto(id: BaseItemId('familiar-$i'))];
    final fresh = [for (var i = 0; i < 25; i++) BaseItemDto(id: BaseItemId('fresh-$i'))];
    final ordered = RightNowService.mixTracks(familiar, fresh, randomness: 0);
    expect(ordered, [...familiar.take(38), ...fresh.take(12)]);
    final firstSelection = <String>[];
    for (var seed = 0; seed < 10; seed++) {
      final mix = RightNowService.mixTracks(familiar, fresh, randomness: 100, random: Random(seed));
      expect(mix, hasLength(50));
      expect(mix.where((track) => track.id.raw.startsWith('familiar-')), hasLength(38));
      expect(mix.where((track) => track.id.raw.startsWith('fresh-')), hasLength(12));
      firstSelection.add(mix.map((track) => track.id.raw).join(','));
    }
    expect(firstSelection.toSet().length, greaterThan(5));
  });

  test('0% preserves the ranking, clamps values, and leaves the input intact', () {
    final input = List.generate(50, (i) => i);
    expect(ShuffleRandomness.order(input, 0), input);
    expect(ShuffleRandomness.order(input, -50), input);
    expect(
      ShuffleRandomness.order(input, 200, random: Random(7)),
      ShuffleRandomness.order(input, 100, random: Random(7)),
    );
    final result = ShuffleRandomness.order(input, 100, random: Random(1));
    expect(result, unorderedEquals(input));
    expect(result, isNot(input));
    expect(input, List.generate(50, (i) => i));
    expect(ShuffleRandomness.order(<int>[], 50), isEmpty);
    expect(ShuffleRandomness.order([1], 50), [1]);
  });

  test('movement increases across intermediate percentages', () {
    final input = List.generate(60, (i) => i);
    final movement = <int>[];
    for (final percentage in [0, 10, 25, 50, 75, 100]) {
      var total = 0;
      for (var seed = 0; seed < 200; seed++) {
        final result = ShuffleRandomness.order(input, percentage, random: Random(seed));
        total += [for (final (index, item) in result.indexed) (index - item).abs()].reduce((a, b) => a + b);
        expect(result, unorderedEquals(input));
      }
      movement.add(total);
    }
    for (var i = 1; i < movement.length; i++) {
      expect(movement[i], greaterThan(movement[i - 1]), reason: '$movement');
    }
  });

  test('100% has no preference for the original first track', () {
    final firstCounts = List.filled(5, 0);
    for (var seed = 0; seed < 4000; seed++) {
      firstCounts[ShuffleRandomness.order([0, 1, 2, 3, 4], 100, random: Random(seed)).first]++;
    }
    for (final count in firstCounts) {
      expect(count, inInclusiveRange(650, 950), reason: '$firstCounts');
    }
  });

  test('current song and Next Up stay pinned at every percentage', () {
    final input = ['a1', 'b1', 'c1', 'a2', 'b2', 'c2', 'a3', 'b3', 'c3'];
    for (final percentage in [0, 10, 25, 50, 75, 100]) {
      for (var seed = 0; seed < 30; seed++) {
        final result = ShuffleRandomness.indices(
          input,
          (track) => track[0],
          percentage,
          random: Random(seed),
          initialIndex: 2,
          nextUpLength: 1,
        );
        expect(result.take(2), [2, 3]);
        expect(result, unorderedEquals(List.generate(input.length, (i) => i)));
        for (var i = 1; i < result.length; i++) {
          expect(input[result[i]][0], isNot(input[result[i - 1]][0]));
        }
      }
    }
  });

  test('fresh shuffles keep bare-majority artists feasible at every percentage', () {
    for (final percentage in [0, 50, 100]) {
      for (var seed = 0; seed < 30; seed++) {
        final input = ['b1', 'a1', 'a2', 'a3', 'b2'];
        final result = ShuffleRandomness.indices(input, (track) => track[0], percentage, random: Random(seed));
        expect(input[result.first][0], 'a');
        for (var i = 1; i < result.length; i++) {
          expect(input[result[i]][0], isNot(input[result[i - 1]][0]));
        }
      }
    }
  });

  test('explicit artist requests allow repeats while still honoring randomness', () {
    final input = ['a1', 'a2', 'a3', 'a4', 'a5'];
    expect(ShuffleRandomness.indices(input, (track) => track[0], 0, allowArtistRepeats: true), [0, 1, 2, 3, 4]);
    final result = ShuffleRandomness.indices(
      input,
      (track) => track[0],
      100,
      allowArtistRepeats: true,
      random: Random(12),
    );
    expect(result, unorderedEquals([0, 1, 2, 3, 4]));
    expect(result, isNot([0, 1, 2, 3, 4]));
  });

  test('random candidate pools get the same baseline regardless of server order', () {
    final a = BaseItemDto(id: const BaseItemId('1'), name: 'A');
    final b = BaseItemDto(id: const BaseItemId('2'), name: 'B');
    expect(ShuffleRandomness.libraryOrder([b, a]), [a, b]);
    expect(ShuffleRandomness.libraryOrder([a, b]), [a, b]);
  });

  test('radio follows suitability at 0% and uses the shared randomizer at 100%', () {
    final input = [1, 3, 2];
    expect(RadioTuning.weightedShuffle(input, (item) => item.toDouble(), randomness: 0), [3, 2, 1]);
    expect(
      RadioTuning.weightedShuffle(input, (item) => item.toDouble(), randomness: 100, random: Random(9)),
      ShuffleRandomness.order([3, 2, 1], 100, random: Random(9)),
    );
  });

  test('harmonic Radio still prefers matching songs at 100% randomness', () {
    var heavyFirst = 0;
    for (var seed = 0; seed < 400; seed++) {
      final order = RadioTuning.weightedShuffle(
        ['light', 'heavy', 'middle'],
        (item) => switch (item) {
          'heavy' => 1.0,
          'middle' => 0.3,
          _ => 0.1,
        },
        randomness: 100,
        weightedRandom: true,
        random: Random(seed),
      );
      expect(order.toSet(), {'light', 'heavy', 'middle'});
      if (order.first == 'heavy') heavyFirst++;
    }
    // A plain random order would put it first about a third of the time.
    expect(heavyFirst, greaterThan(220));
    expect(RadioTuning.weightedShuffle([1, 3, 2], (item) => item.toDouble(), randomness: 0, weightedRandom: true), [
      3,
      2,
      1,
    ]);
  });

  test('harmonic strength sets how much a clash in key or tempo counts for Radio', () {
    expect(RadioTuning.harmonicStrictness(0), closeTo(0.25, 1e-9));
    expect(RadioTuning.harmonicStrictness(HarmonicMixing.defaultStrength), closeTo(1.0, 1e-9));
    expect(RadioTuning.harmonicStrictness(100), greaterThan(1.5));
    expect(RadioTuning.harmonicStrictness(50), lessThan(1.0));
  });

  test('running follows tempo at 0% and keeps its filters at 100%', () {
    final tracks = [
      for (var i = 0; i < 12; i++)
        BaseItemDto(id: BaseItemId('$i'), name: 'Song $i', artists: ['Artist $i'], type: 'Audio'),
    ];
    final tempos = {for (var i = 0; i < tracks.length; i++) '$i': 160.0 + i};
    final ordered = RunningService.pick(tracks, tempos, 160, exclude: {'0'}, randomness: 0, count: 4);
    expect(ordered.map((track) => track.id.raw), ['1', '2', '3', '4']);
    final result = RunningService.pick(
      tracks,
      tempos,
      160,
      exclude: {'0'},
      randomness: 100,
      count: 4,
      random: Random(2),
    );
    expect(result, hasLength(4));
    expect(result.any((track) => track.id.raw == '0'), isFalse);
    for (final track in result) {
      expect(RunningService.mismatch(tempos[track.id.raw]!, 160), lessThanOrEqualTo(0.06));
    }
  });
}
