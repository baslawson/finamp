import 'dart:async';
import 'dart:convert';

import 'package:finamp/services/ai_provider_health.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/ai_usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _schema = {
  'type': 'object',
  'properties': {
    'line': {'type': 'string'},
  },
  'required': ['line'],
  'additionalProperties': false,
};
const _result = {'line': 'Here comes Muse with Starlight.'};
const _gemini = 'generativelanguage.googleapis.com';

http.Response _answer(http.Request request) {
  if (request.method == 'GET') return http.Response(jsonEncode({'models': <dynamic>[], 'data': <dynamic>[]}), 200);
  final text = jsonEncode(_result);
  return http.Response(
    jsonEncode(
      request.url.host == 'api.openai.com'
          ? {
              'choices': [
                {
                  'message': {'content': text},
                },
              ],
              'usage': {'prompt_tokens': 120, 'completion_tokens': 30},
            }
          : {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': text},
                    ],
                  },
                },
              ],
              'usageMetadata': {'promptTokenCount': 100, 'candidatesTokenCount': 20, 'thoughtsTokenCount': 5},
            },
    ),
    200,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? previous;
  var time = DateTime(2026, 10, 22, 12);
  final posts = <http.Request>[];

  setUp(() async {
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    AiProviderHealth.forgetLoaded();
    AiUsage.forgetLoaded();
    time = DateTime(2026, 10, 22, 12);
    AiProviderHealth.now = () => time;
    AiUsage.now = () => time;
    for (final provider in [AiProvider.gemini, AiProvider.openai]) {
      await AiService.setApiKey(provider, '${provider.name}-test-key');
    }
    posts.clear();
  });
  tearDown(() {
    AiProviderHealth.now = DateTime.now;
    AiUsage.now = DateTime.now;
    AiUsage.forgetLoaded();
    SharedPreferencesAsyncPlatform.instance = previous;
  });

  Future<Map<String, dynamic>> generate(FutureOr<http.Response> Function(http.Request) handler, {bool quick = false}) =>
      http.runWithClient(
        () => AiService.generateJson(
          prompt: 'Introduce the next song.',
          schema: _schema,
          schemaName: 'dj_line',
          quick: quick,
        ),
        () => MockClient((request) async {
          if (request.method == 'POST') posts.add(request);
          return handler(request);
        }),
      );

  http.Response geminiDown(http.Request request) =>
      request.method == 'POST' && request.url.host == _gemini ? http.Response('{}', 503) : _answer(request);

  test('a primary that fails twice in a row waits behind its backup, then gets another chance', () async {
    await generate(geminiDown);
    expect(await AiProviderHealth.order([AiProvider.gemini, AiProvider.openai]), [
      AiProvider.gemini,
      AiProvider.openai,
    ]);
    await generate(geminiDown);
    expect(await AiProviderHealth.order([AiProvider.gemini, AiProvider.openai]), [
      AiProvider.openai,
      AiProvider.gemini,
    ]);

    posts.clear();
    expect(await generate(_answer), _result);
    expect(posts.map((r) => r.url.host), ['api.openai.com'], reason: 'the paused primary is not tried first');

    time = time.add(AiProviderHealth.firstPause + const Duration(seconds: 1));
    posts.clear();
    expect(await generate(_answer), _result);
    expect(posts.map((r) => r.url.host), [_gemini]);
    expect((await AiProviderHealth.status(AiProvider.gemini)).failures, 0);
  });

  test('pauses grow while the primary keeps failing and are kept across restarts', () async {
    for (var i = 0; i < 3; i++) {
      time = time.add(const Duration(hours: 3));
      await generate(geminiDown);
    }
    final status = await AiProviderHealth.status(AiProvider.gemini);
    expect(status.failures, 3);
    expect(status.pausedUntil, time.add(AiProviderHealth.firstPause * 2));
    AiProviderHealth.forgetLoaded();
    expect((await AiProviderHealth.status(AiProvider.gemini)).pausedUntil, status.pausedUntil);
  });

  test('saving a new key clears its failures', () async {
    await generate(geminiDown);
    await generate(geminiDown);
    await AiService.setApiKey(AiProvider.gemini, 'new-gemini-key');
    expect(await AiProviderHealth.order([AiProvider.gemini, AiProvider.openai]), [
      AiProvider.gemini,
      AiProvider.openai,
    ]);
  });

  test('a paused provider is still the last resort', () async {
    await generate(geminiDown);
    await generate(geminiDown);
    posts.clear();
    expect(
      await generate(
        (request) => request.method == 'POST' && request.url.host == 'api.openai.com'
            ? http.Response('{}', 503)
            : _answer(request),
      ),
      _result,
    );
    expect(posts.map((r) => r.url.host), ['api.openai.com', _gemini]);
  });

  test('usage counts requests, failures and tokens per provider without any content', () async {
    await generate(geminiDown);
    await generate(_answer);
    await pumpEventQueue();
    await AiUsage.flush();
    final today = await AiUsage.total();
    expect(today[AiProvider.gemini]!.requests, 2);
    expect(today[AiProvider.gemini]!.failures, 1);
    expect(today[AiProvider.gemini]!.inputTokens, 100);
    expect(today[AiProvider.gemini]!.outputTokens, 25);
    expect(today[AiProvider.openai]!.requests, 1);
    expect(today[AiProvider.openai]!.inputTokens, 120);
    AiUsage.forgetLoaded();
    expect((await AiUsage.total())[AiProvider.gemini]!.requests, 2, reason: 'counts are saved');
  });

  test('old days drop out of the month', () async {
    await generate(_answer);
    await pumpEventQueue();
    await AiUsage.flush();
    time = time.add(const Duration(days: AiUsage.keptDays + 1));
    await generate(_answer);
    await pumpEventQueue();
    await AiUsage.flush();
    expect((await AiUsage.total(days: 60))[AiProvider.gemini]!.requests, 1);
  });

  test('the daily limit stops requests before anything is sent, and resets the next day', () async {
    await AiUsage.setDailyLimit(2);
    await generate(_answer);
    await generate(_answer);
    posts.clear();
    await expectLater(
      generate(_answer),
      throwsA(isA<AiException>().having((e) => e.category, 'category', AiFailureCategory.limit)),
    );
    expect(posts, isEmpty);
    time = time.add(const Duration(days: 1));
    expect(await generate(_answer), _result);
  });

  test('a backup is not sent once the failed primary used the last request of the day', () async {
    await AiUsage.setDailyLimit(2);
    await generate(_answer);
    posts.clear();
    await expectLater(
      generate(geminiDown),
      throwsA(isA<AiException>().having((e) => e.category, 'category', AiFailureCategory.limit)),
    );
    expect(posts.map((post) => post.url.host), [_gemini], reason: 'OpenAI would have been request 3');
    expect((await AiProviderHealth.status(AiProvider.openai)).failures, 0, reason: 'the limit is not its fault');
    final today = await AiUsage.total();
    expect(today.values.fold<int>(0, (sum, count) => sum + count.allRequests), 2);
  });

  test('requests made at the same moment cannot share the last one left', () async {
    await AiUsage.setDailyLimit(1);
    final results = await Future.wait([
      generate(_answer).then<Object>((result) => result, onError: (Object error) => error),
      generate(_answer).then<Object>((result) => result, onError: (Object error) => error),
    ]);
    expect(posts, hasLength(1));
    expect(results.whereType<AiException>().single.category, AiFailureCategory.limit);
  });

  test('every voice request counts once sent, including second takes and cancelled ones', () async {
    await AiUsage.setDailyLimit(3);
    // A first take, a second take after a doubled reading, then one cancelled after sending, never recorded.
    await AiUsage.reserve(AiProvider.gemini, speech: true);
    await AiUsage.reserve(AiProvider.gemini, speech: true);
    await AiUsage.recordSpeech(AiProvider.gemini, ok: true, characters: 40);
    await AiUsage.reserve(AiProvider.gemini, speech: true);
    expect((await AiUsage.total())[AiProvider.gemini]!.speechRequests, 3);
    await expectLater(
      AiUsage.reserve(AiProvider.openai, speech: true),
      throwsA(isA<AiException>().having((e) => e.category, 'category', AiFailureCategory.limit)),
    );
  });

  test('quick requests ask Gemini 3 to think less, and drop the setting when a model rejects it', () async {
    final bodies = <Map<String, dynamic>>[];
    http.Response handler(http.Request request) {
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-3.8-flash'},
            ],
          }),
          200,
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      bodies.add(body);
      final config = body['generationConfig'] as Map<String, dynamic>;
      return config.containsKey('thinkingConfig') && bodies.length > 1
          ? http.Response('{"error":{"message":"Unknown name thinkingLevel"}}', 400)
          : _answer(request);
    }

    expect(await generate(handler, quick: true), _result);
    expect(bodies.single['generationConfig']['thinkingConfig'], {'thinkingLevel': 'low'});

    bodies.clear();
    expect(await generate(handler), _result);
    expect((bodies.single['generationConfig'] as Map).containsKey('thinkingConfig'), false, reason: 'only quick ones');
  });

  test('a model that rejects the quick setting is asked again without it, within the same attempt', () async {
    await AiService.setTextSettings(AiTextSettings(fallbacks: []));
    var calls = 0;
    expect(
      await generate((request) {
        if (request.method == 'GET') return _answer(request);
        calls++;
        final config = (jsonDecode(request.body) as Map<String, dynamic>)['generationConfig'] as Map<String, dynamic>;
        return config.containsKey('thinkingConfig') ? http.Response('{}', 400) : _answer(request);
      }, quick: true),
      _result,
    );
    expect(calls, 2);
    calls = 0;
    expect(await generate(_answer, quick: true), _result);
  });

  test('WAV length comes from the header', () {
    final bytes = List<int>.filled(44 + 48000, 0);
    bytes.setRange(0, 4, 'RIFF'.codeUnits);
    bytes.setRange(28, 32, [0xC0, 0x5D, 0x00, 0x00]); // 24000 bytes a second
    expect(AiService.wavLength(bytes), const Duration(seconds: 2));
    expect(AiService.wavLength([1, 2, 3]), isNull);
  });
}
