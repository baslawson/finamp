import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
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

const _source = QueueItemSource.rawId(
  type: QueueItemSourceType.radio,
  name: QueueItemSourceName(type: QueueItemSourceNameType.radio),
  id: 'test-radio',
);

FinampQueueItem _track(String id) => FinampQueueItem(
  item: MediaItem(id: id, title: 'Song $id', artist: 'Test artist'),
  source: _source,
);

class _Queue extends Fake implements QueueService {
  final info = FinampQueueInfo(
    id: 'prepared-announcement-test',
    previousTracks: [],
    currentTrack: _track('current'),
    nextUp: [],
    queue: [_track('next')],
    source: _source,
    saveState: SavedQueueState.saving,
    sourceLibrary: null,
  );
  @override
  FinampQueueInfo getQueue() => info;
  @override
  FinampQueueItem? getCurrentTrack() => info.currentTrack;
}

Future<void> _until(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for the announcement');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? oldPrefs;
  late PathProviderPlatform oldPaths;
  late Directory directory;
  late _Player player;
  late _Queue queue;
  late String audio;
  var calls = 0;

  setUp(() async {
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await AiService.setProvider(AiProvider.gemini);
    await AiService.setApiKey(AiProvider.gemini, 'test-key');
    oldPaths = PathProviderPlatform.instance;
    directory = await Directory.systemTemp.createTemp('finamp-prepared-dj-');
    PathProviderPlatform.instance = _Paths(directory.path);
    player = _Player();
    queue = _Queue();
    calls = 0;
    final pcm = ByteData(4 * 8000 * 2);
    for (var i = 0; i < 4 * 8000; i++) {
      pcm.setInt16(i * 2, (3000 * sin(2 * pi * 140 * i / 8000)).round(), Endian.little);
    }
    audio = base64Encode(pcm.buffer.asUint8List());
  });

  tearDown(() async {
    player.playbackState.add(PlaybackState(playing: false));
    await Future<void>.delayed(Duration.zero);
    await GetIt.instance.reset();
    await DjVoiceService.initialize();
    await _until(() => !DjVoiceService.status.value.$2);
    await _until(() async => (await directory.list().toList()).isEmpty);
    await player.playbackState.close();
    PathProviderPlatform.instance = oldPaths;
    SharedPreferencesAsyncPlatform.instance = oldPrefs;
    await directory.delete(recursive: true);
  });

  Future<void> preparing(
    Future<void> Function() check, {
    DjShowSettings show = const DjShowSettings(),
    DjAnnouncementLength length = DjAnnouncementLength.brief,
  }) => http.runWithClient(
    () async {
      GetIt.instance.registerSingleton<QueueService>(queue);
      GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
      DjVoiceProfile profile(bool aiVoice) => DjVoiceProfile(
        settings: (
          mode: DjVoiceMode.always,
          every: 1,
          character: DjVoiceCharacter.pirate,
          aiVoice: aiVoice,
          volume: .7,
        ),
        length: length,
        show: show,
      );
      // Observe the first song without requiring native voice playback. Then
      // enter the preparation window, well before the line would be spoken.
      await DjVoiceService.saveProfile(profile(false));
      await DjVoiceService.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 750));
      await DjVoiceService.saveProfile(profile(true));
      player.playbackPosition = const Duration(minutes: 2, seconds: 20);
      await _until(() => calls > 0 && DjVoiceService.status.value.$2);
      await _until(() async => (await directory.list().toList()).isNotEmpty);
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
      if (!request.url.path.contains('-tts')) {
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text': jsonEncode({'line': 'A great tune to keep the music going.'}),
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      }
      calls++;
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'finishReason': 'STOP',
              'content': {
                'parts': [
                  {
                    'inlineData': {'mimeType': 'audio/l16;rate=8000', 'data': audio},
                  },
                ],
              },
            },
          ],
        }),
        200,
      );
    }),
  );

  test(
    'skipping a prepared announcement prevents regenerating it at every-song frequency',
    () => preparing(() async {
      await DjVoiceService.skipAnnouncement();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(calls, 1, reason: 'Dismissed announcements must not be regenerated by the next playback tick');
      expect(await directory.list().toList(), isEmpty);
      expect(player.playbackState.value.playing, isTrue);
      expect(queue.info.currentTrack!.item.id, 'current');
    }),
  );

  test(
    'discarded prepared audio is removed when upcoming songs change',
    () => preparing(() async {
      final oldFile = (await directory.list().toList()).single;
      queue.info.queue = [_track('replacement')];
      await _until(() => calls == 2);
      await _until(() async => !await oldFile.exists());
      expect(player.playbackState.value.playing, isTrue);
      expect(queue.info.currentTrack!.item.id, 'current');
    }),
  );

  test(
    'an enabled co-host is prepared into one clip while music continues unchanged',
    () => preparing(
      () async {
        await _until(() => calls == 2);
        await _until(() async => (await directory.list().toList()).any((file) => file.path.contains('dj-show-')));
        final showFile = (await directory.list().toList()).whereType<File>().singleWhere(
          (file) => file.path.contains('dj-show-'),
        );
        expect(DjVoiceService.wavDuration(await showFile.readAsBytes()), const Duration(milliseconds: 9120));
        expect(player.playbackState.value.playing, isTrue);
        expect(queue.info.currentTrack!.item.id, 'current');
        await DjVoiceService.skipAnnouncement();
        await _until(() async => (await directory.list().toList()).isEmpty);
      },
      show: const DjShowSettings(duoChance: 100, coHost: DjVoiceCharacter.aussieMale),
      length: DjAnnouncementLength.normal,
    ),
  );

  test(
    'changing co-host settings discards prepared audio while the music keeps playing',
    () => preparing(() async {
      final oldFile = (await directory.list().toList()).single;
      final profile = await DjVoiceService.loadProfile();
      await DjVoiceService.saveProfile(
        profile.copyWith(show: profile.show.copyWith(duoChance: 25, coHost: DjVoiceCharacter.trailer)),
      );
      await _until(() => calls == 2);
      await _until(() async => !await oldFile.exists());
      expect(player.playbackState.value.playing, isTrue);
      expect(queue.info.currentTrack!.item.id, 'current');
      await DjVoiceService.skipAnnouncement();
      await _until(() async => (await directory.list().toList()).isEmpty);
    }),
  );

  test(
    'random mode discards a fixed-frequency pending line and switching back restores that frequency',
    () => preparing(() async {
      final profile = await DjVoiceService.loadProfile();
      await DjVoiceService.saveProfile(profile.copyWith(randomTiming: true));
      await _until(() async => (await directory.list().toList()).isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(calls, 1, reason: 'Random mode must wait for its chosen gap instead of keeping the old every-song line');
      expect((await DjVoiceService.loadProfile()).settings.every, 1);
      await DjVoiceService.saveProfile(profile.copyWith(randomTiming: false));
      await _until(() => calls == 2);
      expect(player.playbackState.value.playing, isTrue);
      expect(queue.info.currentTrack!.item.id, 'current');
    }),
  );
}
