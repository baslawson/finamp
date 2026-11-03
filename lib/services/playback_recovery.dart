import 'package:audio_session/audio_session.dart';
import 'package:finamp/services/network_status.dart';
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

/// Whether [error] is the phone's audio decoder giving up. It happens to tracks that play fine, as Android moves the
/// sound to another output (a Bluetooth speaker disconnecting), so the track is worth loading again; a damaged file
/// fails the same way, but then fails again.
bool isDecoderFailure(Object error) =>
    error is PlayerException && (error.message?.contains('ERROR_CODE_DECODING_FAILED') ?? false);

/// A track gets one more try after a decoder failure; failing again within [window], it's taken to be damaged.
class DecoderRetries {
  DecoderRetries({this.window = const Duration(minutes: 1)});
  final Duration window;
  String? _item;
  DateTime? _at;

  bool allow(String item, DateTime now) {
    if (item == _item && _at != null && now.difference(_at!) < window) return false;
    _item = item;
    _at = now;
    return true;
  }
}

/// A play press with nothing loaded yet, as when a Bluetooth button starts the app in the background: Android may keep
/// the network from the app for a while, so loading the saved queue keeps trying until the listener pauses.
class SavedQueueResume {
  Future<bool>? _running;
  int _pauses = 0;
  int _pausesAtPress = 0;

  /// The listener paused or stopped: they no longer want the press still waiting to start anything.
  void paused() => _pauses++;

  /// Treats losing the sound as a pause, so a press still waiting can't start the music on the phone's speaker. With
  /// ducking on, the player handles these by itself and they never reach [paused]. Android only reports [becomingNoisy]
  /// while the app holds the audio focus, which it may not yet while waiting, hence the removed devices as well.
  void watch({
    required Stream<AudioInterruptionEvent> interruptions,
    required Stream<void> becomingNoisy,
    required Stream<AudioDevicesChangedEvent> devicesChanged,
  }) {
    interruptions.listen((event) {
      if (event.begin && event.type != AudioInterruptionType.duck) paused();
    });
    becomingNoisy.listen((_) => paused());
    devicesChanged.listen((event) {
      if (event.devicesRemoved.any((device) => device.isOutput)) paused();
    });
  }

  /// Loads the queue with [load], and answers whether there's anything to play. [load] is told how to check that the
  /// press still stands. Presses during a load share it, and [onNoConnection] is called once if it never got through.
  Future<bool> resume(
    Future<bool> Function(bool Function() stillWanted) load, {
    Duration patience = const Duration(minutes: 1),
    Duration firstPause = const Duration(seconds: 2),
    void Function()? onNoConnection,
  }) {
    _pausesAtPress = _pauses;
    return _running ??= _load(load, patience, firstPause, onNoConnection).whenComplete(() => _running = null);
  }

  Future<bool> _load(
    Future<bool> Function(bool Function() stillWanted) load,
    Duration patience,
    Duration firstPause,
    void Function()? onNoConnection,
  ) async {
    try {
      bool stillWanted() => _pauses == _pausesAtPress;
      return await NetworkStatus.retryWhileOffline(
            () => load(stillWanted),
            patience: patience,
            firstPause: firstPause,
            stop: () => !stillWanted(),
          ) ??
          false;
    } catch (error) {
      if (NetworkStatus.isNetworkFailure(error)) onNoConnection?.call();
      rethrow;
    }
  }
}

/// Where the playing track got to, kept by the track itself, as its place in the queue can change while paused.
class LastPlayed {
  String? _item;
  Duration _position = Duration.zero;

  void note(String? item, Duration position) {
    _item = item;
    _position = position;
  }

  /// Where [item] got to; the start if another track played since.
  Duration of(String item) => item == _item ? _position : Duration.zero;
}

/// Load the failed entry again where it was, keeping the queue and the play/pause state. Returns false when it
/// failed again, so the caller can go on to the next one; true also when a newer queue took over.
Future<bool> reloadAfterError({
  required AudioPlayer player,
  required bool Function() ownsQueue,
  required Future<void> Function(int index, Future<void> Function() reload) duringReload,
  required Duration position,
  ShuffleOrder? shuffleOrder,
}) async {
  final index = player.currentIndex;
  if (index == null) return false;
  final sources = List<AudioSource>.of(player.audioSources);
  final indices = player.shuffleModeEnabled
      ? List<int>.of(player.shuffleIndices)
      : List<int>.generate(sources.length, (index) => index);
  final queuePosition = indices.indexOf(index);
  if (queuePosition < 0) return false;
  final order = _RetainedShuffleOrder(shuffleOrder ?? DefaultShuffleOrder(), List<int>.of(player.shuffleIndices));
  try {
    await duringReload(queuePosition, () async {
      if (!ownsQueue()) return;
      await player.setAudioSources(sources, initialIndex: index, initialPosition: position, shuffleOrder: order);
    });
    return true;
  } on PlayerInterruptedException {
    return true; // A newer selection owns playback now.
  } catch (_) {
    // Also the queue changing as it reloads. A queue that changed meanwhile isn't this failure's to skip on; otherwise
    // the caller skips, which also leaves playback paused rather than stuck if that fails too.
    return !ownsQueue();
  }
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
