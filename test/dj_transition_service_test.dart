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

    test("always takes the best next item at no randomness", () {
      final items = [for (var i = 0; i < 20; i++) i * 7 % 20];
      final ordered = DjTransitionService.harmonicOrder(
        items,
        distance,
        known: always,
        randomness: 0,
        random: Random(3),
      );
      expect(ordered.toSet(), items.toSet());
      expect(ordered, hasLength(items.length));
      // From a random start, walking to the nearest number means at most one jump back to the other end.
      final jumps = [for (var i = 1; i < ordered.length; i++) distance(ordered[i - 1], ordered[i])].where((d) => d > 1);
      expect(jumps.length, lessThanOrEqualTo(1));
    });

    test("picks among the best few at full randomness, the same way for the same seed", () {
      final items = [for (var i = 0; i < 40; i++) i];
      List<int> order(int seed) =>
          DjTransitionService.harmonicOrder(items, distance, known: always, randomness: 100, random: Random(seed));
      final ordered = order(7);
      expect(order(7), ordered);
      expect(ordered.toSet(), items.toSet());
      final remaining = {...items}..remove(ordered.first);
      for (var i = 1; i < ordered.length; i++) {
        final better = remaining.where((item) => distance(ordered[i - 1], item) < distance(ordered[i - 1], ordered[i]));
        expect(better.length, lessThan(8));
        remaining.remove(ordered[i]);
      }
    });

    test("spreads songs without analysis through the mix", () {
      final items = [for (var i = 0; i < 12; i++) i, -1, -2];
      final ordered = DjTransitionService.harmonicOrder(
        items,
        distance,
        known: (item) => item >= 0,
        randomness: 0,
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
        randomness: 0,
        after: 5,
        random: Random(2),
      );
      expect(ordered, hasLength(5));
      expect(ordered, isNot(contains(5)));
      // The nearest to 5 first, then the nearest to each one after.
      expect(ordered, [4, 2, 1, 7, 9]);
    });

    test("keeps everything when nothing is analysed", () {
      final ordered = DjTransitionService.harmonicOrder(
        [1, 2, 3],
        distance,
        known: (_) => false,
        randomness: 50,
        random: Random(1),
      );
      expect(ordered.toSet(), {1, 2, 3});
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
  });
}
