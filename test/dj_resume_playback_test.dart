import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback_navigation.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Player extends Fake implements MusicPlayerBackgroundTask {
  @override
  final playbackState = BehaviorSubject.seeded(PlaybackState(playing: true));
  @override
  bool get karaokeActive => false;
  @override
  Duration get playerDuration => const Duration(minutes: 3);
  @override
  Duration playbackPosition = Duration.zero;
}

class _Queue extends Fake implements QueueService {
  _Queue(int number, {Duration? resumedAt, bool withNext = false}) {
    source = QueueItemSource.rawId(
      type: QueueItemSourceType.radio,
      name: const QueueItemSourceName(type: QueueItemSourceNameType.radio),
      id: 'resume-test-$number',
    );
    final current = track('current-$number');
    info = FinampQueueInfo(
      id: 'queue-$number',
      previousTracks: [],
      currentTrack: current,
      nextUp: [],
      queue: withNext ? [track('next-$number')] : [],
      source: source,
      saveState: SavedQueueState.saving,
      sourceLibrary: null,
      playbackStart: resumedAt == null ? null : (queueItemId: current.id, position: resumedAt),
    );
  }
  late QueueItemSource source;
  late FinampQueueInfo info;
  FinampQueueItem track(String id) => FinampQueueItem(
    item: MediaItem(id: id, title: id, artist: 'Artist'),
    source: source,
  );
  @override
  FinampQueueInfo getQueue() => info;
  @override
  FinampQueueItem? getCurrentTrack() => info.currentTrack;
}

class _CountedTracks extends ListBase<FinampQueueItem> {
  _CountedTracks(this.items);
  final List<FinampQueueItem> items;
  int reads = 0;
  @override
  int get length => items.length;
  @override
  set length(int value) => throw UnsupportedError('Read only');
  @override
  FinampQueueItem operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, FinampQueueItem value) => throw UnsupportedError('Read only');
}

class _CountedShow extends DjShowSettings {
  _CountedShow({String name = 'Test station'}) : super(identityEnabled: true, stationName: name);
  int serializations = 0;
  @override
  Map<String, dynamic> toJson() {
    serializations++;
    return super.toJson();
  }
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('DJ did not reach the expected state');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? oldPreferences;
  late PathProviderPlatform oldPaths;
  late Directory folder;
  late _Player player;
  late _Queue queue;
  late Completer<http.Response> response;
  final prompts = <String>[];
  var number = 0;

  setUp(() async {
    oldPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    oldPaths = PathProviderPlatform.instance;
    folder = await Directory.systemTemp.createTemp('finamp-resume-dj-');
    PathProviderPlatform.instance = _Paths(folder.path);
    player = _Player();
    response = Completer<http.Response>();
    prompts.clear();
    number++;
    await AiService.setProvider(AiProvider.gemini);
    await AiService.setApiKey(AiProvider.gemini, 'test-key');
  });
  tearDown(() async {
    player.playbackState.add(PlaybackState(playing: false));
    await Future<void>.delayed(Duration.zero);
    await GetIt.instance.reset();
    await DjVoiceService.initialize();
    if (!response.isCompleted) {
      response.complete(
        http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text': jsonEncode({'line': 'The next song is ready.'}),
                    },
                  ],
                },
              },
            ],
          }),
          200,
        ),
      );
    }
    await _until(() => !DjVoiceService.status.value.$2);
    await player.playbackState.close();
    PathProviderPlatform.instance = oldPaths;
    SharedPreferencesAsyncPlatform.instance = oldPreferences;
    await folder.delete(recursive: true);
  });

  Future<void> run(
    Future<void> Function() check, {
    Duration? resumedAt,
    bool withNext = false,
    bool paused = false,
    bool navigatedBeforeStartup = false,
  }) => http.runWithClient(
    () async {
      queue = _Queue(number, resumedAt: resumedAt, withNext: withNext);
      if (navigatedBeforeStartup) {
        PlaybackNavigation.shared
            .begin(PlaybackNavigationKind.restart, queueId: queue.info.id)
            .complete(targetItemId: queue.info.currentTrack!.id);
      }
      if (paused) player.playbackState.add(PlaybackState(playing: false));
      GetIt.instance.registerSingleton<QueueService>(queue);
      GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
      await DjVoiceService.saveProfile(
        const DjVoiceProfile(
          settings: (mode: DjVoiceMode.always, every: 1, character: DjVoiceCharacter.pirate, aiVoice: true, volume: .7),
        ),
      );
      await DjVoiceService.initialize();
      await check();
    },
    () => MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-3.8-flash-tts'},
            ],
          }),
          200,
        );
      }
      prompts.add(request.body);
      return response.future;
    }),
  );

  test(
    'restoring at 75 percent does not generate a fresh opening',
    () => run(() async {
      player.playbackPosition = const Duration(seconds: 135);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(prompts, isEmpty);
      expect(DjVoiceService.status.value.$1, isFalse);
    }, resumedAt: const Duration(seconds: 135)),
  );

  test(
    'saved resume context suppresses an opening before the native position arrives',
    () => run(() async {
      expect(player.playbackPosition, Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(prompts, isEmpty);
      player.playbackPosition = const Duration(seconds: 135);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(prompts, isEmpty);
    }, resumedAt: const Duration(seconds: 135)),
  );

  test(
    'paused restore remains a resume when Play is pressed later',
    () => run(
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        player.playbackState.add(PlaybackState(playing: true));
        await Future<void>.delayed(const Duration(milliseconds: 750));
        expect(prompts, isEmpty);
      },
      resumedAt: const Duration(seconds: 135),
      paused: true,
    ),
  );

  test(
    'actual mid-song position is a backstop when restore context is unavailable',
    () => run(() async {
      player.playbackPosition = const Duration(seconds: 135);
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(prompts, isEmpty);
    }),
  );

  test(
    'a real beginning still generates the opening',
    () => run(() async {
      await _until(() => prompts.isNotEmpty);
      expect(prompts.single, contains('as the first song starts'));
    }, resumedAt: Duration.zero),
  );

  test(
    'navigation before DJ initialization is remembered without a false greeting',
    () => run(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(prompts, isEmpty);
    }, navigatedBeforeStartup: true),
  );

  test(
    'a pending skip cannot announce the outgoing track during its native seek',
    () => run(() async {
      final command = PlaybackNavigation.shared.begin(PlaybackNavigationKind.next, queueId: queue.info.id);
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(prompts, isEmpty);
      queue.info.currentTrack = queue.track('selected-$number');
      command.complete(targetItemId: queue.info.currentTrack!.id);
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(prompts, isEmpty);
    }),
  );

  test(
    'resumed playback still prepares the next scheduled song',
    () => run(
      () async {
        player.playbackPosition = const Duration(seconds: 135);
        await _until(() => prompts.isNotEmpty);
        expect(prompts.single, contains('next-$number'));
        expect(prompts.single, isNot(contains('as the first song starts')));
      },
      resumedAt: const Duration(seconds: 135),
      withNext: true,
    ),
  );

  test(
    'DJ preparation inspects a bounded preview of a large queue',
    () => run(() async {
      final tracks = _CountedTracks(List.generate(5000, (index) => queue.track('upcoming-$index')));
      queue.info.queue = tracks;
      await _until(() => prompts.isNotEmpty);
      expect(tracks.reads, inInclusiveRange(3, 8));
      expect(queue.info.queue.length, 5000);
    }),
  );

  for (final kind in [
    PlaybackNavigationKind.seekForward,
    PlaybackNavigationKind.seekBackward,
    PlaybackNavigationKind.restart,
  ]) {
    test(
      '${kind.name} cancels generation without replaying the opening',
      () => run(() async {
        await _until(() => prompts.isNotEmpty);
        final navigation = PlaybackNavigation.shared.begin(kind, queueId: queue.info.id);
        player.playbackPosition = kind == PlaybackNavigationKind.seekForward
            ? const Duration(seconds: 135)
            : Duration.zero;
        navigation.complete(targetItemId: queue.info.currentTrack!.id);
        await _until(() => !DjVoiceService.status.value.$2);
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(prompts, hasLength(1));
        expect(DjVoiceService.status.value.$1, isFalse);
      }),
    );
  }

  for (final kind in [PlaybackNavigationKind.next, PlaybackNavigationKind.previous, PlaybackNavigationKind.select]) {
    test(
      '${kind.name} discards stale speech and does not mistake another source for a new mix',
      () => run(() async {
        await _until(() => prompts.isNotEmpty);
        final navigation = PlaybackNavigation.shared.begin(kind, queueId: queue.info.id);
        final chosen = FinampQueueItem(
          item: MediaItem(id: 'chosen-$number', title: 'Chosen'),
          source: QueueService.savedQueueSource,
        );
        queue.info.currentTrack = chosen;
        navigation.complete(targetItemId: chosen.id);
        await _until(() => !DjVoiceService.status.value.$2);
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(prompts, hasLength(1));
      }),
    );
  }

  test(
    'seeking beyond the opening without a command signal still cancels a late request',
    () => run(() async {
      await _until(() => prompts.isNotEmpty);
      player.playbackPosition = const Duration(seconds: 135);
      await _until(() => !DjVoiceService.status.value.$2);
      expect(prompts, hasLength(1));
    }),
  );

  test(
    'restoring the same playlist with regenerated entry IDs discards its old opening',
    () => run(() async {
      await _until(() => prompts.isNotEmpty);
      final replacement = _Queue(number, resumedAt: const Duration(seconds: 135));
      replacement.info.id = 'reloaded-$number';
      queue.info = replacement.info;
      expect(player.playbackPosition, Duration.zero);
      await _until(() => !DjVoiceService.status.value.$2);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(prompts, hasLength(1));
    }),
  );

  test(
    'a handled skip does not block announcements after the next natural track change',
    () => run(() async {
      await _until(() => prompts.isNotEmpty);
      final command = PlaybackNavigation.shared.begin(PlaybackNavigationKind.next, queueId: queue.info.id);
      queue.info.currentTrack = queue.track('manually-selected-$number');
      command.complete(targetItemId: queue.info.currentTrack!.id);
      await _until(() => !DjVoiceService.status.value.$2);
      await Future<void>.delayed(const Duration(milliseconds: 750));
      queue.info.currentTrack = queue.track('naturally-advanced-$number');
      queue.info.queue = [queue.track('following-$number')];
      player.playbackPosition = const Duration(seconds: 135);
      await _until(() => prompts.length == 2);
      expect(prompts.last, contains('following-$number'));
    }),
  );

  test(
    'a completed skip waits for delayed queue metadata without introducing either track as a new mix',
    () => run(() async {
      final outgoing = queue.info.currentTrack!;
      final chosen = FinampQueueItem(
        item: MediaItem(id: 'chosen-delayed-$number', title: 'Chosen'),
        source: QueueService.savedQueueSource,
      );
      final command = PlaybackNavigation.shared.begin(
        PlaybackNavigationKind.next,
        queueId: queue.info.id,
        fromItemId: outgoing.id,
      );
      command.complete(targetItemId: chosen.id);
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(prompts, isEmpty);
      queue.info.currentTrack = chosen;
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(prompts, isEmpty);
    }),
  );

  test(
    'a late older skip cannot override Back or silence later natural announcements',
    () => run(() async {
      final current = queue.info.currentTrack!;
      final older = PlaybackNavigation.shared.begin(
        PlaybackNavigationKind.next,
        queueId: queue.info.id,
        fromItemId: current.id,
      );
      PlaybackNavigation.shared
          .begin(PlaybackNavigationKind.previous, queueId: queue.info.id, fromItemId: current.id)
          .complete(targetItemId: current.id);
      await Future<void>.delayed(const Duration(milliseconds: 750));
      older.complete(targetItemId: queue.track('outdated-$number').id);
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(prompts, isEmpty);
      queue.info.currentTrack = queue.track('natural-after-back-$number');
      queue.info.queue = [queue.track('following-after-back-$number')];
      player.playbackPosition = const Duration(seconds: 135);
      await _until(() => prompts.isNotEmpty);
      expect(prompts.single, contains('following-after-back-$number'));
    }),
  );

  test(
    'ordinary playback ticks reuse the profile while a saved edit still applies immediately',
    () => run(() async {
      player.playbackPosition = const Duration(seconds: 135);
      final show = _CountedShow();
      await DjVoiceService.saveProfile((await DjVoiceService.loadProfile()).copyWith(show: show));
      show.serializations = 0;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(show.serializations, 0);
      final edited = _CountedShow(name: 'Edited station');
      await DjVoiceService.saveProfile((await DjVoiceService.loadProfile()).copyWith(show: edited));
      expect(DjVoiceService.effectiveProfile.show, same(edited));
      edited.serializations = 0;
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(edited.serializations, 0);
      expect(prompts, isEmpty);
    }),
  );
}
