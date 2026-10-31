import 'dart:async';
import 'dart:math';

import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("measures distances on the Camelot wheel", () {
    expect(DjTransitionService.camelotDistance("8A", "8A"), 0);
    expect(DjTransitionService.camelotDistance("8A", "9A"), 1);
    expect(DjTransitionService.camelotDistance("12B", "1B"), 1);
    expect(DjTransitionService.camelotDistance("8A", "8B"), 1);
    expect(DjTransitionService.camelotDistance("1A", "7B"), 7);
  });

  test("treats half and double time as close tempos", () {
    const slow = TrackAnalysis(bpm: 60.0, camelot: "8A");
    const fast = TrackAnalysis(bpm: 120.0, camelot: "8A");
    const other = TrackAnalysis(bpm: 90.0, camelot: "8A");
    expect(DjTransitionService.transitionCost(slow, fast), closeTo(0, 0.001));
    expect(DjTransitionService.transitionCost(slow, other), greaterThan(4));
    expect(DjTransitionService.transitionCost(null, fast), 3);
  });

  test("the cached transition cost gives the same answers", () {
    final dice = Random(5);
    final analyses = [
      for (var i = 0; i < 40; i++)
        TrackAnalysis(
          bpm: i % 7 == 0 ? null : 60 + dice.nextDouble() * 120,
          camelot: i % 5 == 0 ? null : "${1 + dice.nextInt(12)}${dice.nextBool() ? "A" : "B"}",
        ),
      null,
    ];
    final cost = DjTransitionService.cachedTransitionCost();
    for (final from in analyses) {
      for (final to in analyses) {
        expect(cost(from, to), closeTo(DjTransitionService.transitionCost(from, to), 1e-9));
      }
    }
  });

  test("orders greedily from the first item", () {
    final ordered = DjTransitionService.orderByCost([0, 10, 1, 9, 2], (a, b) => (a - b).abs().toDouble());
    expect(ordered, [0, 1, 2, 9, 10]);
  });

  test("spreads out neighbours with the same key", () {
    String artist(String track) => track[0];
    expect(DjTransitionService.spreadOut(["a1", "a2", "a3", "b1", "b2", "c1"], artist), [
      "a1",
      "b1",
      "a2",
      "b2",
      "a3",
      "c1",
    ]);
    // Nothing left to put between the last ones, so they stay together.
    expect(DjTransitionService.spreadOut(["b1", "a1", "a2", "a3"], artist), ["b1", "a1", "a2", "a3"]);
    String? unknown(String track) => null;
    expect(DjTransitionService.spreadOut(["x", "x"], unknown), ["x", "x"]);
  });

  group("harmonic order", () {
    double distance(int a, int b) => (a - b).abs().toDouble();
    bool always(int item) => true;

    test("always takes the best next item at full strength", () {
      final items = [for (var i = 0; i < 20; i++) i * 7 % 20];
      final ordered = DjTransitionService.harmonicOrder(
        items,
        distance,
        known: always,
        strength: 100,
        random: Random(3),
      );
      expect(ordered.toSet(), items.toSet());
      expect(ordered, hasLength(items.length));
      // From a random start, walking to the nearest number means at most one jump back to the other end.
      final jumps = [for (var i = 1; i < ordered.length; i++) distance(ordered[i - 1], ordered[i])].where((d) => d > 1);
      expect(jumps.length, lessThanOrEqualTo(1));
    });

    test("picks among the best few at the default strength, the same way for the same seed", () {
      final items = [for (var i = 0; i < 40; i++) i];
      List<int> order(int seed) =>
          DjTransitionService.harmonicOrder(items, distance, known: always, strength: 75, random: Random(seed));
      final ordered = order(7);
      expect(order(7), ordered);
      expect(ordered.toSet(), items.toSet());
      final remaining = {...items}..remove(ordered.first);
      for (var i = 1; i < ordered.length; i++) {
        final better = remaining.where((item) => distance(ordered[i - 1], item) < distance(ordered[i - 1], ordered[i]));
        // 40 songs to the power of 0.25: one of the best 3.
        expect(better.length, lessThan(3));
        remaining.remove(ordered[i]);
      }
    });

    test("spreads songs without analysis through the mix", () {
      final items = [for (var i = 0; i < 12; i++) i, -1, -2];
      final ordered = DjTransitionService.harmonicOrder(
        items,
        distance,
        known: (item) => item >= 0,
        strength: 100,
        random: Random(1),
      );
      expect(ordered.toSet(), items.toSet());
      final places = [ordered.indexOf(-1), ordered.indexOf(-2)]..sort();
      expect(places.last - places.first, greaterThan(3));
      expect(places.last, lessThan(ordered.length - 1));
    });

    test("carries on from the song playing, leaving it out", () {
      final ordered = DjTransitionService.harmonicOrder(
        [1, 9, 4, 7, 2],
        distance,
        known: always,
        strength: 100,
        after: 5,
        random: Random(2),
      );
      expect(ordered, hasLength(5));
      expect(ordered, isNot(contains(5)));
      // The nearest to 5 first, then the nearest to each one after.
      expect(ordered, [4, 2, 1, 7, 9]);
    });

    test("ignores key and tempo at no strength", () {
      final items = [for (var i = 0; i < 40; i++) i];
      // A walk by nearest neighbour hardly ever jumps far; a plain shuffle often does.
      var far = 0;
      for (var seed = 0; seed < 5; seed++) {
        final ordered = DjTransitionService.harmonicOrder(
          items,
          distance,
          known: always,
          strength: 0,
          random: Random(seed),
        );
        expect(ordered.toSet(), items.toSet());
        far += [
          for (var i = 1; i < ordered.length; i++) distance(ordered[i - 1], ordered[i]),
        ].where((d) => d > 5).length;
      }
      expect(far, greaterThan(5 * 20));
    });

    test("a bigger pool has more to choose from at the same strength", () {
      int worstRank(int size) {
        final items = [for (var i = 0; i < size; i++) i];
        var worst = 0;
        for (var seed = 0; seed < 5; seed++) {
          final ordered = DjTransitionService.harmonicOrder(
            items,
            distance,
            known: always,
            strength: 50,
            random: Random(seed),
          );
          final remaining = {...items}..remove(ordered.first);
          for (var i = 1; i < ordered.length; i++) {
            final step = distance(ordered[i - 1], ordered[i]);
            worst = max(worst, remaining.where((item) => distance(ordered[i - 1], item) < step).length);
            remaining.remove(ordered[i]);
          }
        }
        return worst;
      }

      // About the square root of the pool at 50%: one of the best 3 of 9 songs, of the best 14 of 200.
      expect(worstRank(9), lessThan(3));
      expect(worstRank(200), greaterThanOrEqualTo(3));
      expect(worstRank(200), lessThan(14));
    });

    test("stays quick for a big pool at any strength", () {
      final items = [for (var i = 0; i < 2000; i++) i * 7919 % 2000];
      for (final strength in [0, 1, 25, 50, 100]) {
        final clock = Stopwatch()..start();
        final ordered = DjTransitionService.harmonicOrder(
          items,
          distance,
          known: always,
          strength: strength,
          random: Random(strength),
        );
        expect(ordered.toSet(), items.toSet(), reason: "$strength%");
        expect(clock.elapsed, lessThan(const Duration(seconds: 2)), reason: "$strength%");
      }
    });

    test("keeps everything when nothing is analysed", () {
      final ordered = DjTransitionService.harmonicOrder(
        [1, 2, 3],
        distance,
        known: (_) => false,
        strength: 50,
        random: Random(1),
      );
      expect(ordered.toSet(), {1, 2, 3});
    });
  });

  group("ordering a long mix off the main thread", () {
    // Songs with a key and tempo each, from a seed.
    Map<String, TrackAnalysis> songs(int count, {int seed = 3}) {
      final dice = Random(seed);
      return {
        for (var i = 0; i < count; i++)
          "song $i": TrackAnalysis(
            bpm: 70 + dice.nextDouble() * 110,
            camelot: "${1 + dice.nextInt(12)}${dice.nextBool() ? "A" : "B"}",
          ),
      };
    }

    test("gives the same order as working it out here, for the same seed", () async {
      final analysis = songs(60);
      analysis.remove("song 7");
      final items = [for (var i = 0; i < 60; i++) "song $i"];
      final cost = DjTransitionService.cachedTransitionCost();
      final here = DjTransitionService.harmonicOrder(
        items,
        (a, b) => cost(analysis[a], analysis[b]),
        known: analysis.containsKey,
        strength: 75,
        random: Random(9),
      );
      expect(
        await DjTransitionService.harmonicOrderAway(items, (item) => analysis[item], strength: 75, random: Random(9)),
        here,
      );
    });

    test("a long mix ordered away comes out as it would here", () async {
      final count = DjTransitionService.awayFrom + 100;
      final analysis = songs(count);
      final items = analysis.keys.toList();
      final cost = DjTransitionService.cachedTransitionCost();
      // At full strength, carrying on from a song, nothing is left to chance.
      final here = DjTransitionService.harmonicOrder(
        items.skip(1).toList(),
        (a, b) => cost(analysis[a], analysis[b]),
        known: analysis.containsKey,
        strength: 100,
        after: items.first,
      );
      final away = await DjTransitionService.harmonicOrderAway(
        items.skip(1).toList(),
        (item) => analysis[item],
        strength: 100,
        after: items.first,
      );
      expect(away, here);
      expect(
        await DjTransitionService.orderByCostAway(items, (item) => analysis[item]),
        DjTransitionService.orderByCost(items, (a, b) => cost(analysis[a], analysis[b])),
      );
    });

    test("the app carries on while a long mix is ordered", () async {
      final analysis = songs(3000);
      var carriedOn = false;
      Timer.run(() => carriedOn = true);
      final ordered = await DjTransitionService.harmonicOrderAway(
        analysis.keys.toList(),
        (item) => analysis[item],
        strength: 100,
      );
      expect(carriedOn, isTrue, reason: "the main thread was free while it was ordered");
      expect(ordered.toSet(), analysis.keys.toSet());
    });
  });

  group("smoothing within groups", () {
    double distance(int a, int b) => (a - b).abs().toDouble();

    test("reorders only within each run", () {
      expect(DjTransitionService.smoothWithinGroups([0, 10, 1, 11, 30, 20, 31, 21, 40], distance), [
        0,
        1,
        10,
        11,
        20,
        21,
        30,
        31,
        40,
      ]);
    });

    test("leaves the order alone when nothing is better", () {
      expect(DjTransitionService.smoothWithinGroups([5, 3, 9, 1, 7], (a, b) => 1), [5, 3, 9, 1, 7]);
      expect(DjTransitionService.smoothWithinGroups(<int>[], distance), isEmpty);
    });

    test("takes one of a run's better orders below full strength, and any at none", () {
      final run = [40, 0, 30, 10];
      double total(List<int> order) =>
          [for (var i = 1; i < order.length; i++) distance(order[i - 1], order[i])].fold(0.0, (a, b) => a + b);
      final best = total(DjTransitionService.smoothWithinGroups(run, distance));
      final seen = <String>{}, loose = <String>{};
      for (var seed = 0; seed < 60; seed++) {
        final half = DjTransitionService.smoothWithinGroups(run, distance, strength: 50, random: Random(seed));
        final none = DjTransitionService.smoothWithinGroups(run, distance, strength: 0, random: Random(seed));
        expect(half.toSet(), run.toSet());
        // 24 orders to the power of 0.5: one of the best 5, so never far worse than the best.
        expect(total(half), lessThanOrEqualTo(best + 20));
        seen.add(half.join(","));
        loose.add(none.join(","));
        // Still only within the run.
        expect(
          DjTransitionService.smoothWithinGroups([...run, 99], distance, strength: 0, random: Random(seed)).last,
          99,
        );
      }
      expect(seen.length, greaterThan(1));
      expect(loose.length, greaterThan(seen.length));
    });
  });
}
