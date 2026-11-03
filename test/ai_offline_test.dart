import 'dart:async';
import 'dart:convert';

import 'package:finamp/services/ai_provider_health.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/ai_usage.dart';
import 'package:finamp/services/network_status.dart';
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
const _result = {'line': 'Rock, Pop and Folk.'};
const _gemini = 'generativelanguage.googleapis.com';
const _openai = 'api.openai.com';

http.Response _answer(http.Request request) {
  if (request.method == 'GET') {
    return http.Response(
      jsonEncode({
        'models': [
          {'name': 'models/gemini-3.8-flash'},
        ],
        'data': [
          {'id': 'gpt-5-mini'},
        ],
      }),
      200,
    );
  }
  final text = jsonEncode(_result);
  return http.Response(
    jsonEncode(
      request.url.host == _openai
          ? {
              'choices': [
                {
                  'message': {'content': text},
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
                },
              ],
            },
    ),
    200,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? previous;
  late StreamController<bool> changes;
  var online = true;
  final posts = <http.Request>[];

  setUp(() async {
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    AiProviderHealth.forgetLoaded();
    AiUsage.forgetLoaded();
    for (final provider in [AiProvider.gemini, AiProvider.openai]) {
      await AiService.setApiKey(provider, '${provider.name}-test-key');
    }
    posts.clear();
    online = true;
    changes = StreamController<bool>.broadcast(sync: true);
    NetworkStatus.changes = () => changes.stream;
    NetworkStatus.hasNetwork = () async => online;
  });
  tearDown(() async {
    await changes.close();
    AiUsage.forgetLoaded();
    SharedPreferencesAsyncPlatform.instance = previous;
  });

  Future<Map<String, dynamic>> generate(
    FutureOr<http.Response> Function(http.Request) handler, {
    Duration? timeout,
    Duration? waitForConnection,
    AiThinking? thinking,
    bool quick = false,
  }) => http.runWithClient(
    () => AiService.generateJson(
      prompt: 'Tidy these genres.',
      schema: _schema,
      schemaName: 'genre_groups',
      timeout: timeout,
      waitForConnection: waitForConnection,
      thinking: thinking,
      quick: quick,
    ),
    () => MockClient((request) async {
      if (request.method == 'POST') posts.add(request);
      return handler(request);
    }),
  );

  /// Gemini's request loses the network, as when Android cuts it with Finamp in the background.
  FutureOr<http.Response> Function(http.Request) cutOnce() {
    var cut = false;
    return (request) {
      if (request.method == 'POST' && request.url.host == _gemini && !cut) {
        cut = true;
        online = false;
        throw http.ClientException('Connection closed', request.url);
      }
      return _answer(request);
    };
  }

  Matcher lostConnection() => throwsA(
    isA<AiException>()
        .having((e) => e.message, 'message', 'Lost the internet connection, try again with Finamp open')
        .having((e) => e.category, 'category', AiFailureCategory.network),
  );

  test("with the phone offline, the backup isn't tried and nothing is blamed on the AI", () async {
    await expectLater(generate(cutOnce()), lostConnection());
    expect(posts.map((request) => request.url.host), [_gemini]);
    expect((await AiProviderHealth.status(AiProvider.gemini)).failures, 0);
    expect((await AiProviderHealth.status(AiProvider.openai)).failures, 0);
  });

  test('a network failure while online still goes to the backup and counts against the AI', () async {
    expect(
      await generate((request) {
        if (request.method == 'POST' && request.url.host == _gemini) {
          throw http.ClientException('Connection reset', request.url);
        }
        return _answer(request);
      }),
      _result,
    );
    expect(posts.map((request) => request.url.host), [_gemini, _openai]);
    expect((await AiProviderHealth.status(AiProvider.gemini)).failures, 1);
  });

  test('waiting for the connection asks the same AI again once it is back', () async {
    final request = generate(cutOnce(), waitForConnection: const Duration(minutes: 1));
    await pumpEventQueue();
    expect(posts.map((request) => request.url.host), [_gemini], reason: 'waiting, not trying the backup');
    online = true;
    changes.add(true);
    expect(await request, _result);
    expect(posts.map((request) => request.url.host), [_gemini, _gemini]);
    expect((await AiProviderHealth.status(AiProvider.gemini)).failures, 0);
  });

  test("the time spent waiting for the connection isn't taken from the request", () async {
    final request = generate(
      cutOnce(),
      timeout: const Duration(milliseconds: 400),
      waitForConnection: const Duration(minutes: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    online = true;
    changes.add(true);
    expect(await request, _result);
    expect(posts.map((request) => request.url.host), [_gemini, _gemini]);
  });

  test('a network given back without any reported change is still noticed', () async {
    NetworkStatus.recheckEvery = const Duration(milliseconds: 20);
    addTearDown(() => NetworkStatus.recheckEvery = const Duration(seconds: 3));
    final request = generate(cutOnce(), waitForConnection: const Duration(minutes: 1));
    await pumpEventQueue();
    // Android lets Finamp back online as it returns, with no change on the phone's own connection.
    online = true;
    expect(await request.timeout(const Duration(seconds: 5)), _result);
    expect(posts.map((request) => request.url.host), [_gemini, _gemini]);
  });

  test("with the request's time used up, it doesn't wait for a connection it can't use", () async {
    await AiService.setTextSettings(AiTextSettings(fallbacks: []));
    final stalled = Completer<http.Response>();
    addTearDown(() => stalled.complete(http.Response('{}', 200)));
    final request = generate(
      (request) {
        if (request.method != 'POST') return _answer(request);
        online = false;
        return stalled.future;
      },
      timeout: const Duration(milliseconds: 300),
      waitForConnection: const Duration(minutes: 1),
    );
    await expectLater(request.timeout(const Duration(seconds: 5)), lostConnection());
  });

  test("with only a sliver of the request's time left, it doesn't wait for the connection", () async {
    await AiService.setTextSettings(AiTextSettings(fallbacks: []));
    final request = generate(
      (request) async {
        if (request.method != 'POST') return _answer(request);
        // The connection drops with almost all of the request's time used, as when its timer fires a hair early.
        await Future<void>.delayed(const Duration(milliseconds: 240));
        online = false;
        throw http.ClientException('Connection reset', request.url);
      },
      timeout: const Duration(milliseconds: 300),
      waitForConnection: const Duration(minutes: 1),
    );
    await expectLater(request.timeout(const Duration(seconds: 5)), lostConnection());
  });

  test("a slow network check doesn't use up the backup's time", () async {
    final never = Completer<bool>();
    NetworkStatus.hasNetwork = () => never.future;
    expect(
      await generate((request) {
        if (request.method == 'POST' && request.url.host == _gemini) {
          throw http.ClientException('Connection reset', request.url);
        }
        return _answer(request);
      }, timeout: const Duration(milliseconds: 800)),
      _result,
    );
    expect(posts.map((request) => request.url.host), [_gemini, _openai]);
  });

  test('a connection that stays away ends the wait with a clear message', () async {
    await expectLater(generate(cutOnce(), waitForConnection: const Duration(milliseconds: 50)), lostConnection());
    expect(posts.map((request) => request.url.host), [_gemini]);
  });

  test('a network that keeps flickering gets a few tries, not endless ones', () async {
    // Gone at every check after a failure, back at the next one, then lost again with the next request.
    NetworkStatus.recheckEvery = const Duration(milliseconds: 10);
    addTearDown(() => NetworkStatus.recheckEvery = const Duration(seconds: 3));
    var checks = 0;
    NetworkStatus.hasNetwork = () async => (checks++).isOdd;
    final request = generate((request) {
      if (request.method == 'POST') throw http.ClientException('Connection closed', request.url);
      return _answer(request);
    }, waitForConnection: const Duration(minutes: 1));
    await expectLater(request, lostConnection());
    expect(posts, hasLength(4));
  });

  test('medium thinking is asked of Gemini 3 and OpenAI reasoning models', () async {
    expect(await generate(_answer, thinking: AiThinking.medium), _result);
    final gemini = jsonDecode(posts.single.body) as Map<String, dynamic>;
    expect(gemini['generationConfig']['thinkingConfig'], {'thinkingLevel': 'medium'});

    posts.clear();
    await AiService.setTextSettings(AiTextSettings(primary: AiProvider.openai, fallbacks: []));
    expect(await generate(_answer, thinking: AiThinking.medium), _result);
    expect((jsonDecode(posts.single.body) as Map<String, dynamic>)['reasoning_effort'], 'medium');
  });

  test("a model rejecting medium thinking still gets low thinking for quick requests", () async {
    await AiService.setTextSettings(AiTextSettings(fallbacks: []));
    http.Response handler(http.Request request) {
      if (request.method == 'GET') return _answer(request);
      final config = (jsonDecode(request.body) as Map<String, dynamic>)['generationConfig'] as Map<String, dynamic>;
      final level = (config['thinkingConfig'] as Map<String, dynamic>?)?['thinkingLevel'];
      return level == 'medium' ? http.Response('{}', 400) : _answer(request);
    }

    expect(await generate(handler, thinking: AiThinking.medium), _result);
    expect(posts, hasLength(2), reason: 'asked again without the setting');
    posts.clear();
    expect(await generate(handler, thinking: AiThinking.medium), _result);
    expect(posts, hasLength(1), reason: 'remembered');
    posts.clear();
    expect(await generate(handler, quick: true), _result);
    final config = (jsonDecode(posts.single.body) as Map<String, dynamic>)['generationConfig'] as Map<String, dynamic>;
    expect(config['thinkingConfig'], {'thinkingLevel': 'low'});
  });
}
