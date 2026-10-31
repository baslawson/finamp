import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/screens/radio_controls_screen.dart';
import 'package:finamp/screens/karaoke_dashboard_screen.dart';
import 'package:finamp/screens/saved_karaoke_screen.dart';
import 'package:finamp/screens/karaoke_screen.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/loudness_normalization.dart';
import 'package:finamp/screens/listen_together_screen.dart';
import 'package:finamp/services/playon_service.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/party_relay.dart';
import 'package:finamp/services/party_service.dart';
import 'package:finamp/services/party_tv.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:finamp/services/server_hub_service.dart';
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
  double get playbackSpeed => 1;
  @override
  double get playbackPitch => 1;
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
    bool keepsShape = false,
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

  /// Holds a library search, while set.
  Completer<List<BaseItemDto>?>? searching;

  /// Holds looking songs up by id, while set.
  Completer<void>? lookingUp;
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
    if (searching != null && invocation.namedArguments[#searchTerm] != null) return searching!.future;
    if (fail) return Future<List<BaseItemDto>?>.error(StateError('server unavailable'));
    final parent = invocation.namedArguments[#parentItem] as BaseItemDto?;
    final ids = invocation.namedArguments[#itemIds] as List<BaseItemId>?;
    if (ids != null) {
      final found = (itemTracks ?? [_seed, ..._pool()]).where((item) => ids.contains(item.id)).toList();
      if (lookingUp case final waiting?) return waiting.future.then<List<BaseItemDto>?>((_) => found);
      return Future<List<BaseItemDto>?>.value(found);
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
  final BehaviorSubject<PlaybackState> playbackState = BehaviorSubject.seeded(PlaybackState());
  @override
  Future<void> refreshPlaybackStateAndMediaNotification() async {}

  /// What the karaoke screen asked of the player, in order.
  final karaokeCalls = <String>[];
  @override
  Duration get playbackPosition => Duration.zero;
  @override
  Duration? get playerDuration => const Duration(minutes: 3);
  @override
  String? karaokeMixPath;
  @override
  Future<void> setKaraokeMix({required String queueId, File? file, LoudnessMeasurement? measurement}) async {
    karaokeCalls.add('mix ${file?.path}');
    karaokeActive = file != null || karaokeActive;
    if (file != null) karaokeMixPath = file.path;
  }

  @override
  Future<void> play({bool disableFade = false}) async {
    karaokeCalls.add('play');
    playbackState.add(playbackState.value.copyWith(playing: true));
  }

  @override
  Future<void> pause({bool disableFade = false, PauseBy by = PauseBy.listener, String? cause}) async {
    karaokeCalls.add('pause');
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position, {bool userInitiated = true}) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setPitch(double pitch) async {}
}

/// A song prepared both ways on the server.
class _BothPartsKaraokeService extends Fake implements KaraokeService {
  KaraokeJob _ready(KaraokePart part) => KaraokeJob.fromJson({
    'state': 'ready',
    'part': part.name,
    'revision': {KaraokePart.vocals: 'c', KaraokePart.drums: 'd', KaraokePart.both: 'e'}[part]! * 64,
    'mixes': {
      for (final guide in KaraokeService.guideLevels) '$guide': {'bytes': 4, 'version': 1, 'lufs': -14, 'truePeak': -1},
    },
  });
  @override
  Future<KaraokeJob> status(String id, {bool offline = false, KaraokePart part = KaraokePart.vocals}) async =>
      _ready(part);
  @override
  Future<LyricDto?> savedLyrics(String id) async => null;
  @override
  Future<void> saveLyrics(String id, LyricDto lyrics) async {}
  @override
  Future<List<int>> availableGuides(String id, KaraokeJob job, {bool onlyOffline = false}) async =>
      KaraokeService.guideLevels;
  @override
  Future<File?> localMix(String id, KaraokeJob job, int guide, {bool onlyOffline = false, String? serverUrl}) async =>
      null;
  @override
  Future<File> download(String id, KaraokeJob job, int guide, {bool keepOffline = false, bool offline = false}) async =>
      File('saved/${KaraokeService.mixName(job, guide)}');
}

/// The karaoke screen redraws every frame for the lyrics, so it never settles.
Future<void> karaokeFrames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A TV's live feed from the party, read the way a browser's EventSource does.
/// The server hub as the party relay sees it: guests' requests are handed out one inbox at a time.
class _Hub implements ServerHubService {
  _Hub([this.publicUrl = 'https://music.example.com/finamp-analyzer']);
  @override
  final url = 'http://10.0.0.2:8000';
  final String publicUrl;

  /// Holds the hub's answer to ending a party, while set.
  Completer<void>? ending;

  /// Holds the hub's answer to opening a party again, while set.
  Completer<void>? reopening;
  final calls = <String>[];
  final opened = <Object?>[];
  final _inbox = StreamController<Object>();
  late final _messages = StreamIterator(_inbox.stream);
  final _answers = StreamController<List<dynamic>>();
  late final answers = StreamIterator(_answers.stream);

  /// Hands the phone guests' messages, or the error its next inbox request fails with.
  void send(Object messagesOrError) => _inbox.add(messagesOrError);

  /// The next [count] answers the phone sends, in the order of the messages they answer.
  Future<List<dynamic>> answersFor(int count) async =>
      [for (var i = 0; i < count; i++) ...await nextAnswers()]
        ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));

  /// The phone's next answers.
  Future<List<dynamic>> nextAnswers() async {
    expect(await answers.moveNext(), isTrue);
    return answers.current;
  }

  @override
  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    String? program,
    String contentType = 'audio/wav',
    Duration timeout = const Duration(seconds: 15),
  }) async {
    calls.add('$method $path');
    if (method == 'POST' && path == '/api/parties') {
      opened.add(body);
      if ((body! as Map).isNotEmpty) await reopening?.future;
      return {'id': 'party-0123456789', 'token': 'cap.one/two', 'publicUrl': publicUrl};
    }
    if (method == 'DELETE') await ending?.future;
    if (path.contains('/inbox')) {
      if (!await _messages.moveNext()) return const [];
      final next = _messages.current;
      if (next is Exception) throw next;
      return next;
    }
    if (path.endsWith('/answers')) _answers.add((body! as Map)['answers'] as List);
    return const {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object> _guestMessage(int id, String path, String guest, [Object? body]) => {
  'id': id,
  'method': body == null ? 'GET' : 'POST',
  'path': path,
  'query': const <String, String>{},
  'body': body == null ? '' : (body is String ? body : jsonEncode(body)),
  'guest': guest,
};

class _TvFeed {
  _TvFeed(HttpClientResponse response) : statusCode = response.statusCode {
    var event = '';
    _subscription = response.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('event: ')) event = line.substring(7);
      if (line.startsWith('data: ')) events.add((event: event, data: line.substring(6)));
      final arrived = _arrived;
      _arrived = null;
      arrived?.complete();
    }, onDone: () => closed.isCompleted ? null : closed.complete());
  }

  final int statusCode;
  final events = <({String event, String data})>[];
  final closed = Completer<void>();
  late final StreamSubscription<String> _subscription;
  Completer<void>? _arrived;

  static Future<_TvFeed> open(Uri uri) async {
    final request = await _LocalHttp().createHttpClient(null).getUrl(uri);
    return _TvFeed(await request.close());
  }

  /// The next [event] after the [seen] already read, waiting for it to come.
  Future<String> next(String event, {int seen = 0}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final found = events.skip(seen).where((e) => e.event == event);
      if (found.isNotEmpty) return found.first.data;
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('No "$event" from the party TV feed');
      _arrived = Completer<void>();
      await _arrived!.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    }
  }

  Future<void> cancel() => _subscription.cancel();
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
    // Party tests use this phone's own Wi-Fi link, unless they hand the relay a server hub.
    PartyRelay.connect = () async => null;
    PartyRelay.answerTime = const Duration(seconds: 6);
    PartyService.anywhere = true;
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

  /// Opens the karaoke screen as the song plays [loaded], a saved vocal mix built into its queue entry.
  Future<_Player> openKaraoke(WidgetTester tester, KaraokeScreen screen, {required String loaded}) async {
    final player = GetIt.instance<MusicPlayerBackgroundTask>() as _Player;
    player.karaokeActive = true;
    player.karaokeMixPath = 'saved/$loaded';
    player.playbackState.add(PlaybackState(playing: true));
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: providers,
        child: ProviderScope(
          overrides: [
            currentTrackProvider.overrideWith((ref) => Stream.value(queue.info.currentTrack)),
            currentTrackMetadataProvider.overrideWith((ref) => const AsyncValue.data(null)),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: screen,
          ),
        ),
      ),
    );
    await karaokeFrames(tester);
    return player;
  }

  final vocalMix = '${'c' * 64}-0.flac', vocalMix50 = '${'c' * 64}-50.flac', drumMix = '${'d' * 64}-0.flac';

  testWidgets('Switching a saved karaoke song to drumless plays the drumless mix, not the loaded one', (tester) async {
    final player = await openKaraoke(tester, KaraokeScreen(service: _BothPartsKaraokeService()), loaded: vocalMix);
    await tester.tap(find.text('No drums'));
    await karaokeFrames(tester);
    expect(player.karaokeCalls, ['pause']);
    await tester.tap(find.byTooltip('Play drumless version'));
    await karaokeFrames(tester);
    expect(player.karaokeCalls, ['pause', 'mix saved/$drumMix', 'play']);
    // Now the drumless mix is the one loaded, so the button pauses it.
    await tester.tap(find.byTooltip('Play drumless version'));
    await karaokeFrames(tester);
    expect(player.karaokeCalls, ['pause', 'mix saved/$drumMix', 'play', 'pause']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await karaokeFrames(tester);
  });

  testWidgets('Opening drumless while a saved vocal mix is loaded plays the drumless mix', (tester) async {
    final player = await openKaraoke(
      tester,
      KaraokeScreen(service: _BothPartsKaraokeService(), initialPart: KaraokePart.drums),
      loaded: vocalMix,
    );
    await tester.tap(find.byTooltip('Play drumless version'));
    await karaokeFrames(tester);
    expect(player.karaokeCalls, ['mix saved/$drumMix', 'play']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await karaokeFrames(tester);
  });

  testWidgets('Taking out both plays its own mix with a drum guide', (tester) async {
    final player = await openKaraoke(
      tester,
      KaraokeScreen(service: _BothPartsKaraokeService(), initialPart: KaraokePart.drums),
      loaded: drumMix,
    );
    await tester.tap(find.text('Both'));
    await karaokeFrames(tester);
    expect(player.karaokeCalls, ['pause']);
    expect(find.text('Guide drums'), findsOneWidget);
    await tester.tap(find.byTooltip('Play version without vocals or drums'));
    await karaokeFrames(tester);
    expect(player.karaokeCalls, ['pause', 'mix saved/${'e' * 64}-0.flac', 'play']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await karaokeFrames(tester);
  });

  testWidgets('Switching back to karaoke plays the guide level shown, not the one left loaded', (tester) async {
    final player = await openKaraoke(
      tester,
      KaraokeScreen(service: _BothPartsKaraokeService(), initialGuide: 50),
      loaded: vocalMix50,
    );
    // The loaded 50% mix is the one shown, so the button only pauses it.
    await tester.tap(find.byTooltip('Play karaoke'));
    await karaokeFrames(tester);
    expect(player.karaokeCalls, ['pause']);
    await tester.tap(find.text('No drums'));
    await karaokeFrames(tester);
    await tester.tap(find.text('No vocals'));
    await karaokeFrames(tester);
    expect(find.text('0%'), findsOneWidget);
    await tester.tap(find.byTooltip('Play karaoke'));
    await karaokeFrames(tester);
    expect(player.karaokeCalls, ['pause', 'mix saved/$vocalMix', 'play']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await karaokeFrames(tester);
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

  test('guests away from the Wi-Fi reach the party through the server hub, each as their own guest', () async {
    PartyService.votingEnabled = true;
    PartyService.autoAccept = true;
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    final local = await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    expect(PartyService.url, 'https://music.example.com/finamp-analyzer/hub/party/#cap.one%2Ftwo');
    expect(PartyService.localUrl, local);
    expect(PartyService.relayed, isTrue);
    hub.send([
      _guestMessage(1, '/api/add', 'web:aaaa', {'id': 'song1', 'guest': 'Sam'}),
      _guestMessage(2, '/api/add', 'web:bbbb', '{'),
      _guestMessage(3, '/api/rooms', 'web:bbbb'),
    ]);
    final answers = await hub.answersFor(3);
    expect([for (final answer in answers) (answer['id'], answer['status'])], [(1, 200), (2, 400), (3, 404)]);
    expect((jsonDecode(answers.first['body'] as String) as Map)['ok'], isTrue);
    final request = PartyService.voting.requests.single;
    expect(request.address, 'web:aaaa');
    // Votes count per guest, as on the Wi-Fi.
    hub.send([
      _guestMessage(4, '/api/vote', 'web:bbbb', {'id': request.id}),
      _guestMessage(5, '/api/vote', 'web:aaaa', {'id': request.id}),
      _guestMessage(6, '/api/state', 'web:bbbb'),
    ]);
    final votes = await hub.answersFor(3);
    expect([for (final answer in votes.take(2)) (jsonDecode(answer['body'] as String) as Map)['ok']], [true, false]);
    expect(request.voters, {'web:aaaa', 'web:bbbb'});
    expect(votes.last['body'], contains('"voted":true'));
    // The TV says guests can join from any network.
    expect(jsonDecode(PartyTv.stateForTest()), containsPair('anywhere', true));
  });

  test('the party opens again on a restarted server hub, under the same link, and ends there with the party', () async {
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    final link = PartyService.url;
    hub.send(const ServerHubException('Open the party again', 404));
    hub.send([_guestMessage(1, '/api/state', 'web:aaaa')]);
    expect((await hub.nextAnswers()).single['status'], 200);
    expect(hub.opened, [
      <String, Object>{},
      {'id': 'party-0123456789'},
    ]);
    expect(PartyService.url, link);
    await PartyService.stop();
    expect(hub.calls, contains('DELETE /api/parties/party-0123456789'));
    expect(PartyService.url, isNull);
    expect(PartyService.relayed, isFalse);
  });

  test('without a server hub guests join on the Wi-Fi, and the host can switch joining from anywhere', () async {
    final local = await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    expect(PartyService.url, local);
    expect(PartyService.relayProblem, PartyRelayProblem.noServer);
    expect(jsonDecode(PartyTv.stateForTest()), containsPair('anywhere', false));
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    await PartyService.setAnywhere(false);
    await PartyService.setAnywhere(true);
    expect(PartyService.url, startsWith('https://music.example.com/'));
    expect(PartyService.relayProblem, isNull);
    await PartyService.setAnywhere(false);
    expect(PartyService.url, local);
    expect(hub.calls, contains('DELETE /api/parties/party-0123456789'));
    // A hub that can't be reached says so, and guests keep the Wi-Fi link.
    PartyRelay.connect = () async => throw const SocketException('No route to host');
    await PartyService.setAnywhere(true);
    expect(PartyService.relayProblem, PartyRelayProblem.unreachable);
    expect(PartyService.url, local);
  });

  test('a party ended while it was opening on the server hub is ended there too', () async {
    final hub = _Hub();
    final connecting = Completer<ServerHubService?>();
    PartyRelay.connect = () => connecting.future;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    final opening = PartyService.relayOpening!;
    await PartyService.stop();
    connecting.complete(hub);
    await opening;
    expect(hub.calls, [
      'POST /api/parties',
      'GET /api/parties/party-0123456789/inbox?wait=25',
      'DELETE /api/parties/party-0123456789',
    ]);
    expect(PartyService.url, isNull);
    expect(PartyService.relayed, isFalse);
  });

  test('a guest request through the server hub as the party ends is not acted on', () async {
    PartyService.votingEnabled = false;
    PartyService.autoAccept = true;
    final hub = _Hub()..ending = Completer();
    PartyRelay.connect = () async => hub;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    hub.send([
      _guestMessage(1, '/api/add', 'web:aaaa', {'id': 'song1', 'guest': 'Sam'}),
    ]);
    final stopping = PartyService.stop();
    await settle();
    hub.ending!.complete();
    await stopping;
    expect(queue.info.nextUp, isEmpty);
  });

  test('a party started again while the last one was still opening on the server hub opens its own', () async {
    final connecting = Completer<ServerHubService?>();
    PartyRelay.connect = () => connecting.future;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    final old = _Hub('https://old.example.com');
    await PartyService.stop();
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    expect(PartyService.url, startsWith('https://music.example.com/'));
    connecting.complete(old);
    await settle();
    await settle();
    expect(PartyService.url, startsWith('https://music.example.com/'));
    expect(PartyService.relayProblem, isNull);
    expect(old.calls, contains('DELETE /api/parties/party-0123456789'));
    expect(hub.calls, isNot(contains('DELETE /api/parties/party-0123456789')));
  });

  test('a slow guest request through the server hub does not hold up the others', () async {
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    PartyRelay.answerTime = const Duration(milliseconds: 300);
    api.searching = Completer();
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    hub.send([
      {
        ..._guestMessage(1, '/api/search', 'web:aaaa'),
        'query': {'q': 'queen'},
      },
      _guestMessage(2, '/api/state', 'web:aaaa'),
    ]);
    expect((await hub.nextAnswers()).single['id'], 2);
    // The next guests are heard meanwhile, and the slow one is told to try again.
    hub.send([_guestMessage(3, '/api/state', 'web:bbbb')]);
    expect((await hub.nextAnswers()).single['id'], 3);
    expect([for (final answer in await hub.nextAnswers()) (answer['id'], answer['status'])], [(1, 503)]);
  });

  test('a guest request through the server hub too slow to answer in time is not acted on later', () async {
    PartyService.votingEnabled = false;
    PartyService.autoAccept = true;
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    PartyRelay.answerTime = const Duration(milliseconds: 300);
    api.itemTracks = [_track('party0', 'Singer 0')];
    api.lookingUp = Completer();
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    hub.send([
      _guestMessage(1, '/api/add', 'web:aaaa', {'id': 'party0', 'guest': 'Sam'}),
    ]);
    final late = (await hub.nextAnswers()).single;
    expect(late['status'], 503);
    expect(late['body'], contains('Check Up next'));
    api.lookingUp!.complete();
    // Long enough for the song to have reached Next Up, had it gone ahead.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(queue.info.nextUp, isEmpty);
    expect(PartyService.pending, isEmpty);
  });

  test('a TV reconnecting while the party ends waits for the next one instead of giving up', () async {
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    final tv = Uri.parse(PartyService.tvUrl!);
    hub.ending = Completer();
    final stopping = PartyService.stop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final client = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(client.close);
    expect((await client.get(tv)).statusCode, 503);
    hub.ending!.complete();
    await stopping;
  });

  test('a party ended while opening again on a restarted server hub is ended there too', () async {
    final hub = _Hub()..reopening = Completer();
    PartyRelay.connect = () async => hub;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    hub.send(const ServerHubException('Open the party again', 404));
    await settle();
    await PartyService.stop();
    hub.reopening!.complete();
    await settle();
    await settle();
    expect(hub.calls.where((call) => call.startsWith('POST /api/parties')), hasLength(2));
    expect(hub.calls.where((call) => call == 'DELETE /api/parties/party-0123456789'), hasLength(2));
  });

  test('a guest request the hub has nearly given up on is left alone', () async {
    PartyService.votingEnabled = false;
    PartyService.autoAccept = true;
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    api.itemTracks = [_track('party0', 'Singer 0')];
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    hub.send([
      {
        ..._guestMessage(1, '/api/add', 'web:aaaa', {'id': 'party0', 'guest': 'Sam'}),
        'budget': 1.2,
      },
    ]);
    expect((jsonDecode((await hub.nextAnswers()).single['body'] as String) as Map)['ok'], isFalse);
    expect(queue.info.nextUp, isEmpty);
  });

  test('switching joining from anywhere off and on while it opens still ends up open', () async {
    final hub = _Hub();
    final connecting = Completer<ServerHubService?>();
    PartyRelay.connect = () => connecting.future;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    final off = PartyService.setAnywhere(false);
    hub.ending = Completer();
    connecting.complete(hub);
    await settle();
    PartyRelay.connect = () async => hub;
    final on = PartyService.setAnywhere(true);
    hub.ending!.complete();
    await off;
    await on;
    expect(PartyService.relayed, isTrue);
    expect(PartyService.url, startsWith('https://music.example.com/'));
  });

  test('a party ending while the server hub is slow to hear of it stays ended', () async {
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    hub.ending = Completer();
    final stopping = PartyService.stop();
    await PartyService.setAnywhere(false);
    await PartyService.setAnywhere(true);
    hub.ending!.complete();
    await stopping;
    expect(PartyService.relayed, isFalse);
    expect(hub.opened, hasLength(1));
  });

  test('switching joining from anywhere off and on again quickly keeps the server hub link', () async {
    final hub = _Hub();
    PartyRelay.connect = () async => hub;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    await PartyService.relayOpening;
    hub.ending = Completer();
    final off = PartyService.setAnywhere(false);
    await PartyService.setAnywhere(true);
    hub.ending!.complete();
    await off;
    expect(PartyService.url, startsWith('https://music.example.com/'));
    expect(PartyService.relayed, isTrue);
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
    // A new connection, as a browser makes once the old party closed the last one.
    final nextClient = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(nextClient.close);
    expect(
      (await nextClient.get(nextBase.replace(path: '/api/state', queryParameters: base.queryParameters))).statusCode,
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

  test('the party TV link only shows the screen, follows the party and comes back with the next one', () async {
    PartyService.votingEnabled = true;
    PartyService.autoAccept = true;
    PartyTv.showVotes = true;
    final guest = Uri.parse(await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0));
    final tv = Uri.parse(PartyService.tvUrl!);
    final client = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(client.close);
    final page = await client.get(tv);
    expect(page.statusCode, 200);
    expect(page.body, contains('EventSource'));
    // Each key opens only its own part: the TV can't add or vote, and a guest can't open the TV feed.
    expect((await client.get(tv.replace(path: '/api/state'))).statusCode, 403);
    expect((await client.post(tv.replace(path: '/api/add'), body: jsonEncode({'id': 'song1'}))).statusCode, 403);
    expect((await client.get(guest.replace(path: '/tv'))).statusCode, 403);
    expect((await client.get(tv.replace(queryParameters: {'t': 'wrong'}))).statusCode, 403);
    // The cover of anything but what's playing isn't served.
    final art = tv.replace(path: '/tv/art', queryParameters: {...tv.queryParameters, 'id': 'song1'});
    expect((await client.get(art)).statusCode, 404);

    final feed = await _TvFeed.open(tv.replace(path: '/tv/events'));
    addTearDown(feed.cancel);
    expect(feed.statusCode, 200);
    final first = jsonDecode(await feed.next('state')) as Map<String, dynamic>;
    expect(PartyTv.screens, 1);
    expect((first['qr'] as Map)['path'], isNotEmpty);
    expect((first['now'] as Map)['name'], 'Song seed');
    expect(first['ballot'], isEmpty);

    final seen = feed.events.length;
    await client.post(guest.replace(path: '/api/add'), body: jsonEncode({'id': 'song1', 'guest': 'Sam'}));
    final voting = jsonDecode(await feed.next('state', seen: seen)) as Map<String, dynamic>;
    expect((voting['ballot'] as List).single, containsPair('guest', 'Sam'));

    // While music plays the levels follow, but a quiet phone sends silence only once.
    final beforeBands = feed.events.length;
    GetIt.instance<MusicPlayerBackgroundTask>().playbackState.add(PlaybackState(playing: true));
    expect(await feed.next('b', seen: beforeBands), '00' * 32);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(feed.events.skip(beforeBands).where((e) => e.event == 'b'), hasLength(1));

    final tvKey = tv.queryParameters['t'];
    await PartyService.stop();
    await feed.next('end');
    await feed.closed.future.timeout(const Duration(seconds: 5));
    expect(PartyTv.screens, 0);
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    final next = Uri.parse(PartyService.tvUrl!);
    expect(next.queryParameters['t'], tvKey);
    final nextClient = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(nextClient.close);
    expect((await nextClient.get(next)).statusCode, 200);
  });

  test(
    'a TV joining as something changes leaves the others up to date, and the newest TV takes the oldest place',
    () async {
      PartyService.votingEnabled = true;
      PartyService.autoAccept = true;
      PartyTv.showVotes = true;
      final guest = Uri.parse(await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0));
      final events = Uri.parse(PartyService.tvUrl!).replace(path: '/tv/events');
      final client = IOClient(_LocalHttp().createHttpClient(null));
      addTearDown(client.close);
      final first = await _TvFeed.open(events);
      addTearDown(first.cancel);
      await first.next('state');
      final seen = first.events.length;
      await client.post(guest.replace(path: '/api/add'), body: jsonEncode({'id': 'song1', 'guest': 'Sam'}));
      // Joins while the change is still waiting to go out.
      final second = await _TvFeed.open(events);
      addTearDown(second.cancel);
      final update = jsonDecode(await first.next('state', seen: seen)) as Map<String, dynamic>;
      expect((update['ballot'] as List).single, containsPair('guest', 'Sam'));

      final more = [for (var i = 0; i < PartyTv.maxScreens - 1; i++) await _TvFeed.open(events)];
      for (final feed in more) {
        addTearDown(feed.cancel);
        expect(feed.statusCode, 200);
      }
      await first.closed.future.timeout(const Duration(seconds: 5));
      expect(first.events.last.event, 'replaced');
      expect(PartyTv.screens, PartyTv.maxScreens);
      expect(second.closed.isCompleted, isFalse);
    },
  );

  test('with the usual party port taken, later parties keep the same stand-in port for open TVs', () async {
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: taken.port);
    final first = Uri.parse(PartyService.tvUrl!);
    expect(first.port, isNot(taken.port));
    await PartyService.stop();
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: taken.port);
    expect(Uri.parse(PartyService.tvUrl!), first);
    // Even once the usual port is free again.
    await taken.close();
    await PartyService.stop();
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: taken.port);
    expect(Uri.parse(PartyService.tvUrl!), first);
  });

  test('ending a party while the queue changes does not queue a vote winner on the way out', () async {
    PartyService.votingEnabled = true;
    await PartyService.start(address: InternetAddress.loopbackIPv4, port: 0);
    PartyService.voting.add(
      PartyRequest(
        track: _track('late', 'Guest'),
        guest: 'G',
        address: 'guest',
        time: DateTime.now().subtract(const Duration(minutes: 1)),
      ),
    );
    // A queue change is on its way to the party as it stops.
    queue.stream.add(queue.info);
    await PartyService.stop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(queue.info.nextUp, isEmpty);
  });

  test('party TV band levels are sent as two hex digits each, kept between 0 and 1', () {
    expect(PartyTv.encodeBands([0, 0.5, 1, 2, -1]), '0080ffff00');
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
