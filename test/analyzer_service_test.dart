import 'dart:convert';

import 'package:finamp/services/analyzer_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? previous;

  setUp(() async {
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await AnalyzerService.saveSettings(url: 'http://analyzer.test', token: 't');
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = previous;
  });

  test("batches analysis at 2000 IDs and caches hits and misses from every batch", () async {
    final ids = [for (var i = 0; i < AnalyzerService.analysisBatchSize * 2 + 1; i++) "batch$i"];
    final known = {for (var i = 0; i < ids.length; i += 2) ids[i]};
    final batches = <List<String>>[];
    await http.runWithClient(
      () async {
        final result = await AnalyzerService.analysis(ids);
        expect(batches.map((batch) => batch.length), [2000, 2000, 1]);
        expect(batches.expand((batch) => batch), ids);
        expect(result.keys, unorderedEquals(known));
        expect(result[ids.last]!.bpm, 120);

        final cached = await AnalyzerService.cachedAnalysis(ids);
        expect(cached.keys, unorderedEquals(known));
        expect(cached[ids.last], same(result[ids.last]));
        // Missing analysis is cached too, including in the second batch.
        expect(batches, hasLength(3));
      },
      () => MockClient((request) async {
        expect(request.method, "POST");
        expect(request.url.path, "/analysis");
        final requested = ((jsonDecode(request.body) as Map<String, dynamic>)["ids"] as List).cast<String>();
        batches.add(requested);
        // The real endpoint ignores IDs after its 2000-ID limit.
        final processed = requested.take(2000);
        return http.Response(
          jsonEncode({
            for (final id in processed.where(known.contains)) id: {"bpm": 120},
          }),
          200,
        );
      }),
    );
  });

  test("a failed batch leaves its IDs and unrequested IDs uncached", () async {
    final ids = [for (var i = 0; i < AnalyzerService.analysisBatchSize * 2 + 1; i++) "retry$i"];
    final batches = <List<String>>[];
    await http.runWithClient(
      () async {
        await expectLater(AnalyzerService.analysis(ids), throwsA(isA<AnalyzerException>()));
        expect(batches, hasLength(2));
        expect(AnalyzerService.cached(ids.first)!.bpm, 100);

        final result = await AnalyzerService.cachedAnalysis(ids);
        expect(batches.map((batch) => batch.length), [2000, 2000, 2000, 1]);
        expect(batches.skip(2).expand((batch) => batch), ids.skip(AnalyzerService.analysisBatchSize));
        expect(result.keys, unorderedEquals([ids.first, ...ids.skip(AnalyzerService.analysisBatchSize)]));
        expect(result[ids.last]!.bpm, 120);

        await AnalyzerService.cachedAnalysis(ids);
        expect(batches, hasLength(4));
      },
      () => MockClient((request) async {
        final requested = ((jsonDecode(request.body) as Map<String, dynamic>)["ids"] as List).cast<String>();
        batches.add(requested);
        if (batches.length == 1) {
          return http.Response(
            jsonEncode({
              ids.first: {"bpm": 100},
            }),
            200,
          );
        }
        if (batches.length == 2) return http.Response("unavailable", 503);
        return http.Response(
          jsonEncode({
            for (final id in requested) id: {"bpm": 120},
          }),
          200,
        );
      }),
    );
  });

  test("empty analysis does not send a request", () async {
    await http.runWithClient(() async {
      expect(await AnalyzerService.analysis([]), isEmpty);
    }, () => MockClient((_) async => fail("No IDs to analyze")));
  });
}
