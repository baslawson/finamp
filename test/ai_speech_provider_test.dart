import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:finamp/services/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? original;
  late Uint8List pcm;
  final calls = <String>[];
  const line = 'Here comes a favourite from Queen. Turn it up and enjoy the music.';
  setUp(() async {
    original = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await AiService.setProvider(AiProvider.claude);
    await AiService.setApiKey(AiProvider.gemini, 'gemini-test-key');
    await AiService.setApiKey(AiProvider.openai, 'openai-test-key');
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini, fallbacks: [AiProvider.openai]));
    final samples = ByteData(24000 * 2);
    for (var i = 0; i < 24000; i++) {
      samples.setInt16(i * 2, (3000 * sin(2 * pi * 140 * i / 24000)).round(), Endian.little);
    }
    pcm = samples.buffer.asUint8List();
    calls.clear();
  });
  tearDown(() {
    expect(AiService.hasSpeechPreparations, isFalse, reason: 'Completed requests must release cancellation listeners');
    SharedPreferencesAsyncPlatform.instance = original;
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

  MockClient client(FutureOr<http.Response> Function(http.Request) handle) => MockClient((request) async {
    final openai = request.url.host == 'api.openai.com';
    expect(
      request.headers[openai ? 'authorization' : 'x-goog-api-key'],
      openai ? 'Bearer openai-test-key' : 'gemini-test-key',
    );
    expect(request.headers[openai ? 'x-goog-api-key' : 'authorization'], isNull);
    calls.add('${openai ? 'openai' : 'gemini'}:${request.method}');
    return handle(request);
  });

  Future<({List<int> bytes, String extension})?> speak(
    http.Client client, {
    bool Function()? wanted,
    Duration timeout = const Duration(seconds: 60),
  }) => http.runWithClient(
    () => AiService.speech(
      line,
      style: 'Warm and upbeat.',
      voice: (openai: 'ash', gemini: 'Puck'),
      stillWanted: wanted,
      timeout: timeout,
    ),
    () => client,
  );

  test('repeated successful recordings release their cancellation listeners without a settings change', () async {
    for (var i = 0; i < 20; i++) {
      expect(await speak(client(success)), isNotNull);
      expect(AiService.hasSpeechPreparations, isFalse);
    }
  });

  test('voice selection is persisted independently of the text AI', () async {
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.openai, fallbacks: []));
    expect((await AiService.getSpeechSettings()).primary, AiProvider.openai);
    expect((await AiService.getSpeechSettings()).fallbacks, isEmpty);
    expect(await AiService.getProvider(), AiProvider.claude);
    await AiService.setProvider(AiProvider.gemini);
    expect((await AiService.getSpeechSettings()).primary, AiProvider.openai);
  });

  test('migration preserves the existing voice provider and then separates it from text AI', () async {
    await SharedPreferencesAsync().remove('aiSpeechSettings');
    await AiService.setProvider(AiProvider.openai);
    final settings = await AiService.getSpeechSettings();
    expect(settings.primary, AiProvider.openai);
    expect(settings.fallbacks, [AiProvider.gemini]);
    await AiService.setProvider(AiProvider.gemini);
    expect((await AiService.getSpeechSettings()).primary, AiProvider.openai);
  });

  test('a concurrent migration cannot overwrite a newly selected voice API', () async {
    await SharedPreferencesAsync().remove('aiSpeechSettings');
    final migration = AiService.getSpeechSettings();
    final save = AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.openai));
    await migration;
    await save;
    expect((await AiService.getSpeechSettings()).order, [AiProvider.openai]);
  });

  test('damaged preferences recover and unsupported or repeated APIs are excluded', () async {
    await SharedPreferencesAsync().setString('aiSpeechSettings', '{damaged');
    expect(AiSpeechSettings.supported, contains((await AiService.getSpeechSettings()).primary));
    final settings = AiSpeechSettings.fromJson({
      'primary': 'claude',
      'fallbacks': ['openai', 'gemini', 'claude', 'openai', 'unknown', 42],
    });
    expect(settings.order, [AiProvider.gemini, AiProvider.openai]);
    expect(() => settings.fallbacks.add(AiProvider.claude), throwsUnsupportedError);
  });

  test('changing primary swaps an enabled backup and preserves disabled fallback', () {
    final settings = AiSpeechSettings(primary: AiProvider.gemini, fallbacks: [AiProvider.openai]);
    expect(settings.selectPrimary(AiProvider.openai).order, [AiProvider.openai, AiProvider.gemini]);
    expect(AiSpeechSettings(primary: AiProvider.gemini).selectPrimary(AiProvider.openai).order, [AiProvider.openai]);
    final unboosted = AiSpeechSettings(primary: AiProvider.gemini, boost: false).selectPrimary(AiProvider.openai);
    expect(AiSpeechSettings.fromJson(unboosted.toJson()).boost, isFalse);
    expect(AiSpeechSettings.fromJson({'primary': 'gemini'}).boost, isTrue);
  });

  for (final primary in AiSpeechSettings.supported) {
    test('${primary.displayName} respects the disabled boost and keeps the full recording', () async {
      await AiService.setSpeechSettings(AiSpeechSettings(primary: primary, boost: false));
      final result = await speak(client(success));
      final output = ByteData.sublistView(Uint8List.fromList(result!.bytes), 44);
      final input = ByteData.sublistView(pcm);
      expect(output.getInt16(4002, Endian.little), closeTo(input.getInt16(4002, Endian.little), 2));
      expect(result.bytes.length, 44 + pcm.length + 24000);
    });
    test('${primary.displayName} success never calls the backup and keeps the 25% voice boost', () async {
      await AiService.setSpeechSettings(AiSpeechSettings(primary: primary, fallbacks: AiSpeechSettings.supported));
      final result = await speak(client(success));
      expect(result?.extension, 'wav');
      expect(calls.every((value) => value.startsWith(primary.name)), isTrue);
      expect(AiService.lastSpeechProvider.value, primary);
      final output = ByteData.sublistView(Uint8List.fromList(result!.bytes), 44);
      final input = ByteData.sublistView(pcm);
      expect(output.getInt16(4002, Endian.little), closeTo(input.getInt16(4002, Endian.little) * 1.25, 2));
      expect(await AiService.getProvider(), AiProvider.claude);
    });
  }

  test('Gemini failure falls back to OpenAI once with each API using only its own key', () async {
    final result = await speak(
      client(
        (request) => request.method == 'POST' && request.url.host != 'api.openai.com'
            ? http.Response('unavailable', 503)
            : success(request),
      ),
    );
    expect(result?.extension, 'wav');
    expect(calls, ['gemini:GET', 'gemini:POST', 'openai:POST']);
    expect(AiService.lastSpeechProvider.value, AiProvider.openai);
    expect((await AiService.getSpeechSettings()).primary, AiProvider.gemini);
  });

  test('OpenAI rejects the key then falls back to Gemini', () async {
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.openai, fallbacks: [AiProvider.gemini]));
    final result = await speak(
      client((request) => request.url.host == 'api.openai.com' ? http.Response('unauthorized', 401) : success(request)),
    );
    expect(result, isNotNull);
    expect(calls, ['openai:POST', 'gemini:GET', 'gemini:POST']);
    expect(AiService.lastSpeechProvider.value, AiProvider.gemini);
  });

  test('a disabled fallback is never contacted even when it has a key', () async {
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini));
    await expectLater(
      speak(client((request) => request.method == 'GET' ? success(request) : http.Response('', 503))),
      throwsA(isA<AiException>()),
    );
    expect(calls, ['gemini:GET', 'gemini:POST']);
    expect(AiService.lastSpeechProvider.value, isNull);
  });

  test('a missing primary key uses only an enabled backup', () async {
    await AiService.setApiKey(AiProvider.gemini, null);
    expect(await AiService.speechProvider(), AiProvider.openai);
    expect(await speak(client(success)), isNotNull);
    expect(calls, ['openai:POST']);
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini));
    calls.clear();
    expect(await AiService.speechProvider(), isNull);
    expect(await speak(client(success)), isNull);
    expect(calls, isEmpty);
  });

  test('usage limits and all-provider failure terminate without cycling between APIs', () async {
    await expectLater(
      speak(client((request) => request.method == 'GET' ? success(request) : http.Response('', 429))),
      throwsA(isA<AiException>()),
    );
    expect(calls, ['gemini:GET', 'gemini:POST', 'openai:POST']);
    expect(AiService.lastSpeechProvider.value, isNull);
  });

  test('timeouts use the enabled backup', () async {
    final result = await speak(
      client((request) {
        if (request.method == 'POST' && request.url.host != 'api.openai.com') throw TimeoutException('timeout');
        return success(request);
      }),
    );
    expect(result, isNotNull);
    expect(calls.last, 'openai:POST');
  });

  test('a stalled primary leaves time for the enabled backup and discards its late response', () async {
    final stalled = Completer<http.Response>();
    http.Request? pending;
    final result = await speak(
      client((request) {
        if (request.method == 'POST' && request.url.host != 'api.openai.com') {
          pending = request;
          return stalled.future;
        }
        return success(request);
      }),
      timeout: const Duration(milliseconds: 1200),
    );
    expect(result, isNotNull);
    expect(calls, ['gemini:GET', 'gemini:POST', 'openai:POST']);
    expect(AiService.lastSpeechProvider.value, AiProvider.openai);
    stalled.complete(success(pending!));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(AiService.lastSpeechProvider.value, AiProvider.openai);
    expect(calls, hasLength(3));
  });

  test('discovery and speech share a deadline instead of restarting it at each request', () async {
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini));
    await expectLater(
      speak(
        client((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          return success(request);
        }),
        timeout: const Duration(milliseconds: 500),
      ),
      throwsA(isA<AiException>().having((e) => e.timedOut, 'timedOut', isTrue)),
    );
    expect(calls.first, 'gemini:GET');
    expect(calls.length, lessThanOrEqualTo(2));
    final completedCalls = calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(calls, hasLength(completedCalls));
  });

  test('an early discovery timeout cannot start a late voice request', () async {
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini));
    final pending = Completer<http.Response>();
    final request = runZoned(
      () => speak(
        client((request) => request.method == 'GET' ? pending.future : success(request)),
        timeout: const Duration(milliseconds: 150),
      ),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) => parent.createTimer(
          zone,
          duration > const Duration(milliseconds: 100) ? duration - const Duration(milliseconds: 100) : duration,
          callback,
        ),
      ),
    );
    await expectLater(request, throwsA(isA<AiException>().having((e) => e.timedOut, 'timedOut', isTrue)));
    expect(calls, ['gemini:GET']);
    pending.complete(http.Response(jsonEncode({'models': <dynamic>[]}), 200));
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['gemini:GET']);
  });

  test('a failing primary cools down without changing the saved provider order', () async {
    await speak(
      client(
        (request) => request.method == 'POST' && request.url.host != 'api.openai.com'
            ? http.Response('', 503)
            : success(request),
      ),
    );
    calls.clear();
    expect(await speak(client(success)), isNotNull);
    expect(calls, ['openai:POST']);
    expect((await AiService.getSpeechSettings()).order, [AiProvider.gemini, AiProvider.openai]);
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini, fallbacks: [AiProvider.openai]));
    calls.clear();
    expect(await speak(client(success)), isNotNull);
    expect(calls, ['gemini:POST']);
  });

  test('cancelling an in-flight request returns promptly and never starts the backup', () async {
    final cancelled = Completer<void>(), started = Completer<void>();
    final response = Completer<http.Response>();
    http.Request? pending;
    final result = http.runWithClient(
      () => AiService.speech(line, style: 'Warm', voice: (openai: 'ash', gemini: 'Puck'), cancelled: cancelled.future),
      () => client((request) {
        if (request.method == 'GET') return success(request);
        pending = request;
        started.complete();
        return response.future;
      }),
    );
    await started.future;
    cancelled.complete();
    expect(await result.timeout(const Duration(seconds: 1)), isNull);
    expect(calls, ['gemini:GET', 'gemini:POST']);
    response.complete(success(pending!));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, hasLength(2));
  });

  test('incomplete Gemini speech is discarded before falling back', () async {
    final result = await speak(
      client(
        (request) => request.method == 'POST' && request.url.host != 'api.openai.com'
            ? http.Response('{"candidates":[{"finishReason":"MAX_TOKENS"}]}', 200)
            : success(request),
      ),
    );
    expect(result, isNotNull);
    expect(calls.last, 'openai:POST');
    expect(AiService.lastSpeechProvider.value, AiProvider.openai);
  });

  test('invalid OpenAI PCM falls back instead of playing an empty or truncated clip', () async {
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.openai, fallbacks: [AiProvider.gemini]));
    final result = await speak(
      client(
        (request) => request.url.host == 'api.openai.com' ? http.Response.bytes([1, 2, 3], 200) : success(request),
      ),
    );
    expect(result, isNotNull);
    expect(calls, ['openai:POST', 'gemini:GET', 'gemini:POST']);
  });

  test('OpenAI model retries finish before moving to the backup API', () async {
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.openai, fallbacks: [AiProvider.gemini]));
    final models = <String>[];
    final result = await speak(
      client((request) {
        if (request.url.host != 'api.openai.com') return success(request);
        models.add((jsonDecode(request.body) as Map<String, dynamic>)['model'] as String);
        return http.Response('', 404);
      }),
    );
    expect(result, isNotNull);
    expect(models, ['gpt-4o-mini-tts', 'tts-1']);
    expect(calls, ['openai:POST', 'openai:POST', 'gemini:GET', 'gemini:POST']);
  });

  for (final changeSettings in [false, true]) {
    test(
      '${changeSettings ? 'changing APIs' : 'dismissing a line'} cancels late audio and prevents a fallback request',
      () async {
        var wanted = true;
        final started = Completer<void>(), release = Completer<void>();
        final recording = speak(
          client((request) async {
            if (request.method == 'GET') return success(request);
            started.complete();
            await release.future;
            return http.Response('', 503);
          }),
          wanted: () => wanted,
        );
        await started.future;
        if (changeSettings) {
          await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.openai));
        } else {
          wanted = false;
        }
        release.complete();
        expect(await recording, isNull);
        expect(calls, ['gemini:GET', 'gemini:POST']);
        expect(AiService.lastSpeechProvider.value, isNull);
      },
    );
  }

  test('a cancelled announcement makes no HTTP requests', () async {
    expect(await speak(client(success), wanted: () => false), isNull);
    expect(calls, isEmpty);
  });
}
