import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/dj_voice_studio.dart';
import 'package:finamp/services/rolling_reserve_service.dart';
import 'package:flutter_test/flutter_test.dart';
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
  late SharedPreferencesAsyncPlatform? oldPrefs;
  late PathProviderPlatform oldPaths;
  late Directory directory;
  late Uint8List pcm;
  final requests = <http.Request>[];
  const line = 'Next up is AC/DC with a classic song from the library.';
  const aussie = DjVoiceProfile(
    settings: (mode: DjVoiceMode.always, every: 2, character: DjVoiceCharacter.aussieMale, aiVoice: true, volume: .7),
  );
  setUp(() async {
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    oldPaths = PathProviderPlatform.instance;
    directory = await Directory.systemTemp.createTemp('finamp-studio-test-');
    PathProviderPlatform.instance = _Paths(directory.path);
    await AiService.setApiKey(AiProvider.openai, 'openai-test-key');
    await AiService.setApiKey(AiProvider.gemini, 'gemini-test-key');
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.openai, boost: false));
    final data = ByteData(24000 * 2 * 2);
    for (var i = 0; i < data.lengthInBytes ~/ 2; i++) {
      data.setInt16(i * 2, (3000 * sin(2 * pi * 140 * i / 24000)).round(), Endian.little);
    }
    pcm = data.buffer.asUint8List();
    requests.clear();
  });
  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    SharedPreferencesAsyncPlatform.instance = oldPrefs;
    await directory.delete(recursive: true);
  });
  http.Response success(http.Request request) {
    if (request.url.host == 'api.openai.com') return http.Response.bytes(pcm, 200);
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
    return http.Response(
      jsonEncode({
        'candidates': [
          {
            'finishReason': 'STOP',
            'content': {
              'parts': [
                {
                  'inlineData': {'mimeType': 'audio/l16;rate=24000', 'data': base64Encode(pcm)},
                },
              ],
            },
          },
        ],
      }),
      200,
    );
  }

  Future<File?> record({
    DjVoiceProfile? selectedProfile,
    AiProvider? forced,
    DjVoiceCharacter? character,
    bool throwOnError = false,
    FutureOr<http.Response> Function(http.Request)? handler,
  }) => http.runWithClient(
    () => DjVoiceService.record(
      line,
      profile: selectedProfile ?? aussie,
      character: character,
      provider: forced,
      throwOnError: throwOnError,
    ),
    () => MockClient((request) async {
      requests.add(request);
      return (handler ?? success)(request);
    }),
  );

  test('empty preferences preserve existing speech routing and migration defaults', () async {
    expect((await DjVoiceStudioSettings.load()).isEmpty, isTrue);
    expect(DjVoiceProfile.fromJson({}).show.active, isFalse);
    expect(await record(), isNotNull);
    expect(requests.single.url.host, 'api.openai.com');
    expect((await AiService.getSpeechSettings()).boost, isFalse);
  });
  test('an Aussie override changes only this character and preserves global text and voice settings', () async {
    final textBefore = (await AiService.getTextSettings()).toJson();
    await DjVoiceService.saveStudioSettings(
      const DjVoiceStudioSettings(
        routes: {DjVoiceCharacter.aussieMale: DjVoiceRoute(AiProvider.gemini, backup: AiProvider.openai)},
      ),
    );
    expect(await record(), isNotNull);
    expect(requests.where((r) => r.method == 'POST').single.url.host, 'generativelanguage.googleapis.com');
    expect(AiService.lastSpeechProvider.value, AiProvider.gemini);
    requests.clear();
    expect(await record(character: DjVoiceCharacter.pirate), isNotNull);
    expect(requests.single.url.host, 'api.openai.com');
    expect((await AiService.getSpeechSettings()).order, [AiProvider.openai]);
    expect((await AiService.getTextSettings()).toJson(), textBefore);
  });
  test('a character uses its enabled backup even when the global voice route has none', () async {
    await const DjVoiceStudioSettings(
      routes: {DjVoiceCharacter.aussieMale: DjVoiceRoute(AiProvider.gemini, backup: AiProvider.openai)},
    ).save();
    expect(
      await record(
        handler: (request) => request.url.host != 'api.openai.com' && request.method == 'POST'
            ? http.Response('unavailable', 503)
            : success(request),
      ),
      isNotNull,
    );
    expect(requests.where((r) => r.method == 'POST').map((r) => r.url.host), [
      'generativelanguage.googleapis.com',
      'api.openai.com',
    ]);
  });
  test('a time-of-day host override follows the main host without leaking into another character', () async {
    const timed = DjVoiceProfile(
      settings: (
        mode: DjVoiceMode.always,
        every: 2,
        character: DjVoiceCharacter.byTimeOfDay,
        aiVoice: true,
        volume: .7,
      ),
    );
    await const DjVoiceStudioSettings(routes: {DjVoiceCharacter.byTimeOfDay: DjVoiceRoute(AiProvider.gemini)}).save();
    expect(await record(selectedProfile: timed), isNotNull);
    expect(AiService.lastSpeechProvider.value, AiProvider.gemini);
    requests.clear();
    expect(await record(selectedProfile: timed, character: DjVoiceCharacter.pirate), isNotNull);
    expect(requests.single.url.host, 'api.openai.com');
  });
  test('an audition uses only the named provider and surfaces billing errors without silent fallback', () async {
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini, fallbacks: [AiProvider.openai]));
    await expectLater(
      record(
        forced: AiProvider.openai,
        throwOnError: true,
        handler: (_) => http.Response('{"error":{"message":"You have no credits remaining."}}', 429),
      ),
      throwsA(isA<AiException>().having((e) => e.message, 'message', contains('no credits'))),
    );
    expect(requests.single.url.host, 'api.openai.com');
    expect((await AiService.getSpeechSettings()).order, [AiProvider.gemini, AiProvider.openai]);
  });
  test('pronunciation affects only the spoken input and handles names literally', () async {
    await const DjVoiceStudioSettings(pronunciations: [DjPronunciation('AC/DC', 'ay see dee see')]).save();
    expect(await record(), isNotNull);
    expect(jsonDecode(requests.single.body)['input'], contains('ay see dee see'));
    expect(line, contains('AC/DC'));
    const studio = DjVoiceStudioSettings(
      pronunciations: [
        DjPronunciation('Queen', 'Kween'),
        DjPronunciation('Queens of the Stone Age', 'Queens ov the Stone Age'),
        DjPronunciation('Kween', 'wrong'),
      ],
    );
    expect(
      studio.spokenText('QUEEN, Queens of the Stone Age, Queenstown, Kween.'),
      'Kween, Queens ov the Stone Age, Queenstown, wrong.',
    );
  });
  test('editing the studio cancels in-flight speech without writing or playing stale audio', () async {
    final started = Completer<void>(), pending = Completer<http.Response>();
    final recording = record(
      handler: (request) {
        started.complete();
        return pending.future;
      },
    );
    await started.future;
    await DjVoiceService.saveStudioSettings(
      const DjVoiceStudioSettings(pronunciations: [DjPronunciation('AC/DC', 'ay see dee see')]),
    );
    expect(await recording.timeout(const Duration(seconds: 5)), isNull);
    pending.complete(http.Response.bytes(pcm, 200));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await directory.list().toList(), isEmpty);
    expect(requests.length, 1);
  });
  test('damaged settings reject unsupported providers, duplicates and malformed dictionary entries', () async {
    final studio = DjVoiceStudioSettings.fromJson({
      'routes': {
        'pirate': {'primary': 'claude'},
        'aussieMale': {'primary': 'gemini', 'backup': 'gemini'},
        'removed': {'primary': 'openai'},
      },
      'pronunciations': [
        null,
        {'name': '', 'spoken': 'bad'},
        {'name': 'Queen', 'spoken': 'Kween'},
        {'name': 'queen', 'spoken': 'duplicate'},
        {'name': 'long', 'spoken': 'x' * 121},
      ],
    });
    expect(studio.routes.length, 1);
    expect(studio.routes[DjVoiceCharacter.aussieMale]!.backup, isNull);
    expect(studio.pronunciations.length, 1);
    await SharedPreferencesAsync().setString('djVoiceStudio', '{broken');
    expect((await DjVoiceStudioSettings.load()).isEmpty, isTrue);
  });
  test('route and dictionary edits cannot reuse an obsolete reserved voice', () {
    final speech = AiSpeechSettings(primary: AiProvider.gemini);
    final original = RollingReserveService.voiceSignature(aussie, speech);
    expect(RollingReserveService.voiceSignature(aussie, speech, studio: const DjVoiceStudioSettings()), original);
    expect(
      RollingReserveService.voiceSignature(
        aussie,
        speech,
        studio: const DjVoiceStudioSettings(pronunciations: [DjPronunciation('AC/DC', 'ay see dee see')]),
      ),
      isNot(original),
    );
    expect(
      RollingReserveService.voiceSignature(
        aussie,
        speech,
        studio: const DjVoiceStudioSettings(routes: {DjVoiceCharacter.aussieMale: DjVoiceRoute(AiProvider.openai)}),
      ),
      isNot(original),
    );
  });
  test('new settings survive station and preset round trips without enabling legacy profiles', () {
    const show = DjShowSettings(
      duoChance: 25,
      coHost: DjVoiceCharacter.pirate,
      identityEnabled: true,
      stationName: 'Bas FM',
      intro: 'Welcome to Bas FM.',
      jingleId: 'test',
      jingleChance: 35,
    );
    final profile = aussie.copyWith(show: show);
    final restored = DjVoiceProfile.fromJson(profile.toJson());
    expect(restored.show.toJson(), show.toJson());
    expect(DjListeningPreset.car.apply(restored).show.toJson(), show.toJson());
    expect(
      DjVoiceProfile.fromJson(
        restored.copyWith(show: show.copyWith(duoChance: 0, identityEnabled: false)).toJson(),
      ).show.coHost,
      DjVoiceCharacter.pirate,
    );
    expect(DjShowSettings.fromJson({'duoChance': double.nan, 'jingleChance': 500, 'coHost': 'removed'}).duoChance, 0);
    expect(DjShowSettings.fromJson({'jingleChance': 500}).jingleChance, 100);
  });
  test('a long station opening cannot crowd out the song introduction for a slow host', () {
    final song = List.filled(30, 'song').join(' ');
    final show = DjShowSettings(identityEnabled: true, intro: List.filled(20, 'welcome').join(' '));
    expect(show.openingFor(song, DjVoiceCharacter.trailer), song);
    expect(show.openingFor(song, DjVoiceCharacter.aussieMale), startsWith('welcome'));
    expect(show.copyWith(identityEnabled: false).openingFor(song, DjVoiceCharacter.aussieMale), song);
  });
}
