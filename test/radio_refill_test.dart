import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/screens/radio_controls_screen.dart';
import 'package:finamp/screens/karaoke_dashboard_screen.dart';
import 'package:finamp/screens/saved_karaoke_screen.dart';
import 'package:finamp/screens/listen_together_screen.dart';
import 'package:finamp/services/playon_service.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/party_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/audio_service_helper.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_service_helper.dart' as radio;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

BaseItemDto _track(String id, String artist, {String? album}) => BaseItemDto(
  id: BaseItemId(id),
  name: 'Song $id',
  type: 'Audio',
  artists: [artist],
  albumId: BaseItemId(album ?? 'album-$id'),
  genres: ['Rock'],
);
final _seed = _track('seed', 'Seed');
List<BaseItemDto> _pool() => [for (var i = 0; i < 40; i++) _track('song$i', 'Artist ${i % 4}')];
QueueItemSource _source() => QueueItemSource.fromBaseItem(_seed, type: QueueItemSourceType.radio);
FinampQueueItem _queued(BaseItemDto item, QueueItemSource source) => FinampQueueItem(
  item: MediaItem(
    id: item.id.raw,
    title: item.name!,
    duration: const Duration(minutes: 3),
    extras: {'itemJson': item.toJson(), 'isDownloaded': true},
  ),
  source: source,
);

class _Queue extends Fake implements QueueService {
  @override
  FinampLoopMode loopMode = FinampLoopMode.none;
  _Queue() {
    info = FinampQueueInfo(
      id: 'queue',
      previousTracks: [],
      currentTrack: _queued(_seed, _source()),
      nextUp: [],
      queue: [],
      source: _source(),
      saveState: SavedQueueState.saving,
      sourceLibrary: BaseItemDto(id: const BaseItemId('library'), type: 'CollectionFolder'),
    );
    stream = BehaviorSubject.seeded(info);
  }
  late FinampQueueInfo info;
  late BehaviorSubject<FinampQueueInfo?> stream;
  int appends = 0;
  bool failAppend = false;
  bool limitFirstAppend = false;
  Completer<void>? preparing;
  Completer<void>? prepared;
  int? startingIndex;
  bool? pinnedReplacement;
  BaseItemDto? retunedSeed;
  bool failNextUp = false;
  Completer<void>? nextUpStarted, nextUpRelease;
  @override
  Future<void> retuneRadio({BaseItemDto? seed, bool replaceQueued = false}) async {
    retunedSeed = seed;
    if (seed != null) info.source = QueueItemSource.fromBaseItem(seed, type: QueueItemSourceType.radio);
    info.queue.removeWhere((item) => replaceQueued || item.source.type == QueueItemSourceType.radio);
    radio.invalidateRadioCache();
    await radio.maybeAddRadioTracks();
  }

  @override
  Future<void> addToNextUp(PlayableSlice slice) async {
    if (nextUpStarted?.isCompleted == false) nextUpStarted!.complete();
    await nextUpRelease?.future;
    if (failNextUp) throw StateError('native append failed');
    final resolved = await slice.resolve();
    info.nextUp.addAll(resolved.items.map((item) => _queued(item, slice.source)));
    stream.add(info);
  }

  @override
  FinampQueueInfo getQueue() => info;
  @override
  BehaviorSubject<FinampQueueInfo?> getQueueStream() => stream;
  @override
  FinampQueueItem? getCurrentTrack() => info.currentTrack;
  @override
  Future<void> startPlayback({
    required List<BaseItemDto> items,
    required QueueItemSource source,
    QueueItemSource? customTrackSource,
    FinampPlaybackOrder? order,
    int? startingIndex,
    bool skipRadioCacheInvalidation = false,
    bool beginPlaying = true,
    bool randomizeGenerated = true,
    bool harmonicOrder = false,
  }) async {
    this.startingIndex = startingIndex;
    items = ArtistSpacing.prepareStart(items, source, startingIndex: startingIndex).items;
    info.id = 'started';
    info.source = source;
    info.previousTracks.clear();
    info.currentTrack = _queued(items.first, source);
    info.queue = items.skip(1).map((item) => _queued(item, source)).toList();
    stream.add(info);
    // Native queue callbacks can fire before the startup lock is released.
    await radio.maybeAddRadioTracks();
  }

  @override
  Future<void> replaceUpcoming(PlayableSlice slice, {bool pinFirst = false}) async {
    pinnedReplacement = pinFirst;
    final resolved = await slice.resolve(preShuffle: true);
    final items = ArtistSpacing.generated(
      resolved.items,
      slice.source,
      previous: info.currentTrack?.baseItem,
      keepFirst: pinFirst,
    );
    info.source = slice.source;
    info.nextUp.clear();
    info.queue = items.map((item) => _queued(item, slice.source)).toList();
    stream.add(info);
    await radio.maybeAddRadioTracks();
  }

  @override
  Future<List<BaseItemDto>> addRadioTracks(BasePlayableSlice slice, {required bool Function() isCurrent}) async {
    prepared?.complete();
    await preparing?.future;
    if (!isCurrent()) return [];
    appends++;
    if (failAppend) throw StateError('append failed');
    final previous = info.fullQueue.last.baseItem;
    var items = ArtistSpacing.generated(slice.items, slice.source, previous: previous);
    if (limitFirstAppend && appends == 1) items = items.take(1).toList();
    info.queue.addAll(items.map((item) => _queued(item, slice.source)));
    stream.add(info);
    return items;
  }
}

class _Api extends Fake implements JellyfinApiHelper {
  int calls = 0;
  int itemCalls = 0;
  bool fail = false;
  bool empty = false;
  bool narrowFirst = false;
  List<BaseItemDto>? mixTracks, itemTracks;
  List<BaseItemDto>? libraryTracks, genres;
  Completer<void>? started;
  Completer<List<BaseItemDto>>? response;
  List<BaseItemDto> get albums => [
    for (final id in ['one', 'two', 'three'])
      BaseItemDto(id: BaseItemId(id), name: id, type: 'MusicAlbum', childCount: 8),
  ];
  @override
  Future<List<BaseItemDto>?> getInstantMix(BaseItemDto item, {int? limit}) async {
    calls++;
    if (started?.isCompleted == false) started!.complete();
    if (response != null) return response!.future;
    if (fail) throw StateError('server unavailable');
    if (empty) return [];
    if (narrowFirst && calls == 1) return [for (var i = 0; i < 10; i++) _track('narrow$i', 'Artist 0')];
    return [_seed, ...?mixTracks, if (mixTracks == null) ..._pool()];
  }

  @override
  Future<List<BaseItemDto>?> getSimilarAlbums(BaseItemId id, {int? limit}) async => empty ? [] : albums;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName != #getItems) return super.noSuchMethod(invocation);
    itemCalls++;
    if (fail) return Future<List<BaseItemDto>?>.error(StateError('server unavailable'));
    final parent = invocation.namedArguments[#parentItem] as BaseItemDto?;
    final ids = invocation.namedArguments[#itemIds] as List<BaseItemId>?;
    if (ids != null) {
      return Future<List<BaseItemDto>?>.value(
        (itemTracks ?? [_seed, ..._pool()]).where((item) => ids.contains(item.id)).toList(),
      );
    }
    if (invocation.namedArguments[#includeItemTypes] == 'MusicGenre') {
      return Future<List<BaseItemDto>?>.value(
        genres ?? [BaseItemDto(id: const BaseItemId('rock'), name: 'Rock', type: 'MusicGenre')],
      );
    }
    final items = empty
        ? <BaseItemDto>[]
        : parent?.type == 'MusicAlbum'
        ? [for (var i = 0; i < 8; i++) _track('${parent!.id.raw}-$i', parent.id.raw, album: parent.id.raw)]
        : invocation.namedArguments[#includeItemTypes] == 'MusicAlbum'
        ? albums
        : libraryTracks ?? _pool();
    return Future<List<BaseItemDto>?>.value(items);
  }
}

class _Audio extends Fake implements AudioServiceHelper {
  List<BaseItemDto> tracks = _pool();
  @override
  Future<(List<BaseItemDto>, int)?> getShuffleAllTracks({
    required bool onlyShowFavorites,
    required BaseItemDto library,
    BaseItemDto? genreFilter,
    int? itemCount,
  }) async => (tracks, tracks.length);
}

class _User extends Fake implements FinampUserHelper {
  @override
  FinampUser? get currentUser => null;
}

class _Downloads extends Fake implements DownloadsService {}

class _LocalHttp extends HttpOverrides {}

class _Player extends Fake implements MusicPlayerBackgroundTask {
  @override
  bool karaokeActive = false;
  @override
  final BehaviorSubject<MediaItem?> mediaItem = BehaviorSubject.seeded(null);
  @override
  Future<void> refreshPlaybackStateAndMediaNotification() async {}
}

class _SavedKaraokeService extends Fake implements KaraokeService {
  final List<SavedKaraoke> songs = [];
  final List<String> deleted = [];
  @override
  Future<List<SavedKaraoke>> savedSongs() async => [...songs];
  @override
  Future<void> deleteLocal(String id) async {
    deleted.add(id);
    songs.removeWhere((saved) => saved.item.id.raw == id);
  }
}

class _PlayOn extends Fake implements PlayOnService {
  @override
  SocketState get socketState => SocketState.connected;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FinampSettings settings;
  late ProviderContainer providers;
  late _Queue queue;
  late _Api api;
  late _Audio audio;
  late PathProviderPlatform oldPaths;
  late SharedPreferencesAsyncPlatform? oldPrefs;
  late ProviderSubscription<RadioCacheState?> subscription;
  RadioCacheState? state;
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('finamp-radio-refill-');
    Hive.init(directory.path);
    final box = await Hive.openBox<FinampSettings>('FinampSettings');
    settings =
        FinampSettings(
            downloadLocations: [],
            downloadLocationsMap: {},
            tabSortBy: {},
            tabSortOrder: {},
            homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
            gridImageSize: 130,
            homeScreenImageSize: 90,
            deviceId: 'test',
          )
          ..radioEnabled = true
          ..radioMode = RadioMode.similar
          ..shuffleRandomness = 0;
    await box.put('FinampSettings', settings);
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    queue = _Queue();
    api = _Api();
    providers = ProviderContainer();
    GetIt.instance.registerSingleton<QueueService>(queue);
    GetIt.instance.registerSingleton<JellyfinApiHelper>(api);
    audio = _Audio();
    GetIt.instance.registerSingleton<AudioServiceHelper>(audio);
    GetIt.instance.registerSingleton<DownloadsService>(_Downloads());
    GetIt.instance.registerSingleton<FinampUserHelper>(_User());
    GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(_Player());
    GetIt.instance.registerSingleton<ProviderContainer>(providers);
    await providers.read(finampSettingsProvider.future);
    radio.invalidateRadioCache();
    state = null;
    subscription = providers.listen(radio.radioStateProvider, (_, next) => state = next, fireImmediately: true);
    await settle();
  });
  tearDown(() async {
    await PartyService.stop();
    settings.radioEnabled = false;
    radio.invalidateRadioCache();
    await settle();
    subscription.close();
    providers.dispose();
    await GetIt.instance<MusicPlayerBackgroundTask>().mediaItem.close();
    await queue.stream.close();
    await GetIt.instance.reset();
    await Hive.close();
    PathProviderPlatform.instance = oldPaths;
    SharedPreferencesAsyncPlatform.instance = oldPrefs;
    // The directory was created by this test and contains only its Hive/skip data.
    await directory.delete(recursive: true);
  });

  for (final mode in RadioMode.values) {
    test('${mode.name} refills the actual queue with ten upcoming songs', () async {
      settings.radioMode = mode;
      radio.invalidateRadioCache();
      await radio.maybeAddRadioTracks();
      await settle();
      expect(queue.info.upcomingTrackCount, greaterThanOrEqualTo(10));
      expect(state?.loading, false);
      expect(state?.failed, false);
      final items = queue.info.fullQueue.map((item) => item.baseItem).toList();
      expect(items.map((item) => item.id).toSet().length, items.length);
      if (mode != RadioMode.albumMix) {
        for (var i = 1; i < items.length; i++) {
          expect(ArtistSpacing.artistKey(items[i]), isNot(ArtistSpacing.artistKey(items[i - 1])));
        }
      } else {
        expect(queue.info.queue.length, 16);
        for (var offset = 0; offset < 16; offset += 8) {
          expect(queue.info.queue.skip(offset).take(8).map((item) => item.baseItem.albumId).toSet().length, 1);
        }
      }
    });
  }

  test('a same-artist response broadens before it can collapse to one queued song', () async {
    api.narrowFirst = true;
    await radio.maybeAddRadioTracks();
    expect(queue.info.upcomingTrackCount, 10);
    expect(api.calls, 2);
  });

  test('starting a new Radio queue retains unused preview songs across queue callbacks', () async {
    await radio.startRadioPlaybackWithTracks(_seed, RadioMode.similar, _pool());
    await settle();
    expect(queue.info.upcomingTrackCount, 29);
    expect(state?.tracks.length, 11);
    expect(state?.queueId, 'started');
    expect(state?.loading, false);
  });

  test('saved station identity follows its queue and every automatic refill', () async {
    await radio.startRadioPlaybackWithTracks(
      _seed,
      RadioMode.similar,
      _pool(),
      stationId: 'evening',
      stationName: 'Evening station',
    );
    await settle();
    await radio.maybeAddRadioTracks();
    expect(queue.info.source.djStationId, 'evening');
    expect(queue.info.source.name.localizationParameter, 'Evening station');
    expect(queue.info.upcomingTrackCount, greaterThanOrEqualTo(10));
    expect(queue.info.fullQueue.every((item) => item.source.djStationId == 'evening'), isTrue);
  });

  for (final mode in RadioMode.values) {
    test('${mode.name} preview and playback begin with the song originally picked', () async {
      final preview = await radio.generateRadioPreview(_seed, radioMode: mode);
      expect(preview.tracks.first.id, _seed.id);
      expect(preview.tracks.where((item) => item.id == _seed.id).length, 1);
      expect(queue.info.id, 'queue');
      await radio.startRadioPlaybackWithTracks(_seed, mode, preview.tracks);
      await settle();
      for (var i = 0; i < 100 && (queue.info.upcomingTrackCount < 10 || (state?.loading ?? false)); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(queue.info.currentTrack!.baseItem.id, _seed.id);
      expect(queue.startingIndex, 0);
      expect(queue.info.queue.map((item) => item.baseItem.id), isNot(contains(_seed.id)));
      expect(queue.info.upcomingTrackCount, greaterThanOrEqualTo(10));
      expect(state?.loading, false);
    });
  }

  test('a picked song stays first after a different playing song by the same artist', () async {
    final playing = _track('playing', 'Seed');
    queue.info.currentTrack = _queued(playing, _source());
    await radio.startRadioPlaybackWithTracks(_seed, RadioMode.similar, _pool(), keepCurrentTrack: true);
    expect(queue.info.currentTrack!.baseItem.id, playing.id);
    expect(queue.info.queue.first.baseItem.id, _seed.id);
    expect(queue.pinnedReplacement, true);
    expect(queue.info.queue.where((item) => item.baseItem.id == _seed.id).length, 1);
  });

  test('starting from the song already playing continues it without queuing it again', () async {
    await radio.startRadioPlaybackWithTracks(_seed, RadioMode.similar, [_seed, ..._pool()], keepCurrentTrack: true);
    expect(queue.info.currentTrack!.baseItem.id, _seed.id);
    expect(queue.info.queue.map((item) => item.baseItem.id), isNot(contains(_seed.id)));
    expect(queue.pinnedReplacement, false);
    expect(queue.info.upcomingTrackCount, 30);
  });

  test('a chosen CarPlay preview row stays first in the upcoming mix', () async {
    final tapped = _pool()[3];
    await radio.startRadioPlaybackWithTracks(
      _seed,
      RadioMode.similar,
      [_seed, ..._pool()],
      keepCurrentTrack: true,
      startingTrack: tapped,
    );
    expect(queue.info.currentTrack!.baseItem.id, _seed.id);
    expect(queue.info.queue.first.baseItem.id, tapped.id);
    expect(queue.pinnedReplacement, true);
    expect(queue.info.queue.where((item) => item.baseItem.id == tapped.id).length, 1);
  });

  test('a cancelled Radio request never starts its original song later', () async {
    api.started = Completer();
    api.response = Completer();
    final start = radio.startRadioPlayback(_seed);
    await api.started!.future;
    radio.invalidateRadioCache();
    api.response!.complete(_pool());
    await start;
    expect(queue.info.id, 'queue');
    expect(queue.startingIndex, isNull);
    expect(queue.info.queue, isEmpty);
  });

  test('an empty related-song response still starts the picked song', () async {
    api.empty = true;
    await radio.startRadioPlayback(_seed);
    for (var i = 0; i < 30; i++) {
      await settle();
      if (state?.failed ?? false) break;
    }
    expect(queue.info.id, 'started');
    expect(queue.info.currentTrack!.baseItem.id, _seed.id);
    expect(queue.startingIndex, 0);
    expect(state?.loading, false);
  });

  for (final mode in [RadioMode.random, RadioMode.reshuffle]) {
    test('${mode.name} can reuse played source songs on the next cycle', () async {
      settings.radioMode = mode;
      queue.info.previousTracks.addAll(_pool().map((item) => _queued(item, _source())));
      radio.invalidateRadioCache();
      await radio.maybeAddRadioTracks();
      expect(queue.info.upcomingTrackCount, 10);
    });
  }

  test('Reshuffle recovers when its remaining song needs a new artist separator', () async {
    settings.radioMode = RadioMode.reshuffle;
    final songs = [for (var i = 0; i < 3; i++) _track('a$i', 'A'), _track('b', 'B')];
    audio.tracks = songs;
    radio.invalidateRadioCache();
    await radio.maybeAddRadioTracks();
    expect(queue.info.queue.length, 3);
    queue.info.previousTracks.add(queue.info.currentTrack!);
    queue.info.previousTracks.addAll(queue.info.queue.take(2));
    queue.info.currentTrack = queue.info.queue.last;
    queue.info.queue.clear();
    expect(queue.info.currentTrack!.baseItem.artists, ['A']);
    // The short source backs off, then a later playback event can start the next cycle.
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    await radio.maybeAddRadioTracks();
    expect(queue.info.queue, isNotEmpty);
    expect(queue.info.queue.first.baseItem.artists, ['B']);
    expect(queue.info.queue.map((item) => item.baseItem.id.raw), contains('a2'));
  });

  test('Similar can use the playing song when a library queue has no source item', () async {
    queue.info.source = const QueueItemSource.rawId(
      type: QueueItemSourceType.allTracks,
      id: 'all',
      name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'All tracks'),
    );
    radio.invalidateRadioCache();
    await radio.maybeAddRadioTracks();
    expect(queue.info.upcomingTrackCount, 10);
  });

  test('only actually appended tracks are consumed and Continuous follows the real tail', () async {
    settings.radioMode = RadioMode.continuous;
    queue.limitFirstAppend = true;
    radio.invalidateRadioCache();
    await radio.maybeAddRadioTracks();
    await settle();
    expect(queue.appends, 2);
    expect(queue.info.upcomingTrackCount, 10);
    expect(state?.seedItem?.id, queue.info.queue.last.baseItem.id);
    expect(queue.info.queue.map((item) => item.baseItem.id).toSet().length, 10);
  });

  test('a replaced queue discards an in-flight mix', () async {
    api.started = Completer();
    api.response = Completer();
    final refill = radio.maybeAddRadioTracks();
    await api.started!.future;
    queue.info.id = 'replacement';
    settings.radioEnabled = false;
    api.response!.complete(_pool());
    await refill;
    expect(queue.info.queue, isEmpty);
    expect(queue.appends, 0);
  });

  test('replacing the queue while loading automatically refills the new session', () async {
    api.started = Completer();
    api.response = Completer();
    final response = api.response!;
    final refill = radio.maybeAddRadioTracks();
    await api.started!.future;
    queue.info.id = 'replacement';
    api.response = null;
    response.complete(_pool());
    await refill;
    for (var i = 0; i < 30 && queue.info.upcomingTrackCount < 10; i++) {
      await settle();
    }
    expect(queue.info.upcomingTrackCount, 10);
    expect(queue.appends, 1);
    await settle();
    expect(state?.loading, false);
  });

  test('manual queue edits during media preparation prevent a stale append', () async {
    queue.prepared = Completer();
    queue.preparing = Completer();
    final refill = radio.maybeAddRadioTracks();
    await queue.prepared!.future;
    queue.info.queue.add(_queued(_track('manual', 'Manual'), _source()));
    queue.preparing!.complete();
    await refill;
    expect(queue.info.queue.map((item) => item.baseItem.id.raw), ['manual']);
    expect(queue.appends, 0);
    await settle();
    expect(state?.loading, false);
  });

  test('append failure retains candidates and releases the lock for retry', () async {
    queue.failAppend = true;
    await radio.maybeAddRadioTracks();
    await settle();
    expect(state?.loading, false);
    expect(state?.failed, true);
    expect(state?.tracks, isNotEmpty);
    final calls = api.calls;
    await radio.maybeAddRadioTracks();
    expect(api.calls, calls);
    queue.failAppend = false;
    radio.invalidateRadioCache();
    await radio.maybeAddRadioTracks();
    expect(queue.info.upcomingTrackCount, 10);
  });

  test('failed searches are bounded and repeated events respect retry backoff', () async {
    api.fail = true;
    await radio.maybeAddRadioTracks();
    await settle();
    expect(api.calls + api.itemCalls, 4);
    expect(state?.loading, false);
    expect(state?.failed, true);
    await Future.wait(List.generate(20, (_) => radio.maybeAddRadioTracks()));
    expect(api.calls + api.itemCalls, 4);
    api.fail = false;
    radio.invalidateRadioCache();
    await radio.maybeAddRadioTracks();
    expect(queue.info.upcomingTrackCount, 10);
  });

  test('rapid refill events share a single pending request', () async {
    api.started = Completer();
    api.response = Completer();
    final refill = radio.maybeAddRadioTracks();
    await api.started!.future;
    await Future.wait(List.generate(20, (_) => radio.maybeAddRadioTracks()));
    expect(api.calls, 1);
    api.response!.complete(_pool());
    await refill;
    expect(queue.info.upcomingTrackCount, 10);
    expect(queue.appends, 1);
  });

  test('Album Mix stops when every fallback is exhausted', () async {
    api.empty = true;
    settings.radioMode = RadioMode.albumMix;
    radio.invalidateRadioCache();
    await radio.maybeAddRadioTracks().timeout(const Duration(seconds: 2));
    await settle();
    expect(queue.info.queue, isEmpty);
    expect(api.itemCalls, lessThanOrEqualTo(10));
    expect(state?.loading, false);
    expect(state?.failed, true);
  });

  for (final mode in [RadioMode.similar, RadioMode.continuous, RadioMode.random, RadioMode.reshuffle]) {
    for (final percent in [0, 50, 100]) {
      test('${mode.name} fills the actual queue at $percent percent discovery', () async {
        final pool = [
          for (var i = 0; i < 40; i++)
            _track('mixed$i', 'Artist ${i % 4}')
              ..userData = UserItemDataDto(
                playbackPositionTicks: 0,
                playCount: i < 20 ? 3 : 0,
                isFavorite: false,
                played: i < 20,
              ),
        ];
        api.mixTracks = pool;
        audio.tracks = pool;
        settings.radioMode = mode;
        await RadioPreferencesStore.save(RadioPreferences(discovery: percent));
        radio.invalidateRadioCache();
        await radio.maybeAddRadioTracks();
        expect(queue.info.queue.length, 10);
        expect(queue.info.queue.where((item) => item.baseItem.userData?.played != true).length, (percent / 10).round());
      });
    }
  }

  test('retuning Radio preserves the current song and explicit Next Up requests', () async {
    final manual = _track('manual', 'Manual');
    queue.info.nextUp.add(_queued(manual, QueueItemSource.fromBaseItem(manual)));
    queue.info.queue.addAll(_pool().take(10).map((item) => _queued(item, _source())));
    await RadioPreferencesStore.save(const RadioPreferences(excludedArtists: ['artist0']));
    await queue.retuneRadio(seed: _seed);
    expect(queue.info.currentTrack!.baseItem.id, _seed.id);
    expect(queue.info.nextUp.single.baseItem.id, manual.id);
    expect(queue.info.queue, hasLength(9));
    expect(queue.info.queue.any((item) => ArtistSpacing.artistKey(item.baseItem) == 'artist0'), false);
  });

  test('a selected genre broadens to that genre even when the seed belongs to another', () async {
    api.genres = [BaseItemDto(id: const BaseItemId('jazz'), name: 'Jazz', type: 'MusicGenre')];
    api.libraryTracks = [
      for (var i = 0; i < 20; i++) _track('jazz$i', 'Jazz artist ${i % 2}')..genres = ['Jazz'],
    ];
    await RadioPreferencesStore.save(const RadioPreferences(genres: ['Jazz']));
    await radio.maybeAddRadioTracks();
    expect(queue.info.queue.length, 10);
    expect(queue.info.queue.every((item) => item.baseItem.genres!.contains('Jazz')), true);
    expect(queue.info.currentTrack!.baseItem.id, _seed.id);
  });

  Future<void> showScreen(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: UncontrolledProviderScope(
          container: providers,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: child,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Radio controls save discovery and station choices on a narrow screen', (tester) async {
    settings.radioEnabled = false;
    await showScreen(tester, const RadioControlsScreen());
    await tester.scrollUntilVisible(find.byType(Slider), 250);
    tester.widget<Slider>(find.byType(Slider)).onChanged!(75);
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Save and update Radio'), 250);
    await tester.tap(find.text('Save and update Radio'));
    await tester.pumpAndSettle();
    expect((await RadioPreferencesStore.load()).discovery, 75);
    await tester.scrollUntilVisible(find.byTooltip('Save station'), 250);
    await tester.tap(find.byTooltip('Save station'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'My station');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await RadioPreferencesStore.stations()).single.name, 'My station');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('More like this reads the playing song at press time', (tester) async {
    settings.radioEnabled = false;
    await showScreen(tester, const RadioControlsScreen());
    final next = _track('new-current', 'Other');
    final manual = _track('manual-next', 'Manual');
    queue.info.nextUp.add(_queued(manual, QueueItemSource.fromBaseItem(manual)));
    queue.info.queue.addAll(_pool().map((item) => _queued(item, QueueItemSource.fromBaseItem(item))));
    queue.info.currentTrack = _queued(next, _source());
    queue.stream.add(queue.info);
    await tester.pump();
    await tester.scrollUntilVisible(find.text('More like the playing song'), 250);
    await tester.runAsync(() async {
      await tester.tap(find.text('More like the playing song'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(queue.retunedSeed?.id, next.id);
    expect(queue.info.currentTrack!.baseItem.id, next.id);
    expect(queue.info.nextUp.single.baseItem.id, manual.id);
    expect(queue.info.queue.length, 9);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Karaoke dashboard paginates server jobs and hides inaccessible library items', (tester) async {
    settings.radioEnabled = false;
    final first = _track('a' * 32, 'A'), last = _track('b' * 32, 'B');
    api.itemTracks = [first, last];
    final offsets = <String>[];
    final service = KaraokeService(
      settings: () async => (url: 'https://server', token: 'test'),
      client: MockClient((request) async {
        offsets.add(request.url.queryParameters['offset']!);
        final more = request.url.queryParameters['offset'] != '0';
        final ids = more
            ? [last.id.raw]
            : [first.id.raw, for (var i = 0; i < 49; i++) i.toRadixString(16).padLeft(32, '0')];
        return http.Response(
          jsonEncode({
            'items': [
              for (final id in ids) {'id': id, 'state': 'ready', 'revision': 'c' * 64},
            ],
            'total': 51,
          }),
          200,
        );
      }),
    );
    await showScreen(tester, KaraokeDashboardScreen(service: service));
    expect(find.text(first.name!), findsOneWidget);
    expect(find.text('Song ${'0' * 32}'), findsNothing);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(offsets, ['0', '50']);
    expect(find.text(last.name!), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Listen Together refresh replaces the group list without a runtime error', (tester) async {
    GetIt.instance.registerSingleton<PlayOnService>(_PlayOn());
    var calls = 0;
    await showScreen(
      tester,
      ListenTogetherScreen(
        loadGroups: () async {
          calls++;
          return [
            (id: 'group-$calls', name: 'Group $calls', participants: ['Listener'], state: 'Idle'),
          ];
        },
      ),
    );
    expect(find.text('Group 1'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byType(IconButton)));
    await tester.pumpAndSettle();
    expect(find.text('Group 2'), findsOneWidget);
    expect(find.text('Group 1'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Server mix deletion requires confirmation and refreshes the dashboard', (tester) async {
    final item = _track('a' * 32, 'A');
    api.itemTracks = [item];
    var deletes = 0;
    final service = KaraokeService(
      settings: () async => (url: 'https://server', token: 'test'),
      client: MockClient((request) async {
        if (request.method == 'DELETE') {
          expect(request.url.queryParameters['revision'], 'c' * 64);
          deletes++;
          return http.Response('{"state":"missing"}', 200);
        }
        return http.Response(
          jsonEncode({
            'items': [
              if (deletes == 0) {'id': item.id.raw, 'state': 'queued', 'revision': 'c' * 64},
            ],
            'total': deletes == 0 ? 1 : 0,
          }),
          200,
        );
      }),
    );
    await showScreen(tester, KaraokeDashboardScreen(service: service));
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete server mixes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(deletes, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deletes, 0);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete server mixes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, 'Delete server mixes'));
    await tester.pumpAndSettle();
    expect(deletes, 1);
    expect(find.text(item.name!), findsNothing);
    expect(find.textContaining('No karaoke preparations yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Phone deletion requires confirmation and refreshes saved karaoke', (tester) async {
    final service = _SavedKaraokeService();
    final item = _track('a' * 32, 'A');
    service.songs.add((
      item: item,
      job: KaraokeJob.fromJson({'state': 'ready', 'revision': 'c' * 64}),
      guides: [0, 25],
    ));
    await showScreen(tester, SavedKaraokeScreen(service: service));
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from phone'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.deleted, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.deleted, isEmpty);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from phone'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, 'Delete from phone'));
    await tester.pumpAndSettle();
    expect(service.deleted, [item.id.raw]);
    expect(find.text(item.name!), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('The phone copy cannot be deleted while selected for karaoke playback', (tester) async {
    final service = _SavedKaraokeService();
    final item = queue.info.currentTrack!.baseItem;
    (GetIt.instance<MusicPlayerBackgroundTask>() as _Player).karaokeActive = true;
    service.songs.add((item: item, job: KaraokeJob.fromJson({'state': 'ready', 'revision': 'c' * 64}), guides: [0]));
    await showScreen(tester, SavedKaraokeScreen(service: service));
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from phone'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Switch to another song'), findsOneWidget);
    expect(service.deleted, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test("a party request keeps the guest's cleaned-up dedication for the DJ", () async {
    PartyService.votingEnabled = true;
    PartyService.autoAccept = true;
    final base = Uri.parse(await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0));
    final client = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(client.close);
    final result = await client.post(
      base.replace(path: '/api/add'),
      body: jsonEncode({'id': 'song1', 'guest': 'Sam', 'message': 'For "Tom"\n, happy birthday ${'x' * 200}'}),
    );
    expect((jsonDecode(result.body) as Map)['ok'], true);
    final request = PartyService.voting.requests.single;
    expect(request.message, startsWith('For Tom , happy birthday'));
    expect(request.message.length, PartyService.maxMessage);
    await PartyService.stop();
  });

  test('party HTTP rejects old links, duplicate votes, excess requests and malformed bodies', () async {
    PartyService.votingEnabled = true;
    PartyService.autoAccept = true;
    final base = Uri.parse(await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0));
    final client = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(client.close);
    final wrong = base.replace(path: '/api/state', queryParameters: {'k': 'wrong'});
    expect((await client.get(wrong)).statusCode, 403);
    final malformed = await client.post(base.replace(path: '/api/add'), body: '{');
    expect(malformed.statusCode, 400);
    expect((await client.post(base.replace(path: '/api/add'), body: 'x' * 5000)).statusCode, 413);
    for (var i = 0; i < 4; i++) {
      final result =
          jsonDecode(
                (await client.post(
                  base.replace(path: '/api/add'),
                  body: jsonEncode({'id': 'song$i', 'guest': '<b>Guest</b>'}),
                )).body,
              )
              as Map;
      expect(result['ok'], i < 3);
    }
    final request = PartyService.voting.requests.first;
    final vote =
        jsonDecode((await client.post(base.replace(path: '/api/vote'), body: jsonEncode({'id': request.id}))).body)
            as Map;
    expect(vote['ok'], false);
    expect(request.voters, hasLength(1));
    final state = (await client.get(base.replace(path: '/api/state'))).body;
    expect(state, isNot(contains('address')));
    expect(state, contains('votes'));
    await PartyService.queueWinner(now: true);
    expect(queue.info.nextUp, hasLength(1));
    expect(PartyService.voting.requests, hasLength(2));
    await PartyService.queueWinner();
    expect(queue.info.nextUp, hasLength(1));
    final nextBase = Uri.parse(await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0));
    expect(
      (await client.get(nextBase.replace(path: '/api/state', queryParameters: base.queryParameters))).statusCode,
      403,
    );
    expect(PartyService.voting.requests, isEmpty);
  });

  test('party requests keep duplicate and per-guest limits after songs enter Next Up', () async {
    PartyService.votingEnabled = false;
    PartyService.autoAccept = true;
    api.itemTracks = [for (var i = 0; i < 4; i++) _track('party$i', 'Singer $i')];
    final base = Uri.parse(await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0));
    final client = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(client.close);
    Future<Map<String, dynamic>> request(int i) async =>
        jsonDecode(
              (await client.post(
                base.replace(path: '/api/add'),
                body: jsonEncode({'id': 'party$i', 'guest': 'Guest'}),
              )).body,
            )
            as Map<String, dynamic>;
    expect((await request(0))['ok'], isTrue);
    expect((await request(0))['duplicate'], isTrue);
    expect(queue.info.nextUp.length, 1);
    expect((await request(1))['ok'], isTrue);
    expect((await request(2))['ok'], isTrue);
    expect((await request(3))['tooMany'], isTrue);
    queue.info.nextUp.removeAt(0);
    expect((await request(3))['ok'], isTrue);
    expect(queue.info.nextUp.length, 3);
    queue.info.nextUp.clear();
    expect((await request(0))['ok'], isTrue);
    expect((await request(1))['ok'], isTrue);
    expect((await request(2))['ok'], isTrue);
    expect((await request(3))['tooMany'], isTrue);
  });

  test('party reserves pending native additions and releases a failed addition for retry', () async {
    PartyService.votingEnabled = false;
    PartyService.autoAccept = true;
    api.itemTracks = [_track('one', 'A'), _track('two', 'B')];
    final base = Uri.parse(await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0));
    final client = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(client.close);
    Future<http.Response> request(String id) =>
        client.post(base.replace(path: '/api/add'), body: jsonEncode({'id': id}));
    queue.nextUpStarted = Completer<void>();
    queue.nextUpRelease = Completer<void>();
    final first = request('one');
    await queue.nextUpStarted!.future;
    expect((jsonDecode((await request('one')).body) as Map)['duplicate'], isTrue);
    queue.nextUpRelease!.complete();
    expect((jsonDecode((await first).body) as Map)['ok'], isTrue);
    queue.failNextUp = true;
    expect((await request('two')).statusCode, 500);
    queue.failNextUp = false;
    expect((jsonDecode((await request('two')).body) as Map)['ok'], isTrue);
    expect(queue.info.nextUp.map((item) => item.baseItem.id.raw), ['one', 'two']);
  });

  test('party voting cannot request a song again while its winner is still queued', () async {
    PartyService.votingEnabled = true;
    PartyService.autoAccept = true;
    final track = _track('winner', 'Singer');
    api.itemTracks = [track];
    final base = Uri.parse(await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0));
    final client = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(client.close);
    Future<Map<String, dynamic>> request() async =>
        jsonDecode(
              (await client.post(
                base.replace(path: '/api/add'),
                body: jsonEncode({'id': track.id.raw, 'guest': 'Guest'}),
              )).body,
            )
            as Map<String, dynamic>;
    expect((await request())['ok'], isTrue);
    await PartyService.queueWinner(now: true);
    expect(queue.info.nextUp.length, 1);
    expect((await request())['duplicate'], isTrue);
    expect(PartyService.voting.requests, isEmpty);
  });

  test('a party winner remains available after a failed native queue append', () async {
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    PartyService.voting.add(PartyRequest(track: _track('party', 'Guest'), guest: 'G', address: 'guest'));
    queue.failNextUp = true;
    await expectLater(PartyService.queueWinner(now: true), throwsStateError);
    expect(PartyService.voting.requests, hasLength(1));
    queue.failNextUp = false;
    await PartyService.queueWinner(now: true);
    expect(PartyService.voting.requests, isEmpty);
    expect(queue.info.nextUp.single.baseItem.id.raw, 'party');
  });

  test('automatic party queueing gives voting time and remains single-flight', () async {
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    final request = PartyRequest(track: _track('early', 'Guest'), guest: 'G', address: 'guest');
    PartyService.voting.add(request);
    await PartyService.queueWinner();
    expect(queue.info.nextUp, isEmpty);
    PartyService.voting.clear();
    PartyService.voting.add(
      PartyRequest(
        track: _track('old', 'Guest'),
        guest: 'G',
        address: 'guest',
        time: DateTime.now().subtract(const Duration(seconds: 20)),
      ),
    );
    await Future.wait(List.generate(20, (_) => PartyService.queueWinner()));
    expect(queue.info.nextUp.length, 1);
    expect(PartyService.voting.requests, isEmpty);
  });
}
