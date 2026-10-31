import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/screens/offline_mixes_screen.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/favorite_provider.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/lock_screen_lyrics_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/normalization_session.dart';
import 'package:finamp/services/playback_history_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/adapters.dart';

class _Server extends Fake implements JellyfinApiHelper {
  int fetches = 0;
  bool favorite = false;
  @override
  Future<BaseItemDto> getItemById(BaseItemId itemId) async {
    fetches++;
    return BaseItemDto(
      id: itemId,
      userData: UserItemDataDto(playbackPositionTicks: 0, playCount: 0, isFavorite: favorite, played: false),
    );
  }
}

class _Downloads extends Fake implements DownloadsService {
  @override
  bool? isFavorite(BaseItemDto item) => null;
}

class _User extends Fake implements FinampUserHelper {
  @override
  final currentUser = FinampUser(
    id: 'user',
    publicAddress: 'https://server.invalid',
    localAddress: '',
    preferLocalNetwork: false,
    isLocal: false,
    accessToken: 'test',
    serverId: 'server',
  );
}

class _Queue extends Fake implements QueueService {
  _Queue(this.items);
  final List<FinampQueueItem> items;
  int reads = 0;
  @override
  FinampPlaybackOrder get playbackOrder => FinampPlaybackOrder.linear;
  @override
  FinampQueueInfo getQueue() {
    reads++;
    return FinampQueueInfo(
      id: 'queue',
      previousTracks: [],
      currentTrack: items.first,
      nextUp: [],
      queue: items.sublist(1),
      source: QueueService.savedQueueSource,
      saveState: SavedQueueState.saving,
      sourceLibrary: null,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late FinampSettings settings;

  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-battery-');
    Hive.init(folder.path);
    final box = await Hive.openBox<FinampSettings>('FinampSettings');
    settings = FinampSettings(
      downloadLocations: [],
      downloadLocationsMap: {},
      tabSortBy: {},
      tabSortOrder: {},
      homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
      gridImageSize: 130,
      homeScreenImageSize: 90,
      deviceId: 'test',
      isOffline: false,
      volumeNormalizationActive: true,
      volumeNormalizationMode: VolumeNormalizationMode.albumOnly,
    );
    await box.put('FinampSettings', settings);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.close();
    await folder.delete(recursive: true);
  });

  group('the favourite in the playback state', () {
    late _Server server;
    late ProviderContainer providers;
    var changes = 0;
    final song = BaseItemDto(id: BaseItemId('song'), name: 'Song', type: 'Audio').toJson(setOffline: false);
    final other = BaseItemDto(id: BaseItemId('other'), name: 'Other', type: 'Audio').toJson(setOffline: false);

    setUp(() async {
      server = _Server();
      changes = 0;
      providers = ProviderContainer(
        overrides: [finampSettingsProvider.overrideWith((ref) => Stream.value(settings))],
      );
      // Loaded, as in the app by the time anything plays.
      providers.listen(finampSettingsProvider, (_, _) {});
      await pumpEventQueue();
      GetIt.instance.registerSingleton<JellyfinApiHelper>(server);
      GetIt.instance.registerSingleton<DownloadsService>(_Downloads());
    });

    tearDown(() => providers.dispose());

    test('is asked of the server once per song, however many events it plays through', () async {
      final favorite = CurrentFavorite(providers, () => changes++);
      for (var i = 0; i < 5; i++) {
        favorite.read(song);
        // Room for an unwatched provider to be disposed of between events.
        await pumpEventQueue();
      }
      expect(server.fetches, 1);
      favorite.read(other);
      await pumpEventQueue();
      favorite.read(other);
      await pumpEventQueue();
      expect(server.fetches, 2, reason: 'the next song is asked about once');
      favorite.close();
    });

    test('shows the server\'s answer, and a change made elsewhere, at once', () async {
      server.favorite = true;
      final favorite = CurrentFavorite(providers, () => changes++);
      expect(favorite.read(song), isFalse, reason: 'not known yet');
      await pumpEventQueue();
      expect(changes, 1, reason: 'the notification is refreshed with the answer');
      expect(favorite.read(song), isTrue);
      // Toggled on the player screen, through its own copy of the song.
      providers.read(isFavoriteProvider(BaseItemDto.fromJson(song)).notifier).updateState(false);
      expect(changes, 2);
      expect(favorite.read(song), isFalse);
      favorite.close();
    });
  });

  test('album normalization looks through the queue once per gain worked out', () {
    final items = [
      for (final id in ['a', 'b'])
        FinampQueueItem(
          item: MediaItem(
            id: 'queue-$id',
            title: id,
            extras: {'itemJson': BaseItemDto(id: BaseItemId(id), type: 'Audio').toJson(setOffline: false)},
          ),
          source: QueueItemSource(
            type: QueueItemSourceType.album,
            name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Album'),
            id: BaseItemId('album'),
          ),
        ),
    ];
    final queue = _Queue(items);
    GetIt.instance.registerSingleton<QueueService>(queue);
    GetIt.instance.registerSingleton<FinampUserHelper>(_User());
    final track = items[1].item;
    // Worked out already for this playback, so only whether it's album normalized is looked up.
    NormalizationSession.playback.resolve(
      server: 'server',
      playbackId: track.id,
      context: 'test',
      create: () => const NormalizationSnapshot(source: NormalizationSource.album, gainDb: -3, headroomDb: 0),
    );
    expect(getGainForCurrentPlayback(track, null), -3);
    expect(queue.reads, 1);
    NormalizationSession.playback.clear();
  });

  test('playback reports follow going online and what they say, not every setting saved', () {
    const same = (1.0, FinampLoopMode.none, FinampPlaybackOrder.linear);
    const louder = (0.5, FinampLoopMode.none, FinampPlaybackOrder.linear);
    bool reports({required bool wasOffline, required bool isOffline, Object before = same, Object after = same}) =>
        PlaybackHistoryService.reportsSettingsChange(
          wasOffline: wasOffline,
          isOffline: isOffline,
          before: before,
          after: after,
        );
    expect(reports(wasOffline: false, isOffline: false), isFalse, reason: 'some other setting saved');
    expect(reports(wasOffline: true, isOffline: false), isTrue, reason: 'back online');
    expect(reports(wasOffline: false, isOffline: true), isFalse);
    expect(reports(wasOffline: false, isOffline: false, after: louder), isTrue, reason: 'the volume is reported');
    expect(reports(wasOffline: true, isOffline: true, after: louder), isFalse, reason: 'offline');
  });

  test('lock screen lyrics wake once for the next line, at the speed playing', () {
    const second = 10000000;
    final lines = [
      LyricLine(text: 'one', start: 1 * second),
      LyricLine(text: 'unsynced'),
      LyricLine(text: 'three', start: 3 * second),
      LyricLine(text: 'two', start: 2 * second),
    ];
    const late = Duration(milliseconds: 20);
    expect(LockScreenLyricsService.untilNextLine(lines, 0, 1), const Duration(seconds: 1) + late);
    expect(
      LockScreenLyricsService.untilNextLine(lines, second + second ~/ 2, 1),
      const Duration(milliseconds: 500) + late,
      reason: 'the nearest line after, though listed later',
    );
    expect(LockScreenLyricsService.untilNextLine(lines, 0, 2), const Duration(milliseconds: 500) + late);
    expect(LockScreenLyricsService.untilNextLine(lines, 3 * second, 1), isNull, reason: 'the last line');
    expect(LockScreenLyricsService.untilNextLine(lines, 0, 0), isNull, reason: 'standing still');
  });

  test('the queue save check stops once a paused queue is saved', () {
    expect(QueueService.saveTimerNeeded(paused: false, saveImmediate: false, state: SavedQueueState.saving), isTrue);
    expect(QueueService.saveTimerNeeded(paused: true, saveImmediate: true, state: SavedQueueState.saving), isTrue);
    expect(QueueService.saveTimerNeeded(paused: true, saveImmediate: false, state: SavedQueueState.saving), isFalse);
    expect(
      QueueService.saveTimerNeeded(paused: true, saveImmediate: true, state: SavedQueueState.pendingSave),
      isFalse,
      reason: 'a restored queue is not saved until it plays',
    );
  });

  test('offline mixes look at downloads only while one is still coming', () {
    const ready = (music: 3, voices: 3, ready: true);
    const downloading = (music: 1, voices: 0, ready: false);
    expect(OfflineMixesScreen.pollNeeded([ready, ready], {}), isFalse);
    expect(OfflineMixesScreen.pollNeeded([ready, downloading], {}), isTrue);
    expect(OfflineMixesScreen.pollNeeded([ready], {'mix'}), isTrue, reason: 'being prepared');
    expect(OfflineMixesScreen.pollNeeded([], {}), isFalse);
  });
}
