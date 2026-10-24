import 'dart:async';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/server_health_guard.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:finamp/services/media_art_uri.dart';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:finamp/components/PlayerScreen/queue_source_helper.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/now_playing_bar.dart';
import 'package:finamp/gen/assets.gen.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart' as jellyfin_models;
import 'package:finamp/services/album_image_provider.dart';
import 'package:finamp/services/current_album_image_provider.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback_history_service.dart';
import 'package:finamp/services/radio_service_helper.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/utils/run_again.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path_helper;
import 'package:path_provider/path_provider.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:finamp/services/shuffle_randomness.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';

import '../models/music_slices.dart';

/// A track queueing service for Finamp.
class QueueService {
  static const savedQueueSource = QueueItemSource.rawId(
    type: QueueItemSourceType.unknown,
    name: QueueItemSourceName(type: QueueItemSourceNameType.savedQueue),
    id: "savedqueue",
  );

  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  final _downloadsService = GetIt.instance<DownloadsService>();
  final _queueServiceLogger = Logger("QueueService");
  final _queuesBox = Hive.box<FinampStorableQueueInfo>("Queues");
  final _providers = GetIt.instance<ProviderContainer>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();

  // internal state

  final List<FinampQueueItem> _queuePreviousTracks =
      []; // contains **all** items that have been played, including "next up"
  FinampQueueItem? _currentTrack; // the currently playing track
  final List<FinampQueueItem> _queueNextUp = []; // a temporary queue that gets appended to if the user taps "next up"
  final List<FinampQueueItem> _queue = []; // contains all regular queue items
  // The latest shuffle indices.  This is only updated by _buildQueueFromNativePlayerQueue to ensure
  // it is always in sync with the queued track lists
  List<int> _latestShuffleIndices = [];
  FinampQueueOrder _order = FinampQueueOrder(
    items: [],
    originalSource: QueueItemSource.rawId(
      id: "",
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated),
      type: QueueItemSourceType.unknown,
    ),
    linearOrder: [],
    shuffledOrder: [],
    sourceLibrary: null,
  ); // contains all items that were at some point added to the regular queue, as well as their order when shuffle is enabled and disabled. This is used to loop the original queue once the end has been reached and "loop all" is enabled, **excluding** "next up" items and keeping the playback order.

  FinampPlaybackOrder _playbackOrder = FinampPlaybackOrder.linear;
  FinampLoopMode _loopMode = FinampLoopMode.none;
  double _playbackSpeed = 1.0;
  double _playbackPitch = 1.0;

  final _currentTrackStream = BehaviorSubject<FinampQueueItem?>.seeded(null);
  final _queueStream = BehaviorSubject<FinampQueueInfo?>.seeded(null);

  final _playbackOrderStream = BehaviorSubject<FinampPlaybackOrder>.seeded(FinampPlaybackOrder.linear);
  // Whether the songs after the current one (and Next up) are in harmonic order. Any other change of order clears it.
  final _harmonicOrderStream = BehaviorSubject<bool>.seeded(false);
  final _loopModeStream = BehaviorSubject<FinampLoopMode>.seeded(FinampLoopMode.none);
  final _playbackSpeedStream = BehaviorSubject<double>.seeded(1.0);
  final _playbackPitchStream = BehaviorSubject<double>.seeded(1.0);

  // external queue state

  late final NextUpShuffleOrder _shuffleOrder;
  int _currentQueueIndex = 0;
  int? _activeInitialIndex;
  Object? _activeReload;
  QueuePlaybackStart? _playbackStart;

  /// Suppress transient index changes while the current song's audio source is replaced.
  Future<void> duringPlayerReload(int initialIndex, Future<void> Function() reload) async {
    final owner = Object();
    _activeReload = owner;
    _activeInitialIndex = initialIndex;
    try {
      await reload();
    } finally {
      if (identical(_activeReload, owner)) {
        _activeInitialIndex = null;
        _activeReload = null;
      }
    }
  }

  // Flags for saving and loading saved queues
  int _saveUpdateCycleCount = 0;
  bool _saveUpdateImmediate = false;
  SavedQueueState _savedQueueState = SavedQueueState.preInit;
  FinampStorableQueueInfo? _failedSavedQueue;
  static const int _maxSavedQueues = 60;

  final _initialQueueLoad = Completer<void>();

  static int get maxInitialQueueItems => Platform.isIOS || Platform.isMacOS
      ? 1000
      : Platform.isAndroid
      ? 1000
      : 1000;

  static int get maxQueueItems => Platform.isIOS || Platform.isMacOS ? 1500 : 5000;

  QueueService() {
    // _queueServiceLogger.level = Level.OFF;

    final finampSettings = FinampSettingsHelper.finampSettings;

    loopMode = finampSettings.loopMode;
    _queueServiceLogger.info("Restored loop mode to $loopMode from settings");

    playbackSpeed = finampSettings.playbackSpeed;
    _queueServiceLogger.info("Restored playback speed to $playbackSpeed from settings");

    _shuffleOrder = NextUpShuffleOrder(queueService: this);

    _audioHandler.playbackState.listen((event) async {
      // int indexDifference = (event.currentIndex ?? 0) - _queueAudioSourceIndex;

      final previousIndex = _currentQueueIndex;
      _currentQueueIndex = event.queueIndex ?? 0;

      // Ignore playback events if queue is empty.
      if (_audioHandler.audioSources.isNotEmpty && (previousIndex != _currentQueueIndex || _currentTrack == null)) {
        _queueServiceLogger.finer("Play queue index changed, new index: $_currentQueueIndex");
        _buildQueueFromNativePlayerQueue();
      } else {
        _saveUpdateImmediate = true;
      }
    });

    Stream<void>.periodic(const Duration(seconds: 10)).listen((event) {
      // Update once per minute while playing in background, and up to once every ten seconds if
      // pausing/seeking is occurring
      // We also update on every track switch.
      if ((_saveUpdateCycleCount >= 5 && !_audioHandler.paused) || _saveUpdateImmediate) {
        if (_savedQueueState == SavedQueueState.pendingSave && !_audioHandler.paused) {
          _savedQueueState = SavedQueueState.saving;
        }
        if (_savedQueueState == SavedQueueState.saving) {
          _saveUpdateImmediate = false;
          _saveUpdateCycleCount = 0;
          final info = _saveCurrentQueue(withPosition: true);
          _queueServiceLogger.finest("Saved new periodic queue $info");
        }
      } else {
        _saveUpdateCycleCount++;
      }
      // just in case, check if there are radio tracks missing (due to errors, race conditions, etc.)
      unawaited(maybeAddRadioTracks());
    });

    // check if new radio tracks are needed whenever the queue changes in some way
    _queueStream.listen((_) {
      unawaited(maybeAddRadioTracks());
    });

    // Schedule for after queue service is registered
    Future.microtask(() {
      // Keep currentAlbumImageProvider alive to provide precaching
      _providers.listen(currentAlbumImageProvider, (_, _) {});

      // check if new radio tracks are needed whenever the radio mode or connectivity is changed
      _providers.listen(finampSettingsProvider.radioEnabled, (_, _) => unawaited(maybeAddRadioTracks()));
      _providers.listen(finampSettingsProvider.radioMode, (_, _) => unawaited(maybeAddRadioTracks()));
      _providers.listen(finampSettingsProvider.isOffline, (_, _) => unawaited(maybeAddRadioTracks()));
      _providers.listen(FinampUserHelper.finampCurrentUserProvider, (_, _) => unawaited(maybeAddRadioTracks()));
    });

    // register callbacks
    // _audioHandler.setQueueCallbacks(
    //   nextTrackCallback: _applyNextTrack,
    //   previousTrackCallback: _applyPreviousTrack,
    //   skipToIndexCallback: _applySkipToTrackByOffset,
    // );
  }

  ProviderSubscription<AlbumImageInfo>? _latestAlbumImage;

  void _buildQueueFromNativePlayerQueue({bool logUpdate = true, int? indexOverride}) {
    final playbackHistoryService = GetIt.instance<PlaybackHistoryService>();

    _currentQueueIndex = indexOverride ?? _audioHandler.queueIndex ?? _currentQueueIndex;
    if (_activeInitialIndex != null && _currentQueueIndex != _activeInitialIndex) {
      // We have been during the middle of a queue replacement.  Ignore to avoid stripping next up entries.
      _queueServiceLogger.warning("Ignoring call to _buildQueueFromNativePlayerQueue while in queue replacement");
      return;
    }

    List<FinampQueueItem> allTracks = _audioHandler.sequenceState.effectiveSequence
        .map((e) => e.tag as FinampQueueItem)
        .toList();
    _latestShuffleIndices = _audioHandler.sequenceState.shuffleIndices;

    _queuePreviousTracks.clear();
    _queueNextUp.clear();
    _queue.clear();

    bool canHaveNextUp = true;

    // split the queue by old type
    for (int i = 0; i < allTracks.length; i++) {
      if (i < _currentQueueIndex) {
        _queuePreviousTracks.add(allTracks[i]);
        if ([
          QueueItemSourceType.nextUp,
          QueueItemSourceType.nextUpAlbum,
          QueueItemSourceType.nextUpPlaylist,
          QueueItemSourceType.nextUpArtist,
          QueueItemSourceType.nextUpGenre,
        ].contains(_queuePreviousTracks.last.source.type)) {
          _queuePreviousTracks.last.source = QueueItemSource.rawId(
            type: QueueItemSourceType.formerNextUp,
            name: const QueueItemSourceName(type: QueueItemSourceNameType.tracksFormerNextUp),
            id: "former-next-up",
          );
        }
        _queuePreviousTracks.last.type = QueueItemQueueType.previousTracks;
      } else if (i == _currentQueueIndex) {
        _currentTrack = allTracks[i];
        _currentTrack!.type = QueueItemQueueType.currentTrack;
      } else {
        if (allTracks[i].type == QueueItemQueueType.currentTrack &&
            [
              QueueItemSourceType.nextUp,
              QueueItemSourceType.nextUpAlbum,
              QueueItemSourceType.nextUpPlaylist,
              QueueItemSourceType.nextUpArtist,
              QueueItemSourceType.nextUpGenre,
            ].contains(allTracks[i].source.type)) {
          _queue.add(allTracks[i]);
          _queue.last.type = QueueItemQueueType.queue;
          _queue.last.source = QueueItemSource.rawId(
            type: QueueItemSourceType.formerNextUp,
            name: const QueueItemSourceName(type: QueueItemSourceNameType.tracksFormerNextUp),
            id: "former-next-up",
          );
          canHaveNextUp = false;
        } else if (allTracks[i].type == QueueItemQueueType.nextUp) {
          if (canHaveNextUp) {
            _queueNextUp.add(allTracks[i]);
            _queueNextUp.last.type = QueueItemQueueType.nextUp;
          } else {
            _queue.add(allTracks[i]);
            _queue.last.type = QueueItemQueueType.queue;
            _queue.last.source = QueueItemSource.rawId(
              type: QueueItemSourceType.formerNextUp,
              name: const QueueItemSourceName(type: QueueItemSourceNameType.tracksFormerNextUp),
              id: "former-next-up",
            );
          }
        } else {
          _queue.add(allTracks[i]);
          _queue.last.type = QueueItemQueueType.queue;
          canHaveNextUp = false;
        }
      }
    }

    if (_activeReload == null && _playbackStart?.queueItemId != _currentTrack?.id) {
      _playbackStart = null;
    }

    if (allTracks.isEmpty) {
      _queueServiceLogger.info("Queue is empty");
      _currentTrack = null;
      _audioHandler.playbackState.add(
        PlaybackState(
          processingState: AudioProcessingState.idle,
          playing: false,
          queueIndex: 0,
          updatePosition: Duration.zero,
          updateTime: DateTime.now(),
          bufferedPosition: Duration.zero,
        ),
      );
    }

    refreshQueueStream();
    _currentTrackStream.add(_currentTrack);
    var currentMediaItem = _currentTrack?.item;
    if (currentMediaItem != null) {
      final item = jellyfin_models.BaseItemDto.fromJson(currentMediaItem.extras!["itemJson"] as Map<String, dynamic>);
      final artRequest = AlbumImageRequest(item: item);

      void updateMediaItem(AlbumImageInfo latest, bool force) async {
        var artUri = latest.uri;
        if (artUri == null) {
          // replace with placeholder art
          final applicationSupportDirectory = await getApplicationSupportDirectory();
          artUri = Uri.file(path_helper.join(applicationSupportDirectory.absolute.path, Assets.images.albumWhite.path));
        }
        // player images should always be either the placeholder image, downloaded images, or loaded from the image cache.
        assert(artUri.scheme == "file");
        // use content provider for handling media art on Android
        if (Platform.isAndroid) {
          final packageInfo = await PackageInfo.fromPlatform();
          artUri = Uri(scheme: "content", host: packageInfo.packageName, path: artUri.path);
        }
        if (!force && _audioHandler.mediaItem.valueOrNull?.id != currentMediaItem?.id) return;
        currentMediaItem = currentMediaItem?.copyWith(artUri: artUri);
        _audioHandler.mediaItem.add(currentMediaItem);
      }

      _latestAlbumImage?.close();
      _latestAlbumImage = _providers.listen(
        albumImageProvider(artRequest),
        (_, latest) => updateMediaItem(latest, false),
      );
      updateMediaItem(_providers.read(albumImageProvider(artRequest)), true);
    }
    _audioHandler.queue.add(
      _queuePreviousTracks
          .followedBy(_currentTrack != null ? [_currentTrack!] : [])
          .followedBy(_queueNextUp)
          .followedBy(_queue)
          .map((e) => e.item)
          .toList(),
    );
    // _audioHandler.queueTitle.add(_order.originalSource.name.toString());
    _audioHandler.queueTitle.add("Finamp");

    if (_savedQueueState == SavedQueueState.saving) {
      _saveCurrentQueue(withPosition: false);
      _queueServiceLogger.finest("Saved new rebuilt queue");
      _saveUpdateImmediate = false;
      _saveUpdateCycleCount = 0;
    }

    if (logUpdate) {
      _logQueues(message: "(current)");
    }

    if (FinampSettingsHelper.finampSettings.reportQueueToServer || FinampSettingsHelper.finampSettings.enablePlayon) {
      unawaited(playbackHistoryService.reportQueueStatus());
    }
  }

  FinampStorableQueueInfo _saveCurrentQueue({bool withPosition = false}) {
    final queueToSave = getQueue();
    List<int> shuffleIndices = [..._latestShuffleIndices];
    // if we exceeded the queue size limit, remove as many tracks from previousTracks as needed
    if (queueToSave.fullQueue.length > maxQueueItems) {
      final excess = queueToSave.fullQueue.length - maxQueueItems;
      // create a copy of previous tracks to avoid modifying the original list, which is tied directly to Finamp's internal queue
      var trimmedPreviousTracks = [...queueToSave.previousTracks];
      List<int> indicesToRemove = [];
      trimmedPreviousTracks.forEachIndexed((index, e) {
        if (indicesToRemove.length < excess && [QueueItemSourceType.radio].contains(e.source.type)) {
          indicesToRemove.add(index);
        }
      });
      if (indicesToRemove.isNotEmpty) {
        final List<int> shuffleIndicesToRemove;
        if (playbackOrder == FinampPlaybackOrder.shuffled) {
          shuffleIndicesToRemove = indicesToRemove.map((x) => shuffleIndices[x]).toList();
        } else {
          shuffleIndicesToRemove = indicesToRemove;
        }
        trimmedPreviousTracks = trimmedPreviousTracks
            .mapIndexed((i, x) => indicesToRemove.contains(i) ? null : x)
            .nonNulls
            .toList();
        shuffleIndices = shuffleIndices.map((x) => shuffleIndicesToRemove.contains(x) ? null : x).nonNulls.toList();
        queueToSave.previousTracks = trimmedPreviousTracks;
        // repair shuffle indices to close "gaps"
        for (int i = 0; i < shuffleIndices.length; i++) {
          int removedBefore = shuffleIndicesToRemove.where((x) => x < shuffleIndices[i]).length;
          shuffleIndices[i] = shuffleIndices[i] - removedBefore;
        }
      }
    }
    assert(queueToSave.trackCount == shuffleIndices.length);
    FinampStorableQueueInfo info = FinampStorableQueueInfo.fromQueueInfo(
      queueToSave,
      withPosition ? _audioHandler.playbackPosition.inMilliseconds : null,
      playbackOrder,
      shuffleIndices,
    );
    _queuesBox.put("latest", info);
    return info;
  }

  /// Returns the saved queue history (excluding the live "latest" queue),
  /// newest first.
  List<FinampStorableQueueInfo> getRecentQueueHistory() {
    final queueMap = _queuesBox.toMap();
    queueMap.remove("latest");
    final queueList = queueMap.values.toList();
    queueList.sort((x, y) => y.creation - x.creation);
    return queueList;
  }

  /// Startup queue restore, called once from main().
  Future<void> performInitialQueueLoad() async {
    if (_savedQueueState != SavedQueueState.preInit) return;
    try {
      _savedQueueState = SavedQueueState.init;
      archiveSavedQueue(inInit: true);
      var info = _queuesBox.get("latest");
      if (info != null) {
        var keys = _queuesBox.values.map((x) => DateTime.fromMillisecondsSinceEpoch(x.creation)).toList();
        keys.sort();
        _queueServiceLogger.finest("Stored queue dates: $keys");
        if (keys.length > _maxSavedQueues) {
          var extra = keys.getRange(0, keys.length - _maxSavedQueues).map((e) => e.millisecondsSinceEpoch.toString());
          _queueServiceLogger.finest("Deleting stored queues: $extra");
          unawaited(_queuesBox.deleteAll(extra));
        }

        if (FinampSettingsHelper.finampSettings.autoloadLastQueueOnStartup && !await _hasInitialPlayLink()) {
          await loadSavedQueue(info);
        } else {
          _savedQueueState = SavedQueueState.pendingSave;
        }
      }
    } catch (e) {
      _queueServiceLogger.severe(e);
      rethrow;
    } finally {
      if (!_initialQueueLoad.isCompleted) {
        _initialQueueLoad.complete();
      }
    }
  }

  /// Completes when the startup restore finishes, and never errors.
  Future<void> get initialQueueLoaded => _initialQueueLoad.future;

  /// Waits for the startup restore, then loads the latest saved queue if that restore skipped it.
  Future<bool> ensureQueueLoaded() async {
    await _initialQueueLoad.future;
    if (_currentTrack == null && _audioHandler.audioSources.isEmpty) {
      if (_savedQueueState == SavedQueueState.failed) {
        await retryQueueLoad();
      } else if (_savedQueueState == SavedQueueState.pendingSave) {
        final info = _queuesBox.get("latest");
        if (info != null) {
          await loadSavedQueue(info);
        }
      }
    }
    return _currentTrack != null || _audioHandler.audioSources.isNotEmpty;
  }

  Future<bool> _hasInitialPlayLink() async {
    try {
      final initialLink = await AppLinks().getInitialLink();
      return initialLink != null && (initialLink.host == "play" || initialLink.host == "alarm");
    } catch (_) {
      return false;
    }
  }

  /// Push latest queue into history if it is not empty and not a duplicate.
  /// If the caller is setting the queue state to saving, that should generally
  /// occur after this is called.
  void archiveSavedQueue({bool inInit = false}) {
    if (_savedQueueState == SavedQueueState.saving || inInit) {
      var latest = _queuesBox.get("latest");
      if (latest != null && latest.trackCount != 0) {
        _queuesBox.put(latest.creation.toString(), latest);
      }
    }
  }

  Future<void> retryQueueLoad() async {
    if (_savedQueueState == SavedQueueState.failed && _failedSavedQueue != null) {
      await loadSavedQueue(_failedSavedQueue!);
    }
  }

  Future<void> loadSavedQueue(
    FinampStorableQueueInfo info, {
    Map<jellyfin_models.BaseItemId, jellyfin_models.BaseItemDto>? existingItems,
    bool isReload = false,
  }) async {
    final playbackHistoryService = GetIt.instance<PlaybackHistoryService>();
    if (_savedQueueState == SavedQueueState.loading) {
      return Future.error("A saved queue is currently loading");
    }
    _queueServiceLogger.info("Loading stored queue: $info");

    SavedQueueState finalState = SavedQueueState.failed;
    try {
      _savedQueueState = SavedQueueState.loading;
      if (info.trackCount == 0) {
        finalState = SavedQueueState.pendingSave;
        return;
      }
      refreshQueueStream();

      List<jellyfin_models.BaseItemId> allIds =
          info.previousTracks + ((info.currentTrack == null) ? [] : [info.currentTrack!]) + info.nextUp + info.queue;
      allIds.addAll(info.sourceList.where((x) => x.wantsItem).map((x) => jellyfin_models.BaseItemId(x.id)));
      Map<jellyfin_models.BaseItemId, jellyfin_models.BaseItemDto> idMap = existingItems ?? {};

      // If queue source is playlist, fetch via parent to retrieve metadata needed
      // for removal from playlist via queueItem
      if (!FinampSettingsHelper.finampSettings.isOffline) {
        for (final source in info.sourceList.where((x) => x.type == QueueItemSourceType.playlist)) {
          try {
            // Only id and type are really needed to fetch child items.  Full base item will be fetched later.
            final playlist = jellyfin_models.BaseItemDto(
              id: jellyfin_models.BaseItemId(source.id),
              type: BaseItemDtoType.playlist.jellyfinName,
            );
            var itemList =
                await _jellyfinApiHelper.getItems(
                  parentItem: playlist,
                  sortBy: "ParentIndexNumber,IndexNumber,SortName",
                  includeItemTypes: "Audio",
                ) ??
                [];
            for (var d2 in itemList) {
              idMap[d2.id] = d2;
            }
          } catch (e) {
            _queueServiceLogger.warning("Error loading queue source playlist, continuing anyway.  Error: $e");
          }
        }
      }

      // Get list of unique ids that do not yet have an associated item.
      List<jellyfin_models.BaseItemId> missingIds = allIds.toSet().difference(idMap.keys.toSet()).toList();

      if (FinampSettingsHelper.finampSettings.isOffline) {
        for (var id in missingIds) {
          jellyfin_models.BaseItemDto? item = _downloadsService.getTrackDownload(id: id)?.baseItem;
          if (item != null) {
            idMap[id] = item;
          }
        }
      } else {
        List<jellyfin_models.BaseItemDto> itemList = await _jellyfinApiHelper.getItems(itemIds: missingIds) ?? [];
        for (var d2 in itemList) {
          idMap[d2.id] = d2;
        }
      }

      int prevCount = 0;
      int curCount = 0;
      int nextCount = 0;
      int queueCount = 0;
      var previousTracks = info.previousTracks;
      var currentTracks = info.currentTrack == null ? <jellyfin_models.BaseItemId>[] : [info.currentTrack!];
      var nextTracks = info.nextUp;
      var queueTracks = info.queue;

      var order = info.shuffleOrder;
      // If order!=null, we received shuffled tracks.  Unshuffle before submitting to player.
      if (order != null && info.trackCount > 0) {
        final allTracks = previousTracks + currentTracks + nextTracks + queueTracks;
        final unshuffled = List.generate(order.length, (x) => x).map((x) => allTracks[order!.indexOf(x)]).toList();
        final currentIndex = order[previousTracks.length < allTracks.length ? previousTracks.length : 0];
        previousTracks = unshuffled.slice(0, currentIndex);
        currentTracks = unshuffled.slice(currentIndex, currentIndex + currentTracks.length);
        nextTracks = unshuffled.slice(
          currentIndex + currentTracks.length,
          currentIndex + currentTracks.length + nextTracks.length,
        );
        queueTracks = unshuffled.slice(currentIndex + currentTracks.length + nextTracks.length, order.length);
      }

      List<jellyfin_models.BaseItemDto> items = [];
      List<QueueItemSource> sources = [];
      List<int?> postDropIndices = [];
      final allSources = info.trackSources;
      int i = 0;
      int j = 0;
      void processTrack(jellyfin_models.BaseItemId id) {
        if (idMap.containsKey(id) && idMap[id] != null) {
          items.add(idMap[id]!);
          sources.add(allSources[i].withItem(idMap[jellyfin_models.BaseItemId(allSources[i].id)]));
          postDropIndices.add(j);
          j++;
        } else {
          postDropIndices.add(null);
        }
        i++;
      }

      previousTracks.forEach(processTrack);
      prevCount = items.length;
      currentTracks.forEach(processTrack);
      curCount = items.length - prevCount;
      nextTracks.forEach(processTrack);
      nextCount = items.length - curCount - prevCount;
      queueTracks.forEach(processTrack);
      queueCount = items.length - nextCount - curCount - prevCount;

      if (order != null) {
        order = order.map((x) => postDropIndices[x]).nonNulls.toList();
      }

      assert(i == info.trackCount);
      assert(j == items.length);
      assert(prevCount + curCount + nextCount + queueCount == items.length);
      assert(order == null || order.length == items.length);

      int loadedTracks = items.length;
      int droppedTracks = info.trackCount - loadedTracks;

      if (_savedQueueState != SavedQueueState.loading) {
        throw "Loading of saved Queue was interrupted.";
      }

      if (loadedTracks > 0) {
        await _replaceWholeQueue(
          isRestoredQueue: true,
          itemList: items,
          trackSources: sources,
          initialIndex: curCount > 0 || queueCount > 0 || nextCount > 0 ? prevCount : 0,
          nextUpLength: curCount == 0 ? max(0, nextCount - 1) : nextCount,
          shuffleOrder: order,
          initialSeekPosition: (info.currentTrackSeek ?? 0) > (isReload ? 500 : 5000) && curCount > 0
              ? Duration(milliseconds: info.currentTrackSeek!)
              : null,
          order: order == null ? FinampPlaybackOrder.linear : FinampPlaybackOrder.shuffled,
          beginPlaying: isReload
              ? (_audioHandler.playbackState.valueOrNull?.playing ?? false)
              : (FinampSettingsHelper.finampSettings.autoplayRestoredQueue && droppedTracks == 0),
          source: info.source.withItem(idMap[jellyfin_models.BaseItemId(info.source.id)]),
        );
      }
      _queueServiceLogger.info("Loaded saved queue.");
      if (loadedTracks > 0 || info.trackCount == 0) {
        // After loading queue, do not begin overwriting latest until the user modifies
        // the queue or begins playback.  This prevents saving unused queues that
        // had loading errors or were immediately overwritten.
        finalState = SavedQueueState.pendingSave;

        if (droppedTracks > 0) {
          GlobalSnackbar.message((scaffold) => AppLocalizations.of(scaffold)!.queueRestoreError(droppedTracks));
        }
      }
    } finally {
      // Do not overwrite state or bump reporting if loading was interrupted by the user starting a new queue
      if (_savedQueueState == SavedQueueState.loading) {
        _savedQueueState = finalState;
        if (finalState == SavedQueueState.failed) {
          _failedSavedQueue = info;
        }
        refreshQueueStream();
        await Future<void>.delayed(const Duration(seconds: 1)).then((_) {
          unawaited(playbackHistoryService.reportRestoredSessionStatus());
        });
      }
    }
  }

  // TODO cut more/all usages of this over to startSlicePlayback
  Future<void> startPlayback({
    required List<jellyfin_models.BaseItemDto> items,
    required QueueItemSource source,
    // Only used for radio startup
    QueueItemSource? customTrackSource,
    FinampPlaybackOrder? order,
    int? startingIndex,
    bool skipRadioCacheInvalidation = false,
    bool beginPlaying = true,
    bool randomizeGenerated = true,
    // Whether [items] are already in harmonic order (a harmonic Smart Shuffle or Ai DJ mix), for the Harmonic button.
    bool harmonicOrder = false,
    // With [harmonicOrder], whether that order also keeps an energy shape (a shaped Ai DJ mix), which a new harmonic
    // strength mustn't undo by ordering the whole rest of the queue.
    bool keepsShape = false,
  }) async {
    // _initialQueue = list; // save original PlaybackList for looping/restarting and meta info

    // Mixes and shuffles shouldn't play the same song twice (or its copy from a compilation).
    if (isGeneratedSource(source)) {
      final starting = startingIndex == null || startingIndex >= items.length ? null : items[startingIndex];
      final unique = withoutDuplicateSongs(items);
      if (unique.length < items.length) {
        _queueServiceLogger.info("Left out ${items.length - unique.length} duplicate songs");
        if (starting != null) {
          final key = songKey(starting);
          startingIndex = max(0, unique.indexWhere((track) => songKey(track) == key));
        }
        items = unique;
      }
    }

    await _replaceWholeQueue(
      itemList: items,
      source: source,
      customTrackSource: customTrackSource,
      order: order,
      initialIndex: startingIndex,
      skipRadioCacheInvalidation: skipRadioCacheInvalidation,
      beginPlaying: beginPlaying,
      randomizeGenerated: randomizeGenerated,
    );
    _harmonicOrderStream.add(harmonicOrder);
    _harmonicKeepsShape = harmonicOrder && keepsShape;
    _queueServiceLogger.info(
      "Started playing '${source.name.getLocalized(GlobalSnackbar.requireL10n)}' (${source.type}) in order $order from index $startingIndex",
    );
    _queueServiceLogger.info("Items for queue: [${items.map((e) => e.name).join(", ")}]");
  }

  Future<void> startSlicePlayback(PlayableSlice slice) async => _startSlicePlayback(slice: slice);

  Future<void> _startSlicePlayback({required PlayableSlice slice, bool beginPlaying = true}) async {
    await ListeningPreferences.ensureLoaded();
    // Artist spacing needs the complete pool before a generated list starts.
    if (slice is PreCachedPlayableSlice && (isGeneratedSource(slice.source) || ArtistSpacing.appliesTo(slice.source))) {
      return _startSlicePlayback(slice: await slice.resolve(), beginPlaying: beginPlaying);
    }
    switch (slice) {
      case BasePlayableSlice():
      case GroupedPlayableSlice():
      case PreCachedPlayableSlice() when slice.shuffleState == SliceShuffleState.playerShuffled:
        final base = await slice.resolve();
        final order = switch (base.shuffleState) {
          SliceShuffleState.preShuffled => FinampPlaybackOrder.linear,
          SliceShuffleState.playerShuffled => FinampPlaybackOrder.shuffled,
          SliceShuffleState.linear => FinampPlaybackOrder.linear,
        };
        await _replaceWholeQueue(
          itemList: base.items,
          source: base.source,
          order: order,
          initialIndex: order == FinampPlaybackOrder.linear ? base.startingIndex : null,
          beginPlaying: beginPlaying,
          randomizeGenerated: base.shuffleState != SliceShuffleState.preShuffled,
        );
        _queueServiceLogger.info(
          "Started playing '${base.source.name.getLocalized(GlobalSnackbar.requireL10n)}' (${base.source.type}) in order $order from index ${base.startingIndex}",
        );
        _queueServiceLogger.info("Items for queue: [${base.items.map((e) => e.name).join(", ")}]");
      // TODO also do pre-cache work in other queue add methods?
      case PreCachedPlayableSlice slice:
        // Shuffle state is linear or preshuffled, so ignore.
        await _replaceWholeQueue(
          itemList: slice.cachedTracks,
          source: slice.source,
          order: FinampPlaybackOrder.linear,
          initialIndex: slice.startingOffset,
          beginPlaying: beginPlaying,
        );
        _queueServiceLogger.info(
          "Started playing '${slice.source.name.getLocalized(GlobalSnackbar.requireL10n)}' (${slice.source.type}), pending additional tracks",
        );
        _queueServiceLogger.info("Items for queue: [${slice.cachedTracks.map((e) => e.name).join(", ")}]");
        final additionalTracks = List.of(await slice.fetchTracks);
        if (!slice.combineTracks) {
          assert(() {
            for (int i = 0; i < slice.cachedTracks.length; i++) {
              if (slice.cachedTracks[i] != additionalTracks[i]) {
                return false;
              }
            }
            return true;
          }());
          for (var track in slice.cachedTracks) {
            additionalTracks.remove(track);
          }
        }
        // TODO verify we haven't made other queue changes?
        await _insertFollowupItems(additionalTracks, slice.source, slice.cachedTracks.length);
    }
  }

  /// Replaces the queue with the given list of items. If startAtIndex is specified, Any items below it
  /// will be ignored. This is used for when the user taps in the middle of an album to start from that point.
  Future<void> _replaceWholeQueue({
    required List<jellyfin_models.BaseItemDto> itemList,
    required QueueItemSource source,
    QueueItemSource? customTrackSource,
    List<QueueItemSource?>? trackSources,
    int? initialIndex,
    int? nextUpLength,
    List<int>? shuffleOrder,
    Duration? initialSeekPosition,
    FinampPlaybackOrder? order,
    bool beginPlaying = true,
    bool isRestoredQueue = false,
    bool skipRadioCacheInvalidation = false,
    bool randomizeGenerated = true,
  }) async {
    if (!isRestoredQueue && trackSources == null && shuffleOrder == null) {
      if (isGeneratedSource(source)) {
        await ListeningPreferences.ensureLoaded();
        final selected = initialIndex == null ? null : itemList.elementAtOrNull(initialIndex);
        itemList = itemList.where((item) => item.id == selected?.id || ListeningPreferences.permits(item)).toList();
        if (itemList.isEmpty) throw ServerHubException(GlobalSnackbar.requireL10n.listeningAllResting);
        itemList = await ServerHealthGuard.filter(itemList);
        if (selected != null) initialIndex = max(0, itemList.indexWhere((item) => item.id == selected.id));
        if (itemList.isEmpty) {
          throw const ServerHubException(
            'No playable recordings remain in this mix. Review Audio health in Server hub.',
          );
        }
      }
      if (initialIndex == null &&
          (const {QueueItemSourceType.allTracks, QueueItemSourceType.favorites}.contains(source.type) ||
              (source.type == QueueItemSourceType.genre && order == FinampPlaybackOrder.shuffled))) {
        itemList = ShuffleRandomness.libraryOrder(itemList);
      }
      if (randomizeGenerated && isGeneratedSource(source) && order != FinampPlaybackOrder.shuffled) {
        final start = initialIndex;
        itemList = start == null
            ? ShuffleRandomness.order(itemList, FinampSettingsHelper.finampSettings.shuffleRandomness)
            : [
                ...itemList.take(start + 1),
                ...ShuffleRandomness.order(
                  itemList.skip(start + 1).toList(),
                  FinampSettingsHelper.finampSettings.shuffleRandomness,
                ),
              ];
      }
      final prepared = ArtistSpacing.prepareStart(itemList, source, startingIndex: initialIndex);
      if (prepared.items.length < itemList.length) {
        _queueServiceLogger.info(
          "Artist spacing left out ${itemList.length - prepared.items.length} tracks that would repeat the previous artist",
        );
      }
      itemList = prepared.items;
      if (order != FinampPlaybackOrder.shuffled || initialIndex != null) initialIndex = prepared.startingIndex;
    }
    if (trackSources != null) {
      if (trackSources.length != itemList.length) {
        _queueServiceLogger.severe(
          "trackSources length (${trackSources.length}) does not match itemList length (${itemList.length})",
        );
        assert(false);
        trackSources = null;
      }
    }
    if (shuffleOrder != null) {
      if (shuffleOrder.length != itemList.length ||
          shuffleOrder.toSet().length != itemList.length ||
          shuffleOrder.any((x) => x < 0 || x >= shuffleOrder!.length)) {
        _queueServiceLogger.severe(
          "received invalid shuffleOrder $shuffleOrder for  itemList length (${itemList.length})",
        );
        // If an invalid shuffleOrder is received in release mode, ignore it and continue.  But if we are
        // in debug mode, throw.
        assert(false);
        shuffleOrder = null;
      }
    }

    try {
      if (itemList.isEmpty) {
        _queueServiceLogger.warning("Cannot start playback of empty queue! Source: $source");
        return;
      }

      if (!skipRadioCacheInvalidation) {
        invalidateRadioCache();
      }

      order ??= FinampPlaybackOrder.linear;

      nextUpLength ??= 0;

      if (initialIndex == null) {
        if (order != FinampPlaybackOrder.shuffled) initialIndex = 0;
      }

      if (order == FinampPlaybackOrder.shuffled && shuffleOrder == null) {
        shuffleOrder = ShuffleRandomness.indices(
          itemList,
          ArtistSpacing.artistKey,
          FinampSettingsHelper.finampSettings.shuffleRandomness,
          initialIndex: initialIndex,
          nextUpLength: nextUpLength,
          allowArtistRepeats: ArtistSpacing.allowsRepeats(source),
        );
        initialIndex = shuffleOrder.first;
      }
      initialIndex ??= 0;

      if (initialIndex >= itemList.length) {
        throw "initialIndex is bigger than the itemList! ($initialIndex >= ${itemList.length})";
      }

      if (initialIndex + nextUpLength >= itemList.length) {
        throw "nextUpLength is longer than available items! ($nextUpLength >= ${itemList.length - initialIndex})";
      }

      _queueServiceLogger.info("Replacing whole queue with ${itemList.length} items.");

      if (!isRestoredQueue) {
        archiveSavedQueue();
        _savedQueueState = SavedQueueState.saving;
      }

      List<FinampQueueItem> newItems = [];
      List<int> newLinearOrder = [];
      List<int> newShuffledOrder;
      for (int i = 0; i < itemList.length; i++) {
        final jellyfin_models.BaseItemDto item = itemList[i];
        try {
          MediaItem mediaItem = await generateMediaItem(
            item,
            contextNormalizationGain: isRestoredQueue ? null : source.contextNormalizationGain,
          );
          newItems.add(
            FinampQueueItem(
              item: mediaItem,
              source: trackSources?[i] ?? (isRestoredQueue ? savedQueueSource : customTrackSource ?? source),
              type: switch (i) {
                _ when i < initialIndex => QueueItemQueueType.previousTracks,
                _ when i == initialIndex => QueueItemQueueType.currentTrack,
                _ when i <= initialIndex + nextUpLength => QueueItemQueueType.nextUp,
                _ => QueueItemQueueType.queue,
              },
            ),
          );
          newLinearOrder.add(i);
        } catch (e, trace) {
          _queueServiceLogger.severe(e, e, trace);
        }
      }

      if (newItems.isEmpty) {
        _queueServiceLogger.warning("No tracks could be prepared for playback. Source: $source");
        return;
      }
      if (newItems.length != itemList.length) {
        final retained = ShuffleRandomness.retainPlayableIndices(
          shuffleOrder ?? List.generate(itemList.length, (i) => i),
          newLinearOrder,
          initialIndex: initialIndex,
          nextUpLength: nextUpLength,
        );
        if (newLinearOrder[retained.initialIndex] != initialIndex) initialSeekPosition = null;
        initialIndex = retained.initialIndex;
        nextUpLength = retained.nextUpLength;
        if (shuffleOrder != null) shuffleOrder = retained.indices;
        newLinearOrder = List.generate(newItems.length, (i) => i);
        for (final (index, item) in newItems.indexed) {
          item.type = index < initialIndex
              ? QueueItemQueueType.previousTracks
              : index == initialIndex
              ? QueueItemQueueType.currentTrack
              : index <= initialIndex + nextUpLength
              ? QueueItemQueueType.nextUp
              : QueueItemQueueType.queue;
        }
      }

      _queue.clear(); // empty queue
      _queuePreviousTracks.clear();
      _queueNextUp.clear();
      _currentTrack = null;
      playlistRemovalsCache.clear();

      if (Platform.isIOS || Platform.isMacOS) {
        // Both iOS and macOS will start playing the first queue index if we don't stop first.
        // Use pause() instead of stop() to keep the audio session active and prevent
        // other apps (e.g. Podcasts) from briefly resuming during Siri handoff.
        // Server activity reporting: pause() sends a progress update (paused state)
        // rather than a stop event; when the new queue starts, onTrackChanged fires
        // and correctly reports the old track stopped + new track started.
        await _audioHandler.pause();
      }
      await _audioHandler.clearFinampQueueItems();

      _playbackStart = (queueItemId: newItems[initialIndex].id, position: initialSeekPosition ?? Duration.zero);
      await duringPlayerReload(initialIndex, () async {
        // block _buildQueueFromNativePlayerQueue until both new sequence
        // and intial index have been applied.
        await _audioHandler.setQueueItems(
          newItems,
          initialIndex: initialIndex,
          preload: true,
          shuffleOrder: _shuffleOrder,
          initialPosition: initialSeekPosition ?? Duration.zero,
        );
      });

      //!!! keep this roughly here so the player screen opens to the correct track, but doesn't seem laggy
      if (beginPlaying) {
        // only open the player screen if we actually start playing, otherwise it would open after startup + queue restore
        if (FinampSettingsHelper.finampSettings.autoExpandPlayerScreen) {
          if (GlobalSnackbar.navigatorState?.mounted ?? false) {
            unawaited(NowPlayingBar.openPlayerScreen());
          }
        }
      }

      newShuffledOrder = List.from(_audioHandler.shuffleIndices);

      _order = FinampQueueOrder(
        items: newItems,
        originalSource: source,
        linearOrder: newLinearOrder,
        shuffledOrder: newShuffledOrder,
        sourceLibrary: _finampUserHelper.currentUser?.currentView,
      );

      _queueServiceLogger.fine("Order items length: ${_order.items.length}");

      // set playback order to trigger shuffle if necessary (fixes indices being wrong when starting with shuffle enabled)
      // this will run _queueFromConcatenatingAudioSource();
      await setPlaybackOrder(order, shuffleOrder: shuffleOrder);

      if (beginPlaying) {
        // don't await this, because it will not return until playback is finished
        unawaited(_audioHandler.play(disableFade: true));
      } else if (!Platform.isAndroid && !Platform.isIOS) {
        unawaited(_audioHandler.pause(disableFade: true));
      }
    } catch (e) {
      _queueServiceLogger.severe("Error while initializing queue: $e", e);
    }
  }

  Future<void> reloadQueue({bool archiveQueue = false}) async {
    _queueServiceLogger.info("Reloading queue");

    if (_audioHandler.audioSources.isEmpty) {
      return Future.error("Queue is empty, cannot reload!");
    }

    _saveCurrentQueue(withPosition: true);
    if (archiveQueue) {
      archiveSavedQueue();
    }

    var info = _queuesBox.get("latest");
    if (info != null) {
      final Map<jellyfin_models.BaseItemId, jellyfin_models.BaseItemDto> existingItems = {};
      final queueInfo = getQueue();

      // re-use items in online mode, re-fetch from downloads service in offline mode (will happen later on)
      if (!FinampSettingsHelper.finampSettings.isOffline) {
        for (var item in queueInfo.fullQueue) {
          existingItems[item.baseItemId] = item.baseItem;
        }
      }

      await loadSavedQueue(info, existingItems: existingItems, isReload: true);
    }
  }

  Future<void> stopAndClearQueue() async {
    queueServiceLogger.info("Stopping playback");

    archiveSavedQueue();
    if (_savedQueueState == SavedQueueState.pendingSave) {
      _savedQueueState = SavedQueueState.saving;
    }

    // avoid radio eagerly adding new tracks from cache (or requesting new tracks) right after the queue is cleared
    final previousRadioState = FinampSettingsHelper.finampSettings.radioEnabled;
    FinampSetters.setRadioEnabled(false);
    invalidateRadioCache();

    await _audioHandler.clearFinampQueueItems();

    await _audioHandler.stopPlayback();

    _buildQueueFromNativePlayerQueue();
    // await _audioHandler.initializeAudioSource(_queueAudioSource,
    //     preload: false);

    FinampSetters.setRadioEnabled(previousRadioState);

    return;
  }

  List<jellyfin_models.BaseItemDto> _prepareGeneratedSlice(
    BasePlayableSlice slice, {
    jellyfin_models.BaseItemDto? previous,
    bool pinFirst = false,
  }) {
    var items = slice.items;
    if (isGeneratedSource(slice.source) && slice.shuffleState == SliceShuffleState.linear) {
      if (const {QueueItemSourceType.allTracks, QueueItemSourceType.favorites}.contains(slice.source.type)) {
        items = ShuffleRandomness.libraryOrder(items);
      }
      items = ShuffleRandomness.order(items, FinampSettingsHelper.finampSettings.shuffleRandomness);
    }
    return ArtistSpacing.generated(items, slice.source, previous: previous, keepFirst: pinFirst);
  }

  Future<void> addToQueue(PlayableSlice slice, {jellyfin_models.BaseItemDto? afterTrack}) async {
    if (_audioHandler.audioSources.isEmpty) {
      return _startSlicePlayback(slice: slice, beginPlaying: false);
    }
    await _appendToQueue(slice, afterTrack: afterTrack);
  }

  /// Radio needs the actual appended items, and must not populate a replaced or cleared queue.
  Future<List<jellyfin_models.BaseItemDto>> addRadioTracks(
    BasePlayableSlice slice, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent() || _audioHandler.audioSources.isEmpty) return [];
    return _appendToQueue(slice, isCurrent: isCurrent);
  }

  Future<List<jellyfin_models.BaseItemDto>> _appendToQueue(
    PlayableSlice slice, {
    jellyfin_models.BaseItemDto? afterTrack,
    bool Function()? isCurrent,
    bool pinFirst = false,
  }) async {
    await ListeningPreferences.ensureLoaded();
    final baseSlice = await slice.resolve(preShuffle: true);
    if (isCurrent?.call() == false) return [];
    final info = getQueue();
    final previous = afterTrack ?? (info.queue.lastOrNull ?? info.nextUp.lastOrNull ?? info.currentTrack)?.baseItem;
    var items = _prepareGeneratedSlice(baseSlice, previous: previous, pinFirst: pinFirst);
    if (isGeneratedSource(slice.source)) {
      items = await ServerHealthGuard.filter(items);
      items = ArtistSpacing.generated(items, slice.source, previous: previous, keepFirst: pinFirst);
    }
    if (isCurrent?.call() == false) return [];
    if (items.isEmpty) return [];

    try {
      if (_savedQueueState == SavedQueueState.pendingSave) {
        _savedQueueState = SavedQueueState.saving;
      }
      List<FinampQueueItem> queueItems = [];
      for (final item in items) {
        queueItems.add(
          FinampQueueItem(
            item: await generateMediaItem(item, contextNormalizationGain: slice.source.contextNormalizationGain),
            source: slice.source,
            type: QueueItemQueueType.queue,
          ),
        );
      }

      _queueServiceLogger.fine(
        "Added ${items.length} items to queue from '${slice.source.name}' (${slice.source.type})",
      );

      if (isCurrent?.call() == false) return [];
      await _audioHandler.appendFinampQueueItems(queueItems);

      _buildQueueFromNativePlayerQueue(); // update internal queues
      return items;
    } catch (e) {
      _queueServiceLogger.severe(e);
      rethrow;
    }
  }

  Future<void> addNext(PlayableSlice slice) async {
    if (_audioHandler.audioSources.isEmpty) {
      return _startSlicePlayback(slice: slice, beginPlaying: false);
    }
    final baseSlice = await slice.resolve(preShuffle: true);
    final items = _prepareGeneratedSlice(baseSlice, previous: getCurrentTrack()?.baseItem);
    if (items.isEmpty) return;

    try {
      if (_savedQueueState == SavedQueueState.pendingSave) {
        _savedQueueState = SavedQueueState.saving;
      }
      List<FinampQueueItem> queueItems = [];
      for (final item in items) {
        queueItems.add(
          FinampQueueItem(
            item: await generateMediaItem(item, contextNormalizationGain: slice.source.contextNormalizationGain),
            source: slice.source,
            type: QueueItemQueueType.nextUp,
          ),
        );
      }

      int adjustedQueueIndex = getActualIndexByLinearIndex(_currentQueueIndex);
      int offset = min(_audioHandler.audioSources.length, 1);
      _queueServiceLogger.fine(
        "Prepended ${items.length} items to Next Up at index ${adjustedQueueIndex + offset} from '${slice.source.name}' (${slice.source.type})",
      );
      await _audioHandler.insertFinampQueueItems(adjustedQueueIndex + offset, queueItems);

      _buildQueueFromNativePlayerQueue(); // update internal queues
    } catch (e) {
      _queueServiceLogger.severe(e);
      rethrow;
    }
  }

  Future<void> addToNextUp(PlayableSlice slice) async {
    if (_audioHandler.audioSources.isEmpty) {
      return _startSlicePlayback(slice: slice, beginPlaying: false);
    }
    final baseSlice = await slice.resolve(preShuffle: true);
    final info = getQueue();
    final previous = (info.nextUp.lastOrNull ?? info.currentTrack)?.baseItem;
    var items = _prepareGeneratedSlice(baseSlice, previous: previous);
    if (isGeneratedSource(slice.source)) {
      items = await ServerHealthGuard.filter(items);
      items = ArtistSpacing.generated(items, slice.source, previous: previous);
    }
    if (items.isEmpty) return;

    try {
      if (_savedQueueState == SavedQueueState.pendingSave) {
        _savedQueueState = SavedQueueState.saving;
      }
      List<FinampQueueItem> queueItems = [];
      for (final item in items) {
        queueItems.add(
          FinampQueueItem(
            item: await generateMediaItem(item, contextNormalizationGain: slice.source.contextNormalizationGain),
            source: slice.source,
            type: QueueItemQueueType.nextUp,
          ),
        );
      }

      _buildQueueFromNativePlayerQueue(logUpdate: false); // update internal queues
      int offset = _queueNextUp.length + min(_audioHandler.audioSources.length, 1);

      int adjustedQueueIndex = getActualIndexByLinearIndex(_currentQueueIndex);
      _queueServiceLogger.fine(
        "Appended ${items.length} items to Next Up at index ${adjustedQueueIndex + offset} from '${slice.source.name}' (${slice.source.type})",
      );
      await _audioHandler.insertFinampQueueItems(adjustedQueueIndex + offset, queueItems);

      _buildQueueFromNativePlayerQueue(); // update internal queues
    } catch (e) {
      _queueServiceLogger.severe(e);
      rethrow;
    }
  }

  Future<void> _insertFollowupItems(
    List<jellyfin_models.BaseItemDto> items,
    QueueItemSource source,
    int previousItems,
  ) async {
    if (_audioHandler.audioSources.isEmpty) {
      assert(
        false,
        "PreCachedPlayableSlice should always have enough tracks to begin playback.  Was the queue manually cleared?",
      );
      _queueServiceLogger.info("Queue was already empty when inserting followup items");
      return;
    }
    List<FinampQueueItem> queueItems = [];
    for (final item in items) {
      queueItems.add(
        FinampQueueItem(
          item: await generateMediaItem(item, contextNormalizationGain: source.contextNormalizationGain),
          source: source,
          type: QueueItemQueueType.queue,
        ),
      );
    }

    _buildQueueFromNativePlayerQueue(logUpdate: false); // update internal queues

    if (_playbackOrder == FinampPlaybackOrder.shuffled) {
      // If the queue was shuffled between playback start and followup items loading, we don't currently have any good options
      // We will just shuffle the items and add them to the end of the queue.  This will prevent unshuffling, and it
      // will still leave all of the first set of tracks shuffled before the followup set, but it should be better
      // than playing back unshuffled.
      queueItems = ShuffleRandomness.order(queueItems, FinampSettingsHelper.finampSettings.shuffleRandomness);
      if (!ArtistSpacing.allowsRepeats(source)) {
        final info = getQueue();
        final previous = (info.queue.lastOrNull ?? info.nextUp.lastOrNull ?? info.currentTrack)?.baseItem;
        queueItems = ArtistSpacing.order(
          queueItems,
          (track) => ArtistSpacing.artistKey(track.baseItem),
          previousKey: previous == null ? null : ArtistSpacing.artistKey(previous),
          keepFirst: false,
        );
      }

      _queueServiceLogger.info(
        "Added ${items.length} followup items to shuffled queue from '${source.name}' (${source.type})",
      );

      await _audioHandler.appendFinampQueueItems(queueItems);
    } else {
      int offset = previousItems + _queueNextUp.length;
      int adjustedQueueIndex = getActualIndexByLinearIndex(_currentQueueIndex);
      int earliestQueueOffset = adjustedQueueIndex + _queueNextUp.length + min(_audioHandler.audioSources.length, 1);
      offset = offset.clamp(earliestQueueOffset, _audioHandler.audioSources.length);

      _queueServiceLogger.info(
        "Inserted ${items.length} followup items into queue at index $offset from '${source.name}' (${source.type})",
      );

      await _audioHandler.insertFinampQueueItems(offset, queueItems);
    }

    _buildQueueFromNativePlayerQueue(); // update internal queues
  }

  Future<void> skipByOffset(int offset) async {
    await _audioHandler.skipByOffset(offset);
  }

  Future<void> removeAtOffset(int offset) async {
    int adjustedQueueIndex = getActualIndexByLinearIndex(_currentQueueIndex + offset);

    await _audioHandler.removeFinampQueueItemAt(adjustedQueueIndex);
    _buildQueueFromNativePlayerQueue();
  }

  /// This function removes all upcoming radio tracks.
  Future<void> retuneRadio({jellyfin_models.BaseItemDto? seed, bool replaceQueued = false}) async {
    if (replaceQueued) archiveSavedQueue();
    if (seed != null) {
      _order.originalSource = QueueItemSource.fromBaseItem(
        seed,
        type: QueueItemSourceType.radio,
        library: _order.originalSource.library,
        djStationId: _order.originalSource.djStationId,
      );
    }
    await clearRadioTracks(allQueued: replaceQueued);
    _buildQueueFromNativePlayerQueue();
    await maybeAddRadioTracks();
  }

  /// This function removes all upcoming radio tracks.
  /// Callers should set up correct radio state synchronously before calling this,
  /// so that we will be ready for the radio to restart as soon as this function releases its lock.
  /// i.e., there's a chance for [maybeAddRadioTracks] to fire in the async gap after the lock releases before the caller regains execution, so the radio settings should be set up beforehand so that the state doesn't get invalidated immediately.
  Future<void> clearRadioTracks({bool allQueued = false}) async {
    _queueServiceLogger.finer("Clearing radio tracks from queue.");
    await withRadioLock(() async {
      final radioIndices = _queue
          .asMap()
          .entries
          .where((entry) {
            return allQueued || entry.value.source.type == QueueItemSourceType.radio;
          })
          .map((entry) => entry.key)
          .toList();
      if (radioIndices.isEmpty) {
        return;
      }
      List<int> adjustedIndicesToRemove = [];
      for (final index in radioIndices) {
        int adjustedQueueIndex = getActualIndexByLinearIndex(_currentQueueIndex + _queueNextUp.length + index + 1);
        adjustedIndicesToRemove.add(adjustedQueueIndex);
      }
      int currentRangeEnd = adjustedIndicesToRemove.last;
      int currentRangeStart = currentRangeEnd;
      // remove from the back to avoid index shifting
      for (final adjustedIndex in adjustedIndicesToRemove.reversed.skip(1)) {
        if (adjustedIndex == currentRangeStart - 1 && adjustedIndex != adjustedIndicesToRemove.first) {
          currentRangeStart = adjustedIndex;
        } else {
          // remove in batches to improve performance
          await _audioHandler.removeFinampQueueItemRange(adjustedIndex, currentRangeEnd + 1);
          currentRangeStart = adjustedIndex;
          currentRangeEnd = adjustedIndex;
        }
      }
      _buildQueueFromNativePlayerQueue();
    });
  }

  /// Replaces the upcoming tracks with [slice] without interrupting the current track.
  /// [pinFirst] preserves an explicitly picked first song through artist spacing.
  Future<void> replaceUpcoming(PlayableSlice slice, {bool pinFirst = false}) async {
    if (_audioHandler.audioSources.isEmpty || _currentTrack == null) {
      return _startSlicePlayback(slice: slice);
    }

    final upcomingCount = _queueNextUp.length + _queue.length;

    archiveSavedQueue();

    _order.originalSource = slice.source;

    await _appendToQueue(slice, afterTrack: _currentTrack?.baseItem, pinFirst: pinFirst);

    final adjustedIndicesToRemove = List.generate(
      upcomingCount,
      (index) => getActualIndexByLinearIndex(_currentQueueIndex + index + 1),
    )..sort();

    if (upcomingCount > 0) {
      int currentRangeEnd = adjustedIndicesToRemove.last;
      int currentRangeStart = currentRangeEnd;
      // remove from the back to avoid index shifting
      for (final adjustedIndex in adjustedIndicesToRemove.reversed.skip(1)) {
        if (adjustedIndex == currentRangeStart - 1) {
          currentRangeStart = adjustedIndex;
        } else {
          // remove in batches to improve performance
          await _audioHandler.removeFinampQueueItemRange(currentRangeStart, currentRangeEnd + 1);
          currentRangeStart = adjustedIndex;
          currentRangeEnd = adjustedIndex;
        }
      }
      await _audioHandler.removeFinampQueueItemRange(currentRangeStart, currentRangeEnd + 1);
    }

    _buildQueueFromNativePlayerQueue();

    _queueServiceLogger.fine("Replaced $upcomingCount upcoming items with items from '${slice.source.name}'");
  }

  Future<void> removeQueueItem(FinampQueueItem queueItem) async {
    int? offset = getQueue().getOffsetForQueueItem(queueItem);
    if (offset == null) {
      return;
    }
    return removeAtOffset(offset);
  }

  Future<void> reorderByOffset(int oldOffset, int newOffset) async {
    _queueServiceLogger.fine("Reordering queue item at offset $oldOffset to offset $newOffset");

    if (playbackOrder == FinampPlaybackOrder.shuffled) {
      final newShuffleOrder = [..._shuffleOrder.indices];
      final int itemToMove = newShuffleOrder.removeAt(_currentQueueIndex + oldOffset);
      newShuffleOrder.insert(_currentQueueIndex + newOffset, itemToMove);
      try {
        _shuffleOrder.overrideShuffle(newShuffleOrder);
        await _audioHandler.shuffle();
      } finally {
        _shuffleOrder.overrideShuffle(null);
      }
    } else {
      final oldIndex = _currentQueueIndex + oldOffset;
      final newIndex = _currentQueueIndex + newOffset;

      await _audioHandler.moveFinampQueueItem(oldIndex, newIndex);
    }

    _buildQueueFromNativePlayerQueue();
  }

  Future<void> clearNextUp() async {
    int adjustedQueueIndex = getActualIndexByLinearIndex(_currentQueueIndex);

    // remove all items from Next Up
    if (_queueNextUp.isNotEmpty) {
      await _audioHandler.removeFinampQueueItemRange(
        adjustedQueueIndex + 1,
        adjustedQueueIndex + 1 + _queueNextUp.length,
      );
      _queueNextUp.clear();
    }

    _buildQueueFromNativePlayerQueue(); // update internal queues
  }

  FinampQueueInfo getQueue() {
    return FinampQueueInfo(
      id: _order.id,
      previousTracks: _queuePreviousTracks,
      currentTrack: _currentTrack,
      queue: _queue,
      nextUp: _queueNextUp,
      source: _order.originalSource,
      saveState: _savedQueueState,
      sourceLibrary: _order.sourceLibrary,
      playbackStart: _playbackStart,
    );
  }

  BehaviorSubject<FinampQueueInfo?> getQueueStream() {
    return _queueStream;
  }

  static final _queueInfoStreamProvider = StreamProvider<FinampQueueInfo?>((ref) {
    final service = GetIt.instance<QueueService>();
    return service.getQueueStream();
  });

  static final queueProvider = Provider<FinampQueueInfo?>((ref) {
    return ref.watch(_queueInfoStreamProvider).value ?? GetIt.instance<QueueService>().getQueue();
  });

  void refreshQueueStream() {
    _queueStream.add(getQueue());
  }

  /// Returns the entire queue (Next Up + regular queue)
  /// If [next] is provided (and greater than 0), at most [next] QueueItems from Next Up and the regular queue will be returned
  /// If [previous] is provided (and greater than 0), at most [previous] QueueItems from previous tracks will be additionally returned.
  /// The length of the returned list may be less than the sum of [next] and [previous] if there are not enough items in the queue
  List<FinampQueueItem> peekQueue({int? next, int previous = 0, bool current = false}) {
    List<FinampQueueItem> nextTracks = [];
    if (_queuePreviousTracks.isNotEmpty && previous > 0) {
      nextTracks.addAll(
        _queuePreviousTracks.sublist(max(0, _queuePreviousTracks.length - previous), _queuePreviousTracks.length),
      );
    }
    if (_currentTrack != null && current) {
      nextTracks.add(_currentTrack!);
    }
    if (_queueNextUp.isNotEmpty) {
      if (next == null) {
        nextTracks.addAll(_queueNextUp);
      } else {
        nextTracks.addAll(_queueNextUp.sublist(0, min(next, _queueNextUp.length)));
        next -= _queueNextUp.length;
      }
    }
    if (_queue.isNotEmpty) {
      if (next == null) {
        nextTracks.addAll(_queue);
      } else if (next > 0) {
        nextTracks.addAll(_queue.sublist(0, min(next, _queue.length)));
      }
    }
    return nextTracks;
  }

  BehaviorSubject<FinampPlaybackOrder> getPlaybackOrderStream() {
    return _playbackOrderStream;
  }

  BehaviorSubject<FinampLoopMode> getLoopModeStream() {
    return _loopModeStream;
  }

  BehaviorSubject<double> getPlaybackSpeedStream() {
    return _playbackSpeedStream;
  }

  BehaviorSubject<FinampQueueItem?> getCurrentTrackStream() {
    return _currentTrackStream;
  }

  FinampQueueItem? getCurrentTrack() {
    return _currentTrack;
  }

  set playbackSpeed(double speed) {
    _playbackSpeed = speed;
    _playbackSpeedStream.add(speed);
    _audioHandler.setSpeed(speed);
    FinampSetters.setPlaybackSpeed(playbackSpeed);
    _queueServiceLogger.fine("Playback speed set to ${FinampSettingsHelper.finampSettings.playbackSpeed}");
    if (FinampSettingsHelper.finampSettings.syncPlaybackSpeedAndPitch) {
      playbackPitch = speed;
    }
  }

  double get playbackSpeed => _playbackSpeed;

  set playbackPitch(double pitch) {
    _playbackPitch = pitch;
    _playbackPitchStream.add(pitch);
    _audioHandler.setPitch(pitch);
    FinampSetters.setPlaybackPitch(playbackPitch);
    _queueServiceLogger.fine("Playback pitch set to ${FinampSettingsHelper.finampSettings.playbackPitch}");
  }

  double get playbackPitch => _playbackPitch;

  set loopMode(FinampLoopMode mode) {
    _loopMode = mode;

    _loopModeStream.add(mode);
    if (FinampSettingsHelper.finampSettings.radioEnabled) {
      // we disable looping in the player while the radio is enabled
      // so that we can pause on the current track if we ever run out of radio tracks
      _audioHandler.setRepeatMode(AudioServiceRepeatMode.none);
    } else {
      if (mode == FinampLoopMode.one) {
        _audioHandler.setRepeatMode(AudioServiceRepeatMode.one);
      } else if (mode == FinampLoopMode.all) {
        _audioHandler.setRepeatMode(AudioServiceRepeatMode.all);
      } else {
        _audioHandler.setRepeatMode(AudioServiceRepeatMode.none);
      }
    }

    FinampSetters.setLoopMode(loopMode);
    _queueServiceLogger.fine("Loop mode set to ${FinampSettingsHelper.finampSettings.loopMode}");
  }

  FinampLoopMode get loopMode => _loopMode;

  Future<void> setPlaybackOrder(FinampPlaybackOrder order, {List<int>? shuffleOrder}) async {
    _playbackOrder = order;
    _queueServiceLogger.fine("Playback order set to $order");

    _playbackOrderStream.add(order);
    _harmonicOrderStream.add(false);

    // update queue accordingly and generate new shuffled order if necessary
    final AudioServiceShuffleMode mode;
    if (_playbackOrder == FinampPlaybackOrder.shuffled) {
      if (shuffleOrder != null) {
        // shuffleOrder does not need to be applied when switching to linear
        // mode, as we will reshuffle if we later switch over to shuffle mode.
        try {
          _shuffleOrder.overrideShuffle(shuffleOrder);
          await _audioHandler.shuffle();
        } finally {
          _shuffleOrder.overrideShuffle(null);
        }
      } else {
        await _audioHandler.shuffle();
      }
      mode = AudioServiceShuffleMode.all;
    } else {
      mode = AudioServiceShuffleMode.none;
    }
    await _audioHandler.setShuffleMode(mode);
    //await _audioHandler.playbackState.where((event) => event.shuffleMode == mode).first;
    _buildQueueFromNativePlayerQueue();
    await _audioHandler.refreshPlaybackStateAndMediaNotification();
  }

  FinampPlaybackOrder get playbackOrder => _playbackOrder;

  Future<void> togglePlaybackOrder() {
    if (_playbackOrder == FinampPlaybackOrder.shuffled) {
      return setPlaybackOrder(FinampPlaybackOrder.linear);
    } else {
      return setPlaybackOrder(FinampPlaybackOrder.shuffled);
    }
  }

  BehaviorSubject<bool> getHarmonicOrderStream() => _harmonicOrderStream;

  bool get harmonicOrder => _harmonicOrderStream.value;

  /// One at a time; asked for again while it's being worked out (say, at a new harmonic strength), it's done once more
  /// when that finishes.
  late final _orderHarmonicallyAgain = RunAgain(_orderHarmonically);

  /// Whether the queue's harmonic order came with an energy shape (see [startPlayback]'s keepsShape).
  bool _harmonicKeepsShape = false;

  /// Puts the songs after the current one (and after Next up) in harmonic order, each flowing into the next in key
  /// and tempo, or with [enabled] false shuffles them as usual. Earlier songs, the current one and Next up stay put.
  /// Returns false when too few of those songs have been analysed to order them.
  Future<bool> setHarmonicOrder(bool enabled) async {
    if (!enabled) {
      await setPlaybackOrder(FinampPlaybackOrder.shuffled);
      return true;
    }
    // Asked for, so the whole rest of the queue goes in harmonic order, whatever shape it had.
    _harmonicKeepsShape = false;
    // Done again with the latest strength, unless harmonic order was turned off meanwhile.
    return _orderHarmonicallyAgain(whileRunning: true, wanted: () => harmonicOrder);
  }

  /// Puts the rest of the queue in harmonic order again (say, at a new harmonic strength) when it's in harmonic order
  /// or being put in it. While that's being applied the queue briefly isn't [harmonicOrder], so that alone isn't enough.
  /// A shaped Ai DJ mix keeps its energy shape instead.
  Future<void> refreshHarmonicOrder() async {
    if (_harmonicKeepsShape) return;
    if (harmonicOrder || _orderHarmonicallyAgain.running) await setHarmonicOrder(true);
  }

  Future<bool> _orderHarmonically() async {
    final sequence = _audioHandler.sequenceState.sequence.map((e) => e.tag as FinampQueueItem).toList();
    final shuffleIndices = _audioHandler.sequenceState.shuffleIndices;
    // Positions in play order, each pointing at its song in the player's sequence.
    final order = _playbackOrder == FinampPlaybackOrder.shuffled && shuffleIndices.length == sequence.length
        ? [...shuffleIndices]
        : List.generate(sequence.length, (i) => i);
    final current = _currentQueueIndex;
    if (current < 0 || current >= order.length) return false;
    var restStart = current + 1;
    while (restStart < order.length && sequence[order[restStart]].type == QueueItemQueueType.nextUp) {
      restStart++;
    }
    final rest = order.sublist(restStart);
    // Nothing to reorder, so it's already as harmonic as it gets.
    if (rest.length < 2) {
      _harmonicOrderStream.add(true);
      return true;
    }
    final reordered = await DjTransitionService.harmonicContinuation(
      order[restStart - 1],
      rest,
      (index) => sequence[index].baseItem,
      strength: HarmonicMixing.strength.value,
      allowArtistRepeats: ArtistSpacing.allowsRepeats(sequence[order[current]].source),
    );
    if (reordered == null) return false;
    // The queue may have moved on while the analysis loaded; only apply the order to the queue it was made for.
    // (Not a lack of analysis, so no message; tapping again uses the new queue.)
    if (_currentQueueIndex != current || _audioHandler.sequenceState.sequence.length != sequence.length) {
      _queueServiceLogger.info("Queue changed while ordering it harmonically; left as it is");
      return true;
    }
    await setPlaybackOrder(FinampPlaybackOrder.shuffled, shuffleOrder: [...order.take(restStart), ...reordered]);
    _harmonicOrderStream.add(true);
    _queueServiceLogger.info("Put ${reordered.length} upcoming songs in harmonic order");
    return true;
  }

  void toggleLoopMode() {
    final radioMode = FinampSettingsHelper.finampSettings.radioMode;
    final radioEnabled = FinampSettingsHelper.finampSettings.radioEnabled;
    final radioSeed = _providers.read(getActiveRadioSeedProvider(radioMode));
    final radioAvailabilityStatus = _providers.read(radioModeAvailabilityStatusProvider((radioMode, radioSeed)));
    final radioActive = radioEnabled && radioAvailabilityStatus.isAvailable;

    // if we start toggling loop modes, the radio should be disabled, to prevent it kicking back in when it becomes available
    if (radioEnabled) {
      toggleRadio(false);
    }
    // if the radio was active, we also reset the loop mode
    if (radioActive) {
      loopMode = FinampLoopMode.none;
      return;
    }

    if (_loopMode == FinampLoopMode.all) {
      loopMode = FinampLoopMode.one;
    } else if (_loopMode == FinampLoopMode.one) {
      loopMode = FinampLoopMode.none;
    } else {
      loopMode = FinampLoopMode.all;
    }
  }

  Logger get queueServiceLogger => _queueServiceLogger;

  int getActualIndexByLinearIndex(int linearIndex) {
    if (_playbackOrder == FinampPlaybackOrder.shuffled && _audioHandler.shuffleIndices.isNotEmpty) {
      return _audioHandler.shuffleIndices[linearIndex];
    } else {
      return linearIndex;
    }
  }

  void _logQueues({String message = ""}) {
    // generate string for `_queue`
    String queueString = "";
    for (FinampQueueItem queueItem in _queuePreviousTracks) {
      queueString += "${queueItem.item.title}, ";
    }
    queueString += "[[${_currentTrack?.item.title}]], ";
    queueString += "{";
    for (FinampQueueItem queueItem in _queueNextUp) {
      queueString += "${queueItem.item.title}, ";
    }
    queueString += "} ";
    for (FinampQueueItem queueItem in _queue) {
      queueString += "${queueItem.item.title}, ";
    }

    // generate string for `_queueAudioSource`
    // String queueAudioSourceString = "";
    // queueAudioSourceString += "[${_queueAudioSource.sequence.firstOrNull?.toString()}], ";
    // for (AudioSource queueItem in _queueAudioSource.sequence.sublist(1)) {
    //   queueAudioSourceString += "${queueItem.toString()}, ";
    // }

    // log queues
    _queueServiceLogger.finer(
      "Queue $message [${_queuePreviousTracks.length}-1-${_queueNextUp.length}-${_queue.length}]: $queueString",
    );
    // _queueServiceLogger.finer(
    //   "Audio Source Queue $message [${_queue.length}]: $queueAudioSourceString"
    // )
  }

  /// [contextNormalizationGain] is the normalization gain of the context that the track is being played in, e.g. the album
  /// Should only be used when the tracks within that context come from the same source, e.g. the same album (or maybe artist?). Usually makes no sense for playlists.
  Future<MediaItem> generateMediaItem(
    jellyfin_models.BaseItemDto item, {
    double? contextNormalizationGain,
    MediaItemParentType? parentType,
    jellyfin_models.BaseItemId? parentId,
    bool Function({jellyfin_models.BaseItemDto? item, ContentType? contentType})? isPlayable,
  }) async {
    const uuid = Uuid();

    MediaItemId? itemId;
    final tabContentType = ContentType.fromItemType(item.type ?? "Audio");
    bool isAndroidAutoOrMediaBrowserRequest = false;

    if (parentType != null) {
      isAndroidAutoOrMediaBrowserRequest = true;
      itemId = MediaItemId(
        contentType: tabContentType,
        parentType: parentType,
        parentId: parentId ?? item.parentId,
        itemId: item.id,
      );
    }

    bool isDownloaded = false;
    bool isItemPlayable = isPlayable?.call(item: item) ?? true;
    DownloadItem? downloadedTrack;
    DownloadStub? downloadedCollection;

    if (item.type == "Audio") {
      downloadedTrack = _downloadsService.getTrackDownload(item: item);
      isDownloaded = downloadedTrack?.file != null;
    } else {
      downloadedCollection = await _downloadsService.getCollectionInfo(item: item);
      if (downloadedCollection != null) {
        final downloadStatus = _downloadsService.getStatus(downloadedCollection, null);
        isDownloaded = downloadStatus != DownloadItemStatus.notNeeded;
      }
    }

    Uri? artUri = isAndroidAutoOrMediaBrowserRequest
        ? _providers.read(albumImageProvider(AlbumImageRequest(item: item, maxHeight: 200, maxWidth: 200))).uri
        : null;

    // use content provider for handling media art on Android
    if (Platform.isAndroid && isAndroidAutoOrMediaBrowserRequest) {
      final packageInfo = await PackageInfo.fromPlatform();
      // replace with placeholder art
      if (artUri == null) {
        final applicationSupportDirectory = await getApplicationSupportDirectory();
        artUri = Uri(
          scheme: "content",
          host: packageInfo.packageName,
          path: path_helper.join(applicationSupportDirectory.absolute.path, Assets.images.albumWhite.path),
        );
      } else {
        // store the origin in fragment since it should be unused
        artUri = androidMediaArtworkUri(artUri, packageInfo.packageName);
      }
    }

    return MediaItem(
      id: itemId?.toString() ?? uuid.v4(),
      playable:
          isItemPlayable, // this dictates whether clicking on an item will try to play it or browse it in media browsers like Android Auto
      album: item.album,
      artist: item.artists?.sortedBy((e) => e).join(", ") ?? item.albumArtist,
      title: item.name ?? "unknown",
      extras: {
        //!!! this ID has to be consistent across the transcoding URL and the playback reporting status, otherwise the server won't show that we're transcoding
        "playSessionId": uuid.v4(),
        "itemJson": item.toJson(setOffline: false),
        "shouldTranscode": FinampSettingsHelper.finampSettings.shouldTranscode,
        "downloadedTrackPath": downloadedTrack?.file?.path,
        "isDownloaded": isDownloaded,
        "android.media.extra.DOWNLOAD_STATUS": isDownloaded ? 2 : 0,
        "android.media.IS_EXPLICIT": item.isExplicit ? 1 : 0,
        "isOffline": FinampSettingsHelper.finampSettings.isOffline,
        "contextNormalizationGain": contextNormalizationGain,
      },
      // Jellyfin returns microseconds * 10 for some reason
      duration: item.runTimeTicksDuration(),
      artUri: artUri,
    );
  }
}

class NextUpShuffleOrder extends ShuffleOrder {
  final Random _random;
  final QueueService _queueService;
  final int? randomness;
  @override
  List<int> indices = <int>[];
  List<int>? shuffleIndicesOverride;

  NextUpShuffleOrder({Random? random, required QueueService queueService, this.randomness})
    : _random = random ?? Random(),
      _queueService = queueService;

  @override
  void shuffle({int? initialIndex}) {
    assert(initialIndex == null || indices.contains(initialIndex));

    if (shuffleIndicesOverride != null) {
      if (shuffleIndicesOverride!.length == indices.length) {
        indices = shuffleIndicesOverride!;
        return;
      } else {
        throw Exception(
          "Invalid shuffleIndicesOverride length ${shuffleIndicesOverride!.length} indices length ${indices.length}.",
        );
      }
    }

    if (initialIndex == null) {
      throw Exception("NextUpShuffleOrder always expects an initialIndex.");
    }

    // calculate next up size manually insted of using _queueService._queueNextUp because that could be out of date, and we
    // don't want to call _queueService._buildQueueFromNativePlayerQueue on an in-progress queue with an invalid shuffle order.
    List<FinampQueueItem> allTracks = GetIt.instance<MusicPlayerBackgroundTask>().sequenceState.sequence
        .map((e) => e.tag as FinampQueueItem)
        .toList();
    assert(allTracks.length == indices.length);
    assert(initialIndex >= 0 && initialIndex < allTracks.length);

    if (indices.length <= 1) {
      return;
    }

    _queueService.queueServiceLogger.finest("initialIndex: $initialIndex");

    // log indices
    String indicesString = "";
    for (int index in indices) {
      indicesString += "$index, ";
    }
    _queueService.queueServiceLogger.finest("Shuffled indices: $indicesString");
    _queueService.queueServiceLogger.finest("Current Track: ${allTracks[initialIndex]}");

    int nextUpLength = 0;
    for (int i = initialIndex + 1; i < allTracks.length; i++) {
      if (allTracks[i].type == QueueItemQueueType.nextUp) {
        nextUpLength++;
      } else {
        break;
      }
    }

    indices = ShuffleRandomness.indices(
      allTracks,
      (track) => ArtistSpacing.artistKey(track.baseItem),
      randomness ?? FinampSettingsHelper.finampSettings.shuffleRandomness,
      random: _random,
      initialIndex: initialIndex,
      nextUpLength: nextUpLength,
      allowArtistRepeats: ArtistSpacing.allowsRepeats(allTracks[initialIndex].source),
    );

    // log indices
    indicesString = "";
    for (int index in indices) {
      indicesString += "$index, ";
    }
    _queueService.queueServiceLogger.finest("Shuffled indices (swapped): $indicesString");
  }

  /// `index` is the linear index of the item in the ConcatenatingAudioSource
  @override
  void insert(int index, int count) {
    int insertionPoint = index;
    int linearIndexOfPreviousItem = index - 1;

    // _queueService!._queueFromConcatenatingAudioSource(logUpdate: false);
    // QueueInfo queueInfo = _queueService!.getQueue();

    // // log indices
    // String indicesString = "";
    // for (int index in indices) {
    //   indicesString += "$index, ";
    // }
    // _queueService!.queueServiceLogger.finest("Shuffled indices: $indicesString");
    // _queueService!.queueServiceLogger.finest("Current Track: ${queueInfo.currentTrack}");

    if (index >= indices.length) {
      // handle appending to the queue
      insertionPoint = indices.length;
    } else {
      // handle adding to Next Up
      int shuffledIndexOfPreviousItem = indices.indexOf(linearIndexOfPreviousItem);
      if (shuffledIndexOfPreviousItem != -1) {
        insertionPoint = shuffledIndexOfPreviousItem + 1;
      }
      _queueService.queueServiceLogger.finest(
        "Inserting $count items at index $index (shuffled indices insertion point: $insertionPoint) (index of previous item: $shuffledIndexOfPreviousItem)",
      );
    }

    // Offset indices after insertion point.
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) {
        indices[i] += count;
      }
    }

    // Insert new indices at the specified position.
    final newIndices = List.generate(count, (i) => index + i);
    indices.insertAll(insertionPoint, newIndices);
  }

  @override
  void removeRange(int start, int end) {
    // log indices
    String indicesString = "";
    for (int index in indices) {
      indicesString += "$index, ";
    }
    _queueService.queueServiceLogger.finest("Shuffled indices before removing: $indicesString");
    final count = end - start;
    // Remove old indices.
    final oldIndices = List.generate(count, (i) => start + i).toSet();
    indices.removeWhere(oldIndices.contains);
    // Offset indices after deletion point.
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= end) {
        indices[i] -= count;
      }
    }
    // log indices
    indicesString = "";
    for (int index in indices) {
      indicesString += "$index, ";
    }
    _queueService.queueServiceLogger.finest("Shuffled indices after removing: $indicesString");
  }

  void overrideShuffle(List<int>? shuffleOrder) {
    shuffleIndicesOverride = shuffleOrder;
  }

  @override
  void clear() {
    indices.clear();
  }
}

extension SequentialTracks on FinampQueueInfo {
  bool isCurrentlyPlayingTracksFromSameAlbum() {
    final currentTrackAlbum = currentTrack?.baseItem.parentId;
    if (currentTrackAlbum == null) return false;
    final previousTrackAlbum = previousTracks.lastOrNull?.baseItem.parentId;
    final nextTrackAlbum = (nextUp.firstOrNull ?? queue.firstOrNull)?.baseItem.parentId;

    return previousTrackAlbum == currentTrackAlbum || currentTrackAlbum == nextTrackAlbum;
  }
}
