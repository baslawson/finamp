import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? originalPrefs;
  final next = FinampQueueItem(
    item: const MediaItem(id: 'next', title: 'Starlight', artist: 'Muse'),
    source: QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      id: 'aiDj',
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Rock mix'),
    ),
  );
  final prompts = <String>[];
  var responseLine = '';
  setUp(() async {
    originalPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await SharedPreferencesAsync().setString('djVoiceMode', 'off');
    await AiService.setProvider(AiProvider.gemini);
    await AiService.setApiKey(AiProvider.gemini, 'test-key');
    prompts.clear();
    responseLine = 'A little space for the piano. Muse brings us Starlight.';
    await DjVoiceService.initialize();
  });
  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = originalPrefs;
  });

  http.Client client() => MockClient((request) async {
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
                  'text': jsonEncode({'line': responseLine}),
                },
              ],
            },
            'finishReason': 'STOP',
          },
        ],
      }),
      200,
    );
  });

  test('recycled AI wording gets a fresh introduction without a second network request', () async {
    await SharedPreferencesAsync().setStringList('djVoiceRecentLines', [
      'Keeping the good times rolling. Here is Queen.',
    ]);
    await DjVoiceService.initialize();
    responseLine = 'Keeping the good times rolling. Here is Muse with Starlight.';
    final line = await http.runWithClient(() => DjVoiceService.writeLine(null, next, []), client);
    expect(line, allOf(contains('Muse'), contains('Starlight'), isNot(contains('Keeping the good times rolling'))));
    expect(prompts, hasLength(1));
    expect(prompts.single, contains('do not mention listening history, play counts'));
  });

  test('session openings rotate even when the AI repeats the same response', () async {
    for (var i = 0; i < DjVoiceService.intros.length; i++) {
      await http.runWithClient(() => DjVoiceService.writeLine(null, next, []), client);
    }
    final openings = prompts.map((prompt) => DjVoiceService.intros.singleWhere(prompt.contains)).toSet();
    expect(openings, hasLength(DjVoiceService.intros.length));
  });

  test('Brief keeps complete song names and never requests generated commentary', () async {
    final line = await http.runWithClient(
      () => DjVoiceService.writeLine(null, next, [], length: DjAnnouncementLength.brief),
      client,
    );
    expect(line, allOf(contains('Starlight'), contains('Muse')));
    expect(prompts, isEmpty);
  });

  test('Chatty respects slow voices and uses the same character for its writing', () async {
    await http.runWithClient(
      () => DjVoiceService.writeLine(
        null,
        next,
        [],
        length: DjAnnouncementLength.chatty,
        character: DjVoiceCharacter.meditation,
      ),
      client,
    );
    expect(prompts.single, contains('calm meditation guide'));
    expect(prompts.single, contains('at most 40 words'));
  });

  for (final status in [429, 503]) {
    test('commentary failure HTTP $status still supplies a song introduction', () async {
      final line = await http.runWithClient(
        () => DjVoiceService.writeLine(null, next, []),
        () => MockClient((_) async => http.Response('{"error":{"message":"Unavailable"}}', status)),
      );
      expect(line, allOf(contains('Starlight'), contains('Muse')));
    });
  }

  test('commentary failure from an empty answer still supplies an introduction', () async {
    responseLine = '';
    final line = await http.runWithClient(() => DjVoiceService.writeLine(null, next, []), client);
    expect(line, allOf(contains('Starlight'), contains('Muse')));
  });

  test('commentary failure from invalid JSON still supplies an offline-safe introduction', () async {
    final line = await http.runWithClient(
      () => DjVoiceService.writeLine(null, next, [], offline: true),
      () => MockClient((_) async => http.Response('not JSON', 200)),
    );
    expect(line, 'Starlight, by Muse.');
  });
}
