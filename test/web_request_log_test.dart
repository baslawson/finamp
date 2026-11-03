import 'dart:async';
import 'dart:convert';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_provider_health.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/ai_usage.dart';
import 'package:finamp/services/lrclib_service.dart';
import 'package:finamp/services/web_request_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final records = <LogRecord>[];
  late StreamSubscription<LogRecord> listening;
  late Level previousLevel;

  setUp(() {
    records.clear();
    previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    listening = Logger.root.onRecord.listen(records.add);
  });
  tearDown(() async {
    await listening.cancel();
    Logger.root.level = previousLevel;
  });

  List<String> requestLines() => [
    for (final record in records)
      if (record.level == Level.FINE && RegExp(r"^(GET|POST) ").hasMatch(record.message)) record.message,
  ];

  group("the request line", () {
    final logger = Logger("Test");
    final url = Uri.parse("https://example.com/path?a=1");

    test("says where it went, how it ended and how much moved", () async {
      await loggedWebRequest(logger, "POST", url, () async => http.Response("12345", 201), sent: 7);
      expect(records.single.level, Level.FINE);
      expect(
        records.single.message,
        matches(RegExp(r"^POST https://example\.com/path\?a=1: 201, received 5 bytes after \d+ ms, sent 7 bytes$")),
      );
    });

    test("leaves out the sent size for a request with no body", () async {
      await loggedWebRequest(logger, "GET", url, () async => http.Response("", 200));
      expect(records.single.message, isNot(contains("sent")));
    });

    test("a timeout is logged and still reaches the caller", () async {
      await expectLater(
        loggedWebRequest(logger, "GET", url, () async => throw TimeoutException("slow")),
        throwsA(isA<TimeoutException>()),
      );
      expect(records.single.message, contains("timed out"));
    });

    test("another failure names its type, not its message, and still reaches the caller", () async {
      await expectLater(
        loggedWebRequest(logger, "GET", url, () async => throw http.ClientException("private detail")),
        throwsA(isA<http.ClientException>()),
      );
      expect(records.single.message, contains("failed with ClientException"));
      expect(records.single.message, isNot(contains("private detail")));
    });
  });

  test("every LRCLIB try gets a line, so a retry shows", () async {
    LrclibService.busyRetries = const [Duration.zero, Duration.zero];
    var asked = 0;
    await http.runWithClient(
      () => LrclibService.lookUp(
        BaseItemDto(id: const BaseItemId("song"), name: "Little Wing", albumArtist: "Jimi Hendrix"),
      ),
      () => MockClient((request) async => ++asked == 1 ? http.Response("", 503) : http.Response("", 404)),
    );
    final lines = requestLines();
    expect(lines, hasLength(asked));
    expect(lines.first, allOf(contains("lrclib.net/api/get"), contains("Little+Wing"), contains(": 503,")));
    expect(lines.last, allOf(contains("/api/search"), contains(": 404,")));
  });

  group("AI requests", () {
    const key = "secret-test-key";
    const prompt = "Tidy these private genres: Música, 日本語.";
    const reply = "Rock, Pop and Folk.";
    late SharedPreferencesAsyncPlatform? previous;

    setUp(() async {
      previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      AiProviderHealth.forgetLoaded();
      AiUsage.forgetLoaded();
      await AiService.setApiKey(AiProvider.gemini, key);
    });
    tearDown(() {
      AiUsage.forgetLoaded();
      SharedPreferencesAsyncPlatform.instance = previous;
    });

    test("are logged without the key, the prompt or the answer", () async {
      int? bytesSent;
      await http.runWithClient(
        () => AiService.generateJson(
          prompt: prompt,
          schema: const {
            'type': 'object',
            'properties': {
              'line': {'type': 'string'},
            },
            'required': ['line'],
            'additionalProperties': false,
          },
          schemaName: 'genre_groups',
        ),
        () => MockClient((request) async {
          if (request.method == "GET") {
            return http.Response(
              jsonEncode({
                'models': [
                  {'name': 'models/gemini-3.8-flash'},
                ],
              }),
              200,
            );
          }
          bytesSent = request.bodyBytes.length;
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text': jsonEncode({'line': reply}),
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
      final lines = requestLines();
      expect(lines.where((line) => line.startsWith("POST ")), hasLength(1));
      expect(
        lines.singleWhere((line) => line.startsWith("POST ")),
        // In bytes as they were sent, which isn't the prompt's length in characters.
        allOf(contains("generateContent"), contains(": 200,"), contains(", sent $bytesSent bytes")),
      );
      expect(lines.where((line) => line.startsWith("GET ")), isNotEmpty);
      final everything = records.map((record) => "${record.message} ${record.error}").join("\n");
      expect(everything, isNot(contains(key)));
      expect(everything, isNot(contains(prompt)));
      expect(lines.join("\n"), isNot(contains(reply)));
    });
  });
}
