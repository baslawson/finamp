import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final String directory;
  @override
  Future<String?> getTemporaryPath() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const line = 'Next up, a little treasure from Queen. Settle in and enjoy the music, my friends.';
  late Directory directory;
  late PathProviderPlatform oldPaths;
  late SharedPreferencesAsyncPlatform? oldPrefs;
  late String audio;
  var calls = 0;
  final voices = <String>[];
  final requests = <Map<String, dynamic>>[];
  Completer<void>? started;
  Completer<void>? release;
  setUp(() async {
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await AiService.setProvider(AiProvider.gemini);
    await AiService.setApiKey(AiProvider.gemini, 'test-key');
    directory = await Directory.systemTemp.createTemp('finamp-dj-test-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    final pcm = ByteData(11 * 8000 * 2);
    for (var i = 0; i < 11 * 8000; i++) {
      pcm.setInt16(i * 2, (3000 * sin(2 * pi * 140 * i / 8000)).round(), Endian.little);
    }
    audio = base64Encode(pcm.buffer.asUint8List());
    calls = 0;
    voices.clear();
    requests.clear();
    started = null;
    release = null;
  });
  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    SharedPreferencesAsyncPlatform.instance = oldPrefs;
    await directory.delete(recursive: true);
  });

  http.Client client() => MockClient((request) async {
    expect(request.headers['x-goog-api-key'], 'test-key');
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
    calls++;
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    requests.add(body);
    voices.add(body['generationConfig']['speechConfig']['voiceConfig']['prebuiltVoiceConfig']['voiceName'] as String);
    if (started != null && !started!.isCompleted) started!.complete();
    if (release != null) await release!.future;
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
  });

  test('a slow character produces a playable WAV on the first Gemini take', () async {
    final result = await http.runWithClient(
      () => AiService.speech(
        line,
        style: DjVoiceService.styleFor(DjVoiceCharacter.pirate),
        voice: (openai: 'fable', gemini: 'Algenib'),
        minimumWordsPerSecond: DjVoiceCharacter.pirate.minimumWordsPerSecond,
      ),
      client,
    );
    expect(result?.extension, 'wav');
    expect(DjVoiceService.wavDuration(result!.bytes), const Duration(milliseconds: 11500));
    expect(calls, 1);
  });

  test('a Gemini recording too long to use is logged with why the voice failed', () async {
    audio = base64Encode(Uint8List(46 * 8000 * 2));
    final warnings = <String>[];
    final subscription = Logger.root.onRecord.listen((record) {
      if (record.loggerName == 'AiService' && record.level == Level.WARNING) warnings.add(record.message);
    });
    addTearDown(subscription.cancel);
    await expectLater(
      http.runWithClient(
        () => AiService.speech(
          line,
          style: DjVoiceService.styleFor(DjVoiceCharacter.energetic),
          voice: (openai: 'fable', gemini: 'Laomedeia'),
          minimumWordsPerSecond: DjVoiceCharacter.energetic.minimumWordsPerSecond,
        ),
        client,
      ),
      throwsA(isA<AiException>()),
    );
    expect(
      warnings,
      contains('Gemini voice failed (Gemini returned an oversized speech recording); checking enabled fallback APIs'),
    );
  });

  test('an Aussie DJ sends explicit English speech control while retaining the verbatim transcript', () async {
    const transcript = 'Next one: In the Closet, from Michael Jackson.';
    audio = base64Encode(base64Decode(audio).sublist(0, 8000 * 2 * 3));
    final file = await http.runWithClient(
      () => DjVoiceService.record(transcript, character: DjVoiceCharacter.aussieMale, profile: const DjVoiceProfile()),
      client,
    );
    expect(file, isNotNull);
    final request = requests.single;
    expect(request['generationConfig']['speechConfig']['languageCode'], 'en-AU');
    final part = request['contents'][0]['parts'][0] as Map<String, dynamic>;
    expect(part['text'], transcript);
    expect(part['speechMetadata']['style'], contains('Read the English transcript verbatim'));
    await file!.delete();
  });

  test('failed commentary still records a natural Gemini voice without exposing the error body', () async {
    final next = FinampQueueItem(
      item: const MediaItem(id: 'starlight', title: 'Starlight', artist: 'Muse'),
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.unknown,
        id: 'aiDj',
        name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Mix'),
      ),
    );
    await DjVoiceService.saveSettings((
      mode: DjVoiceMode.off,
      every: 2,
      character: DjVoiceCharacter.energetic,
      aiVoice: true,
      volume: .7,
    ));
    final warnings = <String>[];
    final subscription = Logger.root.onRecord.listen((record) {
      if (record.loggerName == 'DjVoiceService') warnings.add(record.message);
    });
    var scripts = 0, recordings = 0;
    try {
      final file = await http.runWithClient(
        () async {
          final text = await DjVoiceService.writeLine(null, next, []);
          expect(text, allOf(contains('Starlight'), contains('Muse')));
          return DjVoiceService.record(text!);
        },
        () => MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'models': [
                  {'name': 'models/gemini-3.8-flash'},
                  {'name': 'models/gemini-3.8-flash-tts'},
                ],
              }),
              200,
            );
          }
          if (!request.url.path.contains('-tts')) {
            scripts++;
            return http.Response('{"error":{"message":"private-provider-error-sentinel"}}', 429);
          }
          recordings++;
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'finishReason': 'STOP',
                  'content': {
                    'parts': [
                      {
                        'inlineData': {
                          'mimeType': 'audio/l16;rate=8000',
                          'data': base64Encode(base64Decode(audio).take(8000 * 2 * 2).toList()),
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
      expect(file, isNotNull);
      expect(DjVoiceService.wavDuration(await file!.readAsBytes()), const Duration(milliseconds: 2500));
      expect(scripts, 1);
      expect(recordings, 1);
      expect(AiService.lastSpeechProvider.value, AiProvider.gemini);
      expect(warnings.any((message) => message.contains('HTTP 429')), isTrue);
      expect(warnings.join(), isNot(contains('private-provider-error-sentinel')));
    } finally {
      await subscription.cancel();
    }
  });

  test('normal-rate repeated takes remain rejected rather than played twice', () async {
    await expectLater(
      http.runWithClient(
        () => AiService.speech(line, style: 'Upbeat.', voice: (openai: 'ash', gemini: 'Puck')),
        client,
      ),
      throwsA(isA<AiException>()),
    );
    expect(calls, 2);
  });

  test('changing the DJ while a recording is pending discards the old voice', () async {
    DjVoiceSettings settings(DjVoiceCharacter character) =>
        (mode: DjVoiceMode.off, every: 2, character: character, aiVoice: true, volume: .7);
    await DjVoiceService.saveSettings(settings(DjVoiceCharacter.pirate));
    started = Completer<void>();
    release = Completer<void>();
    final recording = http.runWithClient(() => DjVoiceService.record(line), client);
    await started!.future;
    await DjVoiceService.saveSettings(settings(DjVoiceCharacter.aussieMale));
    release!.complete();
    expect(await recording, isNull);
    expect(await directory.list().toList(), isEmpty);
  });

  test('saving the preview volume with automatic DJ off does not discard the selected voice', () async {
    DjVoiceSettings settings(double volume) =>
        (mode: DjVoiceMode.off, every: 2, character: DjVoiceCharacter.pirate, aiVoice: true, volume: volume);
    await DjVoiceService.saveSettings(settings(.7));
    started = Completer<void>();
    release = Completer<void>();
    final recording = http.runWithClient(() => DjVoiceService.record(line), client);
    await started!.future;
    await DjVoiceService.saveSettings(settings(.8));
    release!.complete();
    final file = await recording;
    expect(file, isNotNull);
    expect(await file!.length(), greaterThan(44));
  });

  test('changing voice APIs discards a pending recording and the next line uses the new API', () async {
    await DjVoiceService.saveSettings((
      mode: DjVoiceMode.off,
      every: 2,
      character: DjVoiceCharacter.pirate,
      aiVoice: true,
      volume: .7,
    ));
    await AiService.setApiKey(AiProvider.openai, 'openai-test-key');
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini, fallbacks: [AiProvider.openai]));
    started = Completer<void>();
    release = Completer<void>();
    final pending = http.runWithClient(() => DjVoiceService.record(line), client);
    await started!.future;
    await DjVoiceService.saveSpeechSettings(
      AiSpeechSettings(primary: AiProvider.openai, fallbacks: [AiProvider.gemini]),
    );
    release!.complete();
    expect(await pending, isNull);
    expect(await directory.list().toList(), isEmpty);
    final next = await http.runWithClient(
      () => DjVoiceService.record(line),
      () => MockClient((request) async {
        expect(request.url.host, 'api.openai.com');
        expect(request.headers['authorization'], 'Bearer openai-test-key');
        return http.Response.bytes(base64Decode(audio), 200);
      }),
    );
    expect(next, isNotNull);
    expect(AiService.lastSpeechProvider.value, AiProvider.openai);
  });

  test('recorded AI voices are balanced without losing speech or output padding', () async {
    await DjVoiceService.saveSettings((
      mode: DjVoiceMode.off,
      every: 2,
      character: DjVoiceCharacter.pirate,
      aiVoice: true,
      volume: .7,
    ));
    final file = await http.runWithClient(() => DjVoiceService.record(line), client);
    final bytes = await file!.readAsBytes();
    expect(DjVoiceService.wavDuration(bytes), const Duration(milliseconds: 11500));
    final pcm = ByteData.sublistView(bytes, 44);
    var energy = 0.0;
    for (var i = 800; i < 10 * 8000; i++) {
      final sample = pcm.getInt16(i * 2, Endian.little) / 32768;
      energy += sample * sample;
    }
    expect(sqrt(energy / (10 * 8000 - 800)), closeTo(0.18, 0.002));
    expect(bytes.skip(bytes.length - 8000).every((byte) => byte == 0), isTrue);
  });

  test('the boost switch affects the final recorded voice after balancing', () async {
    await DjVoiceService.saveSettings((
      mode: DjVoiceMode.off,
      every: 2,
      character: DjVoiceCharacter.pirate,
      aiVoice: true,
      volume: .7,
    ));
    double level(List<int> file) {
      final data = ByteData.sublistView(Uint8List.fromList(file), 44);
      var energy = 0.0;
      for (var i = 800; i < 10 * 8000; i++) {
        final sample = data.getInt16(i * 2, Endian.little) / 32768;
        energy += sample * sample;
      }
      return sqrt(energy / (10 * 8000 - 800));
    }

    final on = await http.runWithClient(() => DjVoiceService.record(line), client);
    await DjVoiceService.saveSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini, boost: false));
    final off = await http.runWithClient(() => DjVoiceService.record(line), client);
    expect(level(await on!.readAsBytes()) / level(await off!.readAsBytes()), closeTo(1.25, .002));
    expect(await on.length(), await off.length());
  });

  test('favourite rotation uses each selected native voice before another cycle', () async {
    await DjVoiceService.saveProfile(
      const DjVoiceProfile(
        settings: (mode: DjVoiceMode.off, every: 2, character: DjVoiceCharacter.energetic, aiVoice: true, volume: .7),
        rotate: true,
        favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer, DjVoiceCharacter.meditation],
      ),
    );
    for (var i = 0; i < 4; i++) {
      expect(await http.runWithClient(() => DjVoiceService.record(line), client), isNotNull);
    }
    expect(voices.take(3).toSet(), {'Algenib', 'Charon', 'Enceladus'});
    expect(voices[3], isNot(voices[2]));
  });

  test('favourite rotation never records the reserved co-host as the main DJ', () async {
    const profile = DjVoiceProfile(
      settings: (mode: DjVoiceMode.off, every: 2, character: DjVoiceCharacter.pirate, aiVoice: true, volume: .7),
      rotate: true,
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer, DjVoiceCharacter.meditation],
      show: DjShowSettings(duoChance: 25, coHost: DjVoiceCharacter.pirate),
    );
    await DjVoiceService.saveProfile(profile);
    for (var i = 0; i < 4; i++) {
      expect(await http.runWithClient(() => DjVoiceService.record(line), client), isNotNull);
    }
    expect(voices.take(2).toSet(), {'Charon', 'Enceladus'});
    expect(voices, isNot(contains('Algenib')));
    expect(voices[0], voices[2]);
    expect(voices[1], voices[3]);
  });

  test('a paused rotation uses the remaining favourite and restores the co-host when disabled', () async {
    const profile = DjVoiceProfile(
      settings: (mode: DjVoiceMode.off, every: 2, character: DjVoiceCharacter.pirate, aiVoice: true, volume: .7),
      rotate: true,
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer],
      show: DjShowSettings(duoChance: 100, coHost: DjVoiceCharacter.pirate),
    );
    await DjVoiceService.saveProfile(profile);
    for (var i = 0; i < 2; i++) {
      expect(await http.runWithClient(() => DjVoiceService.record(line), client), isNotNull);
    }
    expect(voices, ['Charon', 'Charon']);
    await DjVoiceService.saveProfile(profile.copyWith(show: profile.show.copyWith(duoChance: 0)));
    expect(await http.runWithClient(() => DjVoiceService.record(line), client), isNotNull);
    expect(voices.last, 'Algenib');
    await DjVoiceService.saveProfile(profile.copyWith(show: profile.show.copyWith(coHost: DjVoiceCharacter.trailer)));
    expect(await http.runWithClient(() => DjVoiceService.record(line), client), isNotNull);
    expect(voices.last, 'Algenib');
  });

  test('changing the co-host discards an in-flight main recording', () async {
    const profile = DjVoiceProfile(
      settings: (mode: DjVoiceMode.off, every: 2, character: DjVoiceCharacter.pirate, aiVoice: true, volume: .7),
      rotate: true,
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer],
      show: DjShowSettings(duoChance: 25, coHost: DjVoiceCharacter.pirate),
    );
    await DjVoiceService.saveProfile(profile);
    started = Completer<void>();
    release = Completer<void>();
    final pending = http.runWithClient(() => DjVoiceService.record(line), client);
    await started!.future;
    await DjVoiceService.saveProfile(profile.copyWith(show: profile.show.copyWith(coHost: DjVoiceCharacter.trailer)));
    release!.complete();
    expect(await pending, isNull);
    expect(await directory.list().toList(), isEmpty);
  });

  test('Skip announcement discards a pending recording without changing DJ preferences', () async {
    const selected = (mode: DjVoiceMode.off, every: 3, character: DjVoiceCharacter.pirate, aiVoice: true, volume: .6);
    await DjVoiceService.saveSettings(selected);
    started = Completer<void>();
    release = Completer<void>();
    final recording = http.runWithClient(() => DjVoiceService.record(line), client);
    await started!.future;
    await DjVoiceService.skipAnnouncement();
    release!.complete();
    expect(await recording, isNull);
    expect(await DjVoiceService.loadSettings(), selected);
    expect(await directory.list().toList(), isEmpty);
  });
}
