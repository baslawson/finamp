import 'dart:collection';
import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:finamp/services/listening_preferences.dart';

/// Artist spacing shared by generated mixes and the player's shuffle order.
class ArtistSpacing {
  ArtistSpacing._();

  static String? artistKey(BaseItemDto track) {
    for (final name in [
      ...?track.artists,
      for (final artist in track.artistItems ?? <NameIdPair>[]) artist.name,
      track.albumArtist,
    ]) {
      if (keyOfName(name) case final key?) return key;
    }
    return null;
  }

  /// An artist's name as a key, the same however it's written ("BLINK 182 feat. Someone" is "blink182"), or null for
  /// none or a placeholder ("Unknown artist", "Various artists").
  static String? keyOfName(String? name) {
    final key = (name ?? "")
        .toLowerCase()
        .replaceAll(RegExp(r'\s+(?:feat\.?|ft\.?|featuring)\s+.*$'), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    return key.isEmpty || const {'unknown', 'unknownartist', 'variousartists'}.contains(key) ? null : key;
  }

  static bool allowsRepeats(QueueItemSource source) =>
      source.allowArtistRepeats ||
      const {
        QueueItemSourceType.artist,
        QueueItemSourceType.album,
        QueueItemSourceType.nextUpArtist,
        QueueItemSourceType.nextUpAlbum,
      }.contains(source.type);

  static bool appliesTo(QueueItemSource source, {bool shuffled = false}) =>
      !allowsRepeats(source) && (shuffled || isGeneratedSource(source));

  /// A bare-majority artist has to go first for a complete alternating shuffle.
  /// Other starting tracks remain random, and the original list stays intact.
  static int startingIndex<T>(List<T> items, Object? Function(T) key, Random random) {
    final counts = <Object, List<int>>{};
    for (final (index, item) in items.indexed) {
      final artist = key(item);
      if (artist != null) (counts[artist] ??= []).add(index);
    }
    for (final positions in counts.values) {
      if (positions.length * 2 > items.length) return positions[random.nextInt(positions.length)];
    }
    return random.nextInt(items.length);
  }

  /// Keeps the incoming random/ranked order where possible. A dominant artist
  /// is used before its separators run out, rather than collecting at the end.
  /// Unknown artists never clash. Explicitly pinned first tracks can stay first.
  /// Fresh generated lists omit an unavoidable repeated tail; existing queues
  /// keep every track when [dropUnavoidable] is false.
  static List<T> order<T>(
    List<T> items,
    Object? Function(T) key, {
    Object? previousKey,
    bool keepFirst = true,
    bool dropUnavoidable = false,
  }) {
    final groups = <Object, _ArtistBucket<T>>{};
    final buckets = <_ArtistBucket<T>>[];
    for (final (index, item) in items.indexed) {
      final artist = key(item);
      final bucket = artist == null
          ? _ArtistBucket<T>(null)
          : groups.putIfAbsent(artist, () => _ArtistBucket<T>(artist));
      if (bucket.items.isEmpty) buckets.add(bucket);
      bucket.items.add((index: index, item: item));
    }
    final byPosition = SplayTreeSet<_ArtistBucket<T>>((a, b) => a.items.first.index.compareTo(b.items.first.index))
      ..addAll(buckets);
    final byCount = SplayTreeSet<_ArtistBucket<T>>((a, b) {
      final count = b.items.length.compareTo(a.items.length);
      return count != 0 ? count : a.items.first.index.compareTo(b.items.first.index);
    })..addAll(buckets);
    final result = <T>[];
    var remaining = items.length;
    while (byPosition.isNotEmpty) {
      final dominant = byCount.first;
      final _ArtistBucket<T> chosen;
      if (keepFirst && result.isEmpty) {
        chosen = byPosition.first;
      } else if (dominant.key != previousKey && dominant.items.length * 2 > remaining) {
        chosen = dominant;
      } else {
        final eligible = byPosition.where((bucket) => bucket.key == null || bucket.key != previousKey);
        if (eligible.isEmpty) {
          if (dropUnavoidable) break;
          chosen = byPosition.first;
        } else {
          chosen = eligible.first;
        }
      }
      byPosition.remove(chosen);
      byCount.remove(chosen);
      result.add(chosen.items.removeFirst().item);
      previousKey = chosen.key;
      remaining--;
      if (chosen.items.isNotEmpty) {
        byPosition.add(chosen);
        byCount.add(chosen);
      }
    }
    return result;
  }

  static List<BaseItemDto> generated(
    List<BaseItemDto> tracks,
    QueueItemSource source, {
    BaseItemDto? previous,
    bool keepFirst = false,
  }) {
    final eligible = !isGeneratedSource(source)
        ? tracks
        : [
            for (final (index, track) in tracks.indexed)
              if ((keepFirst && index == 0) || ListeningPreferences.permits(track)) track,
          ];
    return appliesTo(source)
        ? order(
            eligible,
            artistKey,
            previousKey: previous == null ? null : artistKey(previous),
            keepFirst: keepFirst,
            dropUnavoidable: true,
          )
        : List.of(eligible);
  }

  static ({List<BaseItemDto> items, int? startingIndex}) prepareStart(
    List<BaseItemDto> items,
    QueueItemSource source, {
    int? startingIndex,
  }) {
    if (!appliesTo(source) ||
        items.isEmpty ||
        (startingIndex != null && (startingIndex < 0 || startingIndex >= items.length))) {
      return (items: items, startingIndex: startingIndex);
    }
    final start = startingIndex ?? 0;
    return (
      items: [
        ...items.take(start),
        ...order(items.sublist(start), artistKey, keepFirst: startingIndex != null, dropUnavoidable: true),
      ],
      // A generated shuffle must start with a feasible first artist too.
      startingIndex: start,
    );
  }

  /// Indices always address the player's original sequence, never its effective
  /// (already shuffled) sequence. Current and explicit Next Up entries stay put.
  static List<int> shuffleIndices<T>(
    List<int> shuffled,
    List<T> sequence,
    Object? Function(T) key, {
    required int initialIndex,
    int nextUpLength = 0,
    bool allowArtistRepeats = false,
  }) {
    final pinned = List.generate(1 + nextUpLength, (i) => initialIndex + i);
    final pinnedSet = pinned.toSet();
    final rest = shuffled.where((index) => !pinnedSet.contains(index)).toList();
    return [
      ...pinned,
      ...allowArtistRepeats
          ? rest
          : order(rest, (index) => key(sequence[index]), previousKey: key(sequence[pinned.last]), keepFirst: false),
    ];
  }
}

class _ArtistBucket<T> {
  _ArtistBucket(this.key);

  final Object? key;
  final items = ListQueue<({int index, T item})>();
}
