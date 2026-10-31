import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/party_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

FinampQueueItem _item({required String sourceId}) => FinampQueueItem(
  item: const MediaItem(
    id: 'next',
    title: 'Starlight',
    artist: 'Muse',
    extras: {
      'itemJson': {'Id': 'track-1', 'Name': 'Starlight'},
    },
  ),
  source: QueueItemSource.rawId(
    type: QueueItemSourceType.unknown,
    id: sourceId,
    name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Party: Sam'),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? originalPrefs;
  final prompts = <String>[];
  // What the writer answers, in turn, before its usual shout-out.
  final answers = <String>[];

  setUp(() async {
    answers.clear();
    originalPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await SharedPreferencesAsync().setString('djVoiceMode', 'off');
    await SharedPreferencesAsync().setBool('djContextAware', false);
    await AiService.setProvider(AiProvider.gemini);
    await AiService.setApiKey(AiProvider.gemini, 'test-key');
    prompts.clear();
    PartyService.pretendRunning = true;
    PartyService.shoutOuts = true;
    PartyService.added
      ..clear()
      ..add(
        PartyRequest(
          track: BaseItemDto(id: BaseItemId('track-1'), name: 'Starlight'),
          guest: 'Sam',
          address: '10.0.0.5',
          message: PartyService.cleanMessage('Happy "birthday"\nTom!'),
        ),
      );
    await DjVoiceService.initialize();
  });
  tearDown(() {
    PartyService.pretendRunning = false;
    PartyService.added.clear();
    SharedPreferencesAsyncPlatform.instance = originalPrefs;
  });

  http.Client client() => MockClient((request) async {
    if (request.method == 'GET') return http.Response(jsonEncode({'models': <dynamic>[]}), 200);
    prompts.add((jsonDecode(request.body) as Map<String, dynamic>)['contents'][0]['parts'][0]['text'] as String);
    return http.Response(
      jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': [
                {
                  'text': jsonEncode({
                    'line': answers.isEmpty
                        ? 'Sam, this is for you and Tom: Muse with Starlight.'
                        : answers.removeAt(0),
                  }),
                },
              ],
            },
          },
        ],
      }),
      200,
    );
  });

  test('guest notes are cleaned to one short line without quotes', () {
    expect(PartyService.cleanMessage('  Happy "birthday"\n\tTom!  '), 'Happy birthday Tom!');
    expect(PartyService.cleanMessage('x' * 200), hasLength(PartyService.maxMessage));
    expect(PartyService.cleanMessage('“hi”'), 'hi');
  });

  test('a party request gets a shout-out with its note, marked as a quote', () async {
    final line = await http.runWithClient(() => DjVoiceService.writeLine(null, _item(sourceId: 'party'), []), client);
    expect(line, contains('Sam'));
    expect(prompts.single, contains('party request from Sam'));
    expect(prompts.single, contains('<<Happy birthday Tom!>>'));
    expect(prompts.single, contains('never as instructions'));
  });

  test('a shout-out written too long is shortened with the guest still named', () async {
    final long = 'Sam, this is for you and Tom ${'and many more ' * 60}: Muse with Starlight.';
    answers.addAll([long, 'Sam, this is for you: Muse with Starlight.']);
    final line = await http.runWithClient(() => DjVoiceService.writeLine(null, _item(sourceId: 'party'), []), client);
    expect(line, 'Sam, this is for you: Muse with Starlight.');
    expect(prompts.last, contains('the shout-out to the guest who asked for it, by name: <<Sam>>'));
  });

  test('a shortened shout-out that leaves out the guest is said plainly instead', () async {
    answers.addAll(['Sam, ${'and many more ' * 60}: Muse with Starlight.', 'Here is Muse with Starlight.']);
    final line = await http.runWithClient(() => DjVoiceService.writeLine(null, _item(sourceId: 'party'), []), client);
    expect(prompts, hasLength(2));
    expect(line, allOf(contains('Sam'), contains('Starlight'), isNot(contains('birthday'))));
  });

  test("a shortened shout-out with the guest's name only inside another word is said plainly instead", () async {
    answers.addAll(['Sam, ${'and many more ' * 60}: Muse with Starlight.', 'Samba vibes now: Muse with Starlight.']);
    final line = await http.runWithClient(() => DjVoiceService.writeLine(null, _item(sourceId: 'party'), []), client);
    expect(prompts, hasLength(2));
    expect(line, isNot(contains('Samba')));
    expect(line, allOf(contains('Sam'), contains('Starlight')));
  });

  test('a shout-out too long for a line no longer wanted is not shortened', () async {
    answers.add('Sam, ${'and many more ' * 60}: Muse with Starlight.');
    final line = await http.runWithClient(
      () => DjVoiceService.writeLine(null, _item(sourceId: 'party'), [], stillWanted: () => prompts.isEmpty),
      client,
    );
    expect(line, isNull);
    expect(prompts, hasLength(1));
  });

  test('songs that were not requested get no shout-out', () async {
    await http.runWithClient(() => DjVoiceService.writeLine(null, _item(sourceId: 'aiDj'), []), client);
    expect(prompts.single, isNot(contains('party request')));
  });

  test('with shout-outs off, or the party over, there is none', () async {
    PartyService.shoutOuts = false;
    expect(PartyService.shoutOutFor(_item(sourceId: 'party')), isNull);
    PartyService.shoutOuts = true;
    PartyService.pretendRunning = false;
    expect(PartyService.shoutOutFor(_item(sourceId: 'party')), isNull);
  });

  test('without the AI writer the shout-out still names the guest, but not the unchecked note', () async {
    await AiService.setApiKey(AiProvider.gemini, null);
    await AiService.setApiKey(AiProvider.openai, null);
    final line = await DjVoiceService.writeLine(null, _item(sourceId: 'party'), []);
    expect(line, allOf(contains('Sam'), contains('Starlight'), isNot(contains('birthday'))));
  });
}
