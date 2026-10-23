import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_recordings.dart';
import 'package:finamp/services/dj_voice_settings.dart';
import 'package:finamp/services/offline_dj_library.dart';
import 'package:finamp/services/offline_mix_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

BaseItemDto song(String id) => BaseItemDto(id: BaseItemId(id), name: id, artists: ['Artist'], type: 'Audio');
const source = QueueItemSource.rawId(
  type: QueueItemSourceType.playlist,
  id: 'mix',
  name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Mix'),
);
FinampQueueItem entry(String id) => FinampQueueItem(
  source: source,
  item: MediaItem(id: id, title: id, extras: {'itemJson': song(id).toJson()}),
);
OfflineDjMix mix() => OfflineDjMix(
  id: '11111111-1111-4111-8111-111111111111',
  playlist: song('playlist'),
  tracks: [song('a'), song('b')],
  profile: const DjVoiceProfile(musicUnderVoice: .17),
  includeDj: true,
  createdAt: DateTime.utc(2026),
  stationId: 'station',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late OfflineDjLibrary library;
  late PathProviderPlatform oldPaths;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-offline-dj-');
    library = OfflineDjLibrary(Directory('${folder.path}/voices'), scope: 'account');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(folder.path);
  });
  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    await folder.delete(recursive: true);
  });

  test(
    'cancel stops paid batches, offline mode makes no requests, and retry fills only missing announcements',
    () async {
      Hive.registerAdapters();
      Hive.registerAdapter(ThemeModeAdapter());
      Hive.registerAdapter(ColorAdapter());
      Hive.registerAdapter(LocaleAdapter());
      Hive.init(folder.path);
      final box = await Hive.openBox<FinampSettings>('FinampSettings');
      final settings = FinampSettings(
        downloadLocations: [],
        downloadLocationsMap: {},
        tabSortBy: {},
        tabSortOrder: {},
        homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
        gridImageSize: 130,
        homeScreenImageSize: 90,
        deviceId: 'test',
      );
      await box.put('FinampSettings', settings);
      final oldPrefs = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      try {
        await AiService.setProvider(AiProvider.gemini);
        await AiService.setApiKey(AiProvider.gemini, 'test');
        final active = await OfflineDjLibrary.current();
        final saved = OfflineDjMix(
          id: mix().id,
          playlist: song('playlist'),
          tracks: [song('a'), song('b')],
          profile: const DjVoiceProfile(length: DjAnnouncementLength.brief),
          includeDj: true,
          createdAt: DateTime.utc(2026),
        );
        await active.add(saved);
        final pcm = ByteData(8000 * 2 * 2);
        for (var i = 0; i < 8000 * 2; i++) {
          pcm.setInt16(i * 2, (3000 * sin(i * .1)).round(), Endian.little);
        }
        final response = http.Response(
          jsonEncode({
            'candidates': [
              {
                'finishReason': 'STOP',
                'content': {
                  'parts': [
                    {
                      'inlineData': {'mimeType': 'audio/L16;rate=8000', 'data': base64Encode(pcm.buffer.asUint8List())},
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
        final first = Completer<http.Response>();
        final entered = Completer<void>();
        var calls = 0;
        await http.runWithClient(
          () async {
            final job = OfflineMixService.prepare(saved);
            await entered.future.timeout(const Duration(seconds: 5));
            OfflineMixService.cancel(saved);
            first.complete(response);
            await job;
            expect(saved.voices, isEmpty);
            expect(OfflineMixService.preparing.value, isEmpty);
            settings.isOffline = true;
            await OfflineMixService.prepare(saved);
            expect(calls, 1);
            settings.isOffline = false;
            await OfflineMixService.prepare(saved);
            expect(calls, 3);
            expect(await active.hasVoice(saved, 'a'), isTrue);
            expect(await active.hasVoice(saved, 'b'), isTrue);
            await OfflineMixService.prepare(saved);
            expect(calls, 3, reason: 'Saved announcements must not be regenerated');
            await OfflineMixService.clearVoices(saved);
            expect(saved.voices, isEmpty);
            expect(await active.copyVoice(saved, 'a'), isNull);
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
            if (++calls == 1) {
              entered.complete();
              return first.future;
            }
            return response;
          }),
        );
      } finally {
        SharedPreferencesAsyncPlatform.instance = oldPrefs;
        await Hive.close();
      }
    },
  );

  test('queue snapshot starts at current song, respects Next Up and excludes history/duplicates', () {
    final queue = FinampQueueInfo(
      id: 'queue',
      previousTracks: [entry('past')],
      currentTrack: entry('a'),
      nextUp: [entry('b')],
      queue: [entry('a'), for (var i = 0; i < 60; i++) entry('s$i')],
      source: source,
      saveState: SavedQueueState.saving,
      sourceLibrary: null,
    );
    expect(OfflineMixService.snapshot(queue, 20).map((s) => s.id.raw), ['a', 'b', for (var i = 0; i < 18; i++) 's$i']);
    expect(OfflineMixService.snapshot(queue, 50), hasLength(50));
    expect(() => OfflineMixService.snapshot(queue, 51), throwsArgumentError);
  });

  test('saved announcements and profile survive restart, missing files remain retryable', () async {
    final saved = mix();
    await library.add(saved);
    final input = await File('${folder.path}/input.wav').writeAsBytes(List.filled(100, 1));
    await library.saveVoice(saved, 'a', DjAudioClip(input, 'Here is A'));
    final restarted = OfflineDjLibrary(library.root, scope: 'account');
    await restarted.load();
    final loaded = restarted.mixes.single;
    expect(loaded.profile.musicUnderVoice, .17);
    expect(loaded.stationId, 'station');
    expect(await restarted.hasVoice(loaded, 'a'), isTrue);
    expect(await restarted.hasVoice(loaded, 'b'), isFalse);
    final clip = (await restarted.copyVoice(loaded, 'a'))!;
    expect(clip.text, 'Here is A');
    await restarted.clearVoices(loaded);
    expect(loaded.includeDj, isFalse);
    expect(await clip.file.exists(), isTrue);
    expect(await input.exists(), isTrue);
    expect(await restarted.copyVoice(loaded, 'a'), isNull);
    expect(
      (await restarted.root.list(recursive: true).toList()).whereType<File>().map((f) => f.path),
      everyElement(endsWith('manifest.json')),
    );
  });

  test('clearing or deleting a mix prevents late voice writes and preserves unrelated files', () async {
    final saved = mix();
    await library.add(saved);
    final input = await File('${folder.path}/music.wav').writeAsBytes(List.filled(100, 1));
    await library.clearVoices(saved);
    await library.saveVoice(saved, 'a', DjAudioClip(input, 'Late line'));
    expect(saved.voices, isEmpty);
    await library.remove(saved);
    await library.saveVoice(saved, 'a', DjAudioClip(input, 'Later line'));
    expect(await input.exists(), isTrue);
    expect(library.mixes, isEmpty);
    expect(await library.root.list().toList(), isEmpty);
  });

  test('invalid paths and incomplete manifests cannot affect other mixes', () async {
    final saved = mix();
    await library.add(saved);
    final values = saved.toJson();
    values['voices'] = {
      'a': {'file': '../music.wav', 'text': 'Bad path'},
    };
    expect(OfflineDjMix.fromJson(values).voices, isEmpty);
    values['id'] = '../outside';
    expect(() => OfflineDjMix.fromJson(values), throwsFormatException);
    final broken = Directory('${library.root.path}/22222222-2222-4222-8222-222222222222');
    await broken.create();
    await File('${broken.path}/manifest.json').writeAsString(jsonEncode({'incomplete': true}));
    final restarted = OfflineDjLibrary(library.root, scope: 'account');
    await restarted.load();
    expect(restarted.mixes, hasLength(1));
  });
}
