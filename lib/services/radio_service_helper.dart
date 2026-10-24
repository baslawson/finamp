import 'dart:async';
import 'dart:math';
import 'package:finamp/services/shuffle_randomness.dart';

import 'package:collection/collection.dart';
import 'package:finamp/components/PlayerScreen/artist_chip.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_content_provider.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/item_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/services/radio_clock_settings.dart';
import 'package:finamp/services/genre_mix.dart';
import 'package:finamp/services/radio_queue.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import '../models/music_slices.dart';
import 'audio_service_helper.dart';

final _radioLogger = Logger("Radio");
final _radioRandom = Random();

/// Returns the amount of tracks that are needed to fill up the radio queue
int calculateRadioTracksNeeded() {
  // fetch enough (10 or more) tracks of at least ~2 minutes to fill the entire precache buffer
  final minUpcomingRadioTracks = max(10, FinampSettingsHelper.finampSettings.bufferDuration.inMinutes ~/ 2);
  final queueService = GetIt.instance<QueueService>();
  final currentQueue = queueService.getQueue();
  if (FinampSettingsHelper.finampSettings.radioEnabled) {
    if (![SavedQueueState.saving, SavedQueueState.pendingSave].contains(currentQueue.saveState)) {
      return 0;
    }
    final queueSize = currentQueue.nextUp.length + currentQueue.queue.length;
    return max(0, minUpcomingRadioTracks - queueSize);
  }
  return 0;
}

final _radioCacheStateStream = BehaviorSubject<RadioCacheState?>.seeded(null);
final _radioCacheStateStreamProvider = StreamProvider<RadioCacheState?>((ref) {
  if (_radioCacheStateStream.valueOrNull == null) {
    invalidateRadioCache();
  }
  GetIt.instance<MusicPlayerBackgroundTask>().refreshPlaybackStateAndMediaNotification();
  return _radioCacheStateStream;
});
final radioStateProvider = Provider<RadioCacheState?>((ref) {
  return ref.watch(_radioCacheStateStreamProvider).value;
});

final _radioRefillGate = RadioRefillGate();
int _radioGeneration = 0;

List<BaseItemDto> _radioBlocked(FinampQueueInfo queue, RadioMode mode, {bool recent = true}) => [
  ?queue.currentTrack?.baseItem,
  ...queue.nextUp.map((item) => item.baseItem),
  ...queue.queue.map((item) => item.baseItem),
  if (recent && (mode == RadioMode.similar || mode == RadioMode.continuous))
    ...RadioQueue.recent(queue, const Duration(minutes: 30)),
];

BaseItemDto? _radioTail(FinampQueueInfo queue) =>
    (queue.queue.lastOrNull ?? queue.nextUp.lastOrNull ?? queue.currentTrack)?.baseItem;

Future<void> maybeAddRadioTracks() async {
  if (_radioCacheStateStream.valueOrNull == null || !_radioCacheStateStream.value!.isStillValid()) {
    invalidateRadioCache(resetRetry: false);
  }
  if (calculateRadioTracksNeeded() <= 0) return;
  if (_radioCacheStateStream.value!.loading) return;
  await _radioRefillGate.run(() async {
    final queueService = GetIt.instance<QueueService>();
    final queueId = queueService.getQueue().id;
    final generation = _radioGeneration;
    var state = _radioCacheStateStream.value!;
    final preferences = await RadioPreferencesStore.load();
    bool current() =>
        generation == _radioGeneration &&
        queueService.getQueue().id == queueId &&
        FinampSettingsHelper.finampSettings.radioEnabled &&
        FinampSettingsHelper.finampSettings.radioMode == state.radioMode &&
        (state.queueing || activeRadioSeed(queueService.getQueue(), state.radioMode)?.id == state.seedItem?.id);
    void publish(RadioCacheState next) {
      state = next;
      _radioCacheStateStream.add(state);
    }

    try {
      for (var round = 0; round < 3 && current(); round++) {
        final needed = calculateRadioTracksNeeded();
        if (needed <= 0) return true;
        final queue = queueService.getQueue();
        final allowRepeats = RadioQueue.allowsArtistRepeats(state.radioMode, queue.source);
        publish(state.copyWith(generating: true, queueing: false, failed: false));
        // Already tuned (skips, key and tempo, time of day) when it was generated.
        var pool = await preferences.rank(state.tracks, needed, album: state.radioMode == RadioMode.albumMix);
        if (!current()) return true;
        RadioSelection select() => RadioQueue.select(
          pool,
          needed: state.radioMode == RadioMode.albumMix ? pool.length : needed,
          allowArtistRepeats: allowRepeats,
          blocked: _radioBlocked(queueService.getQueue(), state.radioMode),
          previous: _radioTail(queueService.getQueue()),
          deferBlocked: state.radioMode == RadioMode.reshuffle,
          preferPrefix: true,
        );
        var selection = select();
        // Finish the current reshuffle cycle first. At an empty queue, a new cycle
        // can supply an artist separator for an otherwise unplayable last song.
        final pendingCycle =
            state.radioMode == RadioMode.reshuffle &&
            pool.isNotEmpty &&
            (selection.selected.isNotEmpty || queue.upcomingTrackCount > 0);
        if (selection.selected.length < needed && !pendingCycle) {
          final generated = await generateRadioTracks(needed, cachedTracks: pool, isCurrent: current);
          if (!current()) return true;
          pool = await preferences.rank(
            withoutDuplicateSongs([...pool, ...generated]),
            needed,
            album: state.radioMode == RadioMode.albumMix,
          );
          if (!current()) return true;
          selection = select();
        }
        publish(state.copyWith(tracks: pool));
        if (selection.selected.isEmpty) break;
        final expectedTail = _radioTail(queueService.getQueue())?.id;
        publish(state.copyWith(generating: false, queueing: true));
        final added = await queueService.addRadioTracks(
          BasePlayableSlice(
            items: selection.selected,
            startingIndex: 0,
            source: QueueItemSource.rawId(
              type: QueueItemSourceType.radio,
              name: QueueItemSourceName(
                type: QueueItemSourceNameType.radio,
                localizationParameter: queue.source.djStationId != null
                    ? queue.source.name.localizationParameter
                    : queue.source.item?.name ?? queue.source.name.getLocalized(GlobalSnackbar.requireL10n),
              ),
              id: queue.source.item?.id.raw ?? queue.source.id,
              item: queue.source.item,
              library: queue.source.library,
              allowArtistRepeats: allowRepeats,
              djStationId: queue.source.djStationId,
              genreMix: GenreMix.radioGenreMix(preferences),
            ),
            shuffleState: SliceShuffleState.preShuffled,
          ),
          isCurrent: () => current() && _radioTail(queueService.getQueue())?.id == expectedTail,
        );
        if (!current()) return true;
        final used = added.map((item) => item.id).toSet();
        // Only consume tracks actually appended. Artist-filtered candidates stay available.
        publish(
          state.copyWith(
            tracks: pool.where((item) => !used.contains(item.id)).toList(),
            seedItem: state.radioMode == RadioMode.continuous ? _radioTail(queueService.getQueue()) : null,
            generating: false,
            queueing: false,
          ),
        );
        if (added.isEmpty) break;
      }
      return calculateRadioTracksNeeded() <= 0;
    } catch (error, stack) {
      _radioLogger.warning("Could not refill radio", error, stack);
      return false;
    } finally {
      if (current() && identical(state, _radioCacheStateStream.value)) {
        publish(state.copyWith(generating: false, queueing: false, failed: calculateRadioTracksNeeded() > 0));
      } else if (generation == _radioGeneration && identical(state, _radioCacheStateStream.value)) {
        invalidateRadioCache(resetRetry: false);
      }
      if (generation != _radioGeneration) {
        // The single-flight lock releases before this starts the new session.
        unawaited(Future<void>.delayed(Duration.zero, maybeAddRadioTracks));
      }
    }
  });
}

int _radioTracksNeededForInitialQueue(RadioMode radioMode) => switch (radioMode) {
  // continuous mode requires successive requests, so reduce the amount of tracks so the queue starts faster
  // additional tracks will be loaded after the queue has started
  RadioMode.continuous => 3,
  // if we find true albums right away, this threshold should be easily surpassed
  // if not, searching for fallbacks could take a few requests, so accept fewer tracks to start the queue, then delegate further loading
  RadioMode.albumMix => 7,
  _ => 30,
};

Future<void> startRadioPlayback(BaseItemDto source) async {
  final pendingPreview = generateRadioPreview(source);
  final generation = _radioGeneration;
  final preview = await pendingPreview;
  if (generation != _radioGeneration) return;
  await startRadioPlaybackWithTracks(source, preview.radioMode, preview.tracks);
}

/// Generates the tracks for a new radio queue without touching playback.
Future<({RadioMode radioMode, List<BaseItemDto> tracks})> generateRadioPreview(
  BaseItemDto source, {
  RadioMode? radioMode,
}) async {
  final selectedRadioMode = radioMode ?? FinampSettingsHelper.finampSettings.radioMode;
  final radioTracksNeededForInitialQueue = _radioTracksNeededForInitialQueue(selectedRadioMode);

  invalidateRadioCache(); // we're starting a new queue, any older state is invalid now
  final localResult = _radioCacheStateStream.value!.copyWith(generating: true, failed: false);
  final generation = _radioGeneration;
  _radioCacheStateStream.add(localResult);

  List<BaseItemDto> generatedTracks = [];
  try {
    generatedTracks = await generateRadioTracks(
      radioTracksNeededForInitialQueue,
      overrideSeedItem: source,
      forNewQueue: true,
      radioMode: selectedRadioMode,
      isCurrent: () => generation == _radioGeneration,
    );
  } catch (e) {
    _radioLogger.warning("Couldn't generate radio tracks: $e");
  }

  if (identical(localResult, _radioCacheStateStream.value)) {
    _radioCacheStateStream.add(localResult.copyWith(generating: false));
  }
  if (generation != _radioGeneration) return (radioMode: selectedRadioMode, tracks: <BaseItemDto>[]);
  final preview = RadioQueue.initial(
    source,
    generatedTracks,
    mode: selectedRadioMode,
    needed: generatedTracks.length + 1,
  );
  return (radioMode: selectedRadioMode, tracks: [...preview.selected, ...preview.deferred]);
}

/// Starts a radio queue from preview tracks, after the current track when [keepCurrentTrack].
Future<void> startRadioPlaybackWithTracks(
  BaseItemDto source,
  RadioMode radioMode,
  List<BaseItemDto> tracks, {
  bool keepCurrentTrack = false,
  BaseItemDto? startingTrack,
  String? stationId,
  String? stationName,
}) async {
  final radioTracksNeededForInitialQueue = _radioTracksNeededForInitialQueue(radioMode);

  final tracksToAddCount = switch (radioMode) {
    RadioMode.albumMix => tracks.length + 1, // full albums stay together after the picked song
    RadioMode.reshuffle => tracks.length + 1, // append the full shuffled source after the picked song
    _ => radioTracksNeededForInitialQueue,
  };
  final queueService = GetIt.instance<QueueService>();
  final current = keepCurrentTrack ? queueService.getCurrentTrack()?.baseItem : null;
  final first = startingTrack ?? (BaseItemDtoType.fromItem(source) == BaseItemDtoType.track ? source : null);
  final allowRepeats = RadioQueue.allowsArtistRepeats(
    radioMode,
    QueueItemSource.fromBaseItem(source, type: QueueItemSourceType.radio),
  );
  final selection = RadioQueue.initial(
    source,
    tracks,
    mode: radioMode,
    needed: tracksToAddCount,
    current: current,
    startingTrack: startingTrack,
  );
  final tracksToAdd = selection.selected;
  final tracksToCache = selection.deferred;

  final pinFirst = first != null && tracksToAdd.firstOrNull?.id == first.id;
  if (tracksToAdd.isEmpty && !(current != null && first != null)) {
    _radioLogger.warning("No tracks generated for radio playback from source '${source.name}'. Aborting.");
    GlobalSnackbar.message((context) => AppLocalizations.of(context)!.radioNoTracksFound);
    return;
  }

  FinampSetters.setRadioMode(radioMode);
  toggleRadio(true);
  invalidateRadioCache(); // we're still starting a new queue, and acquire a new lock here
  final localResult = _radioCacheStateStream.value!.copyWith(
    generating: false,
    queueing: true,
    seedItem: radioMode == RadioMode.continuous ? tracksToAdd.lastOrNull ?? source : source,
    tracks: tracksToCache.toList(),
  );
  _radioCacheStateStream.add(localResult);

  final preferences = await RadioPreferencesStore.load();
  final radioSource = QueueItemSource(
    type: QueueItemSourceType.radio,
    name: QueueItemSourceName(
      type: QueueItemSourceNameType.radio,
      localizationParameter: stationName ?? source.name ?? "",
    ),
    id: source.id,
    item: source,
    library: GetIt.instance<FinampUserHelper>().currentUser?.currentViewId,
    allowArtistRepeats: allowRepeats,
    djStationId: stationId,
    genreMix: GenreMix.radioGenreMix(preferences),
  );

  try {
    if (keepCurrentTrack && queueService.getCurrentTrack() != null) {
      await queueService.replaceUpcoming(
        BasePlayableSlice(
          items: tracksToAdd.toList(),
          startingIndex: 0,
          source: radioSource,
          shuffleState: SliceShuffleState.preShuffled,
        ),
        pinFirst: pinFirst,
      );
    } else {
      await queueService.startPlayback(
        items: tracksToAdd.toList(),
        source: radioSource,
        startingIndex: pinFirst ? 0 : null,
        skipRadioCacheInvalidation: true,
        randomizeGenerated: false,
      );
    }
  } finally {
    if (identical(localResult, _radioCacheStateStream.value)) {
      _radioCacheStateStream.add(
        localResult.copyWith(
          queueing: false,
          queueId: queueService.getQueue().id,
          seedItem: radioMode == RadioMode.continuous ? _radioTail(queueService.getQueue()) : source,
        ),
      );
    }
  }
  unawaited(maybeAddRadioTracks());
}

void invalidateRadioCache({bool resetRetry = true}) {
  _radioGeneration++;
  if (resetRetry) _radioRefillGate.reset();
  final radioMode = FinampSettingsHelper.finampSettings.radioMode;
  final radioState = FinampSettingsHelper.finampSettings.radioEnabled;
  final queue = GetIt.instance<QueueService>().getQueue();
  _radioLogger.info("Invalidating radio cache.");
  _radioCacheStateStream.add(
    RadioCacheState(
      tracks: [],
      radioMode: radioMode,
      seedItem: activeRadioSeed(queue, radioMode),
      queueId: queue.id,
      radioState: radioState,
    ),
  );
}

bool toggleRadio([bool? enable]) {
  final queueService = GetIt.instance<QueueService>();
  final currentlyEnabled = FinampSettingsHelper.finampSettings.radioEnabled;
  final radioNowEnabled = enable ?? !currentlyEnabled;
  FinampSetters.setRadioEnabled(radioNowEnabled);
  // trigger a loop mode update to configure the player correctly
  // since for the radio we override the player loop mode
  queueService.loopMode = queueService.loopMode;
  if (!radioNowEnabled) {
    unawaited(queueService.clearRadioTracks());
  }
  GetIt.instance<MusicPlayerBackgroundTask>().refreshPlaybackStateAndMediaNotification();
  return radioNowEnabled;
}

/// Callers should set up correct radio state synchronously before calling this,
/// so that we will be ready for the radio to restart as soon as this function releases its lock.
Future<void> withRadioLock(Future<void> Function() action) async {
  invalidateRadioCache();
  var localResult = _radioCacheStateStream.value!.copyWith(queueing: true);
  _radioCacheStateStream.add(localResult);
  try {
    await action();
  } finally {
    if (identical(localResult, _radioCacheStateStream.value)) {
      final queue = GetIt.instance<QueueService>().getQueue();
      _radioCacheStateStream.add(
        localResult.copyWith(
          queueing: false,
          queueId: queue.id,
          seedItem: activeRadioSeed(queue, localResult.radioMode),
        ),
      );
    }
  }
}

// Generates tracks for the radio. Provide item to generate the initial radio tracks.
Future<List<BaseItemDto>> generateRadioTracks(
  int minNumTracks, {
  BaseItemDto? overrideSeedItem,
  List<BaseItemDto> cachedTracks = const [],
  bool forNewQueue = false,
  RadioMode? radioMode,
  bool Function()? isCurrent,
}) async {
  final selectedRadioMode = radioMode ?? FinampSettingsHelper.finampSettings.radioMode;
  final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final downloadsService = GetIt.instance<DownloadsService>();
  final finampUserHelper = GetIt.instance<FinampUserHelper>();
  final queueService = GetIt.instance<QueueService>();
  final providers = GetIt.instance<ProviderContainer>();
  final currentQueue = queueService.getQueue();
  final preferences = await RadioPreferencesStore.load();
  List<BaseItemDto> tracksOut = [];

  assert(
    currentQueue.fullQueue.isNotEmpty || overrideSeedItem != null,
    "overrideSeedItem must be provided if the queue is empty.",
  );

  final actualSeed = overrideSeedItem ?? activeRadioSeed(currentQueue, selectedRadioMode);

  _radioLogger.info(
    "Generating $minNumTracks radio tracks from ${overrideSeedItem == null ? "queue" : "override"} item '${actualSeed?.name}' using '${selectedRadioMode.name}' mode.",
  );

  Future<List<BaseItemDto>> collectionTracks() async {
    if (actualSeed != null && BaseItemDtoType.fromItem(actualSeed) != BaseItemDtoType.track) {
      return loadChildTracksFromBaseItem(
        item: actualSeed,
        sortConfig: SortAndFilterConfiguration.defaultForItem(actualSeed),
      );
    }
    if (actualSeed != null && (forNewQueue || currentQueue.source.type == QueueItemSourceType.radio)) {
      // A song has no child collection. Random/Reshuffle radio use its music library.
      final views = finampUserHelper.currentUser?.views.values;
      final library =
          currentQueue.sourceLibrary ??
          views?.firstWhereOrNull((item) => item.id == finampUserHelper.currentUser?.currentViewId) ??
          views?.firstOrNull;
      if (library != null) {
        if (preferences.genres.isNotEmpty && !FinampSettingsHelper.finampSettings.isOffline) {
          return preferences.libraryTracks(
            jellyfinApiHelper,
            library,
            max(100, FinampSettingsHelper.finampSettings.trackShuffleItemCount),
            favoritesOnly: currentQueue.source.type == QueueItemSourceType.favorites,
          );
        }
        final result = await GetIt.instance<AudioServiceHelper>().getShuffleAllTracks(
          onlyShowFavorites: false,
          library: library,
          itemCount: max(100, FinampSettingsHelper.finampSettings.trackShuffleItemCount),
        );
        return result?.$1 ?? [];
      }
    }
    if (selectedRadioMode == RadioMode.random &&
        const {
          QueueItemSourceType.allTracks,
          QueueItemSourceType.favorites,
          QueueItemSourceType.genre,
        }.contains(currentQueue.source.type)) {
      final library = currentQueue.sourceLibrary ?? finampUserHelper.currentUser?.views.values.firstOrNull;
      if (library != null) {
        if (preferences.genres.isNotEmpty && !FinampSettingsHelper.finampSettings.isOffline) {
          return preferences.libraryTracks(
            jellyfinApiHelper,
            library,
            max(100, FinampSettingsHelper.finampSettings.trackShuffleItemCount),
            favoritesOnly: currentQueue.source.type == QueueItemSourceType.favorites,
          );
        }
        final result = await GetIt.instance<AudioServiceHelper>().getShuffleAllTracks(
          onlyShowFavorites: currentQueue.source.type == QueueItemSourceType.favorites,
          library: library,
          genreFilter: currentQueue.source.type == QueueItemSourceType.genre ? currentQueue.source.item : null,
          itemCount: max(100, FinampSettingsHelper.finampSettings.trackShuffleItemCount),
        );
        return result?.$1 ?? [];
      }
    }
    return currentQueue.fullQueue
        .where((item) => !FinampSettingsHelper.finampSettings.isOffline || item.item.extras?['isDownloaded'] == true)
        .map((item) => item.baseItem)
        .toList();
  }

  Future<List<BaseItemDto>> reshuffleMode() async {
    final tracks = withoutDuplicateSongs(await collectionTracks());
    // Matching the time of day leans the order by the hour (and by key and tempo, as all tuned Radio does);
    // otherwise the collection is reshuffled as it always was.
    if (tracks.isEmpty || !await RadioClockSettings.load()) {
      return ShuffleRandomness.order(tracks, FinampSettingsHelper.finampSettings.shuffleRandomness);
    }
    return RadioTuning.order(actualSeed ?? tracks.first, tracks);
  }

  Future<List<BaseItemDto>> randomMode() async {
    final tracks = withoutDuplicateSongs(await collectionTracks());
    if (tracks.isEmpty || !await RadioClockSettings.load()) {
      return ShuffleRandomness.order(
        ShuffleRandomness.libraryOrder(tracks),
        FinampSettingsHelper.finampSettings.shuffleRandomness,
      );
    }
    return RadioTuning.order(actualSeed ?? tracks.first, ShuffleRandomness.libraryOrder(tracks));
  }

  /// Adds tracks which are similar to the queue source, with a slightly randomized order
  /// Filters out any duplicates
  Future<List<BaseItemDto>> similarMode() async {
    if (actualSeed == null) {
      throw Exception("No seed item available for radio generation. Aborting.");
    }
    if (FinampSettingsHelper.finampSettings.isOffline) {
      throw Exception("Not available offline.");
    }
    // extra tracks to randomly choose from to introduce non-determinism
    final randomnessExtraTracks = 8 + (minNumTracks * 0.5).ceil();
    return await _getSimilarTracks(
      referenceItem: actualSeed,
      minNumTracks: minNumTracks,
      additionalExistingTracks: cachedTracks,
      randomnessExtraTracks: randomnessExtraTracks,
      maxAttempts: 10,
      // Keep upcoming songs and recent playback out of regular refills.
      disableDuplicateFiltering: forNewQueue,
      isCurrent: isCurrent,
    );
  }

  /// Like [RadioMode.similar], but based on the last track in the queue, not the original source
  Future<List<BaseItemDto>> continuousMode() async {
    if (actualSeed == null) {
      throw Exception("No seed item available for radio generation. Aborting.");
    }
    if (FinampSettingsHelper.finampSettings.isOffline) {
      throw Exception("Not available offline.");
    }
    // extra tracks to randomly choose from to introduce non-determinism
    final randomnessExtraTracks = 5 + (minNumTracks * 1.5).ceil();

    final continuousTime = Stopwatch()..start();
    return RadioQueue.continuous(
      seed: actualSeed,
      needed: minNumTracks,
      isCurrent: () => continuousTime.elapsed < const Duration(seconds: 20) && (isCurrent?.call() ?? true),
      allowArtistRepeats: !forNewQueue && RadioQueue.allowsArtistRepeats(selectedRadioMode, currentQueue.source),
      next: (reference, selected) => _getSimilarTracks(
        referenceItem: reference,
        fallbackReferenceItem: actualSeed,
        minNumTracks: 1,
        additionalExistingTracks: [...cachedTracks, actualSeed, ...selected],
        maxAttempts: 4,
        randomnessExtraTracks: randomnessExtraTracks,
        disableDuplicateFiltering: forNewQueue,
        previous: reference,
        tuning: preferences.copyWith(
          discovery:
              selected.where((item) => (item.userData?.playCount ?? 0) == 0 && item.userData?.played != true).length <
                  ((selected.length + 1) * preferences.discovery / 100).round()
              ? 100
              : 0,
        ),
        isCurrent: isCurrent,
      ),
    );
  }

  Future<List<BaseItemDto>> albumMixMode() async {
    int attempt = 0;
    final albumTime = Stopwatch()..start();

    RadioCacheState? localRadioState = _radioCacheStateStream.valueOrNull;
    AlbumMixFallbackModes? fallbackMode;
    if (overrideSeedItem == null) {
      assert(actualSeed == localRadioState?.seedItem, "Inconsistent seed item state in album mix radio generation.");
      fallbackMode = localRadioState?.albumMixFallbackMode;
    }
    if (fallbackMode == null && FinampSettingsHelper.finampSettings.isOffline) {
      fallbackMode = AlbumMixFallbackModes.artistAlbums;
    }

    try {
      if (actualSeed == null) {
        throw Exception("No seed item available for radio generation. Aborting.");
      }
      final seedId = getAlbumMixRadioModeSeedId(actualSeed);
      if (seedId == null) {
        throw Exception(
          "Album mix radio mode selected but the provided item '${actualSeed.name}' is not suitable for album mix radio. Returning empty track list.",
        );
      }
      // extra albums in case duplicates are removed
      const filterExtraAlbums = 10;
      // extra albums to randomly choose from to introduce non-determinism
      final randomnessExtraAlbums = 5;

      // filter out any albums where tracks with that album as the (radio) source are already in the queue
      final existingAlbumIds =
          (forNewQueue
                  ? <BaseItemDto>[]
                  : [
                      ..._radioBlocked(currentQueue, selectedRadioMode, recent: false),
                      ...RadioQueue.recent(currentQueue, const Duration(minutes: 90)),
                      ...cachedTracks,
                    ])
              .map((item) => item.albumId)
              .nonNulls
              .toSet();
      List<BaseItemDto> filteredSimilarAlbums = [];

      while (filteredSimilarAlbums.isEmpty &&
          attempt < 10 &&
          albumTime.elapsed < const Duration(seconds: 20) &&
          (isCurrent?.call() ?? true)) {
        final additionalAlbums = 2 * attempt + pow(attempt, 2.75).toInt(); // ~ 0, 3, 10, 27, 50, 100
        attempt++;
        if (attempt > 1) {
          _radioLogger.warning("No similar albums found. Retrying with $additionalAlbums extra albums.");
        }

        List<BaseItemDto> similarAlbums;

        switch (fallbackMode) {
          case AlbumMixFallbackModes.artistAlbums:
          case AlbumMixFallbackModes.artistSingles:
          case AlbumMixFallbackModes.performingArtistAlbums:
            BaseItemDto? artist;
            List<BaseItemId> artistIds = [];
            if (fallbackMode != AlbumMixFallbackModes.performingArtistAlbums) {
              artistIds.addAll(actualSeed.albumArtists?.map((e) => e.id).whereType<BaseItemId>() ?? []);
            }
            artistIds.addAll(actualSeed.artistItems?.map((e) => e.id).whereType<BaseItemId>() ?? []);
            while (artist == null &&
                artistIds.isNotEmpty &&
                albumTime.elapsed < const Duration(seconds: 20) &&
                (isCurrent?.call() ?? true)) {
              final artistId = artistIds.removeAt(0);
              artist = await providers.read(artistItemProvider(artistId).future);
            }
            if (artist == null) {
              fallbackMode = AlbumMixFallbackModes.libraryAlbumsOrSingles;
              continue;
            }
            if (fallbackMode == AlbumMixFallbackModes.performingArtistAlbums) {
              similarAlbums = await providers.read(
                getPerformingArtistAlbumsProvider(
                  artist: artist,
                  libraryFilter: currentQueue.sourceLibrary?.id,
                  sortBy: SortBy.random,
                ).future,
              );
            } else {
              similarAlbums = await providers.read(
                getArtistAlbumsProvider(
                  artist: artist,
                  libraryFilter: currentQueue.sourceLibrary?.id,
                  sortBy: SortBy.random,
                ).future,
              );
            }

            break;
          case AlbumMixFallbackModes.libraryAlbumsOrSingles:
            // just fetch a random album from the library
            if (FinampSettingsHelper.finampSettings.isOffline) {
              similarAlbums = (await downloadsService.getAllCollections(
                includeItemTypes: [BaseItemDtoType.album],
                fullyDownloaded: false,
                viewFilter: finampUserHelper.currentUser?.currentViewId,
                nullableViewFilters: FinampSettingsHelper.finampSettings.showDownloadsWithUnknownLibrary,
              )).map((e) => e.baseItem).nonNulls.toList();
            } else {
              similarAlbums =
                  (await jellyfinApiHelper.getItems(
                    parentItem: currentQueue.sourceLibrary,
                    recursive: true,
                    includeItemTypes: BaseItemDtoType.album.jellyfinName,
                    sortBy: SortBy.random.jellyfinName(ContentType.albums),
                  )) ??
                  [];
            }
            break;
          case AlbumMixFallbackModes.similarSingles:
          case null:
            if (FinampSettingsHelper.finampSettings.isOffline) {
              fallbackMode = AlbumMixFallbackModes.artistAlbums;
              continue;
            }
            similarAlbums =
                await jellyfinApiHelper.getSimilarAlbums(
                  seedId,
                  limit: 1 + filterExtraAlbums + randomnessExtraAlbums + additionalAlbums,
                ) ??
                [];
            break;
        }

        if (similarAlbums.isEmpty && fallbackMode == null) {
          // Jellyfin can't guarantee that there are similar albums, since the suggestions are based on genre tags
          // If a genre only contains that one album, no similar albums will be returned
          _radioLogger.warning(
            "No new similar albums found for album mix radio from item '${actualSeed.name}'. Fetching based on album artist.",
          );
          fallbackMode = AlbumMixFallbackModes.artistAlbums;
          continue;
        }

        filteredSimilarAlbums = similarAlbums
            .where(preferences.permits)
            .where((album) => !existingAlbumIds.contains(album.id))
            // don't include singles unless we're falling back to them
            .where(
              (album) =>
                  ([
                    AlbumMixFallbackModes.similarSingles,
                    AlbumMixFallbackModes.artistSingles,
                    AlbumMixFallbackModes.libraryAlbumsOrSingles,
                  ].contains(fallbackMode) ||
                  (album.songCount ?? album.childCount ?? 0) > 1),
            )
            .toList();

        if (filteredSimilarAlbums.isEmpty) {
          switch (fallbackMode) {
            case AlbumMixFallbackModes.artistAlbums:
              _radioLogger.warning(
                "No suitable similar full albums found for album mix radio from artist '${actualSeed.albumArtists?.firstOrNull?.name ?? actualSeed.artistItems?.firstOrNull?.name}'. Fetching singles.",
              );
              fallbackMode = AlbumMixFallbackModes.artistSingles;
              continue;
            case AlbumMixFallbackModes.artistSingles:
              _radioLogger.warning(
                "No suitable similar singles found for album mix radio from artist '${actualSeed.albumArtists?.firstOrNull?.name ?? actualSeed.artistItems?.firstOrNull?.name}'. Fetching appears on albums.",
              );
              fallbackMode = AlbumMixFallbackModes.performingArtistAlbums;
              continue;
            case AlbumMixFallbackModes.performingArtistAlbums:
              _radioLogger.warning(
                "No suitable similar appears on albums found for album mix radio from artist '${actualSeed.albumArtists?.firstOrNull?.name ?? actualSeed.artistItems?.firstOrNull?.name}'. Fetching from library.",
              );
              fallbackMode = AlbumMixFallbackModes.libraryAlbumsOrSingles;
              continue;
            case AlbumMixFallbackModes.similarSingles:
            case AlbumMixFallbackModes.libraryAlbumsOrSingles:
              break;
            case null:
              if (attempt >= 5) {
                _radioLogger.warning(
                  "No new suitable similar albums found for album mix radio for item '${actualSeed.name}' after $attempt attempts. Switching to fallbacks",
                );
                fallbackMode = AlbumMixFallbackModes.artistAlbums;
              }
              break;
          }
        }
      }

      // pick a random album from the remaining ones
      if (filteredSimilarAlbums.isNotEmpty) {
        BaseItemDto selectedAlbum;
        if (fallbackMode == AlbumMixFallbackModes.libraryAlbumsOrSingles) {
          // since we can't filter by track count when fetching from the server, we instead sort by track count > 1 to pick a full album if available, but fall back to singles
          filteredSimilarAlbums.sortBy<num>((album) => (album.songCount ?? album.childCount ?? 0) > 1 ? 0 : 1);
          selectedAlbum = filteredSimilarAlbums.first;
          filteredSimilarAlbums.removeAt(0);
        } else {
          final randomIndex = ShuffleRandomness.order(
            List.generate(min(filteredSimilarAlbums.length, randomnessExtraAlbums), (i) => i),
            FinampSettingsHelper.finampSettings.shuffleRandomness,
            random: _radioRandom,
          ).first;
          selectedAlbum = filteredSimilarAlbums[randomIndex];
          filteredSimilarAlbums.removeAt(randomIndex);
        }
        _radioLogger.finer("Selected album '${selectedAlbum.name}' for album mix radio.");
        // load tracks from the selected album
        final albumTracks = await loadChildTracksFromBaseItem(
          item: selectedAlbum,
          sortConfig: SortAndFilterConfiguration.defaultForItem(selectedAlbum),
        );
        // we add all tracks at once to preserve the album as a unit
        return albumTracks;
      } else {
        throw Exception("No suitable similar albums found for album mix radio. Returning empty track list.");
      }
    } catch (e) {
      rethrow;
    } finally {
      // if it's a regular radio track generation, update the fallback mode for the current cache state
      // if the cache gets replaced/invalidated before we get here, we only end up modifying the old cache state which isn't used anymore
      if (localRadioState != null && overrideSeedItem == null) {
        localRadioState.updateAlbumMixFallbackMode(fallbackMode);
      }
    }
  }

  try {
    tracksOut = switch (selectedRadioMode) {
      RadioMode.reshuffle => await reshuffleMode().timeout(const Duration(seconds: 20)),
      RadioMode.random => await randomMode().timeout(const Duration(seconds: 20)),
      RadioMode.similar => await similarMode(),
      RadioMode.continuous => await continuousMode(),
      RadioMode.albumMix => await albumMixMode().timeout(const Duration(seconds: 20)),
    };
  } catch (e) {
    _radioLogger.warning(e);
  }
  tracksOut = await preferences.rank(tracksOut, minNumTracks, album: selectedRadioMode == RadioMode.albumMix);
  _radioLogger.info(
    "Selected ${tracksOut.length} tracks for '${selectedRadioMode.name}' mode: ${tracksOut.map((e) => "'${e.artists?.firstOrNull} - ${e.name}'").join(", ")}",
  );
  return tracksOut;
}

Future<List<BaseItemDto>> _getSimilarTracks({
  required BaseItemDto referenceItem,
  required int minNumTracks,
  required List<BaseItemDto> additionalExistingTracks,
  required int randomnessExtraTracks,
  required int maxAttempts,
  bool disableDuplicateFiltering = false,
  BaseItemDto? previous,
  BaseItemDto? fallbackReferenceItem,
  RadioPreferences? tuning,
  bool Function()? isCurrent,
}) async {
  if (FinampSettingsHelper.finampSettings.isOffline) return [];
  final api = GetIt.instance<JellyfinApiHelper>();
  final queue = GetIt.instance<QueueService>().getQueue();
  final mode = FinampSettingsHelper.finampSettings.radioMode;
  final preferences = tuning ?? await RadioPreferencesStore.load();
  final allowRepeats = !disableDuplicateFiltering && RadioQueue.allowsArtistRepeats(mode, queue.source);
  final boundary = previous ?? (disableDuplicateFiltering ? null : _radioTail(queue));
  final fixedBlocked = [
    if (!disableDuplicateFiltering) ..._radioBlocked(queue, mode, recent: false),
    ...additionalExistingTracks,
    if (BaseItemDtoType.fromItem(referenceItem) == BaseItemDtoType.track) referenceItem,
  ];
  final genreIds = [
    ...?referenceItem.genreItems,
    ...?fallbackReferenceItem?.genreItems,
  ].map((genre) => genre.id).toSet().toList();
  final genreNames = {
    ...?referenceItem.genres,
    ...?fallbackReferenceItem?.genres,
  }.map((genre) => genre.toLowerCase()).toSet();
  return RadioQueue.search(
    needed: minNumTracks,
    previous: boundary,
    allowArtistRepeats: allowRepeats,
    blocked: [
      ...fixedBlocked,
      if (!disableDuplicateFiltering) ...RadioQueue.recent(queue, const Duration(minutes: 30)),
    ],
    attempts: min(4, maxAttempts),
    isCurrent: isCurrent,
    fetch: (attempt, limit) async {
      List<BaseItemDto> candidates;
      if (attempt == 3 && (preferences.genres.isNotEmpty || genreIds.isNotEmpty || genreNames.isNotEmpty)) {
        final filters = preferences.genres.isEmpty ? genreIds : await preferences.genreIds(api, queue.sourceLibrary);
        if (preferences.genres.isNotEmpty && filters.isEmpty) return [];
        candidates =
            await api
                .getItems(
                  parentItem: queue.sourceLibrary,
                  includeItemTypes: 'Audio',
                  sortBy: 'Random',
                  recursive: true,
                  genreFilters: filters.isEmpty ? null : filters,
                  limit: min(500, limit + randomnessExtraTracks),
                )
                .timeout(const Duration(seconds: 4)) ??
            [];
        if (filters.isEmpty) {
          candidates = candidates
              .where((item) => item.genres?.any((genre) => genreNames.contains(genre.toLowerCase())) ?? false)
              .toList();
        }
      } else {
        final seed = attempt == 2 && fallbackReferenceItem != null ? fallbackReferenceItem : referenceItem;
        candidates =
            await api
                .getInstantMix(seed, limit: min(500, limit + randomnessExtraTracks))
                .timeout(const Duration(seconds: 4)) ??
            [];
      }
      candidates = withoutDuplicateSongs(
        candidates,
        already: [
          ...fixedBlocked,
          if (!disableDuplicateFiltering) ...RadioQueue.recent(queue, Duration(minutes: attempt < 2 ? 90 : 30)),
        ],
      );
      if (isCurrent?.call() == false) return [];
      if (minNumTracks == 1 && !allowRepeats && boundary != null) {
        final previousArtist = ArtistSpacing.artistKey(boundary);
        if (previousArtist != null) {
          candidates = candidates.where((item) => ArtistSpacing.artistKey(item) != previousArtist).toList();
        }
      }
      final ranked = await RadioTuning.order(
        referenceItem,
        candidates,
      ).timeout(const Duration(seconds: 3), onTimeout: () => candidates);
      return preferences.rank(ranked, minNumTracks);
    },
  );
}

enum RadioModeAvailabilityStatus {
  disabled,
  available,
  unavailableOffline,
  unavailableNotDownloaded,
  unavailableSourceTypeNotSupported,
  unavailableQueueEmpty,
  unavailableSourceNull;

  bool get isAvailable => this == RadioModeAvailabilityStatus.available;
}

final currentRadioAvailabilityStatusProvider = Provider<RadioModeAvailabilityStatus>((ref) {
  final radioMode = ref.watch(finampSettingsProvider.radioMode);
  final radioModeAvailable = ref.watch(
    radioModeAvailabilityStatusProvider((radioMode, ref.watch(getActiveRadioSeedProvider(radioMode)))),
  );
  final radioEnabled = ref.watch(finampSettingsProvider.radioEnabled);
  return !radioEnabled ? RadioModeAvailabilityStatus.disabled : radioModeAvailable;
});

final radioModeAvailabilityStatusProvider =
    AutoDisposeProviderFamily<RadioModeAvailabilityStatus, (RadioMode, BaseItemDto?)>((
      ref,
      (RadioMode radioMode, BaseItemDto? source) arguments,
    ) {
      final radioMode = arguments.$1;
      final source = arguments.$2;

      final randomAndReshuffleModeAvailability = ref.watch(
        _randomAndReshuffleRadioModeAvailabilityStatusProvider(source),
      );
      final similarAndContinuousModeAvailability = ref.watch(
        _similarAndContinuousRadioModeAvailabilityStatusProvider(source),
      );
      final albumMixModeAvailable = ref.watch(_albumMixRadioModeAvailabilityStatusProvider(source));

      final currentModeAvailable = switch (radioMode) {
        RadioMode.random || RadioMode.reshuffle => randomAndReshuffleModeAvailability,
        RadioMode.similar || RadioMode.continuous => similarAndContinuousModeAvailability,
        RadioMode.albumMix => albumMixModeAvailable,
      };
      return currentModeAvailable;
    });

final _randomAndReshuffleRadioModeAvailabilityStatusProvider =
    ProviderFamily<RadioModeAvailabilityStatus, BaseItemDto?>((ref, BaseItemDto? baseItem) {
      if (baseItem != null) {
        final downloadsService = GetIt.instance<DownloadsService>();

        // only available offline when downloaded
        return (!ref.watch(finampSettingsProvider.isOffline) ||
                ref
                    .watch(
                      downloadsService.statusProvider((
                        DownloadStub.fromItem(type: baseItem.downloadType, item: baseItem),
                        null,
                      )),
                    )
                    .isDownloaded)
            ? RadioModeAvailabilityStatus.available
            : RadioModeAvailabilityStatus.unavailableNotDownloaded;
      } else {
        return ref.watch(QueueService.queueProvider.select((x) => (x?.trackCount ?? 0) > 0))
            ? RadioModeAvailabilityStatus.available
            : RadioModeAvailabilityStatus.unavailableQueueEmpty;
      }
    });

final _similarAndContinuousRadioModeAvailabilityStatusProvider =
    ProviderFamily<RadioModeAvailabilityStatus, BaseItemDto?>((ref, BaseItemDto? baseItem) {
      // only available online when source is not null
      return ref.watch(finampSettingsProvider.isOffline)
          ? RadioModeAvailabilityStatus.unavailableOffline
          : baseItem == null
          ? RadioModeAvailabilityStatus.unavailableSourceNull
          : RadioModeAvailabilityStatus.available;
    });

BaseItemId? getAlbumMixRadioModeSeedId(BaseItemDto? baseItem) {
  return baseItem != null
      ? switch (BaseItemDtoType.fromItem(baseItem)) {
          BaseItemDtoType.album => baseItem.id,
          BaseItemDtoType.track => baseItem.albumId,
          _ => null,
        }
      : null;
}

final _albumMixRadioModeAvailabilityStatusProvider = ProviderFamily<RadioModeAvailabilityStatus, BaseItemDto?>((
  ref,
  BaseItemDto? baseItem,
) {
  // only when the seed item is an album itself or part of one
  final albumMixModeAvailable = getAlbumMixRadioModeSeedId(baseItem) != null;
  return albumMixModeAvailable
      ? RadioModeAvailabilityStatus.available
      : RadioModeAvailabilityStatus.unavailableSourceTypeNotSupported;
});

final getActiveRadioSeedProvider = ProviderFamily<BaseItemDto?, RadioMode>((Ref ref, RadioMode radioMode) {
  return activeRadioSeed(ref.watch(QueueService.queueProvider), radioMode);
});

/// Queue mutations are synchronous; background refill checks must not wait for the UI stream.
BaseItemDto? activeRadioSeed(FinampQueueInfo? currentQueue, RadioMode radioMode) {
  switch (radioMode) {
    case RadioMode.continuous:
      return currentQueue?.fullQueue.lastOrNull?.baseItem;
    case RadioMode.reshuffle:
    case RadioMode.random:
      return currentQueue?.source.type == QueueItemSourceType.radio ? currentQueue?.source.item : null;
    case RadioMode.similar:
      return currentQueue?.source.item ?? currentQueue?.currentTrack?.baseItem;
    case RadioMode.albumMix:
      final seed = currentQueue?.source.item;
      return getAlbumMixRadioModeSeedId(seed) != null ? seed : currentQueue?.currentTrack?.baseItem;
  }
}

IconData getRadioModeIcon(RadioMode radioMode) {
  return switch (radioMode) {
    RadioMode.reshuffle => TablerIcons.arrows_shuffle,
    RadioMode.random => TablerIcons.help_hexagon,
    RadioMode.similar => TablerIcons.ear,
    RadioMode.continuous => TablerIcons.route,
    RadioMode.albumMix => TablerIcons.album,
  };
}
