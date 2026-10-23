import 'package:just_audio/just_audio.dart';

/// Reload the next entry explicitly: Android ignores seeks after a source error,
/// and a bare load() starts the playlist at index zero again.
Future<void> recoverPlaybackAfterError({
  required AudioPlayer player,
  required bool Function() ownsQueue,
  required Future<void> Function(int index, Future<void> Function() reload) duringReload,
  ShuffleOrder? shuffleOrder,
  int maxSkips = 3,
  void Function(Object error)? onFailure,
}) async {
  final sources = List<AudioSource>.of(player.audioSources);
  final indices = player.shuffleModeEnabled
      ? List<int>.of(player.shuffleIndices)
      : List<int>.generate(sources.length, (index) => index);
  final failedIndex = player.currentIndex;
  var next = player.nextIndex;
  final visited = <int>{?failedIndex};
  final order = _RetainedShuffleOrder(shuffleOrder ?? DefaultShuffleOrder(), List<int>.of(player.shuffleIndices));

  for (var attempt = 0; attempt < maxSkips && next != null && visited.add(next); attempt++) {
    if (!ownsQueue()) return;
    final index = next;
    final position = indices.indexOf(index);
    if (position < 0) break;
    try {
      await duringReload(position, () async {
        if (!ownsQueue()) return;
        // setAudioSources retains play/pause intent, including a pause made
        // while loading. Copying sources also avoids aliasing the live playlist.
        order.retainNextShuffle();
        await player.setAudioSources(sources, initialIndex: index, initialPosition: Duration.zero, shuffleOrder: order);
      });
      return;
    } on PlayerInterruptedException {
      return; // A newer selection owns playback now.
    } on PlayerException catch (error) {
      if (!ownsQueue()) return;
      onFailure?.call(error);
      next = position + 1 < indices.length
          ? indices[position + 1]
          : player.loopMode == LoopMode.all && indices.isNotEmpty
          ? indices.first
          : null;
    }
  }
  // Keep the queue available for retry, but do not leave the UI "playing" when
  // the connection or several consecutive sources have failed.
  if (ownsQueue()) await player.pause();
}

/// Retain the exact queue order for recovery, then delegate later shuffle/edit
/// operations to the queue's usual policy (including artist spacing and Next Up).
class _RetainedShuffleOrder extends ShuffleOrder {
  _RetainedShuffleOrder(this.delegate, this.savedIndices);
  final ShuffleOrder delegate;
  final List<int> savedIndices;
  bool _retain = true;
  void retainNextShuffle() => _retain = true;
  @override
  List<int> get indices => delegate.indices;
  @override
  void shuffle({int? initialIndex}) {
    if (!_retain) {
      delegate.shuffle(initialIndex: initialIndex);
      return;
    }
    if (savedIndices.length != indices.length) throw StateError('Playback recovery queue changed');
    indices
      ..clear()
      ..addAll(savedIndices);
    _retain = false;
  }

  @override
  void insert(int index, int count) => delegate.insert(index, count);
  @override
  void removeRange(int start, int end) => delegate.removeRange(start, end);
  @override
  void clear() => delegate.clear();
}
