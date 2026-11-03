import 'dart:async';
import 'dart:convert';

import 'package:finamp/services/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
const _privateContent =
    'private-provider-response gemini-test-key openai-test-key Introduce the next song. Here comes Muse with Starlight.';

http.Response _success(http.Request request) {
  if (request.method == 'GET') {
    return http.Response(jsonEncode({'models': <dynamic>[], 'data': <dynamic>[]}), 200);
  }
  final text = jsonEncode(_result);
  return http.Response(
    jsonEncode(
      request.url.host == 'api.openai.com'
          ? {
              'choices': [
                {
                  'message': {'content': text},
                  'finish_reason': 'stop',
                },
              ],
            }
          : {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': text},
                    ],
                  },
                  'finishReason': 'STOP',
                },
              ],
            },
    ),
    200,
  );
}

Future<Map<String, dynamic>> _generate({Duration? timeout}) => AiService.generateJson(
  prompt: 'Introduce the next song.',
  schema: _schema,
  schemaName: 'dj_line',
  timeout: timeout,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? previous;
  final posts = <http.Request>[];
  final records = <LogRecord>[];
  late StreamSubscription<LogRecord> subscription;
  setUp(() async {
    records.clear();
    subscription = Logger.root.onRecord.where((record) => record.loggerName == 'AiService').listen(records.add);
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    for (final provider in AiProvider.values) {
      await AiService.setApiKey(provider, '${provider.name}-test-key');
    }
    posts.clear();
  });
  tearDown(() async {
    await subscription.cancel();
    SharedPreferencesAsyncPlatform.instance = previous;
  });

  String fallbackWarning() {
    for (final record in records) {
      expect(record.error, isNull);
      expect(record.stackTrace, isNull);
      for (final privateText in [
        'private-provider-response',
        'gemini-test-key',
        'openai-test-key',
        'Introduce the next song.',
        _result['line']!,
      ]) {
        expect(record.message, isNot(contains(privateText)));
      }
    }
    final warning = records.singleWhere((record) => record.message.contains(' request failed ('));
    expect(warning.level, Level.WARNING);
    expect(warning.message, matches(RegExp(r'elapsedMs=\d+, budgetMs=\d+')));
    return warning.message;
  }

  Future<Map<String, dynamic>> generate(FutureOr<http.Response> Function(http.Request) handler, {Duration? timeout}) =>
      http.runWithClient(
        () => _generate(timeout: timeout),
        () => MockClient((request) async {
          if (request.method == 'POST') posts.add(request);
          return handler(request);
        }),
      );

  test('fresh installs and legacy Claude selections default to Gemini then OpenAI, independently of voice', () async {
    expect((await AiService.getTextSettings()).order, [AiProvider.gemini, AiProvider.openai]);
    await SharedPreferencesAsync().setString('aiProvider', 'claude');
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini, boost: false));
    expect(await AiService.getProvider(), AiProvider.gemini);
    expect((await AiService.getTextSettings()).order, [AiProvider.gemini, AiProvider.openai]);
    await AiService.setTextSettings(AiTextSettings(primary: AiProvider.openai, fallbacks: [AiProvider.gemini]));
    expect((await AiService.getTextSettings()).order, [AiProvider.openai, AiProvider.gemini]);
    expect((await AiService.getSpeechSettings()).primary, AiProvider.gemini);
    expect((await AiService.getSpeechSettings()).boost, false);
  });

  test('Gemini handles a successful request without invoking a backup or Claude', () async {
    expect(await generate(_success), _result);
    expect(posts.map((r) => r.url.host), ['generativelanguage.googleapis.com']);
    expect(posts.single.headers['x-goog-api-key'], 'gemini-test-key');
    expect(posts.single.headers['authorization'], isNull);
  });

  for (final status in [400, 401, 429, 503]) {
    test('Gemini HTTP $status uses the enabled OpenAI backup with its own key', () async {
      expect(
        await generate(
          (request) => request.method == 'POST' && request.url.host != 'api.openai.com'
              ? http.Response(
                  jsonEncode({
                    'error': {'message': _privateContent},
                  }),
                  status,
                )
              : _success(request),
        ),
        _result,
      );
      expect(posts.map((r) => r.url.host), ['generativelanguage.googleapis.com', 'api.openai.com']);
      expect(posts.last.headers['authorization'], 'Bearer openai-test-key');
      expect(posts.last.headers['x-goog-api-key'], isNull);
      expect(await AiService.getProvider(), AiProvider.gemini);
      final warning = fallbackWarning();
      expect(warning, contains('reason=http, status=$status, timedOut=false'));
      expect(warning, contains('stage=generation, model=models/gemini-2.5-flash'));
      expect(warning, endsWith('trying OpenAI backup'));
    });
  }

  test('a malformed Gemini answer uses OpenAI rather than returning an unusable mix', () async {
    expect(
      await generate(
        (request) => request.method == 'POST' && request.url.host != 'api.openai.com'
            ? http.Response(_privateContent, 200)
            : _success(request),
      ),
      _result,
    );
    expect(posts.last.url.host, 'api.openai.com');
    expect(fallbackWarning(), contains('reason=invalidResponse, status=none, timedOut=false'));
  });

  test('a missing Gemini key can use a saved OpenAI backup key', () async {
    await AiService.setApiKey(AiProvider.gemini, null);
    expect(await AiService.isConfigured(), true);
    expect(await generate(_success), _result);
    expect(posts.map((r) => r.url.host), ['api.openai.com']);
  });

  test('a non-object Gemini answer falls back instead of throwing a type error', () async {
    expect(
      await generate((request) {
        if (request.method == 'POST' && request.url.host == 'generativelanguage.googleapis.com') {
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': '[]'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        return _success(request);
      }),
      _result,
    );
    expect(posts.last.url.host, 'api.openai.com');
    expect(fallbackWarning(), contains('reason=invalidResponse, status=none, timedOut=false'));
  });

  test('a disabled OpenAI backup and a saved Claude key are never used implicitly', () async {
    await AiService.setTextSettings(AiTextSettings(fallbacks: []));
    await expectLater(
      generate((request) => request.method == 'POST' ? http.Response('{}', 429) : _success(request)),
      throwsA(isA<AiException>()),
    );
    expect(posts.map((r) => r.url.host), ['generativelanguage.googleapis.com']);
  });

  test('a Claude-only key does not enable the Gemini/OpenAI route', () async {
    await AiService.setApiKey(AiProvider.gemini, null);
    await AiService.setApiKey(AiProvider.openai, null);
    expect(await AiService.isConfigured(), false);
    await expectLater(generate(_success), throwsA(isA<AiException>()));
    expect(posts, isEmpty);
  });

  for (final stage in ['discovery', 'generation']) {
    test('a stalled Gemini $stage leaves time for OpenAI and cannot send a late request', () async {
      final pending = Completer<http.Response>();
      try {
        expect(
          await generate((request) {
            if (request.url.host == 'generativelanguage.googleapis.com' &&
                request.method == (stage == 'discovery' ? 'GET' : 'POST')) {
              return pending.future;
            }
            return _success(request);
          }, timeout: const Duration(seconds: 2)),
          _result,
        );
        expect(posts.last.url.host, 'api.openai.com');
        final warning = fallbackWarning();
        expect(warning, contains('reason=timeout, status=none, timedOut=true'));
        expect(
          warning,
          contains(
            stage == 'discovery'
                ? 'stage=model_discovery, model=not_selected'
                : 'stage=generation, model=models/gemini-2.5-flash',
          ),
        );
        final timing = RegExp(r'elapsedMs=(\d+), budgetMs=(\d+)').firstMatch(warning)!;
        final elapsedMs = int.parse(timing.group(1)!);
        final budgetMs = int.parse(timing.group(2)!);
        // The primary gets two thirds of the 2 s, leaving the rest for the backup.
        expect(budgetMs, inInclusiveRange(1200, 1400));
        expect(elapsedMs, greaterThanOrEqualTo(budgetMs - 50));
        final count = posts.length;
        pending.complete(http.Response('{}', 200));
        await Future<void>.delayed(Duration.zero);
        expect(posts, hasLength(count));
      } finally {
        if (!pending.isCompleted) pending.complete(http.Response('{}', 200));
      }
    });
  }

  test('model discovery HTTP failure identifies the stage before a model is selected', () async {
    expect(
      await generate(
        (request) => request.method == 'GET' && request.url.host == 'generativelanguage.googleapis.com'
            ? http.Response(
                jsonEncode({
                  'error': {'message': _privateContent},
                }),
                403,
              )
            : _success(request),
      ),
      _result,
    );
    final warning = fallbackWarning();
    expect(warning, contains('reason=http, status=403, timedOut=false'));
    expect(warning, contains('stage=model_discovery, model=not_selected'));
    expect(posts.map((request) => request.url.host), ['api.openai.com']);
  });

  test('a network failure logs a safe category without the client exception contents', () async {
    expect(
      await generate((request) {
        if (request.method == 'POST' && request.url.host == 'generativelanguage.googleapis.com') {
          throw http.ClientException(_privateContent, request.url);
        }
        return _success(request);
      }),
      _result,
    );
    expect(fallbackWarning(), contains('reason=network, status=none, timedOut=false'));
  });

  test('an empty answer logs a safe category without the provider finish reason', () async {
    expect(
      await generate(
        (request) => request.method == 'POST' && request.url.host == 'generativelanguage.googleapis.com'
            ? http.Response(
                jsonEncode({
                  'candidates': [
                    {'finishReason': _privateContent},
                  ],
                }),
                200,
              )
            : _success(request),
      ),
      _result,
    );
    expect(fallbackWarning(), contains('reason=noAnswer, status=none, timedOut=false'));
  });

  test('a malformed model listing uses the fallback model without logging response contents', () async {
    expect(
      await generate((request) {
        if (request.url.host == 'generativelanguage.googleapis.com') {
          return http.Response(_privateContent, request.method == 'GET' ? 200 : 503);
        }
        return _success(request);
      }),
      _result,
    );
    expect(fallbackWarning(), contains('stage=generation, model=models/gemini-2.5-flash'));
    expect(records.any((record) => record.message.contains('Listing Gemini models failed (invalidResponse)')), isTrue);
  });

  for (final provider in AiProvider.values) {
    test('${provider.displayName} failure logs the model used for generation', () async {
      final backup = provider == AiProvider.gemini ? AiProvider.openai : AiProvider.gemini;
      await AiService.setTextSettings(AiTextSettings(primary: provider, fallbacks: [backup]));
      final host = switch (provider) {
        AiProvider.gemini => 'generativelanguage.googleapis.com',
        AiProvider.openai => 'api.openai.com',
        AiProvider.claude => 'api.anthropic.com',
      };
      String? usedModel;
      expect(
        await generate((request) {
          if (request.url.host == host) {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'models': [
                    {'name': 'models/gemini-9.9-flash'},
                  ],
                  'data': [
                    {'id': 'gpt-9.9-mini'},
                  ],
                }),
                200,
              );
            }
            usedModel = provider == AiProvider.gemini
                ? request.url.path.substring('/v1beta/'.length).split(':').first
                : (jsonDecode(request.body) as Map<String, dynamic>)['model'] as String;
            return http.Response(
              jsonEncode({
                'error': {'message': _privateContent},
              }),
              503,
            );
          }
          return _success(request);
        }),
        _result,
      );
      expect(usedModel, isNotNull);
      final warning = fallbackWarning();
      expect(warning, startsWith('${provider.displayName} request failed'));
      expect(warning, contains('stage=generation, model=$usedModel'));
      expect(warning, endsWith('trying ${backup.displayName} backup'));
    });
  }

  test('failure of both configured APIs surfaces an error without trying Claude', () async {
    await expectLater(
      generate((request) => request.method == 'POST' ? http.Response('{}', 503) : _success(request)),
      throwsA(isA<AiException>().having((e) => e.statusCode, 'status', 503)),
    );
    expect(posts.map((r) => r.url.host), ['generativelanguage.googleapis.com', 'api.openai.com']);
  });

  test('an explicitly selected Claude uses structured JSON, without unsupported forced tools', () async {
    await AiService.setTextSettings(AiTextSettings(primary: AiProvider.claude, fallbacks: []));
    expect(
      await generate((request) {
        final body = jsonDecode(request.body) as Map;
        if (body.containsKey('tool_choice')) {
          return http.Response(
            '{"error":{"message":"tool_choice: type tool and any are not supported for this model."}}',
            400,
          );
        }
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'thinking', 'thinking': 'internal'},
              {'type': 'text', 'text': jsonEncode(_result)},
            ],
            'stop_reason': 'end_turn',
          }),
          200,
        );
      }),
      _result,
    );
    final body = jsonDecode(posts.single.body) as Map;
    expect(body['output_config']['format'], {'type': 'json_schema', 'schema': _schema});
    expect(body.containsKey('tools'), false);
    expect(body.containsKey('tool_choice'), false);
  });

  for (final reason in ['max_tokens', 'refusal']) {
    test('Claude $reason cannot be accepted as a complete playlist', () async {
      await AiService.setTextSettings(AiTextSettings(primary: AiProvider.claude, fallbacks: []));
      await expectLater(
        generate(
          (_) => http.Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': jsonEncode(_result)},
              ],
              'stop_reason': reason,
            }),
            200,
          ),
        ),
        throwsA(isA<AiException>()),
      );
    });
  }
}
