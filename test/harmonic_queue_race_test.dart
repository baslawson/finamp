import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/album_image_provider.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/current_album_image_provider.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback_history_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/services/theme_provider.dart' as theme;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Pause the real harmonic continuation at its analyzer settings read. Its
/// analysis is already cached, so releasing this needs no server or wall time.
final class _Preferences extends InMemorySharedPreferencesAsync {
  _Preferences() : super.empty();
  Completer<void>? ordering;
  Completer<void>? orderingStarted;
  int heldReads = 0;
  // Holds reads of keys starting with this, as a new list's start reads its listening choices before clearing the queue.
  String? holdPrefix;
  Completer<void>? held;
  Completer<void>? heldStarted;

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) async {
    if (key == 'analyzerUrl' && ordering != null) {
      heldReads++;
      orderingStarted?.complete();
      orderingStarted = null;
      await ordering!.future;
    }
    if (holdPrefix != null && key.startsWith(holdPrefix!) && held != null) {
      heldStarted?.complete();
      heldStarted = null;
      await held!.future;
    }
    return super.getString(key, options);
  }
}

class _Downloads extends Fake implements DownloadsService {
  @override
  DownloadItem? getTrackDownload({BaseItemDto? item, BaseItemId? id}) => null;
}

class _Server extends Fake implements JellyfinApiHelper {}

class _User extends Fake implements FinampUserHelper {
  @override
  FinampUser? get currentUser => null;
}

class _History extends Fake implements PlaybackHistoryService {
  @override
  Future<void> reportRestoredSessionStatus() async {}
}

/// Models the native sequence and uses the very ShuffleOrder QueueService
/// hands to the player, including its temporary harmonic override.
class _Player extends Fake implements MusicPlayerBackgroundTask {
  final sources = <IndexedAudioSource>[];
  late ShuffleOrder order;
  AudioServiceShuffleMode mode = AudioServiceShuffleMode.none;
  Completer<void>? shuffling;
  Completer<void>? shuffleStarted;
  Completer<void>? changingMode;
  Completer<void>? changingModeStarted;
  Completer<void>? loading;
  Completer<void>? loadingStarted;
  bool publishFirst = false;
  int index = 0;
  int shuffleCalls = 0;
  // The orders plain shuffles give in turn; after these, linear.
  final plainOrders = <List<int>>[];
  final appliedOrders = <List<int>>[];

  @override
  final playbackState = BehaviorSubject.seeded(PlaybackState(queueIndex: 0));
  @override
  final mediaItem = BehaviorSubject<MediaItem?>.seeded(null);
  @override
  final queue = BehaviorSubject<List<MediaItem>>.seeded([]);
  @override
  final queueTitle = BehaviorSubject<String>.seeded('');
  @override
  List<AudioSource> get audioSources => sources;
  @override
  List<int> get shuffleIndices => [...order.indices];
  @override
  int? get queueIndex => mode == AudioServiceShuffleMode.all ? order.indices.indexOf(index) : index;
  @override
  bool get paused => true;
  @override
  SequenceState get sequenceState => SequenceState(
    sequence: [...sources],
    currentIndex: index,
    shuffleIndices: shuffleIndices,
    shuffleModeEnabled: mode == AudioServiceShuffleMode.all,
    loopMode: LoopMode.off,
  );

  List<String> get playing => [
    for (final source in sequenceState.effectiveSequence) (source.tag as FinampQueueItem).baseItem.id.raw,
  ];

  @override
  Future<void> clearFinampQueueItems() async => sources.clear();
  @override
  Future<Duration?> setQueueItems(
    List<FinampQueueItem> queueItems, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
    bool rethrowErrors = false,
  }) async {
    // The new list, as the native player has it, before loading finishes when [publishFirst].
    final items = [for (final item in queueItems) AudioSource.uri(Uri.parse('file:///unused/${item.id}'), tag: item)];
    if (publishFirst) {
      sources
        ..clear()
        ..addAll(items);
      order = shuffleOrder!..clear();
      order.insert(0, sources.length);
    }
    final gate = loading;
    loadingStarted?.complete();
    loadingStarted = null;
    await gate?.future;
    if (publishFirst) return null;
    sources.clear();
    sources.addAll([for (final item in queueItems) AudioSource.uri(Uri.parse('file:///unused/${item.id}'), tag: item)]);
    order = shuffleOrder!..clear();
    order.insert(0, sources.length);
    return null;
  }

  @override
  Future<void> shuffle() async {
    shuffleCalls++;
    // The native player consumes the override before its asynchronous reply.
    // Ordinary shuffle is fixed here so these races never depend on randomness.
    final nativeOrder = order as NextUpShuffleOrder;
    if (nativeOrder.shuffleIndicesOverride == null) {
      nativeOrder.indices = plainOrders.isEmpty ? List.generate(sources.length, (i) => i) : plainOrders.removeAt(0);
    } else {
      nativeOrder.shuffle(initialIndex: 0);
      appliedOrders.add([...order.indices]);
    }
    shuffleStarted?.complete();
    shuffleStarted = null;
    await shuffling?.future;
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    mode = shuffleMode;
    changingModeStarted?.complete();
    changingModeStarted = null;
    await changingMode?.future;
  }

  /// Like the native playlist, moves one at a time, each applied once the one before has its reply.
  Future<void> _moves = Future.value();
  Completer<void>? moving;

  @override
  Future<void> removeFinampQueueItemAt(int index) async {
    sources.removeAt(index);
    order.removeRange(index, index + 1);
  }

  @override
  Future<void> moveFinampQueueItem(int oldIndex, int newIndex) {
    final move = _moves.then((_) async {
      sources.insert(newIndex, sources.removeAt(oldIndex));
      await moving?.future;
    });
    _moves = move;
    return move;
  }

  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setPitch(double pitch) async {}
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {}
  @override
  Future<void> pause({bool disableFade = false, PauseBy by = PauseBy.listener, String? cause}) async {}
  @override
  Future<void> play({bool disableFade = false}) async {}
  @override
  Future<void> refreshPlaybackStateAndMediaNotification() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late FinampSettings settings;
  late _Preferences preferences;
  late SharedPreferencesAsyncPlatform? oldPreferences;
  late int oldStrength;
  // At full strength these distinct keys have one best continuation: 0, 3, 2, 1.
  final tracks = [
    for (var i = 0; i < 4; i++)
      BaseItemDto(
        id: BaseItemId(i.toString().padLeft(32, '0')),
        name: 'Song $i',
        type: 'Audio',
        artists: ['Artist $i'],
      ),
  ];
  final linear = [for (final track in tracks) track.id.raw];
  final harmonic = [linear[0], linear[3], linear[2], linear[1]];

  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-harmonic-race-');
    Hive.init(folder.path);
    final box = await Hive.openBox<FinampSettings>('FinampSettings');
    await Hive.openBox<FinampStorableQueueInfo>('Queues');
    settings = FinampSettings(
      downloadLocations: [],
      downloadLocationsMap: {},
      tabSortBy: {},
      tabSortOrder: {},
      homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
      gridImageSize: 130,
      homeScreenImageSize: 90,
      deviceId: 'test',
      isOffline: true,
      autoplayRestoredQueue: false,
      reportQueueToServer: false,
      enablePlayon: false,
    );
    await box.put('FinampSettings', settings);
    oldPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = preferences = _Preferences();
    oldStrength = HarmonicMixing.strength.value;
    HarmonicMixing.strength.value = 100;
    await AnalyzerService.saveSettings(url: 'http://analyzer.test', token: 'test');
    await http.runWithClient(
      () => AnalyzerService.analysis(linear),
      () => MockClient(
        (request) async => http.Response(
          jsonEncode({
            for (var i = 0; i < tracks.length; i++)
              linear[i]: {
                'bpm': 120,
                'camelot': '${[1, 7, 3, 2][i]}A',
              },
          }),
          200,
        ),
      ),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
    SharedPreferencesAsyncPlatform.instance = oldPreferences;
    HarmonicMixing.strength.value = oldStrength;
    await Hive.close();
    await folder.delete(recursive: true);
  });

  /// Restore through the public API to attach QueueService's own shuffle order.
  /// Capture the service's periodic timer because QueueService has no dispose.
  /// All race interleavings themselves use explicit completion gates.
  Future<void> exercise(Future<void> Function(QueueService queue, _Player player) race) async {
    final timers = <Timer>[];
    await runZoned(
      () async {
        final player = _Player();
        final providers = ProviderContainer(
          overrides: [
            finampSettingsProvider.overrideWith((ref) => Stream.value(settings)),
            FinampUserHelper.finampCurrentUserProvider.overrideWith((ref) => null),
            currentAlbumImageProvider.overrideWith((ref) => StateController(const theme.FinampImage.empty())),
            albumImageProvider.overrideWith(
              (ref, request) => AlbumImageInfo(null, request, Uri.file('${folder.path}/art'), fullQuality: true),
            ),
          ],
        );
        GetIt.instance.registerSingleton<ProviderContainer>(providers);
        GetIt.instance.registerSingleton<JellyfinApiHelper>(_Server());
        GetIt.instance.registerSingleton<DownloadsService>(_Downloads());
        GetIt.instance.registerSingleton<FinampUserHelper>(_User());
        GetIt.instance.registerSingleton<PlaybackHistoryService>(_History());
        GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
        final queue = QueueService();
        GetIt.instance.registerSingleton<QueueService>(queue);
        final items = [
          for (final track in tracks)
            FinampQueueItem(
              item: MediaItem(
                id: track.id.raw,
                title: track.name!,
                extras: {'itemJson': track.toJson(setOffline: false)},
              ),
              source: QueueService.savedQueueSource,
            ),
        ];
        final saved = FinampStorableQueueInfo.fromQueueInfo(
          FinampQueueInfo(
            id: 'saved',
            previousTracks: [],
            currentTrack: items.first,
            nextUp: [],
            queue: items.sublist(1),
            source: QueueService.savedQueueSource,
            saveState: SavedQueueState.pendingSave,
            sourceLibrary: null,
          ),
          0,
          FinampPlaybackOrder.linear,
          [0, 1, 2, 3],
        );
        await queue.loadSavedQueue(saved, existingItems: {for (final track in tracks) track.id: track});
        expect(queue.getQueue().saveState, SavedQueueState.pendingSave);
        expect(player.playing, linear);
        try {
          await race(queue, player);
        } finally {
          providers.dispose();
          await player.playbackState.close();
          await player.mediaItem.close();
          await player.queue.close();
          await player.queueTitle.close();
          for (final timer in timers) {
            timer.cancel();
          }
        }
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
  }

  Future<void> holdOrdering() {
    preferences.ordering = Completer<void>();
    preferences.orderingStarted = Completer<void>();
    return preferences.orderingStarted!.future;
  }

  void releaseOrdering() {
    preferences.ordering!.complete();
    preferences.ordering = null;
  }

  test('choosing linear playback while harmonic shuffle is pending leaves it linear', () async {
    await exercise((queue, player) async {
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await started.future;
      expect(player.appliedOrders, [
        [0, 3, 2, 1],
      ]);
      expect(queue.playbackOrder, FinampPlaybackOrder.shuffled);

      await queue.setPlaybackOrder(FinampPlaybackOrder.linear);
      player.shuffling!.complete();
      await first;

      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
      expect(player.mode, AudioServiceShuffleMode.none);
      expect(queue.harmonicOrder, isFalse);
      expect(player.playing, linear);
    });
  });

  test('turning harmonic order off and on while it is worked out honours the later request', () async {
    await exercise((queue, player) async {
      final started = holdOrdering();
      final first = queue.setHarmonicOrder(true);
      await started;
      expect(preferences.heldReads, 1);
      expect(player.shuffleCalls, 0);

      await queue.setHarmonicOrder(false);
      await queue.setHarmonicOrder(true);
      expect(queue.harmonicOrder, isFalse);
      releaseOrdering();
      await first;

      expect(queue.harmonicOrder, isTrue);
      expect(queue.playbackOrder, FinampPlaybackOrder.shuffled);
      expect(player.mode, AudioServiceShuffleMode.all);
      expect(player.playing, harmonic);
      expect(player.appliedOrders, [
        [0, 3, 2, 1],
      ]);
    });
  });

  test('changing harmonic strength after turning it off while it is worked out leaves it off', () async {
    await exercise((queue, player) async {
      final started = holdOrdering();
      final first = queue.setHarmonicOrder(true);
      await started;
      expect(preferences.heldReads, 1);

      await queue.setHarmonicOrder(false);
      HarmonicMixing.strength.value = 90;
      await queue.refreshHarmonicOrder();
      releaseOrdering();
      await first;

      expect(queue.harmonicOrder, isFalse);
      expect(queue.playbackOrder, FinampPlaybackOrder.shuffled);
      expect(player.mode, AudioServiceShuffleMode.all);
      expect(player.playing, linear);
      expect(player.appliedOrders, isEmpty);
    });
  });

  test('moving upcoming songs while harmonic order is worked out keeps the edit though the queue is as long', () async {
    await exercise((queue, player) async {
      final started = holdOrdering();
      final first = queue.setHarmonicOrder(true);
      await started;
      expect(preferences.heldReads, 1);
      final ids = queue.getQueue().fullQueue.map((item) => item.id).toList();
      await queue.reorderByOffset(1, 2);
      final edited = [linear[0], linear[2], linear[1], linear[3]];
      expect(player.playing, edited);
      expect(queue.getQueue().fullQueue.map((item) => item.id), [ids[0], ids[2], ids[1], ids[3]]);
      expect(queue.getQueue().trackCount, ids.length);
      expect(queue.getQueue().currentTrack!.id, ids.first);
      releaseOrdering();
      await first;

      expect(queue.harmonicOrder, isFalse);
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
      expect(player.mode, AudioServiceShuffleMode.none);
      expect(player.playing, edited);
      expect(player.appliedOrders, isEmpty);
    });
  });

  test('shuffling and going back to linear while harmonic order is worked out leaves it linear', () async {
    await exercise((queue, player) async {
      final started = holdOrdering();
      final first = queue.setHarmonicOrder(true);
      await started;

      // Back where it was, the same songs in the same order, but harmonic order is no longer what was chosen.
      await queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      await queue.setPlaybackOrder(FinampPlaybackOrder.linear);
      releaseOrdering();
      await first;

      expect(queue.harmonicOrder, isFalse);
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
      expect(player.mode, AudioServiceShuffleMode.none);
      expect(player.playing, linear);
      expect(player.appliedOrders, isEmpty);
    });
  });

  test('choosing linear playback while a harmonic mix starts leaves it linear and not harmonic', () async {
    await exercise((queue, player) async {
      player.changingMode = Completer<void>();
      final reached = player.changingModeStarted = Completer<void>();
      final starting = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.linear,
        beginPlaying: false,
        harmonicOrder: true,
      );
      await reached.future;

      final chosen = queue.setPlaybackOrder(FinampPlaybackOrder.linear);
      player.changingMode!.complete();
      await Future.wait([starting, chosen]);

      expect(queue.harmonicOrder, isFalse);
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
      expect(player.playing, linear);
    });
  });

  test('turning harmonic order off while a harmonic mix starts leaves it off', () async {
    await exercise((queue, player) async {
      player.changingMode = Completer<void>();
      final reached = player.changingModeStarted = Completer<void>();
      final starting = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.linear,
        beginPlaying: false,
        harmonicOrder: true,
      );
      await reached.future;

      final off = queue.setHarmonicOrder(false);
      player.changingMode!.complete();
      await Future.wait([starting, off]);

      expect(queue.harmonicOrder, isFalse);
      expect(queue.playbackOrder, FinampPlaybackOrder.shuffled);
    });
  });

  test('a shuffle asked for while harmonic order is applied neither takes its order nor loses its own', () async {
    await exercise((queue, player) async {
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await started.future;
      expect(player.appliedOrders, [
        [0, 3, 2, 1],
      ]);

      // Shuffled again before the harmonic order is in: it waits, then shuffles as usual.
      final again = queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      await pumpEventQueue();
      expect(player.shuffleCalls, 1);
      player.shuffling!.complete();
      await Future.wait([first, again]);

      expect(player.shuffleCalls, 2);
      expect(player.appliedOrders, [
        [0, 3, 2, 1],
      ]);
      expect(queue.harmonicOrder, isFalse);
      expect(queue.playbackOrder, FinampPlaybackOrder.shuffled);
      expect(player.playing, linear);
    });
  });

  test(
    'a harmonic order asked for while another shuffle is applied is worked out from where playback then is',
    () async {
      await exercise((queue, player) async {
        player.shuffling = Completer<void>();
        final started = player.shuffleStarted = Completer<void>();
        final shuffled = queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
        await started.future;
        final first = queue.setHarmonicOrder(true);
        await pumpEventQueue();
        expect(player.shuffleCalls, 1);

        player.index = 1;
        player.playbackState.add(PlaybackState(queueIndex: 1));
        await pumpEventQueue();
        player.shuffling!.complete();
        await Future.wait([shuffled, first]);

        // The songs before and the current one stay; only the rest after it is ordered.
        expect(player.appliedOrders, hasLength(1));
        expect(player.appliedOrders.single.take(2), [0, 1]);
        expect(player.appliedOrders.single.skip(2), unorderedEquals([2, 3]));
        expect(queue.harmonicOrder, isTrue);
        expect(queue.getQueue().currentTrack!.baseItem.id.raw, linear[1]);
      });
    },
  );

  test('a queue being replaced is settling while it looks empty, and is shown again once settled', () async {
    await exercise((queue, player) async {
      expect(queue.settling, false);
      final settlingWhenShown = <bool>[];
      final listening = queue.getQueueStream().listen((_) => settlingWhenShown.add(queue.settling));
      player.loading = Completer<void>();
      final reached = player.loadingStarted = Completer<void>();
      final starting = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.linear,
        beginPlaying: false,
      );
      await reached.future;
      expect(queue.getQueue().currentTrack, isNull);
      expect(queue.settling, true);
      player.loading!.complete();
      await starting;
      await Future<void>.delayed(Duration.zero);
      await listening.cancel();
      expect(queue.settling, false);
      expect(queue.getQueue().currentTrack, isNotNull);
      // A listener that waited for the replacement to end hears of it.
      expect(settlingWhenShown.last, false);
    });
  });

  test('a queue not yet restored at startup, or being restored, is settling', () async {
    await exercise((queue, player) async {
      expect(QueueService().settling, true);
      final saved = FinampStorableQueueInfo.fromQueueInfo(queue.getQueue(), 0, FinampPlaybackOrder.linear, [
        0,
        1,
        2,
        3,
      ]);
      final settlingWhenShown = <bool>[];
      final listening = queue.getQueueStream().listen((_) => settlingWhenShown.add(queue.settling));
      await Future<void>.delayed(Duration.zero);
      settlingWhenShown.clear();
      await queue.loadSavedQueue(saved, existingItems: {for (final track in tracks) track.id: track});
      await listening.cancel();
      // Shown first as the restore starts, before the queue is replaced.
      expect(settlingWhenShown.first, true);
      expect(queue.settling, false);
    });
  });

  test('a startup with no queue to restore is shown as settled', () async {
    await exercise((queue, player) async {
      await Hive.box<FinampStorableQueueInfo>('Queues').clear();
      final starting = QueueService();
      final settlingWhenShown = <bool>[];
      final listening = starting.getQueueStream().listen((_) => settlingWhenShown.add(starting.settling));
      // What the shared player's state shows the new service is no part of the restore.
      await pumpEventQueue();
      settlingWhenShown.clear();
      await starting.performInitialQueueLoad();
      await pumpEventQueue();
      await listening.cancel();
      expect(starting.settling, false);
      // A listener that waited for the restore hears that there was none.
      expect(settlingWhenShown, [false]);
    });
  });

  test('shuffle chosen while a new list loads stands', () async {
    await exercise((queue, player) async {
      player.loading = Completer<void>();
      final reached = player.loadingStarted = Completer<void>();
      final starting = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.linear,
        beginPlaying: false,
      );
      await reached.future;

      await queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      player.loading!.complete();
      await starting;

      expect(queue.playbackOrder, FinampPlaybackOrder.shuffled);
      expect(player.mode, AudioServiceShuffleMode.all);
    });
  });

  test('harmonic order turned on while a new list loads puts that list in harmonic order', () async {
    await exercise((queue, player) async {
      player.loading = Completer<void>();
      final reached = player.loadingStarted = Completer<void>();
      final starting = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.linear,
        beginPlaying: false,
      );
      await reached.future;

      final on = queue.getHarmonicOrderStream().firstWhere((harmonic) => harmonic);
      await queue.setHarmonicOrder(true);
      player.loading!.complete();
      await starting;
      await on.timeout(const Duration(seconds: 10));

      expect(queue.harmonicOrder, isTrue);
      expect(queue.playbackOrder, FinampPlaybackOrder.shuffled);
      expect(player.playing, harmonic);
    });
  });

  test('two moves made while harmonic order is applied both stand', () async {
    await exercise((queue, player) async {
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await started.future;
      expect(player.appliedOrders, [
        [0, 3, 2, 1],
      ]);

      // As shown (still linear): song 3 dropped on song 1, then song 1 on song 2. Each from the order the one before it
      // leaves: [0, 3, 2, 1], then [0, 2, 3, 1], then [0, 2, 1, 3].
      final moves = [queue.reorderByOffset(3, 1), queue.reorderByOffset(1, 2)];
      player.shuffling!.complete();
      await Future.wait([first, ...moves]);

      expect(player.playing, [linear[0], linear[2], linear[1], linear[3]]);
    });
  });

  test('harmonic order turned on, then off, while a new list loads stays off', () async {
    await exercise((queue, player) async {
      player.loading = Completer<void>();
      final reached = player.loadingStarted = Completer<void>();
      final starting = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.linear,
        beginPlaying: false,
      );
      await reached.future;
      await queue.setHarmonicOrder(true);

      // Turned off as the list applies the order kept from loading.
      player.changingMode = Completer<void>();
      final applying = player.changingModeStarted = Completer<void>();
      player.loading!.complete();
      await applying.future;
      final off = queue.setHarmonicOrder(false);
      player.changingMode!.complete();
      await Future.wait([starting, off]);
      await pumpEventQueue();

      expect(queue.harmonicOrder, isFalse);
      expect(player.appliedOrders, isEmpty);
      expect(queue.playbackOrder, FinampPlaybackOrder.shuffled);
    });
  });

  test('harmonic work for the old queue does not shuffle a linear list started meanwhile', () async {
    await exercise((queue, player) async {
      final started = holdOrdering();
      final first = queue.setHarmonicOrder(true);
      await started;

      // Held before the new list clears the queue, so the old one is still just as it was.
      ListeningPreferences.reset();
      preferences
        ..holdPrefix = 'listeningChoices.'
        ..held = Completer<void>();
      final reached = preferences.heldStarted = Completer<void>();
      final starting = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.linear,
        beginPlaying: false,
      );
      await reached.future;
      releaseOrdering();
      await first;
      preferences.held!.complete();
      preferences.held = null;
      await starting;
      await pumpEventQueue();

      expect(player.appliedOrders, isEmpty);
      expect(queue.harmonicOrder, isFalse);
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
      expect(player.mode, AudioServiceShuffleMode.none);
    });
  });

  test('harmonic order asked for behind two shuffles is applied after them', () async {
    await exercise((queue, player) async {
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      // The second shuffle moves the songs, so an order worked out before it would no longer fit.
      player.plainOrders.addAll([
        [0, 1, 2, 3],
        [0, 2, 1, 3],
      ]);
      final shuffles = [queue.setPlaybackOrder(FinampPlaybackOrder.shuffled)];
      await started.future;
      shuffles.add(queue.setPlaybackOrder(FinampPlaybackOrder.shuffled));
      final first = queue.setHarmonicOrder(true);
      await pumpEventQueue();
      expect(player.shuffleCalls, 1);

      player.shuffling!.complete();
      await Future.wait([...shuffles, first]);

      expect(player.shuffleCalls, 3);
      expect(player.appliedOrders, [
        [0, 3, 2, 1],
      ]);
      expect(queue.harmonicOrder, isTrue);
      expect(player.playing, harmonic);
    });
  });

  Future<void> startLinearHeld(
    QueueService queue,
    Future<void> Function() meanwhile, {
    List<BaseItemDto>? items,
  }) async {
    ListeningPreferences.reset();
    preferences
      ..holdPrefix = 'listeningChoices.'
      ..held = Completer<void>();
    final reached = preferences.heldStarted = Completer<void>();
    final starting = queue.startPlayback(
      items: items ?? tracks,
      source: QueueService.savedQueueSource,
      order: FinampPlaybackOrder.linear,
      beginPlaying: false,
    );
    await reached.future;
    await meanwhile();
    preferences.held!.complete();
    preferences.held = null;
    await starting;
    await pumpEventQueue();
  }

  test('harmonic order asked for behind a shuffle is not applied to a list started meanwhile', () async {
    await exercise((queue, player) async {
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final shuffled = queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      await started.future;
      final first = queue.setHarmonicOrder(true);
      await pumpEventQueue();

      await startLinearHeld(queue, () async {
        player.shuffling!.complete();
        await Future.wait([shuffled, first]);
      });

      expect(player.appliedOrders, isEmpty);
      expect(queue.harmonicOrder, isFalse);
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
      expect(player.mode, AudioServiceShuffleMode.none);
    });
  });

  test('a song moved behind a shuffle is not moved in a list started meanwhile', () async {
    await exercise((queue, player) async {
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final shuffled = queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      await started.future;
      final moves = [queue.reorderByOffset(1, 2), queue.reorderByOffset(3, 1)];
      await pumpEventQueue();

      await startLinearHeld(queue, () async {}, items: tracks.take(3).toList());
      player.shuffling!.complete();
      await Future.wait([shuffled, ...moves]);

      expect(player.playing, linear.take(3));
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
    });
  });

  test('a song moved while harmonic order is applied is the song that was dragged', () async {
    await exercise((queue, player) async {
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await started.future;
      // Still shown linear, so song 1 is dragged below song 2.
      expect([for (final item in queue.getQueue().fullQueue) item.baseItem.id.raw], linear);

      final move = queue.reorderByOffset(1, 2);
      player.shuffling!.complete();
      await Future.wait([first, move]);

      // In harmonic order [0, 3, 2, 1] song 1 is already below song 2; nothing else moves.
      expect(player.playing, [linear[0], linear[3], linear[2], linear[1]]);
    });
  });

  test('a song moved up while harmonic order is applied lands just before the song it was dropped on', () async {
    await exercise((queue, player) async {
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await started.future;

      // Song 3 dropped on song 1.
      final move = queue.reorderByOffset(3, 1);
      player.shuffling!.complete();
      await Future.wait([first, move]);

      expect(player.playing, [linear[0], linear[2], linear[3], linear[1]]);
    });
  });

  test('turning harmonic order off while it waits on a shuffle near the end of the queue leaves it off', () async {
    await exercise((queue, player) async {
      player.index = 2;
      player.playbackState.add(PlaybackState(queueIndex: 2));
      await pumpEventQueue();
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final shuffled = queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      await started.future;
      final first = queue.setHarmonicOrder(true);
      await pumpEventQueue();

      final linearAgain = queue.setPlaybackOrder(FinampPlaybackOrder.linear);
      player.shuffling!.complete();
      await Future.wait([shuffled, first, linearAgain]);

      expect(queue.harmonicOrder, isFalse);
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
    });
  });

  for (final order in FinampPlaybackOrder.values) {
    test(
      'a drag in the earlier songs moves the dragged song though the list shown is moved right after ($order)',
      () async {
        await exercise((queue, player) async {
          if (order == FinampPlaybackOrder.shuffled) await queue.setPlaybackOrder(order);
          player.index = 2;
          player.playbackState.add(PlaybackState(queueIndex: 2));
          await pumpEventQueue();
          expect([for (final item in queue.getQueue().previousTracks) item.baseItem.id.raw], linear.take(2));

          // As the queue list does: the queue told first, then the list it shows (the queue's own) moved.
          final previous = queue.getQueue().previousTracks;
          final move = queue.reorderByOffset(-2, -1);
          previous.insert(1, previous.removeAt(0));
          await move;

          expect(player.playing, [linear[1], linear[0], linear[2], linear[3]]);
        });
      },
    );
  }

  test('harmonic order asked for while a shuffle moves the current song works from where it then is', () async {
    await exercise((queue, player) async {
      player.index = 2;
      player.playbackState.add(PlaybackState(queueIndex: 2));
      await pumpEventQueue();
      // Song 2 playing, shuffled to [2, 0, 3, 1]: first in play order now.
      player.plainOrders.add([2, 0, 3, 1]);
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final shuffled = queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      await started.future;
      final first = queue.setHarmonicOrder(true);
      await pumpEventQueue();

      player.shuffling!.complete();
      await Future.wait([shuffled, first]);

      expect(player.appliedOrders, [
        [2, 3, 0, 1],
      ]);
      expect(player.playing, [linear[2], linear[3], linear[0], linear[1]]);
      expect(queue.harmonicOrder, isTrue);
    });
  });

  test(
    'songs dragged one after another while the first move is applied each move from where the last left them',
    () async {
      await exercise((queue, player) async {
        player.moving = Completer<void>();
        // As the upcoming list does: the queue told first, then the list it shows (the queue's own) moved. The last song
        // dragged to the top three times brings the queue back round to as it was.
        final moves = <Future<void>>[];
        for (var i = 0; i < 3; i++) {
          moves.add(queue.reorderByOffset(3, 1));
          final upcoming = queue.getQueue().queue;
          upcoming.insert(0, upcoming.removeAt(2));
        }
        await pumpEventQueue();
        player.moving!.complete();
        await Future.wait(moves);

        expect(player.playing, linear);
      });
    },
  );

  test('playback moving on as harmonic order is applied skips no upcoming song', () async {
    await exercise((queue, player) async {
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await started.future;
      expect(player.appliedOrders, [
        [0, 3, 2, 1],
      ]);

      player.index = 1;
      player.playbackState.add(PlaybackState(queueIndex: 1));
      await pumpEventQueue();
      player.shuffling!.complete();
      await first;

      // Songs 0 and 1 played; the rest still to come, in the harmonic order's own order.
      expect(player.playing, [linear[0], linear[1], linear[3], linear[2]]);
      expect(queue.getQueue().currentTrack!.baseItem.id.raw, linear[1]);
      expect(queue.getQueue().queue, hasLength(2));
    });
  });

  test('a harmonic order asked for at a new strength before a song is moved does not undo the move', () async {
    await exercise((queue, player) async {
      final started = holdOrdering();
      final first = queue.setHarmonicOrder(true);
      await started;
      HarmonicMixing.strength.value = 99;
      await queue.refreshHarmonicOrder();

      await queue.reorderByOffset(1, 2);
      final moved = [linear[0], linear[2], linear[1], linear[3]];
      expect(player.playing, moved);
      releaseOrdering();
      await first;

      expect(player.playing, moved);
      expect(player.appliedOrders, isEmpty);
    });
  });

  test('playback following the new harmonic order while shuffled keeps its songs to come', () async {
    await exercise((queue, player) async {
      await queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await started.future;

      // Already shuffled, so the player follows [0, 3, 2, 1] at once: on to song 3.
      player.index = 3;
      player.playbackState.add(PlaybackState(queueIndex: 1));
      await pumpEventQueue();
      player.shuffling!.complete();
      await first;

      expect(player.playing, harmonic);
      expect(queue.getQueue().currentTrack!.baseItem.id.raw, linear[3]);
      expect(queue.getQueue().queue, hasLength(2));
    });
  });

  test('playback following the new harmonic order as shuffle turns on keeps its songs to come', () async {
    await exercise((queue, player) async {
      player.changingMode = Completer<void>();
      final reached = player.changingModeStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await reached.future;

      // Shuffle on, so the player follows [0, 3, 2, 1]: on to song 3.
      player.index = 3;
      player.playbackState.add(PlaybackState(queueIndex: 1));
      await pumpEventQueue();
      player.changingMode!.complete();
      await first;

      expect(player.playing, harmonic);
      expect(queue.getQueue().currentTrack!.baseItem.id.raw, linear[3]);
      expect(queue.getQueue().queue, hasLength(2));
    });
  });

  test('songs moved and moved back while harmonic order is worked out keep it from being applied', () async {
    await exercise((queue, player) async {
      final started = holdOrdering();
      final first = queue.setHarmonicOrder(true);
      await started;

      await queue.reorderByOffset(1, 2);
      await queue.reorderByOffset(2, 1);
      expect(player.playing, linear);
      releaseOrdering();
      await first;

      expect(player.playing, linear);
      expect(player.appliedOrders, isEmpty);
    });
  });

  test('playback going on twice through the new harmonic order keeps the songs it skipped none of', () async {
    await exercise((queue, player) async {
      await queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await started.future;

      // Following [0, 3, 2, 1]: song 3, then song 2.
      for (final (song, at) in [(3, 1), (2, 2)]) {
        player.index = song;
        player.playbackState.add(PlaybackState(queueIndex: at));
        await pumpEventQueue();
      }
      player.shuffling!.complete();
      await first;

      expect(player.playing, harmonic);
      expect(queue.getQueue().currentTrack!.baseItem.id.raw, linear[2]);
      expect([for (final item in queue.getQueue().queue) item.baseItem.id.raw], [linear[1]]);
    });
  });

  test('a song removed while harmonic order is applied leaves no error behind', () async {
    await exercise((queue, player) async {
      // Shuffled to [3, 0, 1, 2], song 0 playing after song 3.
      player.plainOrders.add([3, 0, 1, 2]);
      await queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      player.playbackState.add(PlaybackState(queueIndex: 1));
      await pumpEventQueue();
      player.shuffling = Completer<void>();
      final started = player.shuffleStarted = Completer<void>();
      final first = queue.setHarmonicOrder(true);
      await started.future;

      // Song 3, before the current one, removed as the order is applied.
      await queue.removeAtOffset(-1);
      player.shuffling!.complete();
      await first;

      expect(player.sources, hasLength(3));
      expect(player.order.indices.toSet(), {0, 1, 2});
    });
  });

  test('harmonic order asked for while a drag is still being applied is applied after it', () async {
    await exercise((queue, player) async {
      player.moving = Completer<void>();
      final move = queue.reorderByOffset(1, 2);
      await pumpEventQueue();
      final first = queue.setHarmonicOrder(true);
      await pumpEventQueue();
      player.moving!.complete();
      await Future.wait([move, first]);

      expect(queue.harmonicOrder, isTrue);
      expect(player.appliedOrders, hasLength(1));
    });
  });

  test('an older list finishing as a newer harmonic mix loads leaves the mix as it was made', () async {
    await exercise((queue, player) async {
      final older = player.loading = Completer<void>();
      final olderReached = player.loadingStarted = Completer<void>();
      final first = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.shuffled,
        beginPlaying: false,
      );
      await olderReached.future;
      final newer = player.loading = Completer<void>();
      final newerReached = player.loadingStarted = Completer<void>();
      final mix = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.linear,
        beginPlaying: false,
        harmonicOrder: true,
      );
      await newerReached.future;

      older.complete();
      await first;
      newer.complete();
      await mix;

      expect(queue.harmonicOrder, isTrue);
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
      expect(player.mode, AudioServiceShuffleMode.none);
    });
  });

  test('songs moved after harmonic order is chosen while a list loads stay where they were moved', () async {
    await exercise((queue, player) async {
      player.publishFirst = true;
      player.loading = Completer<void>();
      final reached = player.loadingStarted = Completer<void>();
      final starting = queue.startPlayback(
        items: tracks,
        source: QueueService.savedQueueSource,
        order: FinampPlaybackOrder.linear,
        beginPlaying: false,
      );
      await reached.future;
      await queue.setHarmonicOrder(true);
      final afterHarmonic = List.of(player.playing);
      expect(player.appliedOrders, hasLength(1));
      // Moved by hand, as the queue then shows it.
      await queue.reorderByOffset(1, 2);
      final moved = List.of(player.playing);
      expect(moved, isNot(afterHarmonic));
      player.loading!.complete();
      await starting;
      await pumpEventQueue();

      expect(player.playing, moved);
    });
  });

  test(
    'a song moved before harmonic order is chosen while a list loads still puts that list in harmonic order',
    () async {
      await exercise((queue, player) async {
        final on = Completer<void>();
        await startLinearHeld(queue, () async {
          // On the old queue, still shown: a move, then harmonic order.
          await queue.reorderByOffset(1, 2);
          await queue.setHarmonicOrder(true);
        });
        final harmonicOn = queue.getHarmonicOrderStream().listen((harmonic) {
          if (harmonic && !on.isCompleted) on.complete();
        });
        await on.future.timeout(const Duration(seconds: 10));
        await harmonicOn.cancel();

        expect(player.playing, harmonic);
      });
    },
  );
}
