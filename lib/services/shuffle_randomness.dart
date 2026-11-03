import 'dart:math';

import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/models/jellyfin_models.dart';

/// Blends the incoming ranking with a random ranking, without changing the pool.
class ShuffleRandomness {
  ShuffleRandomness._();

  /// A stable baseline for a randomly sampled library pool. Sampling still
  /// varies which songs are available; the slider controls their play order.
  static List<BaseItemDto> libraryOrder(List<BaseItemDto> tracks) => List.of(tracks)
    ..sort((a, b) {
      final name = (a.nameForSorting ?? a.name ?? '').compareTo(b.nameForSorting ?? b.name ?? '');
      return name == 0 ? a.id.raw.compareTo(b.id.raw) : name;
    });

  static List<T> order<T>(List<T> items, int percentage, {Random? random}) {
    final amount = percentage.clamp(0, 100) / 100;
    if (amount == 0 || items.length < 2) return List.of(items);
    final dice = random ?? Random();
    final ranked =
        [
          for (final (index, item) in items.indexed)
            (item: item, index: index, score: (1 - amount) * index / (items.length - 1) + amount * dice.nextDouble()),
        ]..sort((a, b) {
          final score = a.score.compareTo(b.score);
          return score == 0 ? a.index.compareTo(b.index) : score;
        });
    return [for (final entry in ranked) entry.item];
  }

  /// Media preparation can omit failed tracks after an order was chosen.
  /// Translate that order into the surviving sequence, keeping the current
  /// song when possible, or advancing to the next surviving song otherwise.
  static ({List<int> indices, int initialIndex, int nextUpLength}) retainPlayableIndices(
    List<int> order,
    List<int> retained, {
    required int initialIndex,
    int nextUpLength = 0,
  }) {
    if (retained.isEmpty) return (indices: <int>[], initialIndex: 0, nextUpLength: 0);
    final positions = {for (final (index, original) in retained.indexed) original: index};
    final currentPosition = order.indexOf(initialIndex);
    final selected =
        order.skip(max(0, currentPosition)).where(positions.containsKey).firstOrNull ??
        order.reversed.firstWhere(positions.containsKey);
    return (
      indices: [for (final index in order) ?positions[index]],
      initialIndex: positions[selected]!,
      nextUpLength: retained
          .where((index) => index > max(selected, initialIndex) && index <= initialIndex + nextUpLength)
          .length,
    );
  }

  /// Always starts from the original sequence, so repeated low-percentage
  /// reshuffles do not gradually turn into a fully random shuffle.
  static List<int> indices<T>(
    List<T> sequence,
    Object? Function(T) artistKey,
    int percentage, {
    Random? random,
    int? initialIndex,
    int nextUpLength = 0,
    bool allowArtistRepeats = false,
  }) {
    final pinned = initialIndex == null ? <int>[] : List.generate(1 + nextUpLength, (i) => initialIndex + i);
    final pinnedSet = pinned.toSet();
    final rest = order(
      [
        for (var i = 0; i < sequence.length; i++)
          if (!pinnedSet.contains(i)) i,
      ],
      percentage,
      random: random,
    );
    return [
      ...pinned,
      ...allowArtistRepeats
          ? rest
          : ArtistSpacing.order(
              rest,
              (index) => artistKey(sequence[index]),
              previousKey: pinned.isEmpty ? null : artistKey(sequence[pinned.last]),
              keepFirst: false,
            ),
    ];
  }
}
