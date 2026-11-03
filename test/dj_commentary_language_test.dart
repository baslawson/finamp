import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/rolling_reserve_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? oldPreferences;
  late Directory folder;
  late Box<FinampSettings> settings;
  late PathProviderPlatform oldPaths;
  final prompts = <String>[];
  final next = FinampQueueItem(
    item: const MediaItem(id: 'french-title', title: 'La vie en rose', artist: 'Édith Piaf'),
    source: QueueService.savedQueueSource,
  );
  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-dj-language-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(folder.path);
    Hive.init(folder.path);
    settings = await Hive.openBox<FinampSettings>('FinampSettings');
    await settings.put(
      'FinampSettings',
      FinampSettings(
        locale: const Locale('en', 'NZ'),
        downloadLocations: [],
        downloadLocationsMap: {},
        tabSortBy: {},
        tabSortOrder: {},
        homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
        gridImageSize: 130,
        homeScreenImageSize: 90,
        deviceId: 'language-test',
      ),
    );
    oldPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await SharedPreferencesAsync().setString('djVoiceMode', 'off');
    await AiService.setProvider(AiProvider.gemini);
    await AiService.setApiKey(AiProvider.gemini, 'test-key');
    prompts.clear();
    await DjVoiceService.initialize();
  });
  tearDown(() async {
    await Hive.close();
    await folder.delete(recursive: true);
    SharedPreferencesAsyncPlatform.instance = oldPreferences;
    PathProviderPlatform.instance = oldPaths;
  });

  Future<String?> writeLine() => http.runWithClient(
    () => DjVoiceService.writeLine(null, next, [], character: DjVoiceCharacter.dutch),
    () => MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-2.5-flash'},
            ],
          }),
          200,
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      prompts.add(body['contents'][0]['parts'][0]['text'] as String);
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'text': jsonEncode({'line': 'Enjoy La vie en rose by Édith Piaf.'}),
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

  test('English app selection takes precedence over the host device locale', () async {
    await writeLine();
    expect(prompts.single, contains('English (en-NZ)'));
    expect(prompts.single, contains('Write the entire announcement in English'));
  });

  test('foreign titles and earlier announcements retain English narration instructions', () async {
    await SharedPreferencesAsync().setStringList('djVoiceRecentLines', ['Bienvenue, voici votre prochaine chanson.']);
    await DjVoiceService.initialize();
    final line = await writeLine();
    expect(line, contains('La vie en rose'));
    expect(prompts.single, contains('La vie en rose'));
    expect(prompts.single, contains('Earlier announcements and song metadata must not change the narration language'));
    expect(prompts.single, isNot(contains('a Dutch word thrown in')));
  });

  test('an explicit non-English app language is respected', () async {
    final value = settings.get('FinampSettings')!;
    value.locale = const Locale('fr', 'FR');
    await settings.put('FinampSettings', value);
    await writeLine();
    expect(prompts.single, contains('locale: fr-FR'));
    expect(prompts.single, isNot(contains('Write the entire announcement in English')));
  });

  test('reserve voice recordings follow commentary language while music keeps its cache key', () async {
    const profile = DjVoiceProfile();
    final speech = AiSpeechSettings(primary: AiProvider.gemini);
    final english = RollingReserveService.voiceSignature(profile, speech);
    final music = RollingReserveService.musicKey('scope', 'song', false);
    final value = settings.get('FinampSettings')!;
    value.locale = const Locale('fr', 'FR');
    await settings.put('FinampSettings', value);
    expect(RollingReserveService.voiceSignature(profile, speech), isNot(english));
    expect(RollingReserveService.musicKey('scope', 'song', false), music);
    expect(jsonDecode(english)['commentaryLocale'], 'en-NZ');
  });

  test('changing language while Gemini is recording discards late audio without saving a voice file', () async {
    final started = Completer<void>(), release = Completer<void>();
    final pcm = ByteData(24000 * 2 * 3);
    for (var i = 0; i < pcm.lengthInBytes ~/ 2; i++) {
      pcm.setInt16(i * 2, (3000 * sin(2 * pi * 140 * i / 24000)).round(), Endian.little);
    }
    var requests = 0;
    final recording = http.runWithClient(
      () => DjVoiceService.record('Next one: In the Closet, from Michael Jackson.', profile: const DjVoiceProfile()),
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
        requests++;
        started.complete();
        await release.future;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'finishReason': 'STOP',
                'content': {
                  'parts': [
                    {
                      'inlineData': {
                        'mimeType': 'audio/l16;rate=24000',
                        'data': base64Encode(pcm.buffer.asUint8List()),
                      },
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
    await started.future.timeout(const Duration(seconds: 5));
    final value = settings.get('FinampSettings')!;
    value.locale = const Locale('fr', 'FR');
    await settings.put('FinampSettings', value);
    release.complete();
    expect(await recording, isNull);
    expect(requests, 1);
    expect(await folder.list().where((file) => file.path.endsWith('.wav')).isEmpty, isTrue);
  });
}
