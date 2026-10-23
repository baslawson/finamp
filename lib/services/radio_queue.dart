import 'dart:async';
import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/song_duplicates.dart';

typedef RadioSelection = ({List<BaseItemDto> selected, List<BaseItemDto> deferred});

/// Candidate counts are only useful after duplicate filtering and artist spacing.
class RadioQueue {
  /// The picked song leads a new mix, unless it is already playing and retained.
  static RadioSelection initial(
    BaseItemDto source,
    Iterable<BaseItemDto> candidates, {
    required RadioMode mode,
    required int needed,
    BaseItemDto? current,
    BaseItemDto? startingTrack,
  }) {
    final first = startingTrack ?? (BaseItemDtoType.fromItem(source) == BaseItemDtoType.track ? source : null);
    final alreadyPlaying =
        first != null && current != null && withoutDuplicateSongs([first], already: [current]).isEmpty;
    final pinned = first != null && !alreadyPlaying;
    final remainder = select(
      candidates,
      needed: max(0, needed - (pinned ? 1 : 0)),
      allowArtistRepeats: allowsArtistRepeats(
        mode,
        QueueItemSource.fromBaseItem(source, type: QueueItemSourceType.radio),
      ),
      blocked: [?first, ?current],
      previous: first ?? current,
      preferPrefix: true,
    );
    return (selected: [if (pinned) first, ...remainder.selected], deferred: remainder.deferred);
  }

  static bool allowsArtistRepeats(RadioMode mode, QueueItemSource source) =>
      mode == RadioMode.albumMix ||
      source.allowArtistRepeats ||
      ((mode == RadioMode.random || mode == RadioMode.reshuffle) &&
          (ArtistSpacing.allowsRepeats(source) || const {'MusicArtist', 'MusicAlbum'}.contains(source.item?.type)));

  static List<BaseItemDto> recent(FinampQueueInfo queue, Duration window) {
    var duration = Duration.zero;
    final result = <BaseItemDto>[];
    for (final item in queue.previousTracks.reversed) {
      if (duration >= window) break;
      result.add(item.baseItem);
      duration += item.item.duration ?? const Duration(minutes: 3);
    }
    return result;
  }

  static RadioSelection select(
    Iterable<BaseItemDto> candidates, {
    required int needed,
    required bool allowArtistRepeats,
    Iterable<BaseItemDto> blocked = const [],
    BaseItemDto? previous,
    bool deferBlocked = false,
    bool preferPrefix = false,
  }) {
    final pool = withoutDuplicateSongs(candidates);
    final eligible = withoutDuplicateSongs(pool, already: blocked);
    List<BaseItemDto> order(List<BaseItemDto> items) => allowArtistRepeats
        ? items
        : ArtistSpacing.order(
            items,
            ArtistSpacing.artistKey,
            previousKey: previous == null ? null : ArtistSpacing.artistKey(previous),
            keepFirst: false,
            dropUnavoidable: true,
          );
    final prefix = preferPrefix ? order(eligible.take(max(0, needed)).toList()) : <BaseItemDto>[];
    final ordered = preferPrefix && prefix.length >= needed ? prefix : order(eligible);
    final selected = ordered.take(max(0, needed)).toList();
    final used = selected.map((item) => item.id).toSet();
    return (
      selected: selected,
      deferred: (deferBlocked ? pool : eligible).where((item) => !used.contains(item.id)).toList(),
    );
  }

  /// Keep partial progress when a later request fails or a related-song branch runs out.
  static Future<List<BaseItemDto>> continuous({
    required BaseItemDto seed,
    required int needed,
    required Future<List<BaseItemDto>> Function(BaseItemDto reference, List<BaseItemDto> selected) next,
    bool Function()? isCurrent,
    bool allowArtistRepeats = false,
  }) async {
    final selected = <BaseItemDto>[];
    while (selected.length < needed && (isCurrent?.call() ?? true)) {
      final List<BaseItemDto> candidates;
      try {
        candidates = await next(selected.lastOrNull ?? seed, selected);
      } catch (_) {
        break;
      }
      if (isCurrent?.call() == false) break;
      final fresh = select(
        candidates,
        needed: 1,
        allowArtistRepeats: allowArtistRepeats,
        blocked: [seed, ...selected],
        previous: selected.lastOrNull ?? seed,
      ).selected;
      if (fresh.isEmpty) break;
      selected.add(fresh.first);
    }
    return selected;
  }

  /// Expand the search based on playable candidates, not the unfiltered response size.
  static Future<List<BaseItemDto>> search({
    required int needed,
    required Future<List<BaseItemDto>> Function(int attempt, int limit) fetch,
    required bool allowArtistRepeats,
    Iterable<BaseItemDto> blocked = const [],
    BaseItemDto? previous,
    int attempts = 4,
    bool Function()? isCurrent,
  }) async {
    var pool = <BaseItemDto>[];
    for (var attempt = 0; attempt < attempts && (isCurrent?.call() ?? true); attempt++) {
      try {
        final batch = await fetch(attempt, min(500, max(40, needed * 4) * (attempt + 1)));
        if (isCurrent?.call() == false) return [];
        pool = withoutDuplicateSongs([...pool, ...batch], already: blocked);
      } catch (_) {
        // Another seed or the genre fallback can still provide candidates.
      }
      final selection = select(
        pool,
        needed: needed,
        allowArtistRepeats: allowArtistRepeats,
        previous: previous,
        preferPrefix: true,
      );
      if (selection.selected.length >= needed) return [...selection.selected, ...selection.deferred];
    }
    final selection = select(
      pool,
      needed: needed,
      allowArtistRepeats: allowArtistRepeats,
      previous: previous,
      preferPrefix: true,
    );
    return [...selection.selected, ...selection.deferred];
  }
}

/// One refill at a time, including across cache invalidations. Failed searches back off.
class RadioRefillGate {
  RadioRefillGate({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  Future<void>? _active;
  DateTime? _retryAt;
  int _failures = 0;
  int _generation = 0;

  void reset() {
    _generation++;
    _failures = 0;
    _retryAt = null;
  }

  Future<void> run(Future<bool> Function() refill) {
    if (_active != null) return _active!;
    if (_retryAt != null && _now().isBefore(_retryAt!)) return Future.value();
    final generation = _generation;
    final operation = Future<bool>.sync(refill).then((filled) {
      if (generation != _generation) return;
      if (filled) {
        _failures = 0;
        _retryAt = null;
      } else {
        _retryAt = _now().add(Duration(seconds: min(60, 2 << min(_failures++, 5))));
      }
    });
    _active = operation.whenComplete(() {
      _active = null;
    });
    return _active!;
  }
}
